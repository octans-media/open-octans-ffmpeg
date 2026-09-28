#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

build_root="${OCTANS_FFMPEG_BUILD_ROOT:-${repo_root}/.build}"
deb_path="${OCTANS_FFMPEG_DEB_PATH:-${build_root}/dist/octans-ffmpeg-full_8.1.2+jellyfin4+octans13_amd64.deb}"
image_version="${OCTANS_FFMPEG_IMAGE_VERSION:-8.1.2-jellyfin4-octans13-resolute-amd64}"
local_image="${OCTANS_FFMPEG_RUNTIME_IMAGE:-octans-ffmpeg-full:${image_version}}"
harbor_image="${OCTANS_FFMPEG_HARBOR_IMAGE:-}"
context_dir="${OCTANS_FFMPEG_RUNTIME_CONTEXT:-${build_root}/work/runtime-image/${image_version}}"
no_cache=0
registry_tags=1

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --deb PATH                  Debian package path. Defaults to ${deb_path}
  --version VERSION           Image version/tag suffix. Defaults to ${image_version}
  --tag IMAGE                 Local image tag. Defaults to ${local_image}
  --harbor-tag IMAGE          Harbor image tag. Defaults to ${harbor_image}
  --context-dir PATH          Build context directory. Defaults to ${context_dir}
  --no-cache                  Pass --no-cache to docker build.
  --no-registry-tags          Build only the local image tag.
  -h, --help                  Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --deb)
      deb_path="$2"
      shift 2
      ;;
    --version)
      image_version="$2"
      local_image="octans-ffmpeg-full:${image_version}"
      context_dir="${build_root}/work/runtime-image/${image_version}"
      if [[ -n "${OCTANS_FFMPEG_HARBOR_REPOSITORY:-}" && -z "${OCTANS_FFMPEG_HARBOR_IMAGE:-}" ]]; then
        harbor_image="${OCTANS_FFMPEG_HARBOR_REPOSITORY}:${image_version}"
      fi
      shift 2
      ;;
    --tag)
      local_image="$2"
      shift 2
      ;;
    --harbor-tag)
      harbor_image="$2"
      shift 2
      ;;
    --context-dir)
      context_dir="$2"
      shift 2
      ;;
    --no-cache)
      no_cache=1
      shift
      ;;
    --no-registry-tags)
      registry_tags=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

fail() {
  echo "fail - $*" >&2
  exit 1
}

deb_path="$(readlink -f "${deb_path}")"
[[ -f "${deb_path}" ]] || fail "deb not found: ${deb_path}"

deb_sha256="$(sha256sum "${deb_path}" | awk '{print $1}')"

rm -rf "${context_dir}"
mkdir -p "${context_dir}"
cp "${deb_path}" "${context_dir}/octans-ffmpeg-full.deb"
printf '%s  %s\n' "${deb_sha256}" "octans-ffmpeg-full.deb" > "${context_dir}/octans-ffmpeg-full.deb.sha256"

build_args=(
  docker build
  -f "${repo_root}/docker/octans-runtime-linux.Dockerfile"
  --build-arg "OCTANS_FFMPEG_IMAGE_VERSION=${image_version}"
  --build-arg "OCTANS_FFMPEG_DEB_SHA256=${deb_sha256}"
  -t "${local_image}"
)

if [[ "${no_cache}" -eq 1 ]]; then
  build_args+=(--no-cache)
fi

build_args+=("${context_dir}")
"${build_args[@]}"

if [[ "${registry_tags}" -eq 1 ]]; then
  if [[ -z "${harbor_image}" && -n "${OCTANS_FFMPEG_HARBOR_REPOSITORY:-}" ]]; then
    harbor_image="${OCTANS_FFMPEG_HARBOR_REPOSITORY}:${image_version}"
  fi
  if [[ -z "${harbor_image}" ]]; then
    fail "set OCTANS_FFMPEG_HARBOR_REPOSITORY or pass --harbor-tag or --no-registry-tags"
  fi
  docker tag "${local_image}" "${harbor_image}"
fi

image_id="$(docker image inspect --format '{{.Id}}' "${local_image}")"
image_size="$(docker image inspect --format '{{.Size}}' "${local_image}")"

echo "deb: ${deb_path}"
echo "deb_sha256: ${deb_sha256}"
echo "context: ${context_dir}"
echo "local_image: ${local_image}"
if [[ "${registry_tags}" -eq 1 ]]; then
  echo "harbor_image: ${harbor_image}"
else
  echo "registry_tags: disabled"
fi
echo "image_id: ${image_id}"
echo "image_size_bytes: ${image_size}"
