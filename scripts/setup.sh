#!/usr/bin/env bash
# Create .env, generate a strong VNC password, and prepare bind-mount dirs.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/setup.sh [options]

Options:
  --domain <host>     Serve at this domain with automatic HTTPS
                      (default: plain HTTP on :80)
  --http-port <port>  Host port for HTTP (default: 80)
  --user <name>       Desktop login / Linux username (default: munna)
  --tz <area/city>    Container timezone (default: auto-detected, else UTC)
  -h, --help          Show this help

Re-running is safe: an existing .env is never overwritten.
EOF
}

DOMAIN=""
HTTP_PORT_ARG=""
USER_ARG=""
TZ_ARG=""

while (( $# > 0 )); do
  case "$1" in
    --domain)    DOMAIN="${2:?--domain needs a value}"; shift 2 ;;
    --http-port) HTTP_PORT_ARG="${2:?--http-port needs a value}"; shift 2 ;;
    --user)      USER_ARG="${2:?--user needs a value}"; shift 2 ;;
    --tz)        TZ_ARG="${2:?--tz needs a value}"; shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    *)           printf 'Unknown option: %s\n' "$1" >&2; usage; exit 1 ;;
  esac
done

cd "${ROOT_DIR}"

command -v docker >/dev/null 2>&1 || die "docker is not installed or not in PATH"
docker info >/dev/null 2>&1 || die "Docker daemon is not reachable (is it running?)"
docker compose version >/dev/null 2>&1 || die "docker compose v2 is required"

if [[ -f .env ]]; then
  log ".env already exists; leaving it untouched."
  log "Edit it directly, or remove it and re-run 'make setup' to regenerate."
  exit 0
fi

# --- Timezone ---------------------------------------------------------------
if [[ -z "${TZ_ARG}" ]]; then
  if [[ -L /etc/localtime ]]; then
    TZ_ARG="$(readlink /etc/localtime | sed -E 's#.*/zoneinfo/##')"
  elif command -v timedatectl >/dev/null 2>&1; then
    TZ_ARG="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  fi
fi
TZ_VAL="${TZ_ARG:-UTC}"

# --- Password ---------------------------------------------------------------
if command -v openssl >/dev/null 2>&1; then
  PASSWORD="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | cut -c1-24)"
else
  PASSWORD="$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-24)"
fi
(( ${#PASSWORD} >= 16 )) || die "password generation failed"

# --- Write .env from the example -------------------------------------------
awk -v pw="${PASSWORD}" '
  /^VNC_PASSWORD=/ { print "VNC_PASSWORD=" pw; next }
  { print }
' .env.example > .env.tmp
mv .env.tmp .env

set_env() {
  local key="$1" value="$2"
  awk -v k="${key}" -v v="${value}" '
    index($0, k "=") == 1 { print k "=" v; next }
    { print }
  ' .env > .env.tmp
  mv .env.tmp .env
}

set_env TZ "${TZ_VAL}"
[[ -n "${USER_ARG}" ]] && set_env DESKTOP_USER "${USER_ARG}"
[[ -n "${HTTP_PORT_ARG}" ]] && set_env HTTP_PORT "${HTTP_PORT_ARG}"
if [[ -n "${DOMAIN}" ]]; then
  DOMAIN="${DOMAIN#http://}"
  DOMAIN="${DOMAIN#https://}"
  DOMAIN="${DOMAIN%/}"
  set_env SITE_ADDRESS "${DOMAIN}"
fi

chmod 0600 .env

# --- Data directories -------------------------------------------------------
mkdir -p "data/desktop" "data/caddy/data" "data/caddy/config" "backups"

# --- Summary ----------------------------------------------------------------
load_env "${ROOT_DIR}"
ACCESS_URL="$(site_url)"

cat <<EOF

  MunnaVPS is configured.

  URL        : ${ACCESS_URL}
  Username   : ${DESKTOP_USER}
  Password   : stored in .env (VNC_PASSWORD)
  Data       : ${DATA_DIR}/desktop
  Timezone   : ${TZ_VAL}

  Start it:
      make up

  For automatic HTTPS later, set SITE_ADDRESS in .env to a real domain
  whose DNS points at this host, then run 'make up'.

EOF
