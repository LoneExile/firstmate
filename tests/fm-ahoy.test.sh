#!/usr/bin/env bash
# Behavior tests for the Quartermaster companion (fm-ahoy.sh + fm-set-sail.sh).
#
# Both scripts run as real subprocesses against a fake FM_HOME/FM_ROOT built so
# the real scripts (symlinked in) resolve their siblings inside it. The herdr
# backend adapter is replaced by a STUB backends/herdr.sh that logs every call
# and lets the test control liveness, so these tests exercise the real
# fm-ahoy/fm-set-sail LOGIC (per-label marker + charter write, refocus, reap,
# auto-label, soft cap, route selection, plan handoff, teardown) without a live
# herdr/omp. fm-backend.sh sources the adapter lazily from its own dir, which is
# the fake bin, so the stub wins. fm-send and tasks-axi are stubbed too.
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
  # fm-ahoy sources fm-wake-lib.sh for the portable spawn-claim mutex.
  ln -s "$ROOT/bin/fm-wake-lib.sh" "$fake/bin/fm-wake-lib.sh"
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

# Run fm-ahoy in $fake with the stub env wired. Optional 3rd arg = label.
run_ahoy() {  # <fake> <captain-target> [label]
  local fake=$1 captain=$2 label=${3:-}
  env -u TMUX -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID \
    FM_HOME="$fake" FM_BACKEND=herdr \
    FM_SUPERVISOR_TARGET="$captain" FM_SUPERVISOR_BACKEND=herdr \
    QM_LOG="$fake/log/calls" QM_LAUNCH="$fake/log/launch" \
    QM_ALIVE_FILE="$fake/log/alive" \
    bash "$fake/bin/fm-ahoy.sh" ${label:+"$label"} >/dev/null 2>&1
}

# Run fm-set-sail for a given instance <label>, threading FM_QM_MARKER exactly as
# fm-ahoy injects it into the Quartermaster at launch.
run_set_sail() {  # <fake> <label> <args...>
  local fake=$1 label=$2; shift 2
  env -u TMUX -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID \
    FM_HOME="$fake" FM_BACKEND=herdr \
    FM_QM_MARKER="$fake/state/.quartermaster-$label" \
    PATH="$fake/pathbin:$PATH" \
    QM_LOG="$fake/log/calls" QM_SEND_LOG="$fake/log/send" QM_TASKS_LOG="$fake/log/tasks" \
    bash "$fake/bin/fm-set-sail.sh" "$@" >/dev/null 2>&1
}

test_ahoy_summons() {
  local fake; fake=$(make_qm_root ahoy-summon)
  run_ahoy "$fake" "default:wA:p1" planning || fail "fm-ahoy exited non-zero on a fresh labelled summon"

  local m="$fake/state/.quartermaster-planning"
  [ -f "$m" ] || fail "no per-label marker written"
  grep -q '^label=planning$' "$m" || fail "marker did not record its label"
  grep -q '^window=default:p1$' "$m" || fail "marker window not recorded"
  grep -q '^captain=default:wA:p1$' "$m" || fail "marker did not record the captain pane"
  grep -q '^scratch=' "$m" || fail "marker did not record the scratch home"
  [ -f "$fake/state/quartermaster-home-planning/AGENTS.md" ] || fail "companion charter not seeded into the per-label scratch home"
  grep -q 'Quartermaster' "$fake/state/quartermaster-home-planning/AGENTS.md" || fail "charter missing role"
  grep -q '/set-sail' "$fake/state/quartermaster-home-planning/AGENTS.md" || fail "charter missing the /set-sail handoff"
  [ -f "$fake/state/quartermaster-home-planning/.agents/skills/set-sail/SKILL.md" ] || fail "set-sail skill not seeded into the scratch home (so /set-sail would not be a command)"
  grep -q 'Reading the code' "$fake/state/quartermaster-home-planning/AGENTS.md" || fail "charter missing the read-only project-code guidance"
  [ -L "$fake/state/quartermaster-home-planning/projects" ] || fail "projects/ not symlinked into the scratch home (Quartermaster can't see project code)"
  [ -d "$fake/state/quartermaster-home-planning/projects/demo" ] || fail "projects symlink does not resolve to the home's read-only project clones"
  grep -q 'create_task .*quartermaster' "$fake/log/calls" || fail "create_task not invoked for the quartermaster pane"
  grep -q 'cli default tab focus tab1' "$fake/log/calls" || fail "the new pane was not focused"
  grep -q 'omp' "$fake/log/launch" || fail "omp not launched in the pane"
  grep -q 'FM_QM_CAPTAIN=default:wA:p1' "$fake/log/launch" || fail "captain target not threaded into the launch env"
  grep -q 'FM_QM_LABEL=planning' "$fake/log/launch" || fail "label not threaded into the launch env"
  grep -q 'FM_QM_MARKER=.*\.quartermaster-planning' "$fake/log/launch" || fail "per-label marker not threaded into the launch env (set-sail could not target this instance)"
  # No claim lock should be left behind.
  [ ! -d "$m.lock" ] || fail "spawn claim lock was not released"
  pass "fm-ahoy summons a labelled Quartermaster: per-label marker, charter, launch env, focus"
}

test_ahoy_refocuses_same_label() {
  local fake; fake=$(make_qm_root ahoy-refocus)
  printf 'alive' > "$fake/log/alive"
  run_ahoy "$fake" "default:wA:p1" planning || fail "first summon failed"
  local first; first=$(grep -c '^create_task ' "$fake/log/calls")
  [ "$first" = 1 ] || fail "expected one create_task after first summon (got $first)"
  local out
  out=$(env -u TMUX -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID \
    FM_HOME="$fake" FM_BACKEND=herdr \
    QM_LOG="$fake/log/calls" QM_LAUNCH="$fake/log/launch" QM_ALIVE_FILE="$fake/log/alive" \
    bash "$fake/bin/fm-ahoy.sh" planning 2>&1) || fail "second summon of the same label exited non-zero"
  printf '%s' "$out" | grep -q "'planning' is already aboard" || fail "second summon of a live label did not refocus"
  local after; after=$(grep -c '^create_task ' "$fake/log/calls")
  [ "$after" = 1 ] || fail "a duplicate was spawned for the same live label (create_task count $after)"
  pass "fm-ahoy refocuses instead of duplicating when the SAME label is aboard"
}

test_ahoy_bare_autolabels() {
  local fake; fake=$(make_qm_root ahoy-autolabel)
  printf 'alive' > "$fake/log/alive"
  run_ahoy "$fake" "default:wA:p1" || fail "first bare summon failed"
  run_ahoy "$fake" "default:wA:p1" || fail "second bare summon failed"
  [ -f "$fake/state/.quartermaster-qm-1" ] || fail "first bare summon did not auto-label qm-1"
  [ -f "$fake/state/.quartermaster-qm-2" ] || fail "second bare summon did not auto-label a fresh qm-2 (it refocused instead of opening a parallel thread)"
  local creates; creates=$(grep -c '^create_task ' "$fake/log/calls")
  [ "$creates" = 2 ] || fail "bare summons did not each spawn a fresh instance (create_task count $creates)"
  pass "fm-ahoy auto-labels a fresh instance (qm-1, qm-2) on every bare summon"
}

test_ahoy_two_labels_coexist_without_wiping() {
  local fake; fake=$(make_qm_root ahoy-coexist)
  printf 'alive' > "$fake/log/alive"
  run_ahoy "$fake" "default:wA:p1" alpha || fail "summon alpha failed"
  # A sentinel proves alpha's scratch home survives a sibling spawn.
  printf 'ALPHA-CONTEXT' > "$fake/state/quartermaster-home-alpha/notes.txt"
  run_ahoy "$fake" "default:wA:p1" beta || fail "summon beta failed"
  [ -f "$fake/state/.quartermaster-alpha" ] || fail "alpha marker vanished when beta was summoned"
  [ -f "$fake/state/.quartermaster-beta" ] || fail "beta marker not written"
  [ -d "$fake/state/quartermaster-home-alpha" ] || fail "alpha scratch home wiped by the beta spawn"
  grep -q 'ALPHA-CONTEXT' "$fake/state/quartermaster-home-alpha/notes.txt" 2>/dev/null || fail "alpha's scratch contents were destroyed by the beta spawn (shared-scratch wipe bug)"
  pass "fm-ahoy runs two labelled instances side by side without wiping a sibling's scratch"
}

test_ahoy_reaps_dead_on_summon() {
  local fake; fake=$(make_qm_root ahoy-reap)
  # alive file absent -> stub reports 'dead' for every window.
  run_ahoy "$fake" "default:wA:p1" alpha || fail "summon alpha failed"
  [ -f "$fake/state/.quartermaster-alpha" ] || fail "alpha marker not written"
  [ -d "$fake/state/quartermaster-home-alpha" ] || fail "alpha scratch not created"
  run_ahoy "$fake" "default:wA:p1" beta || fail "summon beta failed"
  [ ! -f "$fake/state/.quartermaster-alpha" ] || fail "dead alpha instance was not reaped on the next summon"
  [ ! -d "$fake/state/quartermaster-home-alpha" ] || fail "dead alpha scratch home was not reaped"
  [ -f "$fake/state/.quartermaster-beta" ] || fail "beta was not spawned"
  pass "fm-ahoy reaps a confidently-dead instance (marker + scratch) on the next summon"
}

test_ahoy_list_shows_roster() {
  local fake; fake=$(make_qm_root ahoy-list)
  printf 'alive' > "$fake/log/alive"
  run_ahoy "$fake" "default:wA:p1" alpha || fail "summon alpha failed"
  run_ahoy "$fake" "default:wA:p1" beta || fail "summon beta failed"
  local out
  out=$(env -u TMUX -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID \
    FM_HOME="$fake" FM_BACKEND=herdr QM_ALIVE_FILE="$fake/log/alive" \
    bash "$fake/bin/fm-ahoy.sh" --list 2>&1) || fail "--list exited non-zero"
  printf '%s' "$out" | grep -q 'LABEL' || fail "--list did not print a roster header"
  printf '%s' "$out" | grep -q 'alpha' || fail "--list did not list alpha"
  printf '%s' "$out" | grep -q 'beta' || fail "--list did not list beta"
  pass "fm-ahoy --list prints the roster of instances aboard"
}

test_ahoy_reap_flag_retires_instance() {
  local fake; fake=$(make_qm_root ahoy-reapflag)
  printf 'alive' > "$fake/log/alive"
  run_ahoy "$fake" "default:wA:p1" alpha || fail "summon alpha failed"
  env -u TMUX -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID \
    FM_HOME="$fake" FM_BACKEND=herdr \
    QM_LOG="$fake/log/calls" QM_ALIVE_FILE="$fake/log/alive" \
    bash "$fake/bin/fm-ahoy.sh" --reap alpha >/dev/null 2>&1 || fail "--reap exited non-zero"
  [ ! -f "$fake/state/.quartermaster-alpha" ] || fail "--reap did not remove the marker"
  [ ! -d "$fake/state/quartermaster-home-alpha" ] || fail "--reap did not remove the scratch home"
  grep -q '^kill default:p1$' "$fake/log/calls" || fail "--reap did not kill the pane"
  pass "fm-ahoy --reap <label> force-retires a specific instance"
}

test_ahoy_rejects_bad_label() {
  local fake; fake=$(make_qm_root ahoy-badlabel)
  local rc=0
  env -u TMUX -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID \
    FM_HOME="$fake" FM_BACKEND=herdr \
    FM_SUPERVISOR_TARGET="default:wA:p1" FM_SUPERVISOR_BACKEND=herdr \
    QM_LOG="$fake/log/calls" QM_LAUNCH="$fake/log/launch" QM_ALIVE_FILE="$fake/log/alive" \
    bash "$fake/bin/fm-ahoy.sh" "../evil" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || fail "a traversal label was not rejected with exit 2 (got $rc)"
  [ ! -e "$fake/state/.quartermaster-../evil" ] || fail "a traversal label produced a marker outside the label namespace"
  [ ! -f "$fake/log/calls" ] || fail "a rejected label still created a pane"
  pass "fm-ahoy rejects a path-traversal label without spawning"
}

test_ahoy_warns_past_three_live() {
  local fake; fake=$(make_qm_root ahoy-cap)
  printf 'alive' > "$fake/log/alive"
  run_ahoy "$fake" "default:wA:p1" || fail "summon 1 failed"
  run_ahoy "$fake" "default:wA:p1" || fail "summon 2 failed"
  run_ahoy "$fake" "default:wA:p1" || fail "summon 3 failed"
  local out
  out=$(env -u TMUX -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID \
    FM_HOME="$fake" FM_BACKEND=herdr \
    FM_SUPERVISOR_TARGET="default:wA:p1" FM_SUPERVISOR_BACKEND=herdr \
    QM_LOG="$fake/log/calls" QM_LAUNCH="$fake/log/launch" QM_ALIVE_FILE="$fake/log/alive" \
    bash "$fake/bin/fm-ahoy.sh" 2>&1) || fail "fourth summon exited non-zero"
  printf '%s' "$out" | grep -q '3 Quartermasters already aboard' || fail "no soft-cap warning past three live instances"
  [ -f "$fake/state/.quartermaster-qm-4" ] || fail "the fourth instance was not spawned (soft cap must warn, not block)"
  pass "fm-ahoy warns past three live instances but still spawns (soft cap)"
}

test_set_sail_hands_off_and_retires() {
  local fake; fake=$(make_qm_root setsail-both)
  run_ahoy "$fake" "default:wA:p1" plan || fail "summon failed"
  [ -d "$fake/state/quartermaster-home-plan" ] || fail "scratch home missing after summon"
  run_set_sail "$fake" plan --to both --title "Add widget" --plan "Build the widget: steps A, B, C." \
    || fail "set-sail exited non-zero"
  grep -q 'args=add ' "$fake/log/tasks" || fail "tasks-axi add not invoked for the backlog route"
  grep -q "tasks-axi cwd=$fake " "$fake/log/tasks" || fail "tasks-axi not run from FM_HOME, so it would not resolve data/backlog.md via .tasks.toml"
  grep -q 'fm-send default:wA:p1' "$fake/log/send" || fail "captain not pinged for the captain route"
  grep -q 'queued=qm-plan-t1' "$fake/log/send" || fail "captain ping missing the minted backlog id"
  grep -q 'qm=plan' "$fake/log/send" || fail "captain ping missing the instance label (captain can't tell handoffs apart)"
  ls "$fake"/state/quartermaster-plan-plan-*.md >/dev/null 2>&1 || fail "durable plan file not written with the label in its name"
  [ ! -f "$fake/state/.quartermaster-plan" ] || fail "marker not removed on retire"
  [ ! -d "$fake/state/quartermaster-home-plan" ] || fail "scratch home not removed on retire"
  grep -q '^kill default:p1$' "$fake/log/calls" || fail "the Quartermaster pane was not closed"
  pass "fm-set-sail hands off to captain + backlog (label-tagged) and retires the pane"
}

test_set_sail_plan_filename_is_unique() {
  local fake; fake=$(make_qm_root setsail-unique)
  run_ahoy "$fake" "default:wA:p1" uniq || fail "summon failed"
  run_set_sail "$fake" uniq --to backlog --title "T" --plan "P" || fail "set-sail exited non-zero"
  local f=""; local g; for g in "$fake"/state/quartermaster-plan-uniq-*.md; do [ -e "$g" ] && { f=$g; break; }; done
  [ -n "$f" ] || fail "labelled plan file not written"
  # Name carries the label AND a trailing pid, so two same-second handoffs never collide.
  case "${f##*/}" in
    quartermaster-plan-uniq-*-[0-9]*.md) : ;;
    *) fail "plan filename lacks the label-...-pid uniquifier: ${f##*/}" ;;
  esac
  pass "fm-set-sail plan filename carries the label and a pid uniquifier"
}

test_set_sail_noop_without_marker() {
  local fake; fake=$(make_qm_root setsail-noop)
  run_set_sail "$fake" ghost --to backlog --plan "x" || true
  [ ! -f "$fake/log/tasks" ] || fail "tasks-axi called with no Quartermaster aboard"
  [ ! -f "$fake/log/calls" ] || fail "backend called with no Quartermaster aboard"
  pass "fm-set-sail is a clean no-op when the addressed instance is not aboard"
}

test_set_sail_empty_plan_retires_without_handoff() {
  local fake; fake=$(make_qm_root setsail-empty)
  run_ahoy "$fake" "default:wA:p1" plan || fail "summon failed"
  env -u TMUX -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID \
    FM_HOME="$fake" FM_BACKEND=herdr PATH="$fake/pathbin:$PATH" \
    FM_QM_MARKER="$fake/state/.quartermaster-plan" \
    QM_LOG="$fake/log/calls" QM_SEND_LOG="$fake/log/send" QM_TASKS_LOG="$fake/log/tasks" \
    bash "$fake/bin/fm-set-sail.sh" --to backlog </dev/null >/dev/null 2>&1 \
    || fail "empty-plan set-sail exited non-zero"
  [ ! -f "$fake/log/tasks" ] || fail "empty plan should not hit tasks-axi"
  [ ! -f "$fake/state/.quartermaster-plan" ] || fail "empty-plan set-sail did not retire the marker"
  grep -q '^kill default:p1$' "$fake/log/calls" || fail "empty-plan set-sail did not close the pane"
  pass "fm-set-sail with no plan retires cleanly without a handoff"
}

test_set_sail_backlog_route_pings_captain() {
  # A backlog ("do it later") route must still ping the captain a one-line
  # pointer when a captain pane is recorded - a filed plan the captain never
  # hears about strands the work (observed 2026-07-20: backlog set-sail landed
  # the task but pinged nothing, so the captain re-created it by hand).
  local fake; fake=$(make_qm_root setsail-backlog)
  run_ahoy "$fake" "default:wA:p1" plan || fail "summon failed"
  run_set_sail "$fake" plan --to backlog --title "Later widget" --plan "Build the widget later: A, B, C." \
    || fail "backlog set-sail exited non-zero"
  grep -q 'args=add ' "$fake/log/tasks" || fail "tasks-axi add not invoked for the backlog route"
  [ -f "$fake/log/send" ] || fail "captain not pinged on the backlog route (no fm-send at all)"
  grep -q 'fm-send default:wA:p1' "$fake/log/send" || fail "captain not pinged on the backlog route"
  grep -q 'filed to backlog' "$fake/log/send" || fail "backlog ping did not use the 'do it later' pointer wording"
  grep -q 'queued=qm-plan-t1' "$fake/log/send" || fail "backlog ping missing the minted backlog id"
  pass "fm-set-sail pings the captain a pointer even on a backlog route"
}

test_set_sail_rejects_bad_label() {
  local fake; fake=$(make_qm_root setsail-badlabel)
  local rc=0
  # No FM_QM_MARKER, so the --label branch (which builds the marker path) runs.
  env -u TMUX -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID \
    FM_HOME="$fake" FM_BACKEND=herdr PATH="$fake/pathbin:$PATH" \
    QM_LOG="$fake/log/calls" QM_SEND_LOG="$fake/log/send" QM_TASKS_LOG="$fake/log/tasks" \
    bash "$fake/bin/fm-set-sail.sh" --label "../../etc/x" --to backlog --plan "p" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || fail "set-sail did not reject a traversal --label with exit 2 (got $rc)"
  [ ! -f "$fake/log/tasks" ] || fail "a rejected --label still hit tasks-axi"
  pass "fm-set-sail rejects a path-traversal --label"
}

test_ahoy_declines_same_label_while_claim_held() {
  local fake; fake=$(make_qm_root ahoy-claim)
  printf 'alive' > "$fake/log/alive"
  # Simulate a concurrent summon mid-claim: a fresh claim lock for this label.
  # FM_LOCK_STALE_AFTER large keeps it "held" regardless of host load, so the
  # decline is deterministic (no background process, no timing race).
  mkdir -p "$fake/state/.quartermaster-held.lock"
  local out rc=0
  out=$(env -u TMUX -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID \
    FM_HOME="$fake" FM_BACKEND=herdr FM_LOCK_STALE_AFTER=3600 \
    FM_SUPERVISOR_TARGET="default:wA:p1" FM_SUPERVISOR_BACKEND=herdr \
    QM_LOG="$fake/log/calls" QM_LAUNCH="$fake/log/launch" QM_ALIVE_FILE="$fake/log/alive" \
    bash "$fake/bin/fm-ahoy.sh" held 2>&1) || rc=$?
  [ "$rc" = 0 ] || fail "ahoy should exit 0 (clean decline) when the same-label claim is held (got $rc)"
  printf '%s' "$out" | grep -q "another summon for 'held' is in progress" || fail "ahoy did not decline while the same-label claim was held"
  [ ! -f "$fake/log/calls" ] || fail "ahoy created a pane despite a held same-label claim (duplicate spawn)"
  [ ! -f "$fake/state/.quartermaster-held" ] || fail "ahoy wrote a duplicate marker despite a held claim"
  [ ! -d "$fake/state/quartermaster-home-held" ] || fail "ahoy built a scratch home despite a held claim"
  pass "fm-ahoy declines a duplicate same-label summon while a claim is in progress"
}

test_ahoy_summons
test_ahoy_refocuses_same_label
test_ahoy_bare_autolabels
test_ahoy_two_labels_coexist_without_wiping
test_ahoy_reaps_dead_on_summon
test_ahoy_list_shows_roster
test_ahoy_reap_flag_retires_instance
test_ahoy_rejects_bad_label
test_ahoy_warns_past_three_live
test_ahoy_declines_same_label_while_claim_held
test_set_sail_hands_off_and_retires
test_set_sail_plan_filename_is_unique
test_set_sail_noop_without_marker
test_set_sail_empty_plan_retires_without_handoff
test_set_sail_backlog_route_pings_captain
test_set_sail_rejects_bad_label
