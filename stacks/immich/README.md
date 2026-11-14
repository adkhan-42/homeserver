# Immich

This folder is populated by `install.sh`, which downloads Immich's official
`docker-compose.yml` and `example.env` from the **latest release** and fills in
the paths and a generated database password.

Immich's own docs insist on using the release compose file rather than a
hand-written one: its Postgres image (with the VectorChord extension) is pinned
there and changes between versions. Don't edit the database image tag by hand.

Upgrading: read the release notes first (Immich occasionally ships breaking
changes), then run `sudo ./update.sh --immich`.
