#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_root="${OCTANS_FFMPEG_BUILD_ROOT:-${repo_root}/.build}"
input_path="${1:-${OCTANS_FFMPEG_STAGE:-${build_root}/stage/current}}"
link_path="${OCTANS_FFMPEG_HOST_LINK:-/opt/octans-ffmpeg}"

run_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

resolve_runtime_dir() {
  local candidate="$1"

  if [[ -x "${candidate}/bin/ffmpeg" && -x "${candidate}/bin/ffprobe" ]]; then
    readlink -f "${candidate}"
    return
  fi

  if [[ -x "${candidate}/opt/octans-ffmpeg/bin/ffmpeg" && -x "${candidate}/opt/octans-ffmpeg/bin/ffprobe" ]]; then
    readlink -f "${candidate}/opt/octans-ffmpeg"
    return
  fi

  echo "invalid runtime path: ${candidate}" >&2
  echo "expected either bin/ffmpeg or opt/octans-ffmpeg/bin/ffmpeg under the path" >&2
  exit 2
}

runtime_dir="$(resolve_runtime_dir "${input_path}")"
ffmpeg_bin="${runtime_dir}/bin/ffmpeg"
ffprobe_bin="${runtime_dir}/bin/ffprobe"

if [[ -e "${link_path}" && ! -L "${link_path}" ]]; then
  echo "refusing to replace non-symlink path: ${link_path}" >&2
  exit 3
fi

run_root mkdir -p "$(dirname "${link_path}")"
run_root ln -sfnT "${runtime_dir}" "${link_path}"

"${link_path}/bin/ffmpeg" -hide_banner -version | sed -n '1,4p'
"${link_path}/bin/ffprobe" -hide_banner -version | sed -n '1,2p'

ldd_output="$(ldd "${link_path}/bin/ffmpeg")"
printf '%s\n' "${ldd_output}" | grep 'not found' && exit 4 || true

"${link_path}/bin/ffmpeg" -hide_banner -hwaccels
"${link_path}/bin/ffmpeg" -hide_banner -h muxer=hls | grep -E 'hls_segment_type|hls_flags'
"${link_path}/bin/ffmpeg" -hide_banner -h filter=tonemapx | grep -F apply_dovi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

printf '1\n00:00:00,000 --> 00:00:00,200\nhello\n' > "${tmp_dir}/in.srt"
"${link_path}/bin/ffmpeg" -hide_banner -y \
  -f srt -i "${tmp_dir}/in.srt" \
  -map 0:s:0 \
  -c:s webvtt \
  -f webvtt "${tmp_dir}/out.vtt" >/dev/null

grep -q '^WEBVTT' "${tmp_dir}/out.vtt"

echo "host runtime: ${link_path} -> ${runtime_dir}"
