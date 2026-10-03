#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

package_name="${OCTANS_FFMPEG_DEB_PACKAGE:-}"
if [[ -z "${package_name}" ]]; then
  package_name="octans-ffmpeg-full"
fi
package_kind="${OCTANS_FFMPEG_DEB_KIND:-core}"
version="${OCTANS_FFMPEG_DEB_VERSION:-8.1.3+jellyfin1+octans15}"
arch="${OCTANS_FFMPEG_DEB_ARCH:-amd64}"
build_root="${OCTANS_FFMPEG_BUILD_ROOT:-${repo_root}/.build}"
stage_input="${OCTANS_FFMPEG_STAGE:-${build_root}/stage/current}"
output_dir="${OCTANS_FFMPEG_DIST_DIR:-${build_root}/dist}"
maintainer="${OCTANS_FFMPEG_DEB_MAINTAINER:-Octans Media <octans-media@users.noreply.github.com>}"

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --stage PATH          Runtime path or stage root. Defaults to ${stage_input}
  --version VERSION    Debian package version. Defaults to ${version}
  --output-dir PATH    Output directory. Defaults to ${output_dir}
  --package-name NAME  Package name. Defaults to ${package_name}
  --package-kind KIND  Package kind: core. Defaults to ${package_kind}
  --arch ARCH          Package architecture. Defaults to ${arch}
  -h, --help           Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stage)
      stage_input="$2"
      shift 2
      ;;
    --version)
      version="$2"
      shift 2
      ;;
    --output-dir)
      output_dir="$2"
      shift 2
      ;;
    --package-name)
      package_name="$2"
      shift 2
      ;;
    --package-kind|--kind)
      package_kind="$2"
      shift 2
      ;;
    --arch)
      arch="$2"
      shift 2
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

case "${package_kind}" in
  core)
    ;;
  *)
    echo "invalid package kind: ${package_kind}; Ubuntu 26.04 builds only support core" >&2
    usage >&2
    exit 2
    ;;
esac

fail() {
  echo "fail - $*" >&2
  exit 1
}

is_legacy_uppercase_version() {
  [[ "$1" =~ ^7\.1\.3\+Jellyfin6\+octans[1-8]([~+].*)?$ ]]
}

if [[ "${version}" =~ [A-Z] ]] && ! is_legacy_uppercase_version "${version}"; then
  fail "new deb versions must use lowercase letters; keep historical 7.1.3+Jellyfin6+octans1..octans8 unchanged"
fi

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

  fail "invalid runtime path: ${candidate}"
}

is_elf() {
  file -b "$1" 2>/dev/null | grep -q 'ELF'
}

read_needed() {
  readelf -d "$1" 2>/dev/null | sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p'
}

has_glob() {
  compgen -G "$1" >/dev/null
}

resolve_system_package() {
  local lib_name="$1"
  local path
  local real_path
  local owner

  path="$(ldconfig -p | awk -v lib="${lib_name}" '$1 == lib {print $NF; exit}')"
  [[ -n "${path}" ]] || fail "cannot resolve shared library from ldconfig: ${lib_name}"

  real_path="$(realpath -e "${path}" 2>/dev/null || true)"
  [[ -n "${real_path}" ]] || real_path="${path}"

  owner="$(dpkg -S "${real_path}" 2>/dev/null | head -n1 | cut -d: -f1 || true)"
  if [[ -z "${owner}" ]]; then
    owner="$(dpkg -S "${path}" 2>/dev/null | head -n1 | cut -d: -f1 || true)"
  fi

  [[ -n "${owner}" ]] || fail "cannot map ${lib_name} (${real_path}) to an installed Debian package"
  printf '%s\n' "${owner}"
}

join_control_list() {
  local -a values=("$@")
  local result=""
  local value

  for value in "${values[@]}"; do
    if [[ -z "${result}" ]]; then
      result="${value}"
    else
      result="${result}, ${value}"
    fi
  done

  printf '%s\n' "${result}"
}

copy_core_payload() {
  rsync -a --delete "${runtime_dir}/" "${package_root}/opt/octans-ffmpeg/"

  rm -f "${package_root}/opt/octans-ffmpeg/bin/vainfo"
  rm -rf "${package_root}/opt/octans-ffmpeg/lib/dri"
  rm -f "${package_root}/opt/octans-ffmpeg/lib"/libigdgmm.so*
  rm -f "${package_root}/opt/octans-ffmpeg/lib"/libigfxcmrt.so*
  rm -f "${package_root}/opt/octans-ffmpeg/lib"/libOpenCL.so*
  rm -f "${package_root}/opt/octans-ffmpeg/lib/pkgconfig/igdgmm.pc"
  rm -f "${package_root}/opt/octans-ffmpeg/lib/pkgconfig/igfxcmrt.pc"
  rm -rf "${package_root}/opt/octans-ffmpeg/include/igdgmm"
  rm -rf "${package_root}/opt/octans-ffmpeg/include/igfxcmrt"
  rm -rf "${package_root}/etc/OpenCL"

  [[ -x "${package_root}/opt/octans-ffmpeg/bin/ffmpeg" ]] || fail "core package missing ffmpeg"
  [[ -x "${package_root}/opt/octans-ffmpeg/bin/ffprobe" ]] || fail "core package missing ffprobe"
  [[ -x "${package_root}/opt/octans-ffmpeg/bin/octans-ffmpeg-capabilities" ]] || fail "core package missing octans-ffmpeg-capabilities"
  [[ ! -e "${package_root}/opt/octans-ffmpeg/bin/vainfo" ]] || fail "core package must not include vainfo"
  [[ ! -e "${package_root}/opt/octans-ffmpeg/lib/dri/iHD_drv_video.so" ]] || fail "core package must not include Intel iHD driver"
  ! has_glob "${package_root}/opt/octans-ffmpeg/lib/libigdgmm.so*" || fail "core package must not include Intel gmmlib"
  ! has_glob "${package_root}/opt/octans-ffmpeg/lib/libigfxcmrt.so*" || fail "core package must not include Intel Media SDK runtime"
  ! has_glob "${package_root}/opt/octans-ffmpeg/lib/libOpenCL.so*" || fail "core package must not include OpenCL loader"
  [[ ! -e "${package_root}/etc/OpenCL/vendors" ]] || fail "core package must not include OpenCL ICD vendor files"
}

dpkg --validate-version "${version}" >/dev/null

runtime_dir="$(resolve_runtime_dir "${stage_input}")"
ffmpeg_bin="${runtime_dir}/bin/ffmpeg"
ffprobe_bin="${runtime_dir}/bin/ffprobe"
package_work="${build_root}/package/${package_name}_${version}_${arch}"
package_root="${package_work}/root"
deb_path="${output_dir}/${package_name}_${version}_${arch}.deb"

rm -rf "${package_work}"
mkdir -p "${package_root}/opt" "${package_root}/DEBIAN" "${output_dir}"

case "${package_kind}" in
  core)
    copy_core_payload
    ;;
esac

mkdir -p "${package_root}/usr/share/doc/${package_name}"
if [[ -f "${repo_root}/debian/copyright" ]]; then
  cp "${repo_root}/debian/copyright" "${package_root}/usr/share/doc/${package_name}/copyright"
fi

changelog_entry="Package Octans FFmpeg full runtime for Ubuntu 26.04 Resolute amd64."

gzip -n -9 > "${package_root}/usr/share/doc/${package_name}/changelog.Debian.gz" <<EOF
${package_name} (${version}) resolute; urgency=medium

  * ${changelog_entry}

 -- ${maintainer}  $(date -R)
EOF

declare -A bundled_libs=()
if [[ -d "${package_root}/opt/octans-ffmpeg/lib" ]]; then
  while IFS= read -r entry; do
    bundled_libs["$(basename "${entry}")"]=1
  done < <(find "${package_root}/opt/octans-ffmpeg/lib" -maxdepth 1 \( -type f -o -type l \) -name '*.so*' | sort)
fi

declare -A needed_libs=()
while IFS= read -r elf_file; do
  while IFS= read -r lib_name; do
    [[ -n "${lib_name}" ]] || continue
    if [[ -n "${bundled_libs[${lib_name}]:-}" ]]; then
      continue
    fi
    needed_libs["${lib_name}"]=1
  done < <(read_needed "${elf_file}")
done < <(
  find "${package_root}/opt/octans-ffmpeg/bin" "${package_root}/opt/octans-ffmpeg/lib" \
    -type f -print | while IFS= read -r file_path; do
      if is_elf "${file_path}"; then
        printf '%s\n' "${file_path}"
      fi
    done
)

declare -A dependency_packages=()
for lib_name in "${!needed_libs[@]}"; do
  dependency_packages["$(resolve_system_package "${lib_name}")"]=1
done

case "${package_kind}" in
  core)
    dependency_packages["ca-certificates"]=1
    dependency_packages["intel-media-va-driver-non-free"]=1
    dependency_packages["intel-opencl-icd"]=1
    dependency_packages["mesa-vulkan-drivers"]=1
    dependency_packages["ocl-icd-libopencl1"]=1
    dependency_packages["vainfo"]=1
    ;;
esac

mapfile -t depends < <(printf '%s\n' "${!dependency_packages[@]}" | sort)
depends_line="$(join_control_list "${depends[@]}")"
recommends_line="intel-opencl-icd-legacy"
description_summary="Octans FFmpeg full runtime for Ubuntu 26.04"
description_body=" Octans maintained FFmpeg full GPL runtime based on Jellyfin FFmpeg.
 It installs ffmpeg and ffprobe under /opt/octans-ffmpeg and does not
 replace system FFmpeg. VAAPI, Intel OpenCL and Vulkan runtime providers
 are installed from Ubuntu system packages. FFmpeg itself does not
 enable libvpl, nvenc, amf or cuda."
installed_size="$(du -sk "${package_root}" | awk '{print $1}')"

cat > "${package_root}/DEBIAN/control" <<EOF
Package: ${package_name}
Version: ${version}
Section: video
Priority: optional
Architecture: ${arch}
Maintainer: ${maintainer}
Installed-Size: ${installed_size}
Depends: ${depends_line}
Homepage: https://github.com/octans-media/open-octans-ffmpeg
Description: ${description_summary}
${description_body}
EOF

if [[ -n "${recommends_line}" ]]; then
  sed -i "/^Homepage:/i Recommends: ${recommends_line}" "${package_root}/DEBIAN/control"
fi

dpkg-deb --build --root-owner-group "${package_root}" "${deb_path}" >/dev/null
sha256sum "${deb_path}" > "${deb_path}.sha256"

echo "runtime: ${runtime_dir}"
echo "kind: ${package_kind}"
echo "package: ${deb_path}"
echo "sha256: ${deb_path}.sha256"
echo "depends: ${depends_line}"
echo "recommends: ${recommends_line}"
