#!/usr/bin/env bash
# Tests for supervision instruction rendering (omp-only harness).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-supervision-instructions)
RENDER="$ROOT/bin/fm-supervision-instructions.sh"

test_omp_harness_block() {
  local out
  out=$("$RENDER")
  assert_contains "$out" "SUPERVISION OPERATING INSTRUCTIONS - primary harness: omp" "omp heading missing"
  assert_not_contains "$out" "primary harness: codex" "renderer printed a codex heading"
  assert_not_contains "$out" "primary harness: claude" "renderer printed a claude heading"
  assert_not_contains "$out" "primary harness: pi" "renderer printed a pi heading"
  assert_not_contains "$out" "primary harness: grok" "renderer printed a grok heading"
  pass "renderer always prints the omp harness block"
}

test_harness_arg_ignored() {
  # --harness is vestigial; harness is unconditionally omp.
  local out
  out=$("$RENDER" --harness codex)
  assert_contains "$out" "primary harness: omp" "--harness codex must be ignored; still prints omp"
  out=$("$RENDER" --harness not-real)
  assert_contains "$out" "primary harness: omp" "--harness not-real must be ignored; still prints omp"
  pass "renderer ignores the --harness arg and always emits the omp block"
}

test_conditional_stanzas() {
  local home config out
  home="$TMP_ROOT/conditional-home"
  config="$TMP_ROOT/conditional-config"
  mkdir -p "$home/state" "$home/config" "$config"
  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" "$RENDER" --read-only 1 --afk 1 --x-mode 1)
  assert_contains "$out" "- Lock: read-only" "read-only stanza missing"
  assert_contains "$out" "- Away mode: active" "afk stanza missing"
  assert_contains "$out" "- X mode: active" "x-mode stanza missing"
  assert_contains "$out" "$config/x-mode.env" "x-mode stanza did not render the effective config path"
  assert_contains "$out" "primary harness: omp" "omp heading missing from conditional render"
  assert_not_contains "$out" "Source \`config/x-mode.env\`" "snippet kept the repo-relative x-mode config path"
  pass "renderer includes read-only, afk, and effective x-mode current-state stanzas"
}

test_repair_lines() {
  local home out
  home="$TMP_ROOT/repair-home"
  mkdir -p "$home/state" "$home/config"

  out=$(FM_HOME="$home" "$RENDER" --repair-line)
  assert_contains "$out" "fm_watch_arm_omp" "omp repair line does not direct the model to the extension-owned tool"

  out=$(FM_HOME="$home" "$RENDER" --queue-pending 1 --repair-line)
  assert_contains "$out" "After draining queued wakes" "queue-pending prefix missing from omp repair line"

  : > "$home/config/x-mode.env"
  out=$(FM_HOME="$home" "$RENDER" --x-mode 1 --repair-line)
  assert_contains "$out" "source '$home/config/x-mode.env' first" "x-mode repair line did not source the effective cadence config"

  out=$(FM_HOME="$home" "$RENDER" --read-only 1 --repair-line)
  assert_contains "$out" "session holding the fleet lock" "read-only repair line missing"

  pass "renderer repair-line mode is omp-aware and honors conditional state"
}

test_ordinary_wake_line_distinct_from_repair() {
  local home out ordinary repair
  home="$TMP_ROOT/ordinary-home"
  mkdir -p "$home/state" "$home/config"

  out=$(FM_HOME="$home" "$RENDER")
  ordinary=$(printf '%s\n' "$out" | grep -F -- '- Ordinary wake:')
  assert_contains "$ordinary" "the omp extension already owns watcher continuity" "ordinary-wake line does not leave continuity to the extension"
  assert_not_contains "$ordinary" "fm_watch_arm_omp" "ordinary-wake line incorrectly tells the model to arm the recovery tool"
  assert_not_contains "$out" "resume this emitted harness protocol" "renderer kept the old hardcoded after-every-wake re-arm wording"

  repair=$(FM_HOME="$home" "$RENDER" --repair-line)
  assert_contains "$repair" "repair a missing or failed watcher cycle" "repair line lost the recovery verb"
  assert_contains "$repair" "fm_watch_arm_omp" "repair line lost the extension-owned recovery tool"
  pass "renderer distinguishes ordinary-wake continuation from failure recovery"
}

test_omp_snippet_uses_effective_extension_path() {
  local home out turnend watch
  home="$TMP_ROOT/omp-home"
  turnend="$ROOT/.omp/extensions/fm-primary-turnend-guard.ts"
  watch="$ROOT/.omp/extensions/fm-primary-omp-watch.ts"
  mkdir -p "$home/state" "$home/config"
  out=$(FM_HOME="$home" "$RENDER")
  assert_contains "$out" "$turnend" "omp snippet did not render the turn-end guard extension path"
  assert_contains "$out" "$watch" "omp snippet did not render the watcher extension path"
  assert_not_contains "$out" "__FM_OMP_EXT__" "renderer leaked the OMP extension path placeholder"
  assert_not_contains "$out" "__FM_OMPTURNEND__" "renderer leaked the OMP turn-end extension path placeholder"
  pass "omp supervision snippet renders the effective extension paths"
}

test_omp_harness_block
test_harness_arg_ignored
test_conditional_stanzas
test_repair_lines
test_ordinary_wake_line_distinct_from_repair
test_omp_snippet_uses_effective_extension_path
