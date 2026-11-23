#!/usr/bin/env bash
# MunnaVPS TigerVNC + noVNC fallback entrypoint.
set -Eeuo pipefail

log() { printf '[munna-vps] %s\n' "$*"; }
die() { printf '[munna-vps] ERROR: %s\n' "$*" >&2; exit 1; }

DESKTOP_USER="${DESKTOP_USER:-munna}"
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
VNC_PASSWORD="${VNC_PASSWORD:-}"
VNC_RESOLUTION="${VNC_RESOLUTION:-1920x1080}"
VNC_DEPTH="${VNC_DEPTH:-24}"
HOME_DIR="/home/${DESKTOP_USER}"

[[ "${DESKTOP_USER}" =~ ^[a-z_][a-z0-9_-]*$ ]] \
  || die "DESKTOP_USER must be a valid lowercase username"
[[ -n "${VNC_PASSWORD}" ]] || die "VNC_PASSWORD is not set (run: make setup)"
(( ${#VNC_PASSWORD} >= 6 )) || die "VNC_PASSWORD must be at least 6 characters"
[[ "${VNC_RESOLUTION}" =~ ^[0-9]+x[0-9]+$ ]] || die "VNC_RESOLUTION must look like 1920x1080"
[[ "${VNC_DEPTH}" =~ ^(16|24|32)$ ]] || die "VNC_DEPTH must be 16, 24 or 32"

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

# Keep parity with the KasmVNC image (harmless for TigerVNC).
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
if [[ ! -f "${HOME_DIR}/.vnc/xstartup" ]]; then
  install -o "${PUID}" -g "${PGID}" -m 0755 \
    /etc/munnavps/xstartup "${HOME_DIR}/.vnc/xstartup"
  log "Seeded ${HOME_DIR}/.vnc/xstartup"
fi

# --- VNC password ----------------------------------------------------------
# TigerVNC ships tigervncpasswd on Debian/Ubuntu (vncpasswd on some builds).
# -f reads one plain password from stdin and writes the obfuscated form to
# stdout; we redirect it into ~/.vnc/passwd.
VNC_PASSWD_BIN="$(command -v tigervncpasswd || command -v vncpasswd || true)"
[[ -n "${VNC_PASSWD_BIN}" ]] || die "TigerVNC password utility not found"
if ! printf '%s\n' "${VNC_PASSWORD}" \
    | gosu "${DESKTOP_USER}" env HOME="${HOME_DIR}" "${VNC_PASSWD_BIN}" -f \
    > "${HOME_DIR}/.vnc/passwd"; then
  die "Could not create the TigerVNC password file"
fi
chown "${PUID}:${PGID}" "${HOME_DIR}/.vnc/passwd"
chmod 0600 "${HOME_DIR}/.vnc/passwd"

# --- Clean stale session state ---------------------------------------------
VNC_SERVER_BIN="$(command -v tigervncserver || command -v vncserver || true)"
if [[ -n "${VNC_SERVER_BIN}" ]]; then
  gosu "${DESKTOP_USER}" env HOME="${HOME_DIR}" "${VNC_SERVER_BIN}" -kill :1 >/dev/null 2>&1 || true
fi
find "${HOME_DIR}/.vnc" -maxdepth 1 -type f \( -name '*.pid' -o -name '*.lock' \) -delete 2>/dev/null || true
rm -f /tmp/.X1-lock 2>/dev/null || true

log "Desktop user : ${DESKTOP_USER} (uid ${PUID}, gid ${PGID})"
log "Resolution   : ${VNC_RESOLUTION} @ ${VNC_DEPTH}-bit"
log "Web port     : 6080 (inside container, HTTP)"
log "Idle timeout : never"
log "Starting TigerVNC + noVNC + XFCE ..."

# supervisord runs as root (so it can write to Docker's stdout) and drops to
# the desktop user for each program.
SUPERVISOR_CONF="/tmp/munnavps-supervisord.conf"
sed -e "s|@DESKTOP_USER@|${DESKTOP_USER}|g" \
    -e "s|@HOME_DIR@|${HOME_DIR}|g" \
    /etc/munnavps/supervisord.conf > "${SUPERVISOR_CONF}"
chmod 0644 "${SUPERVISOR_CONF}"

exec supervisord -c "${SUPERVISOR_CONF}"
