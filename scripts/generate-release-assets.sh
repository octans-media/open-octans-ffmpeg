#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=ci-retry-helpers.sh
. "${repo_root}/scripts/ci-retry-helpers.sh"

stage_dir=""
build_root="${OCTANS_FFMPEG_BUILD_ROOT:-}"
build_version="${OCTANS_FFMPEG_BUILD_VERSION:-}"
deb_path="${OCTANS_FFMPEG_DEB_PATH:-}"
release_channel="${OCTANS_FFMPEG_RELEASE_CHANNEL:-stable}"
release_version="${OCTANS_FFMPEG_RELEASE_VERSION:-${OCTANS_FFMPEG_STABLE_VERSION:-}}"
deb_version="${OCTANS_FFMPEG_DEB_VERSION:-}"
image_digest="${OCTANS_FFMPEG_PUBLISHED_DIGEST:-}"
fixed_tag="${FIXED_TAG:-}"
trace_tag="${TRACE_TAG:-}"
moving_tag="${MOVING_TAG:-stable}"
harbor_repository="${OCTANS_FFMPEG_HARBOR_REPOSITORY:?OCTANS_FFMPEG_HARBOR_REPOSITORY is required}"
distribution="${OCTANS_GITEA_DEBIAN_DISTRIBUTION:-resolute}"
component="${OCTANS_GITEA_DEBIAN_COMPONENT:-main}"
gitea_url="${OCTANS_GITEA_URL:?OCTANS_GITEA_URL is required}"
package_owner="${OCTANS_GITEA_PACKAGE_OWNER:-octans}"
base_image_ref="${OCTANS_FFMPEG_BASE_IMAGE_REF:-ubuntu:26.04}"
base_image_digest="${OCTANS_FFMPEG_BASE_IMAGE_DIGEST:-}"
release_dir=""

usage() {
  cat <<EOF
Usage: $(basename "$0") --stage PATH --version VERSION --channel stable|rc [options]

Generates Gitea Release assets for octans-ffmpeg RC and stable releases.

Options:
  --stage PATH           Staged runtime path containing bin/ffmpeg.
  --build-root PATH      CI build root. Defaults to OCTANS_FFMPEG_BUILD_ROOT.
  --build-version NAME   Build version. Defaults to OCTANS_FFMPEG_BUILD_VERSION.
  --deb PATH             Debian package path. Defaults to OCTANS_FFMPEG_DEB_PATH.
  --version VER          Release version, e.g. 8.1.3-jellyfin1-octans15-rc.1.
  --stable-version VER   Backward-compatible alias for --version.
  --channel NAME         Release channel: stable or rc. Defaults to stable.
  --deb-version VER      Debian version. Defaults to OCTANS_FFMPEG_DEB_VERSION.
  --image-digest SHA     Published Docker digest.
  --fixed-tag TAG        Fixed Docker tag.
  --trace-tag TAG        Trace Docker tag.
  --moving-tag TAG       Moving Docker tag. Defaults to stable.
  --base-image-ref REF   Docker base image ref. Defaults to ubuntu:26.04.
  --base-image-digest D  Docker base image digest.
  --release-dir PATH     Output directory for release assets.
  -h, --help             Show this help.
EOF
}

fail() {
  printf 'fail - %s\n' "$*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stage)
      stage_dir="$2"
      shift 2
      ;;
    --build-root)
      build_root="$2"
      shift 2
      ;;
    --build-version)
      build_version="$2"
      shift 2
      ;;
    --deb)
      deb_path="$2"
      shift 2
      ;;
    --version)
      release_version="$2"
      shift 2
      ;;
    --stable-version)
      release_version="$2"
      shift 2
      ;;
    --channel)
      release_channel="$2"
      shift 2
      ;;
    --deb-version)
      deb_version="$2"
      shift 2
      ;;
    --image-digest)
      image_digest="$2"
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
    --base-image-ref)
      base_image_ref="$2"
      shift 2
      ;;
    --base-image-digest)
      base_image_digest="$2"
      shift 2
      ;;
    --release-dir)
      release_dir="$2"
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

[[ -n "${stage_dir}" ]] || fail "--stage is required"
[[ -n "${build_root}" ]] || fail "--build-root is required"
[[ -n "${build_version}" ]] || fail "--build-version is required"
[[ -n "${deb_path}" ]] || fail "--deb is required"
[[ -n "${release_version}" ]] || fail "--version is required"
[[ -n "${deb_version}" ]] || fail "--deb-version is required"
[[ -n "${image_digest}" ]] || fail "--image-digest is required"
[[ -n "${fixed_tag}" ]] || fail "--fixed-tag is required"
[[ -n "${trace_tag}" ]] || fail "--trace-tag is required"

case "${release_channel}" in
  stable|rc)
    ;;
  *)
    fail "--channel must be stable or rc: ${release_channel}"
    ;;
esac

prerelease=false
if [[ "${release_channel}" == "rc" ]]; then
  prerelease=true
fi

command -v git >/dev/null || fail "git is required"
command -v jq >/dev/null || fail "jq is required"
command -v zstd >/dev/null || fail "zstd is required"

if [[ -n "$(git -C "${repo_root}" status --porcelain)" ]]; then
  fail "refusing to generate source bundle from dirty worktree"
fi

ffmpeg_bin="${stage_dir}/bin/ffmpeg"
ffprobe_bin="${stage_dir}/bin/ffprobe"
runtime_tar="${build_root}/dist/${build_version}.tar.zst"
patch_log="${build_root}/logs/${build_version}-patches.log"

[[ -x "${ffmpeg_bin}" ]] || fail "missing staged ffmpeg: ${ffmpeg_bin}"
[[ -x "${ffprobe_bin}" ]] || fail "missing staged ffprobe: ${ffprobe_bin}"
[[ -f "${deb_path}" ]] || fail "missing deb: ${deb_path}"
[[ -f "${runtime_tar}" ]] || fail "missing runtime tar: ${runtime_tar}"

if [[ -z "${release_dir}" ]]; then
  release_dir="${build_root}/release-assets"
fi

rm -rf "${release_dir}"
mkdir -p "${release_dir}"

deb_file="$(basename "${deb_path}")"
runtime_file="octans-ffmpeg-full-${release_version}-resolute-amd64-runtime.tar.zst"
source_file="octans-ffmpeg-full-${release_version}-source.tar.zst"
release_tag="octans-ffmpeg-full-${release_version}"
published_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
source_commit="$(git -C "${repo_root}" rev-parse HEAD)"
source_short_commit="$(git -C "${repo_root}" rev-parse --short=8 HEAD)"
source_branch="${GITHUB_REF_NAME:-$(git -C "${repo_root}" rev-parse --abbrev-ref HEAD)}"
source_remote="$(git -C "${repo_root}" config --get remote.origin.url || true)"

if [[ -z "${base_image_digest}" ]]; then
  command -v docker >/dev/null || fail "docker is required when --base-image-digest is not provided"
  base_image_digest="$(octans_ci_imagetools_digest "${base_image_ref}")"
fi

[[ -n "${base_image_digest}" ]] || fail "cannot resolve base image digest: ${base_image_ref}"

cp "${deb_path}" "${release_dir}/${deb_file}"
cp "${runtime_tar}" "${release_dir}/${runtime_file}"

(
  cd "${release_dir}"
  sha256sum "${deb_file}" > "${deb_file}.sha256"
  sha256sum "${runtime_file}" > "${runtime_file}.sha256"
)

git -C "${repo_root}" archive \
  --format=tar \
  --prefix="octans-ffmpeg-${release_version}/" \
  HEAD \
  | zstd -q -19 -T0 -o "${release_dir}/${source_file}" >/dev/null
(
  cd "${release_dir}"
  sha256sum "${source_file}" > "${source_file}.sha256"
)

{
  printf '# ffmpeg -version\n'
  "${ffmpeg_bin}" -version
  printf '\n# ffprobe -version\n'
  "${ffprobe_bin}" -version
} > "${release_dir}/ffmpeg-version.txt"

"${ffmpeg_bin}" -hide_banner -buildconf > "${release_dir}/ffmpeg-buildconf.txt"
"${ffmpeg_bin}" -hide_banner -L > "${release_dir}/ffmpeg-license-output.txt"

{
  printf '# dpkg-source --before-build output\n'
  if [[ -f "${patch_log}" ]]; then
    cat "${patch_log}"
  else
    printf 'missing patch log: %s\n' "${patch_log}"
  fi

  printf '\n# debian/patches/series\n'
  if [[ -f "${repo_root}/debian/patches/series" ]]; then
    cat "${repo_root}/debian/patches/series"
  else
    printf 'none\n'
  fi

  printf '\n# bundled builder patches\n'
  if [[ -d "${repo_root}/builder/patches" ]]; then
    find "${repo_root}/builder/patches" -type f -name '*.patch' \
      -printf '%P\n' | sort
  else
    printf 'none\n'
  fi
} > "${release_dir}/patches-applied.txt"

{
  printf 'release_tag=%s\n' "${release_tag}"
  printf 'release_channel=%s\n' "${release_channel}"
  printf 'release_version=%s\n' "${release_version}"
  printf 'prerelease=%s\n' "${prerelease}"
  printf 'deb_version=%s\n' "${deb_version}"
  printf 'source_remote=%s\n' "${source_remote}"
  printf 'source_branch=%s\n' "${source_branch}"
  printf 'source_commit=%s\n' "${source_commit}"
  printf 'source_short_commit=%s\n' "${source_short_commit}"
  printf 'build_script_commit=%s\n' "${source_commit}"
  printf 'upstream_baseline=%s\n' "$(git -C "${repo_root}" describe --tags --always)"
  printf 'docker_base_image=%s\n' "${base_image_ref}"
  printf 'docker_base_digest=%s\n' "${base_image_digest}"
  printf 'docker_fixed_ref=%s:%s\n' "${harbor_repository}" "${fixed_tag}"
  printf 'docker_trace_ref=%s:%s\n' "${harbor_repository}" "${trace_tag}"
  printf 'docker_moving_ref=%s:%s\n' "${harbor_repository}" "${moving_tag}"
  printf 'docker_digest=%s\n' "${image_digest}"
  printf 'debian_registry=%s/api/packages/%s/debian\n' "${gitea_url}" "${package_owner}"
  printf 'debian_distribution=%s\n' "${distribution}"
  printf 'debian_component=%s\n' "${component}"
  printf 'published_at=%s\n' "${published_at}"
} > "${release_dir}/source-refs.txt"

artifact_json="$(mktemp)"
trap 'rm -f "${artifact_json}"' EXIT
: > "${artifact_json}"

while IFS= read -r -d '' file_path; do
  file_name="$(basename "${file_path}")"
  file_sha="$(sha256sum "${file_path}" | awk '{print $1}')"
  file_size="$(stat -c '%s' "${file_path}")"
  jq -n \
    --arg file "${file_name}" \
    --arg sha256 "${file_sha}" \
    --argjson bytes "${file_size}" \
    '{file: $file, sha256: $sha256, bytes: $bytes}' \
    >> "${artifact_json}"
done < <(
  find "${release_dir}" -maxdepth 1 -type f \
    ! -name 'release-manifest.json' \
    ! -name 'sha256sums.txt' \
    -print0 | sort -z
)

jq -s \
  --arg published_at "${published_at}" \
  --arg release_tag "${release_tag}" \
  --arg release_channel "${release_channel}" \
  --arg release_version "${release_version}" \
  --argjson prerelease "${prerelease}" \
  --arg source_remote "${source_remote}" \
  --arg source_branch "${source_branch}" \
  --arg source_commit "${source_commit}" \
  --arg source_short_commit "${source_short_commit}" \
  --arg deb_file "${deb_file}" \
  --arg deb_version "${deb_version}" \
  --arg distribution "${distribution}" \
  --arg component "${component}" \
  --arg debian_registry "${gitea_url}/api/packages/${package_owner}/debian" \
  --arg fixed_tag "${fixed_tag}" \
  --arg trace_tag "${trace_tag}" \
  --arg moving_tag "${moving_tag}" \
  --arg image_digest "${image_digest}" \
  --arg harbor_repository "${harbor_repository}" \
  --arg base_image_ref "${base_image_ref}" \
  --arg base_image_digest "${base_image_digest}" \
  '{
    schemaVersion: 1,
    kind: "octans-ffmpeg-release",
    publishedAt: $published_at,
    release: {
      tag: $release_tag,
      channel: $release_channel,
      version: $release_version,
      prerelease: $prerelease
    },
    source: {
      remote: $source_remote,
      branch: $source_branch,
      commit: $source_commit,
      shortCommit: $source_short_commit
    },
    debian: {
      package: "octans-ffmpeg-full",
      version: $deb_version,
      file: $deb_file,
      distribution: $distribution,
      component: $component,
      registry: $debian_registry
    },
    docker: {
      fixedTag: $fixed_tag,
      traceTag: $trace_tag,
      movingTag: $moving_tag,
      digest: $image_digest,
      harbor: "\($harbor_repository):\($fixed_tag)",
      baseImage: {
        ref: $base_image_ref,
        digest: $base_image_digest
      }
    },
    verification: [
      "scripts/verify-full-linux.sh",
      "scripts/verify-deb-install.sh",
      "scripts/verify-runtime-image.sh",
      "scripts/verify-runtime-image-gpu.sh",
      "scripts/verify-gitea-debian-package.sh --install",
      "docker buildx imagetools inspect Harbor digest"
    ],
    artifacts: .
  }' "${artifact_json}" > "${release_dir}/release-manifest.json"

(
  cd "${release_dir}"
  find . -maxdepth 1 -type f ! -name 'sha256sums.txt' \
    -printf '%P\0' | sort -z | xargs -0 sha256sum > sha256sums.txt
)

printf 'release assets generated:\n'
printf '  channel: %s\n' "${release_channel}"
printf '  version: %s\n' "${release_version}"
printf '  release_dir: %s\n' "${release_dir}"
find "${release_dir}" -maxdepth 1 -type f -printf '  - %f\n' | sort
