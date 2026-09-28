#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ci-retry-helpers.sh
. "${script_dir}/ci-retry-helpers.sh"

gitea_url="${OCTANS_GITEA_URL:?OCTANS_GITEA_URL is required}"
gitea_host="${OCTANS_GITEA_HOST:?OCTANS_GITEA_HOST is required}"
owner="${OCTANS_GITEA_PACKAGE_OWNER:-octans}"
distribution="${OCTANS_GITEA_DEBIAN_DISTRIBUTION:-resolute}"
component="${OCTANS_GITEA_DEBIAN_COMPONENT:-main}"
username="${OCTANS_GITEA_PACKAGE_USERNAME:-}"
token="${OCTANS_GITEA_PACKAGE_TOKEN:-}"
deb_path=""

usage() {
  cat <<EOF
Usage: $(basename "$0") --deb PATH [options]

Publishes one Debian package to Gitea Debian Package Registry.

Options:
  --deb PATH              Debian package to upload.
  --gitea-url URL         Gitea base URL. Defaults to ${gitea_url}
  --gitea-host HOST       Gitea host for netrc. Defaults to ${gitea_host}
  --owner OWNER           Package owner. Defaults to ${owner}
  --distribution NAME     Debian distribution. Defaults to ${distribution}
  --component NAME        Debian component. Defaults to ${component}
  --username USERNAME     Gitea username. Defaults to OCTANS_GITEA_PACKAGE_USERNAME
  --token TOKEN           Gitea token. Defaults to OCTANS_GITEA_PACKAGE_TOKEN
EOF
}

fail() {
  echo "$*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --deb)
      deb_path="$2"
      shift 2
      ;;
    --gitea-url)
      gitea_url="${2%/}"
      shift 2
      ;;
    --gitea-host)
      gitea_host="$2"
      shift 2
      ;;
    --owner)
      owner="$2"
      shift 2
      ;;
    --distribution)
      distribution="$2"
      shift 2
      ;;
    --component)
      component="$2"
      shift 2
      ;;
    --username)
      username="$2"
      shift 2
      ;;
    --token)
      token="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      fail "unknown argument: $1"
      ;;
  esac
done

[[ -n "${deb_path}" ]] || fail "--deb is required"
[[ -f "${deb_path}" ]] || fail "deb not found: ${deb_path}"
[[ -n "${username}" ]] || fail "missing Gitea package username"
[[ -n "${token}" ]] || fail "missing Gitea package token"

package_name="$(dpkg-deb -f "${deb_path}" Package)"
package_version="$(dpkg-deb -f "${deb_path}" Version)"
package_architecture="$(dpkg-deb -f "${deb_path}" Architecture)"
deb_sha256="$(sha256sum "${deb_path}" | awk '{print $1}')"
upload_url="${gitea_url}/api/packages/${owner}/debian/pool/${distribution}/${component}/upload"

netrc_file="$(mktemp)"
trap 'rm -f "${netrc_file}"' EXIT
chmod 600 "${netrc_file}"
printf 'machine %s login %s password %s\n' \
  "${gitea_host}" \
  "${username}" \
  "${token}" \
  > "${netrc_file}"

octans_ci_retry_curl \
  "upload Debian package ${package_name} ${package_version}" \
  --fail-with-body --silent --show-error \
  --netrc-file "${netrc_file}" \
  --upload-file "${deb_path}" \
  "${upload_url}"

printf 'published Debian package:\n'
printf '  package: %s\n' "${package_name}"
printf '  version: %s\n' "${package_version}"
printf '  architecture: %s\n' "${package_architecture}"
printf '  distribution: %s\n' "${distribution}"
printf '  component: %s\n' "${component}"
printf '  sha256: %s\n' "${deb_sha256}"
