#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ci-retry-helpers.sh
. "${script_dir}/ci-retry-helpers.sh"

gitea_url="${OCTANS_GITEA_URL:?OCTANS_GITEA_URL is required}"
owner="${OCTANS_GITEA_REPOSITORY_OWNER:-octans}"
repo="${OCTANS_GITEA_REPOSITORY_NAME:-open-octans-ffmpeg}"
token="${OCTANS_GITEA_RELEASE_TOKEN:-${OCTANS_GITEA_REGISTRY_TOKEN:-}}"
tag=""
title=""
body_file=""
asset_dir=""
target_commitish="${GITHUB_SHA:-}"
prerelease="false"
recovery="false"

release_id=""
created_release=0
created_tag=0
tag_was_absent=0
tmp_files=()

usage() {
  cat <<EOF
Usage: $(basename "$0") --tag TAG --title TITLE --asset-dir PATH [options]

Creates or resumes an octans-ffmpeg Gitea Release and uploads release assets.

Options:
  --owner NAME          Gitea repository owner. Defaults to OCTANS_GITEA_REPOSITORY_OWNER or octans.
  --repo NAME           Gitea repository name. Defaults to OCTANS_GITEA_REPOSITORY_NAME or octans-ffmpeg.
  --tag TAG             Release tag name.
  --title TITLE         Release title.
  --body-file PATH      Markdown body file. If omitted, a concise body is generated.
  --asset-dir PATH      Directory containing release assets.
  --target REF          Target commitish for release tag. Defaults to GITHUB_SHA.
  --prerelease BOOL     true for RC, false for stable. Defaults to false.
  --recovery BOOL       true to resume an existing release and upload missing assets.
  -h, --help            Show this help.
EOF
}

fail() {
  printf 'fail - %s\n' "$*" >&2
  exit 1
}

remember_tmp() {
  tmp_files+=("$1")
}

cleanup_on_exit() {
  local status=$?
  local response_body
  local http_status

  for file_path in "${tmp_files[@]:-}"; do
    rm -f "${file_path}"
  done

  if [[ "${status}" -eq 0 ]]; then
    exit 0
  fi

  set +e
  if [[ "${created_release}" == "1" && -n "${release_id}" ]]; then
    response_body="$(mktemp)"
    http_status="$(octans_ci_curl_status \
      "204,404" \
      "${response_body}" \
      "cleanup Gitea release ${release_id}" \
      --header "Authorization: token ${token}" \
      --request DELETE \
      "${api_base}/releases/${release_id}")"

    if [[ "${http_status}" == "204" || "${http_status}" == "404" ]]; then
      printf 'cleaned failed Gitea release: id=%s\n' "${release_id}" >&2
    else
      printf 'failed to clean Gitea release after error, status=%s\n' "${http_status}" >&2
      cat "${response_body}" >&2
    fi
    rm -f "${response_body}"
  fi

  if [[ "${created_tag}" == "1" && -n "${tag}" ]]; then
    response_body="$(mktemp)"
    http_status="$(octans_ci_curl_status \
      "204,404" \
      "${response_body}" \
      "cleanup Gitea release tag ${tag}" \
      --header "Authorization: token ${token}" \
      --request DELETE \
      "${api_base}/tags/${tag}")"

    if [[ "${http_status}" == "204" || "${http_status}" == "404" ]]; then
      printf 'cleaned failed Gitea release tag: %s\n' "${tag}" >&2
    else
      printf 'failed to clean Gitea release tag after error, status=%s\n' "${http_status}" >&2
      cat "${response_body}" >&2
    fi
    rm -f "${response_body}"
  fi

  exit "${status}"
}

trap cleanup_on_exit EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --owner)
      owner="$2"
      shift 2
      ;;
    --repo)
      repo="$2"
      shift 2
      ;;
    --tag)
      tag="$2"
      shift 2
      ;;
    --title)
      title="$2"
      shift 2
      ;;
    --body-file)
      body_file="$2"
      shift 2
      ;;
    --asset-dir)
      asset_dir="$2"
      shift 2
      ;;
    --target)
      target_commitish="$2"
      shift 2
      ;;
    --prerelease)
      prerelease="$2"
      shift 2
      ;;
    --recovery)
      recovery="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ -n "${token}" ]] || fail "OCTANS_GITEA_RELEASE_TOKEN or OCTANS_GITEA_REGISTRY_TOKEN is required"
[[ -n "${tag}" ]] || fail "--tag is required"
[[ -n "${title}" ]] || fail "--title is required"
[[ -n "${asset_dir}" ]] || fail "--asset-dir is required"
[[ -d "${asset_dir}" ]] || fail "asset directory does not exist: ${asset_dir}"
[[ -n "${target_commitish}" ]] || fail "--target or GITHUB_SHA is required"

case "${prerelease}" in
  true|false)
    ;;
  *)
    fail "--prerelease must be true or false: ${prerelease}"
    ;;
esac

case "${recovery}" in
  true|false)
    ;;
  *)
    fail "--recovery must be true or false: ${recovery}"
    ;;
esac

command -v curl >/dev/null || fail "curl is required"
command -v jq >/dev/null || fail "jq is required"
command -v sha256sum >/dev/null || fail "sha256sum is required"
command -v stat >/dev/null || fail "stat is required"

mapfile -d '' asset_paths < <(
  find "${asset_dir}" -maxdepth 1 -type f -print0 | sort -z
)
[[ "${#asset_paths[@]}" -gt 0 ]] || fail "asset directory is empty: ${asset_dir}"

api_base="${gitea_url%/}/api/v1/repos/${owner}/${repo}"

request_body="$(mktemp)"
remember_tmp "${request_body}"

get_release_response="$(mktemp)"
remember_tmp "${get_release_response}"
get_release_status="$(octans_ci_curl_status \
  "200,404" \
  "${get_release_response}" \
  "get Gitea release ${tag}" \
  --header "Authorization: token ${token}" \
  "${api_base}/releases/tags/${tag}")"

if [[ "${get_release_status}" == "200" ]]; then
  if [[ "${recovery}" != "true" ]]; then
    fail "release already exists; rerun with --recovery true only for the same version: ${tag}"
  fi

  release_id="$(jq -r '.id // empty' "${get_release_response}")"
  [[ -n "${release_id}" ]] || fail "existing release response does not include id"

  existing_prerelease="$(jq -r '.prerelease // false' "${get_release_response}")"
  if [[ "${existing_prerelease}" != "${prerelease}" ]]; then
    fail "existing release prerelease mismatch: expected ${prerelease}, got ${existing_prerelease}"
  fi

  printf 'reusing existing Gitea release: tag=%s id=%s\n' "${tag}" "${release_id}"
elif [[ "${get_release_status}" == "404" ]]; then
  tag_response="$(mktemp)"
  remember_tmp "${tag_response}"
  tag_status="$(octans_ci_curl_status \
    "200,404" \
    "${tag_response}" \
    "get Gitea tag ${tag}" \
    --header "Authorization: token ${token}" \
    "${api_base}/tags/${tag}")"

  case "${tag_status}" in
    200)
      if [[ "${recovery}" != "true" ]]; then
        fail "tag already exists without a release; clean it or rerun with --recovery true: ${tag}"
      fi
      ;;
    404)
      tag_was_absent=1
      ;;
    *)
      printf 'failed to check release tag, status=%s\n' "${tag_status}" >&2
      cat "${tag_response}" >&2
      exit 1
      ;;
  esac

  if [[ -n "${body_file}" ]]; then
    [[ -f "${body_file}" ]] || fail "body file does not exist: ${body_file}"
    release_body="$(cat "${body_file}")"
  else
    release_body="$(
      printf 'Automated octans-ffmpeg release.\n\n'
      printf -- '- Tag: `%s`\n' "${tag}"
      printf -- '- Target commit: `%s`\n' "${target_commitish}"
      printf -- '- Prerelease: `%s`\n\n' "${prerelease}"
      printf 'See `release-manifest.json` and `sha256sums.txt` for provenance and checksums.\n'
    )"
  fi

  jq -n \
    --arg tag_name "${tag}" \
    --arg target_commitish "${target_commitish}" \
    --arg name "${title}" \
    --arg body "${release_body}" \
    --argjson prerelease "${prerelease}" \
    '{
      tag_name: $tag_name,
      target_commitish: $target_commitish,
      name: $name,
      body: $body,
      draft: false,
      prerelease: $prerelease
    }' > "${request_body}"

  create_response="$(mktemp)"
  remember_tmp "${create_response}"
  create_status="$(octans_ci_curl_status \
    "201" \
    "${create_response}" \
    "create Gitea release ${tag}" \
    --header "Authorization: token ${token}" \
    --header "Content-Type: application/json" \
    --request POST \
    --data @"${request_body}" \
    "${api_base}/releases")"

  if [[ "${create_status}" != "201" ]]; then
    printf 'failed to create Gitea release, status=%s\n' "${create_status}" >&2
    cat "${create_response}" >&2
    exit 1
  fi

  release_id="$(jq -r '.id // empty' "${create_response}")"
  [[ -n "${release_id}" ]] || fail "Gitea release response did not include release id"
  created_release=1
  created_tag="${tag_was_absent}"
  printf 'created Gitea release: tag=%s id=%s prerelease=%s\n' "${tag}" "${release_id}" "${prerelease}"
else
  printf 'failed to query Gitea release, status=%s\n' "${get_release_status}" >&2
  cat "${get_release_response}" >&2
  exit 1
fi

list_response="$(mktemp)"
remember_tmp "${list_response}"

list_assets() {
  local http_status
  http_status="$(octans_ci_curl_status \
    "200" \
    "${list_response}" \
    "list Gitea release assets ${release_id}" \
    --header "Authorization: token ${token}" \
    "${api_base}/releases/${release_id}/assets")"

  if [[ "${http_status}" != "200" ]]; then
    printf 'failed to list Gitea release assets, status=%s\n' "${http_status}" >&2
    cat "${list_response}" >&2
    exit 1
  fi
}

list_assets

for asset_path in "${asset_paths[@]}"; do
  asset_name="$(basename "${asset_path}")"
  existing_asset="$(jq --arg name "${asset_name}" '.[] | select(.name == $name)' "${list_response}")"

  if [[ -n "${existing_asset}" ]]; then
    local_sha="$(sha256sum "${asset_path}" | awk '{print $1}')"
    local_size="$(stat -c '%s' "${asset_path}")"
    existing_size="$(jq -r '.size // empty' <<<"${existing_asset}")"
    download_url="$(jq -r '.browser_download_url // .download_url // empty' <<<"${existing_asset}")"

    if [[ -n "${existing_size}" && "${existing_size}" != "${local_size}" ]]; then
      fail "existing release asset size mismatch: ${asset_name}"
    fi
    [[ -n "${download_url}" ]] || fail "existing release asset has no download url: ${asset_name}"

    downloaded_asset="$(mktemp)"
    remember_tmp "${downloaded_asset}"
    download_status="$(octans_ci_curl_status \
      "200" \
      "${downloaded_asset}" \
      "download existing Gitea release asset ${asset_name}" \
      --header "Authorization: token ${token}" \
      --location \
      "${download_url}")"

    if [[ "${download_status}" != "200" ]]; then
      printf 'failed to download existing release asset, status=%s name=%s\n' \
        "${download_status}" \
        "${asset_name}" >&2
      exit 1
    fi

    existing_sha="$(sha256sum "${downloaded_asset}" | awk '{print $1}')"
    if [[ "${existing_sha}" != "${local_sha}" ]]; then
      fail "existing release asset checksum mismatch: ${asset_name}"
    fi

    printf 'reused existing Gitea release asset: %s\n' "${asset_name}"
    continue
  fi

  encoded_name="$(jq -rn --arg value "${asset_name}" '$value|@uri')"
  upload_response="$(mktemp)"
  remember_tmp "${upload_response}"
  upload_status="$(octans_ci_curl_status \
    "201" \
    "${upload_response}" \
    "upload Gitea release asset ${asset_name}" \
    --header "Authorization: token ${token}" \
    --request POST \
    --form "attachment=@${asset_path}" \
    "${api_base}/releases/${release_id}/assets?name=${encoded_name}")"

  if [[ "${upload_status}" != "201" ]]; then
    printf 'failed to upload Gitea release asset, status=%s name=%s\n' \
      "${upload_status}" \
      "${asset_name}" >&2
    cat "${upload_response}" >&2
    exit 1
  fi

  printf 'uploaded Gitea release asset: %s\n' "${asset_name}"
  list_assets
done

list_assets
for asset_path in "${asset_paths[@]}"; do
  asset_name="$(basename "${asset_path}")"
  if ! jq -e --arg name "${asset_name}" '.[] | select(.name == $name)' "${list_response}" >/dev/null; then
    fail "release asset is missing after upload: ${asset_name}"
  fi
done

printf 'Gitea Release assets published:\n'
printf '  release: %s/%s %s\n' "${owner}" "${repo}" "${tag}"
printf '  release_id: %s\n' "${release_id}"
printf '  prerelease: %s\n' "${prerelease}"
printf '  asset_count: %s\n' "${#asset_paths[@]}"
