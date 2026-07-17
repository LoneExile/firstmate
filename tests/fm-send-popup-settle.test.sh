#!/usr/bin/env bash
# fm-send pre-submit popup-settle selection.
#
# Some TUIs open a completion popup when the composer's first character triggers
# it (e.g. for a leading `/` slash command). Submitting before the popup settles
# lets it swallow the Enter, so the line never submits. fm-send absorbs this by
# pausing `settle` seconds AFTER typing and BEFORE the (retried) Enter - the first
# sleep fm_tmux_submit_core makes. These tests pin the settle-SELECTION matrix
# hermetically (stubbed tmux + sleep, no real agent):
#
#   /...        -> 1.2  (universal; `/` only starts a command, never plain text)
#   other text  -> 0.3  (fast path)
#
# The popup-settle is the FIRST sleep recorded: fm_tmux_submit_core types the text,
# then `sleep "$settle"`, then the Enter-retry loop (sleep 0.4 each) and finally
# fm-send's own post-submit FM_SEND_SETTLE pause. So tail-vs-head matters: this
# suite asserts on the HEAD sleep, distinct from fm-send-settle.test.sh which pins
# the TAIL (post-submit) pause. The retried Enter in fm_tmux_submit_core remains the
# real safety net; this settle is only the optimization that lets the popup clear so
# the first Enter lands.
#
# Every case below passes a LITERAL `$<skill>` message in single quotes on purpose
# so SC2016 is a false positive and is disabled file-wide.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEND="$ROOT/bin/fm-send.sh"

TMP_ROOT=$(fm_test_tmproot fm-send-popup-settle)

# Same stub shape as fm-send-settle.test.sh: a fake tmux that drives the submit
# path to a clean "empty" verdict on the first Enter, and a fake sleep that records
# every requested duration (one per line) into FM_SLEEP_LOG instead of sleeping.
make_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys) exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '0\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '\xe2\x94\x82 \xe2\x94\x82\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${1:-}" >> "$FM_SLEEP_LOG"
exit 0
SH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

# first_settle <expected> <label> <harness|--explicit> <message> [selector-form]: build a fresh
# home, send <message> to a target whose meta records <harness> (or to a bare
# session:window with NO meta when --explicit), and assert the FIRST recorded sleep
# (the popup-settle) equals <expected>. FM_SEND_SETTLE=0 strips the trailing
# post-submit pause so the log holds only the popup-settle plus the 0.4 Enter wait,
# keeping the head assertion crisp. FM_ROOT_OVERRIDE points at a non-repo dir so
# fm-guard's tangle check stays silent; its watcher-liveness note goes to stderr
# (discarded).
first_settle() {  # <expected> <label> <harness|--explicit> <message> [selector-form]
  local expected=$1 label=$2 harness=$3 msg=$4
  local selector_form=${5:-legacy}
  local dir fb log home target rc first meta_id
  dir="$TMP_ROOT/case-$RANDOM"; mkdir -p "$dir/state"
  fb=$(make_stubs "$dir"); log="$dir/sleep.log"; home="$dir"
  if [ "$harness" = --explicit ]; then
    target="sess:win"
  else
    case "$selector_form" in
      exact)
        target="popupcase"
        meta_id=popupcase
        ;;
      legacy)
        target="fm-popupcase"
        meta_id=popupcase
        ;;
      *)
        fail "$label: unknown selector form '$selector_form'"
        ;;
    esac
    fm_write_meta "$home/state/$meta_id.meta" "window=sess:win" "harness=$harness"
  fi
  : > "$log"
  env FM_SEND_SETTLE=0 PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SLEEP_LOG="$log" \
    "$SEND" "$target" "$msg" 2>/dev/null; rc=$?
  expect_code 0 "$rc" "$label: send should succeed"
  first=$(head -1 "$log")
  [ "$first" = "$expected" ] || fail "$label: expected popup-settle $expected, got '$first'"$'\n'"--- sleeps ---"$'\n'"$(cat "$log")"
  pass "fm-send popup-settle: $label -> ${expected}s"
}

# The `/` slash case gives the long settle so its completion popup clears.
first_settle 1.2 'omp /command -> long settle' omp '/no-mistakes'

# The same slash path when addressed by exact task id.
first_settle 1.2 'omp /command exact task id -> long settle' omp '/no-mistakes' exact

# An explicit session:window target with no meta still gets the slash settle.
first_settle 1.2 'explicit target /command -> long settle' --explicit '/no-mistakes'

# A `$`-prefixed message takes the fast path (no harness-specific popup scoping).
first_settle 0.3 'omp $message -> fast path' omp '$no-mistakes'

# An explicit session:window target has no meta - still fast path for `$`.
first_settle 0.3 'explicit target $message -> fast path' --explicit '$no-mistakes'

# Plain text takes the fast path.
first_settle 0.3 'omp plain text -> fast path' omp 'just a normal steer'
