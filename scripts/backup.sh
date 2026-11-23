#!/usr/bin/env bash
# Stop the desktop briefly and archive its home directory.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

cd "${ROOT_DIR}"
[[ -f .env ]] || die "No .env found. Run 'make setup' first."
load_env "${ROOT_DIR}"

CONTAINER="munna-vps-desktop"
mkdir -p backups
STAMP="$(date +%Y%m%d-%H%M%S)"
ARCHIVE="backups/desktop-${DESKTOP_USER}-${STAMP}.tar.gz"

[[ -d "${DATA_DIR}/desktop" ]] || die "${DATA_DIR}/desktop does not exist"

WAS_RUNNING="$(docker inspect -f '{{.State.Running}}' "${CONTAINER}" 2>/dev/null || echo false)"

STARTED_BY_US=false
if [[ "${WAS_RUNNING}" == "true" ]]; then
  log "Stopping desktop for a consistent snapshot ..."
  docker stop "${CONTAINER}" >/dev/null
  STARTED_BY_US=true
fi

log "Archiving ${DATA_DIR}/desktop -> ${ARCHIVE}"
if ! tar -czf "${ARCHIVE}" \
    --exclude='./.ssh/agent' \
    --exclude='./.gnupg/S.*' \
    --exclude='*.sock' \
    -C "${DATA_DIR}/desktop" .; then
  [[ "${STARTED_BY_US}" == "true" ]] && docker start "${CONTAINER}" >/dev/null || true
  die "backup failed"
fi

if [[ "${STARTED_BY_US}" == "true" ]]; then
  docker start "${CONTAINER}" >/dev/null
  log "Desktop restarted."
fi

SIZE="$(du -h "${ARCHIVE}" | awk '{print $1}')"
log "Backup complete (${SIZE}): ${ARCHIVE}"
