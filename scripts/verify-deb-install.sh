#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
image="${OCTANS_FFMPEG_VERIFY_IMAGE:-ubuntu:26.04}"

usage() {
  cat <<EOF
Usage: $0 PATH_TO_DEB

Verifies Octans FFmpeg deb installation in clean Ubuntu 26.04 containers.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -ne 1 ]]; then
  usage >&2
  exit 2
fi

deb_path="$(readlink -f "$1")"
[[ -f "${deb_path}" ]] || {
  echo "deb not found: $1" >&2
  exit 2
}

run_case() {
  local label="$1"
  local install_flags="$2"
  local expect_legacy="$3"
  local -a docker_args=(
    docker run --rm
    -e DEBIAN_FRONTEND=noninteractive
    -e "OCTANS_INSTALL_FLAGS=${install_flags}"
    -e "OCTANS_EXPECT_LEGACY=${expect_legacy}"
    -v "${deb_path}:/pkg/octans-ffmpeg-full.deb:ro"
    -v "${repo_root}/scripts:/scripts:ro"
  )

  echo "== ${label} =="
  docker_args+=(
    "${image}"
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

      apt-get update
      apt-get install -y ${OCTANS_INSTALL_FLAGS} /pkg/octans-ffmpeg-full.deb

      for package_name in octans-ffmpeg-full vainfo intel-media-va-driver-non-free intel-opencl-icd ocl-icd-libopencl1 mesa-vulkan-drivers; do
        assert_installed_package "${package_name}"
      done
      if [[ "${OCTANS_EXPECT_LEGACY}" == "1" ]]; then
        assert_installed_package intel-opencl-icd-legacy
      else
        assert_absent_package intel-opencl-icd-legacy
      fi

      test -x /opt/octans-ffmpeg/bin/ffmpeg
      test -x /opt/octans-ffmpeg/bin/ffprobe
      test -x /opt/octans-ffmpeg/bin/octans-ffmpeg-capabilities
      test "$(command -v vainfo)" = "/usr/bin/vainfo"
      test ! -e /opt/octans-ffmpeg/bin/vainfo
      test ! -e /opt/octans-ffmpeg/lib/dri/iHD_drv_video.so
      assert_absent_glob "/opt/octans-ffmpeg/lib/libigdgmm.so*"
      assert_absent_glob "/opt/octans-ffmpeg/lib/libigfxcmrt.so*"
      assert_absent_glob "/opt/octans-ffmpeg/lib/libOpenCL.so*"
      test ! -e /etc/OpenCL/vendors/octans.icd
      assert_absent_package fonts-noto-core
      assert_absent_package fonts-noto-cjk

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
      /scripts/verify-full-linux.sh /opt/octans-ffmpeg
    '
  )

  "${docker_args[@]}"
}

run_case "install without recommends" "--no-install-recommends" "0"
run_case "install with default recommends" "" "1"

echo "deb install verification passed: ${deb_path}"
