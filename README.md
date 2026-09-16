# gitea-stars

Gitea (1.27.3) + PostgreSQL (16) stack for syncing GitHub stars locally.

```
docker-compose.yml   the stack
.env                 DB password (generated, set on first run)
gitea/               Gitea config, LFS, ssh keys  (bind mount -> /data)
repositories/        ★ git repo storage            (bind mount -> /data/git/repositories)
postgres/            Postgres data files
```

## Bring up

```sh
cd ~/gitea-stars
docker compose up -d
```

Finish the install wizard at http://localhost:3000 (Database type: **PostgreSQL**, host `db` — or just let the env vars do it). SSH clones use host port **222** (`git@localhost:222/owner/repo.git`).

> Requires the `docker compose` plugin (`docker-compose-plugin`). The two images chown their data dirs on first boot (Gitea→uid 1000, Postgres→its own uid), so no manual `chown` needed.

## Day-2 commands

```sh
docker compose ps            # status
docker compose logs -f       # tail logs
docker compose down          # stop (data kept)
docker compose pull && docker compose up -d   # upgrade (bump pins first)
```

## Backup

```sh
docker compose exec db pg_dump -U gitea gitea > gitea-db.sql   # DB
tar czf repos.tgz repositories/                                # git repos
```

## Star-sync service (systemd)

The systemd timer `gitea-star-sync` turns a GitHub user's starred repos into
Gitea **pull-mirrors** (named `owner-repo`) in a Gitea org, daily. Gitea's own
mirror scheduler keeps them updated; the script only creates new ones.

**Prereqs on the sync host:** `jq`, `curl` (Arch: `sudo pacman -S jq curl` / `yay -S jq curl`; Debian/Ubuntu: `sudo apt install jq curl`)

**Install:**

```sh
sudo ./install-systemd.sh
sudo nano /etc/gitea-stars/sync-stars.env   # GIT_USER / GITEA_HOST / GITEA_ORG / GITEA_TOKEN
sudo systemctl start gitea-star-sync.service   # run once
journalctl -u gitea-star-sync -f               # watch
```

- Create the Gitea token under **Settings ▸ Applications ▸ Generate New Token**
  (needs repo rights on `GITEA_ORG`). Rotate it if it was ever shared.
- `GITEA_HOST` has no trailing slash, e.g. `http://192.168.4.201:3001`.
- Run it periodically with `systemctl start gitea-star-sync.service`, or let
  the daily timer (04:15, `Persistent=true`) handle it.

`sync-stars.sh` is also runnable standalone:

```sh
env $(cat /etc/gitea-stars/sync-stars.env) ./sync-stars.sh
```
