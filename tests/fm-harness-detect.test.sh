#!/usr/bin/env bash
# Focused behavior tests for fm-harness.sh in the omp-only world.
#
# detect_own is gone: fm-harness.sh now unconditionally echoes "omp" for own,
# crew, and secondmate. The only variable behavior is the optional model/effort
# token parsing from config/secondmate-harness, tested in fm-secondmate-harness.
#
# This file asserts the basic invariant: own/crew/secondmate all print "omp"
# regardless of environment markers, and the cli is shellcheck-clean.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Drop any ambient harness markers (this suite may run inside a live omp/claude
# session) so the constant-omp path is exercised without marker interference.
unset OMPCODE CLAUDECODE

HARNESS="$ROOT/bin/fm-harness.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-harness-detect.XXXXXX")
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT

check() {
  local desc=$1 args=$2 expected=$3 got
  # shellcheck disable=SC2086  # deliberate word-splitting for argument list
  got=$(bash "$HARNESS" $args 2>/dev/null)
  [ "$got" = "$expected" ] \
    || fail "$desc: expected '$expected', got '$got'"
}

# own: no args → always omp
check "own (no args) is omp"             ""            omp
# crew: always omp
check "crew is omp"                       "crew"        omp
# secondmate: always omp
check "secondmate is omp"                 "secondmate"  omp
# unrecognised subcommand: falls through to the * case → omp
check "unknown subcommand falls to omp"   "not-a-mode"  omp

# env markers do not affect the constant omp result
OMPCODE=1 check "OMPCODE=1 still yields omp"    ""   omp
CLAUDECODE=1 check "CLAUDECODE=1 still yields omp" "" omp

# secondmate-model / secondmate-effort parse the optional token from
# config/secondmate-harness. A missing file gives empty output.
cfg="$TMP_ROOT/config-empty"
mkdir -p "$cfg"
got=$(FM_CONFIG_OVERRIDE="$cfg" bash "$HARNESS" secondmate-model 2>/dev/null)
[ -z "$got" ] || fail "absent secondmate-harness must yield empty model, got '$got'"
got=$(FM_CONFIG_OVERRIDE="$cfg" bash "$HARNESS" secondmate-effort 2>/dev/null)
[ -z "$got" ] || fail "absent secondmate-harness must yield empty effort, got '$got'"

# A line "omp claude3-haiku high" → model=claude3-haiku effort=high
cfg2="$TMP_ROOT/config-tokens"
mkdir -p "$cfg2"
printf 'omp claude3-haiku high\n' > "$cfg2/secondmate-harness"
got_m=$(FM_CONFIG_OVERRIDE="$cfg2" bash "$HARNESS" secondmate-model 2>/dev/null)
got_e=$(FM_CONFIG_OVERRIDE="$cfg2" bash "$HARNESS" secondmate-effort 2>/dev/null)
[ "$got_m" = "claude3-haiku" ] || fail "model token parsed as '$got_m', expected claude3-haiku"
[ "$got_e" = "high" ] || fail "effort token parsed as '$got_e', expected high"

pass "fm-harness.sh always echoes omp for own/crew/secondmate; model/effort tokens parse correctly"
