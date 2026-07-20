#!/usr/bin/env bash
# Behavior tests for the Quartermaster companion (fm-ahoy.sh + fm-set-sail.sh).
#
# Both scripts run as real subprocesses against a fake FM_HOME/FM_ROOT built so
# the real scripts (symlinked in) resolve their siblings inside it. The herdr
# backend adapter is replaced by a STUB backends/herdr.sh that logs every call
# and lets the test control liveness, so these tests exercise the real
# fm-ahoy/fm-set-sail LOGIC (marker + charter write, collision refocus, route
# selection, plan handoff, teardown) without a live herdr/omp. fm-backend.sh
# sources the adapter lazily from its own dir, which is the fake bin, so the stub
# wins. fm-send and tasks-axi are stubbed too.
set -u

# Not sourced through tests/lib.sh; exempt the subprocesses from the gate refusal
# so the no-mistakes gate can run this suite from a gate worktree.
export FM_GATE_REFUSE_BYPASS=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AHOY="$ROOT/bin/fm-ahoy.sh"
SETSAIL="$ROOT/bin/fm-set-sail.sh"

fail() { printf 'FAIL - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

TMP_ROOT=
cleanup() { [ -z "$TMP_ROOT" ] || rm -rf "$TMP_ROOT"; }
trap cleanup EXIT
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-ahoy-tests.XXXXXX")
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)  # collapse any // from a trailing-slash TMPDIR so cwd asserts match

# Build a fake home whose real fm-ahoy/fm-set-sail resolve into it, with a stub
# herdr adapter + stub fm-send + a tasks-axi on PATH. All stubs log under $fake/log.
make_qm_root() {
  local id=$1
  local fake="$TMP_ROOT/$id"
  mkdir -p "$fake/bin/backends" "$fake/state" "$fake/pathbin" "$fake/log" "$fake/.agents/skills" "$fake/projects/demo"
  cp -R "$ROOT/.agents/skills/set-sail" "$fake/.agents/skills/set-sail"
  ln -s "$AHOY" "$fake/bin/fm-ahoy.sh"
  ln -s "$SETSAIL" "$fake/bin/fm-set-sail.sh"
  ln -s "$ROOT/bin/fm-backend.sh" "$fake/bin/fm-backend.sh"
  ln -s "$ROOT/bin/fm-supervisor-target-lib.sh" "$fake/bin/fm-supervisor-target-lib.sh"
  # Stub herdr adapter: log calls, controllable liveness via QM_ALIVE_FILE.
  cat > "$fake/bin/backends/herdr.sh" <<'SH'
# shellcheck shell=bash
fm_backend_herdr_agent_alive() { cat "${QM_ALIVE_FILE:-/dev/null}" 2>/dev/null || printf 'dead'; }
fm_backend_herdr_container_ensure() { printf '%s:%s\t%s' "${QM_SES:-default}" "${QM_WS:-ws1}" ""; }
fm_backend_herdr_create_task() { printf 'create_task %s\n' "$*" >>"$QM_LOG"; printf '%s %s' "${QM_TAB:-tab1}" "${QM_PANE:-p1}"; }
fm_backend_herdr_send_text_line() { printf 'send_text_line target=%s\n' "$1" >>"$QM_LOG"; printf '%s\n' "$2" >"$QM_LAUNCH"; }
fm_backend_herdr_cli() { printf 'cli %s\n' "$*" >>"$QM_LOG"; }
fm_backend_herdr_kill() { printf 'kill %s\n' "$1" >>"$QM_LOG"; }
SH
  # Stub fm-send (set-sail calls it by absolute path via its own SCRIPT_DIR).
  cat > "$fake/bin/fm-send.sh" <<'SH'
#!/usr/bin/env bash
printf 'fm-send %s\n' "$*" >>"$QM_SEND_LOG"
SH
  chmod +x "$fake/bin/fm-send.sh"
  # Stub tasks-axi on PATH: log its cwd (must be FM_HOME so .tasks.toml resolves) + args, emit a mintable id.
  cat > "$fake/pathbin/tasks-axi" <<'SH'
#!/usr/bin/env bash
printf 'tasks-axi cwd=%s args=%s\n' "$PWD" "$*" >>"$QM_TASKS_LOG"
printf '{"id":"qm-plan-t1"}\n'
SH
  chmod +x "$fake/pathbin/tasks-axi"
  printf '%s' "$fake"
}

# Run fm-ahoy in $fake with the stub env wired.
run_ahoy() {  # <fake> <captain-target>
  local fake=$1 captain=$2
  env -u TMUX -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID \
    FM_HOME="$fake" FM_BACKEND=herdr \
    FM_SUPERVISOR_TARGET="$captain" FM_SUPERVISOR_BACKEND=herdr \
    QM_LOG="$fake/log/calls" QM_LAUNCH="$fake/log/launch" \
    QM_ALIVE_FILE="$fake/log/alive" \
    bash "$fake/bin/fm-ahoy.sh" >/dev/null 2>&1
}

run_set_sail() {  # <fake> <args...>
  local fake=$1; shift
  env -u TMUX -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID \
    FM_HOME="$fake" FM_BACKEND=herdr \
    PATH="$fake/pathbin:$PATH" \
    QM_LOG="$fake/log/calls" QM_SEND_LOG="$fake/log/send" QM_TASKS_LOG="$fake/log/tasks" \
    bash "$fake/bin/fm-set-sail.sh" "$@"  >/dev/null 2>&1
}

test_ahoy_summons() {
  local fake; fake=$(make_qm_root ahoy-summon)
  env -u TMUX -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID \
    FM_HOME="$fake" FM_BACKEND=herdr FM_SUPERVISOR_TARGET="default:wA:p1" FM_SUPERVISOR_BACKEND=herdr \
    QM_LOG="$fake/log/calls" QM_LAUNCH="$fake/log/launch" QM_ALIVE_FILE="$fake/log/alive" \
    bash "$fake/bin/fm-ahoy.sh" >/dev/null 2>&1 || fail "fm-ahoy exited non-zero on a fresh summon"

  [ -f "$fake/state/.quartermaster" ] || fail "no marker written"
  grep -q '^window=default:p1$' "$fake/state/.quartermaster" || fail "marker window not recorded"
  grep -q '^captain=default:wA:p1$' "$fake/state/.quartermaster" || fail "marker did not record the captain pane"
  grep -q '^scratch=' "$fake/state/.quartermaster" || fail "marker did not record the scratch home"
  [ -f "$fake/state/quartermaster-home/AGENTS.md" ] || fail "companion charter not seeded"
  grep -q 'Quartermaster' "$fake/state/quartermaster-home/AGENTS.md" || fail "charter missing role"
  grep -q '/set-sail' "$fake/state/quartermaster-home/AGENTS.md" || fail "charter missing the /set-sail handoff"
  [ -f "$fake/state/quartermaster-home/.agents/skills/set-sail/SKILL.md" ] || fail "set-sail skill not seeded into the scratch home (so /set-sail would not be a command)"
  grep -q 'Reading the code' "$fake/state/quartermaster-home/AGENTS.md" || fail "charter missing the read-only project-code guidance"
  [ -L "$fake/state/quartermaster-home/projects" ] || fail "projects/ not symlinked into the scratch home (Quartermaster can't see project code)"
  [ -d "$fake/state/quartermaster-home/projects/demo" ] || fail "projects symlink does not resolve to the home's read-only project clones"
  grep -q 'create_task .*quartermaster' "$fake/log/calls" || fail "create_task not invoked for the quartermaster pane"
  grep -q 'cli default tab focus tab1' "$fake/log/calls" || fail "the new pane was not focused"
  grep -q 'omp' "$fake/log/launch" || fail "omp not launched in the pane"
  grep -q 'FM_QM_CAPTAIN=default:wA:p1' "$fake/log/launch" || fail "captain target not threaded into the launch env"
  pass "fm-ahoy summons the Quartermaster: marker, charter, launch, focus"
}

test_ahoy_refocuses_when_aboard() {
  local fake; fake=$(make_qm_root ahoy-collision)
  run_ahoy "$fake" "default:wA:p1" || fail "first summon failed"
  local first_creates; first_creates=$(grep -c '^create_task ' "$fake/log/calls")
  [ "$first_creates" = 1 ] || fail "expected exactly one create_task after first summon (got $first_creates)"
  # A live Quartermaster is aboard.
  printf 'alive' > "$fake/log/alive"
  local out
  out=$(env -u TMUX -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID \
    FM_HOME="$fake" FM_BACKEND=herdr \
    QM_LOG="$fake/log/calls" QM_LAUNCH="$fake/log/launch" QM_ALIVE_FILE="$fake/log/alive" \
    bash "$fake/bin/fm-ahoy.sh" 2>&1) || fail "second summon exited non-zero"
  printf '%s' "$out" | grep -q 'already aboard' || fail "second summon did not report already-aboard"
  local after_creates; after_creates=$(grep -c '^create_task ' "$fake/log/calls")
  [ "$after_creates" = 1 ] || fail "a second Quartermaster was spawned (create_task count $after_creates)"
  pass "fm-ahoy refocuses instead of spawning a second when one is aboard"
}

test_set_sail_hands_off_and_retires() {
  local fake; fake=$(make_qm_root setsail-both)
  run_ahoy "$fake" "default:wA:p1" || fail "summon failed"
  [ -d "$fake/state/quartermaster-home" ] || fail "scratch home missing after summon"
  run_set_sail "$fake" --to both --title "Add widget" --plan "Build the widget: steps A, B, C." \
    || fail "set-sail exited non-zero"
  # Handoff: backlog add + captain ping.
  grep -q 'args=add ' "$fake/log/tasks" || fail "tasks-axi add not invoked for the backlog route"
  grep -q "tasks-axi cwd=$fake " "$fake/log/tasks" || fail "tasks-axi not run from FM_HOME, so it would not resolve data/backlog.md via .tasks.toml"
  grep -q 'fm-send default:wA:p1' "$fake/log/send" || fail "captain not pinged for the captain route"
  grep -q 'queued=qm-plan-t1' "$fake/log/send" || fail "captain ping missing the minted backlog id"
  ls "$fake"/state/quartermaster-plan-*.md >/dev/null 2>&1 || fail "durable plan file not written"
  # Teardown.
  [ ! -f "$fake/state/.quartermaster" ] || fail "marker not removed on retire"
  [ ! -d "$fake/state/quartermaster-home" ] || fail "scratch home not removed on retire"
  grep -q '^kill default:p1$' "$fake/log/calls" || fail "the Quartermaster pane was not closed"
  pass "fm-set-sail hands off to captain + backlog and retires the pane"
}

test_set_sail_noop_without_marker() {
  local fake; fake=$(make_qm_root setsail-noop)
  run_set_sail "$fake" --to backlog --plan "x" || true
  [ ! -f "$fake/log/tasks" ] || fail "tasks-axi called with no Quartermaster aboard"
  [ ! -f "$fake/log/calls" ] || fail "backend called with no Quartermaster aboard"
  pass "fm-set-sail is a clean no-op when no Quartermaster is aboard"
}

test_set_sail_empty_plan_retires_without_handoff() {
  local fake; fake=$(make_qm_root setsail-empty)
  run_ahoy "$fake" "default:wA:p1" || fail "summon failed"
  env -u TMUX -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID \
    FM_HOME="$fake" FM_BACKEND=herdr PATH="$fake/pathbin:$PATH" \
    QM_LOG="$fake/log/calls" QM_SEND_LOG="$fake/log/send" QM_TASKS_LOG="$fake/log/tasks" \
    bash "$fake/bin/fm-set-sail.sh" --to backlog </dev/null >/dev/null 2>&1 \
    || fail "empty-plan set-sail exited non-zero"
  [ ! -f "$fake/log/tasks" ] || fail "empty plan should not hit tasks-axi"
  [ ! -f "$fake/state/.quartermaster" ] || fail "empty-plan set-sail did not retire the marker"
  grep -q '^kill default:p1$' "$fake/log/calls" || fail "empty-plan set-sail did not close the pane"
  pass "fm-set-sail with no plan retires cleanly without a handoff"
}

test_set_sail_backlog_route_pings_captain() {
  # A backlog ("do it later") route must still ping the captain a one-line
  # pointer when a captain pane is recorded - a filed plan the captain never
  # hears about strands the work (observed 2026-07-20: backlog set-sail landed
  # the task but pinged nothing, so the captain re-created it by hand).
  local fake; fake=$(make_qm_root setsail-backlog)
  run_ahoy "$fake" "default:wA:p1" || fail "summon failed"
  run_set_sail "$fake" --to backlog --title "Later widget" --plan "Build the widget later: A, B, C." \
    || fail "backlog set-sail exited non-zero"
  grep -q 'args=add ' "$fake/log/tasks" || fail "tasks-axi add not invoked for the backlog route"
  [ -f "$fake/log/send" ] || fail "captain not pinged on the backlog route (no fm-send at all)"
  grep -q 'fm-send default:wA:p1' "$fake/log/send" || fail "captain not pinged on the backlog route"
  grep -q 'filed to backlog' "$fake/log/send" || fail "backlog ping did not use the 'do it later' pointer wording"
  grep -q 'queued=qm-plan-t1' "$fake/log/send" || fail "backlog ping missing the minted backlog id"
  pass "fm-set-sail pings the captain a pointer even on a backlog route"
}

test_ahoy_summons
test_ahoy_refocuses_when_aboard
test_set_sail_hands_off_and_retires
test_set_sail_noop_without_marker
test_set_sail_empty_plan_retires_without_handoff
test_set_sail_backlog_route_pings_captain
