#!/usr/bin/env bash
# Behavior tests for the primary turn-end supervision guard (docs/turnend-guard.md).
#
# Two layers:
#   PREDICATE  - bin/fm-supervision-lib.sh, the shared beacon/status computation
#                used by fm-guard.sh and by the hook's banner details.
#   HOOK       - bin/fm-turnend-guard.sh, the shared primary hook predicate that
#                scopes in-flight work to the PRIMARY checkout only and requires
#                a live, identity-matched watcher lock plus a fresh beacon.
# All hermetic over temp dirs; no real agent session is invoked.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-supervision-lib.sh
. "$ROOT/bin/fm-supervision-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-turnend-guard)
fm_git_identity fmtest fmtest@example.invalid

# Drop ambient omp session marker so the test runs cleanly whether or not an
# interactive omp session is active.
unset OMPCODE CLAUDECODE

REQUIRED_REASON='resume supervision with the OMP tool fm_watch_arm_omp'

# --- PREDICATE: bin/fm-supervision-lib.sh -----------------------------------

test_predicate_healthy_no_inflight() {
  local state="$TMP_ROOT/pred-empty/state"
  mkdir -p "$state"
  if fm_supervision_unhealthy "$state" 300; then
    fail "predicate reported unhealthy with zero in-flight tasks"
  fi
  [ "$FM_SUP_IN_FLIGHT" -eq 0 ] || fail "expected zero in-flight, got $FM_SUP_IN_FLIGHT"
  pass "fm_supervision_unhealthy: false with no state/*.meta at all"
}

test_predicate_unhealthy_no_beacon() {
  local state="$TMP_ROOT/pred-nobeat/state"
  mkdir -p "$state"
  : > "$state/task1.meta"
  fm_supervision_unhealthy "$state" 300 || fail "predicate did not fire: in-flight task, beacon never seen"
  [ "$FM_SUP_IN_FLIGHT" -eq 1 ] || fail "expected 1 in-flight, got $FM_SUP_IN_FLIGHT"
  [ "$FM_SUP_WATCHER_FRESH" = false ] || fail "beacon absent must not read as fresh"
  [ "$FM_SUP_BEACON_DESC" = never ] || fail "beacon description should be 'never', got $FM_SUP_BEACON_DESC"
  pass "fm_supervision_unhealthy: true with in-flight task and no beacon ever"
}

test_predicate_unhealthy_stale_beacon() {
  local state="$TMP_ROOT/pred-stale/state"
  mkdir -p "$state"
  : > "$state/task1.meta"
  touch -t 202001010000 "$state/.last-watcher-beat"
  fm_supervision_unhealthy "$state" 300 || fail "predicate did not fire: in-flight task, beacon far outside grace"
  [ "$FM_SUP_WATCHER_FRESH" = false ] || fail "an ancient beacon must not read as fresh"
  pass "fm_supervision_unhealthy: true with in-flight task and a beacon far outside the grace window"
}

test_predicate_healthy_fresh_beacon() {
  local state="$TMP_ROOT/pred-fresh/state"
  mkdir -p "$state"
  : > "$state/task1.meta"
  touch "$state/.last-watcher-beat"
  if fm_supervision_unhealthy "$state" 300; then
    fail "predicate fired despite a fresh beacon"
  fi
  [ "$FM_SUP_WATCHER_FRESH" = true ] || fail "a beacon touched just now must read as fresh"
  pass "fm_supervision_unhealthy: false with in-flight task and a fresh beacon"
}

test_predicate_queue_pending_flag() {
  local state="$TMP_ROOT/pred-queue/state"
  mkdir -p "$state"
  fm_supervision_status "$state" 300
  [ "$FM_SUP_QUEUE_PENDING" = false ] || fail "empty/absent wake queue must not read as pending"
  printf 'record\n' > "$state/.wake-queue"
  fm_supervision_status "$state" 300
  [ "$FM_SUP_QUEUE_PENDING" = true ] || fail "a non-empty wake queue must read as pending"
  pass "fm_supervision_status: FM_SUP_QUEUE_PENDING tracks state/.wake-queue"
}

# --- HOOK: bin/fm-turnend-guard.sh ------------------------------------------
#
# Each scenario gets its own directory carrying a copy of the two guard scripts
# under bin/, so the hook (invoked by absolute path) resolves its own FM_ROOT to
# that scenario dir regardless of the test's cwd.

install_guard_scripts() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-turnend-guard.sh" "$dir/bin/fm-turnend-guard.sh"
  cp "$ROOT/bin/fm-supervision-instructions.sh" "$dir/bin/fm-supervision-instructions.sh"
  cp "$ROOT/bin/fm-harness.sh" "$dir/bin/fm-harness.sh"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$dir/bin/fm-supervision-lib.sh"
  cp "$ROOT/bin/fm-wake-lib.sh" "$dir/bin/fm-wake-lib.sh"
  mkdir -p "$dir/docs"
  cp -R "$ROOT/docs/supervision-protocols" "$dir/docs/supervision-protocols"
  chmod +x "$dir/bin/fm-turnend-guard.sh" "$dir/bin/fm-supervision-instructions.sh" "$dir/bin/fm-harness.sh"
}


# A primary-shaped checkout: plain (non-worktree) git repo, AGENTS.md, bin/,
# state/ - everything the hook's scoping check requires to treat it as primary.
make_primary_dir() {
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  install_guard_scripts "$dir"
  printf '%s\n' "$dir"
}

# Same shape as primary, plus the .fm-secondmate-home marker bin/fm-home-seed.sh
# writes at seed time (regardless of treehouse-lease or git-clone acquisition).
make_secondmate_dir() {
  local dir=$1
  make_primary_dir "$dir" >/dev/null
  printf 'sm-test-1\n' > "$dir/.fm-secondmate-home"
  printf '%s\n' "$dir"
}

# A genuine linked `git worktree` of a base repo - the shape bin/fm-spawn.sh
# always hands crewmate/scout tasks working on firstmate itself. git-dir and
# git-common-dir differ here, unlike a plain checkout.
make_crewmate_worktree_dir() {
  local base=$1 dir=$2
  fm_git_worktree "$base" "$dir" fm/turnend-guard-test-branch
  mkdir -p "$dir/state"
  : > "$dir/AGENTS.md"
  install_guard_scripts "$dir"
  printf '%s\n' "$dir"
}

# A secondmate home's OWN child crew/scout worktree: a genuine linked git
# worktree of the secondmate home, so git-dir != git-common-dir exactly as for a
# main-home child worktree. A child worktree never carries the gitignored
# .fm-secondmate-home marker, so the marker force-include never fires for it and
# it stays exempt through the linked-worktree git-dir test.
make_secondmate_child_worktree_dir() {
  local home=$1 dir=$2
  git -C "$home" worktree add --quiet -b fm/turnend-secondmate-child "$dir"
  mkdir -p "$dir/state"
  : > "$dir/AGENTS.md"
  install_guard_scripts "$dir"
  printf '%s\n' "$dir"
}

# A treehouse-leased secondmate HOME: a genuine linked `git worktree` (git-dir !=
# git-common-dir, exactly like a default treehouse-leased home) that DOES carry a
# valid .fm-secondmate-home marker. This is the production topology the plain
# git-init secondmate fixture cannot represent; the guard must force-INCLUDE it
# as a guarded primary via the marker, not exempt it as a linked worktree.
make_secondmate_linked_home_dir() {
  local base=$1 dir=$2
  fm_git_worktree "$base" "$dir" fm/turnend-secondmate-linked-home
  mkdir -p "$dir/state"
  : > "$dir/AGENTS.md"
  install_guard_scripts "$dir"
  printf 'sm-linked-1\n' > "$dir/.fm-secondmate-home"
  printf '%s\n' "$dir"
}

run_hook() {
  local dir=$1 stop_active=$2 home
  home=$(cd "$dir" && pwd)
  printf '{"stop_hook_active":%s}' "$stop_active" | CLAUDECODE=1 FM_HOME="$home" bash "$dir/bin/fm-turnend-guard.sh" 2>&1
}

nonexistent_pid() {
  local pid=999999
  while kill -0 "$pid" 2>/dev/null; do
    pid=$((pid + 1))
  done
  printf '%s\n' "$pid"
}

watcher_identity() {
  local dir=$1 pid=$2
  FM_STATE_OVERRIDE="$dir/state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$dir/bin/fm-wake-lib.sh" "$pid"
}

record_watcher_lock() {
  local dir=$1 pid=$2 identity=$3 root bin_dir
  root=$(cd "$dir" && pwd)
  bin_dir=$(cd "$dir/bin" && pwd)
  mkdir -p "$dir/state/.watch.lock"
  printf '%s\n' "$pid" > "$dir/state/.watch.lock/pid"
  printf '%s\n' "$root" > "$dir/state/.watch.lock/fm-home"
  printf '%s\n' "$bin_dir/fm-watch.sh" > "$dir/state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$dir/state/.watch.lock/pid-identity"
}

test_hook_silent_when_no_work_in_flight() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-idle")
  out=$(run_hook "$dir" false); status=$?
  expect_code 0 "$status" "hook must exit 0 with no in-flight work"
  [ -z "$out" ] || fail "hook produced output with no in-flight work: $out"
  pass "fm-turnend-guard: silent no-op with nothing in flight"
}

test_hook_blocks_when_fresh_beacon_has_no_live_lock() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-fresh-no-lock")
  : > "$dir/state/task1.meta"
  touch "$dir/state/.last-watcher-beat"
  out=$(run_hook "$dir" false); status=$?
  expect_code 2 "$status" "hook must block when a fresh beacon has no live watcher lock"
  assert_contains "$out" "$REQUIRED_REASON" "block reason must contain the exact required instruction"
  pass "fm-turnend-guard: blocks when a fresh beacon has no live watcher lock"
}

test_hook_blocks_when_dead_lock_has_fresh_beacon() {
  local dir dead out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-dead-lock-fresh")
  dead=$(nonexistent_pid)
  : > "$dir/state/task1.meta"
  record_watcher_lock "$dir" "$dead" "dead watcher identity"
  touch "$dir/state/.last-watcher-beat"
  out=$(run_hook "$dir" false); status=$?
  expect_code 2 "$status" "hook must block when the watcher lock pid is dead despite a fresh beacon"
  assert_contains "$out" "$REQUIRED_REASON" "block reason must contain the exact required instruction"
  pass "fm-turnend-guard: blocks on a dead watcher lock even when the beacon is fresh"
}

test_hook_silent_with_live_lock_and_fresh_beacon() {
  local dir pid identity out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-live-lock-fresh")
  : > "$dir/state/task1.meta"
  sleep 60 &
  pid=$!
  identity=$(watcher_identity "$dir" "$pid") || {
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "could not identify live watcher holder"
  }
  record_watcher_lock "$dir" "$pid" "$identity"
  touch "$dir/state/.last-watcher-beat"
  out=$(run_hook "$dir" false); status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 0 "$status" "hook must exit 0 with a live identity-matched watcher lock and fresh beacon"
  [ -z "$out" ] || fail "hook produced output despite a live fresh watcher lock: $out"
  pass "fm-turnend-guard: silent no-op with a live watcher lock and fresh beacon"
}

test_hook_blocks_with_live_lock_and_stale_beacon() {
  local dir pid identity out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-live-lock-stale")
  : > "$dir/state/task1.meta"
  sleep 60 &
  pid=$!
  identity=$(watcher_identity "$dir" "$pid") || {
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "could not identify live watcher holder"
  }
  record_watcher_lock "$dir" "$pid" "$identity"
  touch -t 202001010000 "$dir/state/.last-watcher-beat"
  out=$(run_hook "$dir" false); status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 2 "$status" "hook must block when a live watcher lock has an ancient beacon"
  assert_contains "$out" "$REQUIRED_REASON" "block reason must contain the exact required instruction"
  pass "fm-turnend-guard: blocks on a live watcher lock with an ancient beacon"
}

test_hook_blocks_when_unhealthy_in_primary() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-block")
  : > "$dir/state/task1.meta"
  out=$(run_hook "$dir" false); status=$?
  expect_code 2 "$status" "hook must block (exit 2) when in-flight work has no live watcher"
  assert_contains "$out" "$REQUIRED_REASON" "block reason must contain the exact required instruction"
  assert_contains "$out" "TURN WOULD END BLIND" "block banner must read as an alarm"
  pass "fm-turnend-guard: blocks with the exact required reason in the primary when unhealthy"
}

test_hook_blocks_from_fm_home_state() {
  local dir home out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-fm-home")
  home="$TMP_ROOT/hook-fm-home-op"
  mkdir -p "$home/state"
  : > "$home/state/task1.meta"
  out=$(printf '{"stop_hook_active":false}' | CLAUDECODE=1 FM_HOME="$home" bash "$dir/bin/fm-turnend-guard.sh" 2>&1); status=$?
  expect_code 2 "$status" "hook must inspect the active FM_HOME state dir"
  assert_contains "$out" "$REQUIRED_REASON" "block reason must contain the exact required instruction"
  pass "fm-turnend-guard: blocks from active FM_HOME state, not only repo-root state"
}

test_hook_x_mode_reason_sources_cadence() {
  local dir home out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-x-mode")
  home=$(cd "$dir" && pwd)
  mkdir -p "$dir/config"
  : > "$dir/config/x-mode.env"
  : > "$dir/state/task1.meta"
  out=$(run_hook "$dir" false); status=$?
  expect_code 2 "$status" "hook must block when in-flight X-mode work has no live watcher"
  assert_contains "$out" "source '$home/config/x-mode.env' first" "block reason must source the effective X-mode cadence"
  pass "fm-turnend-guard: X-mode repair reason sources the cadence config"
}

test_hook_ignores_repo_state_when_fm_home_set() {
  local dir home out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-fm-home-ignore-root")
  home="$TMP_ROOT/hook-fm-home-quiet"
  mkdir -p "$home/state"
  : > "$dir/state/task1.meta"
  out=$(printf '{"stop_hook_active":false}' | FM_HOME="$home" bash "$dir/bin/fm-turnend-guard.sh" 2>&1); status=$?
  expect_code 0 "$status" "hook must ignore repo-root state when FM_HOME selects another state dir"
  [ -z "$out" ] || fail "hook produced output from stale repo-root state despite FM_HOME: $out"
  pass "fm-turnend-guard: ignores stale repo-root state when FM_HOME is set"
}

test_hook_uses_state_override() {
  local dir home state out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-state-override")
  home="$TMP_ROOT/hook-state-override-home"
  state="$TMP_ROOT/hook-state-override-active"
  mkdir -p "$home/state" "$state"
  : > "$state/task1.meta"
  out=$(printf '{"stop_hook_active":false}' | CLAUDECODE=1 FM_HOME="$home" FM_STATE_OVERRIDE="$state" bash "$dir/bin/fm-turnend-guard.sh" 2>&1); status=$?
  expect_code 2 "$status" "hook must let FM_STATE_OVERRIDE win over FM_HOME/state"
  assert_contains "$out" "$REQUIRED_REASON" "block reason must contain the exact required instruction"
  pass "fm-turnend-guard: uses FM_STATE_OVERRIDE ahead of FM_HOME/state"
}

test_hook_loop_guard_allows_retry() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-loopguard")
  : > "$dir/state/task1.meta"
  out=$(run_hook "$dir" true); status=$?
  expect_code 0 "$status" "hook must allow the stop when stop_hook_active is already true"
  [ -z "$out" ] || fail "hook produced output on the loop-guarded retry: $out"
  pass "fm-turnend-guard: stop_hook_active=true always allows the stop (never blocks twice in one turn)"
}

# A secondmate's OWN home runs a primary firstmate session and must be guarded
# exactly like the main primary. This was the guard's proven blind spot: the
# .fm-secondmate-home marker used to early-exit here, so an overnight secondmate
# could end a turn with an unsupervised child and sit blind. Removing that marker
# check makes the guard fire, mirroring the cd-guard.
test_hook_blocks_in_secondmate_own_home() {
  local dir out status
  dir=$(make_secondmate_dir "$TMP_ROOT/hook-secondmate")
  : > "$dir/state/task1.meta"
  out=$(run_hook "$dir" false); status=$?
  expect_code 2 "$status" "hook must guard a secondmate's own home like the main primary when unhealthy"
  assert_contains "$out" "$REQUIRED_REASON" "block reason must contain the exact required instruction"
  assert_contains "$out" "TURN WOULD END BLIND" "block banner must read as an alarm"
  pass "fm-turnend-guard: blocks a blind turn end in a secondmate's own home (.fm-secondmate-home no longer excludes it)"
}

# Idle-by-default: an empty-queue secondmate has no in-flight meta, so the guard
# exits at the in-flight gate - never forcing a busy continuation loop.
test_hook_silent_in_idle_secondmate_home() {
  local dir out status
  dir=$(make_secondmate_dir "$TMP_ROOT/hook-secondmate-idle")
  out=$(run_hook "$dir" false); status=$?
  expect_code 0 "$status" "hook must stay silent in an idle, empty-queue secondmate home"
  [ -z "$out" ] || fail "idle secondmate home produced guard output: $out"
  pass "fm-turnend-guard: idle-by-default - silent in a secondmate home with nothing in flight"
}

# The stop_hook_active loop guard bounds the secondmate to one forced
# continuation per turn, exactly as it does for the main primary - no wedged,
# un-endable session.
test_hook_secondmate_loop_guard_allows_retry() {
  local dir out status
  dir=$(make_secondmate_dir "$TMP_ROOT/hook-secondmate-loopguard")
  : > "$dir/state/task1.meta"
  out=$(run_hook "$dir" true); status=$?
  expect_code 0 "$status" "hook must allow the stop in a secondmate home when stop_hook_active is already true"
  [ -z "$out" ] || fail "secondmate loop-guarded retry produced output: $out"
  pass "fm-turnend-guard: stop_hook_active=true allows the stop in a secondmate home (never blocks twice in one turn)"
}

# The guard's half of the deferred-death recovery loop in a secondmate home,
# proven deterministically without a live model or any daemon: silent while the
# watcher is live (the secondmate ends its turn and relies on the background
# re-invoke), then blocks to force the re-arm once the watcher has exited and a
# second child event lands. The live half - that Claude Code autonomously
# re-invokes the model when the background watcher exits (Mechanism A) - is a
# harness property recorded empirically in docs/turnend-guard.md; it needs a live
# session and cannot be a hermetic CI assertion.
test_hook_secondmate_reinvoke_recovery_loop() {
  local dir pid identity out status
  dir=$(make_secondmate_dir "$TMP_ROOT/hook-secondmate-reinvoke")
  : > "$dir/state/child1.meta"
  sleep 60 &
  pid=$!
  identity=$(watcher_identity "$dir" "$pid") || {
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "could not identify live watcher holder"
  }
  record_watcher_lock "$dir" "$pid" "$identity"
  touch "$dir/state/.last-watcher-beat"
  out=$(run_hook "$dir" false); status=$?
  expect_code 0 "$status" "secondmate turn must end silently while its watcher is live (Stop #1)"
  [ -z "$out" ] || {
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "guard nagged a healthy secondmate at Stop #1: $out"
  }
  # The watcher exits on the wake (its normal lifecycle) and a SECOND child event
  # lands. On the re-invoked recovery turn the secondmate must re-arm; if it did
  # not, the guard blocks that turn's end and forces the re-arm (Stop #2).
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  rm -rf "$dir/state/.watch.lock"
  : > "$dir/state/child2.meta"
  touch "$dir/state/.last-watcher-beat"
  out=$(run_hook "$dir" false); status=$?
  expect_code 2 "$status" "secondmate recovery turn must not end blind after the watcher exits (Stop #2)"
  assert_contains "$out" "$REQUIRED_REASON" "block reason must contain the exact required instruction"
  pass "fm-turnend-guard: secondmate deferred-death recovery - silent while watched, forces re-arm once the watcher exits"
}

# The marker force-include must guard only the secondmate's OWN home, never its
# children: a secondmate's linked crew/scout worktree carries no marker, so it
# stays exempt by the same git-dir/git-common-dir test that exempts the main
# home's children.
test_hook_silent_in_secondmate_child_worktree() {
  local home dir out status
  home=$(make_secondmate_dir "$TMP_ROOT/hook-sm-child-home")
  dir="$TMP_ROOT/hook-sm-child-wt"
  make_secondmate_child_worktree_dir "$home" "$dir" >/dev/null
  : > "$dir/state/task1.meta"
  out=$(run_hook "$dir" false); status=$?
  expect_code 0 "$status" "hook must stay exempt in a secondmate's own child crew/scout worktree"
  [ -z "$out" ] || fail "hook produced output inside a secondmate's child worktree: $out"
  pass "fm-turnend-guard: inert in a secondmate's own child worktree (linked git worktree) even when unhealthy"
}

# THE regression the plain git-init fixtures masked: a treehouse-leased secondmate
# home is a genuine LINKED worktree (git-dir != git-common-dir), which the
# remove-only form wrongly exempted. With the marker force-include, its own
# primary session is GUARDED. The test asserts the fixture really is a linked
# worktree so it can never silently regress back into a plain-checkout shape.
test_hook_blocks_in_treehouse_leased_secondmate_home() {
  local base dir gd gcd out status
  base="$TMP_ROOT/hook-sm-leased-base"
  dir="$TMP_ROOT/hook-sm-leased-home"
  make_secondmate_linked_home_dir "$base" "$dir" >/dev/null
  gd=$(git -C "$dir" rev-parse --git-dir)
  gcd=$(git -C "$dir" rev-parse --git-common-dir)
  [ "$gd" != "$gcd" ] || fail "leased-home fixture must be a linked worktree (git-dir != git-common-dir), got equal: $gd"
  : > "$dir/state/task1.meta"
  out=$(run_hook "$dir" false); status=$?
  expect_code 2 "$status" "hook must GUARD a treehouse-leased (linked) secondmate home via its marker when unhealthy"
  assert_contains "$out" "$REQUIRED_REASON" "block reason must contain the exact required instruction"
  assert_contains "$out" "TURN WOULD END BLIND" "block banner must read as an alarm"
  pass "fm-turnend-guard: blocks a blind turn end in a treehouse-leased LINKED secondmate home (marker force-include)"
}

# Anti-spoof: a linked worktree with an INVALID (empty) marker must NOT be
# force-included. Marker validation rejects it, so it falls through to the
# linked-worktree exemption and stays exempt - a stray/empty marker file can
# never spoof a child worktree into being guarded.
test_hook_exempts_linked_worktree_with_stray_marker() {
  local base dir out status
  base="$TMP_ROOT/hook-stray-marker-base"
  dir="$TMP_ROOT/hook-stray-marker-wt"
  make_crewmate_worktree_dir "$base" "$dir" >/dev/null
  : > "$dir/.fm-secondmate-home"
  : > "$dir/state/task1.meta"
  out=$(run_hook "$dir" false); status=$?
  expect_code 0 "$status" "an empty/invalid marker must not spoof force-inclusion in a linked worktree"
  [ -z "$out" ] || fail "stray empty marker wrongly force-included a linked worktree: $out"
  pass "fm-turnend-guard: an invalid (empty) marker cannot spoof inclusion; linked worktree stays exempt"
}

# Anti-spoof under any locale: a NON-ASCII marker id must be REJECTED by the
# ASCII-only (C-collation) allowlist, so it can never force-include a linked
# worktree even where the ambient locale's collation would treat it as a letter.
# Rejection -> git-dir exemption -> the linked worktree stays exempt.
test_hook_exempts_linked_worktree_with_non_ascii_marker() {
  local base dir out status
  base="$TMP_ROOT/hook-nonascii-marker-base"
  dir="$TMP_ROOT/hook-nonascii-marker-wt"
  make_crewmate_worktree_dir "$base" "$dir" >/dev/null
  printf 'caf\xc3\xa9\n' > "$dir/.fm-secondmate-home"
  : > "$dir/state/task1.meta"
  out=$(run_hook "$dir" false); status=$?
  expect_code 0 "$status" "a non-ASCII marker id must not spoof force-inclusion in a linked worktree"
  [ -z "$out" ] || fail "non-ASCII marker wrongly force-included a linked worktree: $out"
  pass "fm-turnend-guard: a non-ASCII marker cannot spoof inclusion; linked worktree stays exempt"
}

test_hook_silent_in_crewmate_worktree() {
  local base dir out status
  base="$TMP_ROOT/hook-crew-base"
  dir="$TMP_ROOT/hook-crew-wt"
  make_crewmate_worktree_dir "$base" "$dir" >/dev/null
  : > "$dir/state/task1.meta"
  out=$(run_hook "$dir" false); status=$?
  expect_code 0 "$status" "hook must never block inside a crewmate task worktree"
  [ -z "$out" ] || fail "hook produced output inside a crewmate task worktree: $out"
  pass "fm-turnend-guard: inert in a crewmate/scout task worktree (linked git worktree) even when unhealthy"
}

test_hook_silent_without_jq() {
  local dir out status fakebin tool tool_path
  dir=$(make_primary_dir "$TMP_ROOT/hook-nojq")
  : > "$dir/state/task1.meta"
  fakebin=$(fm_fakebin "$TMP_ROOT/hook-nojq-fake")
  for tool in bash sh git cat printf date uname stat mkdir dirname; do
    tool_path=$(command -v "$tool") || fail "test host must provide $tool"
    ln -s "$tool_path" "$fakebin/$tool"
  done
  out=$(printf '{"stop_hook_active":false}' | PATH="$fakebin" bash "$dir/bin/fm-turnend-guard.sh" 2>&1)
  status=$?
  expect_code 0 "$status" "hook must fail open (exit 0) when jq is unavailable"
  [ -z "$out" ] || fail "hook produced output without jq: $out"
  pass "fm-turnend-guard: fails open (never blocks) when jq is missing"
}

test_hook_silent_without_stdin() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-nostdin")
  : > "$dir/state/task1.meta"
  out=$(bash "$dir/bin/fm-turnend-guard.sh" < /dev/null 2>&1); status=$?
  expect_code 0 "$status" "hook must exit 0 on empty/absent stdin"
  [ -z "$out" ] || fail "hook produced output on empty stdin: $out"
  pass "fm-turnend-guard: silent no-op on empty stdin"
}

test_hook_runs_fast() {
  local dir start elapsed_s
  dir=$(make_primary_dir "$TMP_ROOT/hook-timing")
  : > "$dir/state/task1.meta"
  start=$SECONDS
  run_hook "$dir" false >/dev/null
  elapsed_s=$((SECONDS - start))
  [ "$elapsed_s" -lt 3 ] || fail "hook took ${elapsed_s}s, expected well under a second (generous 3s CI margin)"
  pass "fm-turnend-guard: runs well under the generous timing margin (${elapsed_s}s)"
}

test_omp_extension_forces_followup() {
  local ext content
  ext="$ROOT/.omp/extensions/fm-primary-turnend-guard.ts"
  [ -f "$ext" ] || fail "tracked omp primary extension is missing"
  content=$(cat "$ext")
  assert_contains "$content" 'turn_end' "omp extension must run on turn_end (omp has no agent_settled)"
  assert_contains "$content" 'fm-turnend-guard.sh' "omp extension must invoke the shared guard"
  assert_contains "$content" 'sendUserMessage' "omp extension must force a follow-up turn"
  assert_contains "$content" 'deliverAs: "followUp"' "omp extension must queue the follow-up safely"
  assert_contains "$content" 'guardFollowupActive' "omp extension must carry a turn-boundary loop guard"
  assert_contains "$content" 'session-start operating block' "omp extension must use harness-neutral repair wording"
  assert_contains "$content" '.omp-turnend-extension-loaded' "omp extension must write its loaded marker for session-start diagnostics"
  assert_contains "$content" 'lockOwnership' "omp extension loaded marker must respect the session lock"
  pass ".omp primary extension: turn_end forces one follow-up through the shared guard"
}

test_omp_extension_injects_once_per_turn_end() {
  local repo home ext log out status
  repo="$TMP_ROOT/omp-turn-end-root"
  home="$TMP_ROOT/omp-turn-end-home"
  ext="$repo/.omp/extensions/fm-primary-turnend-guard.ts"
  log="$TMP_ROOT/omp-turn-end-guard.log"
  mkdir -p "$repo/.omp/extensions" "$repo/bin" "$home/state"
  cp "$ROOT/.omp/extensions/fm-primary-turnend-guard.ts" "$ext"
  cat > "$repo/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf 'guard\n' >> "${FM_GUARD_LOG:?}"
printf 'logical-run guard fired\n' >&2
exit 2
SH
  cat > "$repo/bin/fm-cd-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$repo/bin/fm-arm-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$repo/bin/fm-turnend-guard.sh" "$repo/bin/fm-cd-pretool-check.sh" "$repo/bin/fm-arm-pretool-check.sh"
  out=$(PLUGIN="$ext" FM_HOME="$home" FM_GUARD_LOG="$log" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { readFileSync } from "node:fs";

const handlers = new Map();
let prompts = 0;
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  async sendUserMessage(message, options) {
    prompts += 1;
    if (!message.includes("TURN WOULD END BLIND")) throw new Error(`unexpected prompt: ${message}`);
    if (options?.deliverAs !== "followUp") throw new Error("guard prompt was not a follow-up");
  },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const turnEnd = handlers.get("turn_end");
if (!turnEnd) throw new Error("turn_end handler was not registered");

// First turn_end: guard fires, injects follow-up (guardFollowupActive → true)
await turnEnd({ type: "turn_end" }, {});
if (prompts !== 1) throw new Error(`first turn_end produced ${prompts} prompts, expected 1`);

// Second turn_end: guardFollowupActive → skip (guard's own follow-up turn), resets to false
await turnEnd({ type: "turn_end" }, {});
if (prompts !== 1) throw new Error(`second turn_end (loop guard) produced ${prompts} prompts, expected still 1`);

// Third turn_end: guard fires again (guardFollowupActive reset to false)
await turnEnd({ type: "turn_end" }, {});
if (prompts !== 2) throw new Error(`third turn_end produced ${prompts} prompts, expected 2`);

const guardRuns = readFileSync(process.env.FM_GUARD_LOG, "utf8").trim().split("\n").length;
if (guardRuns !== 2) throw new Error(`guard predicate ran ${guardRuns} times for 2 non-skipped turn_ends`);
EOF
)
  status=$?
  expect_code 0 "$status" "OMP guard must fire on real turn_end and skip its own follow-up's turn"
  [ -z "$out" ] || fail "OMP turn_end guard test printed output: $out"
  pass ".omp primary extension: guard fires once per real turn_end, skips the follow-up's turn_end"
}

test_omp_extension_retries_after_followup_delivery_failure() {
  local repo home ext out status
  repo="$TMP_ROOT/omp-delivery-failure-root"
  home="$TMP_ROOT/omp-delivery-failure-home"
  ext="$repo/.omp/extensions/fm-primary-turnend-guard.ts"
  mkdir -p "$repo/.omp/extensions" "$repo/bin" "$home/state"
  cp "$ROOT/.omp/extensions/fm-primary-turnend-guard.ts" "$ext"
  cat > "$repo/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf 'delivery failure guard\n' >&2
exit 2
SH
  cat > "$repo/bin/fm-cd-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$repo/bin/fm-arm-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$repo/bin/fm-turnend-guard.sh" "$repo/bin/fm-cd-pretool-check.sh" "$repo/bin/fm-arm-pretool-check.sh"
  out=$(PLUGIN="$ext" FM_HOME="$home" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const handlers = new Map();
let attempts = 0;
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  async sendUserMessage() {
    attempts += 1;
    if (attempts === 1) throw new Error("synthetic delivery failure");
  },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const turnEnd = handlers.get("turn_end");
// First turn_end: delivery fails → guardFollowupActive reset to false
await turnEnd({ type: "turn_end" }, {});
// Second turn_end: must retry (not skipped) → 2nd delivery attempt
await turnEnd({ type: "turn_end" }, {});
if (attempts !== 2) throw new Error(`expected retry after delivery failure, saw ${attempts} attempts`);
EOF
)
  status=$?
  expect_code 0 "$status" "OMP guard latch must reset after follow-up delivery failure"
  [ -z "$out" ] || fail "OMP delivery-failure guard test printed output: $out"
  pass ".omp primary extension: delivery failure resets the turn-boundary latch so the next turn_end retries"
}

test_predicate_healthy_no_inflight
test_predicate_unhealthy_no_beacon
test_predicate_unhealthy_stale_beacon
test_predicate_healthy_fresh_beacon
test_predicate_queue_pending_flag
test_hook_silent_when_no_work_in_flight
test_hook_blocks_when_fresh_beacon_has_no_live_lock
test_hook_blocks_when_dead_lock_has_fresh_beacon
test_hook_silent_with_live_lock_and_fresh_beacon
test_hook_blocks_with_live_lock_and_stale_beacon
test_hook_blocks_when_unhealthy_in_primary
test_hook_blocks_from_fm_home_state
test_hook_x_mode_reason_sources_cadence
test_hook_ignores_repo_state_when_fm_home_set
test_hook_uses_state_override
test_hook_loop_guard_allows_retry
test_hook_blocks_in_secondmate_own_home
test_hook_silent_in_idle_secondmate_home
test_hook_secondmate_loop_guard_allows_retry
test_hook_secondmate_reinvoke_recovery_loop
test_hook_silent_in_secondmate_child_worktree
test_hook_blocks_in_treehouse_leased_secondmate_home
test_hook_exempts_linked_worktree_with_stray_marker
test_hook_exempts_linked_worktree_with_non_ascii_marker
test_hook_silent_in_crewmate_worktree
test_hook_silent_without_jq
test_hook_silent_without_stdin
test_hook_runs_fast
test_omp_extension_forces_followup
test_omp_extension_injects_once_per_turn_end
test_omp_extension_retries_after_followup_delivery_failure
