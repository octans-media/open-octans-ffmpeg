#!/usr/bin/env bash
# Test-machine FFmpeg for tiny-ubuntu. Enables CUDA / NVDEC / NVENC and
# tonemap_cuda. Does not change scripts/build-octans-full-linux.sh or the
# public verify-full-linux.sh gate.
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
cuda_patch="${repo_root}/debian/patches/nvidia-0004-add-cuda-tonemap-impl.patch"
cuda_backport="${repo_root}/debian/patches/nvidia-0083-backport-fixes-for-cuda-from-upstream.patch"

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

# tonemapx already owns the colorspace.h declarations and inserts itself
# between tonemap and tonemap_opencl, so those hunks are applied by hand.
if ! patch -d "${work_dir}" -p1 --forward --batch < "${cuda_patch}"; then
  echo "cuda tonemap patch reported rejects; applying the known fixups" >&2
fi

python3 - "${work_dir}" << 'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1])
makefile = root / "libavfilter/Makefile"
text = makefile.read_text()
anchor = "OBJS-$(CONFIG_TONEMAPX_FILTER)               += vf_tonemapx.o\n"
block = (
    "OBJS-$(CONFIG_TONEMAP_CUDA_FILTER)           += vf_tonemap_cuda.o cuda/tonemap.ptx.o \\\n"
    "                                                cuda/host_util.o cuda/load_helper.o\n"
)
if "CONFIG_TONEMAP_CUDA_FILTER" not in text:
    if anchor not in text:
        raise SystemExit("Makefile is missing the tonemapx anchor")
    makefile.write_text(text.replace(anchor, anchor + block, 1))

allfilters = root / "libavfilter/allfilters.c"
text = allfilters.read_text()
anchor = "extern const FFFilter ff_vf_tonemapx;\n"
line = "extern const FFFilter ff_vf_tonemap_cuda;\n"
if "ff_vf_tonemap_cuda" not in text:
    if anchor not in text:
        raise SystemExit("allfilters.c is missing the tonemapx anchor")
    allfilters.write_text(text.replace(anchor, anchor + line, 1))

if "tonemap_cuda_filter_deps" not in (root / "configure").read_text():
    raise SystemExit("configure did not receive tonemap_cuda dependencies")
if not (root / "libavfilter/vf_tonemap_cuda.c").is_file():
    raise SystemExit("vf_tonemap_cuda.c was not added")

def drop_duplicate_function(text, signature):
    start = text.find(signature)
    if start < 0:
        raise SystemExit(f"missing function: {signature}")
    second = text.find(signature, start + len(signature))
    if second < 0:
        return text
    brace = text.find("{", second)
    depth = 0
    for index in range(brace, len(text)):
        char = text[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                end = index + 1
                if end < len(text) and text[end] == "\n":
                    end += 1
                return text[:second] + text[end:]
    raise SystemExit(f"unclosed function: {signature}")

colorspace = root / "libavfilter/colorspace.c"
text = colorspace.read_text()
for signature in (
    "void ff_matrix_transpose_3x3(const double in[3][3], double out[3][3])",
    "double ff_determine_dovi_signal_peak(const AVDOVIMetadata *data, int l0_only)",
    "void ff_map_dovi_metadata(struct FFDOVIMetadataRemap *out, const AVDOVIMetadata *data)",
    "float ff_eotf_st2084_common(float x)",
    "float ff_eotf_st2084(float x, float ref_white)",
    "float ff_inverse_eotf_st2084_common(float x)",
    "float ff_inverse_eotf_st2084(float x, float ref_white)",
    "float ff_eotf_arib_b67(float x, float ref_white, int bt2446b)",
    "float ff_inverse_eotf_bt1886(float x)",
    "static float inverse_oetf_arib_b67(float x)",
    "static float ootf_arib_b67(float x, float ref_white, int bt2446b)",
):
    text = drop_duplicate_function(text, signature)
colorspace.write_text(text)

runtime = root / "compat/cuda/cuda_runtime.h"
header = runtime.read_text()
if "float3" not in header:
    anchor = """typedef struct __device_builtin__ __align__(8) float2
{
    float x, y;
} float2;
"""
    insertion = anchor + """
typedef struct __device_builtin__ __align__(4) float3
{
    float x, y, z;
} float3;
"""
    if anchor not in header:
        raise SystemExit("cuda_runtime.h is missing the float2 anchor")
    header = header.replace(anchor, insertion, 1)
    if "__constant__" not in header:
        header = header.replace(
            "#define __device__ __attribute__((device))\n",
            "#define __device__ __attribute__((device))\n"
            "#define __constant__ __attribute__((constant))\n",
            1,
        )
    if "ushort3" not in header:
        header = header.replace(
            "} float3;\n",
            """} float3;

typedef struct __device_builtin__ __align__(2) ushort3
{
    unsigned short x, y, z;
} ushort3;

typedef struct __device_builtin__ __align__(4) int3
{
    int x, y, z;
} int3;
""",
            1,
        )
    header = header.replace(
        "#define make_float4(a, b, c, d) ((float4){.x = a, .y = b, .z = c, .w = d})\n",
        "#define make_float4(a, b, c, d) ((float4){.x = a, .y = b, .z = c, .w = d})\n"
        "static inline __device__ float3 make_float3(float a, float b, float c) { float3 v; v.x = a; v.y = b; v.z = c; return v; }\n"
        "static inline __device__ ushort3 make_ushort3(unsigned short a, unsigned short b, unsigned short c) { ushort3 v; v.x = a; v.y = b; v.z = c; return v; }\n"
        "static inline __device__ int3 make_int3(int a, int b, int c) { int3 v; v.x = a; v.y = b; v.z = c; return v; }\n",
        1,
    )
    runtime.write_text(header)

configure = root / "configure"
config_text = configure.read_text()
config_text = config_text.replace(
    'nvccflags_default="--cuda-gpu-arch=sm_30 -O2"',
    'nvccflags_default="--cuda-gpu-arch=sm_89 -O2"',
    1,
)
configure.write_text(config_text)
PY

patch -d "${work_dir}" -p1 --forward --batch < "${cuda_backport}"

find "${work_dir}" -name '*.rej' -delete
find "${work_dir}" -name '*.orig' -delete

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
    runtime_rpath="\$ORIGIN/../lib:\$ORIGIN"
    find /stage/opt/octans-ffmpeg/bin /stage/opt/octans-ffmpeg/lib \
      -type f \( -name ffmpeg -o -name ffprobe -o -name "*.so*" \) \
      -exec patchelf --set-rpath "${runtime_rpath}" {} \;
  '

ln -sfn "${version}" "${build_root}/stage/nvidia-current"

echo "staged: ${stage_dir}/opt/octans-ffmpeg"
echo "current: ${build_root}/stage/nvidia-current/opt/octans-ffmpeg"
