#!/usr/bin/env bash
# End-to-end smoke test. Uses throwaway host ports and stops the stack unless
# KEEP=1 is set.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../scripts/lib/common.sh
. "${SCRIPT_DIR}/../scripts/lib/common.sh"

cd "${ROOT_DIR}"
[[ -f .env ]] || die "No .env found. Run 'make setup' first."

# Override ports so a running production stack does not conflict.
export HTTP_PORT="${SMOKE_HTTP_PORT:-18080}"
export HTTPS_PORT="${SMOKE_HTTPS_PORT:-18443}"
export SITE_ADDRESS=":80"

load_env "${ROOT_DIR}"
# load_env re-reads .env and would undo the port overrides; restore them.
HTTP_PORT="${SMOKE_HTTP_PORT:-18080}"
HTTPS_PORT="${SMOKE_HTTPS_PORT:-18443}"
SITE_ADDRESS=":80"

cleanup() {
  if [[ "${KEEP:-0}" != "1" ]]; then
    log "Stopping smoke-test stack ..."
    docker compose down --remove-orphans >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

log "Building and starting the stack on ${HTTP_PORT} ..."
docker compose up -d --build

log "Waiting for the desktop health check (up to 240s) ..."
for _ in $(seq 1 48); do
  state="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' munna-vps-desktop 2>/dev/null || echo missing)"
  [[ "${state}" == "healthy" ]] && break
  sleep 5
done
[[ "${state}" == "healthy" ]] || die "desktop did not become healthy (state: ${state})"

URL="http://localhost:${HTTP_PORT}"
CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "${URL}" || true)"
case "${CODE}" in
  200|302|401) log "OK   ${URL} -> HTTP ${CODE}" ;;
  *) die "${URL} returned HTTP ${CODE:-no response}" ;;
esac

AUTH_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
  -u "${DESKTOP_USER}:${VNC_PASSWORD}" "${URL}" || true)"
case "${AUTH_CODE}" in
  200|302) log "OK   authenticated request -> HTTP ${AUTH_CODE}" ;;
  *) die "authenticated request returned HTTP ${AUTH_CODE:-no response}" ;;
esac

log "Checking the desktop process inside the container ..."
docker compose exec -T desktop bash -c \
  'pgrep -u "$DESKTOP_USER" -f "Xvnc|Xtigervnc" >/dev/null' \
  || die "no VNC server process found"

log "Smoke test passed."
