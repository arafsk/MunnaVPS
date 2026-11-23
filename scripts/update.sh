#!/usr/bin/env bash
# Pull newer base/upstream images and recreate the stack.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

cd "${ROOT_DIR}"
[[ -f .env ]] || die "No .env found. Run 'make setup' first."

log "Building with --pull ..."
docker compose build --pull

log "Recreating services ..."
docker compose up -d --remove-orphans

log "Waiting for health checks ..."
sleep 5
"${SCRIPT_DIR}/healthcheck.sh"
