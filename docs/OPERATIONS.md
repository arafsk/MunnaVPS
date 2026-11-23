# Operations

## Daily commands

```bash
make ps        # container status
make health    # health checks + HTTP probe
make logs      # follow all logs
make logs      # (Ctrl-C to stop following)
make shell     # bash inside the desktop container
make restart   # restart both services
```

Logs can also be read per service:

```bash
docker compose logs -f desktop
docker compose logs -f caddy
```

## Where things live

```text
data/desktop/          Home directory of DESKTOP_USER
data/desktop/.vnc/     KasmVNC session logs, xstartup, password file
data/caddy/data/       TLS certificates and Caddy state
data/caddy/config/     Caddy autosaved configuration
.env                   Credentials and settings (chmod 600)
backups/               Archives created by make backup
```

Session log:

```bash
tail -f data/desktop/.vnc/*.log
```

## Backups

```bash
make backup
```

The script:

1. Detects whether `munna-vps-desktop` is running.
2. Stops it for a consistent snapshot.
3. Creates `backups/desktop-<user>-<timestamp>.tar.gz` from `data/desktop`.
4. Restarts the container if it was running.

Run it before upgrades and on a schedule. Example cron entry (daily, 03:30):

```cron
30 3 * * * cd /opt/MunnaVPS && make backup >> backups/backup.log 2>&1
```

Cron does not load your shell environment; make sure the user can access the
Docker socket.

### Restore

```bash
make restore FILE=backups/desktop-munna-20261123-033000.tar.gz
```

The current home directory is moved aside to
`data/desktop.pre-restore-<timestamp>` rather than deleted, so you can roll
back. Stop the stack first if you prefer a full cold restore:

```bash
make down
make restore FILE=...
make up
```

### Off-site copies

Back up `.env` separately (it contains the password) and copy archives off the
host:

```bash
rsync -av backups/ user@backup-host:/srv/munnavps/
```

Do not commit `.env` or backups; both are gitignored.

## Password rotation

```bash
# edit VNC_PASSWORD in .env, then
make up
```

The entrypoint rewrites `~/.kasmpasswd` on every start. Existing browser
sessions are disconnected and must log in again.

## Changing resources

Edit `.env` and recreate:

```dotenv
DESKTOP_MEM_LIMIT=6g
DESKTOP_CPUS=6.0
DESKTOP_SHM_SIZE=3gb
```

```bash
make up
```

The home directory is untouched.

## Changing the resolution

```dotenv
VNC_RESOLUTION=2560x1440
```

`make up`. KasmVNC also supports dynamic resize per browser window, so this is
only the initial size.

## Updating

```bash
git pull --ff-only
make update
```

If a rebuild fails, check that KasmVNC still publishes a package for the new
Ubuntu release (`make logs` shows the build output). Pin `UBUNTU_TAG` or switch
to `make up-tigervnc` as a stopgap.

## GPU passthrough

Only on Linux with `/dev/dri`:

```bash
ls -l /dev/dri
make up-gpu
```

Then enable it in `data/desktop/.vnc/kasmvnc.yaml`:

```yaml
desktop:
  gpu:
    hw3d: true
    drinode: /dev/dri/renderD128
```

Restart and verify inside the desktop with `glxinfo -B`.

## Disk usage

```bash
docker system df
du -sh data/desktop data/caddy backups
```

Safe cleanups:

```bash
docker image prune            # dangling build layers
# remove old archives manually once verified
```

`make down` does not delete bind-mounted data.

## Monitoring

- `make health` exits non-zero on failure; use it from cron or an uptime check.
- Point an external monitor at `https://<domain>/` expecting HTTP 200/302/401.
- Watch container restarts: `docker inspect -f '{{.RestartCount}}' munna-vps-desktop`.

## Recovering from an unclean shutdown

The entrypoint kills stale sessions and removes stale X locks before starting.
If the desktop still will not start:

```bash
docker compose logs desktop
docker compose exec desktop bash
ls -la ~/.vnc
```

Removing `~/.vnc/*.pid` and `/tmp/.X1-lock` inside the container is safe when no
VNC process is running.
