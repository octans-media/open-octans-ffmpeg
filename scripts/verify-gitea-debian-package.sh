#!/usr/bin/env bash
set -euo pipefail

gitea_url="${OCTANS_GITEA_URL:?OCTANS_GITEA_URL is required}"
gitea_host="${OCTANS_GITEA_HOST:?OCTANS_GITEA_HOST is required}"
owner="${OCTANS_GITEA_PACKAGE_OWNER:-octans}"
distribution="${OCTANS_GITEA_DEBIAN_DISTRIBUTION:-resolute}"
component="${OCTANS_GITEA_DEBIAN_COMPONENT:-main}"
username="${OCTANS_GITEA_PACKAGE_USERNAME:-}"
token="${OCTANS_GITEA_PACKAGE_TOKEN:-}"
package_name=""
package_version=""
install_package="false"
max_attempts="5"
architecture="amd64"

usage() {
  cat <<EOF
Usage: $(basename "$0") --package-name NAME --version VERSION [options]

Verifies a package version from Gitea Debian Package Registry.

Options:
  --package-name NAME     Debian package name.
  --version VERSION       Debian package version.
  --install               Install exact package version after index lookup.
  --architecture ARCH     Debian package architecture. Defaults to ${architecture}
  --gitea-url URL         Gitea base URL. Defaults to ${gitea_url}
  --gitea-host HOST       Gitea host for apt auth. Defaults to ${gitea_host}
  --owner OWNER           Package owner. Defaults to ${owner}
  --distribution NAME     Debian distribution. Defaults to ${distribution}
  --component NAME        Debian component. Defaults to ${component}
  --username USERNAME     Gitea username. Defaults to OCTANS_GITEA_PACKAGE_USERNAME
  --token TOKEN           Gitea token. Defaults to OCTANS_GITEA_PACKAGE_TOKEN
  --max-attempts COUNT    apt index refresh attempts. Defaults to ${max_attempts}
EOF
}

fail() {
  echo "$*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --package-name)
      package_name="$2"
      shift 2
      ;;
    --version)
      package_version="$2"
      shift 2
      ;;
    --install)
      install_package="true"
      shift
      ;;
    --architecture)
      architecture="$2"
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
    --max-attempts)
      max_attempts="$2"
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

[[ -n "${package_name}" ]] || fail "--package-name is required"
[[ -n "${package_version}" ]] || fail "--version is required"
[[ -n "${username}" ]] || fail "missing Gitea package username"
[[ -n "${token}" ]] || fail "missing Gitea package token"
[[ "${max_attempts}" =~ ^[1-9][0-9]*$ ]] || fail "invalid --max-attempts"

base_url="${gitea_url}/api/packages/${owner}/debian"
key_url="${base_url}/repository.key"

export PKG_USER="${username}"
export PKG_TOKEN="${token}"
export PKG_HOST="${gitea_host}"
export PKG_NAME="${package_name}"
export PKG_VERSION="${package_version}"
export PKG_BASE_URL="${base_url}"
export PKG_KEY_URL="${key_url}"
export PKG_DISTRIBUTION="${distribution}"
export PKG_COMPONENT="${component}"
export PKG_INSTALL="${install_package}"
export PKG_MAX_ATTEMPTS="${max_attempts}"
export PKG_ARCHITECTURE="${architecture}"

docker run --rm -i \
  -e PKG_USER \
  -e PKG_TOKEN \
  -e PKG_HOST \
  -e PKG_NAME \
  -e PKG_VERSION \
  -e PKG_BASE_URL \
  -e PKG_KEY_URL \
  -e PKG_DISTRIBUTION \
  -e PKG_COMPONENT \
  -e PKG_INSTALL \
  -e PKG_MAX_ATTEMPTS \
  -e PKG_ARCHITECTURE \
  ubuntu:26.04 \
  bash -s <<'EOF'
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends ca-certificates curl

mkdir -p /etc/apt/keyrings /etc/apt/auth.conf.d

cat > /tmp/gitea.netrc <<AUTH
machine ${PKG_HOST}
login ${PKG_USER}
password ${PKG_TOKEN}
AUTH
chmod 600 /tmp/gitea.netrc

curl --fail --silent --show-error \
  --retry 5 --retry-delay 2 --retry-all-errors \
  --netrc-file /tmp/gitea.netrc \
  "${PKG_KEY_URL}" \
  -o /etc/apt/keyrings/gitea-octans.asc

cat > /etc/apt/auth.conf.d/gitea-octans.conf <<AUTH
machine ${PKG_HOST}
login ${PKG_USER}
password ${PKG_TOKEN}
AUTH
chmod 600 /etc/apt/auth.conf.d/gitea-octans.conf

cat > /etc/apt/sources.list.d/gitea-octans.list <<APT
deb [signed-by=/etc/apt/keyrings/gitea-octans.asc] ${PKG_BASE_URL} ${PKG_DISTRIBUTION} ${PKG_COMPONENT}
APT

fetch_packages_index() {
  local index_base="${PKG_BASE_URL}/dists/${PKG_DISTRIBUTION}/${PKG_COMPONENT}/binary-${PKG_ARCHITECTURE}/Packages"

  if curl --fail --silent --show-error \
      --retry 5 --retry-delay 2 --retry-all-errors \
      --netrc-file /tmp/gitea.netrc \
      "${index_base}" \
      -o /tmp/gitea-packages; then
    return 0
  fi

  if curl --fail --silent --show-error \
      --retry 5 --retry-delay 2 --retry-all-errors \
      --netrc-file /tmp/gitea.netrc \
      "${index_base}.gz" \
      -o /tmp/gitea-packages.gz; then
    gzip -dc /tmp/gitea-packages.gz > /tmp/gitea-packages
    return 0
  fi

  return 1
}

has_exact_package_version() {
  awk -v package_name="${PKG_NAME}" -v package_version="${PKG_VERSION}" '
    BEGIN {
      RS = "";
      FS = "\n";
    }
    {
      has_package = 0;
      has_version = 0;

      for (i = 1; i <= NF; i++) {
        if ($i == "Package: " package_name) {
          has_package = 1;
        }
        if ($i == "Version: " package_version) {
          has_version = 1;
        }
      }

      if (has_package && has_version) {
        found = 1;
      }
    }
    END {
      exit(found ? 0 : 1);
    }
  ' /tmp/gitea-packages
}

found=0
for attempt in $(seq 1 "${PKG_MAX_ATTEMPTS}"); do
  apt-get update
  if fetch_packages_index && has_exact_package_version; then
    found=1
    break
  fi

  printf 'package not visible yet, retrying apt index refresh: attempt %s\n' "${attempt}"
  sleep 5
done

if [[ "${found}" != "1" ]]; then
  printf 'package is not visible in Debian registry: %s=%s\n' "${PKG_NAME}" "${PKG_VERSION}" >&2
  exit 1
fi

if [[ "${PKG_INSTALL}" == "true" ]]; then
  apt-get install -y --no-install-recommends "${PKG_NAME}=${PKG_VERSION}"

  installed_version="$(dpkg-query -W -f='${Version}\n' "${PKG_NAME}")"
  if [[ "${installed_version}" != "${PKG_VERSION}" ]]; then
    printf 'installed version mismatch: expected %s, got %s\n' "${PKG_VERSION}" "${installed_version}" >&2
    exit 1
  fi

  if [[ "${PKG_NAME}" == "octans-ffmpeg-full" ]]; then
    test -x /opt/octans-ffmpeg/bin/ffmpeg
    test -x /opt/octans-ffmpeg/bin/ffprobe
    test -x /opt/octans-ffmpeg/bin/octans-ffmpeg-capabilities
    /opt/octans-ffmpeg/bin/ffmpeg -version | head -n 1
  fi
fi

printf 'verified Debian package from Gitea registry: %s=%s %s/%s\n' \
  "${PKG_NAME}" \
  "${PKG_VERSION}" \
  "${PKG_DISTRIBUTION}" \
  "${PKG_COMPONENT}"
EOF
