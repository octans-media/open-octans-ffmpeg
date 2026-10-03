#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

version="${OCTANS_FFMPEG_VERSION:-octans-ffmpeg-full-linux-8.1.3-1-ubuntu2604-system-runtime}"
image="${OCTANS_FFMPEG_BUILD_IMAGE:-octans-ffmpeg-full-linux-build:resolute}"
build_root="${OCTANS_FFMPEG_BUILD_ROOT:-${repo_root}/.build}"
work_dir="${build_root}/work/${version}"
stage_dir="${build_root}/stage/${version}"
log_dir="${build_root}/logs"
dist_dir="${build_root}/dist"
jobs="${JOBS:-}"

mkdir -p "${build_root}/work" "${build_root}/stage" "${log_dir}" "${dist_dir}"

docker build \
  -f "${repo_root}/docker/octans-full-linux.Dockerfile" \
  -t "${image}" \
  "${repo_root}"

rm -rf "${work_dir}" "${stage_dir}"
mkdir -p "${work_dir}" "${stage_dir}"

rsync -a --delete \
  --exclude .git \
  --exclude builder/ffbuild \
  --exclude builder/.cache \
  --exclude builder/artifacts \
  "${repo_root}/" "${work_dir}/"

dpkg-source --before-build "${work_dir}" | tee "${log_dir}/${version}-patches.log"

run_jobs="${jobs}"
if [[ -z "${run_jobs}" ]]; then
  run_jobs="$(nproc)"
fi

docker run --rm \
  -u "$(id -u):$(id -g)" \
  -e "JOBS=${run_jobs}" \
  -v "${work_dir}:/src" \
  -v "${stage_dir}:/stage" \
  -v "${log_dir}:/logs" \
  "${image}" \
  bash -lc '
    set -euo pipefail
    cd /src
    ./configure \
      --prefix=/opt/octans-ffmpeg \
      --extra-version=OctansFull \
      --disable-doc \
      --disable-ffplay \
      --disable-debug \
      --disable-static \
      --disable-libxcb \
      --disable-sdl2 \
      --disable-xlib \
      --enable-shared \
      --enable-pic \
      --enable-gpl \
      --enable-version3 \
      --enable-gmp \
      --enable-gnutls \
      --enable-libass \
      --enable-libfontconfig \
      --enable-libfreetype \
      --enable-libfribidi \
      --enable-libharfbuzz \
      --enable-libdav1d \
      --enable-libsvtav1 \
      --enable-libaom \
      --enable-librav1e \
      --enable-libvpx \
      --enable-libopus \
      --enable-libvorbis \
      --enable-libwebp \
      --enable-libmp3lame \
      --enable-libtheora \
      --enable-libopenmpt \
      --enable-libbluray \
      --enable-libxml2 \
      --enable-chromaprint \
      --enable-libx264 \
      --enable-libx265 \
      --enable-libzimg \
      --enable-opencl \
      --enable-libplacebo \
      --enable-vulkan \
      --enable-libshaderc \
      --enable-libdrm \
      --enable-vaapi \
      --disable-libvpl \
      --disable-ffnvcodec \
      --disable-cuda \
      --disable-cuda-llvm \
      --disable-cuvid \
      --disable-nvdec \
      --disable-nvenc \
      --disable-amf \
      2>&1 | tee /logs/'"${version}"'-configure.log
    make -j"${JOBS}" V=1 2>&1 | tee /logs/'"${version}"'-build.log
    make DESTDIR=/stage install 2>&1 | tee /logs/'"${version}"'-install.log
    gcc -std=c11 -O2 -Wall -Wextra \
      -I/stage/opt/octans-ffmpeg/include \
      /src/tools/octans_ffmpeg_capabilities.c \
      -L/stage/opt/octans-ffmpeg/lib \
      -Wl,-rpath,"\$ORIGIN/../lib:\$ORIGIN" \
      -o /stage/opt/octans-ffmpeg/bin/octans-ffmpeg-capabilities \
      -lavutil -lva \
      2>&1 | tee /logs/'"${version}"'-capabilities-helper.log
    runtime_rpath="\$ORIGIN/../lib:\$ORIGIN"
    find /stage/opt/octans-ffmpeg/bin /stage/opt/octans-ffmpeg/lib \
      -type f \( -name ffmpeg -o -name ffprobe -o -name octans-ffmpeg-capabilities -o -name "*.so*" \) \
      -exec patchelf --set-rpath "${runtime_rpath}" {} \;
  '

ln -sfn "${version}" "${build_root}/stage/current"

tar -C "${stage_dir}" --zstd -cf "${dist_dir}/${version}.tar.zst" opt
sha256sum "${dist_dir}/${version}.tar.zst" > "${dist_dir}/${version}.tar.zst.sha256"

echo "staged: ${stage_dir}/opt/octans-ffmpeg"
echo "current: ${build_root}/stage/current/opt/octans-ffmpeg"
echo "dist: ${dist_dir}/${version}.tar.zst"
