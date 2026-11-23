# Security

MunnaVPS provides a **full desktop with a browser** over the web. Treat it like
a machine exposed to the internet, not like a static website.

## Threat model

In scope:

- Unauthorized access through the web endpoint.
- Credential theft (password, session cookies).
- A compromised desktop being used to attack the host or network.
- Accidental data exposure through backups or `.env`.

Out of scope by default:

- Multi-tenant isolation between several users (this deployment is
  single-user).
- Host kernel exploits (keep the host patched).
- Protecting data from someone who already has root on the host.

## Baseline controls in this repo

| Control | Implementation |
| --- | --- |
| Only the proxy is exposed | Compose publishes 80/443; VNC ports stay on the Docker network. |
| Transport encryption | Caddy automatic HTTPS with a real domain. |
| Authentication | KasmVNC HTTP Basic Auth; password stored as an obfuscated file with mode 0600. |
| Brute-force protection | KasmVNC blacklists a host after 5 failed attempts (10 s, increasing). |
| Secret hygiene | `.env` is gitignored and created with mode 0600; no secrets in the image. |
| Least privilege for the session | XFCE runs as `DESKTOP_USER`, not root. |
| Resource limits | Memory/CPU/PID/file-descriptor limits reduce runaway workloads. |
| Automatic renewals | Caddy renews certificates. |

## Hardening checklist

1. **Use HTTPS.** Set `SITE_ADDRESS` to a real domain. Do not send passwords
   over plain HTTP beyond a trusted LAN.
2. **Use a strong password.** `make setup` generates 24 random characters.
   Rotate it if it was ever shared or logged.
3. **Restrict exposure.** Prefer a WireGuard/Tailscale network or an IP
   allowlist over the public internet.
4. **Keep the stack updated.** `git pull && make update` monthly, and
   `sudo apt-get upgrade` inside the desktop for user-space tools.
5. **Back up `.env` securely.** It contains the password; store it in a password
   manager, not a public repo.
6. **Do not add `privileged: true`.** The GPU override is the only device
   passthrough and is opt-in.
7. **Review added ports.** Every published port bypasses Caddy.
8. **Limit clipboard/file transfer** if the desktop is for untrusted content:
   set `data_loss_prevention.clipboard.*` in
   `data/desktop/.vnc/kasmvnc.yaml`.

## About sudo inside the container

The image grants `DESKTOP_USER` passwordless sudo **inside the container** so it
behaves like a VPS. This is convenient and does not directly grant host root,
but container escape vulnerabilities would be amplified. If you do not need it,
remove this line from `docker/desktop/Dockerfile` and rebuild:

```dockerfile
RUN printf '%s\n' 'ALL ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/desktop-user ...
```

## Network exposure

- Caddy is the only published service. It forwards WebSocket upgrades.
- KasmVNC binds `0.0.0.0:6901` **inside the Docker bridge**, not on the host.
- If you add a reverse proxy in front of Caddy, sanitize `X-Forwarded-For` at
  the first trusted hop so KasmVNC's brute-force blacklist sees real client IPs.
- Do not enable KasmVNC's WebRTC UDP (`network.udp.public_ip`) unless you
  understand the additional port exposure.

## Data at rest

- Desktop files are plain files under `data/desktop`; host disk encryption is
  recommended.
- Backups are unencrypted tarballs. If they leave the host, encrypt them:

  ```bash
  gpg --symmetric --cipher-algo AES256 backups/desktop-*.tar.gz
  ```

- The KasmVNC password file is obfuscated, not strongly hashed. Anyone who can
  read it can recover the password; rely on host filesystem permissions.

## Reporting a problem

Open an issue at <https://github.com/arafsk/MunnaVPS/issues> with reproduction
steps and the output of `make health` (redact credentials and domains).
