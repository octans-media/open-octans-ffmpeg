#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
input_path="${1:-${OCTANS_FFMPEG_RUNTIME:-/opt/octans-ffmpeg}}"
build_root="${OCTANS_FFMPEG_BUILD_ROOT:-${repo_root}/.build}"
report_root="${OCTANS_FFMPEG_REPORT_ROOT:-${build_root}/reports}"
timestamp="$(date +%Y%m%d%H%M%S)"
report_dir="${OCTANS_FFMPEG_UPGRADE_REPORT_DIR:-${report_root}/upgrade-matrix-${timestamp}}"

fail() {
  echo "fail - $*" >&2
  exit 1
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

runtime_dir="$(resolve_runtime_dir "${input_path}")"
ffmpeg_bin="${runtime_dir}/bin/ffmpeg"
ffprobe_bin="${runtime_dir}/bin/ffprobe"

run_ffmpeg() {
  env -u LD_LIBRARY_PATH "${ffmpeg_bin}" "$@"
}

run_ffprobe() {
  env -u LD_LIBRARY_PATH "${ffprobe_bin}" "$@"
}

mkdir -p "${report_dir}/logs" "${report_dir}/work"
summary_file="${report_dir}/summary.md"
manual_file="${report_dir}/manual-samples.md"

cat > "${summary_file}" <<EOF
# Octans FFmpeg Upgrade Matrix Report

- generated: $(date --iso-8601=seconds)
- runtime: ${runtime_dir}
- ffmpeg: ${ffmpeg_bin}
- ffprobe: ${ffprobe_bin}

## Cases

EOF

cat > "${manual_file}" <<EOF
# Manual Media Samples

真实媒体样本不进入仓库。本报告只记录本机路径、mediaFileId、用途和人工结论。

| Sample | Path | MediaFileId | Purpose | Verdict |
| --- | --- | --- | --- | --- |
| DV P5 | ${OCTANS_FFMPEG_DV_P5_SAMPLE:-not-provided} | ${OCTANS_FFMPEG_DV_P5_MEDIA_FILE_ID:-not-provided} | pure Dolby Vision Profile 5 software tone mapping | ${OCTANS_FFMPEG_DV_P5_VERDICT:-manual-required} |
| HDR10 | ${OCTANS_FFMPEG_HDR10_SAMPLE:-not-provided} | ${OCTANS_FFMPEG_HDR10_MEDIA_FILE_ID:-not-provided} | HDR10 software tone mapping | ${OCTANS_FFMPEG_HDR10_VERDICT:-manual-required} |

EOF

require_text() {
  local haystack="$1"
  local needle="$2"
  local label="$3"

  grep -Fq -- "${needle}" <<<"${haystack}" || fail "${label}: missing ${needle}"
}

require_file() {
  local path="$1"
  local label="$2"

  [[ -s "${path}" ]] || fail "${label}: missing or empty ${path}"
}

require_no_tmp_files() {
  local path="$1"
  local label="$2"

  if find "${path}" -maxdepth 1 -name '*.tmp' -type f | grep -q .; then
    fail "${label}: temp files were not renamed"
  fi
}

run_case() {
  local name="$1"
  local fn="$2"
  local safe_name
  safe_name="$(tr -cs '[:alnum:]' '-' <<<"${name}" | sed -E 's/^-+|-+$//g' | tr '[:upper:]' '[:lower:]')"
  local log_path="${report_dir}/logs/${safe_name}.log"

  printf '== %s ==\n' "${name}"
  if "${fn}" > "${log_path}" 2>&1; then
    printf -- '- [x] %s\n' "${name}" >> "${summary_file}"
    printf 'ok - %s\n' "${name}"
    return
  fi

  printf -- '- [ ] %s\n' "${name}" >> "${summary_file}"
  printf 'fail - %s; see %s\n' "${name}" "${log_path}" >&2
  sed -n '1,160p' "${log_path}" >&2 || true
  exit 1
}

case_capabilities() {
  local version_output
  version_output="$(run_ffmpeg -hide_banner -version)"
  require_text "${version_output}" "OctansFull" "ffmpeg version"

  local encoder_output
  encoder_output="$(run_ffmpeg -hide_banner -encoders)"
  for encoder in libx265 libmp3lame webvtt aac; do
    require_text "${encoder_output}" "${encoder}" "encoder"
  done

  local muxer_output
  muxer_output="$(run_ffmpeg -hide_banner -muxers)"
  for muxer in matroska mpegts hls webvtt; do
    require_text "${muxer_output}" "${muxer}" "muxer"
  done

  local filter_output
  filter_output="$(run_ffmpeg -hide_banner -filters)"
  for filter in tonemapx tonemap_opencl tonemap_vaapi scale_vaapi libplacebo zscale pan loudnorm; do
    require_text "${filter_output}" "${filter}" "filter"
  done
}

case_single_webvtt_output() {
  local dir="${report_dir}/work/single-webvtt"
  mkdir -p "${dir}"

  printf '1\n00:00:00,000 --> 00:00:00,500\nsingle webvtt\n' > "${dir}/in.srt"
  run_ffmpeg -hide_banner -y -loglevel warning \
    -f srt -i "${dir}/in.srt" \
    -map 0:s:0 \
    -c:s webvtt \
    -f webvtt "${dir}/out.vtt"

  require_file "${dir}/out.vtt" "single webvtt"
  grep -q '^WEBVTT' "${dir}/out.vtt" || fail "single webvtt: missing WEBVTT header"
  grep -q 'single webvtt' "${dir}/out.vtt" || fail "single webvtt: missing cue"
}

case_hls_fmp4() {
  local dir="${report_dir}/work/hls-fmp4"
  mkdir -p "${dir}"

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
    -hls_segment_filename "${dir}/seg%d.m4s" \
    "${dir}/index.m3u8"

  require_file "${dir}/index.m3u8" "hls fmp4 playlist"
  require_no_tmp_files "${dir}" "hls fmp4"
}

make_hevc_sample() {
  local path="$1"
  local audio_codec="$2"

  run_ffmpeg -hide_banner -y -loglevel warning \
    -f lavfi -i testsrc2=duration=6:size=128x72:rate=12 \
    -f lavfi -i sine=frequency=1000:duration=6 \
    -map 0:v:0 -map 1:a:0 \
    -c:v libx265 \
    -preset ultrafast \
    -x265-params log-level=error \
    -pix_fmt yuv420p \
    -c:a "${audio_codec}" \
    "${path}"
}

case_hevc_copy_aac_copy() {
  local dir="${report_dir}/work/hevc-copy-aac-copy"
  mkdir -p "${dir}"

  make_hevc_sample "${dir}/input.mkv" "aac"
  run_ffmpeg -hide_banner -y -loglevel warning \
    -copyts \
    -start_at_zero \
    -i "${dir}/input.mkv" \
    -map 0:v:0 -map 0:a:0 \
    -c:v copy \
    -bsf:v:0 hevc_mp4toannexb \
    -c:a copy \
    -f hls \
    -hls_time 3 \
    -hls_segment_type mpegts \
    -hls_flags independent_segments+temp_file \
    -hls_segment_filename "${dir}/main_%03d.ts" \
    "${dir}/main.m3u8"

  require_file "${dir}/main.m3u8" "hevc aac copy playlist"
  require_file "${dir}/main_000.ts" "hevc aac copy segment"
  run_ffprobe -hide_banner -loglevel error -select_streams a \
    -show_entries stream=codec_name \
    -of default=nk=1:nw=1 "${dir}/main_000.ts" \
    | grep -q '^aac$' || fail "hevc aac copy: output audio is not AAC"
  require_no_tmp_files "${dir}" "hevc aac copy"
}

case_hevc_copy_audio_to_aac() {
  local dir="${report_dir}/work/hevc-copy-audio-to-aac"
  mkdir -p "${dir}"

  make_hevc_sample "${dir}/input.mkv" "ac3"
  run_ffmpeg -hide_banner -y -loglevel warning \
    -copyts \
    -start_at_zero \
    -i "${dir}/input.mkv" \
    -map 0:v:0 -map 0:a:0 \
    -c:v copy \
    -bsf:v:0 hevc_mp4toannexb \
    -c:a aac \
    -ac:a:0 2 \
    -b:a:0 128k \
    -f hls \
    -hls_time 3 \
    -hls_segment_type mpegts \
    -hls_flags independent_segments+temp_file \
    -hls_segment_filename "${dir}/main_%03d.ts" \
    "${dir}/main.m3u8"

  require_file "${dir}/main.m3u8" "hevc audio transcode playlist"
  require_file "${dir}/main_000.ts" "hevc audio transcode segment"
  run_ffprobe -hide_banner -loglevel error -select_streams a \
    -show_entries stream=codec_name \
    -of default=nk=1:nw=1 "${dir}/main_000.ts" \
    | grep -q '^aac$' || fail "hevc audio transcode: output audio is not AAC"
  require_no_tmp_files "${dir}" "hevc audio transcode"
}

case_runtime_pause_help() {
  local pause_help
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
}

case_software_tonemap() {
  local dir="${report_dir}/work/software-tonemap"
  mkdir -p "${dir}"

  local tonemap_help
  tonemap_help="$(run_ffmpeg -hide_banner -h filter=tonemapx)"
  require_text "${tonemap_help}" "apply_dovi" "tonemapx"

  run_ffmpeg -hide_banner -y -loglevel warning \
    -f lavfi -i testsrc2=duration=1:size=64x64:rate=1 \
    -vf 'format=yuv420p10le,tonemapx=tonemap=bt2390:transfer=bt709:matrix=bt709:primaries=bt709:format=yuv420p' \
    -frames:v 1 \
    -f null -

  if [[ -n "${OCTANS_FFMPEG_DV_P5_SAMPLE:-}" && -f "${OCTANS_FFMPEG_DV_P5_SAMPLE}" ]]; then
    run_ffmpeg -hide_banner -y -loglevel warning \
      -i "${OCTANS_FFMPEG_DV_P5_SAMPLE}" \
      -map 0:v:0 \
      -t 2 \
      -vf 'tonemapx=tonemap=bt2390:transfer=bt709:matrix=bt709:primaries=bt709:format=yuv420p' \
      -c:v libx264 \
      -an \
      "${dir}/dv-p5-tonemap.mp4"
    require_file "${dir}/dv-p5-tonemap.mp4" "DV P5 tonemap"
  fi

  if [[ -n "${OCTANS_FFMPEG_HDR10_SAMPLE:-}" && -f "${OCTANS_FFMPEG_HDR10_SAMPLE}" ]]; then
    run_ffmpeg -hide_banner -y -loglevel warning \
      -i "${OCTANS_FFMPEG_HDR10_SAMPLE}" \
      -map 0:v:0 \
      -t 2 \
      -vf 'tonemapx=tonemap=bt2390:transfer=bt709:matrix=bt709:primaries=bt709:format=yuv420p' \
      -c:v libx264 \
      -an \
      "${dir}/hdr10-tonemap.mp4"
    require_file "${dir}/hdr10-tonemap.mp4" "HDR10 tonemap"
  fi
}

run_case "capability surface" case_capabilities
run_case "single WebVTT output" case_single_webvtt_output
run_case "HLS fMP4" case_hls_fmp4
run_case "HEVC copy plus AAC copy" case_hevc_copy_aac_copy
run_case "HEVC copy plus non-AAC audio to AAC" case_hevc_copy_audio_to_aac
run_case "runtime pause help" case_runtime_pause_help
run_case "software tone mapping surface" case_software_tonemap

cat >> "${summary_file}" <<EOF

## Manual Samples

See \`manual-samples.md\` in this report directory for DV P5 / HDR10 real media notes.

EOF

echo "report: ${report_dir}"
