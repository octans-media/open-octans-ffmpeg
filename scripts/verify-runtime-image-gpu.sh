#!/usr/bin/env bash
set -euo pipefail

default_image="${OCTANS_FFMPEG_RUNTIME_IMAGE:-octans-ffmpeg-full:8.1.2-jellyfin4-octans13-resolute-amd64}"
image="${1:-${default_image}}"
device="${OCTANS_FFMPEG_DRI_DEVICE:-/dev/dri/renderD128}"

usage() {
  cat <<EOF
Usage: $0 [IMAGE]

Verifies GPU capability for an octans-ffmpeg-full Ubuntu 26.04 runtime image.
Default image: ${default_image}
Default render device: ${device}
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

fail() {
  echo "fail - $*" >&2
  exit 1
}

command -v docker >/dev/null || fail "docker is required"
command -v jq >/dev/null || fail "jq is required"
docker image inspect "${image}" >/dev/null
[[ -e "${device}" ]] || fail "render device not found: ${device}"

capabilities_json="$(mktemp)"
trap 'rm -f "${capabilities_json}"' EXIT

docker run --rm \
  --device "${device}:${device}" \
  -e "OCTANS_FFMPEG_DRI_DEVICE=${device}" \
  "${image}" \
  bash -lc '
    set -euo pipefail
    device="${OCTANS_FFMPEG_DRI_DEVICE}"
    test -e "${device}"
    /opt/octans-ffmpeg/bin/octans-ffmpeg-capabilities \
      --format json \
      --ffmpeg /opt/octans-ffmpeg/bin/ffmpeg \
      --ffprobe /opt/octans-ffmpeg/bin/ffprobe \
      --vaapi-device "${device}" \
      --opencl-vaapi-interop-smoke
  ' > "${capabilities_json}"

jq -e '.fatalError == null' "${capabilities_json}" >/dev/null
jq -e '.raw.hardwareDevices.vaapi.available == true' "${capabilities_json}" >/dev/null
jq -e '.raw.hardwareDevices.opencl.available == true' "${capabilities_json}" >/dev/null
jq -e '.raw.hardwareDevices.opencl.interop.vaapi.frameMapping.available == true' "${capabilities_json}" >/dev/null
jq -e '[.raw.hardwareDevices.vaapi.encodeProfiles[]? | select(.codec == "h264" and .supported == true)] | length > 0' "${capabilities_json}" >/dev/null

docker run --rm \
  --device "${device}:${device}" \
  -e "OCTANS_FFMPEG_DRI_DEVICE=${device}" \
  "${image}" \
  bash -lc '
    set -euo pipefail
    device="${OCTANS_FFMPEG_DRI_DEVICE}"
    /opt/octans-ffmpeg/bin/ffmpeg -hide_banner -loglevel error \
      -init_hw_device vaapi=va:"${device}" \
      -filter_hw_device va \
      -f lavfi -i testsrc2=size=64x64:duration=0.1 \
      -vf "format=nv12,hwupload,scale_vaapi=w=64:h=64" \
      -c:v h264_vaapi \
      -frames:v 1 \
      -f null - >/dev/null
  '

echo "runtime image GPU verification passed: ${image}"
