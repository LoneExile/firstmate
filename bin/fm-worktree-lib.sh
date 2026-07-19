# shellcheck shell=bash
# Shared worktree helpers, sourced by fm-teardown.sh (and this lib's tests).
# Usage: . bin/fm-worktree-lib.sh
#
# Holds fm_worktree_resync_submodules: after `treehouse return` resets a pooled
# slot, treehouse does not recurse into submodules, so the slot keeps a
# submodule-gitlink drift that reads "dirty" and is never reissued. This helper
# re-aligns the returned slot's nested submodules so the pool stays reusable.
# Unit-tested in tests/fm-worktree-lib.test.sh.

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
