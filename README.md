# MunnaVPS

A self-hosted Linux desktop that runs in Docker and opens in your browser.
No time limit, no per-session sandbox teardown: the VM-like desktop, its files,
and its running apps stay alive until you stop the container.

MunnaVPS is built for people who want a cloud-VPS-style desktop on their own
hardware. It uses **Ubuntu + XFCE**, serves the screen through **KasmVNC**
(a TigerVNC fork with a web-native client), and puts **Caddy** in front for
TLS. A **TigerVNC + noVNC** fallback target is included if KasmVNC is not
available for your architecture.

## Features

- **Full XFCE desktop** with Firefox, Thunar, terminal, screenshot and task
  manager pre-installed.
- **Browser access** — no VNC viewer app; clipboard and dynamic resize work.
- **No session time limit** — idle/active/auto-shutdown timeouts are disabled.
- **Persistent home** — everything lives in `./data/desktop` on the host.
- **Automatic HTTPS** — set a domain and Caddy obtains/renews certificates.
- **Password auth** — KasmVNC HTTP Basic Auth, brute-force protection enabled.
- **Resource limits** — 4 GB RAM / 4 vCPU by default, configurable in `.env`.
- **Optional GPU passthrough** for Intel/AMD hosts (`/dev/dri`).
- **Backup / restore / health** scripts and a one-command smoke test.

## Requirements

| Item | Minimum |
| --- | --- |
| Host OS | Linux with Docker (macOS/Windows work for local testing) |
| Docker | 24+ with Compose v2 |
| RAM | 4 GB available to the container (2 GB minimum) |
| CPU | 2 cores |
| Disk | 10 GB free |

## Quick start

```bash
git clone git@github.com:arafsk/MunnaVPS.git
cd MunnaVPS

make setup     # creates .env, generates a strong VNC password, makes data dirs
make up        # builds the image and starts Caddy + the desktop
make health    # verifies containers and the HTTP endpoint
```

Open the URL printed by `make setup` (default <http://localhost>), then log in
with the `DESKTOP_USER` and the `VNC_PASSWORD` from `.env`.

> First build downloads Ubuntu packages, Firefox, and the KasmVNC `.deb`; it
> can take several minutes. Later builds use the Docker cache.

## Configuration

Everything is driven by `.env`. See [docs/CONFIGURATION.md](docs/CONFIGURATION.md)
for the full reference.

Most important values:

| Variable | Default | Description |
| --- | --- | --- |
| `SITE_ADDRESS` | `:80` | `:80` for HTTP, `desktop.example.com` for automatic HTTPS |
| `HTTP_PORT` / `HTTPS_PORT` | `80` / `443` | Host ports mapped to Caddy |
| `DESKTOP_USER` | `munna` | Linux user and KasmVNC login name |
| `VNC_PASSWORD` | generated | KasmVNC password (min 6 chars) |
| `VNC_RESOLUTION` | `1920x1080` | Initial desktop size |
| `DESKTOP_MEM_LIMIT` | `4g` | Container memory limit |
| `DESKTOP_CPUS` | `4.0` | Container CPU limit |
| `DATA_DIR` | `./data` | Host directory for the home dir and Caddy state |
| `UBUNTU_TAG` | `latest` | Base image tag |
| `KASMVNC_VERSION` | `latest` | KasmVNC release to install |

### Automatic HTTPS

Point a DNS `A`/`AAAA` record at the host, open TCP 80 and 443, then:

```bash
# in .env
SITE_ADDRESS=desktop.example.com
```

Run `make up` again. Caddy obtains a Let's Encrypt certificate and renews it
automatically. See [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md).

### TigerVNC + noVNC fallback

```bash
make up-tigervnc
```

This rebuilds the same base image with the `tigervnc` target, exposes noVNC
inside the container, and points Caddy at it. KasmVNC remains the default and
is recommended.

## Data and backups

The desktop home directory is bind-mounted at `./data/desktop`:

```text
data/
├── desktop/              # /home/<DESKTOP_USER>  (your files, settings, apps)
└── caddy/                # certificates and Caddy state
```

```bash
make backup                               # consistent snapshot into backups/
make restore FILE=backups/desktop-*.tar.gz
```

Backups stop the desktop briefly, archive the home directory, and restart it.

## Commands

```text
make setup       Create .env and data directories
make up          Build and start
make down        Stop (data is kept)
make logs        Follow logs
make shell       Shell inside the desktop container
make health      Check container + endpoint health
make backup      Archive the desktop home
make restore     Restore an archive
make update      Rebuild with newer upstream images
make smoke       End-to-end test on localhost:18080
make up-tigervnc Fallback backend
make up-gpu      GPU passthrough override
```

## Repository layout

```text
docker-compose.yml              # desktop + caddy
compose/                        # optional override files
docker/desktop/Dockerfile       # base + kasmvnc + tigervnc targets
docker/desktop/kasmvnc/         # KasmVNC entrypoint
docker/desktop/tigervnc/        # TigerVNC entrypoint + supervisord
docker/desktop/common/xstartup  # XFCE session script
docker/caddy/Caddyfile          # reverse proxy + TLS
scripts/                        # setup / health / backup / restore / update
tests/smoke.sh                  # end-to-end test
docs/                           # architecture, config, deployment, ops, security
AGENTS.md                       # agent handbook, status, and decision log
```

## Security notes

- The VNC port is **not published**; only Caddy is exposed (80/443).
- Use a strong `VNC_PASSWORD` and, ideally, a real domain with HTTPS.
- The desktop user has passwordless sudo **inside the container** only.
- A web desktop is a full browser-accessible machine: keep it patched, and put
  it behind a VPN if it is not meant for the public internet.
- See [docs/SECURITY.md](docs/SECURITY.md).

## Troubleshooting

Start with:

```bash
make ps
make logs
make health
```

Common fixes are documented in [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

## License

MIT — see [LICENSE](LICENSE).
