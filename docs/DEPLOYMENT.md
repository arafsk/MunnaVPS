# Deployment

## 1. Prepare the host

A small Linux VPS or home server works. Recommended baseline: 2 vCPU, 4 GB
RAM, 20 GB disk.

```bash
# Docker Engine + Compose plugin (Debian/Ubuntu)
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker "$USER"
newgrp docker

docker version
docker compose version
```

Open only the ports you need:

```bash
# UFW example
sudo ufw allow 22/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw enable
```

Do **not** open 6901 or 6080; they are internal to Docker.

## 2. Get the project

```bash
git clone git@github.com:arafsk/MunnaVPS.git
cd MunnaVPS
```

## 3. Configure

```bash
make setup
```

This creates `.env`, generates a 24-character password, detects your timezone
on Linux, and creates `data/desktop`, `data/caddy/*`, and `backups/`.

Useful options:

```bash
./scripts/setup.sh --domain desktop.example.com
./scripts/setup.sh --http-port 8080 --tz Asia/Dhaka --user munna
# or via make:
make setup ARGS="--domain desktop.example.com"
```

Or edit `.env` afterwards. Key values:

```dotenv
SITE_ADDRESS=:80            # or desktop.example.com
DESKTOP_USER=munna
VNC_PASSWORD=<from .env>
DESKTOP_MEM_LIMIT=4g
```

## 4. DNS and TLS

For automatic HTTPS:

1. Create an `A` (and optionally `AAAA`) record for `desktop.example.com`
   pointing at the host.
2. Ensure inbound TCP 80 and 443 reach the host.
3. Set `SITE_ADDRESS=desktop.example.com` in `.env`.
4. Run `make up`.

Caddy requests a certificate on first start, stores it in
`./data/caddy/data`, and renews it automatically. Watch progress with:

```bash
make logs
```

If issuance fails, check DNS propagation (`dig +short desktop.example.com`),
port reachability, and that no other web server is holding 80/443.

## 5. Start

```bash
make up
make health
```

First build takes several minutes. Expected output from health:

```text
[munna-vps] OK   munna-vps-desktop: running (healthy)
[munna-vps] OK   munna-vps-caddy: running (healthy)
[munna-vps] OK   https://desktop.example.com -> HTTP 200
[munna-vps] Stack is healthy.
```

Open the URL, log in with `DESKTOP_USER` and `VNC_PASSWORD`.

## 6. First-login checklist

- Change the default resolution if it does not fit your screen (`VNC_RESOLUTION`).
- Update the OS packages inside the desktop:

  ```bash
  sudo apt-get update && sudo apt-get upgrade -y
  ```

- Install your apps with `sudo apt-get install ...`. Files, browser profiles,
  and user settings under `/home/<user>` persist across container recreation,
  but **system packages do not** — apt installs live in the image layer. For
  permanent software, add packages to `docker/desktop/Dockerfile` and rebuild,
  or install per-user (AppImage, `~/.local`, Flatpak user installs).
- Bookmark `make backup` in your routine.

> Files, browser profiles, and config under `/home/<user>` persist. System
> packages and `/etc` changes do not survive `make up` recreating the
> container.

## 7. Start on boot

Both containers use `restart: unless-stopped`, so Docker starts them after a
reboot as long as the Docker service is enabled:

```bash
sudo systemctl enable --now docker
```

## 8. Updates

```bash
# from the repo root
git pull --ff-only
make update       # rebuild with --pull, recreate, health check
```

`make update` rebuilds the desktop image, which picks up new Ubuntu/KasmVNC
packages from the base layers. Since the Ubuntu tag is `latest`, this can
occasionally pull a new distro release; pin `UBUNTU_TAG` in `.env` if you want
controlled upgrades.

### Pin versions for production

```dotenv
UBUNTU_TAG=24.04
KASMVNC_VERSION=1.5.2
IMAGE_TAG=2026-11
# Optional: bypass release resolution with a direct .deb URL
# KASMVNC_ASSET_URL=https://github.com/kasmtech/KasmVNC/releases/download/v1.5.2/kasmvncserver_ubuntu_noble_1.5.2_amd64.deb
```

Then `make up` builds a reproducible image.

## 9. Behind another reverse proxy

If you already run Nginx/Traefik on the host, do not publish Caddy on 80/443.
Instead:

1. Set `SITE_ADDRESS=:8080` in `.env` and `HTTP_PORT=8080`.
2. Point the existing proxy at `http://127.0.0.1:8080`.
3. Ensure the outer proxy forwards WebSocket upgrades and sets
   `X-Forwarded-For` to the real client address.

Caddy still serves plain HTTP inside that path; put TLS at the outer proxy.

## 10. Fallback backend

If KasmVNC has no package for your platform (for example a brand-new Ubuntu
release or unusual architecture):

```bash
make up-tigervnc
```

This reuses the same base image with TigerVNC + noVNC. noVNC's password prompt
appears inside the page, and the KasmVNC login name is not used (only the VNC
password).

## 11. Uninstall

```bash
make down
# data remains in ./data; remove it manually when you are sure
```
