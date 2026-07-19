#!/usr/bin/env bash
# Behavior tests for bin/fm-worktree-lib.sh's fm_worktree_resync_submodules:
# after `treehouse return` resets a pooled slot, its nested submodule working
# trees must be re-aligned to the superproject's gitlinks so the slot reads
# clean and treehouse reissues it (else the pool bloats with "dirty" slots).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-worktree-lib.sh
. "$ROOT/bin/fm-worktree-lib.sh"

TMP=$(fm_test_tmproot fm-worktree-lib)
# fm_test_tmproot runs in a $() subshell, whose EXIT trap removes the dir it just
# made, so re-create $TMP before the fixtures mktemp under it.
mkdir -p "$TMP"

# --- fm_worktree_resync_submodules -------------------------------------------
# Build a superproject with one submodule pinned at commit C1, then drift the
# submodule working tree to C2 (what a returned-but-not-resynced pooled slot
# looks like). fm_worktree_resync_submodules must re-align it to C1 so the slot
# reads clean again. Local-path submodules need protocol.file.allow; real
# firstmate submodules are https/ssh where it does not apply.
build_submodule_super() {  # echoes the superproject worktree path
  local base sub super c1 c2
  base=$(mktemp -d "$TMP/submod.XXXXXX")
  sub="$base/sub"; super="$base/super"
  git init -q "$sub"
  ( cd "$sub" && echo a >f && git add f && git commit -qm c1 )
  c1=$(git -C "$sub" rev-parse HEAD)
  ( cd "$sub" && echo b >f && git commit -qam c2 )
  c2=$(git -C "$sub" rev-parse HEAD)
  git -C "$sub" checkout -q "$c1"
  git init -q "$super"
  git -C "$super" config protocol.file.allow always
  ( cd "$super" && git -c protocol.file.allow=always submodule add -q "$sub" mod && git commit -qm "add sub" )
  git -C "$super/mod" checkout -q "$c2"   # drift the submodule working tree
  printf '%s' "$super"
}

# A returned slot with drifted submodule pointers is re-aligned to clean.
test_resync_realigns_drifted_submodule() {
  local super
  super=$(build_submodule_super)
  [ -n "$(git -C "$super" status --porcelain)" ] || fail "fixture: submodule not drifted/dirty"
  fm_worktree_resync_submodules "$super"
  [ -z "$(git -C "$super" status --porcelain)" ] || fail "resync left the slot dirty: $(git -C "$super" status --porcelain)"
  pass "resync re-aligns a drifted submodule so the slot reads clean"
}

# A worktree without submodules is a safe no-op (returns 0, changes nothing).
test_resync_no_submodules_is_noop() {
  local plain
  plain=$(mktemp -d "$TMP/plain.XXXXXX")
  git init -q "$plain"
  ( cd "$plain" && echo x >f && git add f && git commit -qm only )
  fm_worktree_resync_submodules "$plain" || fail "resync must return 0 with no submodules"
  [ -z "$(git -C "$plain" status --porcelain)" ] || fail "resync mutated a submodule-free worktree"
  pass "resync is a no-op on a worktree with no submodules"
}

test_resync_realigns_drifted_submodule
test_resync_no_submodules_is_noop
