#!/bin/sh
# Launch the TigerVNC server on display :1 in the foreground (supervisord owns
# the lifecycle). Debian/Ubuntu name the wrapper tigervncserver; some builds
# also install vncserver.
set -eu

if command -v tigervncserver >/dev/null 2>&1; then
    VNCSERVER="$(command -v tigervncserver)"
elif command -v vncserver >/dev/null 2>&1; then
    VNCSERVER="$(command -v vncserver)"
else
    echo "Neither tigervncserver nor vncserver is installed" >&2
    exit 1
fi

exec "${VNCSERVER}" :1 \
    -geometry "${VNC_RESOLUTION:-1920x1080}" \
    -depth "${VNC_DEPTH:-24}" \
    -fg
