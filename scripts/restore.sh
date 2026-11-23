#!/usr/bin/env bash
# Restore a desktop home archive produced by scripts/backup.sh.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/restore.sh <archive.tar.gz> [--yes]

The current home directory is moved aside to
data/desktop.pre-restore-<timestamp> before the archive is extracted.
EOF
}

ARCHIVE=""
ASSUME_YES=false
for arg in "$@"; do
  case "${arg}" in
    --yes) ASSUME_YES=true ;;
    -h|--help) usage; exit 0 ;;
    *) ARCHIVE="${arg}" ;;
  esac
done

[[ -n "${ARCHIVE}" ]] || { usage; exit 1; }
[[ -f "${ARCHIVE}" ]] || die "archive not found: ${ARCHIVE}"

cd "${ROOT_DIR}"
[[ -f .env ]] || die "No .env found. Run 'make setup' first."
load_env "${ROOT_DIR}"

if [[ "${ASSUME_YES}" != "true" ]]; then
  printf 'Restore %s into %s/desktop? [y/N] ' "${ARCHIVE}" "${DATA_DIR}"
  read -r reply
  [[ "${reply}" =~ ^[Yy]$ ]] || { log "Aborted."; exit 0; }
fi

CONTAINER="munna-vps-desktop"
STAMP="$(date +%Y%m%d-%H%M%S)"
WAS_RUNNING="$(docker inspect -f '{{.State.Running}}' "${CONTAINER}" 2>/dev/null || echo false)"

if [[ "${WAS_RUNNING}" == "true" ]]; then
  log "Stopping desktop ..."
  docker stop "${CONTAINER}" >/dev/null
fi

if [[ -d "${DATA_DIR}/desktop" ]]; then
  mv "${DATA_DIR}/desktop" "${DATA_DIR}/desktop.pre-restore-${STAMP}"
  log "Previous home saved at ${DATA_DIR}/desktop.pre-restore-${STAMP}"
fi
mkdir -p "${DATA_DIR}/desktop"

log "Extracting ${ARCHIVE} ..."
tar -xzf "${ARCHIVE}" -C "${DATA_DIR}/desktop"

if [[ "${WAS_RUNNING}" == "true" ]]; then
  docker start "${CONTAINER}" >/dev/null
  log "Desktop restarted."
fi

log "Restore complete."
