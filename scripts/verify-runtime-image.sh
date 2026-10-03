#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
default_image="${OCTANS_FFMPEG_RUNTIME_IMAGE:-octans-ffmpeg-full:8.1.3-jellyfin1-octans15-resolute-amd64}"
image="${1:-${default_image}}"

usage() {
  cat <<EOF
Usage: $0 [IMAGE]

Verifies an octans-ffmpeg-full Ubuntu 26.04 runtime image.
Default image: ${default_image}
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

docker image inspect "${image}" >/dev/null

docker run --rm \
  -v "${repo_root}/scripts:/scripts:ro" \
  "${image}" \
  bash -lc '
    set -euo pipefail
    assert_no_missing() {
      local ldd_output="$1"
      if grep -F "not found" "${ldd_output}"; then
        exit 1
      fi
    }

    is_installed_package() {
      local package_name="$1"
      [[ "$(dpkg-query -W -f="\${Status}" "${package_name}" 2>/dev/null || true)" == "install ok installed" ]]
    }

    assert_installed_package() {
      local package_name="$1"
      if ! is_installed_package "${package_name}"; then
        echo "expected package is not installed: ${package_name}" >&2
        exit 1
      fi
    }

    assert_absent_package() {
      local package_name="$1"
      if is_installed_package "${package_name}"; then
        echo "unexpected package installed: ${package_name}" >&2
        exit 1
      fi
    }

    assert_absent_glob() {
      local pattern="$1"
      if compgen -G "${pattern}" >/dev/null; then
        echo "unexpected path matched: ${pattern}" >&2
        exit 1
      fi
    }

    for package_name in octans-ffmpeg-full vainfo intel-media-va-driver-non-free intel-opencl-icd ocl-icd-libopencl1 mesa-vulkan-drivers; do
      assert_installed_package "${package_name}"
    done
    assert_absent_package octans-intel-media-runtime
    assert_absent_package intel-opencl-icd-legacy
    assert_absent_package fonts-noto-core
    assert_absent_package fonts-noto-cjk
    test "$(command -v ffmpeg)" = "/opt/octans-ffmpeg/bin/ffmpeg"
    test "$(command -v ffprobe)" = "/opt/octans-ffmpeg/bin/ffprobe"
    test "$(command -v octans-ffmpeg-capabilities)" = "/opt/octans-ffmpeg/bin/octans-ffmpeg-capabilities"
    test "$(command -v vainfo)" = "/usr/bin/vainfo"
    test ! -e /opt/octans-ffmpeg/bin/vainfo
    test ! -e /opt/octans-ffmpeg/lib/dri/iHD_drv_video.so
    assert_absent_glob "/opt/octans-ffmpeg/lib/libigdgmm.so*"
    assert_absent_glob "/opt/octans-ffmpeg/lib/libigfxcmrt.so*"
    assert_absent_glob "/opt/octans-ffmpeg/lib/libOpenCL.so*"
    ldd /opt/octans-ffmpeg/bin/ffmpeg | tee /tmp/octans-ffmpeg-ldd.txt
    assert_no_missing /tmp/octans-ffmpeg-ldd.txt
    ldd /opt/octans-ffmpeg/bin/ffprobe | tee /tmp/octans-ffprobe-ldd.txt
    assert_no_missing /tmp/octans-ffprobe-ldd.txt
    ldd /opt/octans-ffmpeg/bin/octans-ffmpeg-capabilities | tee /tmp/octans-ffmpeg-capabilities-ldd.txt
    assert_no_missing /tmp/octans-ffmpeg-capabilities-ldd.txt
    /opt/octans-ffmpeg/bin/octans-ffmpeg-capabilities --format json \
      --ffmpeg /opt/octans-ffmpeg/bin/ffmpeg \
      --ffprobe /opt/octans-ffmpeg/bin/ffprobe \
      >/tmp/octans-ffmpeg-capabilities.json
    grep -Fq "\"schemaVersion\":1" /tmp/octans-ffmpeg-capabilities.json
    /usr/bin/vainfo --help >/dev/null
    /opt/octans-ffmpeg/bin/ffmpeg -hide_banner -loglevel error \
      -init_hw_device vulkan=vk \
      -f lavfi -i testsrc2=size=64x64:duration=0.1 \
      -frames:v 1 -f null - >/dev/null
    /scripts/verify-full-linux.sh /opt/octans-ffmpeg
  '

echo "runtime image verification passed: ${image}"
