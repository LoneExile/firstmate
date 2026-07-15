#!/usr/bin/env bash
# Merge a task's PR, always recording pr= and any available pr_head= into
# state/<id>.meta first via bin/fm-pr-check.sh, so bin/fm-teardown.sh's
# landed-check has a PR reference to verify a squash merge against.
#
# Why this exists: the normal trigger for running fm-pr-check.sh is the crew's
# `done: PR <url> checks green` line, which no-mistakes only emits once its CI
# step turns green. Repos that intentionally run no CI on PRs (CI only on
# pushes to the default branch) never emit that line, so a merge performed by
# hand can skip the recording step entirely. Teardown then has nothing to look
# up for a squash-merge-then-delete-branch flow and false-refuses provably
# landed work. This script makes recording part of the merge itself, so it
# cannot be skipped by omission. Use it for every PR merge (captain-requested
# or yolo-authorized), in place of calling the underlying merge command directly.
#
# Host-agnostic (bin/fm-pr-host-lib.sh): a GitHub PR URL merges via gh-axi
# exactly as before; a Gitea PR URL (https://<host>/<o>/<r>/pulls/<n>) merges via
# the Gitea REST API. The repo is parsed from the PR URL either way.
#
# Merge method: defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method. An explicit caller method is never overridden.
# For GitHub, extra args pass through to gh-axi (but must not include --repo/-R,
# which is parsed from the URL). For Gitea, only the merge method is honored.
#
# Usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra gh-axi pr merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ID=${1:?usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra gh-axi pr merge args>]}
URL=${2:?usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra gh-axi pr merge args>]}
shift 2
[ "${1:-}" = "--" ] && shift

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-pr-host-lib.sh
. "$SCRIPT_DIR/fm-pr-host-lib.sh"
META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META; refusing to merge without recording pr=" >&2; exit 1; }

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
        echo "error: extra merge args must not override --repo parsed from PR URL (got: $arg)" >&2
        return 1
        ;;
    esac
  done
  return 0
}

fm_pr_parse "$URL" || {
  echo "error: PR URL must be a GitHub (https://github.com/<owner>/<repo>/pull/<n>) or Gitea (https://<host>/<owner>/<repo>/pulls/<n>) PR URL (got: $URL)" >&2
  exit 1
}

# Reject a caller --repo override before recording pr= (the repo is authoritative
# from the PR URL). GitHub-only: the gitea path ignores extra args entirely.
[ "$PR_HOST" != github ] || reject_repo_overrides "$@" || exit 1

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || { echo "error: fm-pr-check did not record pr=$URL in $META; refusing to merge" >&2; exit 1; }

WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)

if [ "$PR_HOST" = github ]; then
  merge_args=()
  if ! caller_has_merge_method "$@"; then
    merge_args=(--squash)
  fi
  gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" ${merge_args[@]+"${merge_args[@]}"} "$@"
else
  method=$(requested_method "$@")
  fm_pr_merge "$URL" "$method" "$WT"
fi
