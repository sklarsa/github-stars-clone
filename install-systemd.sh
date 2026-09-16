#!/usr/bin/env bash
#
# Install the gitea-star-sync systemd service + daily timer.
#
#   sudo ./install-systemd.sh
#
# Creates:
#   /etc/gitea-stars/sync-stars.env     (root:root 600, placeholders on first run)
#   /etc/systemd/system/gitea-star-sync.service
#   /etc/systemd/system/gitea-star-sync.timer
# then enables + starts the timer.
#
# After installing, edit /etc/gitea-stars/sync-stars.env with real values and
# run once:  sudo systemctl start gitea-star-sync.service
# Logs:      journalctl -u gitea-star-sync -f

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "run as root: sudo $0" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC_SCRIPT="${SCRIPT_DIR}/sync-stars.sh"
ENV_DIR=/etc/gitea-stars
ENV_FILE="${ENV_DIR}/sync-stars.env"

[ -f "$SYNC_SCRIPT" ] || { echo "missing sync script at ${SYNC_SCRIPT}" >&2; exit 1; }

mkdir -p "$ENV_DIR"
chmod 700 "$ENV_DIR"
chmod +x "$SYNC_SCRIPT"

if [ ! -f "$ENV_FILE" ]; then
  cat > "$ENV_FILE" <<'EOF'
# Gitea star-sync config. Owned root:root, mode 600.
# GITEA_TOKEN: create in Gitea -> Settings -> Applications -> Generate New Token
#   (needs repo read/create rights on GITEA_ORG).

# GitHub user whose stars to mirror
GIT_USER=
# Base URL of your Gitea instance, no trailing slash
GITEA_HOST=
# Target org (or user) on Gitea to create mirrors in
GITEA_ORG=
# Gitea API token
GITEA_TOKEN=
# Optional: GitHub token if you exceed unauthenticated rate limits
# GITHUB_TOKEN=
EOF
  chmod 600 "$ENV_FILE"
  echo "created ${ENV_FILE} — edit it to set GIT_USER / GITEA_HOST / GITEA_ORG / GITEA_TOKEN"
else
  echo "${ENV_FILE} already exists, leaving it untouched"
fi

cat > /etc/systemd/system/gitea-star-sync.service <<EOF
[Unit]
Description=Sync GitHub stars into Gitea as pull-mirrors
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
EnvironmentFile=${ENV_FILE}
ExecStart=${SYNC_SCRIPT}
PrivateTmp=true
NoNewPrivileges=true
EOF

cat > /etc/systemd/system/gitea-star-sync.timer <<'EOF'
[Unit]
Description=Daily GitHub star -> Gitea mirror sync

[Timer]
OnCalendar=*-*-* 04:15:00
Persistent=true
RandomizedDelaySec=600

[Install]
WantedBy=timers.target
EOF

chmod 644 /etc/systemd/system/gitea-star-sync.service /etc/systemd/system/gitea-star-sync.timer

systemctl daemon-reload
systemctl enable --now gitea-star-sync.timer

echo "installed. Next steps:"
echo "  sudo nano ${ENV_FILE}"
echo "  sudo systemctl start gitea-star-sync.service   # first run"
echo "  journalctl -u gitea-star-sync -f               # watch it"
echo "  systemctl status gitea-star-sync.timer         # schedule"
