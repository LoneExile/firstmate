#!/usr/bin/env bash
# fm-test.sh - run the firstmate behavior suite (tests/*.test.sh).
#
# Runs each test in its own env-stripped subprocess with a per-test timeout,
# concurrently via a native bash background-job pool. The pool is deliberately
# NOT GNU parallel or xargs -P: those run each child in a new session detached
# from the controlling terminal, which several real-process tests (watcher,
# daemon, tmux/herdr lifecycle) cannot tolerate - they fail under that wrapper
# even at one job at a time. A plain `bash "$t" &` keeps the exact execution
# context of the serial loop, just concurrent, so results match a serial run.
#
# Each test already isolates its own state (fm_test_tmproot temp dirs) and any
# real session provider it starts (a private tmux `-L` socket, a PID-unique
# herdr `--session`), so concurrent tests do not collide. CI and CONTRIBUTING
# invoke this one runner so the env-strip set, timeout, and file list have a
# single owner.
#
# Ambient harness markers (OMPCODE/CLAUDECODE/HERDR_ENV/TMUX) are stripped per
# test: running the suite from inside a live harness session otherwise leaks
# those markers and deterministically fails the tests that assert on them.
#
# Usage: fm-test.sh [-j JOBS] [-t TIMEOUT] [PATTERN]
#   -j JOBS     concurrent jobs (default: half the CPU count, capped at 8; 1 = serial)
#   -t TIMEOUT  per-test timeout in seconds (default 150; a hang-guard - a slow
#               test starved past it under load is recovered by the serial retry)
#   PATTERN     only run tests whose path matches this grep -E pattern (default: all)
#
# Exit status is non-zero if any test fails or times out. A per-test log for any
# failure is copied to "$TMPDIR/<name>.log"; the summary lists tests slowest-first
# so the long poles are obvious.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- argument parsing --------------------------------------------------------
# Concurrency defaults to half the CPU count (capped at 8): each real-process
# test itself spawns several helper processes, so one job per core oversubscribes
# and starves the slow tests past their timeout. Half-cores runs correctly (its
# results match a serial run); a higher -j is faster but can flake the
# timing-sensitive watcher/daemon tests.
default_jobs() {
  local n
  n=$( { command -v nproc >/dev/null 2>&1 && nproc; } \
    || sysctl -n hw.ncpu 2>/dev/null \
    || echo 4 )
  n=$((n / 2))
  [ "$n" -gt 8 ] 2>/dev/null && n=8
  [ "$n" -ge 1 ] 2>/dev/null || n=1
  printf '%s' "$n"
}
JOBS=$(default_jobs)
TIMEOUT=150
PATTERN=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -j) JOBS=$2; shift 2 ;;
    -j*) JOBS=${1#-j}; shift ;;
    -t) TIMEOUT=$2; shift 2 ;;
    -t*) TIMEOUT=${1#-t}; shift ;;
    -h | --help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) PATTERN=$1; shift ;;
  esac
done
case "$JOBS" in ''|*[!0-9]*) echo "fm-test.sh: -j needs a positive integer" >&2; exit 2 ;; esac
case "$TIMEOUT" in ''|*[!0-9]*) echo "fm-test.sh: -t needs a positive integer" >&2; exit 2 ;; esac
[ "$JOBS" -ge 1 ] || JOBS=1

# --- collect tests -----------------------------------------------------------
cd "$ROOT" || exit 1
tests=()
for t in tests/*.test.sh; do
  [ -e "$t" ] || continue
  if [ -n "$PATTERN" ]; then
    printf '%s\n' "$t" | grep -Eq "$PATTERN" || continue
  fi
  tests+=("$t")
done
if [ "${#tests[@]}" -eq 0 ]; then
  echo "fm-test.sh: no tests match '${PATTERN:-*}'" >&2
  exit 2
fi

resultdir=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-$$.XXXXXX")
trap 'rm -rf "$resultdir"' EXIT
# Hermetic treehouse config: point treehouse at an empty user-config file so a
# developer's global ~/.config/treehouse post_create hooks never run in the suite
# (requires treehouse >= v2.0.2's TREEHOUSE_CONFIG override). $HOME is left real,
# so herdr's live session state and git identity are untouched. Removed with
# $resultdir on EXIT.
empty_th_config="$resultdir/empty-treehouse-config.toml"
: >"$empty_th_config"

# run_one <test>: env-stripped, timed, output to a log, verdict+seconds to a
# .result file. Backgrounded from the main shell so the test inherits the same
# execution context a serial `bash "$t"` would - see the header on why the pool
# is native bash and not GNU parallel/xargs.
run_one() {
  local t=$1 name start end verdict
  name=$(basename "$t")
  start=$(date +%s)
  if env -u OMPCODE -u CLAUDECODE -u HERDR_ENV -u TMUX TREEHOUSE_CONFIG="$empty_th_config" \
    timeout "$TIMEOUT" bash "$t" >"$resultdir/$name.log" 2>&1; then
    verdict=PASS
  else
    verdict=FAIL
  fi
  end=$(date +%s)
  printf '%s %s %s\n' "$verdict" "$((end - start))" "$t" >"$resultdir/$name.result"
}

echo "fm-test.sh: ${#tests[@]} test(s), $JOBS concurrent, ${TIMEOUT}s timeout"
suite_start=$(date +%s)

# --- native bash job pool ----------------------------------------------------
# Throttle to $JOBS concurrent by polling the running-job count. Uses only
# `jobs -r -p` (no `wait -n`), so it works on stock macOS bash 3.2 too.
for t in "${tests[@]}"; do
  while [ "$(jobs -r -p | wc -l | tr -d ' ')" -ge "$JOBS" ]; do
    sleep 0.1
  done
  run_one "$t" &
done
wait

# Serial retry: a concurrent run can starve a slow real-process test past its
# timeout or lose a timing-sensitive race, which a serial run would not. Re-run
# each first-pass failure once, alone, and let the retry result stand. A genuine
# failure (a real bug, or a test that hangs regardless) fails both passes; a
# contention artifact passes on retry. Skipped when already serial (-j1).
retried=0
if [ "$JOBS" -gt 1 ]; then
  for r in "$resultdir"/*.result; do
    read -r verdict _ path <"$r"
    [ "$verdict" = FAIL ] || continue
    retried=$((retried + 1))
    run_one "$path"
  done
  [ "$retried" -gt 0 ] && echo "fm-test.sh: retried $retried first-pass failure(s) serially"
fi

suite_end=$(date +%s)

# --- summarize ---------------------------------------------------------------
fails=0
total_tests=0
# Slowest-first so the long poles are obvious; the sort key is the seconds field.
while read -r verdict secs path; do
  total_tests=$((total_tests + 1))
  if [ "$verdict" = FAIL ]; then
    fails=$((fails + 1))
    printf 'FAIL %4ss %s\n' "$secs" "$path"
  else
    printf 'pass %4ss %s\n' "$secs" "$path"
  fi
done < <(cat "$resultdir"/*.result | sort -k2 -nr)

echo "----"
printf 'TOTAL %ds wall, %d test(s), %d failed (%d concurrent)\n' \
  "$((suite_end - suite_start))" "$total_tests" "$fails" "$JOBS"
if [ "$fails" -gt 0 ]; then
  echo "logs for failures:"
  for r in "$resultdir"/*.result; do
    read -r verdict _ path <"$r"
    [ "$verdict" = FAIL ] || continue
    cp "$resultdir/$(basename "$path").log" "${TMPDIR:-/tmp}/$(basename "$path").log" 2>/dev/null || true
    echo "  ${TMPDIR:-/tmp}/$(basename "$path").log  ($path)"
  done
  exit 1
fi
