#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=ci-retry-helpers.sh
. "${repo_root}/scripts/ci-retry-helpers.sh"

deb_path="${OCTANS_FFMPEG_DEB_PATH:-}"
local_image="${OCTANS_FFMPEG_LOCAL_IMAGE:-}"
fixed_tag="${FIXED_TAG:-}"
trace_tag="${TRACE_TAG:-}"
moving_tag="${MOVING_TAG:-}"
recovery="${OCTANS_FFMPEG_RELEASE_RECOVERY:-false}"
lock_file="${OCTANS_FFMPEG_RELEASE_LOCK:-${OCTANS_FFMPEG_CI_CACHE_ROOT:-${repo_root}/.build}/release.lock}"
lock_timeout="${OCTANS_FFMPEG_RELEASE_LOCK_TIMEOUT_SECONDS:-0}"
harbor_repository="${OCTANS_FFMPEG_HARBOR_REPOSITORY:?OCTANS_FFMPEG_HARBOR_REPOSITORY is required}"
package_name="octans-ffmpeg-full"

usage() {
  cat <<EOF
Usage: $(basename "$0") --deb PATH --local-image IMAGE --fixed-tag TAG --moving-tag TAG [options]

Publishes an octans-ffmpeg Debian package and runtime image with release recovery guards.

Options:
  --deb PATH              Debian package path.
  --local-image IMAGE     Local Docker image to publish.
  --fixed-tag TAG         Immutable Docker fixed tag.
  --trace-tag TAG         Optional immutable trace tag.
  --moving-tag TAG        Moving Docker tag, such as edge, rc, or stable.
  --recovery true|false   Allow resuming an explicitly confirmed partial publish.
  --lock-file PATH        Host lock file. Defaults to OCTANS_FFMPEG_RELEASE_LOCK.
  --lock-timeout SECONDS  Seconds to wait for the lock. Defaults to 0.
  -h, --help              Show this help.
EOF
}

fail() {
  printf 'fail - %s\n' "$*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --deb)
      deb_path="$2"
      shift 2
      ;;
    --local-image)
      local_image="$2"
      shift 2
      ;;
    --fixed-tag)
      fixed_tag="$2"
      shift 2
      ;;
    --trace-tag)
      trace_tag="$2"
      shift 2
      ;;
    --moving-tag)
      moving_tag="$2"
      shift 2
      ;;
    --recovery)
      recovery="$2"
      shift 2
      ;;
    --lock-file)
      lock_file="$2"
      shift 2
      ;;
    --lock-timeout)
      lock_timeout="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ -n "${deb_path}" ]] || fail "--deb is required"
[[ -f "${deb_path}" ]] || fail "deb not found: ${deb_path}"
[[ -n "${local_image}" ]] || fail "--local-image is required"
[[ -n "${fixed_tag}" ]] || fail "--fixed-tag is required"
[[ -n "${moving_tag}" ]] || fail "--moving-tag is required"
[[ "${recovery}" == "true" || "${recovery}" == "false" ]] || fail "--recovery must be true or false"
[[ "${lock_timeout}" =~ ^[0-9]+$ ]] || fail "--lock-timeout must be a non-negative integer"

command -v docker >/dev/null || fail "docker is required"
command -v dpkg-deb >/dev/null || fail "dpkg-deb is required"
command -v flock >/dev/null || fail "flock is required"

package_version="$(dpkg-deb -f "${deb_path}" Version)"
deb_sha256="$(sha256sum "${deb_path}" | awk '{print $1}')"

immutable_refs=(
  "${harbor_repository}:${fixed_tag}"
)
if [[ -n "${trace_tag}" ]]; then
  immutable_refs+=(
    "${harbor_repository}:${trace_tag}"
  )
fi

moving_refs=(
  "${harbor_repository}:${moving_tag}"
)

inspect_digest() {
  octans_ci_imagetools_digest "$1"
}

ref_digest_or_empty() {
  local ref="$1"
  inspect_digest "${ref}" 2>/dev/null || true
}

copy_remote_manifest() {
  local source_ref="$1"
  local target_ref="$2"
  printf 'copying remote manifest: %s -> %s\n' "${source_ref}" "${target_ref}"
  octans_ci_imagetools_create "${target_ref}" "${source_ref}"
}

verify_deb_exists() {
  local output
  output="$(mktemp)"
  if "${repo_root}/scripts/verify-gitea-debian-package.sh" \
      --package-name "${package_name}" \
      --version "${package_version}" \
      --max-attempts 1 >"${output}" 2>&1; then
    rm -f "${output}"
    return 0
  fi

  if grep -Fq 'package is not visible in Debian registry' "${output}"; then
    rm -f "${output}"
    return 1
  fi

  cat "${output}" >&2
  rm -f "${output}"
  fail "failed to check Debian package state"
}

verify_deb_install() {
  "${repo_root}/scripts/verify-gitea-debian-package.sh" \
    --package-name "${package_name}" \
    --version "${package_version}" \
    --install
}

publish_or_recover_deb() {
  if verify_deb_exists; then
    if [[ "${recovery}" != "true" ]]; then
      fail "Debian package already exists; rerun with recovery=true only if resuming the same failed release"
    fi

    printf 'Debian package already exists, recovery mode will reuse it:\n'
    printf '  package: %s\n' "${package_name}"
    printf '  version: %s\n' "${package_version}"
  else
    "${repo_root}/scripts/publish-gitea-debian-package.sh" \
      --deb "${deb_path}"
  fi

  verify_deb_install
}

check_immutable_refs() {
  existing_ref=""
  expected_digest=""

  printf 'checking immutable image refs:\n'
  for ref in "${immutable_refs[@]}"; do
    digest="$(ref_digest_or_empty "${ref}")"
    if [[ -z "${digest}" ]]; then
      printf '  - missing %s\n' "${ref}"
      continue
    fi

    printf '  - exists  %s %s\n' "${ref}" "${digest}"
    if [[ "${recovery}" != "true" ]]; then
      fail "immutable image ref already exists; rerun with recovery=true only if resuming the same failed release"
    fi

    if [[ -z "${expected_digest}" ]]; then
      expected_digest="${digest}"
      existing_ref="${ref}"
    elif [[ "${digest}" != "${expected_digest}" ]]; then
      fail "existing immutable image refs have different digests"
    fi
  done
}

push_or_recover_images() {
  if [[ -n "${expected_digest}" ]]; then
    for ref in "${immutable_refs[@]}"; do
      digest="$(ref_digest_or_empty "${ref}")"
      if [[ -z "${digest}" ]]; then
        copy_remote_manifest "${existing_ref}" "${ref}"
      fi
    done
  else
    for ref in "${immutable_refs[@]}"; do
      docker tag "${local_image}" "${ref}"
      octans_ci_docker_push "${ref}"
    done
    existing_ref="${immutable_refs[0]}"
  fi

  expected_digest=""
  printf 'verified immutable image digests:\n'
  for ref in "${immutable_refs[@]}"; do
    digest="$(ref_digest_or_empty "${ref}")"
    [[ -n "${digest}" ]] || fail "failed to read immutable image digest: ${ref}"
    printf '  - %s %s\n' "${ref}" "${digest}"

    if [[ -z "${expected_digest}" ]]; then
      expected_digest="${digest}"
      existing_ref="${ref}"
    elif [[ "${digest}" != "${expected_digest}" ]]; then
      fail "immutable image digest mismatch: ${ref}"
    fi
  done

  printf 'updating moving image refs last:\n'
  for ref in "${moving_refs[@]}"; do
    copy_remote_manifest "${existing_ref}" "${ref}"
    digest="$(ref_digest_or_empty "${ref}")"
    [[ -n "${digest}" ]] || fail "failed to read moving image digest: ${ref}"
    if [[ "${digest}" != "${expected_digest}" ]]; then
      fail "moving image digest mismatch: ${ref}"
    fi
    printf '  - %s %s\n' "${ref}" "${digest}"
  done

  if [[ -n "${GITHUB_ENV:-}" ]]; then
    echo "OCTANS_FFMPEG_PUBLISHED_DIGEST=${expected_digest}" >> "${GITHUB_ENV}"
  fi
}

mkdir -p "$(dirname "${lock_file}")"
exec 9>"${lock_file}"

if ! flock -w "${lock_timeout}" 9; then
  fail "another octans-ffmpeg release is already running: ${lock_file}"
fi

printf 'acquired octans-ffmpeg release lock:\n'
printf '  lock_file: %s\n' "${lock_file}"
printf '  recovery: %s\n' "${recovery}"
printf '  deb: %s\n' "${deb_path}"
printf '  deb_sha256: %s\n' "${deb_sha256}"
printf '  local_image: %s\n' "${local_image}"
printf '  fixed_tag: %s\n' "${fixed_tag}"
if [[ -n "${trace_tag}" ]]; then
  printf '  trace_tag: %s\n' "${trace_tag}"
fi
printf '  moving_tag: %s\n' "${moving_tag}"

check_immutable_refs
publish_or_recover_deb
push_or_recover_images

printf 'octans-ffmpeg release publish completed:\n'
printf '  deb_version: %s\n' "${package_version}"
printf '  docker_digest: %s\n' "${expected_digest}"
