#!/usr/bin/env bash
# Behavior tests for bin/fm-test.sh, the suite runner. Contract: it selects tests
# by PATTERN, runs them concurrently, prints a per-test verdict plus a TOTAL line,
# and exits non-zero iff a selected test failed. Cases select a single fast, pure
# test (fm-worktree-lib) so the runner-of-the-runner stays quick and hermetic.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RUNNER="$ROOT/bin/fm-test.sh"

# A passing selection: exit 0, a pass line for the selected test, and 0 failed.
test_runner_reports_pass() {
  local out status
  out=$(env -u OMPCODE -u CLAUDECODE -u HERDR_ENV -u TMUX bash "$RUNNER" -j1 'fm-worktree-lib' 2>&1)
  status=$?
  expect_code 0 "$status" "runner exit on a passing selection"
  printf '%s\n' "$out" | grep -Eq 'pass +[0-9]+s tests/fm-worktree-lib\.test\.sh' \
    || fail "runner did not report the selected test as passing: $out"
  printf '%s\n' "$out" | grep -Eq 'TOTAL [0-9]+s wall, 1 test\(s\), 0 failed' \
    || fail "runner did not summarize 1 test, 0 failed: $out"
  pass "runner runs the selected test and reports pass + TOTAL"
}

# The glued short-flag form (-j2) parses the same as the spaced form.
test_runner_parses_glued_jobs() {
  local out
  out=$(env -u OMPCODE -u CLAUDECODE -u HERDR_ENV -u TMUX bash "$RUNNER" -j2 'fm-worktree-lib' 2>&1)
  printf '%s\n' "$out" | grep -Eq '2 concurrent' \
    || fail "runner did not parse glued -j2: $out"
  pass "runner accepts the glued -jN form"
}

# A pattern that matches nothing is a usage error (exit 2), not a silent success.
test_runner_no_match_errors() {
  local out status
  out=$(env -u OMPCODE -u CLAUDECODE -u HERDR_ENV -u TMUX bash "$RUNNER" 'zzz-no-such-test-zzz' 2>&1)
  status=$?
  expect_code 2 "$status" "runner exit on a pattern matching no test"
  printf '%s\n' "$out" | grep -Fq 'no tests match' \
    || fail "runner did not report an empty selection: $out"
  pass "runner errors (exit 2) when the pattern matches no test"
}

test_runner_reports_pass
test_runner_parses_glued_jobs
test_runner_no_match_errors
