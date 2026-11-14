#!/usr/bin/env bash
# Pull new images and recreate containers.
#   sudo ./update.sh            -> AdGuard + media stack
#   sudo ./update.sh --immich   -> also Immich (read its release notes first!)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

for stack in adguard media; do
  echo "==> Updating $stack"
  docker compose --env-file "$ROOT/.env" -f "stacks/$stack/compose.yml" pull
  docker compose --env-file "$ROOT/.env" -f "stacks/$stack/compose.yml" up -d
done

if [[ "${1:-}" == "--immich" ]]; then
  echo "==> Updating Immich"
  echo "    If the release notes mention docker-compose.yml changes, re-download it first:"
  echo "    https://github.com/immich-app/immich/releases/latest/download/docker-compose.yml"
  (cd stacks/immich && docker compose pull && docker compose up -d)
else
  echo "Skipped Immich. Run with --immich after checking https://github.com/immich-app/immich/releases"
fi

docker image prune -f
