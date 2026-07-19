#!/usr/bin/env bash
# Shared detector for the captain-parallel-digest NUDGE.
#
# The captain-parallel-digest skill (fan a turn's READ-ONLY analysis out to omp
# subagents, then serialize every decision on the captain) is worth running
# exactly when several finished crews/scouts pile up for review in one turn - but
# a passive AGENTS.md index entry never got it loaded. This lib is the
# DETERMINISTIC steering layer for the one part of that trigger a script can
# detect with certainty: two or more crews/scouts sitting `done` and awaiting the
# captain's review this turn.
#
# ADVISORY only - an optimization, never a gate like TANGLE. Callers print its
# line into the digest and never change control flow or exit status on it. The
# JUDGMENT half of the skill's trigger (a batch that might already be live, a new
# request to scope) is not runtime-detectable and is steered by an imperative at
# the dispatch decision point, not here (firstmate-coding-guidelines "Trigger
# hygiene").
#
# Reuses fm-classify-lib.sh for the one real contract worth sharing - status-log
# verb parsing (last_status_line + status_line_verb) - so `done` means exactly
# what every other consumer means by it.
set -u

_FM_PD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-classify-lib.sh disable=SC1091
. "$_FM_PD_LIB_DIR/fm-classify-lib.sh"

# fm_parallel_digest_done_count <state_dir> -> integer on stdout
# Count crews/scouts (kind=ship|scout) whose last status-log verb is `done`:
# finished and awaiting the captain's review/teardown. A pure read of state with
# no per-crew subprocess (no fm-crew-state / gh call), cheap enough for the
# session-start and every-wake digest paths. Secondmates are excluded (they are
# not captain-review crews). Idempotent: a torn-down crew loses its meta and
# drops out of the count next call.
fm_parallel_digest_done_count() {  # <state_dir>
  local state=$1 meta id kind count=0
  [ -d "$state" ] || { printf '0'; return 0; }
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    # kind uses LAST-value semantics: fm-promote.sh appends `kind=ship` to
    # promote a scout, so a first-match read would misclassify a promoted crew.
    kind=$(grep -E '^kind=' "$meta" 2>/dev/null | tail -n1 | cut -d= -f2-)
    case "$kind" in ship|scout) ;; *) continue ;; esac
    id=$(basename "$meta" .meta)
    [ "$(status_line_verb "$(last_status_line "$state/$id.status")")" = "done" ] || continue
    count=$((count + 1))
  done
  printf '%s' "$count"
}

# fm_parallel_digest_nudge_line <state_dir> <primary_harness>
# Print the one advisory NUDGE_PARALLEL_DIGEST digest line when BOTH hold:
#   - the primary harness is omp (the skill needs omp subagents on the captain), and
#   - two or more crews/scouts are done and awaiting review this turn.
# Otherwise print nothing. Never fails, never mutates.
fm_parallel_digest_nudge_line() {  # <state_dir> <primary_harness>
  local state=$1 harness=$2 n
  [ "$harness" = omp ] || return 0
  n=$(fm_parallel_digest_done_count "$state")
  [ "$n" -ge 2 ] || return 0
  printf 'NUDGE_PARALLEL_DIGEST: %s crews/scouts are done and awaiting review this turn\n' "$n"
}
