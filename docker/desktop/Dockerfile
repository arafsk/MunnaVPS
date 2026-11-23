# syntax=docker/dockerfile:1
#
# MunnaVPS desktop image.
#
# One base stage + two interchangeable web-desktop backends:
#   target=kasmvnc  -> KasmVNC (default; TigerVNC fork with a web-native client)
#   target=tigervnc -> TigerVNC + noVNC (fallback)
#
# Build:
#   docker build --target kasmvnc -f docker/desktop/Dockerfile .
#   docker build --target tigervnc -f docker/desktop/Dockerfile .

ARG UBUNTU_TAG=latest
FROM ubuntu:${UBUNTU_TAG} AS base

LABEL org.opencontainers.image.title="MunnaVPS Desktop" \
      org.opencontainers.image.description="Self-hosted browser Linux desktop (Ubuntu + XFCE)" \
      org.opencontainers.image.source="https://github.com/arafsk/MunnaVPS" \
      org.opencontainers.image.licenses="MIT"

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    DISPLAY=:1 \
    SHELL=/bin/bash

# Desktop environment, browser runtime libraries, and container tooling.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      wget \
      gnupg \
      jq \
      git \
      dbus \
      dbus-x11 \
      xfce4 \
      xfce4-terminal \
      xfce4-notifyd \
      xfce4-screenshooter \
      xfce4-taskmanager \
      thunar \
      gvfs \
      mousepad \
      ristretto \
      xterm \
      adwaita-icon-theme \
      dmz-cursor-theme \
      hicolor-icon-theme \
      xdg-utils \
      xdg-user-dirs \
      x11-utils \
      x11-xserver-utils \
      xkb-data \
      fonts-dejavu-core \
      fonts-liberation \
      fonts-noto-color-emoji \
      libgl1 \
      libegl1 \
      libglu1-mesa \
      mesa-utils \
      pulseaudio \
      pulseaudio-utils \
      sudo \
      gosu \
      nano \
      less \
      procps \
      psmisc \
      file \
      tar \
      gzip \
      xz-utils \
      unzip \
      zip \
      iproute2 \
      iputils-ping \
      net-tools \
      locales \
      tzdata \
 && rm -rf /var/lib/apt/lists/*

# Ensure the groups used by optional GPU passthrough exist in the image.
RUN getent group video >/dev/null || groupadd -r video \
 && getent group render >/dev/null || groupadd -r render

# The Ubuntu base image ships an unused "ubuntu" account at UID/GID 1000.
# Remove it so the runtime-created desktop user can own 1000 cleanly.
RUN if getent passwd ubuntu >/dev/null; then userdel ubuntu 2>/dev/null || true; fi \
 && if getent group ubuntu >/dev/null; then groupdel ubuntu 2>/dev/null || true; fi

# Firefox: Ubuntu only ships a snap, which does not work in containers.
# Use Mozilla's official APT repository (amd64 + arm64).
RUN install -d -m 0755 /etc/apt/keyrings \
 && curl -fsSL --retry 3 \
      https://packages.mozilla.org/apt/repo-signing-key.gpg \
      -o /etc/apt/keyrings/packages.mozilla.org.asc \
 && printf '%s\n' \
      'deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main' \
      > /etc/apt/sources.list.d/mozilla.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends firefox \
 && rm -rf /var/lib/apt/lists/*

# Give the desktop user passwordless sudo *inside the container*. This is
# convenient for installing packages in the sandbox; it does not grant host
# privileges. Remove the sudoers file if you do not want this.
RUN printf '%s\n' 'ALL ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/desktop-user \
 && chmod 0440 /etc/sudoers.d/desktop-user

RUN mkdir -p /etc/munnavps /usr/local/bin

# ---------------------------------------------------------------------------
# Backend: KasmVNC
# ---------------------------------------------------------------------------
FROM base AS kasmvnc

ARG KASMVNC_VERSION=latest
ARG KASMVNC_ASSET_URL=""

# Resolve and install the KasmVNC package that matches this Ubuntu release.
# GitHub's API has a 60 req/hour unauthenticated limit, so resolve the latest
# tag through the public release redirect (no API) and construct asset URLs.
# Falls back to other tested Ubuntu/Debian builds if the exact codename has no
# asset yet. Pin KASMVNC_VERSION for reproducible builds, or set
# KASMVNC_ASSET_URL to a direct .deb URL as an escape hatch.
RUN set -eux; \
    . /etc/os-release; \
    arch="$(dpkg --print-architecture)"; \
    if [ -n "${KASMVNC_ASSET_URL}" ]; then \
      echo "Using KASMVNC_ASSET_URL"; \
      curl -fsSL --retry 3 -o /tmp/kasmvnc.deb "${KASMVNC_ASSET_URL}"; \
    else \
      if [ "${KASMVNC_VERSION}" = "latest" ]; then \
        tag="$(curl -fsSL -o /dev/null -w '%{url_effective}' \
          https://github.com/kasmtech/KasmVNC/releases/latest \
          | sed -E 's#.*/tag/##')"; \
      else \
        tag="v${KASMVNC_VERSION#v}"; \
      fi; \
      ver="${tag#v}"; \
      echo "KasmVNC release: ${tag}"; \
      base="https://github.com/kasmtech/KasmVNC/releases/download/${tag}"; \
      found=0; \
      for distro in "${ID}_${VERSION_CODENAME}" ubuntu_resolute ubuntu_noble ubuntu_jammy debian_trixie; do \
        url="${base}/kasmvncserver_${distro}_${ver}_${arch}.deb"; \
        echo "Trying ${url}"; \
        if curl -fsSL --retry 2 -o /tmp/kasmvnc.deb "${url}"; then \
          found=1; \
          break; \
        fi; \
      done; \
      if [ "${found}" != "1" ] || [ ! -s /tmp/kasmvnc.deb ]; then \
        echo "ERROR: no KasmVNC .deb for ${ID} ${VERSION_CODENAME} (${arch})." >&2; \
        echo "Set KASMVNC_VERSION, KASMVNC_ASSET_URL, or use the tigervnc target." >&2; \
        exit 1; \
      fi; \
    fi; \
    apt-get update; \
    apt-get install -y --no-install-recommends /tmp/kasmvnc.deb; \
    rm -f /tmp/kasmvnc.deb; \
    rm -rf /var/lib/apt/lists/*

COPY docker/desktop/common/xstartup /etc/munnavps/xstartup
COPY docker/desktop/kasmvnc/entrypoint.sh /usr/local/bin/munnavps-entrypoint
RUN chmod +x /usr/local/bin/munnavps-entrypoint \
 && chmod 0755 /etc/munnavps/xstartup

EXPOSE 6901
STOPSIGNAL SIGTERM

HEALTHCHECK --interval=15s --timeout=5s --start-period=60s --retries=10 \
  CMD curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:6901/ \
      | grep -qE '^(200|302|401)$' || exit 1

ENTRYPOINT ["/usr/local/bin/munnavps-entrypoint"]

# ---------------------------------------------------------------------------
# Backend: TigerVNC + noVNC
# ---------------------------------------------------------------------------
FROM base AS tigervnc

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      tigervnc-standalone-server \
      tigervnc-common \
      tigervnc-tools \
      novnc \
      websockify \
      supervisor \
 && rm -rf /var/lib/apt/lists/* \
 && printf '%s\n' \
      '<!doctype html><meta charset="utf-8"><title>MunnaVPS</title>' \
      '<meta http-equiv="refresh" content="0; url=vnc.html">' \
      > /usr/share/novnc/index.html

COPY docker/desktop/common/xstartup /etc/munnavps/xstartup
COPY docker/desktop/tigervnc/supervisord.conf /etc/munnavps/supervisord.conf
COPY docker/desktop/tigervnc/start-xvnc.sh /usr/local/bin/munnavps-start-xvnc
COPY docker/desktop/tigervnc/entrypoint.sh /usr/local/bin/munnavps-entrypoint
RUN chmod +x /usr/local/bin/munnavps-entrypoint \
 && chmod +x /usr/local/bin/munnavps-start-xvnc \
 && chmod 0755 /etc/munnavps/xstartup

EXPOSE 6080
STOPSIGNAL SIGTERM

HEALTHCHECK --interval=15s --timeout=5s --start-period=60s --retries=10 \
  CMD curl -fsS http://127.0.0.1:6080/ >/dev/null || exit 1

ENTRYPOINT ["/usr/local/bin/munnavps-entrypoint"]
