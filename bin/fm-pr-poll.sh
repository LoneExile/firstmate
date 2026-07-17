#!/usr/bin/env bash
# Static watcher program for a validated PR poll sidecar.
# It emits exactly one merged line for MERGED and stays silent otherwise.
#
# Host-agnostic and fully static: the sidecar holds only data (url, owner, repo,
# number) and this program is copied byte-for-byte as state/<id>.check.sh. No PR
# or task data is ever interpolated into generated shell source. A GitHub PR is
# read with gh; a Gitea PR (https://<host>/<owner>/<repo>/pulls/<n>) is read from
# the Gitea REST API using curl+jq and a token resolved the same way
# bin/fm-pr-host-lib.sh does, confined to a detached poll's available sources.
set -u
LC_ALL=C
export LC_ALL

if [ "$#" -eq 5 ] && [ "$1" = --validated ]; then
  url=$2
  owner=$3
  repo=$4
  number=$5
elif [ "$#" -eq 0 ]; then
  case "$0" in
    *.check.sh) data=${0%.check.sh}.pr-poll ;;
    *) exit 0 ;;
  esac

  [ -f "$data" ] && [ ! -L "$data" ] || exit 0
  { exec 3< "$data"; } 2>/dev/null || exit 0
  IFS= read -r url <&3 || exit 0
  IFS= read -r owner <&3 || exit 0
  IFS= read -r repo <&3 || exit 0
  IFS= read -r number <&3 || exit 0
  if IFS= read -r _extra <&3; then
    exit 0
  fi
  exec 3<&-
else
  exit 0
fi

[ "${#owner}" -ge 1 ] && [ "${#owner}" -le 39 ] || exit 0
case "$owner" in
  *[!A-Za-z0-9-]*|-*|*-|*--*) exit 0 ;;
esac
[ "${#repo}" -ge 1 ] && [ "${#repo}" -le 100 ] || exit 0
case "$repo" in
  .|..|*[!A-Za-z0-9._-]*) exit 0 ;;
esac
case "$number" in
  [1-9]*) ;;
  *) exit 0 ;;
esac
case "$number" in
  *[!0-9]*) exit 0 ;;
esac

# GitHub: unchanged gh lookup.
if [ "$url" = "https://github.com/$owner/$repo/pull/$number" ]; then
  state=$(gh pr view "$url" --json state -q .state 2>/dev/null) || exit 0
  [ "$state" = MERGED ] && printf '%s\n' merged
  exit 0
fi

# Gitea: https://<host>/<owner>/<repo>/pulls/<number>.
host=${url#https://}
host=${host%%/*}
case "$host" in
  ''|github.com) exit 0 ;;
  *[!A-Za-z0-9.:-]*) exit 0 ;;
esac
[ "$url" = "https://$host/$owner/$repo/pulls/$number" ] || exit 0
command -v curl >/dev/null 2>&1 || exit 0
command -v jq >/dev/null 2>&1 || exit 0

# Resolve a Gitea API token as bin/fm-pr-host-lib.sh does, from the sources a
# detached poll can reach: env, FM_HOME/config, FM_ROOT/config, then the recorded
# worktree's userinfo remote (worktree read from the sibling task meta).
tok=${FM_GITEA_TOKEN:-}
if [ -z "$tok" ]; then
  home=${FM_HOME:-}
  if [ -z "$home" ]; then
    case "$0" in
      */state/*.check.sh) home=${0%/state/*} ;;
    esac
  fi
  for cf in "$home/config/gitea-token" "${FM_ROOT:-}/config/gitea-token"; do
    case "$cf" in /config/gitea-token) continue ;; esac
    if [ -f "$cf" ] && [ ! -L "$cf" ]; then
      tok=$(tr -d ' \t\r\n' < "$cf")
      break
    fi
  done
fi
if [ -z "$tok" ]; then
  case "$0" in
    *.check.sh)
      meta=${0%.check.sh}.meta
      if [ -f "$meta" ] && [ ! -L "$meta" ]; then
        wt=$(grep '^worktree=' "$meta" | tail -1 | cut -d= -f2- || true)
        if [ -n "$wt" ] && [ -d "$wt" ]; then
          u=$(cd "$wt" && git remote -v 2>/dev/null | awk '$3=="(fetch)"{print $2}' | grep -m1 '^https://[^/]*@' || true)
          if [ -n "$u" ]; then
            userinfo=${u#https://}
            userinfo=${userinfo%%@*}
            case "$userinfo" in
              *:*) tok=${userinfo#*:} ;;
            esac
          fi
        fi
      fi
      ;;
  esac
fi
[ -n "$tok" ] || exit 0

resp=$(curl -fsS -H "Authorization: token $tok" \
  "https://$host/api/v1/repos/$owner/$repo/pulls/$number" 2>/dev/null) || exit 0
merged=$(printf '%s' "$resp" | jq -r 'if .merged then "yes" else "no" end' 2>/dev/null) || exit 0
[ "$merged" = yes ] && printf '%s\n' merged
exit 0
