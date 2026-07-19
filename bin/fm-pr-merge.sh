#!/usr/bin/env bash
# Merge a task's PR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# The full canonical PR URL is validated by bin/fm-pr-lib.sh and the derived
# owner/repository and PR number drive the merge.
#
# Host-agnostic: a GitHub PR URL merges via gh-axi exactly as before; a Gitea PR
# URL (https://<host>/<o>/<r>/pulls/<n>) merges via the Gitea REST API through
# bin/fm-pr-host-lib.sh. The repository is parsed from the PR URL either way.
#
# Merge method defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. Extra args
# must not include --repo or -R because the repository comes only from the URL.
# For GitHub, extra args pass through to gh-axi; for Gitea only the merge method
# is honored.
# Usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra gh-axi pr merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-pr-host-lib.sh
. "$SCRIPT_DIR/fm-pr-host-lib.sh"

if [ "$#" -lt 2 ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL"; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
URL=$FM_PR_URL
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
shift 2
[ "${1:-}" = "--" ] && shift

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

# Echo the caller-requested merge method (squash|merge|rebase), default squash.
requested_method() {
  local arg want=squash
  for arg in "$@"; do
    case "$arg" in
      --squash) want=squash ;;
      --merge) want=merge ;;
      --rebase) want=rebase ;;
      --method=*) want=${arg#--method=} ;;
    esac
  done
  printf '%s' "$want"
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*|-R|-R?*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
    esac
  done
}

reject_repo_overrides "$@" || exit 1

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || {
  echo "error: PR metadata recording failed" >&2
  exit 1
}

if [ "$(fm_pr_host "$URL")" = github ]; then
  merge_args=()
  if ! caller_has_merge_method "$@"; then
    merge_args=(--squash)
  fi
  gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"
else
  WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
  fm_pr_merge "$URL" "$(requested_method "$@")" "$WT"
fi

