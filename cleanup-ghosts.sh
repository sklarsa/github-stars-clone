#!/usr/bin/env bash
#
# Delete Gitea org repos that have a DB record but NO git data on disk
# ("ghost" repos left behind by failed migrations). Keeps real mirrors.
#
# Usage: sudo ./cleanup-ghosts.sh
# Reads GITEA_HOST / GITEA_ORG / admin creds from the environment:
#   GITEA_ADMIN_USER, GITEA_ADMIN_PASSWORD (or set below).

set -euo pipefail

: "${GITEA_HOST:=http://localhost:3000}"
: "${GITEA_ORG:?GITEA_ORG not set}"
: "${GITEA_ADMIN_USER:?GITEA_ADMIN_USER not set}"
: "${GITEA_ADMIN_PASSWORD:?GITEA_ADMIN_PASSWORD not set}"

REPO_ROOT="${REPO_ROOT:-${HOME}/gitea-stars/repositories}"
AUTH=(-u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASSWORD}")

# Existing data dirs on disk, keyed by lowercased repo name.
declare -A ondisk
while read -r d; do
  base="$(basename "$d" .git)"
  ondisk["${base,,}"]=1
done < <(find "$REPO_ROOT/$GITEA_ORG" -mindepth 1 -maxdepth 1 -type d -name '*.git' 2>/dev/null)

page=1
total=0
deleted=0
kept=0
while : ; do
  names=$(curl -s "${AUTH[@]}" "${GITEA_HOST}/api/v1/orgs/${GITEA_ORG}/repos?limit=50&page=${page}" | jq -r '.[].name')
  [ -n "$names" ] || break
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    total=$((total + 1))
    if [ -n "${ondisk["${name,,}"]:-}" ]; then
      kept=$((kept + 1))
      continue
    fi
    code=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE \
      -H 'Content-Type: application/json' \
      "${AUTH[@]}" "${GITEA_HOST}/api/v1/repos/${GITEA_ORG}/${name}")
    if [ "$code" = "204" ]; then
      deleted=$((deleted + 1))
    else
      echo "delete failed ($code): $name"
    fi
  done <<<"$names"
  page=$((page + 1))
done

echo "scanned $total | kept $kept | deleted $deleted"
