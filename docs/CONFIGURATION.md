# Configuration

All runtime configuration lives in `.env` at the repository root. `make setup`
generates it from `.env.example`; edit it and run `make up` again to apply.

## Access

| Variable | Default | Description |
| --- | --- | --- |
| `SITE_ADDRESS` | `:80` | Address Caddy serves. `:80` = plain HTTP; `desktop.example.com` = automatic HTTPS; `localhost` = HTTPS with Caddy's internal CA. |
| `HTTP_PORT` | `80` | Host port mapped to container port 80. |
| `HTTPS_PORT` | `443` | Host port mapped to container ports 443/tcp and 443/udp. |

### Examples

**LAN / VPN / raw IP**

```dotenv
SITE_ADDRESS=:80
HTTP_PORT=80
```

Open `http://<host-ip>/`.

**Public domain with automatic TLS**

```dotenv
SITE_ADDRESS=desktop.example.com
HTTP_PORT=80
HTTPS_PORT=443
```

Requirements: DNS `A`/`AAAA` points to the host; inbound TCP 80 and 443 are
open (Caddy needs 80 for the ACME HTTP challenge and TLS-ALPN).

**Local HTTPS (self-signed internal CA)**

```dotenv
SITE_ADDRESS=localhost
HTTPS_PORT=443
```

The browser warns until you trust Caddy's local root certificate:
`docker compose exec caddy cat /data/caddy/pki/authorities/local/root.crt`.

**Non-standard host port**

```dotenv
SITE_ADDRESS=:80
HTTP_PORT=8080
```

Open `http://<host>:8080/`. TLS is still terminated by Caddy if you use a
domain, but the host port mapping must match your URL.

## Desktop user and login

| Variable | Default | Description |
| --- | --- | --- |
| `DESKTOP_USER` | `munna` | Linux account, home directory name, and KasmVNC username. Lowercase letters, digits, `_`, `-`. |
| `PUID` | `1000` | UID for the desktop user inside the container. Match your Linux host user to avoid permission friction. |
| `PGID` | `1000` | GID for the desktop user. |
| `VNC_PASSWORD` | generated | KasmVNC password, minimum 6 characters. `make setup` generates 24 random alphanumerics. |

Changing `DESKTOP_USER` changes the bind-mount target
(`/home/<DESKTOP_USER>`); the compose file interpolates it. Existing data stays
in the old directory, so move it manually if you rename the user.

Changing `PUID`/`PGID` makes the entrypoint recursively fix ownership of the
home directory on the next start.

### Change the password

```bash
# 1. edit VNC_PASSWORD in .env
# 2. recreate the container so the entrypoint rewrites ~/.kasmpasswd
make up
```

The password file is regenerated on every container start, so it always
matches `.env`.

## Session

| Variable | Default | Description |
| --- | --- | --- |
| `TZ` | `UTC` | Container timezone (e.g. `Europe/Berlin`, `Asia/Dhaka`). |
| `VNC_RESOLUTION` | `1920x1080` | Initial desktop size. KasmVNC also resizes to the browser window because `desktop.allow_resize` is enabled. |
| `VNC_DEPTH` | `24` | Pixel depth: 16, 24 or 32. Keep 24 unless you have a reason. |

## Resources

| Variable | Default | Description |
| --- | --- | --- |
| `DESKTOP_MEM_LIMIT` | `4g` | Container memory limit. |
| `DESKTOP_CPUS` | `4.0` | CPU limit (fractional values allowed). |
| `DESKTOP_SHM_SIZE` | `2gb` | Shared memory size; important for Firefox. |

For smaller hosts try:

```dotenv
DESKTOP_MEM_LIMIT=2g
DESKTOP_CPUS=2.0
DESKTOP_SHM_SIZE=1gb
VNC_RESOLUTION=1440x900
```

KasmVNC's own minimum recommendation is 2 cores / 2 GB.

## Storage

| Variable | Default | Description |
| --- | --- | --- |
| `DATA_DIR` | `./data` | Host directory for `desktop/` (home) and `caddy/` (TLS state). |

The compose file uses `${DATA_DIR}/desktop` and `${DATA_DIR}/caddy/*`.

## Images

| Variable | Default | Description |
| --- | --- | --- |
| `UBUNTU_TAG` | `latest` | Base image tag, e.g. `latest`, `24.04`, `26.04`. |
| `KASMVNC_VERSION` | `latest` | KasmVNC release, e.g. `1.5.2`. Pin for reproducible builds. |
| `KASMVNC_ASSET_URL` | empty | Direct `.deb` URL escape hatch if release resolution fails. |
| `IMAGE_TAG` | `latest` | Local tag suffix for built images. |
| `DESKTOP_UPSTREAM` | `desktop:6901` | Caddy upstream. Set to `desktop:6080` for the fallback (the override file does this automatically). |

The Dockerfile resolves the KasmVNC package in this order:

1. `ubuntu_<VERSION_CODENAME>` (e.g. `ubuntu_resolute`)
2. `ubuntu_resolute`, `ubuntu_noble`, `ubuntu_jammy`
3. `debian_trixie`

It does **not** use the GitHub API (which is rate-limited to 60 requests/hour
for unauthenticated builds). It reads the latest tag from the public release
redirect and constructs the asset URL, so repeated builds and CI are reliable.

If none exists for the architecture, the build fails with an actionable error;
use `make up-tigervnc`, pin a compatible `UBUNTU_TAG`, or set
`KASMVNC_ASSET_URL` to a direct `.deb` download URL.

## KasmVNC advanced settings

The container regenerates `/etc/kasmvnc/kasmvnc.yaml` on every start from the
entrypoint. Do **not** edit that file directly.

For per-user changes, create `data/desktop/.vnc/kasmvnc.yaml`. It overrides
the generated system config. Example — enable GPU acceleration on a
`make up-gpu` deployment:

```yaml
desktop:
  gpu:
    hw3d: true
    drinode: /dev/dri/renderD128
```

Other useful options: encoding quality (`encoding.*`), WebRTC UDP
(`network.udp.public_ip`), watermarks, and clipboard policy
(`data_loss_prevention.*`). See the
[KasmVNC configuration reference](https://www.kasmweb.com/kasmvnc/docs/latest/configuration.html).

Restart after editing: `make restart`.

## Docker Compose overrides

| File | Use |
| --- | --- |
| `compose/docker-compose.tigervnc.yml` | TigerVNC + noVNC backend |
| `compose/docker-compose.gpu.yml` | `/dev/dri` passthrough + `video`/`render` groups |

Apply manually if you prefer:

```bash
docker compose -f docker-compose.yml -f compose/docker-compose.gpu.yml up -d
```
