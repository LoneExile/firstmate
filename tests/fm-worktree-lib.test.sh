#!/usr/bin/env bash
# Behavior tests for bin/fm-worktree-lib.sh's post-`treehouse get` worktree
# discovery. The load-bearing contract is fm_worktree_discover_settled: it must
# record the slot the crew's subshell SETTLES in, never the lowest pool slot
# treehouse's foreground process transiently visits while acquiring - the
# fm-spawn-worktree-misrecord bug (records slot 1 while the agent is in slot 4/5/7).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-worktree-lib.sh
. "$ROOT/bin/fm-worktree-lib.sh"

TMP=$(fm_test_tmproot fm-worktree-lib)
# Three distinct, real directories standing in for the primary checkout and two
# pool slots. resolve_worktree_root is a no-op on non-git dirs, so it echoes each
# back as its physical path - exactly what the discovery loop compares.
mkdir -p "$TMP/proj" "$TMP/slot1" "$TMP/slot2"
PROJ_REAL=$(cd "$TMP/proj" && pwd -P)
SLOT1=$(cd "$TMP/slot1" && pwd -P)
SLOT2=$(cd "$TMP/slot2" && pwd -P)
CFILE="$TMP/reader.count"

# _bump: monotonic call counter that survives the command-substitution subshell
# each reader runs in (a plain shell var would reset every call).
_bump() {
  local c
  c=$(cat "$CFILE" 2>/dev/null || echo 0)
  c=$((c + 1))
  printf '%s' "$c" >"$CFILE"
  printf '%s' "$c"
}

# The wrong slot appears once (treehouse's startup pool scan), then the subshell
# settles in the acquired slot for good.
reader_transient() {
  [ "$(_bump)" -eq 1 ] && { printf '%s\n' "$SLOT1"; return; }
  printf '%s\n' "$SLOT2"
}
# The pane never leaves the primary checkout.
reader_project() { printf '%s\n' "$PROJ_REAL"; }
# Settled in the acquired slot from the first read.
reader_immediate() { printf '%s\n' "$SLOT2"; }
# Settled, then an intermittent empty read, then settled again.
reader_gap() {
  case "$(_bump)" in
    1 | 3) printf '%s\n' "$SLOT2" ;;
    *) printf '' ;;
  esac
}

# A one-shot transient of the wrong slot must be rejected; discovery returns the
# slot the pane SETTLES in. This is the fm-spawn-worktree-misrecord guarantee and
# the case that fails against a first-match (non-settling) implementation.
test_transient_slot_is_rejected() {
  : >"$CFILE"
  local out
  out=$(fm_worktree_discover_settled reader_transient "$PROJ_REAL" 10 0)
  [ "$out" = "$SLOT2" ] || fail "settled slot not recorded: got '$out', want '$SLOT2'"
  pass "one-shot transient wrong slot is rejected in favor of the settled slot"
}

# A cwd that never leaves the primary checkout never settles: no false worktree.
test_project_cwd_never_settles() {
  : >"$CFILE"
  local out status
  out=$(fm_worktree_discover_settled reader_project "$PROJ_REAL" 3 0)
  status=$?
  [ "$status" -ne 0 ] || fail "project-only cwd should not settle (status $status)"
  [ -z "$out" ] || fail "project-only cwd yielded a worktree: '$out'"
  pass "a cwd that stays in the primary checkout never settles"
}

# The common case: already settled -> accepted after the confirming read.
test_immediate_settle() {
  : >"$CFILE"
  local out
  out=$(fm_worktree_discover_settled reader_immediate "$PROJ_REAL" 10 0)
  [ "$out" = "$SLOT2" ] || fail "immediate settle not accepted: got '$out'"
  pass "an already-settled cwd is accepted"
}

# An intermittent empty read must not reset the running candidate.
test_empty_read_preserves_candidate() {
  : >"$CFILE"
  local out
  out=$(fm_worktree_discover_settled reader_gap "$PROJ_REAL" 10 0)
  [ "$out" = "$SLOT2" ] || fail "empty read reset the candidate: got '$out'"
  pass "an intermittent empty read preserves the settling candidate"
}

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

test_transient_slot_is_rejected
test_project_cwd_never_settles
test_immediate_settle
test_empty_read_preserves_candidate
test_resync_realigns_drifted_submodule
test_resync_no_submodules_is_noop
