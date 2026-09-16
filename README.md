# gitea-stars

Mirror a GitHub user's starred repositories into a self-hosted
**Gitea + PostgreSQL** stack (Docker), keeping a full-history archive of
everything you've starred. New stars are picked up automatically by a
systemd timer; existing mirrors stay in sync via Gitea's own mirror
scheduler.

```
├── docker-compose.yml       Gitea 1.27.3 + Postgres 16 stack
├── .env.example             template for .env (DB password)
├── sync-stars.sh            GitHub stars → Gitea pull-mirror sync
├── install-systemd.sh       installs service + timer + safe env file
├── cleanup-ghosts.sh        removes failed-migrate repo rows (no data)
├── gitea/                   Gitea config/LFS/ssh keys  -> /data
├── repositories/            ★ bare git repos (local bind mount)
└── postgres/                Postgres data files
```

Repos are stored as **host-visible bare git repos** in `repositories/`,
mounted at Gitea's `/data/git/repositories` — easy to inspect or back up.
Mirrors are full-history clones (every branch/tag/commit), named
`<github-owner>-<repo>` to avoid collisions.

## Requirements

- Docker Engine + the `docker compose` plugin
- `jq` and `curl` on the sync host (Arch: `sudo pacman -S jq curl`;
  Debian/Ubuntu: `sudo apt install jq curl`)

## Bring up

```sh
cp .env.example .env                 # set a strong POSTGRES_PASSWORD first
docker compose up -d
```

Open **http://localhost:3000** and finish the install wizard (Database:
**PostgreSQL** — the compose env already wires host `db` and credentials).
SSH clones use host port **222** (`git@localhost:222/owner/repo.git`).

The images auto-`chown` their data dirs on first boot, so no manual `chown`.

## Star-sync service (systemd)

Turns a user's public stars into Gitea pull-mirrors. Idempotent: existing
mirrors are skipped, so it's safe to run on a schedule — Gitea's mirror
scheduler (default 8h) handles ongoing sync; this only finds *new* stars.

```sh
sudo ./install-systemd.sh                                # creates units + env
sudo nano /etc/gitea-stars/sync-stars.env                # fill it in
sudo systemctl start gitea-star-sync.service             # run once
journalctl -u gitea-star-sync -f                         # watch
```

### Config (`/etc/gitea-stars/sync-stars.env`, root-only)

| Var | Purpose |
|---|---|
| `GIT_USER` | GitHub user whose public stars to mirror |
| `GITEA_HOST` | base URL of the Gitea instance, no trailing slash |
| `GITEA_ORG` | Gitea org to create mirrors in (must exist) |
| `GITEA_TOKEN` | Gitea API token (Settings ▸ Applications) |
| `GITHUB_TOKEN` | GitHub token — **recommended**: clones via `auth_token` are immune to GitHub's anonymous-clone rate limits |

The daily timer (`gitea-star-sync.timer`, 04:15, `Persistent=true`) runs it
automatically. A `Type=oneshot` service shows `inactive` between runs —
that's normal; only the timer is always-on.

`sync-stars.sh` also works standalone:

```sh
env $(cat /etc/gitea-stars/sync-stars.env) ./sync-stars.sh
```

### First run

The initial run is a **full-history pull of every star** — expect hours and
tens–hundreds of GB for a large star list. GitHub's `size` metric
under-reports repos with LFS/large history (a repo reported at ~100 MB can
clone to multiple GB). Monitor with `journalctl` and `du -sh repositories/`.

## Troubleshooting: "failed" migrates that leave ghost repos

Some migrate failures return `422` yet still create a Gitea repo **row with
no git data on disk**. The sync's skip-if-exists check then treats them as
done, so they're never retried. Fix:

```sh
GITEA_ORG=public-mirrors GITEA_ADMIN_USER=<admin> GITEA_ADMIN_PASSWORD=<pw> \
  ./cleanup-ghosts.sh        # deletes repo rows that have no data on disk
sudo systemctl start gitea-star-sync.service    # re-run sync
```

(GitHub anonymous-clone rate limits were the trigger for mass failures;
having `GITHUB_TOKEN` set avoids that class entirely.)

## Operations

```sh
docker compose ps            # status
docker compose logs -f       # tail logs
docker compose down          # stop (data kept)
docker compose pull && docker compose up -d     # upgrade (bump pins first)
```

## Backup

```sh
docker compose exec db pg_dump -U gitea gitea > gitea-db.sql   # DB
tar czf repos.tgz repositories/                                # git repos
```

## Security

No secrets are committed. `.env` and the data dirs are gitignored; the sync
config (Gitea + GitHub tokens) lives in `/etc/gitea-stars/sync-stars.env`
(`root:root` mode `600`).
