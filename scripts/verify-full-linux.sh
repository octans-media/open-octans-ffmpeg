#!/usr/bin/env bash
set -euo pipefail

input_path="${1:-${OCTANS_FFMPEG_RUNTIME:-/opt/octans-ffmpeg}}"

fail() {
  echo "fail - $*" >&2
  exit 1
}

pass() {
  echo "ok - $*"
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
  echo "expected bin/ffmpeg or opt/octans-ffmpeg/bin/ffmpeg under the path" >&2
  exit 2
}

require_text() {
  local haystack="$1"
  local needle="$2"
  local label="$3"

  grep -Fq -- "${needle}" <<<"${haystack}" || fail "${label}: missing ${needle}"
  pass "${label}: ${needle}"
}

reject_text() {
  local haystack="$1"
  local needle="$2"
  local label="$3"

  if grep -Fq -- "${needle}" <<<"${haystack}"; then
    fail "${label}: forbidden ${needle}"
  fi
  pass "${label}: no ${needle}"
}

require_entry() {
  local haystack="$1"
  local entry="$2"
  local label="$3"

  grep -Eq "(^|[[:space:]])${entry}([[:space:]]|$)" <<<"${haystack}" || fail "${label}: missing ${entry}"
  pass "${label}: ${entry}"
}

runtime_dir="$(resolve_runtime_dir "${input_path}")"
ffmpeg_bin="${runtime_dir}/bin/ffmpeg"
ffprobe_bin="${runtime_dir}/bin/ffprobe"
helper_bin="${runtime_dir}/bin/octans-ffmpeg-capabilities"

run_ffmpeg() {
  env -u LD_LIBRARY_PATH "${ffmpeg_bin}" "$@"
}

run_ffprobe() {
  env -u LD_LIBRARY_PATH "${ffprobe_bin}" "$@"
}

echo "runtime: ${runtime_dir}"

[[ -x "${helper_bin}" ]] || fail "capability helper missing: ${helper_bin}"

version_output="$(run_ffmpeg -hide_banner -version)"
require_text "${version_output}" "8.1.2-OctansFull" "ffmpeg version"

ffprobe_output="$(run_ffprobe -hide_banner -version)"
require_text "${ffprobe_output}" "8.1.2-OctansFull" "ffprobe version"

license_output="$(run_ffmpeg -hide_banner -L)"
require_text "${license_output}" "GNU General Public License" "license"

buildconf_output="$(run_ffmpeg -hide_banner -buildconf)"
for flag in \
  "--enable-gpl" \
  "--enable-libx264" \
  "--enable-libx265" \
  "--enable-libsvtav1" \
  "--enable-libplacebo" \
  "--enable-vaapi" \
  "--enable-opencl"; do
  require_text "${buildconf_output}" "${flag}" "buildconf"
done

for flag in \
  "--enable-nonfree" \
  "--enable-libfdk-aac" \
  "--enable-openssl" \
  "--enable-libvpl" \
  "--enable-nvenc" \
  "--enable-amf" \
  "--enable-cuda" \
  "--enable-cuvid" \
  "--enable-nvdec" \
  "--enable-ffnvcodec"; do
  reject_text "${buildconf_output}" "${flag}" "buildconf"
done

ldd_ffmpeg="$(env -u LD_LIBRARY_PATH ldd "${ffmpeg_bin}")"
reject_text "${ldd_ffmpeg}" "not found" "ffmpeg ldd"

ldd_ffprobe="$(env -u LD_LIBRARY_PATH ldd "${ffprobe_bin}")"
reject_text "${ldd_ffprobe}" "not found" "ffprobe ldd"

ldd_helper="$(env -u LD_LIBRARY_PATH ldd "${helper_bin}")"
reject_text "${ldd_helper}" "not found" "capability helper ldd"

helper_output="$(
  env -u LD_LIBRARY_PATH "${helper_bin}" \
    --format json \
    --ffmpeg "${ffmpeg_bin}" \
    --ffprobe "${ffprobe_bin}"
)"
require_text "${helper_output}" '"schemaVersion":1' "capability helper json"
require_text "${helper_output}" '"tool":"octans-ffmpeg-capabilities"' "capability helper json"
require_text "${helper_output}" '"ffmpegVersion":{"ok":true' "capability helper json"
require_text "${helper_output}" '"ffprobeVersion":{"ok":true' "capability helper json"
require_text "${helper_output}" '"hardwareDevices":{"vaapi":{"device":null,"available":false' "capability helper json"

encoder_output="$(run_ffmpeg -hide_banner -encoders)"
for encoder in \
  "libx264" \
  "libx265" \
  "libsvtav1" \
  "libvpx-vp9" \
  "libmp3lame" \
  "webvtt" \
  "aac"; do
  require_entry "${encoder_output}" "${encoder}" "encoder"
done

muxer_output="$(run_ffmpeg -hide_banner -muxers)"
for muxer in \
  "matroska" \
  "mpegts" \
  "hls" \
  "webvtt"; do
  require_entry "${muxer_output}" "${muxer}" "muxer"
done

filter_output="$(run_ffmpeg -hide_banner -filters)"
for filter in \
  "tonemapx" \
  "tonemap_opencl" \
  "tonemap_vaapi" \
  "scale_vaapi" \
  "libplacebo" \
  "zscale" \
  "pan" \
  "loudnorm"; do
  require_entry "${filter_output}" "${filter}" "filter"
done

hls_help="$(run_ffmpeg -hide_banner -h muxer=hls)"
for option in \
  "-hls_time" \
  "-hls_segment_type" \
  "-hls_flags"; do
  require_text "${hls_help}" "${option}" "hls muxer"
done

segment_help="$(run_ffmpeg -hide_banner -h muxer=segment)"
for option in \
  "-segment_write_temp" \
  "-segment_limit" \
  "-min_frame_time" \
  "-skip_first_segment"; do
  reject_text "${segment_help}" "${option}" "segment muxer"
done

pause_help="$(
  {
    printf '?'
    sleep 0.2
    printf 'q'
  } | run_ffmpeg -hide_banner -y -stats_period 0.1 \
    -re -f lavfi -i testsrc2=duration=4:size=16x16:rate=1 \
    -an -f null - 2>&1
)"
require_text "${pause_help}" "p      pause transcoding" "runtime pause"
require_text "${pause_help}" "u      unpause transcoding" "runtime pause"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

printf '1\n00:00:00,000 --> 00:00:00,400\nhello srt\n' > "${tmp_dir}/in.srt"
run_ffmpeg -hide_banner -y -loglevel warning \
  -f srt -i "${tmp_dir}/in.srt" \
  -map 0:s:0 \
  -c:s webvtt \
  -f webvtt "${tmp_dir}/out.vtt"
grep -q '^WEBVTT' "${tmp_dir}/out.vtt" || fail "subtitle extract: missing WEBVTT header"
grep -q 'hello srt' "${tmp_dir}/out.vtt" || fail "subtitle extract: missing cue"
pass "subtitle extract to webvtt"

tonemapx_help="$(run_ffmpeg -hide_banner -h filter=tonemapx)"
require_text "${tonemapx_help}" "apply_dovi" "tonemapx"
run_ffmpeg -hide_banner -y -loglevel warning \
  -f lavfi -i testsrc2=duration=0.4:size=64x64:rate=5 \
  -vf 'format=yuv420p10le,tonemapx=tonemap=bt2390:transfer=bt709:matrix=bt709:primaries=bt709:format=yuv420p' \
  -frames:v 1 \
  -f null -
pass "tonemapx software frame"

hls_dir="${tmp_dir}/hls-fmp4"
mkdir -p "${hls_dir}"
run_ffmpeg -hide_banner -y -loglevel warning \
  -f lavfi -i testsrc2=duration=4:size=128x72:rate=12 \
  -f lavfi -i sine=frequency=1000:duration=4 \
  -map 0:v:0 -map 1:a:0 \
  -c:v libx264 \
  -preset ultrafast \
  -pix_fmt yuv420p \
  -c:a aac \
  -f hls \
  -hls_time 2 \
  -hls_segment_type fmp4 \
  -hls_flags independent_segments+temp_file \
  -hls_segment_filename "${hls_dir}/seg%d.m4s" \
  "${hls_dir}/index.m3u8"
[[ -s "${hls_dir}/index.m3u8" ]] || fail "hls fmp4: missing playlist"
[[ -s "${hls_dir}/init.mp4" || -s "${hls_dir}/seg0.m4s" ]] || fail "hls fmp4: missing segment"
if find "${hls_dir}" -maxdepth 1 -name '*.tmp' -type f | grep -q .; then
  fail "hls fmp4: temp files were not renamed"
fi
pass "hls fmp4"

echo "verified: ${ffmpeg_bin}"
