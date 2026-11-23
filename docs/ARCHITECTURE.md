# Architecture

## Goals

1. A persistent Linux desktop that runs on the host's Docker engine.
2. Access from any modern browser, with no session time limit.
3. Host-level persistence for files and settings.
4. A small, auditable footprint: two containers, one bind mount tree.
5. A fallback streaming stack if KasmVNC cannot be installed.

## Components

```text
                        host
┌─────────────────────────────────────────────────────────────┐
│                                                             │
│  browser ──HTTP/HTTPS──▶ caddy :80/:443                     │
│                            │                                │
│                            │ reverse proxy (WebSocket)      │
│                            ▼                                │
│                     desktop :6901 (KasmVNC, internal only)  │
│                            │                                │
│                            ├── Xvnc  :1                     │
│                            ├── dbus-run-session             │
│                            └── startxfce4                   │
│                                                             │
│  bind mounts:                                               │
│    ./data/desktop -> /home/<user>                           │
│    ./data/caddy   -> Caddy /data, /config                   │
└─────────────────────────────────────────────────────────────┘
```

### `desktop` container

- Base: `ubuntu:latest` (currently Ubuntu Resolute).
- Desktop: XFCE 4, Firefox (Mozilla APT build), Thunar, terminal, screenshots.
- Session manager: KasmVNC's `vncserver` starts Xvnc on display `:1` and
  launches `~/.vnc/xstartup`, which starts `dbus-run-session -- startxfce4`.
- Runs as root only for the entrypoint: user creation, ownership fixes, config
  generation, and password setup. The desktop itself runs as `DESKTOP_USER`.
- Only port 6901 is exposed **inside the Docker network**, never on the host.

### `caddy` container

- Official `caddy:2-alpine` image.
- Terminates TLS (automatic Let's Encrypt, or Caddy's internal CA for
  `localhost`), proxies HTTP + WebSocket traffic to `desktop:6901`.
- Publishes 80/443 (and 443/UDP for HTTP/3).
- A single site block keeps routing simple; the desktop is mounted at `/`.

## Streaming backends

### KasmVNC (default)

KasmVNC is a fork of TigerVNC that replaces the RFB transport with a
web-native HTTP/WebSocket client. Benefits:

- No separate noVNC/websockify process.
- TLS termination can live in Caddy; KasmVNC runs plain HTTP inside the
  private Docker network (`network.ssl.require_ssl: false`).
- Dynamic resize, clipboard, WebP/JPEG adaptive encoding, optional WebRTC UDP.
- Built-in brute-force protection.

### TigerVNC + noVNC (fallback)

- `tigervnc-standalone-server` runs Xvnc on `:1`.
- `websockify` serves the bundled noVNC client on `:6080` and bridges it to
  `127.0.0.1:5901`.
- `supervisord` supervises both processes. It runs as root so it can write to
  Docker's stdout, and drops to the desktop user for each program.
- Same XFCE base image and `xstartup`; only the final image stage differs.

Both backends disable idle and auto-shutdown timeouts, so the desktop keeps
running with no browser attached.

## Dockerfile stages

```text
ubuntu:latest
   └── base        (XFCE, Firefox, fonts, sudo, gosu, common tools)
        ├── kasmvnc    (+ KasmVNC .deb, entrypoint, port 6901)
        └── tigervnc   (+ TigerVNC, noVNC, supervisord, port 6080)
```

The shared `base` stage means switching backends reuses almost all layers.

## Data flow

1. Caddy accepts the request and forwards it to `desktop:6901`.
2. KasmVNC performs HTTP Basic Auth against `~/.kasmpasswd`.
3. The browser receives the desktop as WebP/JPEG rectangles over WebSocket.
4. Input events and clipboard travel back over the same socket.
5. Files written on the desktop appear under `./data/desktop` on the host.

## Persistence

| Path | Contents | Backed up |
| --- | --- | --- |
| `./data/desktop` | Entire home directory | Yes (`make backup`) |
| `./data/caddy/data` | TLS certs, Caddy state | Optional |
| `./data/caddy/config` | Caddy autosave config | Optional |
| `.env` | Credentials and configuration | No (contains secrets) |

## Resource limits

Compose applies `mem_limit`, `cpus`, `shm_size` and a high `nofile` limit.
`shm_size` (2 GB default) matters because Chromium/Firefox use shared memory
for renderers; the default 64 MB causes tab crashes.

## Ports

| Port | Published | Purpose |
| --- | --- | --- |
| 80 | Yes | HTTP / ACME challenge / redirect |
| 443 | Yes | HTTPS + WebSocket |
| 443/udp | Yes | HTTP/3 |
| 6901 | No | KasmVNC (Docker network only) |
| 5901 | No | TigerVNC (fallback, container only) |
| 6080 | No | noVNC (fallback, Docker network only) |

## Design decisions

- **Ubuntu latest, not a pinned LTS.** KasmVNC ships a package for each
  current Ubuntu release; the build resolves the matching asset automatically
  and fails with a clear message if none exists.
- **KasmVNC over a self-built noVNC stack.** One fewer process, better
  clipboard/resize support, and a maintained web client.
- **Caddy over Nginx.** Automatic certificates without certbot, a tiny config,
  and correct WebSocket handling by default.
- **Bind mount over named volume.** Users can inspect and back up files
  directly; `make backup` adds consistency.
- **No timeouts.** This is the core difference from hosted demo services.
