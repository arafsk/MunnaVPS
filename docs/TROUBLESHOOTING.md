# Troubleshooting

Start with:

```bash
make ps
make health
make logs
```

## Build fails while installing KasmVNC

Symptom:

```text
ERROR: no KasmVNC .deb for ubuntu <codename> (<arch>).
```

Cause: a new Ubuntu release or architecture is not yet covered by KasmVNC
release assets.

Fixes, in order:

1. **Use the fallback backend** (works on any Ubuntu architecture):

   ```bash
   make up-tigervnc
   ```

2. **Pin a supported base**:

   ```dotenv
   UBUNTU_TAG=24.04
   ```

   Then `make up`.

3. **Pin a KasmVNC version** whose assets include your platform:

   ```dotenv
   KASMVNC_VERSION=1.5.2
   ```

4. **Override the asset URL** entirely (works if release naming changes):

   ```dotenv
   KASMVNC_ASSET_URL=https://github.com/kasmtech/KasmVNC/releases/download/v1.5.2/kasmvncserver_ubuntu_resolute_1.5.2_arm64.deb
   ```

Check available assets:
<https://github.com/kasmtech/KasmVNC/releases>.

> A previous API-rate-limit failure ("no KasmVNC .deb") was caused by GitHub's
> 60 requests/hour unauthenticated limit. The build now resolves the release
> through the public redirect instead, so this should no longer happen.

## Port 80 or 443 already in use

```text
Error response from daemon: ... bind: address already in use
```

Find the listener:

```bash
sudo ss -ltnp | grep ':80\|:443'
```

Either stop the conflicting service or change ports in `.env`:

```dotenv
HTTP_PORT=8080
HTTPS_PORT=8443
SITE_ADDRESS=:80
```

Then `make up` and open `http://host:8080`.

## Certificate is not issued

`make logs` shows ACME failures.

- DNS must resolve to the host: `dig +short desktop.example.com`.
- Inbound TCP 80 and 443 must reach Caddy (firewall, NAT, cloud security group).
- No other process may hold ports 80/443.
- Rate limits: Let's Encrypt limits duplicate certificates; wait or use the
  staging CA while testing.
- Cloudflare proxying can interfere with HTTP-01; set the record to
  "DNS only" until the certificate is issued.

## Login page loops / 401 after entering the password

- Confirm `DESKTOP_USER` and `VNC_PASSWORD` from `.env`.
- Recreate so the password file is rewritten:

  ```bash
  make up
  ```

- Check for stray whitespace in `.env` (no quotes are needed around values).
- Try a private window; a cached Basic Auth credential can mask changes.

## Desktop is black or never appears

1. Check the session log:

   ```bash
   tail -50 data/desktop/.vnc/*.log
   ```

2. Check processes:

   ```bash
   docker compose exec desktop bash -c 'ps aux | grep -E "Xvnc|xfce|startxfce4"'
   ```

3. Look for display locks:

   ```bash
   ls -l data/desktop/.vnc/ /tmp/.X1-lock
   ```

   The entrypoint clears stale locks on start; if you removed them manually,
   restart the container.

4. A corrupted XFCE config can block startup. Back up and reset:

   ```bash
   mv data/desktop/.config/xfce4 data/desktop/.config/xfce4.bak
   make restart
   ```

## Firefox tabs crash immediately

Shared memory is too small. Ensure:

```dotenv
DESKTOP_SHM_SIZE=2gb
```

and that `shm_size` is applied (`docker inspect munna-vps-desktop | grep -i shm`).

## Permission denied writing files in the desktop

UID/GID mismatch between the host directory and the container user:

```bash
id -u
id -g
```

Set matching values in `.env` (`PUID`, `PGID`), then `make up`. The entrypoint
will recursively fix ownership on the next start.

On macOS, files appear with host ownership through the Docker VM; this is
normal and does not affect the desktop.

## WebSocket 400 / "connection closed" through a proxy

When placing another reverse proxy in front of Caddy, enable:

- HTTP/1.1 to the upstream.
- `Upgrade` and `Connection` header forwarding.
- Long read/send timeouts (at least 30 minutes).

Caddy itself handles this automatically.

## Everything works, but the desktop resets after `make up`

The home directory persists, but the **container filesystem does not**. Packages
installed with `apt` and changes outside `/home/<user>` are lost when the
container is recreated. To persist software:

- Add packages to `docker/desktop/Dockerfile`, or
- install into the home directory (e.g. `~/.local/bin`, AppImage, Flatpak
  user installs), or
- rebuild the image intentionally with `make build`.

## `docker compose` permission denied

```bash
sudo usermod -aG docker "$USER"
newgrp docker
```

Log out and back in if needed.

## High CPU with no one connected

KasmVNC only encodes when a client is attached. Check for runaway apps:

```bash
docker stats munna-vps-desktop
docker compose exec desktop top
```

Use `make shell` to kill the offending process.

## Native (no-Docker) mode

`scripts/setup-native.sh` runs on the host, not in a container. Start with:

```bash
systemctl status munnavps-vnc munnavps-web
journalctl -u munnavps-vnc -u munnavps-web -n 50 --no-pager
```

### `Unit munnavps-vnc.service has a bad unit file setting`

On systemd this usually means a quoted path in a setting that does not strip
quotes, for example `WorkingDirectory="/home/user"`. Pull the current script
(fixed 2026-11-27) and re-run it; it regenerates both units.

### `the VNC backend failed to start` with `BadAccess ... MIT-SHM`

Symptom in `journalctl -u munnavps-vnc`:

```text
X Error of failed request:  BadAccess (attempt to access private resource denied)
  Major opcode of failed request:  131 (MIT-SHM)
```

Cause: x11vnc runs as root against an X server owned by the desktop user, so
mit-shm access is denied. The script passes `-noshm` since 2026-11-27. If you
generated the units with an older copy, re-run the setup.

### `-auth guess: failed for display=':0'`

x11vnc's built-in guess only looks at root's files and the XDM locations, so a
user-owned `~/.Xauthority` (startx, XFCE, lightdm) is not found. The script
detects `~/.Xauthority`, gdm, lightdm and xdm paths automatically. If detection
still misses your display manager, pass the file explicitly:

```bash
sudo scripts/setup-native.sh --display :0 --xauth /home/munna/.Xauthority
```

### Share mode finds no display

Share mode attaches x11vnc to an existing X11 session, so it needs a logged-in
Xorg/XFCE desktop. Over SSH with no session, use the virtual backend instead:

```bash
sudo scripts/setup-native.sh --virtual --install-desktop
```

## Reset everything (destructive)

```bash
make down
mv data/desktop data/desktop.old.$(date +%s)
make up
```

This starts from a fresh home directory while keeping the old one for
inspection.
