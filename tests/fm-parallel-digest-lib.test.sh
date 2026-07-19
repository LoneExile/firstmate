#!/usr/bin/env bash
# tests/fm-parallel-digest-lib.test.sh - unit tests for the captain-parallel-digest
# NUDGE detector (bin/fm-parallel-digest-lib.sh): the done crew/scout count and the
# omp-gated, >=2-threshold advisory nudge line. Pure reads of state; no backend.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-parallel-digest-lib.sh
. "$ROOT/bin/fm-parallel-digest-lib.sh"

TMP=$(fm_test_tmproot fm-parallel-digest)
ST="$TMP/state"
mkdir -p "$ST"

mk() {  # <id> <meta-body> <status-line>
  printf '%s\n' "$2" > "$ST/$1.meta"
  printf '%s\n' "$3" > "$ST/$1.status"
}

# --- done count -------------------------------------------------------------

[ "$(fm_parallel_digest_done_count "$ST")" = 0 ] || fail "empty state must count 0"
pass "fm_parallel_digest_done_count: no crews -> 0"

mk a "kind=ship" "done: PR merged"
[ "$(fm_parallel_digest_done_count "$ST")" = 1 ] || fail "one done ship must count 1"

mk b "kind=scout" "done: report ready"
[ "$(fm_parallel_digest_done_count "$ST")" = 2 ] || fail "a done ship + a done scout must count 2"
pass "fm_parallel_digest_done_count: counts done ships AND done scouts"

# working / blocked crews are NOT done and must not inflate the count.
mk c "kind=ship" "working: still grinding"
mk d "kind=ship" "blocked: waiting on human"
[ "$(fm_parallel_digest_done_count "$ST")" = 2 ] || fail "working/blocked crews must not count as done"
pass "fm_parallel_digest_done_count: only the done verb counts (working/blocked excluded)"

# secondmates are not captain-review crews and are excluded.
mk e "kind=secondmate" "done: sub-fleet idle"
[ "$(fm_parallel_digest_done_count "$ST")" = 2 ] || fail "a done secondmate must be excluded"
pass "fm_parallel_digest_done_count: secondmates are excluded"

# a promoted scout has kind=scout THEN kind=ship appended (fm-promote.sh); the
# last-value read must classify it as a crew so a done promoted scout still counts.
printf 'kind=scout\nkind=ship\n' > "$ST/f.meta"
printf 'done: promoted then finished\n' > "$ST/f.status"
[ "$(fm_parallel_digest_done_count "$ST")" = 3 ] || fail "a done promoted scout (kind=scout then kind=ship) must count"
pass "fm_parallel_digest_done_count: last-value kind handles a promoted scout"

# a crew with no status file yet is not done.
printf 'kind=ship\n' > "$ST/g.meta"
[ "$(fm_parallel_digest_done_count "$ST")" = 3 ] || fail "a statusless crew must not count as done"
pass "fm_parallel_digest_done_count: a statusless crew is not done"

# --- nudge line: omp gate + >=2 threshold -----------------------------------

# count is now 3 (a, b, f); omp -> fires, naming the count.
out=$(fm_parallel_digest_nudge_line "$ST" omp)
case "$out" in
  "NUDGE_PARALLEL_DIGEST: 3 crews/scouts are done and awaiting review this turn") : ;;
  *) fail "omp + 3 done must emit the nudge naming N=3, got: '$out'" ;;
esac
pass "fm_parallel_digest_nudge_line: omp + >=2 done emits the NUDGE naming the count"

# a non-omp harness must stay silent even with >=2 done (defensive gate).
[ -z "$(fm_parallel_digest_nudge_line "$ST" claude)" ] || fail "a non-omp harness must not emit the nudge"
[ -z "$(fm_parallel_digest_nudge_line "$ST" unknown)" ] || fail "an unknown harness must not emit the nudge"
pass "fm_parallel_digest_nudge_line: silent on a non-omp harness"

# below the 2-crew threshold -> silent even on omp (no single-item nudge).
ST2="$TMP/state-one"; mkdir -p "$ST2"
printf 'kind=ship\n' > "$ST2/only.meta"
printf 'done: solo\n' > "$ST2/only.status"
[ -z "$(fm_parallel_digest_nudge_line "$ST2" omp)" ] || fail "a single done crew must not fire (the parallel win needs >=2)"
pass "fm_parallel_digest_nudge_line: silent below the 2-crew threshold"

echo "# fm-parallel-digest-lib.test.sh: all assertions passed"
