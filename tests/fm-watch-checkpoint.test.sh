#!/usr/bin/env bash
# Tests for bounded foreground watcher checkpoints used by Codex supervision.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-checkpoint)

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

test_quiet_checkpoint_exits_124_cleanly() {
  local home out err status
  home=$(make_home quiet)
  out="$home/out.txt"
  err="$home/err.txt"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?
  expect_code 124 "$status" "quiet checkpoint exit"
  assert_contains "$(cat "$out")" "checkpoint: no actionable wake within 1s" "quiet checkpoint line missing"
  assert_absent "$home/state/.watch.lock/pid" "watch lock pid survived quiet checkpoint timeout"
  pass "quiet checkpoint exits 124 with a clean checkpoint line and no live lock"
}

test_signal_passes_through_and_exits_zero() {
  local home out err status drained
  home=$(make_home signal)
  out="$home/out.txt"
  err="$home/err.txt"
  (
    sleep 1
    printf 'done: synthetic wake\n' > "$home/state/demo.status"
  ) &
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 8 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "signal checkpoint exit"
  assert_contains "$(cat "$out")" "signal:" "signal wake was not passed through"
  drained=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" $'\tsignal\tdemo.status\t' "signal wake was not queued durably"
  pass "checkpoint passes through a real watcher wake and leaves the queue for drain"
}

test_registered_check_uses_preserved_watcher_environment() {
  local home out err status
  home=$(make_home check-env)
  out="$home/out.txt"
  err="$home/err.txt"
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$home/state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$home/state/.pr-check-migration-v1"
  chmod 0600 "$home/state/.pr-check-migration-scan-v1" "$home/state/.pr-check-migration-v1"
  cat > "$home/state/env-check.check.sh" <<'SH'
#!/usr/bin/env bash
printf 'env check fired with FM_CHECK_INTERVAL=%s\n' "${FM_CHECK_INTERVAL:-missing}"
SH
  chmod 0700 "$home/state/env-check.check.sh"
  FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" env-check >/dev/null \
    || fail "could not register checkpoint custom check"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "check checkpoint exit"
  assert_contains "$(cat "$out")" "check:" "check wake was not passed through"
  assert_contains "$(cat "$out")" "FM_CHECK_INTERVAL=1" "watcher environment was not preserved"
  pass "checkpoint preserves watcher environment for registered custom checks"
}

test_existing_singleton_watcher_is_not_success() {
  local home out err status
  home=$(make_home singleton)
  out="$home/out.txt"
  err="$home/err.txt"
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$home/state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$home/state/.pr-check-migration-v1"
  chmod 0600 "$home/state/.pr-check-migration-scan-v1" "$home/state/.pr-check-migration-v1"
  mkdir "$home/state/.watch.lock"
  printf '%s\n' "$$" > "$home/state/.watch.lock/pid"
  status=0
  FM_HOME="$home" FM_GUARD_GRACE=300 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 1 "$status" "singleton checkpoint exit"
  assert_contains "$(cat "$out")" "watcher: already running" "singleton watcher output was not passed through"
  assert_contains "$(cat "$err")" "outside this foreground checkpoint" "singleton watcher failure was not explained"
  pass "checkpoint rejects an existing watcher singleton as unowned"
}

test_terminal_check_verdict_fires_once_not_every_sweep() {
  # Regression: a merged PR poll (terminal, monotonic verdict) re-emits `merged`
  # on every sweep until teardown. Before the fired-marker dedup it woke the
  # captain every CHECK_INTERVAL forever; now an unchanged verdict fires once.
  local home out err status drained
  home=$(make_home terminal-verdict)
  out="$home/out.txt"; err="$home/err.txt"
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$home/state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$home/state/.pr-check-migration-v1"
  chmod 0600 "$home/state/.pr-check-migration-scan-v1" "$home/state/.pr-check-migration-v1"
  cat > "$home/state/merged-demo.check.sh" <<'SH'
#!/usr/bin/env bash
printf 'merged\n'
SH
  chmod 0700 "$home/state/merged-demo.check.sh"
  FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" merged-demo >/dev/null \
    || fail "could not register terminal-verdict custom check"

  # First sweep: the verdict is new -> fires a check wake.
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "first terminal-verdict checkpoint exit"
  assert_contains "$(cat "$out")" "check:" "first sweep did not fire the terminal verdict"
  assert_present "$home/state/.check-fired-merged-demo" "fired-marker was not written on first fire"
  # Drain so a stale queue entry cannot be what a later drain sees.
  FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2>&1 || true

  # Force the check block to run again (age_of a missing .last-check is "due").
  rm -f "$home/state/.last-check"

  # Second sweep: SAME verdict -> deduped -> no actionable wake -> quiet 124.
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 "$CHECKPOINT" --seconds 2 >"$out" 2>"$err" || status=$?
  expect_code 124 "$status" "second terminal-verdict checkpoint should be quiet (deduped)"
  if grep -q 'check:' "$out"; then
    fail "second sweep re-fired an unchanged terminal verdict (dedup failed): $(cat "$out")"
  fi
  pass "a terminal check verdict fires once, not on every sweep"
}

test_changed_check_verdict_refires_after_dedup() {
  # The dedup is by verdict CONTENT: a genuinely different verdict (e.g. a fresh
  # x-mention <request_id>) must still fire even though the check already fired.
  local home out err status
  home=$(make_home changed-verdict)
  out="$home/out.txt"; err="$home/err.txt"
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$home/state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$home/state/.pr-check-migration-v1"
  chmod 0600 "$home/state/.pr-check-migration-scan-v1" "$home/state/.pr-check-migration-v1"
  # Emits the content of state/verdict.txt each sweep, so the test can change it.
  cat > "$home/state/changing-demo.check.sh" <<'SH'
#!/usr/bin/env bash
cat "$(dirname "$0")/verdict.txt" 2>/dev/null || true
SH
  chmod 0700 "$home/state/changing-demo.check.sh"
  printf 'x-mention req-1\n' > "$home/state/verdict.txt"
  FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" changing-demo >/dev/null \
    || fail "could not register changing-verdict custom check"

  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "first changing-verdict checkpoint exit"
  assert_contains "$(cat "$out")" "req-1" "first sweep did not fire req-1"
  FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2>&1 || true
  rm -f "$home/state/.last-check"

  # Change the verdict -> must fire again.
  printf 'x-mention req-2\n' > "$home/state/verdict.txt"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "second changing-verdict checkpoint exit"
  assert_contains "$(cat "$out")" "req-2" "a changed verdict was wrongly deduped"
  pass "a changed check verdict re-fires after the previous fire"
}

test_quiet_checkpoint_exits_124_cleanly
test_signal_passes_through_and_exits_zero
test_registered_check_uses_preserved_watcher_environment
test_existing_singleton_watcher_is_not_success
test_terminal_check_verdict_fires_once_not_every_sweep
test_changed_check_verdict_refires_after_dedup
