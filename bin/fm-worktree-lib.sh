# shellcheck shell=bash
# Shared worktree-path resolution for fm-spawn's post-`treehouse get` discovery.
# Usage: . bin/fm-worktree-lib.sh
#
# After a crew pane runs `treehouse get`, fm-spawn must learn WHICH pooled slot
# the interactive subshell landed in, to record `worktree=` in the crew's meta.
# The only signal a session provider exposes is the pane's live foreground cwd
# (tmux's pane_current_path, herdr's foreground_cwd, the zellij/cmux pwd probe).
# Reading that cwd naively is subtly wrong, so the resolution is centralized here
# and unit-tested in tests/fm-worktree-lib.test.sh.

# real_path_or_raw: physically-resolve <path> (macOS /tmp -> /private/tmp etc.),
# falling back to the raw string if it is not a reachable directory. Comparisons
# against a canonicalized project path must use the same physical form or they
# misfire both ways (see docs/herdr-backend.md "Known gaps").
real_path_or_raw() {  # <path>
  local path=$1 real
  if real=$(cd "$path" 2>/dev/null && pwd -P); then
    printf '%s\n' "$real"
  else
    printf '%s\n' "$path"
  fi
}

# resolve_worktree_root: resolve a captured pane cwd UP to the outermost git
# worktree root. treehouse's post_create hooks (recursive `git submodule update`,
# seed scripts) can transiently leave the pane cwd INSIDE a nested submodule while
# provisioning, so the raw cwd may be a submodule dir (e.g.
# <wt>/cozystack/libs/kubeovn-chart), not the treehouse worktree root - and a
# caller would otherwise accept that submodule root as a valid isolated worktree.
# Walk up superprojects until none remains. For a repo with no submodules (or a
# non-git dir) the first --show-superproject-working-tree is empty, so this
# returns the path unchanged: a safe no-op for every backend/repo.
resolve_worktree_root() {  # <path> -> outermost superproject working tree (physical)
  local d up
  d=$(cd "$1" 2>/dev/null && pwd -P) || return 1
  while up=$(git -C "$d" rev-parse --show-superproject-working-tree 2>/dev/null) && [ -n "$up" ]; do
    up=$(cd "$up" 2>/dev/null && pwd -P) || break
    d=$up
  done
  printf '%s\n' "$d"
}

# fm_worktree_discover_settled: poll a pane's foreground cwd until it SETTLES on a
# real worktree, then echo that worktree root. Returns 1 if none settles in time.
#
#   <reader-fn>     name of a zero-arg function that echoes the pane's raw cwd
#   <proj-abs-real> the primary checkout's physical path (the cwd to reject)
#   [max-polls]     poll attempts (default 60)
#   [nap-secs]      sleep between polls (default 1; tests pass 0)
#
# Why "settle" and not "first non-project cwd": `treehouse get` transiently runs
# its foreground process from a DIFFERENT pool slot (the lowest available, which
# treehouse scans first) before the interactive subshell settles into the slot it
# actually acquired. A poll that accepts the first cwd differing from the project
# can therefore capture the wrong slot - the fm-spawn-worktree-misrecord bug,
# where the meta records slot 1 while the agent really launched in slot 4/5/7.
# resolve_worktree_root cannot catch it: that transient path IS a valid worktree
# root, just the wrong one. The settled subshell cwd is stable indefinitely while
# the startup transient is a one-shot sub-second scan, so requiring the SAME
# resolved root on two consecutive reads accepts the acquired slot and never the
# transient. Intermittent empty reads leave the running candidate intact.
fm_worktree_discover_settled() {  # <reader-fn> <proj-abs-real> [max-polls] [nap-secs]
  local reader=$1 proj_real=$2 max=${3:-60} nap=${4:-1}
  local p root prev=''
  for _ in $(seq 1 "$max"); do
    p=$("$reader" || true)
    if [ -n "$p" ]; then
      root=$(resolve_worktree_root "$p" 2>/dev/null || true)
      if [ -n "$root" ] && [ "$(real_path_or_raw "$root")" != "$proj_real" ]; then
        if [ "$root" = "$prev" ]; then
          printf '%s\n' "$root"
          return 0
        fi
        prev=$root
      fi
    fi
    sleep "$nap"
  done
  return 1
}

# fm_worktree_resync_submodules: after a pooled worktree has been reset by
# `treehouse return`, re-align its nested submodule working trees to the
# superproject's recorded gitlinks. treehouse's reset does not recurse into
# submodules, so a returned slot otherwise keeps a submodule-gitlink pointer diff
# that treehouse reports as "dirty" and never reissues - the pool bloats and a
# human has to hand-tidy it. Best-effort and non-destructive: it only checks out
# the commits the (already-reset) superproject records, touches no parent-repo
# file, and no-ops when the repo has no submodules or a needed commit is absent
# and unfetchable. Always returns 0 - a returned slot is pool-owned, so a failed
# re-sync is no worse than today's dirty slot and must never fail a teardown.
fm_worktree_resync_submodules() {  # <worktree>
  local wt=${1:-}
  [ -n "$wt" ] && [ -f "$wt/.gitmodules" ] || return 0
  git -C "$wt" submodule update --init --recursive >/dev/null 2>&1 || true
  return 0
}
