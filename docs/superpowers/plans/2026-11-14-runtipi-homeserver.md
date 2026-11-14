# Runtipi Home Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One interactive `sudo ./install.sh` turns a fresh Ubuntu Server 26.04 box with two data drives into a Runtipi home server (Immich, AdGuard), with nightly restic backups (optionally copied to B2), plain-language phone alerts, one-command recovery, and an optional Hermes AI helper locked down by the OS.

**Architecture:** Bash only. `install.sh` is a thin orchestrator that sources focused libraries in `lib/` (one responsibility each). Long-running jobs (`backup.sh`, `healthcheck.sh`) run from systemd timers. One root-owned wrapper, `bin/homeserver`, is the only privileged entry point for the friend and the AI helper. Unit tests use bats with PATH-stubbed commands; real behaviour is proven on a throwaway Ubuntu 26.04 VM (libvirt) with two extra virtual disks.

**Tech Stack:** bash 5, whiptail, systemd, restic, smartmontools, qrencode, curl, jq, openssl, Runtipi (pinned version), Docker (installed by Runtipi), Hermes Agent, bats-core, shellcheck, libvirt/virt-install + cloud-init for test VMs.

**Spec:** `docs/superpowers/specs/2026-11-14-runtipi-homeserver-design.md`

## Global Constraints

- Target: Ubuntu Server 26.04 LTS, x86-64, run as root. Refuse anything else (with a plain message).
- Paths: repo `/opt/homeserver`; Runtipi `/opt/runtipi` (the Runtipi installer creates `./runtipi` in the current directory, so run it from `/opt`); data drive mounted at `/opt/runtipi/media`; backup drive at `/mnt/backup`; restic repo `/mnt/backup/restic`; password `/root/.restic-pass` (0600).
- Drive labels: `homedata`, `homebackup` (ext4). A drive with our label is reused, never reformatted. Formatting a foreign drive with partitions requires typing `ERASE`.
- Settings live in `/opt/homeserver/.env` (0600, gitignored). Nothing secret or network-specific is ever committed. The repo is public.
- Runtipi version is pinned in one place (`lib/runtipi.sh: RUNTIPI_VERSION`), set to the version the spike passed on.
- Immich store app files: `${ROOT_FOLDER_HOST}/media/data/images/immich`. Spare folder: `media/data/documents`. Restores land in `media/data/restored/<YYYY-MM-DD>/`.
- Retention: `--keep-daily 7 --keep-weekly 4 --keep-monthly 6`. Backup at 03:00 nightly. Weekly `restic check`. Healthcheck every 5 min.
- Alert thresholds: disk warn 85% / critical 95%; last local backup < 36 h; last cloud copy < 72 h.
- Alerts are sent only on state change (broken → alert, fixed → "all good again"). Every message says what's wrong and what to do, in plain words, with no container names or HTTP codes.
- `/mnt/backup` is mounted read-only except inside a backup/restore run; a `trap` always restores read-only and restarts Runtipi.
- The `helper` user is never in the `docker` group and has no sudo except `/usr/local/bin/homeserver`.
- No command anywhere deletes photos. Restores never write in place.
- All scripts pass `shellcheck -S warning`. All re-runs are idempotent.

## Review Focus

1. **Data drive absent at boot or mid-run** → Runtipi and backups must not start, and nothing writes into the bare `/opt/runtipi/media` on the SSD. Test: Task 3 `guard blocks writes on empty mountpoint` + Task 11 scenario "pull data disk and reboot".
2. **Backup interrupted (power cut, restic error, Ctrl-C)** → apps come back up and `/mnt/backup` returns to read-only. Test: Task 6 `trap restores state when restic fails`.
3. **Re-run on a box set up by an older script version, or with answers changed** → keeps existing drives/secrets, applies only the difference, never re-prompts for `ERASE` on our own drives. Test: Task 8 `rerun with existing env keeps answers as defaults` + Task 11 scenario "run twice, diff state".
4. **Wrong or lost restic password during restore** → clear message ("That password doesn't open this backup. Try again."), three tries, nothing changed on disk. Test: Task 7 `restore with wrong password changes nothing`.
5. **Wrapper given hostile arguments by the AI helper** (`../`, absolute paths, unknown app names, shell metacharacters) → rejected with a plain error and a non-zero exit. Test: Task 7 `wrapper rejects path escapes and unknown apps`.

---

## File Structure

```
install.sh                  orchestrator: self-update, checks, drives, questions, calls lib steps in order
lib/common.sh               log/warn/die, require_root, env_get/env_set (.env read/write), ask_* whiptail helpers
lib/drives.sh               list candidate disks, detect our labels, format, fstab entries, mount guard
lib/runtipi.sh              install pinned Runtipi, cli_token (JWT), api_call, install_app, installed_apps, app_ready
lib/notify.sh               notify (ntfy), state-change tracking, healthchecks.io pings
lib/restic.sh               restic env, repo detection, local + B2 repo helpers
lib/restore.sh              full restore, data-drive restore, single-path restore
lib/helper.sh               Hermes install + helper user + sudoers + approvals
backup.sh                   nightly job (timer)
healthcheck.sh              5-minute checks (timer)
bin/homeserver              privileged wrapper: status|logs|restart|backup-now|snapshots|restore|update
systemd/*.service|*.timer   homeserver-backup, homeserver-check, homeserver-restic-check, runtipi mount drop-in
messages/alerts.sh          every user-facing alert string, in one file (plain-language copy lives here)
GUIDE.md                    friend's guide + AI helper runbook
README.md, CLAUDE.md        rewritten for the new design
archive/                    old stacks/, old install/update/backup, old README/CLAUDE.md + WHY.md
tests/unit/*.bats           bats unit tests with stubs in tests/unit/stubs/
tests/vm/                   up.sh, down.sh, ssh.sh, scenarios/*.sh (integration on a real 26.04 VM)
docs/superpowers/spikes/    spike findings
```

---

### Task 1: Test VM harness

**Files:**
- Create: `tests/vm/up.sh`, `tests/vm/down.sh`, `tests/vm/ssh.sh`, `tests/vm/snapshot.sh`, `tests/vm/cloud-init.yaml`, `tests/vm/README.md`

**Interfaces:**
- Produces: `tests/vm/up.sh [--fresh]` → boots VM `hs-test` (4 vCPU, 8 GB RAM, 30 GB system disk from `https://cloud-images.ubuntu.com/resolute/current/resolute-server-cloudimg-amd64.img`, plus two blank 20 GB qcow2 disks `vdb`/`vdc` with serials `DATA01`/`BACKUP01`), prints its IP. `tests/vm/ssh.sh <cmd>` runs a command as root in it. `tests/vm/snapshot.sh save|revert <name>`. `tests/vm/down.sh` destroys VM and disks. The repo is copied in with `rsync` to `/opt/homeserver` by `ssh.sh --sync`.
- VM images and disks live under `~/.cache/hs-test/` (never in the repo).

- [ ] **Step 1:** Write the scripts with `virt-install --import --cloud-init user-data=tests/vm/cloud-init.yaml` (`qemu:///session`, user networking with port-forward or default NAT; pick whichever works without root and document it). cloud-init adds the host's `~/.ssh/id_*.pub` to root.
- [ ] **Step 2:** Run `tests/vm/up.sh --fresh && tests/vm/ssh.sh 'lsb_release -rs; lsblk -dno NAME,SERIAL,SIZE'`. Expected: `26.04`, and `vdb DATA01 20G`, `vdc BACKUP01 20G`.
- [ ] **Step 3:** `tests/vm/snapshot.sh save clean && tests/vm/snapshot.sh revert clean` succeeds.
- [ ] **Step 4:** Commit `test: add Ubuntu 26.04 VM harness`.

### Task 2: Spike — Runtipi on the data drive + API install (throwaway, gate)

Not product code. No tests. Its only output is a findings note and a pinned version. **Do not start Task 3 until this passes or the fallback is chosen.**

**Files:**
- Create: `docs/superpowers/spikes/2026-11-runtipi-spike.md`

- [ ] **Step 1:** On a clean VM: format `vdb` ext4 label `homedata`, mount it at `/opt/runtipi/media`, then `cd /opt && curl -L https://setup.runtipi.io | bash`. Record the version installed (`/opt/runtipi/runtipi-cli version`).
- [ ] **Step 2:** Install Immich through the API, without the dashboard: build an HS256 JWT `{"sub":"cli"}` with `JWT_SECRET` from `/opt/runtipi/.env` (openssl + base64url in bash), `POST http://localhost:${NGINX_PORT:-80}/api/app-lifecycle/immich:<store>/install` with a JSON body of the form fields (`DB_PASSWORD`, `JWT_SECRET`, `IMMICH_TYPESENSE_API_KEY`, random) plus whatever the body type in `packages/frontend/src/api-client/types.gen.ts` requires (e.g. `exposedLocal`, `port`). Find the real store id in `/opt/runtipi/apps/`. Poll `/api/app-lifecycle/{urn}/job` or `/api/apps/installed` until running.
  - Record: exact URN, request body, auth header, whether a dashboard admin account must exist first.
- [ ] **Step 3:** Upload one photo via Immich's web UI or API. Check: `ls /opt/runtipi/media/data/images/immich` shows it and `findmnt -T` of that path is `vdb`.
- [ ] **Step 4:** Install AdGuard the same way. Record: does it bind port 53 (after freeing systemd-resolved)? How is its setup wizard reached?
- [ ] **Step 5:** Update Runtipi to a newer version (or `update` re-run of the same version if none newer) and update Immich. Check the photo and the mount survive.
- [ ] **Step 6:** Record where app data, DBs and Runtipi state live under `/opt/runtipi` (for backup include/exclude), the Immich Postgres container name, and whether `runtipi-cli stop/start` cleanly stops all apps.
- [ ] **Step 7:** Decide and record:
  - Step 3 passed → proceed as designed.
  - Step 3 failed → retry with `user-config/<store>/immich/docker-compose.yml` overriding the volumes. Pass → proceed with per-app overrides (note it for Task 4). Fail → **stop and report to the owner.**
  - Step 2 failed → installer uses the "click Install in the dashboard" ending (Task 4 `install_app` returns 2).
- [ ] **Step 8:** Commit the findings note: `docs: record Runtipi spike findings`.

### Task 3: Repo skeleton, archive, common helpers, drives

**Files:**
- Create: `archive/WHY.md`; move `stacks/`, `install.sh`, `update.sh`, `backup.sh`, `README.md`, `CLAUDE.md`, `.env.example` into `archive/` with `git mv`
- Create: `lib/common.sh`, `lib/drives.sh`, `tests/unit/common.bats`, `tests/unit/drives.bats`, `tests/unit/stubs/` (stub `lsblk`, `blkid`, `mkfs.ext4`, `mount`, `findmnt`, `whiptail`), `Makefile` (`make test` = shellcheck + bats)
- Create: `systemd/runtipi-requires-data.conf` (drop-in used by Task 4)

**Interfaces:**
- Produces (`lib/common.sh`): `log MSG`, `warn MSG`, `die MSG` (exit 1); `require_root`; `env_get KEY [DEFAULT]`; `env_set KEY VALUE` (create/replace a line in `$HS_ENV`, default `/opt/homeserver/.env`, keeps mode 0600, quotes values safely); `ask_yesno TITLE TEXT DEFAULT(yes|no)` → exit status; `ask_text TITLE TEXT DEFAULT` → stdout; `ask_password TITLE TEXT` → stdout; `ask_checklist TITLE TEXT TAG:LABEL:on|off...` → space-separated tags; `ask_menu TITLE TEXT TAG:LABEL...` → tag. All `ask_*` honour `HS_NONINTERACTIVE=1` by reading `HS_ANSWER_<KEY>` env vars (used by tests and VM scenarios).
- Produces (`lib/drives.sh`): `list_candidate_disks` → lines `NAME|SIZE|MODEL|SERIAL|LABEL|HASPARTS` excluding the disk holding `/`; `disk_has_label DEV LABEL`; `prepare_disk DEV LABEL` (no-op if label already ours; else requires `confirm_erase` when it has partitions; GPT + single ext4 partition with that label); `ensure_fstab LABEL MOUNTPOINT OPTIONS` (by `LABEL=`, `nofail,x-systemd.device-timeout=10s`; idempotent); `guard_mountpoint DIR` (when unmounted: `chattr +i` on the empty dir so nothing can write into it); `is_mounted DIR`.

- [ ] **Step 1: Write the failing tests**

```bash
# tests/unit/common.bats
@test "env_set creates file 0600 and env_get reads it back" {
  HS_ENV="$BATS_TEST_TMPDIR/.env" env_set APPS "immich adguard"
  [ "$(HS_ENV="$BATS_TEST_TMPDIR/.env" env_get APPS)" = "immich adguard" ]
  [ "$(stat -c %a "$BATS_TEST_TMPDIR/.env")" = "600" ]
}
@test "env_set replaces existing key, keeps others" { ... two keys, set one twice, both present, one line each ... }
@test "env_set survives values with spaces, quotes and \$" { ... }
@test "ask_yesno uses HS_ANSWER_ in noninteractive mode" { HS_NONINTERACTIVE=1 HS_ANSWER_HELPER=no run ask_yesno HELPER "?" yes; [ "$status" -ne 0 ]; }

# tests/unit/drives.bats  (stubs: lsblk reports sda=/ , sdb blank, sdc labelled homebackup)
@test "list_candidate_disks never lists the system disk" { run list_candidate_disks; refute_output --partial "sda|"; }
@test "prepare_disk on a disk with our label does not format" { prepare_disk /dev/sdc homebackup; [ ! -e "$STUB_LOG/mkfs.ext4" ]; }
@test "prepare_disk on a foreign partitioned disk requires ERASE" { HS_NONINTERACTIVE=1 HS_ANSWER_ERASE=nope run prepare_disk /dev/sdd homedata; [ "$status" -ne 0 ]; [ ! -e "$STUB_LOG/mkfs.ext4" ]; }
@test "ensure_fstab is idempotent" { ensure_fstab homedata /opt/runtipi/media defaults; ensure_fstab homedata /opt/runtipi/media defaults; [ "$(grep -c LABEL=homedata "$HS_FSTAB")" = 1 ]; }
@test "guard blocks writes on empty mountpoint" { ... findmnt stub says not mounted; guard_mountpoint DIR; chattr stub called with +i DIR ... }
```

- [ ] **Step 2:** `make test` → the new tests FAIL (functions not defined).
- [ ] **Step 3:** Implement `lib/common.sh` and `lib/drives.sh` with the signatures above. `HS_FSTAB` defaults to `/etc/fstab` (overridable for tests). `confirm_erase DEV` shows the model/size/partitions and requires the exact word `ERASE`. Write `archive/WHY.md` (3–5 lines: the friend doesn't want media now, so the Real-Debrid stack is parked here; how to revive it). `.gitignore` keeps `.env`, `.superpowers/`.
- [ ] **Step 4:** `make test` → PASS, shellcheck clean.
- [ ] **Step 5:** Commit `feat: common helpers and drive preparation; archive old stack`.

### Task 4: Runtipi install + app API

**Files:**
- Create: `lib/runtipi.sh`, `tests/unit/runtipi.bats`, `systemd/runtipi.service` (or a drop-in, per spike) with `RequiresMountsFor=/opt/runtipi/media`

**Interfaces:**
- Consumes: `lib/common.sh`; spike findings (URN format, body, port, store id).
- Produces: `RUNTIPI_VERSION` (pinned), `RUNTIPI_DIR=/opt/runtipi`; `runtipi_install` (no-op when installed at a version ≥ pinned; otherwise `cd /opt && curl -L https://setup.runtipi.io | bash -s -- --version "$RUNTIPI_VERSION"`; then installs the systemd unit so Runtipi only starts when the data drive is mounted, and disables any other autostart the installer added); `runtipi_cli ARGS...`; `cli_token` → JWT on stdout; `api_call METHOD PATH [JSON]` → body on stdout, non-zero on HTTP ≥ 400; `installed_apps` → one app id per line; `install_app ID` → 0 installed/already installed, 1 failed, 2 API unavailable (caller falls back to the dashboard message); `app_ready ID` → 0 when the app answers its health URL. App table (id, store URN, health URL, required random fields) lives in one array in this file: `immich` → `/api/server/ping`; `adguard` → its web UI.

- [ ] **Step 1: Write the failing tests** (stub `curl` records requests; stub `.env` has `JWT_SECRET=testsecret`)

```bash
@test "cli_token is a valid HS256 JWT with sub=cli" {
  t=$(cli_token); IFS=. read -r h p s <<<"$t"
  [ "$(b64url_decode "$p" | jq -r .sub)" = cli ]
  [ "$s" = "$(printf '%s.%s' "$h" "$p" | openssl dgst -sha256 -hmac testsecret -binary | b64url)" ]
}
@test "install_app posts to app-lifecycle install with random secrets" { install_app immich; grep -q 'POST .*/api/app-lifecycle/immich:.*/install' "$STUB_LOG/curl"; grep -q DB_PASSWORD "$STUB_LOG/curl"; }
@test "install_app skips apps already installed" { STUB_INSTALLED=immich install_app immich; ! grep -q /install "$STUB_LOG/curl"; }
@test "install_app returns 2 when the API route 404s" { STUB_HTTP=404 run install_app immich; [ "$status" -eq 2 ]; }
@test "runtipi_install refuses to run when data drive is not mounted" { STUB_MOUNTED=no run runtipi_install; [ "$status" -ne 0 ]; }
```

- [ ] **Step 2:** `make test` → FAIL.
- [ ] **Step 3:** Implement per the Interfaces block. Generated secrets: `openssl rand -hex 24`.
- [ ] **Step 4:** `make test` → PASS. Then on the VM (after Task 3's drive prep, by a small `tests/vm/scenarios/runtipi.sh`): `install_app immich && app_ready immich` → exit 0.
- [ ] **Step 5:** Commit `feat: pinned Runtipi install and app install via API`.

### Task 5: Alerts (`notify.sh`, `healthcheck.sh`, alert copy)

**Files:**
- Create: `lib/notify.sh`, `messages/alerts.sh`, `healthcheck.sh`, `systemd/homeserver-check.{service,timer}`, `tests/unit/notify.bats`, `tests/unit/healthcheck.bats`

**Interfaces:**
- Consumes: `installed_apps`, `app_ready` (Task 4); `is_mounted` (Task 3); `restic_last_snapshot_age REPO` (Task 6; stub here until then).
- Produces: `notify TITLE BODY [PRIORITY]` → POST `https://ntfy.sh/$NTFY_TOPIC` (Title/Priority headers); `set_state CHECK ok|bad MESSAGE_ID` (state files in `/var/lib/homeserver/state/`; sends the alert on ok→bad and `msg_recovered` on bad→ok; nothing on no change); `hc_ping SLUG [fail]` → healthchecks.io ping if the matching URL is set (`HC_ALIVE_URL`, `HC_BACKUP_URL`). `messages/alerts.sh` defines `msg_<id>` functions returning `title|body` for: `app_down <app>`, `adblock_down`, `drive_missing <which>`, `disk_warn <which> <pct>`, `disk_crit <which> <pct>`, `smart_fail <which>`, `backup_stale`, `cloud_stale`, `backup_damaged`, `app_crashloop <app>`, `oom <app>`, `recovered <what>`. Friendly app names: immich → "Photos", adguard → "The ad blocker".
- Checks (exactly the spec table): each installed app ready; AdGuard resolves `example.com` and blocks `doubleclick.net` (`dig @127.0.0.1`); both drives mounted; disk use 85/95% for `/`, data, backup; `smartctl -H` per drive; last local snapshot < 36 h; last cloud copy < 72 h when `B2_BUCKET` set; containers with > 3 restarts in an hour or OOM kills since last run. Finishes with `hc_ping alive`.

- [ ] **Step 1: Write the failing tests**

```bash
@test "set_state alerts once on ok->bad, then silent, then recovered" {
  set_state immich bad app_down; set_state immich bad app_down; set_state immich ok app_down
  [ "$(grep -c '^POST' "$STUB_LOG/curl")" = 2 ]
  grep -q 'Photos' "$STUB_LOG/curl"; grep -q 'all good again' "$STUB_LOG/curl"
}
@test "no alert for apps that are not installed" { STUB_INSTALLED=immich run ./healthcheck.sh; ! grep -qi 'ad blocker' "$STUB_LOG/curl"; }
@test "alert copy never contains jargon" {
  for id in $(alert_ids); do out=$(msg_$id immich data 90); ! grep -Eiq 'container|docker|http|[0-9]{3} |immich-server|restic' <<<"$out"; done
}
@test "disk at 86% warns, at 96% is critical" { ... stub df ...; assert body contains "85%"-style text and priority high for 96 ... }
@test "healthcheck pings alive URL even when a check fails" { ... }
```

- [ ] **Step 2:** `make test` → FAIL.
- [ ] **Step 3:** Implement. Copy pattern for every message: what's wrong + what to do + guide section, e.g. app_down → `Photos aren't working|Open the dashboard and press Restart on Photos. If that doesn't fix it, see the guide: "An app is broken".`
- [ ] **Step 4:** `make test` → PASS.
- [ ] **Step 5:** Commit `feat: plain-language health checks and ntfy alerts`.

### Task 6: Nightly backup + optional B2 copy

**Files:**
- Create: `lib/restic.sh`, `backup.sh`, `systemd/homeserver-backup.{service,timer}` (03:00, `Persistent=true`), `systemd/homeserver-restic-check.{service,timer}` (weekly), `tests/unit/backup.bats`

**Interfaces:**
- Consumes: `runtipi_cli` (Task 4), `notify`/`set_state`/`hc_ping` (Task 5), `is_mounted` (Task 3).
- Produces (`lib/restic.sh`): `restic_local` / `restic_cloud ARGS...` (wrappers setting `RESTIC_REPOSITORY`, `RESTIC_PASSWORD_FILE`, B2 creds from `.env`: `B2_BUCKET`, `B2_ACCOUNT_ID`, `B2_ACCOUNT_KEY`; cloud repo `b2:$B2_BUCKET:homeserver`); `repo_exists local|cloud`; `restic_last_snapshot_age local|cloud` → seconds; `backup_paths` → include list; `backup_excludes` → exclude list (from spike Step 6: caches, Immich thumbs/encoded-video, anything under `media/` other than `data/images/immich` and `data/documents`, live Postgres is fine because apps are stopped); `with_backup_rw CMD...` (remount rw → run → always remount ro via trap).
- `backup.sh`: refuse if either drive is not mounted (alert `drive_missing`); `with_backup_rw` { init repo if missing; `runtipi_cli stop`; `restic backup --tag homeserver` the paths, plus a small `meta.json` with `RUNTIPI_VERSION`, apps and date; `runtipi_cli start` (in trap too); `forget --prune` with the retention }; then if `B2_BUCKET` set: `restic copy --from-repo` local → cloud, `forget --prune` there; cloud failure alerts `cloud_stale`-style but exits 0 for the local result. `backup.sh --check` runs `restic check` (alert `backup_damaged` on failure). Success → `hc_ping backup`.

- [ ] **Step 1: Write the failing tests**

```bash
@test "trap restores state when restic fails" {
  STUB_RESTIC_FAIL=backup run ./backup.sh
  [ "$status" -ne 0 ]
  grep -q 'runtipi-cli start' "$STUB_LOG/calls"; tail -1 "$STUB_LOG/mount" | grep -q 'remount,ro /mnt/backup'
}
@test "refuses to back up when the data drive is missing" { STUB_MOUNTED_DATA=no run ./backup.sh; [ "$status" -ne 0 ]; ! grep -q 'restic backup' "$STUB_LOG/calls"; }
@test "movies and tv are excluded, photos and documents included" { run backup_paths; assert_output --partial images/immich; run backup_excludes; assert_output --partial media/data/movies; }
@test "cloud copy failure does not fail the local backup" { B2_BUCKET=b STUB_RESTIC_FAIL=copy run ./backup.sh; [ "$status" -eq 0 ]; }
@test "retention flags match spec" { ./backup.sh; grep -q -- '--keep-daily 7 --keep-weekly 4 --keep-monthly 6' "$STUB_LOG/calls"; }
```

- [ ] **Step 2:** `make test` → FAIL.
- [ ] **Step 3:** Implement per the Interfaces block.
- [ ] **Step 4:** `make test` → PASS. On the VM: run `backup.sh` with Immich installed; `restic_local snapshots` lists one; `findmnt -no OPTIONS /mnt/backup` starts with `ro`. Point a test B2 bucket (owner-provided creds, or a local `rest-server` / MinIO S3 stand-in if none) and confirm the copy.
- [ ] **Step 5:** Commit `feat: nightly restic backup with optional B2 copy`.

### Task 7: Restore + `homeserver` wrapper

**Files:**
- Create: `lib/restore.sh`, `bin/homeserver`, `tests/unit/restore.bats`, `tests/unit/wrapper.bats`

**Interfaces:**
- Consumes: Tasks 3–6.
- Produces (`lib/restore.sh`): `restore_full SOURCE(local|cloud) SNAPSHOT` (stop Runtipi if running; restore `/opt/runtipi` + media paths + `.env` from the snapshot; install the `RUNTIPI_VERSION` recorded in `meta.json`; start; wait `app_ready` for every app in it; report what's up); `restore_data_drive SNAPSHOT` (only `media/data/images/immich` + `documents` onto a fresh data drive, then start Runtipi); `restore_path SNAPSHOT PATH` (into `media/data/restored/<YYYY-MM-DD>/`, never in place); `prompt_repo_password` (3 tries; checks with `restic cat config` before anything changes on disk; writes `/root/.restic-pass` only after success).
- `bin/homeserver` (installed to `/usr/local/bin/homeserver`, root:root 0755): subcommands `status`, `logs <app> [lines≤500]`, `restart <app>`, `backup-now`, `snapshots`, `restore [<snapshot> <path>]` (no args → whiptail: pick a date, then a folder/album path), `update <app>`. `<app>` must be in `installed_apps`; `<path>` must be relative, under `data/images/immich` or `data/documents`, and contain no `..`; `<snapshot>` must match `^[0-9a-f]{8,64}$|^latest$`. No delete subcommand exists.

- [ ] **Step 1: Write the failing tests**

```bash
@test "restore with wrong password changes nothing" { HS_NONINTERACTIVE=1 HS_ANSWER_PASSWORD=wrong run restore_full local latest; [ "$status" -ne 0 ]; ! grep -q 'restic restore' "$STUB_LOG/calls"; [ ! -e /root/.restic-pass.test ]; }
@test "restore_path writes into restored/<date>, never in place" { restore_path abc12345 data/images/immich/library/x; grep -q -- "--target .*media/data/restored/$(date +%F)" "$STUB_LOG/calls"; }
@test "wrapper rejects path escapes and unknown apps" {
  run bin/homeserver restore latest ../../etc;          [ "$status" -ne 0 ]
  run bin/homeserver restore latest /etc/shadow;        [ "$status" -ne 0 ]
  run bin/homeserver restart 'immich;rm -rf /';         [ "$status" -ne 0 ]
  run bin/homeserver restart jellyfin;                  [ "$status" -ne 0 ]
}
@test "wrapper has no delete-like subcommand" { for c in delete rm remove prune forget uninstall; do run bin/homeserver $c x; [ "$status" -ne 0 ]; done; }
@test "full restore installs the Runtipi version recorded in the backup" { ... meta.json RUNTIPI_VERSION=v4.12.0 → runtipi_install called with it ... }
```

- [ ] **Step 2:** `make test` → FAIL.
- [ ] **Step 3:** Implement per the Interfaces block.
- [ ] **Step 4:** `make test` → PASS.
- [ ] **Step 5:** Commit `feat: restore paths and the homeserver wrapper`.

### Task 8: `install.sh` orchestration

**Files:**
- Create: `install.sh`, `tests/unit/install.bats`

**Interfaces:**
- Consumes: everything above.
- Flow (spec "Install flow", steps 0–9, in order): self-update (`git -C /opt/homeserver pull --ff-only`, re-exec with `HS_UPDATED=1` once; skip silently when offline or not a git checkout) → checks (root, `lsb_release -rs` = 26.04, `uname -m` = x86_64, ≥ 8 GB RAM, `curl -fsS https://ntfy.sh` reachable; warn about the fixed-IP requirement) → drives (`ask_menu` data, then backup from `list_candidate_disks`, `prepare_disk`, `ensure_fstab`, mount, guard) → restore check (`repo_exists local`; else ask "Did you set up an online copy?" → B2 creds → `repo_exists cloud`; found → "Found a backup from <date>. Restore everything?" → `prompt_repo_password` → `restore_full` → finish screen) → questions (apps checklist `immich:Photos (Immich):on adguard:Ad blocker (AdGuard Home):on`; ntfy topic `hs-$(openssl rand -hex 8)` shown as `qrencode -t ansiutf8 "https://ntfy.sh/$topic"`; optional `HC_ALIVE_URL`/`HC_BACKUP_URL` with the strong warning text from the spec if skipped; optional B2 with a live `restic_cloud cat config || init` check; helper yes/no default no) → `env_set` every answer (re-runs use them as defaults) → system prep (`apt-get install -y restic smartmontools qrencode jq dnsutils unattended-upgrades`; free port 53 when adguard is picked — port the old `archive/install.sh` block) → `runtipi_install` → `install_app` each (collect rc=2 into a "click Install" list) → copy `systemd/*`, `bin/homeserver`, enable timers → first `backup.sh` → `helper_setup` if chosen (Task 9) → finish screen (URL `http://<ip>`, next steps from the spec, dashboard-install list if any, guide path) → on first install only: show the generated restic password and require it typed back.
- Un-ticked apps on re-run are not uninstalled.

- [ ] **Step 1: Write the failing tests** (all lib functions stubbed, `HS_NONINTERACTIVE=1`)

```bash
@test "refuses non-26.04 hosts with a plain message" { STUB_RELEASE=24.04 run ./install.sh; [ "$status" -ne 0 ]; assert_output --partial "Ubuntu Server 26.04"; }
@test "rerun with existing env keeps answers as defaults" { printf 'APPS="immich"\nNTFY_TOPIC=hs-abc\n' >"$HS_ENV"; ./install.sh; [ "$(env_get NTFY_TOPIC)" = hs-abc ]; ! grep -q 'install_app adguard' "$STUB_LOG/calls"; }
@test "found backup + yes skips questions and runs restore_full" { STUB_REPO_LOCAL=yes HS_ANSWER_RESTORE=yes ./install.sh; grep -q restore_full "$STUB_LOG/calls"; ! grep -q 'ask_checklist' "$STUB_LOG/calls"; }
@test "API failure ends with click-Install instructions, exit 0" { STUB_INSTALL_RC=2 run ./install.sh; [ "$status" -eq 0 ]; assert_output --partial "click Install"; }
@test "skipping healthchecks shows the warning" { HS_ANSWER_HC_ALIVE_URL= run ./install.sh; assert_output --partial "nobody gets told if the server dies"; }
@test "password must be typed back on first install" { HS_ANSWER_PASSWORD_CONFIRM=wrong run ./install.sh; [ "$status" -ne 0 ]; }
```

- [ ] **Step 2:** `make test` → FAIL.
- [ ] **Step 3:** Implement. Keep `install.sh` a list of calls; any logic over ~10 lines belongs in a lib.
- [ ] **Step 4:** `make test` → PASS.
- [ ] **Step 5:** Commit `feat: interactive installer`.

### Task 9: Optional AI helper (Hermes)

**Files:**
- Create: `lib/helper.sh`, `helper/AGENTS.md` (points at `GUIDE.md` + the wrapper), `systemd/hermes-gateway.service`, `sudoers/homeserver-helper`, `tests/unit/helper.bats`, `tests/vm/scenarios/helper-lockdown.sh`

**Interfaces:**
- Consumes: `bin/homeserver` (Task 7), `ask_yesno` (Task 3).
- Produces: `helper_setup` (create system user `helper` with home `/var/lib/helper`, shell bash, no password, not in `docker`/`sudo`; install `sudoers/homeserver-helper` = `helper ALL=(root) NOPASSWD: /usr/local/bin/homeserver` validated with `visudo -cf`; install Hermes as `helper` using its official Linux installer; run `hermes setup` and `hermes gateway setup` interactively as `helper` so Hermes asks for the chat app + AI key itself; write Hermes config: allowed users restricted to the account paired during setup, command approval required for `homeserver restore` and `homeserver update` and anything not in {`sudo homeserver status|logs|restart|backup-now|snapshots`}, instructions = `helper/AGENTS.md`, a daily 09:00 scheduled task "run `sudo homeserver status` and send me all good or what's wrong"; enable `hermes-gateway.service` as `helper`); `helper_remove` (stop/disable service, remove sudoers file, keep the user's data). Exact Hermes config keys/commands: take from Hermes docs at build time and record them in `lib/helper.sh` comments.

- [ ] **Step 1: Write the failing tests**

```bash
@test "sudoers file only allows the wrapper" { run grep -v '^#' sudoers/homeserver-helper; assert_output "helper ALL=(root) NOPASSWD: /usr/local/bin/homeserver"; }
@test "helper_setup never adds helper to docker group" { helper_setup; ! grep -q 'usermod.*docker' "$STUB_LOG/calls"; ! grep -q 'gpasswd.*docker' "$STUB_LOG/calls"; }
```
VM scenario `helper-lockdown.sh` (run as `helper`): `docker ps` fails; `sudo -n true` fails; `sudo -n homeserver status` succeeds; `touch /mnt/backup/x` fails; `rm /opt/runtipi/media/data/images/immich/*` fails (permission denied); `sudo -n homeserver restore latest ../x` fails.

- [ ] **Step 2:** `make test` → FAIL.
- [ ] **Step 3:** Implement. Ensure photo files are not writable by `helper` (they're root/Immich-owned; check after spike).
- [ ] **Step 4:** `make test` → PASS; run `tests/vm/scenarios/helper-lockdown.sh` on the VM → all checks as stated.
- [ ] **Step 5:** Commit `feat: optional Hermes AI helper with OS-level guardrails`.

### Task 10: Guide, README, CLAUDE.md

**Files:**
- Create: `GUIDE.md`; rewrite `README.md`, `CLAUDE.md`

- [ ] **Step 1:** `GUIDE.md` sections exactly: "What's on your server" (addresses), "Set your router to use the ad blocker" (and the fixed-IP warning), "Set up your phone" (Immich app, ntfy app + topic), "An app is broken", "Get back a deleted photo" (Immich trash first, 30 days; then `sudo homeserver restore`, then upload through Immich's web page), "A drive died" (the spec's recovery table rewritten as steps), "Your backup password", "Updating" (in the morning, after the nightly backup), "Adding an app", "Setting up healthchecks.io" and "Setting up Backblaze" (account → bucket → key, what to paste). Each alert message's guide reference must match a heading here.
- [ ] **Step 2:** `README.md`: what this is, requirements (spec "Hardware and constraints"), install (`sudo git clone https://github.com/<owner>/homeserver /opt/homeserver && cd /opt/homeserver && sudo ./install.sh`), link to GUIDE.md. `CLAUDE.md`: dev notes — layout, invariants (Global Constraints), `make test`, the VM harness, the pinned Runtipi version and how to bump it (re-run spike steps 2–5).
- [ ] **Step 3:** Check every `see the guide: "…"` string in `messages/alerts.sh` matches a `GUIDE.md` heading: `grep -o 'guide: "[^"]*"' messages/alerts.sh | sort -u` vs `grep '^## ' GUIDE.md`.
- [ ] **Step 4:** Commit `docs: friend's guide, README and dev notes`.

### Task 11: End-to-end VM scenarios

**Files:**
- Create: `tests/vm/scenarios/{fresh-install,rerun,data-missing,alerts,photo-restore,recover-ssd,recover-data,recover-cloud}.sh`, `tests/vm/run-all.sh`

Each scenario reverts the VM to `clean` (or a named snapshot), syncs the repo, runs non-interactively with `HS_ANSWER_*`, and asserts with plain shell checks; non-zero exit on failure.

- [ ] **Step 1: fresh-install** — install with both apps, helper off. Assert: Immich and AdGuard answer; `dig @<vm> doubleclick.net` blocked; one snapshot exists; `/mnt/backup` is `ro`; timers enabled.
- [ ] **Step 2: rerun** — run again; capture `/opt/homeserver/.env`, `/etc/fstab`, `docker ps --format '{{.Names}}'`, `restic snapshots` count before/after. Assert identical except one more snapshot at most. Then change answers (add helper, untick adguard) and re-run: helper installed, AdGuard still installed.
- [ ] **Step 3: data-missing** — detach `vdb` (`virsh detach-disk`), reboot. Assert: Runtipi not running; `/opt/runtipi/media` empty and immutable; ntfy test topic got `drive_missing`. Reattach, reboot: everything up and a "recovered" message.
- [ ] **Step 4: alerts** — `docker stop` Immich's server container: within 10 min one "Photos aren't working" on the test topic; start it: one recovery message; no duplicates.
- [ ] **Step 5: photo-restore** — upload a photo via Immich API, back up, delete it and empty trash, `homeserver restore latest data/images/immich/...` → file appears under `restored/<today>/`, original location untouched.
- [ ] **Step 6: recover-ssd** — after fresh-install + one uploaded photo + backup: replace system disk with a new blank cloud image (keep vdb/vdc), clone, run install with `HS_ANSWER_RESTORE=yes` and the saved password. Assert: same Immich users/albums/photo count; same ntfy topic; timers enabled.
- [ ] **Step 7: recover-data** — replace `vdb` with a blank disk, run install. Assert: photos back, Immich shows them.
- [ ] **Step 8: recover-cloud** — with B2 (or the S3 stand-in) enabled and a backup copied: replace all three disks, install, choose the online copy. Assert as Step 6.
- [ ] **Step 9:** `tests/vm/run-all.sh` runs all scenarios in order and prints a pass/fail table. Run it → all PASS.
- [ ] **Step 10:** Commit `test: end-to-end VM scenarios`.

---

## Self-review notes

- Spec coverage: disk layout & guard (T3, T4), install flow 0–9 (T8), API install + fallback (T2, T4, T8), backups + B2 + weekly check (T6), recovery table + single photos (T7, T11), alerts table (T5), updates (unattended-upgrades in T8, guide in T10), guide (T10), helper (T9), repo changes/archive (T3, T10), testing list (T11, T9 lockdown), calls made (wrapper always installed T8; no uninstall on untick T8; fallback order T2).
- Left to the builder per spec: whiptail wording, exact Runtipi paths (from spike), AdGuard port-53 details (spike), Hermes config specifics (T9), installed-apps source (T4 uses API).
