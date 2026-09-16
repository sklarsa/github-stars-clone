#!/usr/bin/env bash
#
# Sync a GitHub user's starred repos into a Gitea org as pull-mirrors.
# Idempotent: existing mirrors are skipped. Created mirrors are `mirror: true`,
# so Gitea's own mirror scheduler keeps them updated afterward; this script
# only needs to run periodically (e.g. daily) to pick up newly-starred repos.
#
# Config comes from the environment (see install-systemd.sh -> /etc/gitea-stars/sync-stars.env):
#   GIT_USER    GitHub user whose stars to mirror
#   GITEA_HOST  base URL of the Gitea instance, e.g. http://192.168.4.201:3001
#   GITEA_ORG   target org/user on Gitea to create mirrors in
#   GITEA_TOKEN Gitea API token with rights to create repos in that org
#
# Optional:
#   GITHUB_TOKEN  GitHub token for a higher API rate limit (unauthenticated
#                 GitHub API is capped at 60 req/hr; per_page=100 keeps us well
#                 under that for <6000 stars, so usually not needed).
#
# Mirrors are named "<github-owner>-<repo-name>" so repos with the same name
# from different owners don't collide in the org.

set -euo pipefail

: "${GIT_USER:?GIT_USER not set}"
: "${GITEA_HOST:?GITEA_HOST not set}"
: "${GITEA_ORG:?GITEA_ORG not set}"
: "${GITEA_TOKEN:?GITEA_TOKEN not set}"

GH_API="https://api.github.com/users/${GIT_USER}/starred"
GH_AUTH=()
if [ -n "${GITHUB_TOKEN:-}" ]; then
  GH_AUTH=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
fi

log()  { echo "[sync-stars] $(date -Is) $*"; }
die()  { echo "[sync-stars] $(date -Is) ERROR: $*" >&2; exit 1; }

# Fetch one page of starred repos; die with GitHub's message on error (e.g. rate limit).
gh_page() {
  local page="$1" body
  body="$(curl -fsS -H 'Accept: application/vnd.github+json' "${GH_AUTH[@]}" \
           "${GH_API}?per_page=100&page=${page}")" \
    || die "GitHub API page ${page} failed (HTTP $?)"
  local msg
  msg="$(jq -r 'if type == "object" then (.message // empty) else empty end' <<<"$body")"
  [ -z "$msg" ] || die "GitHub API page ${page}: ${msg}"
  printf '%s' "$body"
}

# Gitea repo search (exact-owner/name match happens in mirror_exists).
gitea_search() {
  curl -fsS --get "${GITEA_HOST}/api/v1/repos/search" \
    --data-urlencode "q=$1" \
    --data-urlencode "limit=50" \
    -H "Authorization: token ${GITEA_TOKEN}" \
    || { log "Gitea search failed for $1; continuing"; return 1; }
}

mirror_exists() {
  local mirror_name="$1" found
  found="$(gitea_search "$mirror_name" 2>/dev/null \
            | jq -r --arg org "$GITEA_ORG" --arg n "$mirror_name" \
                '.data[] | select(.owner.login == $org and .name == $n) | .name' \
            | head -n1)" || true
  [ -n "$found" ]
}

create_mirror() {
  local owner="$1" name="$2" clone_url="$3"
  local mirror_name="${owner}-${name}"
  # Authenticated clone when a GitHub token exists: immune to GitHub's anonymous
  # clone rate limits, and required if we later mirror private repos. Gitea stores
  # the credential only on the mirror that needs it; public repos mirror as before.
  local data out code body
  data="$(jq -nc \
    --arg addr "$clone_url" \
    --arg rowner "$GITEA_ORG" \
    --arg rname "$mirror_name" \
    --arg ghtoken "${GITHUB_TOKEN:-}" \
    '{clone_addr: $addr, repo_owner: $rowner, repo_name: $rname, service: "github", mirror: true}
     + (if $ghtoken != "" then {auth_token: $ghtoken} else {} end)')"
  log "creating mirror ${mirror_name} from ${clone_url}"
  out="$(curl -s -w '\n%{http_code}' -X POST "${GITEA_HOST}/api/v1/repos/migrate" \
    -H "Authorization: token ${GITEA_TOKEN}" \
    -H "Content-Type: application/json" \
    --data "$data")"
  code="${out##*$'\n'}"
  body="${out%$'\n'*}"
  if [ "$code" = "201" ] || [ "$code" = "200" ]; then
    log "created ${mirror_name}"
  else
    log "migrate FAILED for ${mirror_name} (HTTP $code): $(printf '%s' "$body" | head -c 200)"
    return 1
  fi
}

log "syncing stars of ${GIT_USER} into ${GITEA_HOST} org ${GITEA_ORG}"
page=1
created=0
skipped=0
while : ; do
  rows="$(gh_page "$page" | jq -r '.[] | [.owner.login, .name, .clone_url] | @tsv')"
  [ -n "$rows" ] || break

  while IFS=$'\t' read -r owner name clone_url; do
    mirror_name="${owner}-${name}"
    if mirror_exists "$mirror_name"; then
      log "skip ${mirror_name} (already present)"
      skipped=$((skipped + 1))
    else
      if create_mirror "$owner" "$name" "$clone_url"; then
        created=$((created + 1))
      else
        log "will retry ${mirror_name} on a future run"
      fi
    fi
  done <<<"$rows"

  page=$((page + 1))
done

log "done: ${created} created, ${skipped} skipped"
