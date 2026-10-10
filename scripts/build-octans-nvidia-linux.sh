#!/usr/bin/env bash
# Test-machine FFmpeg for tiny-ubuntu. Uses the same CUDA patches and
# configure flags as scripts/build-octans-full-linux.sh. --extra-version
# stays OctansNvidia so this local tree is distinct from the published
# OctansFull package. The staged symlink is stage/nvidia-current.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

version="${OCTANS_FFMPEG_VERSION:-octans-ffmpeg-nvidia-linux-8.1.3-1-ubuntu2604}"
image="${OCTANS_FFMPEG_BUILD_IMAGE:-octans-ffmpeg-nvidia-linux-build:resolute}"
build_root="${OCTANS_FFMPEG_BUILD_ROOT:-${repo_root}/.build}"
work_dir="${build_root}/work/${version}"
stage_dir="${build_root}/stage/${version}"
log_dir="${build_root}/logs"
dist_dir="${build_root}/dist"
jobs="${JOBS:-}"

mkdir -p "${build_root}/work" "${build_root}/stage" "${log_dir}" "${dist_dir}"

docker build \
  -f "${repo_root}/docker/octans-nvidia-linux.Dockerfile" \
  -t "${image}" \
  "${repo_root}"

rm -rf "${work_dir}" "${stage_dir}"
mkdir -p "${work_dir}" "${stage_dir}"

rsync -a --delete \
  --exclude .git \
  --exclude builder/ffbuild \
  --exclude builder/.cache \
  --exclude builder/artifacts \
  --exclude .build \
  "${repo_root}/" "${work_dir}/"

dpkg-source --before-build "${work_dir}" | tee "${log_dir}/${version}-patches.log"

"${repo_root}/scripts/apply-nvidia-cuda-patches.sh" "${work_dir}" \
  2>&1 | tee -a "${log_dir}/${version}-patches.log"

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
      --extra-version=OctansNvidia \
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
      --enable-ffnvcodec \
      --enable-cuda \
      --enable-cuda-llvm \
      --enable-cuvid \
      --enable-nvdec \
      --enable-nvenc \
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

ln -sfn "${version}" "${build_root}/stage/nvidia-current"

echo "staged: ${stage_dir}/opt/octans-ffmpeg"
echo "current: ${build_root}/stage/nvidia-current/opt/octans-ffmpeg"
