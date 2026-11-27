# Usage

# Share the current X11 desktop
sudo ./scripts/setup-native.sh

# Dedicated virtual desktop on a headless/Wayland machine
sudo ./scripts/setup-native.sh --virtual --install-desktop

# LAN access with TLS and firewall opened
sudo ./scripts/setup-native.sh --bind 0.0.0.0 --tls --open-firewall

# Show the generated password
sudo ./scripts/setup-native.sh --print-password

# Remove services and config
sudo ./scripts/setup-native.sh --uninstall

# It installs:

/etc/systemd/system/munnavps-vnc.service
/etc/systemd/system/munnavps-web.service
/etc/munnavps/ config + password files
/usr/local/bin/munnavps-start-vnc for virtual mode
Package support covers apt, dnf, pacman, and zypper, with a pip fallback for distros without a websockify package.

# Important notes

Share mode needs an X11 session. On GNOME/KDE Wayland it stops with guidance — use --virtual or log in with Xorg.
VNC authentication truncates passwords to 8 characters, so the native script generates an 8-character password.
Default bind is 127.0.0.1; use --bind 0.0.0.0 --tls for LAN access.
Syntax/shellcheck and the Xvnc launcher lifecycle were verified, but I could not run it on a real Linux host in this session. Runtime testing on the target machine is the remaining step.
Committed as 970df1a and pushed to origin/main; AGENTS.md records the new script and pending runtime verification.