#!/usr/bin/env bash
# fm-send per-target send lock.
#
# fm-send.sh serializes concurrent sends to ONE resolved target with a portable,
# stale-tolerant mutex (fm_lock_acquire_wait around the type+submit critical
# section, released on EXIT so error paths unlock too). Without it, two callers
# racing into the same pane (e.g. several Quartermaster /set-sail handoffs into
# the captain's pane) can interleave their keystrokes.
#
# This proves the mutex behaviorally: two fm-send processes hit the SAME target
# concurrently, and the tmux backend stub records how many callers are inside the
# type step at once. Serialized => never more than one => no overlap recorded.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEND="$ROOT/bin/fm-send.sh"
TMP_ROOT=$(fm_test_tmproot fm-send-lock)

# tmux backend stub. The literal-type step (send-keys -l) marks itself in-flight,
# counts concurrent in-flight callers, records any overlap, then holds long enough
# that a second UNSERIALIZED caller would reach its own type step meanwhile. Enter
# and the readback verbs behave like a healthy submit.
make_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      printf 'type pid=%s\n' "$$" >> "$FM_SEND_TYPELOG"
      : > "$FM_INFLIGHT/$$"
      cnt=$(find "$FM_INFLIGHT" -type f | wc -l | tr -d ' ')
      [ "$cnt" -le 1 ] || printf 'overlap cnt=%s\n' "$cnt" >> "$FM_OVERLAP"
      sleep 0.7
      rm -f "$FM_INFLIGHT/$$"
    fi
    exit 0 ;;
  display-message)
    printf '%%1\n'; exit 0 ;;
  capture-pane)
    printf '\xe2\x94\x82 \xe2\x94\x82\n'; exit 0 ;;
  list-windows)
    printf 'sess:%s\n' "${FM_FAKE_TMUX_WINDOW:-fm-none}"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

run_send_bg() {  # <fb> <home> <inflight> <overlap> <typelog> <target> <text> <rc-file>
  local fb=$1 home=$2 inflight=$3 overlap=$4 typelog=$5 target=$6 text=$7 rcfile=$8
  (
    PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
      FM_INFLIGHT="$inflight" FM_OVERLAP="$overlap" FM_SEND_TYPELOG="$typelog" \
      FM_SEND_SETTLE=0 FM_LOCK_STALE_AFTER=3600 \
      "$SEND" "$target" "$text" >/dev/null 2>&1
    printf '%s\n' "$?" > "$rcfile"
  ) &
}

test_concurrent_sends_to_one_target_do_not_interleave() {
  local dir fb home inflight overlap typelog rcA rcB
  dir="$TMP_ROOT/serialize"; mkdir -p "$dir"
  fb=$(make_stubs "$dir")
  home="$dir/home"; mkdir -p "$home/state"
  inflight="$dir/inflight"; mkdir -p "$inflight"
  overlap="$dir/overlap"; : > "$overlap"
  typelog="$dir/typelog"; : > "$typelog"
  rcA="$dir/rcA"; rcB="$dir/rcB"
  fm_write_meta "$home/state/lane-x.meta" "window=sess:fm-lane-x" "kind=ship" "harness=omp"

  # Two callers race into the SAME resolved target (fm-lane-x).
  run_send_bg "$fb" "$home" "$inflight" "$overlap" "$typelog" fm-lane-x "alpha handoff" "$rcA"
  run_send_bg "$fb" "$home" "$inflight" "$overlap" "$typelog" fm-lane-x "beta handoff" "$rcB"
  wait

  [ "$(cat "$rcA" 2>/dev/null)" = 0 ] || fail "first concurrent send did not succeed (rc=$(cat "$rcA" 2>/dev/null))"
  [ "$(cat "$rcB" 2>/dev/null)" = 0 ] || fail "second concurrent send did not succeed (rc=$(cat "$rcB" 2>/dev/null))"
  local types; types=$(grep -c '^type pid=' "$typelog")
  [ "$types" = 2 ] || fail "expected both sends to type once each (type count $types)"
  [ ! -s "$overlap" ] || fail "concurrent sends to one target interleaved (overlap recorded)"$'\n'"$(cat "$overlap")"
  # The lock dir must not be left behind after both callers exit.
  local locks; locks=$(find "$home/state" -maxdepth 1 -name '.send-lock.*' | wc -l | tr -d ' ')
  [ "$locks" = 0 ] || fail "send lock was not released after the sends completed ($locks left)"
  pass "fm-send serializes concurrent sends to one target (no keystroke interleave)"
}

test_lock_is_per_target_not_global() {
  # Two DIFFERENT targets must NOT contend: their overlap is expected and proves
  # the lock is keyed per resolved target, not one global send lock.
  local dir fb home inflight overlap typelog rcA rcB
  dir="$TMP_ROOT/pertarget"; mkdir -p "$dir"
  fb=$(make_stubs "$dir")
  home="$dir/home"; mkdir -p "$home/state"
  inflight="$dir/inflight"; mkdir -p "$inflight"
  overlap="$dir/overlap"; : > "$overlap"
  typelog="$dir/typelog"; : > "$typelog"
  rcA="$dir/rcA"; rcB="$dir/rcB"
  fm_write_meta "$home/state/lane-a.meta" "window=sess:fm-lane-a" "kind=ship" "harness=omp"
  fm_write_meta "$home/state/lane-b.meta" "window=sess:fm-lane-b" "kind=ship" "harness=omp"

  run_send_bg "$fb" "$home" "$inflight" "$overlap" "$typelog" fm-lane-a "to A" "$rcA"
  run_send_bg "$fb" "$home" "$inflight" "$overlap" "$typelog" fm-lane-b "to B" "$rcB"
  wait

  [ "$(cat "$rcA" 2>/dev/null)" = 0 ] || fail "send to target A failed"
  [ "$(cat "$rcB" 2>/dev/null)" = 0 ] || fail "send to target B failed"
  [ -s "$overlap" ] || fail "distinct targets were serialized against each other (a single global lock, not per-target)"
  pass "fm-send's send lock is per-target: distinct targets do not contend"
}

test_concurrent_sends_to_one_target_do_not_interleave
test_lock_is_per_target_not_global
