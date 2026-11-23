# Shared helpers for MunnaVPS scripts. Source, do not execute.
# shellcheck shell=bash

log() { printf '[munna-vps] %s\n' "$*"; }
die() { printf '[munna-vps] ERROR: %s\n' "$*" >&2; exit 1; }

# Load .env from the repository root and apply defaults used by the scripts.
load_env() {
  local root="${1:?repo root required}"
  if [[ -f "${root}/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    . "${root}/.env"
    set +a
  fi

  DATA_DIR="${DATA_DIR:-./data}"
  DESKTOP_USER="${DESKTOP_USER:-munna}"
  SITE_ADDRESS="${SITE_ADDRESS:-:80}"
  HTTP_PORT="${HTTP_PORT:-80}"
  HTTPS_PORT="${HTTPS_PORT:-443}"
}

# Public URL of the stack, as a user would open it.
site_url() {
  if [[ "${SITE_ADDRESS}" == :* ]]; then
    printf 'http://localhost:%s' "${HTTP_PORT}"
  elif [[ "${SITE_ADDRESS}" == localhost* ]]; then
    if [[ "${HTTPS_PORT}" == "443" ]]; then
      printf 'https://localhost'
    else
      printf 'https://localhost:%s' "${HTTPS_PORT}"
    fi
  else
    if [[ "${HTTPS_PORT}" == "443" ]]; then
      printf 'https://%s' "${SITE_ADDRESS}"
    else
      printf 'https://%s:%s' "${SITE_ADDRESS}" "${HTTPS_PORT}"
    fi
  fi
}
