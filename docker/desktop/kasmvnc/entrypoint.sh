#!/usr/bin/env bash
# MunnaVPS KasmVNC entrypoint.
set -Eeuo pipefail

log() { printf '[munna-vps] %s\n' "$*"; }
die() { printf '[munna-vps] ERROR: %s\n' "$*" >&2; exit 1; }

DESKTOP_USER="${DESKTOP_USER:-munna}"
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
VNC_PASSWORD="${VNC_PASSWORD:-}"
VNC_RESOLUTION="${VNC_RESOLUTION:-1920x1080}"
VNC_DEPTH="${VNC_DEPTH:-24}"
VNC_DISPLAY="${VNC_DISPLAY:-:1}"
VNC_PORT="${VNC_PORT:-6901}"
HOME_DIR="/home/${DESKTOP_USER}"

[[ "${DESKTOP_USER}" =~ ^[a-z_][a-z0-9_-]*$ ]] \
  || die "DESKTOP_USER must be a valid lowercase username"
[[ -n "${VNC_PASSWORD}" ]] || die "VNC_PASSWORD is not set (run: make setup)"
(( ${#VNC_PASSWORD} >= 6 )) || die "VNC_PASSWORD must be at least 6 characters"
[[ "${VNC_RESOLUTION}" =~ ^[0-9]+x[0-9]+$ ]] || die "VNC_RESOLUTION must look like 1920x1080"
[[ "${VNC_DEPTH}" =~ ^(16|24|32)$ ]] || die "VNC_DEPTH must be 16, 24 or 32"

SCREEN_WIDTH="${VNC_RESOLUTION%x*}"
SCREEN_HEIGHT="${VNC_RESOLUTION#*x}"

# --- OS user ---------------------------------------------------------------
# The Ubuntu base image may already own UID/GID 1000 (e.g. the default
# "ubuntu" account). Allow non-unique IDs so PUID/PGID always win.
if ! getent group "${DESKTOP_USER}" >/dev/null; then
  if getent group "${PGID}" >/dev/null; then
    groupadd -o -g "${PGID}" "${DESKTOP_USER}"
  else
    groupadd -g "${PGID}" "${DESKTOP_USER}"
  fi
fi

if ! id -u "${DESKTOP_USER}" >/dev/null 2>&1; then
  if id -u "${PUID}" >/dev/null 2>&1; then
    useradd -m -o -u "${PUID}" -g "${PGID}" -s /bin/bash "${DESKTOP_USER}"
  else
    useradd -m -u "${PUID}" -g "${PGID}" -s /bin/bash "${DESKTOP_USER}"
  fi
fi

if [[ "$(id -g "${DESKTOP_USER}")" != "${PGID}" ]]; then
  groupmod -o -g "${PGID}" "${DESKTOP_USER}"
fi
if [[ "$(id -u "${DESKTOP_USER}")" != "${PUID}" ]]; then
  usermod -o -u "${PUID}" "${DESKTOP_USER}"
fi

# KasmVNC validates the (unused, TLS-terminated-by-Caddy) snakeoil certificate
# paths at startup. The key is group-readable only by ssl-cert.
if getent group ssl-cert >/dev/null; then
  usermod -aG ssl-cert "${DESKTOP_USER}"
fi

mkdir -p "${HOME_DIR}"
if [[ "$(stat -c '%u:%g' "${HOME_DIR}")" != "${PUID}:${PGID}" ]]; then
  log "Fixing ownership of ${HOME_DIR} to ${PUID}:${PGID} (one-time)"
  chown -R "${PUID}:${PGID}" "${HOME_DIR}"
fi

mkdir -p "${HOME_DIR}/.vnc" "${HOME_DIR}/Desktop" "${HOME_DIR}/Downloads" \
         "${HOME_DIR}/Documents" "${HOME_DIR}/Pictures" "${HOME_DIR}/Public" \
         "${HOME_DIR}/Templates" "${HOME_DIR}/Videos"
chown "${PUID}:${PGID}" "${HOME_DIR}/.vnc" "${HOME_DIR}"

# --- XFCE session ----------------------------------------------------------
# Only seed on first boot so users can customise their xstartup later.
if [[ ! -f "${HOME_DIR}/.vnc/xstartup" ]]; then
  install -o "${PUID}" -g "${PGID}" -m 0755 \
    /etc/munnavps/xstartup "${HOME_DIR}/.vnc/xstartup"
  log "Seeded ${HOME_DIR}/.vnc/xstartup"
fi

# --- KasmVNC system config -------------------------------------------------
# Regenerated on every start; user overrides belong in ~/.vnc/kasmvnc.yaml.
cat > /etc/kasmvnc/kasmvnc.yaml <<EOF
desktop:
  resolution:
    width: ${SCREEN_WIDTH}
    height: ${SCREEN_HEIGHT}
  allow_resize: true
  pixel_depth: ${VNC_DEPTH}
network:
  protocol: http
  interface: 0.0.0.0
  websocket_port: ${VNC_PORT}
  use_ipv4: true
  use_ipv6: false
  ssl:
    require_ssl: false
  udp:
    public_ip: 127.0.0.1
user_session:
  idle_timeout: never
  new_session_disconnects_existing_exclusive_session: false
logging:
  log_dest: logfile
  level: 30
server:
  advanced:
    kasm_password_file: ${HOME_DIR}/.kasmpasswd
  auto_shutdown:
    no_user_session_timeout: never
    active_user_session_timeout: never
    inactive_user_session_timeout: never
  allow_environment_variables_to_override_config_settings: true
command_line:
  prompt: false
EOF
chmod 0644 /etc/kasmvnc/kasmvnc.yaml

# --- Credentials -----------------------------------------------------------
# KasmVNC 1.5+ installs kasmvncpasswd (with a vncpasswd alternative); older
# packages use vncserver/vncpasswd directly. Support both.
VNC_PASSWD_BIN="$(command -v kasmvncpasswd || command -v vncpasswd || true)"
VNC_SERVER_BIN="$(command -v kasmvncserver || command -v vncserver || true)"
[[ -n "${VNC_PASSWD_BIN}" ]] || die "KasmVNC password utility not found"
[[ -n "${VNC_SERVER_BIN}" ]] || die "KasmVNC server binary not found"

# Re-applied on every start so the container always matches .env. vncpasswd
# reads the password and its confirmation from stdin (see vncpasswd(1)).
if ! printf '%s\n%s\n' "${VNC_PASSWORD}" "${VNC_PASSWORD}" \
    | gosu "${DESKTOP_USER}" env HOME="${HOME_DIR}" "${VNC_PASSWD_BIN}" -u "${DESKTOP_USER}" -w; then
  die "Could not create the KasmVNC password file"
fi
chown "${PUID}:${PGID}" "${HOME_DIR}/.kasmpasswd"
chmod 0600 "${HOME_DIR}/.kasmpasswd"

# --- Clean stale session state from an unclean stop ------------------------
gosu "${DESKTOP_USER}" env HOME="${HOME_DIR}" "${VNC_SERVER_BIN}" -kill "${VNC_DISPLAY}" >/dev/null 2>&1 || true
find "${HOME_DIR}/.vnc" -maxdepth 1 -type f \( -name '*.pid' -o -name '*.lock' \) -delete 2>/dev/null || true
rm -f "/tmp/.X${VNC_DISPLAY#:}-lock" 2>/dev/null || true

log "Desktop user : ${DESKTOP_USER} (uid ${PUID}, gid ${PGID})"
log "Resolution   : ${VNC_RESOLUTION} @ ${VNC_DEPTH}-bit"
log "Web port     : ${VNC_PORT} (inside container, HTTP)"
log "Idle timeout : never"
log "Starting KasmVNC + XFCE ..."

exec gosu "${DESKTOP_USER}" env \
  HOME="${HOME_DIR}" \
  USER="${DESKTOP_USER}" \
  LOGNAME="${DESKTOP_USER}" \
  SHELL=/bin/bash \
  "${VNC_SERVER_BIN}" "${VNC_DISPLAY}" \
    -select-de manual \
    -geometry "${VNC_RESOLUTION}" \
    -depth "${VNC_DEPTH}" \
    -fg
