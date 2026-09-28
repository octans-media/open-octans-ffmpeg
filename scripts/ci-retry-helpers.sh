#!/usr/bin/env bash

if [[ -n "${OCTANS_CI_RETRY_HELPERS_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
OCTANS_CI_RETRY_HELPERS_LOADED=1

octans_ci_retry_attempts() {
  local value="${OCTANS_CI_RETRY_ATTEMPTS:-5}"

  if [[ "${value}" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s\n' "${value}"
    return 0
  fi

  printf '5\n'
}

octans_ci_retry_delay_seconds() {
  local value="${OCTANS_CI_RETRY_DELAY_SECONDS:-2}"

  if [[ "${value}" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s\n' "${value}"
    return 0
  fi

  printf '2\n'
}

octans_ci_next_retry_delay() {
  local delay="$1"
  local max_delay="${OCTANS_CI_RETRY_MAX_DELAY_SECONDS:-30}"

  if [[ ! "${max_delay}" =~ ^[1-9][0-9]*$ ]]; then
    max_delay=30
  fi

  delay=$((delay * 2))
  if ((delay > max_delay)); then
    delay="${max_delay}"
  fi

  printf '%s\n' "${delay}"
}

octans_ci_retry() {
  local label="$1"
  shift

  local attempts
  local delay
  local attempt
  local status

  attempts="$(octans_ci_retry_attempts)"
  delay="$(octans_ci_retry_delay_seconds)"
  attempt=1

  while ((attempt <= attempts)); do
    if "$@"; then
      return 0
    fi

    status=$?
    if ((attempt == attempts)); then
      printf 'retry exhausted: %s failed after %s attempts (status=%s)\n' \
        "${label}" \
        "${attempts}" \
        "${status}" >&2
      return "${status}"
    fi

    printf 'retryable command failed: %s attempt=%s/%s status=%s, retrying in %ss\n' \
      "${label}" \
      "${attempt}" \
      "${attempts}" \
      "${status}" \
      "${delay}" >&2
    sleep "${delay}"
    delay="$(octans_ci_next_retry_delay "${delay}")"
    attempt=$((attempt + 1))
  done
}

octans_ci_retry_curl() {
  local label="$1"
  shift

  octans_ci_retry "${label}" curl "$@"
}

octans_ci_http_status_matches() {
  local expected="$1"
  local actual="$2"
  local entry

  IFS=',' read -r -a expected_statuses <<< "${expected}"
  for entry in "${expected_statuses[@]}"; do
    if [[ "${entry}" == "${actual}" ]]; then
      return 0
    fi
  done

  return 1
}

octans_ci_http_status_is_retryable() {
  case "$1" in
    000|408|425|429|500|502|503|504)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

octans_ci_curl_status() {
  local expected="$1"
  local body_file="$2"
  local label="$3"
  shift 3

  local attempts
  local delay
  local attempt
  local http_status
  local curl_status
  local stderr_file
  local restore_errexit

  attempts="$(octans_ci_retry_attempts)"
  delay="$(octans_ci_retry_delay_seconds)"
  attempt=1
  stderr_file="$(mktemp)"
  restore_errexit=0
  case "$-" in
    *e*)
      restore_errexit=1
      ;;
  esac

  while ((attempt <= attempts)); do
    : > "${body_file}"
    : > "${stderr_file}"

    set +e
    http_status="$(
      curl --silent --show-error \
        --output "${body_file}" \
        --write-out '%{http_code}' \
        "$@" \
        2>"${stderr_file}"
    )"
    curl_status=$?
    if [[ "${restore_errexit}" -eq 1 ]]; then
      set -e
    else
      set +e
    fi

    if [[ "${curl_status}" -eq 0 ]]; then
      if octans_ci_http_status_matches "${expected}" "${http_status}" \
        || ! octans_ci_http_status_is_retryable "${http_status}"; then
        rm -f "${stderr_file}"
        printf '%s\n' "${http_status}"
        return 0
      fi
    else
      http_status="000"
    fi

    if ((attempt == attempts)); then
      if [[ -s "${stderr_file}" ]]; then
        cat "${stderr_file}" >&2
      fi
      printf 'retry exhausted: %s returned HTTP %s after %s attempts\n' \
        "${label}" \
        "${http_status}" \
        "${attempts}" >&2
      rm -f "${stderr_file}"
      printf '%s\n' "${http_status}"
      return 0
    fi

    if [[ -s "${stderr_file}" ]]; then
      cat "${stderr_file}" >&2
    fi
    printf 'retryable HTTP call failed: %s attempt=%s/%s status=%s, retrying in %ss\n' \
      "${label}" \
      "${attempt}" \
      "${attempts}" \
      "${http_status}" \
      "${delay}" >&2
    sleep "${delay}"
    delay="$(octans_ci_next_retry_delay "${delay}")"
    attempt=$((attempt + 1))
  done
}

octans_ci_imagetools_missing_output() {
  local output="${1,,}"

  case "${output}" in
    *"not found"*|*"manifest unknown"*|*"name unknown"*|*"repository does not exist"*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

octans_ci_imagetools_digest() {
  local ref="$1"
  local attempts
  local delay
  local attempt
  local output
  local status
  local digest
  local restore_errexit

  attempts="$(octans_ci_retry_attempts)"
  delay="$(octans_ci_retry_delay_seconds)"
  attempt=1
  restore_errexit=0
  case "$-" in
    *e*)
      restore_errexit=1
      ;;
  esac

  while ((attempt <= attempts)); do
    set +e
    output="$(docker buildx imagetools inspect "${ref}" 2>&1)"
    status=$?
    if [[ "${restore_errexit}" -eq 1 ]]; then
      set -e
    else
      set +e
    fi

    if [[ "${status}" -eq 0 ]]; then
      digest="$(awk '/^Digest:/ {print $2; exit}' <<< "${output}")"
      if [[ -n "${digest}" ]]; then
        printf '%s\n' "${digest}"
        return 0
      fi
      output="docker buildx imagetools inspect did not return a Digest line for ${ref}"
      status=1
    fi

    if ((attempt == attempts)); then
      printf 'failed to inspect image digest after %s attempts: %s\n' "${attempts}" "${ref}" >&2
      printf '%s\n' "${output}" >&2
      return "${status}"
    fi

    printf 'retryable manifest inspect failed: %s attempt=%s/%s status=%s, retrying in %ss\n' \
      "${ref}" \
      "${attempt}" \
      "${attempts}" \
      "${status}" \
      "${delay}" >&2
    sleep "${delay}"
    delay="$(octans_ci_next_retry_delay "${delay}")"
    attempt=$((attempt + 1))
  done
}

octans_ci_imagetools_ref_exists() {
  local ref="$1"
  local attempts
  local delay
  local attempt
  local output
  local status
  local restore_errexit

  attempts="$(octans_ci_retry_attempts)"
  delay="$(octans_ci_retry_delay_seconds)"
  attempt=1
  restore_errexit=0
  case "$-" in
    *e*)
      restore_errexit=1
      ;;
  esac

  while ((attempt <= attempts)); do
    set +e
    output="$(docker buildx imagetools inspect "${ref}" 2>&1)"
    status=$?
    if [[ "${restore_errexit}" -eq 1 ]]; then
      set -e
    else
      set +e
    fi

    if [[ "${status}" -eq 0 ]]; then
      return 0
    fi

    if octans_ci_imagetools_missing_output "${output}"; then
      return 1
    fi

    if ((attempt == attempts)); then
      printf 'failed to determine image ref state after %s attempts: %s\n' "${attempts}" "${ref}" >&2
      printf '%s\n' "${output}" >&2
      return 2
    fi

    printf 'retryable manifest existence check failed: %s attempt=%s/%s status=%s, retrying in %ss\n' \
      "${ref}" \
      "${attempt}" \
      "${attempts}" \
      "${status}" \
      "${delay}" >&2
    sleep "${delay}"
    delay="$(octans_ci_next_retry_delay "${delay}")"
    attempt=$((attempt + 1))
  done
}

octans_ci_docker_push() {
  local ref="$1"
  octans_ci_retry "docker push ${ref}" docker push "${ref}"
}

octans_ci_docker_pull() {
  local ref="$1"
  octans_ci_retry "docker pull ${ref}" docker pull "${ref}"
}

octans_ci_imagetools_create() {
  local target_ref="$1"
  local source_ref="$2"

  octans_ci_retry "docker buildx imagetools create ${target_ref}" \
    docker buildx imagetools create -t "${target_ref}" "${source_ref}"
}
