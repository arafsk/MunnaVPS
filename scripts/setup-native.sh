#!/usr/bin/env bash
# MunnaVPS native setup — expose a physical Linux machine over VNC/noVNC.
#
# No Docker and no Caddy. This script installs and wires up a systemd service
# that serves the machine's desktop in a browser, with password auth and no
# session/idle timeout.
#
# Two backends:
#   share   (default) x11vnc attaches to the logged-in X11 desktop
#   virtual           TigerVNC runs a dedicated XFCE (or detected) desktop
#
# It is self-contained: copy this file to the Linux host and run it there.
#
# Examples:
#   sudo ./setup-native.sh
#   sudo ./setup-native.sh --virtual --install-desktop
#   sudo ./setup-native.sh --bind 0.0.0.0 --tls --open-firewall
#   sudo ./setup-native.sh --print-password
#   sudo ./setup-native.sh --uninstall
#
set -Eeuo pipefail

PROGRAM="munna-native"
CONFIG_DIR="/etc/munnavps"
STATE_DIR="/var/lib/munnavps"
TLS_DIR="${CONFIG_DIR}/tls"
WEB_DIR="${STATE_DIR}/web"
LAUNCHER="/usr/local/bin/munnavps-start-vnc"
UNIT_DIR="${UNIT_DIR:-/etc/systemd/system}"
VNC_PORT_DEFAULT="5900"
NOVNC_VERSION="${NOVNC_VERSION:-1.5.0}"

log() { printf '[%s] %s\n' "$PROGRAM" "$*"; }
die() { printf '[%s] ERROR: %s\n' "$PROGRAM" "$*" >&2; exit 1; }
trap 'printf "[%s] ERROR: unexpected failure at line %s\n" "$PROGRAM" "$LINENO" >&2' ERR

usage() {
  cat <<'EOF'
Usage: setup-native.sh [options]

Share a physical Linux desktop in the browser (no Docker). The default mode
shares the current X11 login with x11vnc; --virtual creates a dedicated
desktop with TigerVNC. Both are served by noVNC + websockify.

Options:
  --share                 Share the existing X11 desktop (default)
  --virtual               Run a dedicated virtual desktop instead
  --user <name>           Linux user that owns the desktop
                          (default: sudo caller, else first login user)
  --display <:N>          X display (share: auto-detect; virtual: free :N)
  --resolution <WxH>      Virtual desktop geometry (default: 1920x1080)
  --depth <16|24|32>      Virtual desktop colour depth (default: 24)
  --port <port>           noVNC web port (default: 6080)
  --vnc-port <port>       Loopback VNC port (default: 5900)
  --bind <addr>           Web listen address (default: 127.0.0.1)
  --tls                   Serve noVNC over HTTPS with a self-signed cert
  --insecure              Allow a non-loopback bind without TLS
  --install-desktop       Install XFCE if --virtual finds no desktop
  --open-firewall         Open the web port in active ufw/firewalld
  --password <pass>       Use this VNC password instead of generating one
                          (VNC auth uses only the first 8 characters; this
                          value also appears in shell history)
  --rotate-password       Generate a new password on re-run
  --xauth <file|guess>    X authority file for x11vnc (default: guess)
  --force                 Continue when only a Wayland session is detected
  --print-password        Print the stored VNC password and exit
  --uninstall             Stop and remove the services and configuration
  -h, --help              Show this help

Security defaults:
  * The VNC port is loopback-only; only websockify is exposed.
  * A non-loopback --bind requires --tls (or --insecure on a trusted network).
  * VNC authentication truncates passwords to 8 characters.
  * VNC auth is not strong; prefer a VPN or TLS + a firewall.

Files:
  /etc/munnavps/vnc.pass          VNC password file used by the backend
  /etc/munnavps/vnc-password      Root-only plaintext copy (for --print-password)
  /etc/munnavps/config            Installed settings
  /etc/systemd/system/munnavps-*  systemd units
EOF
}

# --- Defaults ---------------------------------------------------------------
MODE="share"
DESKTOP_USER=""
DISPLAY_NUM=""
RESOLUTION="1920x1080"
DEPTH="24"
WEB_PORT="6080"
VNC_PORT="${VNC_PORT_DEFAULT}"
BIND_ADDR="127.0.0.1"
USE_TLS=0
INSECURE=0
FORCE=0
OPEN_FW=0
INSTALL_DESKTOP=0
XAUTH="guess"
PASSWORD_ARG="${VNC_PASSWORD:-}"
ROTATE_PASSWORD=0
PRINT_PW=0
UNINSTALL=0
APT_UPDATED=0

# --- Helpers ----------------------------------------------------------------
default_user() {
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    printf '%s' "${SUDO_USER}"
    return 0
  fi

  local user=""
  if command -v loginctl >/dev/null 2>&1; then
    # Columns: SESSION UID USER SEAT TTY. Ignore system accounts such as gdm.
    user="$(loginctl list-sessions --no-legend 2>/dev/null \
      | awk '$2 ~ /^[0-9]+$/ && $2 >= 1000 && $2 < 65534 { print $3; exit }' \
      || true)"
  fi
  if [[ -z "${user}" ]] && command -v who >/dev/null 2>&1; then
    user="$(who 2>/dev/null | awk 'NR == 1 { print $1 }' || true)"
    if [[ -n "${user}" ]]; then
      local uid
      uid="$(id -u "${user}" 2>/dev/null || true)"
      if [[ -z "${uid}" ]] || (( uid < 1000 || uid >= 65534 )); then
        user=""
      fi
    fi
  fi
  if [[ -z "${user}" ]]; then
    user="$(awk -F: '$3 >= 1000 && $3 < 65534 && $7 !~ /(nologin|false)$/ { print $1; exit }' /etc/passwd || true)"
  fi
  printf '%s' "${user}"
}

detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    printf 'apt'
  elif command -v dnf >/dev/null 2>&1; then
    printf 'dnf'
  elif command -v pacman >/dev/null 2>&1; then
    printf 'pacman'
  elif command -v zypper >/dev/null 2>&1; then
    printf 'zypper'
  else
    return 1
  fi
}

pkg_update_once() {
  case "${PKG}" in
    apt)
      if (( APT_UPDATED == 0 )); then
        log "Refreshing the apt package index"
        apt-get update -qq || die "apt-get update failed"
        APT_UPDATED=1
      fi
      ;;
  esac
}

pkg_install() {
  pkg_update_once
  case "${PKG}" in
    apt)
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
      ;;
    dnf)
      dnf -y install "$@"
      ;;
    pacman)
      pacman -S --needed --noconfirm "$@"
      ;;
    zypper)
      zypper --non-interactive install --no-recommends "$@"
      ;;
    *)
      die "unsupported package manager"
      ;;
  esac
}

pkg_try_install() {
  pkg_install "$@" >/dev/null 2>&1
}

installed_base_packages() {
  local -a pkgs=(openssl curl ca-certificates)
  if [[ "${MODE}" == "share" ]]; then
    pkgs+=(x11vnc)
  else
    case "${PKG}" in
      apt)    pkgs+=(tigervnc-standalone-server tigervnc-common tigervnc-tools dbus-x11 xauth) ;;
      dnf)    pkgs+=(tigervnc-server tigervnc-server-minimal dbus-tools xorg-x11-xauth) ;;
      pacman) pkgs+=(tigervnc dbus xorg-xauth) ;;
      zypper) pkgs+=(tigervnc dbus-1 xauth) ;;
    esac
  fi
  printf '%s\n' "${pkgs[@]}"
}

install_base_packages() {
  local -a pkgs=()
  local pkg
  while IFS= read -r pkg; do
    [[ -n "${pkg}" ]] && pkgs+=("${pkg}")
  done < <(installed_base_packages)
  log "Installing: ${pkgs[*]}"
  pkg_install "${pkgs[@]}" || die "package installation failed"
}

install_desktop() {
  log "Installing XFCE (requested with --install-desktop)"
  case "${PKG}" in
    apt)
      pkg_install xfce4 xfce4-terminal dbus-x11 x11-xserver-utils \
        fonts-dejavu-core xfonts-base \
        || die "XFCE installation failed"
      ;;
    dnf)
      dnf -y group install "Xfce Desktop" || die "XFCE group installation failed"
      pkg_install dbus-tools || die "dbus-tools installation failed"
      ;;
    pacman)
      pkg_install xfce4 xfce4-terminal xorg-xset || die "XFCE installation failed"
      ;;
    zypper)
      pkg_install patterns-xfce-xfce xfce4-terminal dbus-1 \
        || die "XFCE installation failed"
      ;;
  esac
}

download_novnc() {
  local url tmp
  local version="${NOVNC_VERSION#v}"
  url="https://github.com/novnc/noVNC/archive/refs/tags/v${version}.tar.gz"
  log "Downloading noVNC v${version} from GitHub"
  tmp="$(mktemp -d)"
  if ! curl -fsSL --retry 3 "${url}" -o "${tmp}/novnc.tar.gz"; then
    rm -rf "${tmp}"
    die "could not download noVNC (set NOVNC_VERSION or install noVNC manually)"
  fi
  if ! tar -xzf "${tmp}/novnc.tar.gz" -C "${tmp}"; then
    rm -rf "${tmp}"
    die "could not unpack noVNC"
  fi
  mkdir -p "${STATE_DIR}"
  rm -rf "${STATE_DIR}/novnc"
  mv "${tmp}/noVNC-${version}" "${STATE_DIR}/novnc" || die "noVNC unpack layout was unexpected"
  rm -rf "${tmp}"
}

find_novnc_dir() {
  local dir
  for dir in "${STATE_DIR}/novnc" /usr/share/novnc /usr/share/webapps/novnc \
             /usr/share/javascript/novnc /usr/local/share/novnc; do
    if [[ -f "${dir}/vnc.html" || -f "${dir}/vnc_lite.html" ]]; then
      NOVNC_DIR="${dir}"
      return 0
    fi
  done
  return 1
}

install_websockify() {
  local package=""
  local wrapper="/usr/local/bin/munnavps-websockify"
  case "${PKG}" in
    apt)    package="websockify" ;;
    dnf)    package="python-websockify" ;;
    pacman) package="websockify" ;;
    zypper) package="python3-websockify" ;;
  esac

  if [[ -x "${wrapper}" ]] \
     && PYTHONPATH="${STATE_DIR}/python" \
        python3 -c 'import websockify' >/dev/null 2>&1; then
    WEBSOCKIFY_WRAPPER="${wrapper}"
    return 0
  fi
  if pkg_try_install "${package}" \
     && command -v websockify >/dev/null 2>&1; then
    return 0
  fi
  if command -v python3 >/dev/null 2>&1 \
     && python3 -c 'import websockify' >/dev/null 2>&1; then
    return 0
  fi

  log "websockify is not packaged here; installing it into ${STATE_DIR}/python"
  case "${PKG}" in
    pacman) pkg_install python-pip || die "could not install python-pip" ;;
    *)      pkg_install python3-pip || die "could not install python3-pip" ;;
  esac
  mkdir -p "${STATE_DIR}/python"
  python3 -m pip install --disable-pip-version-check --no-input \
    --upgrade --target "${STATE_DIR}/python" websockify \
    || die "pip could not install websockify"

  WEBSOCKIFY_WRAPPER="/usr/local/bin/munnavps-websockify"
  cat > "${WEBSOCKIFY_WRAPPER}" <<EOF
#!/bin/sh
# MunnaVPS websockify wrapper (pip-installed fallback).
PYTHONPATH="${STATE_DIR}/python\${PYTHONPATH:+:\${PYTHONPATH}}"
export PYTHONPATH
exec python3 -m websockify "\$@"
EOF
  chmod 0755 "${WEBSOCKIFY_WRAPPER}"
  chown root:root "${WEBSOCKIFY_WRAPPER}"
}

install_novnc() {
  if find_novnc_dir; then
    log "noVNC assets: ${NOVNC_DIR}"
    return 0
  fi
  if ! pkg_try_install novnc; then
    log "The noVNC package is unavailable on this distro; using the upstream release"
  fi
  if ! find_novnc_dir; then
    log "noVNC assets were not found; downloading the upstream release"
    download_novnc
  fi
  find_novnc_dir || die "noVNC web files were not found after installation"
  log "noVNC assets: ${NOVNC_DIR}"
}

find_session() {
  if command -v startxfce4 >/dev/null 2>&1; then
    SESSION_BIN="startxfce4"; SESSION_LABEL="XFCE"; SESSION_ID="xfce"
  elif command -v mate-session >/dev/null 2>&1; then
    SESSION_BIN="mate-session"; SESSION_LABEL="MATE"; SESSION_ID="mate"
  elif command -v startplasma-x11 >/dev/null 2>&1; then
    SESSION_BIN="startplasma-x11"; SESSION_LABEL="KDE"; SESSION_ID="plasma"
  elif command -v gnome-session >/dev/null 2>&1; then
    SESSION_BIN="gnome-session"; SESSION_LABEL="GNOME"; SESSION_ID="gnome"
  else
    return 1
  fi
  return 0
}

detect_display() {
  local socket number best=""
  for socket in /tmp/.X11-unix/X*; do
    [[ -S "${socket}" ]] || continue
    number="${socket##*X}"
    [[ "${number}" =~ ^[0-9]+$ ]] || continue
    if [[ -z "${best}" ]] || (( number < best )); then
      best="${number}"
    fi
  done
  [[ -n "${best}" ]] && printf ':%s' "${best}"
}

free_display() {
  local n
  for (( n = 1; n <= 20; n++ )); do
    if [[ ! -S "/tmp/.X11-unix/X${n}" && ! -e "/tmp/.X${n}-lock" ]]; then
      printf ':%s' "${n}"
      return 0
    fi
  done
  return 1
}

config_value() {
  local key="$1"
  [[ -f "${CONFIG_DIR}/config" ]] || return 1
  awk -F= -v k="${key}" '$1 == k { print substr($0, index($0, "=") + 1); exit }' \
    "${CONFIG_DIR}/config"
}

configured_virtual_display() {
  [[ "$(config_value MODE)" == "virtual" ]] || return 1
  local display
  display="$(config_value DISPLAY_NUM)"
  [[ "${display}" =~ ^:[0-9]+$ ]] || return 1
  printf '%s' "${display}"
}

wayland_only() {
  command -v pgrep >/dev/null 2>&1 || return 1
  if pgrep -x Xorg >/dev/null 2>&1; then
    return 1
  fi
  pgrep -x Xwayland >/dev/null 2>&1
}

is_loopback_bind() {
  case "${BIND_ADDR}" in
    127.*|localhost) return 0 ;;
    *)               return 1 ;;
  esac
}

detect_ip() {
  local ip=""
  if command -v ip >/dev/null 2>&1; then
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null \
      | awk '{ for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit } }' \
      || true)"
  fi
  if [[ -z "${ip}" ]] && command -v hostname >/dev/null 2>&1; then
    ip="$(hostname -I 2>/dev/null | awk '{ print $1 }' || true)"
  fi
  printf '%s' "${ip}"
}

gen_password() {
  local password=""
  if command -v openssl >/dev/null 2>&1; then
    password="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | cut -c1-8 || true)"
  fi
  if (( ${#password} < 8 )); then
    password="$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-8 || true)"
  fi
  printf '%s' "${password}"
}

resolve_password() {
  if [[ -n "${PASSWORD_ARG}" ]]; then
    VNC_PASSWORD="${PASSWORD_ARG}"
  elif (( ROTATE_PASSWORD == 0 )) && [[ -f "${CONFIG_DIR}/vnc-password" ]]; then
    VNC_PASSWORD="$(cat "${CONFIG_DIR}/vnc-password")"
    log "Reusing the existing VNC password (use --rotate-password to change it)"
  else
    VNC_PASSWORD="$(gen_password)"
  fi

  VNC_PASSWORD="${VNC_PASSWORD%$'\n'}"
  [[ "${VNC_PASSWORD}" != *$'\n'* ]] || die "the VNC password must not contain newlines"
  if (( ${#VNC_PASSWORD} > 8 )); then
    log "VNC authentication is limited to 8 characters; truncating the password"
    VNC_PASSWORD="${VNC_PASSWORD:0:8}"
  fi
  (( ${#VNC_PASSWORD} >= 6 )) || die "the VNC password must be at least 6 characters"
}

write_config() {
  mkdir -p "${CONFIG_DIR}" "${STATE_DIR}"
  chmod 0755 "${CONFIG_DIR}" "${STATE_DIR}"
  cat > "${CONFIG_DIR}/config" <<EOF
MODE=${MODE}
DESKTOP_USER=${DESKTOP_USER}
DISPLAY_NUM=${DISPLAY_NUM}
RESOLUTION=${RESOLUTION}
DEPTH=${DEPTH}
WEB_PORT=${WEB_PORT}
VNC_PORT=${VNC_PORT}
BIND_ADDR=${BIND_ADDR}
USE_TLS=${USE_TLS}
EOF
  chmod 0600 "${CONFIG_DIR}/config"
}

write_plain_password() {
  printf '%s\n' "${VNC_PASSWORD}" > "${CONFIG_DIR}/vnc-password"
  chmod 0600 "${CONFIG_DIR}/vnc-password"
}

write_vnc_password_file() {
  local password_file="${CONFIG_DIR}/vnc.pass"
  local passwd_bin

  if [[ "${MODE}" == "share" ]]; then
    [[ -n "${X11VNC_BIN}" ]] || die "x11vnc is not installed"
    "${X11VNC_BIN}" -storepasswd "${VNC_PASSWORD}" "${password_file}" \
      >/dev/null 2>&1 \
      || die "x11vnc could not write ${password_file}"
    chown root:root "${password_file}"
    chmod 0600 "${password_file}"
  else
    passwd_bin="$(command -v tigervncpasswd || command -v vncpasswd || true)"
    [[ -n "${passwd_bin}" ]] || die "TigerVNC password utility not found"
    printf '%s\n' "${VNC_PASSWORD}" | "${passwd_bin}" -f > "${password_file}" \
      || die "could not write ${password_file}"
    chown "${DESKTOP_USER}:${GROUP}" "${password_file}"
    chmod 0600 "${password_file}"
  fi
}

xstartup_body() {
  cat <<EOF
#!/bin/sh
# MunnaVPS native xstartup (generated by setup-native.sh)
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS

export XDG_SESSION_TYPE=x11
export XDG_CURRENT_DESKTOP=${SESSION_LABEL}
export XDG_SESSION_DESKTOP=${SESSION_ID}

# No display power saving inside a virtual session.
if command -v xset >/dev/null 2>&1; then
    xset s off -dpms >/dev/null 2>&1 || true
fi

if command -v dbus-run-session >/dev/null 2>&1; then
    exec dbus-run-session -- ${SESSION_BIN}
fi
exec ${SESSION_BIN}
EOF
}

write_vnc_launcher() {
  mkdir -p "$(dirname "${LAUNCHER}")"
  cat > "${LAUNCHER}" <<'EOF'
#!/bin/sh
# MunnaVPS virtual desktop launcher (generated by setup-native.sh).
# Xvnc and the desktop session share one systemd unit and lifecycle.
set -u
umask 077

: "${MUNNA_DISPLAY:?MUNNA_DISPLAY is not set}"
: "${MUNNA_RESOLUTION:?MUNNA_RESOLUTION is not set}"
: "${MUNNA_DEPTH:?MUNNA_DEPTH is not set}"
: "${MUNNA_VNC_PORT:?MUNNA_VNC_PORT is not set}"
: "${MUNNA_PASSWORD_FILE:?MUNNA_PASSWORD_FILE is not set}"
: "${MUNNA_XVNC:?MUNNA_XVNC is not set}"
: "${MUNNA_XSTARTUP:?MUNNA_XSTARTUP is not set}"
: "${XDG_RUNTIME_DIR:?XDG_RUNTIME_DIR is not set}"

display="${MUNNA_DISPLAY}"
display_number="${display#:}"
export DISPLAY="${display}"
export XAUTHORITY="${XDG_RUNTIME_DIR}/Xauthority"

if [ ! -d /tmp/.X11-unix ]; then
    mkdir -p /tmp/.X11-unix || exit 1
    chmod 1777 /tmp/.X11-unix 2>/dev/null || true
fi

# Remove a stale lock from an unclean stop, but never touch a live server.
lock="/tmp/.X${display_number}-lock"
if [ -f "${lock}" ]; then
    old_pid="$(tr -dc '0-9' < "${lock}" 2>/dev/null || true)"
    if [ -z "${old_pid}" ] || ! kill -0 "${old_pid}" 2>/dev/null; then
        rm -f "${lock}" "/tmp/.X11-unix/X${display_number}" 2>/dev/null || true
    fi
fi

xvnc_pid=""
session_pid=""

cleanup() {
    if [ -n "${session_pid}" ]; then
        kill "${session_pid}" 2>/dev/null || true
    fi
    if [ -n "${xvnc_pid}" ]; then
        kill "${xvnc_pid}" 2>/dev/null || true
    fi
}
trap 'cleanup; exit 0' TERM INT HUP

# Private X cookie so only the desktop session (and users with the file)
# can talk to the X server.
if ! : > "${XAUTHORITY}"; then
    echo "Could not create ${XAUTHORITY}" >&2
    exit 1
fi
cookie="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
if [ -z "${cookie}" ]; then
    echo "Could not generate an X authority cookie" >&2
    exit 1
fi
host="$(hostname)"
if ! xauth -f "${XAUTHORITY}" add "${host}/unix:${display_number}" . "${cookie}" >/dev/null \
   || ! xauth -f "${XAUTHORITY}" add "${host}:${display_number}" . "${cookie}" >/dev/null; then
    echo "Could not write ${XAUTHORITY}" >&2
    exit 1
fi

"${MUNNA_XVNC}" "${display}" \
    -geometry "${MUNNA_RESOLUTION}" \
    -depth "${MUNNA_DEPTH}" \
    -rfbauth "${MUNNA_PASSWORD_FILE}" \
    -auth "${XAUTHORITY}" \
    -localhost \
    -rfbport "${MUNNA_VNC_PORT}" \
    -SecurityTypes VncAuth \
    -AlwaysShared \
    -noreset &
xvnc_pid=$!

i=0
while [ ! -S "/tmp/.X11-unix/X${display_number}" ]; do
    if ! kill -0 "${xvnc_pid}" 2>/dev/null; then
        wait "${xvnc_pid}" 2>/dev/null || true
        exit 1
    fi
    i=$((i + 1))
    if [ "${i}" -ge 150 ]; then
        echo "Timed out waiting for X display ${display}" >&2
        cleanup
        exit 1
    fi
    sleep 0.1
done

sh "${MUNNA_XSTARTUP}" &
session_pid=$!

while kill -0 "${xvnc_pid}" 2>/dev/null \
      && kill -0 "${session_pid}" 2>/dev/null; do
    sleep 2
done

cleanup
wait "${session_pid}" 2>/dev/null || true
wait "${xvnc_pid}" 2>/dev/null || true
EOF
  chmod 0755 "${LAUNCHER}"
  chown root:root "${LAUNCHER}"
  log "Installed ${LAUNCHER}"
}

seed_xstartup() {
  local destination="${HOME_DIR}/.vnc/xstartup"
  mkdir -p "${HOME_DIR}/.vnc"
  chown "${DESKTOP_USER}:${GROUP}" "${HOME_DIR}/.vnc" 2>/dev/null || true
  chmod 0700 "${HOME_DIR}/.vnc"

  xstartup_body > "${CONFIG_DIR}/xstartup"
  chmod 0755 "${CONFIG_DIR}/xstartup"

  if [[ -f "${destination}" ]] \
     && ! grep -q 'MunnaVPS native xstartup' "${destination}"; then
    log "Keeping the existing ${destination}"
    return 0
  fi
  install -o "${DESKTOP_USER}" -g "${GROUP}" -m 0755 \
    "${CONFIG_DIR}/xstartup" "${destination}"
  log "Installed ${destination}"
}

setup_tls() {
  local host ip san
  host="$(hostname -s 2>/dev/null || hostname 2>/dev/null || true)"
  [[ -n "${host}" ]] || host="localhost"
  mkdir -p "${TLS_DIR}"
  chmod 0700 "${TLS_DIR}"

  san="DNS:${host},DNS:localhost,IP:127.0.0.1"
  ip="$(detect_ip)"
  if [[ -n "${ip}" && "${ip}" != 127.* ]]; then
    san="${san},IP:${ip}"
  fi
  if [[ "${BIND_ADDR}" != "0.0.0.0" && "${BIND_ADDR}" != 127.* ]]; then
    if [[ "${BIND_ADDR}" =~ ^[0-9.]+$ ]]; then
      san="${san},IP:${BIND_ADDR}"
    else
      san="${san},DNS:${BIND_ADDR}"
    fi
  fi

  if [[ -f "${TLS_DIR}/cert.pem" && -f "${TLS_DIR}/key.pem" \
        && -f "${TLS_DIR}/san" ]] \
     && [[ "$(cat "${TLS_DIR}/san")" == "${san}" ]]; then
    log "Reusing the existing TLS certificate"
    return 0
  fi

  log "Creating a self-signed TLS certificate for ${host}"
  openssl req -x509 -nodes -newkey rsa:2048 -sha256 -days 825 \
    -keyout "${TLS_DIR}/key.pem" -out "${TLS_DIR}/cert.pem" \
    -subj "/CN=${host}" -addext "subjectAltName=${san}" >/dev/null 2>&1 \
    || die "openssl could not create the TLS certificate"
  printf '%s\n' "${san}" > "${TLS_DIR}/san"
  chmod 0600 "${TLS_DIR}/key.pem"
  chmod 0644 "${TLS_DIR}/cert.pem" "${TLS_DIR}/san"
}

write_web_dir() {
  local item base target
  rm -rf "${WEB_DIR}"
  mkdir -p "${WEB_DIR}"

  for item in "${NOVNC_DIR}"/*; do
    [[ -e "${item}" ]] || continue
    base="$(basename "${item}")"
    ln -s "${item}" "${WEB_DIR}/${base}"
  done

  target="vnc.html"
  [[ -f "${NOVNC_DIR}/vnc.html" ]] || target="vnc_lite.html"

  # Replace the symlinked index with a redirect that auto-connects.
  rm -f "${WEB_DIR}/index.html"
  cat > "${WEB_DIR}/index.html" <<EOF
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>MunnaVPS</title>
<meta http-equiv="refresh" content="0; url=${target}?autoconnect=1&amp;resize=scale">
</head>
<body>
<p>Opening the desktop...</p>
<p><a href="${target}?autoconnect=1&amp;resize=scale">Continue</a></p>
</body>
</html>
EOF
  chmod 0755 "${WEB_DIR}"
}

write_units() {
  local vnc_exec web_cmd

  if [[ "${MODE}" == "share" ]]; then
    vnc_exec="${X11VNC_BIN} -display ${DISPLAY_NUM} -auth ${XAUTH}"
    vnc_exec+=" -rfbauth ${CONFIG_DIR}/vnc.pass -rfbport ${VNC_PORT}"
    vnc_exec+=" -localhost -forever -shared -repeat -norc -noxrecord -noxfixes"
    vnc_exec+=" -desktop \"MunnaVPS physical desktop\""

    cat > "${UNIT_DIR}/munnavps-vnc.service" <<EOF
[Unit]
Description=MunnaVPS VNC backend (x11vnc, display ${DISPLAY_NUM})
Documentation=https://github.com/arafsk/MunnaVPS
After=display-manager.service network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=${vnc_exec}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  else
    cat > "${UNIT_DIR}/munnavps-vnc.service" <<EOF
[Unit]
Description=MunnaVPS virtual desktop (TigerVNC, display ${DISPLAY_NUM})
Documentation=https://github.com/arafsk/MunnaVPS
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=${DESKTOP_USER}
Group=${GROUP}
Environment="HOME=${HOME_DIR}"
Environment="USER=${DESKTOP_USER}"
Environment="LOGNAME=${DESKTOP_USER}"
Environment="SHELL=/bin/bash"
Environment="XDG_RUNTIME_DIR=/run/munnavps"
Environment="MUNNA_DISPLAY=${DISPLAY_NUM}"
Environment="MUNNA_RESOLUTION=${RESOLUTION}"
Environment="MUNNA_DEPTH=${DEPTH}"
Environment="MUNNA_VNC_PORT=${VNC_PORT}"
Environment="MUNNA_PASSWORD_FILE=${CONFIG_DIR}/vnc.pass"
Environment="MUNNA_XVNC=${XVNC_BIN}"
Environment="MUNNA_XSTARTUP=${HOME_DIR}/.vnc/xstartup"
RuntimeDirectory=munnavps
RuntimeDirectoryMode=0700
WorkingDirectory="${HOME_DIR}"
ExecStart=${LAUNCHER}
Restart=always
RestartSec=5
KillMode=mixed
TimeoutStopSec=20

[Install]
WantedBy=multi-user.target
EOF
  fi
  chmod 0644 "${UNIT_DIR}/munnavps-vnc.service"

  web_cmd="${WEBSOCKIFY_CMD} --web=${WEB_DIR}"
  if (( USE_TLS == 1 )); then
    web_cmd+=" --cert=${TLS_DIR}/cert.pem --key=${TLS_DIR}/key.pem"
  fi
  web_cmd+=" ${BIND_ADDR}:${WEB_PORT} 127.0.0.1:${VNC_PORT}"

  cat > "${UNIT_DIR}/munnavps-web.service" <<EOF
[Unit]
Description=MunnaVPS noVNC web gateway
Documentation=https://github.com/arafsk/MunnaVPS
After=network-online.target munnavps-vnc.service
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=${web_cmd}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "${UNIT_DIR}/munnavps-web.service"
}

start_services() {
  systemctl daemon-reload
  systemctl reset-failed munnavps-vnc.service munnavps-web.service >/dev/null 2>&1 || true
  systemctl enable munnavps-vnc.service munnavps-web.service >/dev/null \
    || die "could not enable the MunnaVPS services"
  if ! systemctl restart munnavps-vnc.service; then
    show_logs
    die "the VNC backend failed to start"
  fi
  if ! systemctl restart munnavps-web.service; then
    show_logs
    die "the noVNC gateway failed to start"
  fi
}

show_logs() {
  systemctl --no-pager --lines=30 --full status \
    munnavps-vnc.service munnavps-web.service 2>/dev/null || true
  journalctl --no-pager --lines=40 -u munnavps-vnc.service \
    -u munnavps-web.service 2>/dev/null || true
}

wait_for_vnc() {
  local i
  for (( i = 0; i < 30; i++ )); do
    if ( exec 3<>"/dev/tcp/127.0.0.1/${VNC_PORT}" ) 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_for_web() {
  local i scheme
  scheme="http"
  (( USE_TLS == 1 )) && scheme="https"
  for (( i = 0; i < 20; i++ )); do
    if curl -fsSk --max-time 3 -o /dev/null "${scheme}://127.0.0.1:${WEB_PORT}/"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

verify_runtime() {
  log "Verifying the services"
  if ! wait_for_vnc; then
    show_logs
    die "the VNC backend is not listening on 127.0.0.1:${VNC_PORT}"
  fi
  if ! wait_for_web; then
    show_logs
    die "the noVNC gateway is not answering on port ${WEB_PORT}"
  fi
  if ! systemctl is-active --quiet munnavps-vnc.service \
     || ! systemctl is-active --quiet munnavps-web.service; then
    show_logs
    die "a MunnaVPS service is not active"
  fi
  log "VNC backend and noVNC gateway are up"
}

open_firewall() {
  if command -v ufw >/dev/null 2>&1 \
     && ufw status 2>/dev/null | grep -q 'Status: active'; then
    ufw allow "${WEB_PORT}/tcp" >/dev/null || die "ufw could not open port ${WEB_PORT}"
    log "ufw: allowed TCP ${WEB_PORT}"
  elif command -v firewall-cmd >/dev/null 2>&1 \
       && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${WEB_PORT}/tcp" >/dev/null \
      || die "firewalld could not open port ${WEB_PORT}"
    firewall-cmd --reload >/dev/null || die "firewalld reload failed"
    log "firewalld: allowed TCP ${WEB_PORT}"
  else
    log "No active ufw/firewalld detected; open TCP ${WEB_PORT} yourself if needed."
  fi
}

print_summary() {
  local scheme host url mode_label
  scheme="http"
  (( USE_TLS == 1 )) && scheme="https"

  if is_loopback_bind; then
    host="localhost"
  elif [[ "${BIND_ADDR}" != "0.0.0.0" ]]; then
    host="${BIND_ADDR}"
  else
    host="$(detect_ip)"
    if [[ -z "${host}" ]]; then
      host="$(hostname -s 2>/dev/null || hostname 2>/dev/null || true)"
    fi
    [[ -n "${host}" ]] || host="localhost"
  fi
  url="${scheme}://${host}:${WEB_PORT}/"

  if [[ "${MODE}" == "share" ]]; then
    mode_label="share (physical display ${DISPLAY_NUM})"
  else
    mode_label="virtual (TigerVNC, display ${DISPLAY_NUM})"
  fi

  cat <<EOF

  MunnaVPS native setup complete.

  Mode        : ${mode_label}
  Access URL  : ${url}
  Login       : VNC password only (no username)
  Password    : sudo bash "${SCRIPT_PATH}" --print-password
  Password file: ${CONFIG_DIR}/vnc-password (root only)
  Services    : systemctl status munnavps-vnc munnavps-web
  Logs        : journalctl -u munnavps-vnc -u munnavps-web -f
  Timeouts    : none (no idle or session timeout)

EOF

  if is_loopback_bind; then
    cat <<EOF
  The web port is bound to 127.0.0.1. From another machine, tunnel it:
      ssh -L ${WEB_PORT}:127.0.0.1:${WEB_PORT} ${DESKTOP_USER}@<this-host>
  then open http://localhost:${WEB_PORT}/

EOF
  elif (( USE_TLS == 0 )); then
    cat <<EOF
  WARNING: plain HTTP is exposed on the network. Use --tls (and a VPN where
  possible); VNC authentication alone is not strong.

EOF
  fi

  if (( USE_TLS == 1 )); then
    cat <<EOF
  HTTPS uses a self-signed certificate; the browser will show one warning.
  Native VNC clients are loopback-only; tunnel them with:
      ssh -L ${VNC_PORT}:127.0.0.1:${VNC_PORT} ${DESKTOP_USER}@<this-host>

EOF
  fi
}

uninstall_native() {
  log "Stopping and removing MunnaVPS native services"
  systemctl disable --now munnavps-web.service munnavps-vnc.service \
    >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/munnavps-vnc.service \
        /etc/systemd/system/munnavps-web.service \
        "${LAUNCHER}" \
        /usr/local/bin/munnavps-websockify
  systemctl daemon-reload
  systemctl reset-failed munnavps-vnc.service munnavps-web.service \
    >/dev/null 2>&1 || true
  rm -rf "${STATE_DIR}" "${CONFIG_DIR}"
  log "Removed the unit files, ${CONFIG_DIR}, and ${STATE_DIR}."
  log "The user's home directory and ~/.vnc/xstartup were left untouched."
}

# --- Argument parsing -------------------------------------------------------
parse_args() {
  while (( $# > 0 )); do
    case "$1" in
      --share)              MODE="share"; shift ;;
      --virtual)            MODE="virtual"; shift ;;
      --mode)               MODE="${2:?--mode needs a value}"; shift 2 ;;
      --user)               DESKTOP_USER="${2:?--user needs a value}"; shift 2 ;;
      --display)            DISPLAY_NUM="${2:?--display needs a value}"; shift 2 ;;
      --resolution)         RESOLUTION="${2:?--resolution needs a value}"; shift 2 ;;
      --depth)              DEPTH="${2:?--depth needs a value}"; shift 2 ;;
      --port)               WEB_PORT="${2:?--port needs a value}"; shift 2 ;;
      --vnc-port)           VNC_PORT="${2:?--vnc-port needs a value}"; shift 2 ;;
      --bind)               BIND_ADDR="${2:?--bind needs a value}"; shift 2 ;;
      --password)           PASSWORD_ARG="${2:?--password needs a value}"; shift 2 ;;
      --xauth)              XAUTH="${2:?--xauth needs a value}"; shift 2 ;;
      --tls)                USE_TLS=1; shift ;;
      --insecure)           INSECURE=1; shift ;;
      --force)              FORCE=1; shift ;;
      --open-firewall)      OPEN_FW=1; shift ;;
      --install-desktop)    INSTALL_DESKTOP=1; shift ;;
      --rotate-password)    ROTATE_PASSWORD=1; shift ;;
      --print-password)     PRINT_PW=1; shift ;;
      --uninstall)          UNINSTALL=1; shift ;;
      -h|--help)            usage; exit 0 ;;
      *)                    die "unknown option: $1 (try --help)" ;;
    esac
  done
}

# --- Main -------------------------------------------------------------------
main() {
  local self
  parse_args "$@"

  if (( EUID != 0 )); then
    self="${BASH_SOURCE[0]:-$0}"
    if [[ -f "${self}" ]] && command -v sudo >/dev/null 2>&1; then
      self="$(cd -- "$(dirname -- "${self}")" && pwd)/$(basename -- "${self}")"
      exec sudo -- "$(command -v bash)" "${self}" "$@"
    fi
    die "this script must run as root (use sudo)"
  fi

  if (( PRINT_PW == 1 )); then
    [[ -r "${CONFIG_DIR}/vnc-password" ]] \
      || die "no stored password; run the setup first"
    cat "${CONFIG_DIR}/vnc-password"
    exit 0
  fi

  [[ "$(uname -s)" == "Linux" ]] || die "this script targets Linux"
  [[ -d /run/systemd/system ]] || die "systemd is required"

  if (( UNINSTALL == 1 )); then
    uninstall_native
    exit 0
  fi

  SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
  if [[ -f "${SCRIPT_PATH}" ]]; then
    SCRIPT_PATH="$(cd -- "$(dirname -- "${SCRIPT_PATH}")" && pwd)/$(basename -- "${SCRIPT_PATH}")"
  fi

  case "${MODE}" in
    share|virtual) ;;
    *) die "--mode must be 'share' or 'virtual'" ;;
  esac
  [[ "${BIND_ADDR}" =~ ^[0-9A-Za-z.-]+$ ]] \
    || die "--bind must be an IPv4 address or hostname"
  [[ "${BIND_ADDR}" != "localhost" ]] || BIND_ADDR="127.0.0.1"
  if ! [[ "${WEB_PORT}" =~ ^[0-9]+$ ]] \
     || (( WEB_PORT < 1 || WEB_PORT > 65535 )); then
    die "--port must be 1-65535"
  fi
  if ! [[ "${VNC_PORT}" =~ ^[0-9]+$ ]] \
     || (( VNC_PORT < 1 || VNC_PORT > 65535 )); then
    die "--vnc-port must be 1-65535"
  fi
  (( WEB_PORT != VNC_PORT )) || die "--port and --vnc-port must differ"
  if [[ "${MODE}" == "virtual" ]] && (( VNC_PORT < 1024 )); then
    die "the virtual backend runs as a normal user; --vnc-port must be >= 1024"
  fi
  [[ "${RESOLUTION}" =~ ^[1-9][0-9]*x[1-9][0-9]*$ ]] \
    || die "--resolution must look like 1920x1080"
  [[ "${DEPTH}" =~ ^(16|24|32)$ ]] || die "--depth must be 16, 24 or 32"
  if [[ -n "${DISPLAY_NUM}" ]]; then
    [[ "${DISPLAY_NUM}" =~ ^:[0-9]+$ ]] || die "--display must look like :0"
    DISPLAY_EXPLICIT=1
  else
    DISPLAY_EXPLICIT=0
  fi

  DESKTOP_USER="${DESKTOP_USER:-$(default_user)}"
  [[ -n "${DESKTOP_USER}" ]] \
    || die "could not detect the desktop user; pass --user <name>"
  [[ "${DESKTOP_USER}" =~ ^[A-Za-z_][A-Za-z0-9._-]*$ ]] \
    || die "invalid username: ${DESKTOP_USER}"
  [[ "${DESKTOP_USER}" != "root" ]] \
    || die "refusing to use root as the desktop user; pass --user <name>"
  id -u "${DESKTOP_USER}" >/dev/null 2>&1 \
    || die "user '${DESKTOP_USER}' does not exist (create it first)"
  HOME_DIR="$(getent passwd "${DESKTOP_USER}" | cut -d: -f6)"
  [[ -n "${HOME_DIR}" && -d "${HOME_DIR}" ]] \
    || die "home directory for '${DESKTOP_USER}' was not found"
  GROUP="$(id -gn "${DESKTOP_USER}")"

  PKG="$(detect_pkg_manager)" \
    || die "no supported package manager (apt, dnf, pacman, zypper)"
  log "Distro package manager: ${PKG}"

  if (( INSTALL_DESKTOP == 1 )) && [[ "${MODE}" == "share" ]]; then
    log "Ignoring --install-desktop in share mode"
  fi

  if ! is_loopback_bind && (( USE_TLS == 0 && INSECURE == 0 )); then
    die "refusing to expose noVNC without TLS; add --tls (or --insecure on a trusted network)"
  fi

  if [[ "${MODE}" == "share" ]]; then
    DISPLAY_NUM="${DISPLAY_NUM:-$(detect_display)}"
    [[ -n "${DISPLAY_NUM}" ]] \
      || die "no X11 display found; log in to an X11 session or use --virtual"
    if (( DISPLAY_EXPLICIT == 1 )) \
       && [[ ! -S "/tmp/.X11-unix/X${DISPLAY_NUM#:}" ]]; then
      die "display ${DISPLAY_NUM} is not available; log in or omit --display"
    fi
    if wayland_only; then
      if (( FORCE == 0 )); then
        die "a Wayland session was detected; x11vnc can only capture XWayland apps. Use --virtual for a full desktop, log in with Xorg, or add --force"
      fi
      log "WARNING: Wayland detected; only XWayland applications will be visible"
    fi
    if [[ "${XAUTH}" != "guess" ]]; then
      [[ "${XAUTH}" == /* ]] || die "--xauth must be an absolute path"
      [[ "${XAUTH}" =~ ^[A-Za-z0-9._/-]+$ ]] \
        || die "--xauth may only contain letters, digits, '.', '_', '/', and '-'"
      [[ -f "${XAUTH}" ]] || die "X authority file not found: ${XAUTH}"
    fi
    log "Sharing X display ${DISPLAY_NUM}"
  else
    if [[ -z "${DISPLAY_NUM}" ]]; then
      DISPLAY_NUM="$(configured_virtual_display || true)"
    fi
    if [[ -z "${DISPLAY_NUM}" ]]; then
      DISPLAY_NUM="$(free_display || true)"
    fi
    [[ -n "${DISPLAY_NUM}" ]] || die "no free X display found (1-20)"
    if (( DISPLAY_EXPLICIT == 1 )) \
       && [[ -S "/tmp/.X11-unix/X${DISPLAY_NUM#:}" \
              || -e "/tmp/.X${DISPLAY_NUM#:}-lock" ]]; then
      die "display ${DISPLAY_NUM} is already in use; omit --display to auto-pick"
    fi
    log "Virtual desktop will use display ${DISPLAY_NUM}"
  fi

  resolve_password
  mkdir -p "${CONFIG_DIR}" "${STATE_DIR}" "${TLS_DIR}"
  write_config
  write_plain_password

  install_base_packages
  install_websockify
  install_novnc

  WEBSOCKIFY_CMD=""
  if [[ -n "${WEBSOCKIFY_WRAPPER:-}" && -x "${WEBSOCKIFY_WRAPPER}" ]]; then
    WEBSOCKIFY_CMD="${WEBSOCKIFY_WRAPPER}"
  elif command -v websockify >/dev/null 2>&1; then
    WEBSOCKIFY_CMD="$(command -v websockify)"
  elif command -v python3 >/dev/null 2>&1 \
       && python3 -c 'import websockify' >/dev/null 2>&1; then
    WEBSOCKIFY_CMD="$(command -v python3) -m websockify"
  fi
  [[ -n "${WEBSOCKIFY_CMD}" ]] \
    || die "websockify is not installed; install the websockify package"

  if [[ "${MODE}" == "share" ]]; then
    X11VNC_BIN="$(command -v x11vnc || true)"
    [[ -n "${X11VNC_BIN}" ]] || die "x11vnc is not installed"
  else
    XVNC_BIN="$(command -v Xvnc || true)"
    [[ -n "${XVNC_BIN}" ]] || die "TigerVNC Xvnc is not installed"
    if ! find_session; then
      if (( INSTALL_DESKTOP == 1 )); then
        install_desktop
        find_session || die "XFCE was installed but no session launcher was found"
      else
        die "no desktop environment found; install XFCE or re-run with --install-desktop"
      fi
    fi
    log "Virtual session: ${SESSION_LABEL} (${SESSION_BIN})"
    seed_xstartup
    write_vnc_launcher
  fi

  write_vnc_password_file

  if (( USE_TLS == 1 )); then
    setup_tls
  fi

  write_web_dir
  write_units
  start_services
  verify_runtime

  if (( OPEN_FW == 1 )); then
    open_firewall
  fi

  print_summary
}

main "$@"
