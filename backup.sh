#!/usr/bin/env bash
# Nightly backup: Immich DB dump + photos + all app configs -> restic repo.
# Media from Real-Debrid is NOT backed up (it isn't stored here; Sonarr/Radarr can re-grab).
# Cron (root):  0 3 * * * /opt/homeserver/backup.sh >> /var/log/homeserver-backup.log 2>&1
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
set -a; source "$ROOT/.env"; set +a

: "${RESTIC_REPOSITORY:?Set RESTIC_REPOSITORY in .env}"
: "${RESTIC_PASSWORD_FILE:?Set RESTIC_PASSWORD_FILE in .env}"
[[ -f "$RESTIC_PASSWORD_FILE" ]] || { echo "Missing $RESTIC_PASSWORD_FILE"; exit 1; }
command -v restic >/dev/null || { apt-get update -qq && apt-get install -y -qq restic; }
export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE

echo "== $(date -Is) backup start"

# 1. Consistent Immich database dump (copying live Postgres files is not safe)
DUMP_DIR="$APPDATA/immich/db-dumps"
mkdir -p "$DUMP_DIR"
docker exec immich_postgres pg_dumpall --clean --if-exists --username=postgres \
  | gzip > "$DUMP_DIR/immich-$(date +%F).sql.gz"
find "$DUMP_DIR" -name 'immich-*.sql.gz' -mtime +14 -delete

# 2. Snapshot
restic cat config >/dev/null 2>&1 || restic init
restic backup "$APPDATA" "$PHOTOS" "$ROOT/.env" "$ROOT/stacks/immich/.env" \
  --exclude "$APPDATA/immich/postgres" \
  --exclude "$APPDATA/jellyfin/cache" \
  --exclude "$APPDATA/jellyfin/data/transcodes" \
  --exclude-caches \
  --tag homeserver

# 3. Retention
restic forget --prune --tag homeserver --keep-daily 7 --keep-weekly 4 --keep-monthly 6

echo "== $(date -Is) backup done"
