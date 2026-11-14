# Home server for a non-technical friend: Runtipi rebuild

Date: 2026-11-14
Status: draft, awaiting approval

## Why

The owner (Aadil) is setting up a home server for a friend who is not technical. The friend
should **run and manage it himself**, without Aadil. The previous design (fixed Docker Compose
stacks + Jellyfin/Real-Debrid pipeline, see `CLAUDE.md`) assumed one fixed set of apps that
Aadil would look after. The friend doesn't want any media server right now, and he should be
able to pick what he runs and add more later without help.

What success looks like: the friend clones the repo, runs one command, answers a few questions,
and ends up with a working photo backup and ad blocker. From then on he uses a browser dashboard
and his phone. He gets plain-language alerts when something breaks, has a guide for fixing it,
and can optionally message an AI helper that fixes things for him.

## Goals

- One interactive installer on a fresh Ubuntu Server 26.04 box: `git clone … && sudo ./install.sh`.
- The friend picks his apps during install. At launch the menu has **Immich** (photos) and
  **AdGuard Home** (ad blocking). He can add anything else later from Runtipi's app store.
- Photos and the whole app system are backed up every night to a second drive, without anyone doing anything.
  Optionally also copied to the cloud (Backblaze B2), so a fire, theft or surge doesn't take both copies.
- If any drive dies, recovery is the same `git clone` + `sudo ./install.sh` he did on day one: it finds the backup
  and offers to restore everything.
- Plain-language phone alerts when an app, a drive or the backup has a problem, plus a
  "server went silent" alarm.
- A plain-language guide for the common jobs. It doubles as the AI helper's instructions.
- An **optional** AI helper (Hermes Agent). The installer asks whether he wants it.
- Safe to re-run. Re-running is also how he changes his answers.

## Non-goals (for now)

- Jellyfin / Sonarr / Radarr / Prowlarr / Decypharr / Seerr / Real-Debrid. The friend doesn't want
  a media server. The existing setup is archived, not deleted.
- Navidrome / music.
- RAID. Owner decision: two separate drives, one for data and one for backups.
  Downside accepted: if the data drive dies, the server is down until it's replaced and restored.
- Remote access from outside the home (Tailscale etc.). The dashboard is only reachable on the home network.
  The AI helper works from anywhere because it goes through a chat app. *(Builder's assumption, see "Calls made".)*

## Anti-goals (failure even if it "works")

- Losing photos. That includes the AI helper deleting them, and apps quietly writing photos to the
  SSD because the data drive wasn't mounted.
- The friend needing a terminal after install for everyday tasks.
- Alerts in jargon ("immich-server 503"). Every message must say what's wrong and what to do.
- The installer wiping a drive that has data on it without a clear, explicit confirmation.

## Hardware and constraints

- x86-64 machine, SSD for Ubuntu + apps, plus a DAS with two 4 TB HDDs, used as separate drives.
- Ubuntu Server 26.04 LTS. 8 GB RAM minimum (Immich machine learning), 16 GB comfortable.
- The server needs a fixed LAN IP (DHCP reservation), or AdGuard breaks the home internet when it
  changes. The installer warns about this, and the guide covers it.
- Secrets live only on the server, never in git. The repo goes on GitHub as a **public** repo, so a fresh box can
  `git clone` it with no credentials. Nothing in it may be secret or specific to the friend's network.

## Approaches considered

**Platform**

| | Picked? | Why |
|---|---|---|
| **Runtipi** (app-store dashboard on top of Ubuntu) | ✅ | Actively maintained (v4.12.0, 31 Oct 2026). Has Immich, AdGuard and the future media apps in its store. The friend adds and removes apps himself. |
| ReCasaOS (community CasaOS fork) | ❌ | Tested on 26.04 and has backups, alerts and RAID built in, but it only started in Sept 2026 with a tiny community. Upstream CasaOS was abandoned in 2025. Too risky for a box that should run for years. |
| Our own Compose stacks (current repo) + Portainer | ❌ | The friend can't add apps without a terminal or Portainer's Docker-jargon UI. Only worth it if the Real-Debrid pipeline becomes a priority. |

**Installer**

| | Picked? | Why |
|---|---|---|
| **A. One interactive bash script, run from a git clone** | ✅ | Least new machinery, builds on the existing `install.sh`, and he can run it himself. |
| B. Custom install USB / first-boot wizard | ❌ | A separate project (custom Ubuntu images). Could later be wrapped around A. |
| C. Ansible | ❌ | Built for engineers, and its interactive prompts are clunky. |

**AI helper**: Hermes Agent (Nous Research, MIT, very active) was picked over Claude Code / Pi
because it's messaged from a phone chat app (Telegram, WhatsApp, Signal…), supports many
model providers, and has scheduled tasks and command approval.

## The design

### Disk layout

```
SSD
/opt/homeserver/                 ← git clone: scripts, guide, archive
/opt/runtipi/                    ← Runtipi install: app settings, databases, state

Drive 1 (data)  → /opt/runtipi/media
└── data/
    ├── images/immich/           ← Immich photo library        (backed up)
    ├── documents/               ← spare folder for his files  (backed up)
    └── (movies/, tv/, music/ … created by future apps)        (NOT backed up)

Drive 2 (backup) → /mnt/backup   ← read-only except during backup runs
└── restic/
```

- Every Runtipi store app keeps its files under `runtipi/media` (Immich uses
  `${ROOT_FOLDER_HOST}/media/data/images/immich`; the future Jellyfin, Sonarr and Radarr use `media/data` / `media`).
  Mounting drive 1 at `runtipi/media` puts all big files on the HDD without per-app overrides.
  Folder names follow Runtipi's conventions on purpose.
- Mount by UUID in `/etc/fstab`. **If drive 1 is missing at boot, Runtipi must not start**,
  so apps can't write into the empty mount point on the SSD. Use a systemd dependency
  (`RequiresMountsFor=`) and/or make the empty mount point immutable. Same for the backup drive and the backup job.
- Drives are formatted ext4 with labels (`homedata`, `homebackup`). On re-run, a drive already carrying our
  label is reused, never reformatted.

### Install flow (`install.sh`)

0. **Self-update:** `git pull --ff-only` in `/opt/homeserver`, then re-exec itself, so the owner's fixes reach him on
   every re-run. Re-runs must therefore handle machines set up by older script versions.
1. **Checks:** root, Ubuntu 26.04, x86-64, RAM, internet. Warn if the IP looks DHCP-assigned with no reservation (best effort).
2. **Drives** (whiptail menus; whiptail ships with Ubuntu Server): which drive is for data, which is for backups? Show
   model, size and current contents. Never list the system disk. A drive carrying our label is recognised and reused.
   If a drive isn't ours and has partitions, require typing the word `ERASE` to format it.
   **Restore check:** if the backup drive (or the cloud copy, if he says he has one and gives its key) holds a restic
   repo from a previous install, ask "Found a backup from <date>. Restore everything?" A yes runs the restore path
   (see "Recovery") using the settings saved in the backup, and skips the questions below.
3. **Questions:**
   - Which apps? Checkboxes: Photos (Immich), Ad blocker (AdGuard Home). Both on by default.
   - Phone alerts: generate a random ntfy topic, show it as a QR code / link to subscribe in the ntfy app.
     Optional: paste a healthchecks.io ping URL (the guide explains how to get one). Skipping it shows a strong
     warning: "Without this, nobody gets told if the server dies."
   - "Also keep a copy of your backup online? (recommended)". If yes: Backblaze B2 bucket name + key ID + key
     (the guide walks through making the account). Check the credentials work before moving on.
   - "Do you want the AI helper?" (y/N).
   - Answers are saved in `/opt/homeserver/.env` (chmod 600), so a re-run offers the previous choices as defaults.
4. **System prep:** format/mount the drives, install restic, smartmontools and qrencode, enable unattended security upgrades,
   free port 53 from systemd-resolved (existing code) if AdGuard was picked.
5. **Runtipi:** install with the official installer into `/opt/runtipi`, then wire up the mount-dependency from above.
6. **Apps:** install the chosen apps through Runtipi's internal API (see below). If that fails, don't abort. Finish
   everything else and end with "Open the dashboard and click Install on: …".
7. **Backups + alerts:** install systemd timers (below), and run a first backup.
8. **AI helper**, if chosen (below).
9. **Finish screen:** the dashboard URL, what to do next in plain words (create the Runtipi account, set the router's DNS to
   this server, install the Immich phone app), and where the guide is. Show the backup password once, with "If you lose this, your backups can't be
   opened. Write it down or take a photo of it, and keep it off the server", and make him type it back before finishing.

Re-running: skips anything already done and applies changed answers. Un-picking an app does **not**
uninstall it. It just isn't installed again; removal goes through the dashboard. *(Builder's assumption.)*

### Installing apps without the dashboard

Runtipi's CLI has no `install` command, but it signs its own API calls with a JWT
(`sub: "cli"`, HS256, key = `JWT_SECRET` from Runtipi's `.env`) and calls
`http://localhost:<NGINX_PORT>/api/app-lifecycle/{urn}/…`. The backend also exposes
`POST /api/app-lifecycle/{urn}/install` (see `packages/frontend/src/api-client/sdk.gen.ts` in runtipi/runtipi).
The installer does the same: build the token, POST install with the app's required form fields
(Immich needs `DB_PASSWORD`, `JWT_SECRET` and `IMMICH_TYPESENSE_API_KEY`, all random), and wait for the job to finish.
This is undocumented, so it must fail soft (step 6). Pin the Runtipi version the installer was tested against,
and check it before calling the API.

### Backups (`backup.sh`, systemd timer, nightly 03:00)

What gets backed up is everything that makes the server *his*, not Ubuntu itself (reinstalling Ubuntu takes 15 minutes,
and a disk image would need a boot USB to restore).

- restic repo at `/mnt/backup/restic`. The password is generated at install time and stored in `/root/.restic-pass`. He
  keeps his own copy (finish screen). It's the only thing that can't be recreated.
- Run: remount `/mnt/backup` read-write → `runtipi-cli stop` (apps down for a minute or two, so databases are copied
  in a clean state; this replaces the old `pg_dumpall`) → `restic backup` → `runtipi-cli start` → `restic forget --prune`
  (keep 7 daily, 4 weekly, 6 monthly) → remount read-only. A `trap` always restarts Runtipi and remounts read-only,
  even when the backup fails.
- Includes: all of `/opt/runtipi` (app settings, secrets, databases, state) **except** the bulk of `media/`, plus
  `media/data/images/immich`, `media/data/documents` and `/opt/homeserver/.env`.
- Excludes: movies, TV, music and anything else under `media/` not listed above, plus caches (`--exclude-caches`,
  Immich thumbnails/encoded video can be regenerated, so the builder may exclude them to save space).
- Weekly `restic check` (alert: "Your backup is damaged. Replace the backup drive.").
- **Optional cloud copy:** after a successful local run, `restic copy` the new snapshots into a B2 repo
  (`b2:<bucket>:homeserver`, or B2's S3 endpoint) with the same password, then apply the same `forget --prune` there.
  B2 credentials are in `.env`. A failed cloud copy alerts but doesn't fail the local backup.
- A successful run pings healthchecks.io (its own check) if configured.

### Recovery

All recovery goes through `install.sh`, so he never needs to learn a separate procedure.

| What dies | What he does | What's lost |
|---|---|---|
| SSD | New SSD, install Ubuntu, `git clone`, `sudo ./install.sh` → picks the drives → "Found a backup from <date>. Restore everything?" → types the backup password | Changes since the last backup |
| Data drive | Swaps the drive in, `sudo ./install.sh` → spots the new empty data drive next to an existing system → offers to restore the photos/documents onto it | Photos added since the last backup (the Immich phone app re-uploads them) |
| Backup drive | Swaps the drive in, `sudo ./install.sh` → formats the new drive and starts a fresh repo; with a cloud copy, offers to seed it from there | Old local backup history only |
| Both local copies (fire/theft/surge) | New hardware, same as "SSD", restoring from the cloud copy | Changes since the last cloud copy; nothing if no cloud copy was set up |

A full restore puts `/opt/runtipi` and the media folders back from the newest snapshot, reinstalls Runtipi at the
version recorded in the backup, starts it, and checks every app responds. The builder decides whether Runtipi is
installed first and then overwritten, or restored first.

**Single photos:** Immich's own trash keeps deleted photos for 30 days, so the guide sends him there first. Only for
older deletions does he run `sudo homeserver restore` (or ask the AI helper): it asks for a date and a folder, and
restores into `media/data/restored/<date>/`, from where he uploads the photos back through Immich's web page. Expected to be
needed rarely if ever, so there's no web page for it.

### Alerts (`healthcheck.sh`, systemd timer, every 5 min)

The checks run in a script rather than a dashboard tool, so they work pre-configured with no clicking.
Results go to ntfy, **only when the state changes** (broken → alert; fixed → "all good again").

| Check | Example message |
|---|---|
| Each installed app responds (Immich `/api/server/ping`, AdGuard UI, Runtipi dashboard) | "Photos aren't working. Open the dashboard and press Restart on Immich. If that doesn't fix it, see the guide, section 'An app is broken'." |
| AdGuard resolves a normal domain and blocks a known ad domain | "The ad blocker has stopped. Internet still works but ads are back…" |
| Both drives mounted; disk usage warn 85% / critical 95% | "The photo drive is 85% full…" |
| SMART health of each drive | "The backup drive is starting to fail. Order a replacement…" |
| Last good backup < 36 h old | "Last night's backup didn't run…" |
| Last good cloud copy < 72 h old (if enabled) | "Your online backup copy hasn't updated for 3 days…" |
| Container restarting repeatedly / OOM kills | "Photos keeps crashing…" |

Each run also pings the healthchecks.io "server is alive" check, so if the box dies healthchecks.io sends the alert.

The checks follow whatever apps are actually installed (from Runtipi's installed-apps list),
so apps he adds later don't need config, and apps he never installed never alert.

### Updates

- Ubuntu security updates: unattended-upgrades, automatic.
- Apps and Runtipi: from the dashboard, when he chooses. The guide says to update in the morning, after the nightly backup.
  No auto-updating of apps (Immich updates can need care).

### Guide (`GUIDE.md`)

Plain language, short sections: what's on the box and the addresses; setting the router DNS; phone setup (Immich,
ntfy); "An app is broken"; "Get back a deleted photo"; "A drive died"; "Updating"; "Adding an app".
Written so it also serves as the AI helper's runbook (`AGENTS.md` can point at it or include it).

### Optional AI helper (Hermes Agent)

Only when he answers yes:

1. Create a dedicated user `helper` (no password login, **not** in the `docker` group, since that would equal root).
2. Install Hermes as that user with its official installer. Run its own setup wizard (`hermes setup`,
   `hermes gateway setup`) so it asks for the chat app and AI key itself. Run the gateway as a systemd service.
   Restrict chat access to his account only (Hermes's allowed-users setting).
3. **Guardrails enforced by the OS, not by prompts:**
   - One wrapper, `/usr/local/bin/homeserver`, allowed via sudoers for `helper` and nothing else. Subcommands:
     `status`, `logs <app>`, `restart <app>`, `backup-now`, `snapshots`,
     `restore <snapshot> <path>` (always restores into `/opt/runtipi/media/data/restored/<date>/`, never in place),
     `update <app>`.
   - The wrapper validates every argument (app names from the installed list, no path escapes).
   - There's no delete command. The backup drive is read-only outside backup runs and the helper can't remount it.
4. Hermes approval settings: `restore`, `update` and anything new need him to reply "yes" in chat. `status`, `logs`,
   `restart` and `backup-now` run without asking.
5. Give Hermes the guide as its instructions, plus a daily morning check ("all good" or what's wrong).
   Its self-learned memory/skills may grow, but the guardrails above don't depend on it behaving.

The wrapper is useful without the agent too (the guide can tell him to run `sudo homeserver restore …`),
so it's installed either way. *(Builder's call.)*

### Repo changes

- Move `stacks/`, the Decypharr/Real-Debrid parts of `README.md` and the old `CLAUDE.md` tasks into `archive/`
  with a note on why. Rewrite `README.md` (install) and `CLAUDE.md` (for future dev work) for the new design.
- `.gitignore`: `.env`, `.superpowers/`. Public GitHub repo.

## Testing

1. **Spike first** on an Ubuntu 26.04 VM with two extra virtual disks, to confirm the two unverified assumptions:
   (a) drive 1 mounted at `runtipi/media` works for Immich and survives a Runtipi update, and
   (b) the API install call works with the pinned Runtipi version.
   If (a) fails, fall back to per-app `user-config/<store>/<app>/docker-compose.yml` overrides pointing at the data drive.
   If (b) fails, use the "click Install in the dashboard" ending. Only if the per-app overrides fail too (i.e. Runtipi
   can't keep data on the HDD) stop and go back to the owner.
2. Full install twice (re-run must change nothing), then change answers and re-run.
3. Pull the data drive and reboot: Runtipi must not start, and an alert must say so.
4. Stop Immich and confirm a plain-language ntfy alert arrives, and a recovery message after restart.
5. Back up, delete a photo, restore it with the wrapper, and check it lands in `restored/`.
5b. Full recovery drills: wipe the SSD VM disk and restore everything; replace the data disk and restore photos;
    restore from a B2 test bucket with both local disks gone. Immich must show the same photos, albums and users afterwards.
6. With the helper on: confirm `helper` can't run `docker`, can't write to `/mnt/backup`, and can't delete under `media/`.
7. `shellcheck -S warning *.sh`.

## Left to the builder

- Exact whiptail screens and wording (keep it plain).
- Where Runtipi's app-data, DB and state live under `/opt/runtipi` for the backup include/exclude lists.
- AdGuard on Runtipi: confirm it can bind port 53 and how its first-run wizard is reached.
- Hermes details: the install command, how approvals/allowlists are configured, and the systemd unit.
- Whether `healthcheck.sh` reads Runtipi's installed apps from the API or from its state folder.

## Calls made (for the owner to check)

- Uptime Kuma (mentioned in conversation) is **dropped** in favour of `healthcheck.sh` → ntfy. Uptime Kuma can't be
  pre-configured without scripting its UI API. The Runtipi dashboard already shows which apps are running.
- The dashboard is home-network only, with no remote access.
- The `homeserver` wrapper is installed even without the AI helper.
- Un-picking an app on re-run doesn't uninstall it.
- If the drive-mount test fails, fall back to per-app overrides before asking the owner.
- healthchecks.io stays optional, but skipping it shows a strong warning ("Without this, nobody gets told if the
  server dies").
- Backups stop apps for a minute or two at 03:00 instead of dumping the database live.
- The cloud copy uses Backblaze B2 (cheapest well-supported restic target, roughly $6/TB/month) and the same password as the local repo.
- No "backup before update" step. The nightly backup is recent enough.
