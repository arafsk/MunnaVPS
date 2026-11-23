# AGENTS.md — MunnaVPS Agent Handbook

> **Read this file first, every session.** It is the single source of truth for
> what MunnaVPS is, what has been decided, what is verified, and what to do
> next. Update it in the same commit as any change that alters status,
> architecture, commands, or verification results.
>
> Repository: `git@github.com:arafsk/MunnaVPS.git`
> Default branch: `main` (agents commit and push directly to `main`).

---

## 1. Project snapshot

| Item | Value |
| --- | --- |
| Product | Self-hosted, browser-accessible Linux desktop in Docker |
| Core promise | No session time limit; unlike hosted demo desktops, the session persists |
| Base OS | `ubuntu:latest` (currently Ubuntu Resolute), intentionally unpinned |
| Desktop | XFCE 4 + Firefox + Thunar + terminal |
| Primary backend | KasmVNC (TigerVNC fork, web-native client) |
| Fallback backend | TigerVNC + noVNC (`make up-tigervnc`) |
| Reverse proxy / TLS | Caddy 2, automatic Let's Encrypt or internal CA |
| Auth | KasmVNC HTTP Basic Auth (username + password), no extra SSO |
| Users | Single desktop user (`DESKTOP_USER`, default `munna`) |
| Persistence | Bind mounts under `./data` (`desktop/`, `caddy/`) |
| Default limits | 4 GB RAM, 4 vCPU, 2 GB shm |
| GPU | Software only by default; opt-in `/dev/dri` override |
| Current status | **Verified on arm64 — initial release ready; CI + public TLS verification pending** |

## 2. Locked product decisions

These came from the project owner. Do not change them without explicit approval.

1. **Ubuntu latest, not a fixed LTS.** The Dockerfile resolves the matching
   KasmVNC package by codename; never hardcode `24.04` as the default.
2. **KasmVNC is the default backend.** It is TigerVNC-derived, which satisfies
   the "TigerVNC + KasmVNC" requirement. A TigerVNC + noVNC image target must
   remain available as a fallback.
3. **Single user, single desktop.** No multi-tenant auth in the default stack.
4. **Bind mount persistence** at `./data/desktop`, not a named volume.
5. **Caddy with automatic TLS.** Plain HTTP (`:80`) is the default until a
   domain is configured.
6. **Password-only auth.** No Authelia/Authentik in the default stack.
7. **No GPU by default.** `/dev/dri` is an optional override.
8. **No timeouts.** `idle_timeout`, `no_user_session_timeout`,
   `active_user_session_timeout`, and `inactive_user_session_timeout` must stay
   `never`. This is the product's differentiator.
9. **Agents commit and push directly to `main`.** No long-lived feature
   branches or PR-only flow unless the user changes this instruction.

## 3. Architecture (short version)

```text
browser ──80/443──▶ caddy ──(Docker network)──▶ desktop:6901
                                                 ├─ Xvnc :1
                                                 ├─ dbus-run-session
                                                 └─ startxfce4
bind mounts: ./data/desktop -> /home/<DESKTOP_USER>
             ./data/caddy   -> Caddy state
```

Full detail: `docs/ARCHITECTURE.md`.

## 4. Repository map

| Path | Purpose |
| --- | --- |
| `docker-compose.yml` | Default stack: `desktop` (KasmVNC) + `caddy` |
| `compose/docker-compose.tigervnc.yml` | Fallback backend override |
| `compose/docker-compose.gpu.yml` | Optional `/dev/dri` passthrough |
| `docker/desktop/Dockerfile` | `base` → `kasmvnc` / `tigervnc` targets |
| `docker/desktop/common/xstartup` | XFCE session script |
| `docker/desktop/kasmvnc/entrypoint.sh` | User setup, config, password, launch |
| `docker/desktop/tigervnc/entrypoint.sh` | Same for TigerVNC |
| `docker/desktop/tigervnc/supervisord.conf` | Xvnc + websockify supervision |
| `docker/caddy/Caddyfile` | Site block, WebSocket proxy, TLS |
| `scripts/setup.sh` | `.env` + password + data dirs |
| `scripts/lib/common.sh` | Shared env loading / URL helpers |
| `scripts/healthcheck.sh` | Container + HTTP checks |
| `scripts/backup.sh` / `restore.sh` | Home directory snapshots |
| `scripts/update.sh` | Pull, rebuild, recreate, verify |
| `tests/smoke.sh` | End-to-end test on ports 18080/18443 |
| `docs/` | Architecture, configuration, deployment, operations, security, troubleshooting |
| `AGENTS.md` | This file |

## 5. Standard agent workflow

### Step 0 — Orient

```bash
pwd                       # must be the repo root
git status --short
git log --oneline -5
sed -n '1,120p' AGENTS.md
```

Check the "Current status", "Verification matrix", and "Session log" below
before planning anything.

### Step 1 — Plan

- Identify whether the task changes defaults, ports, commands, or security.
- If it does, record the decision in the Decision Log (section 11).
- Prefer the smallest change that fits existing patterns.

### Step 2 — Change

- Keep configuration in `.env` / compose; avoid hardcoding secrets or domains.
- Keep the KasmVNC default and the TigerVNC fallback working.
- Do not add session timeouts.
- Do not add `privileged: true`.
- If adding a package, add it in the `base` stage so both targets benefit.
- If changing the KasmVNC package resolution, preserve the codename fallback
  chain and the clear failure message.

### Step 3 — Verify

Minimum before committing:

```bash
cp -n .env.example .env 2>/dev/null || true   # only if .env is missing
docker compose config -q
shellcheck --source-path=SCRIPTDIR -x scripts/*.sh scripts/lib/*.sh \
  docker/desktop/*/*.sh tests/*.sh
```

For runtime changes:

```bash
make up
make health
make smoke
```

Record results in the Verification Matrix (section 7).

### Step 4 — Update this file

Update, at minimum:

- Current status (section 1) if the stage changed.
- Verification Matrix (section 7) with date + result.
- Known Issues (section 10) for anything unresolved.
- Session Log (section 12), newest entry first.

### Step 5 — Commit and push directly to `main`

```bash
git add -A
git commit -m "<type>(<scope>): <short summary>"
git push origin main
```

Commit message types: `feat`, `fix`, `docs`, `chore`, `refactor`, `test`.
Examples:

```text
feat(desktop): add TigerVNC + noVNC fallback target
fix(kasmvnc): handle stale X lock on restart
docs(agents): record smoke-test results
```

Never commit `.env`, `data/`, `backups/`, or generated secrets. If a push is
rejected, `git pull --rebase origin main` then push again.

### Definition of done

- [ ] Change matches the locked decisions.
- [ ] `docker compose config -q` passes.
- [ ] Shellcheck passes for touched scripts.
- [ ] Runtime change verified with `make up` + `make health` (or `make smoke`).
- [ ] Docs updated if behavior/configuration changed.
- [ ] AGENTS.md updated.
- [ ] Committed and pushed to `origin/main`.

## 6. Common commands

```bash
make setup          # create .env + password + dirs (safe to re-run)
                    # forward options with ARGS, e.g. make setup ARGS="--domain desktop.example.com"
make up             # build and start
make down           # stop, keep data
make ps             # status
make logs           # follow logs
make shell          # shell in desktop container
make health         # health checks
make backup         # tar the home dir
make restore FILE=... 
make update         # rebuild with --pull
make smoke          # E2E on 18080/18443
make up-tigervnc    # fallback backend
make up-gpu         # /dev/dri override
make config         # merged compose config
```

Debug helpers:

```bash
docker compose exec desktop bash
docker compose exec desktop ps aux
tail -f data/desktop/.vnc/*.log
docker inspect -f '{{json .State.Health}}' munna-vps-desktop | jq
```

## 7. Verification matrix

| Check | Command | Status | Date |
| --- | --- | --- | --- |
| Compose config valid | `docker compose config -q` | ✅ pass | 2026-11-23 |
| Shellcheck clean | `shellcheck --source-path=SCRIPTDIR -x ...` | ✅ pass | 2026-11-23 |
| Caddy config valid | `caddy validate` | ✅ pass | 2026-11-23 |
| KasmVNC image builds (arm64) | `make up` / `docker compose build desktop` | ✅ pass | 2026-11-23 |
| TigerVNC image builds | `make up-tigervnc` | ✅ pass | 2026-11-23 |
| Desktop healthcheck passes | `make health` | ✅ pass | 2026-11-23 |
| HTTP endpoint responds | `curl http://localhost/` | ✅ 401 unauth | 2026-11-23 |
| Password auth accepted | `curl -u user:pass` | ✅ 200 | 2026-11-23 |
| Xvnc/XFCE process runs | `pgrep` inside container | ✅ pass | 2026-11-23 |
| Desktop renders (UI) | KasmVNC screenshot API | ✅ 1280x720 | 2026-11-23 |
| Correct desktop identity | `id munna` | ✅ uid/gid 1000 | 2026-11-23 |
| Fallback backend serves noVNC | `make up-tigervnc` | ✅ HTTP 200 | 2026-11-23 |
| Smoke test | `make smoke` | ✅ pass | 2026-11-23 |
| Backup/restore round-trip | `make backup` + restore | ✅ pass | 2026-11-23 |
| GitHub push | `git push origin main` | ⏳ pending | — |
| GitHub Actions CI | push to `main` | ⏳ pending | — |
| Real domain + Let's Encrypt | `SITE_ADDRESS=<domain>` | ⏳ pending | — |
| GPU passthrough | `make up-gpu` | ➖ not testable on arm64 host | — |
| Audio streaming | manual browser check | ⏳ pending | — |

## 8. Environment and secrets rules

- `.env` is the only place for credentials; it is gitignored and mode 0600.
- `.env.example` must contain only placeholders, never a real password.
- `data/` and `backups/` are gitignored; never force-add them.
- Scripts must not print `VNC_PASSWORD` (health check only prints usernames).
- The generated password is 24 alphanumeric characters.
- `DESKTOP_USER` must match `^[a-z_][a-z0-9_-]*$`; the entrypoint enforces it.

## 9. Roadmap / backlog

### P0 — finish initial build

- [x] Verify KasmVNC image build on arm64 (current dev host).
- [x] Verify fallback image build.
- [x] Run `make smoke` and record results.
- [ ] Push the scaffold to `origin/main`.

### P1 — operational quality

- [ ] Verify CI (compose config + shellcheck + image builds).
- [x] Test backup/restore round-trip.
- [ ] Test with a real domain + Let's Encrypt certificate.
- [ ] Add a screenshot to the README (only if the user asks for one).
- [ ] Confirm audio behavior in KasmVNC; document if disabled.

### P2 — optional extensions

- [ ] Multiple named desktops via compose profiles.
- [ ] Authelia/Authentik SSO override.
- [ ] Selkies-GStreamer backend for low-latency/WebRTC.
- [ ] NVIDIA GPU override.
- [ ] Automated nightly backups via a sidecar or host cron docs.

## 10. Known issues / gotchas

- **KasmVNC packages follow Ubuntu releases.** A brand-new Ubuntu release may
  lack an asset for a few weeks. The Dockerfile fails clearly; use
  `make up-tigervnc` or pin `UBUNTU_TAG`.
- **Do not resolve KasmVNC through the GitHub API in the build.** The
  unauthenticated limit (60 req/hour) breaks repeated builds. The Dockerfile
  resolves the latest tag via the public `/releases/latest` redirect and
  constructs asset URLs; `KASMVNC_ASSET_URL` is the escape hatch.
- **Ubuntu `firefox` is a snap** and cannot run in the container. The image
  installs Firefox from `packages.mozilla.org`; do not switch to the Ubuntu
  package.
- **Base image UID 1000.** Ubuntu ships an unused `ubuntu` account at 1000. The
  base stage removes it; the entrypoint still uses `groupadd -o`/`useradd -o`
  if a host-chosen PUID/PGID is already taken.
- **KasmVNC cert validation.** With TLS terminated by Caddy, KasmVNC still
  validates the snakeoil cert paths, so the desktop user is added to
  `ssl-cert`.
- **Container packages do not persist.** Only `/home/<user>` is persistent.
  Documented in `docs/OPERATIONS.md`.
- **TigerVNC + noVNC logs.** `supervisord` runs as root for Docker stdout
  access and drops to the desktop user per program; the runtime config is
  templated in `/tmp/munnavps-supervisord.conf`.
- **Backups exclude runtime sockets** (`.ssh/agent`, `.gnupg/S.*`, `*.sock`);
  otherwise BSD tar warns about pax-format socket archiving.
- **Caddy healthcheck** inspects `/proc/net/tcp{,6}` for port 80, avoiding a
  dependency on `nc` or `wget` HTTP error semantics.
- **`make health` waits up to 60 s** for Docker's `starting` health state, so
  it is safe immediately after `up`/`update`.
- **macOS bind mounts** report host ownership; this is normal.
- **Default XFCE background is black** with the minimal package set. Cosmetic
  only; add `ubuntu-wallpapers` and set a background if desired.

## 11. Decision log

| Date | Decision | Rationale |
| --- | --- | --- |
| 2026-11-23 | Ubuntu `latest` + XFCE | Owner request; KasmVNC publishes per-release packages. |
| 2026-11-23 | KasmVNC default, TigerVNC+noVNC fallback | Owner asked for TigerVNC with KasmVNC/web access; KasmVNC is the TigerVNC fork with built-in web client. |
| 2026-11-23 | Caddy auto-TLS | Simplest correct TLS + WebSocket proxy. |
| 2026-11-23 | Single user, password auth | Owner selection; lower operational complexity. |
| 2026-11-23 | Bind mount `./data` | Owner selection; transparent backups. |
| 2026-11-23 | 4 GB / 4 vCPU default profile | Owner selection. |
| 2026-11-23 | No session/idle timeouts | Core product requirement ("no time limit"). |
| 2026-11-23 | Direct commits to `main` + push | Explicit owner instruction. |
| 2026-11-23 | Remove GitHub API from image build | Unauthenticated 60 req/hour limit broke repeated builds; use the public release redirect + direct asset URLs. |
| 2026-11-23 | Remove base `ubuntu` user at build | Freed UID/GID 1000 so the configured desktop user is not displayed as `ubuntu`. |
| 2026-11-23 | Add desktop user to `ssl-cert` | KasmVNC validates the snakeoil cert paths even with TLS disabled. |
| 2026-11-23 | supervisord root + per-program user | Non-root supervisord could not open Docker's `/dev/stdout` dispatchers (EACCES). |
| 2026-11-23 | Exclude sockets from backups | BSD tar cannot archive Unix sockets in pax format. |

## 12. Session log

### 2026-11-23 — Build, runtime, and fallback verification

Verified end-to-end on macOS arm64 (Docker Desktop 29.9.3):

- KasmVNC image builds from `ubuntu:latest` (Resolute) with KasmVNC 1.5.2.
- Fixed container restart loop: base image GID 1000 already in use
  (`groupadd` failure) — entrypoint now tolerates pre-existing UID/GID and the
  base image's `ubuntu` account is removed.
- Fixed KasmVNC startup failure: snakeoil key unreadable — desktop user is now
  added to `ssl-cert`.
- Replaced the GitHub API package resolver after hitting the 60 req/hour limit.
- Desktop healthy; unauthenticated `GET /` returns 401, authenticated returns
  200; Xvnc, KasmVNC, xfce4-session and the panel run.
- KasmVNC screenshot API returned a 1280x720 render of the XFCE desktop.
- `make smoke` passed (ports 18080/18443).
- TigerVNC + noVNC fallback builds and becomes healthy; noVNC root returns 200.
  Fixed supervisor EACCES by running it as root with per-program users.
- Backup/restore round-trip passed; sockets excluded from archives.
- `make health` now waits through Docker's `starting` state.
- Next: push and watch the first GitHub Actions run; test a real domain/TLS.

### 2026-11-23 — Initial scaffold

- Created the full project structure: compose stack, multi-stage Dockerfile
  (`base` / `kasmvnc` / `tigervnc`), entrypoints, XFCE xstartup, Caddyfile.
- Added scripts: setup, healthcheck, backup, restore, update, smoke test.
- Added docs: architecture, configuration, deployment, operations, security,
  troubleshooting.
- Verified KasmVNC 1.5.2 publishes an `ubuntu_resolute` asset for amd64 and
  arm64, so `ubuntu:latest` is supported at scaffold time.
- Verified Docker 29.9.3 + Compose v5.7.1 and GitHub SSH auth on the dev host.
