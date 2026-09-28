#!/usr/bin/env bash
set -euo pipefail

prefix="${OCTANS_FFMPEG_VA_PREFIX:-/opt/octans-ffmpeg}"
build_root="${OCTANS_FFMPEG_VA_BUILD_ROOT:-/tmp/octans-va-runtime}"
jobs="${JOBS:-}"

libva_version="${OCTANS_FFMPEG_LIBVA_VERSION:-2.23.0}"
libva_utils_version="${OCTANS_FFMPEG_LIBVA_UTILS_VERSION:-2.23.0}"
gmmlib_version="${OCTANS_FFMPEG_GMMLIB_VERSION:-22.10.0}"
media_driver_version="${OCTANS_FFMPEG_MEDIA_DRIVER_VERSION:-26.1.5}"

if [[ -z "${jobs}" ]]; then
  jobs="$(nproc)"
fi

clone_tag() {
  local repo="$1"
  local tag="$2"
  local target="$3"

  rm -rf "${target}"
  git clone --depth=1 --branch "${tag}" "${repo}" "${target}"
}

maybe_add_configure_flag() {
  local help_output="$1"
  local flag="$2"

  if grep -Fq -- "${flag}" <<<"${help_output}"; then
    printf '%s\n' "${flag}"
  fi
}

build_autotools_project() {
  local source_dir="$1"
  shift

  pushd "${source_dir}" >/dev/null
  ./autogen.sh
  ./configure "$@"
  make -j"${jobs}"
  make install
  popd >/dev/null
}

export PKG_CONFIG_PATH="${prefix}/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export LD_LIBRARY_PATH="${prefix}/lib:${LD_LIBRARY_PATH:-}"
export CFLAGS="-I${prefix}/include ${CFLAGS:-}"
export CXXFLAGS="-I${prefix}/include ${CXXFLAGS:-}"
export LDFLAGS="-L${prefix}/lib -Wl,-rpath,${prefix}/lib ${LDFLAGS:-}"

rm -rf "${build_root}"
mkdir -p "${build_root}" "${prefix}"

echo "building VA runtime into ${prefix}"
echo "libva=${libva_version}"
echo "libva-utils=${libva_utils_version}"
echo "gmmlib=${gmmlib_version}"
echo "media-driver=${media_driver_version}"

clone_tag https://github.com/intel/libva.git "${libva_version}" "${build_root}/libva"
pushd "${build_root}/libva" >/dev/null
./autogen.sh
mapfile -t libva_optional_flags < <(
  configure_help="$(./configure --help)"
  maybe_add_configure_flag "${configure_help}" "--disable-x11"
  maybe_add_configure_flag "${configure_help}" "--disable-wayland"
  maybe_add_configure_flag "${configure_help}" "--disable-glx"
  maybe_add_configure_flag "${configure_help}" "--disable-docs"
)
./configure \
  --prefix="${prefix}" \
  --libdir="${prefix}/lib" \
  --enable-drm \
  "${libva_optional_flags[@]}"
make -j"${jobs}"
make install
popd >/dev/null

clone_tag https://github.com/intel/gmmlib.git "intel-gmmlib-${gmmlib_version}" "${build_root}/gmmlib"
cmake -S "${build_root}/gmmlib" -B "${build_root}/gmmlib/build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="${prefix}" \
  -DCMAKE_INSTALL_LIBDIR=lib
cmake --build "${build_root}/gmmlib/build" --parallel "${jobs}"
cmake --install "${build_root}/gmmlib/build"

clone_tag https://github.com/intel/media-driver.git "intel-media-${media_driver_version}" "${build_root}/media-driver"
cmake -S "${build_root}/media-driver" -B "${build_root}/media-driver/build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="${prefix}" \
  -DCMAKE_INSTALL_LIBDIR=lib \
  -DCMAKE_PREFIX_PATH="${prefix}" \
  -DENABLE_KERNELS=ON \
  -DENABLE_NONFREE_KERNELS=ON \
  -DLIBVA_DRIVERS_PATH="${prefix}/lib/dri"
cmake --build "${build_root}/media-driver/build" --parallel "${jobs}"
cmake --install "${build_root}/media-driver/build"

clone_tag https://github.com/intel/libva-utils.git "${libva_utils_version}" "${build_root}/libva-utils"
pushd "${build_root}/libva-utils" >/dev/null
./autogen.sh
mapfile -t libva_utils_optional_flags < <(
  configure_help="$(./configure --help)"
  maybe_add_configure_flag "${configure_help}" "--disable-x11"
  maybe_add_configure_flag "${configure_help}" "--disable-wayland"
)
./configure \
  --prefix="${prefix}" \
  --libdir="${prefix}/lib" \
  "${libva_utils_optional_flags[@]}"
make -j"${jobs}"
make install
popd >/dev/null

test -x "${prefix}/bin/vainfo"
test -f "${prefix}/lib/libva.so" -o -L "${prefix}/lib/libva.so"
test -f "${prefix}/lib/dri/iHD_drv_video.so" -o -L "${prefix}/lib/dri/iHD_drv_video.so"

echo "VA runtime built: ${prefix}"
