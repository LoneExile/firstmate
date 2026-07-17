#!/usr/bin/env bash
# Focused behavior tests for fm-harness.sh's detect_own Layer-2 ancestry match,
# specifically the bare-interpreter args branch (node/python/bun).
#
# Regression: a live omp runs as `bun /…/omp --auto-approve …` and a live pi as
# `node /…/pi …`, so the args carry the harness only as a path-final component
# followed by flags. The old globs (`*" omp "*|*/omp`, `*" pi "*|*/pi`) matched
# only a trailing `/omp` or a space-delimited ` omp `, so the real launched form
# (`.../omp --auto-approve …`) fell through to `unknown`. The globs now mirror
# fm-lock.sh's `(^|/| )name( |$)` word boundary. Verified live 2026-07-17: a real
# omp process reports comm=bun with args `bun /Users/…/.bun/bin/omp`.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# detect_own checks OMPCODE/CLAUDECODE/PI_CODING_AGENT/GROK_AGENT first; drop any
# ambient markers (this suite may run inside a live omp/claude session) so the
# Layer-2 ancestry path under test is actually exercised.
unset OMPCODE CLAUDECODE PI_CODING_AGENT GROK_AGENT

HARNESS="$ROOT/bin/fm-harness.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-harness-detect.XXXXXX")
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT

# Extract just detect_own so sourcing does not run the CLI dispatch.
FUNCTIONS="$TMP_ROOT/detect.sh"
awk '/^detect_own\(\)/ {c=1} c{print} c&&/^}/{c=0}' "$HARNESS" > "$FUNCTIONS"
# shellcheck disable=SC1090  # generated directly from the tracked script under test
. "$FUNCTIONS"

# Fake ps: detect_own calls `ps -o comm= -p`, `ps -o args= -p`, `ps -o ppid= -p`.
# Return canned fields from FAKE_PS_* and a ppid of 1 so the ancestry walk ends
# after a single deterministic iteration.
FAKEBIN="$TMP_ROOT/bin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/ps" <<'SH'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    comm=) printf '%s\n' "${FAKE_PS_COMM:-bun}"; exit 0 ;;
    args=) printf '%s\n' "${FAKE_PS_ARGS:-}"; exit 0 ;;
    ppid=) printf '%s\n' "${FAKE_PS_PPID:-1}"; exit 0 ;;
  esac
done
exit 0
SH
chmod +x "$FAKEBIN/ps"

check() {
  local desc=$1 comm=$2 args=$3 expected=$4 got
  got=$(export PATH="$FAKEBIN:$PATH" FAKE_PS_COMM="$comm" FAKE_PS_ARGS="$args" FAKE_PS_PPID=1; detect_own)
  [ "$got" = "$expected" ] \
    || fail "$desc: expected '$expected', got '$got'"$'\n'"  comm=$comm args=$args"
}

# The launched form firstmate actually spawns (the bug this fix closes).
check "omp launched form (bun, path + flags)" \
  bun "bun /Users/lex/.bun/bin/omp --auto-approve -e /s/x.omp-ext.ts prompt" omp
check "omp bare path at end of args" \
  bun "bun /Users/lex/.bun/bin/omp" omp
check "pi launched form (node, path + flags)" \
  node "node /Users/lex/.pi/bin/pi --thinking high -e /s/x.pi-ext.ts prompt" pi

# Guard against false positives: an omp worker embeds omp only as `_omp_`, and an
# unrelated interpreter session must never be attributed to a harness.
check "omp worker args are NOT the harness" \
  bun "bun cli.js __omp_worker_daemon_broker" unknown
check "unrelated bun script is unknown" \
  bun "bun /Users/lex/tools/build.js --watch" unknown
check "unrelated node script is unknown" \
  node "node /some/random/server.js" unknown

# Native binaries still match by args substring (unchanged behavior).
check "claude via args still matches" \
  node "node /opt/claude/cli.js" claude

pass "detect_own resolves omp/pi from real bare-interpreter launched-form args and rejects non-harness interpreters"
