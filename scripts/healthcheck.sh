#!/usr/bin/env bash
# Validate the running stack and the public HTTP endpoint.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

cd "${ROOT_DIR}"
[[ -f .env ]] || die "No .env found. Run 'make setup' first."
load_env "${ROOT_DIR}"

container_health() {
  docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}}' "$1" 2>/dev/null || echo missing
}

# Docker reports "starting" during the healthcheck start_period. Wait briefly
# so `make health` works immediately after `make up` or `make update`.
for _ in $(seq 1 30); do
  desktop_health="$(container_health munna-vps-desktop)"
  caddy_health="$(container_health munna-vps-caddy)"
  if [[ "${desktop_health}" != "starting" && "${caddy_health}" != "starting" ]]; then
    break
  fi
  sleep 2
done

FAILED=0

check_container() {
  local name="$1" state health
  state="$(docker inspect -f '{{.State.Status}}' "${name}" 2>/dev/null || echo missing)"
  health="$(container_health "${name}")"
  if [[ "${state}" == "running" && ( "${health}" == "healthy" || "${health}" == "n/a" ) ]]; then
    log "OK   ${name}: ${state} (${health})"
  else
    log "FAIL ${name}: ${state} (${health})"
    FAILED=1
  fi
}

check_container munna-vps-desktop
check_container munna-vps-caddy

URL="$(site_url)"
CODE="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 "${URL}" || true)"
case "${CODE}" in
  200|302|401) log "OK   ${URL} -> HTTP ${CODE}" ;;
  *)           log "FAIL ${URL} -> HTTP ${CODE:-no response}"; FAILED=1 ;;
esac

if [[ "${FAILED}" -ne 0 ]]; then
  die "health check failed; inspect with 'make logs'"
fi
log "Stack is healthy."
