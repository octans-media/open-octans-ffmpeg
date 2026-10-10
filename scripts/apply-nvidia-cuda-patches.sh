#!/usr/bin/env bash
# Apply NVIDIA CUDA patches after dpkg-source --before-build.
# tonemapx already owns colorspace.h and the filter insertion point, so
# nvidia-0004 and nvidia-0083 stay out of debian/patches/series.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 WORK_DIR" >&2
  exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work_dir="$(cd "$1" && pwd)"
cuda_patch="${repo_root}/debian/patches/nvidia-0004-add-cuda-tonemap-impl.patch"
cuda_backport="${repo_root}/debian/patches/nvidia-0083-backport-fixes-for-cuda-from-upstream.patch"

[[ -f "${cuda_patch}" ]] || {
  echo "missing ${cuda_patch}" >&2
  exit 1
}
[[ -f "${cuda_backport}" ]] || {
  echo "missing ${cuda_backport}" >&2
  exit 1
}
command -v patch >/dev/null
command -v python3 >/dev/null

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
