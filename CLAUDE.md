# CLAUDE.md — homeserver

Home server for a non-technical friend: Immich (photos), AdGuard Home (DNS ad-blocking),
and a Jellyfin streaming pipeline fed by Real-Debrid. Goal: SparkBox-style experience —
fill in `.env`, run one command, everything comes up already wired together and monitored.

Target host: Ubuntu Server 24.04 / Debian 12, x86-64, Docker Compose v2. Scripts run as root.

## Current state (working)
- `install.sh` — installs Docker, frees port 53, creates dirs, checks mount propagation,
  fetches Immich's official release compose + env, starts all stacks. Idempotent.
- `stacks/adguard/compose.yml` — AdGuard Home, host networking.
- `stacks/media/compose.yml` — Decypharr, Prowlarr, FlareSolverr, Sonarr, Radarr, Jellyfin, Seerr.
- `stacks/immich/` — populated at install time from
  `https://github.com/immich-app/immich/releases/latest/download/{docker-compose.yml,example.env}`.
  Never hand-write the Immich compose; its Postgres/VectorChord image is pinned there.
- `update.sh`, `backup.sh` (restic + Immich pg_dumpall), `README.md` (manual wiring steps 1–9).

## Invariants — do not break
- `${DATA}` → `/data` in every container; downloads and media on one filesystem (hardlinks).
  Sonarr/Radarr must hardlink, never copy (copying a symlink streams the whole file from RD).
- `${DEBRID_MOUNT}` (default `/mnt/decypharr`) is mounted at the SAME path on host and in
  every container. Decypharr uses `:rshared`; Sonarr/Radarr/Jellyfin use `:rslave`.
  Decypharr needs `/dev/fuse`, `cap_add: SYS_ADMIN`, `apparmor:unconfined`.
- Decypharr "download uncached" stays OFF. Jellyfin trickplay / chapter images / media segment
  scans stay OFF (full-file reads can get the RD account flagged).
- Inter-app URLs use container names (`http://sonarr:8989`), never host IPs.
- Seerr (`ghcr.io/seerr-team/seerr`) runs as UID 1000 internally; its config dir is chowned 1000.
- Secrets only in `.env` (chmod 600). Nothing secret committed.

## Task 1 — `bootstrap.sh`: auto-wire everything (replaces README steps 1–7)
New `.env` inputs: `RD_API_TOKEN`, `ADMIN_USER`, `ADMIN_PASSWORD` (one login reused for all apps).
Pin image versions in `stacks/media/compose.yml` before writing this (Seerr and Decypharr config
formats change between versions). Verify every API call against the pinned version's docs;
run the stacks locally in Docker and test end to end (everything except real RD downloads).
Must be idempotent: check before create, safe to re-run.

1. **Decypharr** — write `${APPDATA}/decypharr/config.json` before first start.
   Docs: https://sirrobot01.github.io/decypharr/configuration — `debrids[]` (name realdebrid,
   api_key, folder under `${DEBRID_MOUNT}`, use_webdav, rate_limit "250/minute",
   download_uncached false), `qbittorrent` (port 8282, download_folder `/data/downloads/`,
   categories [sonarr, radarr]), rclone/mount settings (mount path `${DEBRID_MOUNT}`, uid/gid,
   allow_other), auth. Check whether the pinned version uses the rclone or the DFS mount schema.
2. **Sonarr / Radarr / Prowlarr** — wait for first start, read `<ApiKey>` from
   `${APPDATA}/<app>/config.xml`. Then via API v3/v1:
   set auth (forms, ADMIN_USER/PASSWORD); root folder (`/data/media/tv`, `/data/media/movies`);
   download client qBittorrent → host `decypharr`, port 8282, username = the arr's own URL
   (`http://sonarr:8989`), password = its API key, category `sonarr`/`radarr`
   (that's how Decypharr registers arrs — see https://sirrobot01.github.io/decypharr/usage).
   Prowlarr: FlareSolverr indexer proxy (`http://flaresolverr:8191`, tag `flaresolverr`),
   Applications → Sonarr + Radarr (full sync), optionally 2–3 default public indexers.
3. **Jellyfin** — complete the startup wizard via the `/Startup/*` endpoints (admin user),
   get a token, create libraries Movies `/data/media/movies` and Shows `/data/media/tv`
   with trickplay + chapter image extraction disabled; disable the matching scheduled tasks.
4. **AdGuard Home** — before the wizard has been run, `POST /control/install/configure`:
   web 0.0.0.0:8053, dns 0.0.0.0:53, admin creds. Then set DoH upstreams (Cloudflare, Quad9)
   and add 1–2 blocklists (OISD big, HaGeZi pro).
5. **Seerr** — initialise against Jellyfin (`http://jellyfin:8096`, admin creds), add Radarr and
   Sonarr servers (hostnames, ports, API keys, root folders, default quality profile), mark
   initialised.
6. **Immich** — create the admin user via the admin sign-up endpoint if no users exist.
7. End by printing a summary: URLs, the single login, and the remaining manual steps
   (router DNS → server IP, Immich phone app, `tailscale up`).

Call bootstrap from the end of `install.sh` when `RD_API_TOKEN` is set.

## Task 2 — monitoring (`stacks/monitoring/` + `healthcheck.sh`)
Design decisions (already made):
- **Alerts go via an external service** (ntfy.sh with an unguessable topic, set in
  `.env` as `NTFY_TOPIC`; Telegram as an optional alternative), so alerts still arrive when the box
  is in trouble. Self-hosted ntfy can't tell you the server is down.
- **Dead-man's switch**: `healthcheck.sh` pings a healthchecks.io URL (`HC_PING_URL`) every run.
  If the whole server dies, healthchecks.io notices the missing pings and alerts.
- **Gatus** (config-file driven, so fully pre-wired, no clicking) for service checks + a status page
  on :8080. Generate `config.yaml` from `.env`. Endpoints:
  every app's HTTP health/ping (Sonarr/Radarr/Prowlarr `/ping`, Jellyfin `/health`,
  Immich `/api/server/ping`, Seerr `/api/v1/status`, Decypharr UI, AdGuard),
  DNS check that AdGuard resolves a normal domain AND returns 0.0.0.0/NXDOMAIN for a known ad
  domain. Alert after 3 failures, resolve notification on recovery.
- **`healthcheck.sh`** (host cron, every 5 min) for things HTTP checks can't see. Push each
  result to a Gatus *external endpoint* (verify the current config syntax + push API in the Gatus
  docs) so everything shows on one status page and Gatus does the alerting:
  - disk usage of `/`, `${APPDATA}`, `${PHOTOS}` (warn 85%, crit 95%)
  - `${DEBRID_MOUNT}` is mounted and non-empty (`mountpoint -q` + `ls`)
  - Real-Debrid premium days left via `GET https://api.real-debrid.com/rest/1.0/user`
    (Bearer RD_API_TOKEN → `expiration`); warn at ≤7 days. This is the most likely silent failure.
  - last successful restic snapshot < 36h old (`restic snapshots --latest 1 --json`)
  - SMART health of each disk (`smartctl -H`; install smartmontools)
  - containers that are unhealthy or restarted >3 times in the last hour
  - memory pressure / OOM kills since last run (`journalctl -k` / `dmesg` for oom-kill)
- **Diun** (optional, off by default): notify via ntfy when image updates exist instead of
  auto-updating. Don't add Watchtower; Immich must not auto-update.
- Optional later: Beszel for CPU/RAM/temperature graphs.

Add monitoring URLs and setup (phone: install ntfy app, subscribe to topic) to README.

## Testing
Run the full stack in local Docker, run `install.sh` + `bootstrap.sh` twice (idempotency), check
every app shows wired-up state via its API, then kill a container and confirm Gatus alerts
fire to a test ntfy topic. `shellcheck -S warning *.sh`; `docker compose config -q` for each stack.
