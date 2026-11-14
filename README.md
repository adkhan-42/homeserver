# Home Server: Photos · Ad-blocking · Streaming

Three things, one box:

| What | App | Port |
|---|---|---|
| Google Photos replacement | **Immich** | 2283 |
| Ad/tracker blocking for every device on the Wi-Fi | **AdGuard Home** | 53 (DNS), 8053 (admin) |
| Netflix-style streaming, fed by Real-Debrid | **Jellyfin** + Seerr, Sonarr, Radarr, Prowlarr, Decypharr | 8096 (Jellyfin), 5055 (requests) |

## How the streaming pipeline works

```
 You: "add this movie" in Seerr (:5055)
            │
            ▼
   Radarr / Sonarr  ──search──▶  Prowlarr ──▶ indexers (via FlareSolverr)
            │ picks a release
            ▼
   Decypharr (pretends to be qBittorrent)
            │ sends magnet to Real-Debrid, only accepts it if RD already has it cached
            ▼
   Real-Debrid cloud  ◀── FUSE mount at /mnt/decypharr (nothing downloaded locally)
            │
   Decypharr drops a symlink in /data/downloads/<arr>
            ▼
   Radarr/Sonarr import it into /data/media/{movies,tv}  (still just a symlink)
            ▼
   Jellyfin (:8096) plays it, streaming from Real-Debrid on demand
```

No torrent traffic ever touches the home connection (Real-Debrid does the downloading), so no VPN container is needed. A "4 TB library" uses a few MB of disk.

## Requirements

- x86-64 machine, Ubuntu Server 24.04 or Debian 12, **8 GB RAM minimum** (Immich's ML alone wants ~6 GB). 16 GB is comfortable.
- SSD for the OS + `/srv/appdata`. A bigger disk for `/srv/data/photos`.
- **A fixed LAN IP for the server** (set a DHCP reservation in the router *before* starting — AdGuard breaks the whole house's internet if the server's IP changes).
- A Real-Debrid premium account → API token from https://real-debrid.com/apitoken
- An external drive (or cloud bucket) for backups.

## Install

```bash
sudo git clone <this repo> /opt/homeserver   # or copy the folder there
cd /opt/homeserver
sudo ./install.sh        # first run creates .env and exits
sudo nano .env           # check paths, TZ, PUID/PGID (run `id` to see yours)
sudo ./install.sh        # installs Docker if needed, creates dirs, starts everything
```

## Wire it together (do these in order)

Container names work as hostnames between apps — always use `http://sonarr:8989`, not the IP, when one app talks to another.

### 1. AdGuard Home — `http://SERVER:3000`
1. Wizard: **Admin web interface → port 8053**, **DNS server → all interfaces, port 53**. Create the admin login.
2. Filters → DNS blocklists → add a couple more (e.g. *OISD Big*, *HaGeZi Pro*). Don't go overboard; more lists = more broken sites.
3. Settings → DNS settings → Upstream: `https://dns.cloudflare.com/dns-query` and `https://dns.quad9.net/dns-query`.
4. **Router:** set the DHCP DNS server to the server's IP. **Don't add a secondary DNS** like 8.8.8.8 — devices will use it and skip the blocking.
5. Reconnect a phone to Wi-Fi, open AdGuard's Query Log, and check that requests are showing up.

### 2. Immich — `http://SERVER:2283`
1. Create the admin account.
2. Install the Immich app on the phone, server URL `http://SERVER:2283`, turn on backup.
3. Administration → Settings → Backup: confirm automatic database backups are on.

### 3. Decypharr — `http://SERVER:8282`
1. Run the setup wizard and create a login.
2. **Provider:** Real-Debrid, paste API token. **Leave "Download uncached" OFF.** You only want stuff RD already has, which plays instantly.
3. **Mount:** type **rclone**, mount path **`/mnt/decypharr`**, UID/GID = your PUID/PGID, **Allow Other: on**.
4. **qBittorrent:** download folder **`/data/downloads`**, categories **`sonarr`, `radarr`**, action **Symlink** (the default).
5. Save, then on the server: `ls /mnt/decypharr` — you should see the Real-Debrid folders. If it's empty, see Troubleshooting.

### 4. Prowlarr — `http://SERVER:9696`
1. Set a login.
2. Settings → Indexers → add a **FlareSolverr** proxy: host `http://flaresolverr:8191`, tag `flaresolverr`.
3. Indexers → add some (public ones that need Cloudflare: add the `flaresolverr` tag).
4. Settings → Apps → add **Sonarr** (`http://sonarr:8989`) and **Radarr** (`http://radarr:7878`) with their API keys (each app: Settings → General). Prowlarr server: `http://prowlarr:9696`. The indexers then sync to both apps automatically.

### 5. Sonarr (`:8989`) and Radarr (`:7878`) — same steps in each
1. Set a login.
2. Settings → Media Management → **Root folder**: Sonarr `/data/media/tv`, Radarr `/data/media/movies`. Keep **"Use Hardlinks instead of Copy" ON**. (A *copy* of a symlink reads the whole file from Real-Debrid, which you don't want.)
3. Settings → Download Clients → **+ qBittorrent**:
   - Host `decypharr`, Port `8282`
   - Category `sonarr` (or `radarr`)
   - **Username:** the Arr's own URL, e.g. `http://sonarr:8989` (Radarr: `http://radarr:7878`)
   - **Password:** that Arr's API key
   - Use SSL: No · Sequential download: No
   - Test → Save. Using the URL and API key as the login is how Decypharr learns about each Arr. You can also confirm or add them under Decypharr → Settings → Arrs (this also enables its repair of dead links).

### 6. Jellyfin — `http://SERVER:8096`
1. Wizard → create admin → add libraries:
   - Movies → `/data/media/movies`
   - Shows → `/data/media/tv`
2. **In each library's settings, turn OFF:** trickplay image extraction, chapter image extraction, and any intro/segment detection. Also Dashboard → Scheduled Tasks → disable *Extract Chapter Images*, *Generate Trickplay Images*, *Media Segment Scan*. These read every file end to end, which hammers Real-Debrid and can get the account flagged.
3. Optional: if the box has an Intel iGPU, uncomment `/dev/dri` in `stacks/media/compose.yml`, re-run `sudo ./update.sh`, then enable Intel QSV under Dashboard → Playback.

### 7. Seerr — `http://SERVER:5055`
1. Sign in with Jellyfin: URL `http://jellyfin:8096`, Jellyfin admin login.
2. Add Radarr (`radarr`, 7878, API key, root `/data/media/movies`) and Sonarr (`sonarr`, 8989, root `/data/media/tv`). Tick "Default server".
3. Request something. It should appear in Jellyfin within a minute or two.

### 8. Remote access (Tailscale)
No ports get opened on the router. Install Tailscale on the server and on his phone/laptop:
```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```
Then use `http://<tailscale-name>:8096` etc. from anywhere. Bonus: in the Tailscale admin console → DNS, set the server's Tailscale IP as the nameserver, and you get ad-blocking on mobile data too.

### 9. Backups
```bash
sudo sh -c 'head -c 32 /dev/urandom | base64 > /root/.restic-pass && chmod 600 /root/.restic-pass'
sudo cat /root/.restic-pass     # SAVE THIS in a password manager. Without it the backup is useless.
sudo ./backup.sh                # first run initialises the repo
sudo crontab -e                 # add:
0 3 * * * /opt/homeserver/backup.sh >> /var/log/homeserver-backup.log 2>&1
```
Backed up: photos, Immich DB dump, every app's config. Not backed up: streaming media (it lives on Real-Debrid).

Test a restore once: `restic -r <repo> --password-file /root/.restic-pass snapshots`, then `restic restore latest --target /tmp/restore-test --include /srv/appdata/sonarr`.

## Day to day

| Task | Command |
|---|---|
| Update AdGuard + media apps | `sudo ./update.sh` |
| Update Immich (read release notes first) | `sudo ./update.sh --immich` |
| See what's running | `docker ps` |
| Logs for one app | `docker logs -f sonarr` |
| Restart the pipeline | `docker compose --env-file .env -f stacks/media/compose.yml restart` |

## Troubleshooting

**`/mnt/decypharr` is empty on the host or in Sonarr.**
That's mount propagation. Run `findmnt -o TARGET,PROPAGATION --target /mnt/decypharr`. It must say `shared`. If not, add `/mnt/decypharr /mnt/decypharr none bind,rshared 0 0` to `/etc/fstab`, reboot, then `docker restart decypharr sonarr radarr jellyfin`.

**Files show in Jellyfin but won't play.**
The symlinks point at `/mnt/decypharr/...`. Jellyfin needs that exact path mounted (it is in the compose file). Check with `docker exec jellyfin ls /mnt/decypharr`.

**Lots of "infringing file" errors or failed grabs.**
Real-Debrid has been filtering filenames and removing cached content in 2026. That's on RD's side and isn't a config bug. Grabs succeed less often than they used to. Adding more indexers helps a little.

**AdGuard won't start: "address already in use :53".**
Something still holds port 53: `sudo ss -lunp | grep :53`. Re-run `install.sh`, which disables the systemd-resolved stub.

**Internet down for the whole house.**
The server is off or changed IP. In the router, temporarily set DNS back to automatic. Then fix the server's IP reservation.

## Real-Debrid notes
- **One IP at a time.** Real-Debrid bans accounts used from several IPs at once. Everything here streams through the server, so remote Jellyfin viewers don't count. Just don't also use the same RD account in Stremio on his phone over mobile data.
- Keep "download uncached" off. Uncached items can sit for hours, and the Arrs will time out and retry.
