#!/usr/bin/env bash
# Home server installer: AdGuard Home + Immich + Jellyfin/Real-Debrid pipeline.
# Tested target: Ubuntu Server 24.04 / Debian 12, x86-64. Safe to re-run.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

log()  { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }

[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo ./install.sh"; exit 1; }

if [[ ! -f .env ]]; then
  cp .env.example .env
  echo "Created .env from .env.example — review it (paths, TZ, PUID/PGID), then re-run."
  exit 0
fi
set -a; source .env; set +a

# ---------------------------------------------------------------- Docker
if ! command -v docker >/dev/null 2>&1; then
  log "Installing Docker"
  curl -fsSL https://get.docker.com | sh
fi
docker compose version >/dev/null 2>&1 || { echo "Docker Compose v2 plugin missing"; exit 1; }

# ---------------------------------------------------------------- FUSE (Decypharr mount)
[[ -e /dev/fuse ]] || { apt-get update -qq && apt-get install -y -qq fuse3; }

# ---------------------------------------------------------------- Free port 53 for AdGuard
if systemctl is-active --quiet systemd-resolved 2>/dev/null \
   && ss -lnup 2>/dev/null | grep -q '127.0.0.53:53'; then
  log "Disabling systemd-resolved stub listener so AdGuard can use port 53"
  mkdir -p /etc/systemd/resolved.conf.d
  printf '[Resolve]\nDNS=1.1.1.1 9.9.9.9\nDNSStubListener=no\n' \
    > /etc/systemd/resolved.conf.d/adguardhome.conf
  ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
  systemctl restart systemd-resolved
fi

# ---------------------------------------------------------------- Directories
log "Creating directories"
mkdir -p "$APPDATA"/{adguard/{work,conf},jellyfin,sonarr,radarr,prowlarr,seerr,decypharr,immich/postgres}
mkdir -p "$DATA"/media/{movies,tv} "$DATA"/downloads/{sonarr,radarr} "$PHOTOS" "$DEBRID_MOUNT"
chown -R "$PUID:$PGID" "$APPDATA"/{jellyfin,sonarr,radarr,prowlarr,decypharr} "$DATA"/media "$DATA"/downloads "$DEBRID_MOUNT"
chown -R 1000:1000 "$APPDATA/seerr"   # Seerr runs as UID 1000 internally

# Mount propagation: the Real-Debrid FUSE mount created inside Decypharr only
# reaches the host (and Sonarr/Radarr/Jellyfin) if the host path is on a shared mount.
prop="$(findmnt -no PROPAGATION --target "$DEBRID_MOUNT" || true)"
if [[ "$prop" != *shared* ]]; then
  warn "$DEBRID_MOUNT is on a '$prop' mount; making it shared"
  mount --bind "$DEBRID_MOUNT" "$DEBRID_MOUNT"
  mount --make-rshared "$DEBRID_MOUNT"
  warn "This doesn't survive reboot. Add to /etc/fstab:  $DEBRID_MOUNT $DEBRID_MOUNT none bind,rshared 0 0"
fi

# ---------------------------------------------------------------- Immich (official release files)
IMMICH_DIR="$ROOT/stacks/immich"
if [[ ! -f "$IMMICH_DIR/docker-compose.yml" ]]; then
  log "Fetching Immich's latest release compose + env"
  base="https://github.com/immich-app/immich/releases/latest/download"
  curl -fsSL -o "$IMMICH_DIR/docker-compose.yml" "$base/docker-compose.yml"
  curl -fsSL -o "$IMMICH_DIR/.env" "$base/example.env"
  dbpass="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32 || true)"
  sed -i \
    -e "s|^UPLOAD_LOCATION=.*|UPLOAD_LOCATION=$PHOTOS|" \
    -e "s|^DB_DATA_LOCATION=.*|DB_DATA_LOCATION=$APPDATA/immich/postgres|" \
    -e "s|^DB_PASSWORD=.*|DB_PASSWORD=$dbpass|" \
    -e "s|^# *TZ=.*|TZ=$TZ|" \
    "$IMMICH_DIR/.env"
  chmod 600 "$IMMICH_DIR/.env"
fi

# ---------------------------------------------------------------- Start everything
log "Starting AdGuard Home"
docker compose --env-file "$ROOT/.env" -f stacks/adguard/compose.yml up -d

log "Starting media pipeline"
docker compose --env-file "$ROOT/.env" -f stacks/media/compose.yml up -d

log "Starting Immich (first pull is a few GB)"
(cd "$IMMICH_DIR" && docker compose up -d)

ip="$(hostname -I | awk '{print $1}')"
cat <<EOF

All stacks are up. Next: follow README.md "Wire it together", in order.

  AdGuard setup   http://$ip:3000   (then admin UI on :8053)
  Immich          http://$ip:2283
  Decypharr       http://$ip:8282
  Prowlarr        http://$ip:9696
  Sonarr          http://$ip:8989
  Radarr          http://$ip:7878
  Jellyfin        http://$ip:8096
  Seerr           http://$ip:5055

EOF
