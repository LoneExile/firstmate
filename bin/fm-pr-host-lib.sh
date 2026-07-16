#!/usr/bin/env bash
# fm-pr-host-lib.sh - host-agnostic PR operations for firstmate.
#
# firstmate's PR lifecycle (fm-pr-check.sh, fm-pr-merge.sh, fm-teardown.sh's
# landed-check) historically assumed GitHub via gh / gh-axi. This library adds
# Gitea support (e.g. a self-hosted Gitea such as private-git.ocin.cloud) so a
# project whose canonical remote is a Gitea server can be checked, merged, and
# torn down through the same firstmate machinery.
#
# Host is detected from the PR URL:
#   https://github.com/<o>/<r>/pull/<n>    -> github  (gh / gh-axi path, unchanged)
#   https://<gitea-host>/<o>/<r>/pulls/<n> -> gitea   (Gitea REST API path)
#   (Gitea web PR URLs use /pulls/ (plural); GitHub uses /pull/.)
#
# Gitea auth token resolution (first hit wins):
#   1. $FM_GITEA_TOKEN
#   2. $FM_HOME/config/gitea-token or $FM_ROOT/config/gitea-token (local, gitignored)
#   3. a userinfo token embedded in a matching-host https remote of the given worktree
#      (e.g. an https://<user>:<token>@<host>/... remote the crewmate already pushes to)
#
# Gitea calls need `curl` and `jq`. If either is missing, or no token resolves,
# the gitea path returns non-zero so callers fall back exactly as they do on a
# gh lookup error (fail-safe: never claim work is landed on an inconclusive read).
#
# Source this file; call the fm_pr_* functions. This library sets the shell
# variables PR_HOST / PR_BASE / PR_OWNER / PR_REPO / PR_NUMBER as a side effect
# of fm_pr_parse; callers that only use the fm_pr_* accessors need not read them.

# Detect the PR host from a PR URL. Echoes github|gitea|unknown.
fm_pr_host() {  # <pr-url>
  local url=${1:-} host
  host=${url#https://}
  host=${host%%/*}
  case "$host" in
    "") echo unknown ;;
    github.com) echo github ;;
    *)
      case "$url" in
        *"/pull/"*|*"/pulls/"*) echo gitea ;;
        *) echo unknown ;;
      esac
      ;;
  esac
}

# Parse a PR URL into PR_HOST/PR_BASE/PR_OWNER/PR_REPO/PR_NUMBER. Returns non-zero
# on a URL that is not a recognizable github/gitea PR URL.
fm_pr_parse() {  # <pr-url>
  local url=${1:-} rest host
  PR_HOST=$(fm_pr_host "$url")
  [ "$PR_HOST" = unknown ] && return 1
  rest=${url#https://}
  host=${rest%%/*}
  rest=${rest#*/}
  PR_BASE="https://$host"
  PR_OWNER=${rest%%/*}
  rest=${rest#*/}
  PR_REPO=${rest%%/*}
  rest=${rest#*/}
  case "$rest" in
    pulls/*) rest=${rest#pulls/} ;;
    pull/*) rest=${rest#pull/} ;;
    *) return 1 ;;
  esac
  PR_NUMBER=${rest%%/*}
  case "$PR_NUMBER" in ''|*[!0-9]*) return 1 ;; esac
  # Anchored: nothing may follow the PR number except a single trailing slash
  # (matches the old parse_pr_url regex '/pull/([0-9]+)/?$').
  case "$rest" in "$PR_NUMBER"|"$PR_NUMBER/") ;; *) return 1 ;; esac
  # Strict owner/repo validation (preserves the old GitHub-only parse's safety;
  # rejects unsafe segments like command-substitution or path traversal for both hosts).
  case "$PR_OWNER" in ''|-*|*-) return 1 ;; *[!A-Za-z0-9-]*) return 1 ;; esac
  case "$PR_REPO" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  return 0
}

# Resolve a Gitea API token. Echoes the token or returns non-zero. The worktree
# remote fallback only yields a token from a remote whose host equals <host>,
# so a PAT for one host can never be sent to another host's API.
fm_gitea_token() {  # [worktree] [host]
  local wt=${1:-} host=${2:-} f u remotes auth userinfo
  if [ -n "${FM_GITEA_TOKEN:-}" ]; then
    printf '%s' "$FM_GITEA_TOKEN"
    return 0
  fi
  for f in "${FM_HOME:-}/config/gitea-token" "${FM_ROOT:-}/config/gitea-token"; do
    case "$f" in /config/gitea-token) continue ;; esac
    if [ -f "$f" ]; then
      tr -d ' \t\r\n' < "$f"
      return 0
    fi
  done
  if [ -n "$wt" ] && [ -d "$wt" ] && [ -n "$host" ]; then
    remotes=$(cd "$wt" && git remote -v 2>/dev/null | awk '$3=="(fetch)"{print $2}')
    while IFS= read -r u; do
      case "$u" in https://*) ;; *) continue ;; esac
      auth=${u#https://}
      auth=${auth%%/*}
      case "$auth" in *@*) ;; *) continue ;; esac
      [ "${auth#*@}" = "$host" ] || continue
      userinfo=${auth%%@*}
      case "$userinfo" in
        *:*) printf '%s' "${userinfo#*:}"; return 0 ;;
      esac
    done <<<"$remotes"
  fi
  return 1
}

# Low-level Gitea REST call. Echoes the response body; non-zero on HTTP error.
_fm_gitea_curl() {  # <token> <method> <url> [json-body]
  local tok=$1 method=$2 url=$3 body=${4:-}
  command -v curl >/dev/null 2>&1 || return 1
  if [ -n "$body" ]; then
    curl -fsS -X "$method" \
      -H "Authorization: token $tok" \
      -H "Content-Type: application/json" \
      -d "$body" "$url"
  else
    curl -fsS -X "$method" -H "Authorization: token $tok" "$url"
  fi
}

# Host of a PR ref: for a URL, the URL's host; for a bare number, the worktree
# origin's host (github.com -> github; an https/ssh non-github remote -> gitea;
# anything else, incl. file:// test remotes, defaults to github, exactly as the
# legacy gh-only path did). Non-zero only if a bare number has no worktree.
_fm_pr_ref_host() {  # <ref> [worktree]
  local ref=$1 wt=${2:-} origin
  case "$ref" in http://*|https://*) fm_pr_host "$ref"; return 0 ;; esac
  [ -n "$wt" ] || return 1
  origin=$(cd "$wt" 2>/dev/null && git remote get-url origin 2>/dev/null)
  case "$origin" in
    *github.com*) printf github ;;
    https://*|git@*) printf gitea ;;
    *) printf github ;;
  esac
}

# Resolve a PR ref to a URL: a URL passes through; a bare number is expanded
# against the worktree origin (Gitea accessors need owner/repo from the URL).
_fm_pr_pr_url() {  # <ref> [worktree]
  local ref=$1 wt=${2:-}
  case "$ref" in
    http://*|https://*) printf '%s' "$ref" ;;
    *) [ -n "$wt" ] || return 1; fm_pr_url_from_worktree "$wt" "$ref" ;;
  esac
}

# cd into the worktree for gh repo context: strict for a bare-number ref (gh
# cannot resolve it without the repo), best-effort for a URL ref (the URL is
# self-sufficient, so a missing/moved worktree degrades to a URL-only lookup
# instead of failing every poll).
_fm_pr_cd_wt() {  # <ref> [worktree]
  local ref=$1 wt=${2:-}
  [ -n "$wt" ] || return 0
  case "$ref" in
    http://*|https://*) cd "$wt" 2>/dev/null || true ;;
    *) cd "$wt" ;;
  esac
}

# Echo the normalized PR state: MERGED|OPEN|CLOSED (matching gh's vocabulary).
# Returns non-zero on any lookup failure.
fm_pr_view_state() {  # <pr-url-or-number> [worktree]
  local ref=${1:?} wt=${2:-} url tok json
  case "$(_fm_pr_ref_host "$ref" "$wt")" in
    github)
      ( _fm_pr_cd_wt "$ref" "$wt" || exit 1; gh pr view "$ref" --json state -q .state 2>/dev/null )
      ;;
    gitea)
      command -v jq >/dev/null 2>&1 || return 1
      url=$(_fm_pr_pr_url "$ref" "$wt") || return 1
      fm_pr_parse "$url" || return 1
      tok=$(fm_gitea_token "$wt" "${PR_BASE#https://}") || return 1
      json=$(_fm_gitea_curl "$tok" GET "$PR_BASE/api/v1/repos/$PR_OWNER/$PR_REPO/pulls/$PR_NUMBER") || return 1
      printf '%s' "$json" | jq -r 'if .merged then "MERGED" elif .state=="open" then "OPEN" else "CLOSED" end' 2>/dev/null
      ;;
    *) return 1 ;;
  esac
}

# Echo the PR head commit SHA. Returns non-zero on any lookup failure.
fm_pr_view_head() {  # <pr-url-or-number> [worktree]
  local ref=${1:?} wt=${2:-} url tok json
  case "$(_fm_pr_ref_host "$ref" "$wt")" in
    github)
      ( _fm_pr_cd_wt "$ref" "$wt" || exit 1; gh pr view "$ref" --json headRefOid -q .headRefOid 2>/dev/null )
      ;;
    gitea)
      command -v jq >/dev/null 2>&1 || return 1
      url=$(_fm_pr_pr_url "$ref" "$wt") || return 1
      fm_pr_parse "$url" || return 1
      tok=$(fm_gitea_token "$wt" "${PR_BASE#https://}") || return 1
      json=$(_fm_gitea_curl "$tok" GET "$PR_BASE/api/v1/repos/$PR_OWNER/$PR_REPO/pulls/$PR_NUMBER") || return 1
      printf '%s' "$json" | jq -r '.head.sha // empty' 2>/dev/null
      ;;
    *) return 1 ;;
  esac
}

# Echo the open/all PR number for a branch head in a worktree, or non-zero if none.
fm_pr_number_from_branch() {  # <worktree> <branch> [pr-url-for-host-hint]
  local wt=${1:?} branch=${2:?} hint=${3:-} host tok base owner repo json
  [ -n "$branch" ] && [ "$branch" != HEAD ] || return 1
  host=github
  [ -n "$hint" ] && host=$(fm_pr_host "$hint")
  # Without a hint, infer host from the worktree's origin remote URL.
  if [ -z "$hint" ]; then
    case "$(cd "$wt" && git remote get-url origin 2>/dev/null)" in
      *github.com*) host=github ;;
      https://*|git@*) host=gitea ;;
    esac
  fi
  case "$host" in
    gitea)
      command -v jq >/dev/null 2>&1 || return 1
      local url; url=$(cd "$wt" && git remote get-url origin 2>/dev/null) || return 1
      # https://[user[:tok]@]host/owner/repo(.git)  ->  base/owner/repo
      local hp=${url#https://}; hp=${hp#*@}
      base="https://${hp%%/*}"
      local path=${hp#*/}
      owner=${path%%/*}
      repo=${path#*/}; repo=${repo%%/*}; repo=${repo%.git}
      [ -n "$owner" ] && [ -n "$repo" ] || return 1
      tok=$(fm_gitea_token "$wt" "${base#https://}") || return 1
      json=$(_fm_gitea_curl "$tok" GET "$base/api/v1/repos/$owner/$repo/pulls?state=all&limit=50") || return 1
      local n
      n=$(printf '%s' "$json" | jq -r --arg b "$branch" 'map(select(.head.ref==$b)) | .[0].number // empty' 2>/dev/null)
      [ -n "$n" ] || return 1
      printf '%s' "$n"
      ;;
    *)
      local out n
      out=$(cd "$wt" && gh-axi pr list --state all --head "$branch" --limit 1 2>/dev/null) || return 1
      n=$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*\([0-9][0-9]*\),.*/\1/p' | head -1)
      [ -n "$n" ] || return 1
      printf '%s' "$n"
      ;;
  esac
}

# Merge a PR. method is squash|merge|rebase (default squash). For github, extra
# args pass through to gh-axi; for gitea they are ignored except the method.
# Returns the exit status of the underlying merge call.
fm_pr_merge() {  # <pr-url> <method> [worktree] [-- <extra gh-axi args>]
  local url=${1:?} method=${2:-squash} wt=${3:-}
  shift 3 2>/dev/null || shift $#
  [ "${1:-}" = "--" ] && shift
  case "$(fm_pr_host "$url")" in
    github)
      fm_pr_parse "$url" || return 1
      gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "--$method" "$@"
      ;;
    gitea)
      fm_pr_parse "$url" || return 1
      local tok; tok=$(fm_gitea_token "$wt" "${PR_BASE#https://}") || return 1
      local do_val
      case "$method" in
        squash) do_val=squash ;;
        merge) do_val=merge ;;
        rebase) do_val=rebase ;;
        *) do_val=squash ;;
      esac
      _fm_gitea_curl "$tok" POST \
        "$PR_BASE/api/v1/repos/$PR_OWNER/$PR_REPO/pulls/$PR_NUMBER/merge" \
        "{\"Do\":\"$do_val\",\"delete_branch_after_merge\":true}" >/dev/null
      ;;
    *) return 1 ;;
  esac
}

# Build a canonical PR URL from a worktree's origin remote + PR number, so the
# fm_pr_* accessors (which take a URL) can be used when only a number is known
# (e.g. teardown's branch-derived PR lookup). GitHub uses /pull/, Gitea /pulls/.
fm_pr_url_from_worktree() {  # <worktree> <number>
  local wt=${1:?} n=${2:?} url host path owner repo
  url=$(cd "$wt" && git remote get-url origin 2>/dev/null) || return 1
  case "$url" in
    git@*) host=${url#git@}; host=${host%%:*}; path=${url#*:} ;;
    https://*) path=${url#https://}; path=${path#*@}; host=${path%%/*}; path=${path#*/} ;;
    *) return 1 ;;
  esac
  owner=${path%%/*}
  repo=${path#*/}; repo=${repo%%/*}; repo=${repo%.git}
  [ -n "$host" ] && [ -n "$owner" ] && [ -n "$repo" ] || return 1
  case "$host" in
    github.com) printf 'https://%s/%s/%s/pull/%s' "$host" "$owner" "$repo" "$n" ;;
    *) printf 'https://%s/%s/%s/pulls/%s' "$host" "$owner" "$repo" "$n" ;;
  esac
}
