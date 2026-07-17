#!/usr/bin/env bash
# Tests for the secondmate-vs-crewmate harness split, the optional model/effort
# tokens config/secondmate-harness carries alongside the harness, and the
# primary->secondmate inherited local-material propagation.
#
# Three capabilities are under test:
#   A) Harness split. config/secondmate-harness sets the harness the PRIMARY uses
#      to launch SECONDMATE agents, independent of config/crew-harness (the
#      crewmate harness). fm-harness.sh secondmate resolves the fallback chain
#      config/secondmate-harness -> config/crew-harness -> own; an absent or
#      "default" secondmate-harness behaves exactly as the crew harness did before
#      this knob existed (full backward-compat). fm-spawn.sh resolves a secondmate
#      launch through that mode, durably (every respawn re-resolves), while an
#      explicit per-spawn harness arg still wins.
#   B) Inheritance. The primary pushes a declared, extensible set of LOCAL
#      (gitignored) config items - config/crew-dispatch.json, config/crew-harness,
#      and config/backlog-backend - down into each secondmate home's config/, so
#      the secondmate's OWN crewmates, dispatch profiles, and backlog backend
#      inherit the primary's settings. It is primary-authoritative (re-pushed at
#      secondmate spawn, on the bootstrap secondmate sweep, and by config push).
#      config/secondmate-harness is deliberately NOT inherited (secondmates do
#      not spawn secondmates).
#   C) Model/effort pin. config/secondmate-harness may carry optional model and
#      effort tokens after the harness ("<harness> [<model>] [<effort>]"), read by
#      fm-harness.sh secondmate-model / secondmate-effort. A bare harness-only
#      line (today's format) yields empty model/effort - full backward-compat.
#      fm-spawn.sh populates MODEL/EFFORT from those tokens for a --secondmate
#      spawn only when the harness also resolves from that file, so the pin is
#      durable across every respawn while explicit per-spawn harness/model/effort
#      flags still win.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-ff-lib.sh
. "$ROOT/bin/fm-ff-lib.sh"
# shellcheck source=bin/fm-config-inherit-lib.sh
. "$ROOT/bin/fm-config-inherit-lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
fm_git_identity fmtest fmtest@example.com
TMP_ROOT=$(fm_test_tmproot fm-secondmate-harness)
export FM_BACKEND=tmux

# Drop ambient harness markers: fm-harness.sh no longer checks env markers
# (it always returns omp), but dropping them keeps the test surface clean and
# prevents an interactive omp session from leaking OMPCODE into child shells.
unset OMPCODE CLAUDECODE

# ===========================================================================
# A) fm-harness.sh always returns omp for own/crew/secondmate
# ===========================================================================
# The harness is constant; config/crew-harness and config/secondmate-harness are
# vestigial for harness selection (they only parametrize model/effort tokens now).
# Each row sets or omits those files and asserts that both secondmate and crew
# still resolve to omp regardless.
#   <label>^<crew-harness>^<secondmate-harness>
test_harness_resolution() {
  local label crew sm case_dir cfg got_sm got_crew n
  n=0
  while IFS='^' read -r label crew sm; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    case_dir="$TMP_ROOT/harness-$n"
    cfg="$case_dir/config"
    mkdir -p "$cfg"
    [ "$crew" = "-" ] || printf '%s\n' "$crew" > "$cfg/crew-harness"
    [ "$sm" = "-" ] || printf '%s\n' "$sm" > "$cfg/secondmate-harness"
    got_sm=$(FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh" secondmate)
    got_crew=$(FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh" crew)
    [ "$got_sm" = omp ] || fail "$label: secondmate resolved '$got_sm', expected omp"
    [ "$got_crew" = omp ] || fail "$label: crew resolved '$got_crew', expected omp"
  done <<'ROWS'
both config files absent -> omp^-^-
crew set, secondmate absent -> omp^codex^-
crew set, secondmate set -> still omp^codex^grok
crew absent, secondmate set -> omp^-^grok
secondmate=default -> omp^codex^default
crew=default -> omp^default^-
secondmate=default with crew absent -> omp^-^default
ROWS
  pass "A1 fm-harness.sh always returns omp for secondmate and crew regardless of config files"
}

# ===========================================================================
# C) fm-harness.sh secondmate-model / secondmate-effort token resolution
# ===========================================================================
# config/secondmate-harness holds "<harness> [<model>] [<effort>]" on one line.
# A bare harness (today's format) must yield empty model/effort - the
# backward-compat requirement. The file-line field uses \n for an embedded
# newline (expanded via printf '%b') so a row can express a multi-line file; the
# literal token ABSENT skips creating the file entirely.
#   <label>^<file-line-or-ABSENT>^<expect-harness>^<expect-model>^<expect-effort>
test_secondmate_model_effort_tokens() {
  local label line exp_harness exp_model exp_effort case_dir cfg got_h got_m got_e n
  n=0
  while IFS='^' read -r label line exp_harness exp_model exp_effort; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    case_dir="$TMP_ROOT/tokens-$n"
    cfg="$case_dir/config"
    mkdir -p "$cfg"
    [ "$line" = ABSENT ] || printf '%b\n' "$line" > "$cfg/secondmate-harness"
    got_h=$(FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh" secondmate)
    got_m=$(FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh" secondmate-model)
    got_e=$(FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh" secondmate-effort)
    [ "$got_h" = "$exp_harness" ] || fail "$label: harness resolved '$got_h', expected '$exp_harness'"
    [ "$got_m" = "$exp_model" ] || fail "$label: model resolved '$got_m', expected '$exp_model'"
    [ "$got_e" = "$exp_effort" ] || fail "$label: effort resolved '$got_e', expected '$exp_effort'"
  done <<'ROWS'
absent file -> omp, empty model/effort^ABSENT^omp^^
bare harness only -> empty model/effort (backward-compat)^claude^omp^^
harness + model -> model only^claude opus^omp^opus^
harness + model + effort -> both^claude opus high^omp^opus^high
default harness token -> falls back to own, empty model/effort^default^omp^^
extra whitespace between tokens is tolerated^grok   grok-4    xhigh^omp^grok-4^xhigh
leading/trailing blank lines and a comment are skipped^# a comment\n\nclaude opus low\n^omp^opus^low
ROWS
  pass "C1 fm-harness.sh secondmate-model/secondmate-effort resolve the optional tokens; bare harness stays empty (backward-compat)"
}

# ===========================================================================
# B) propagate_inheritable_config unit behavior
# ===========================================================================
test_propagate_lib() {
  local d src dest m1 m2 outside stdout stderr guard_repo err_text
  d="$TMP_ROOT/prop-lib"
  src="$d/src"
  dest="$d/dest"
  mkdir -p "$src" "$dest"

  # 1. present source is copied
  printf 'manual\n' > "$src/backlog-backend"
  stdout="$d/clean-copy.out"
  stderr="$d/clean-copy.err"
  propagate_inheritable_config "$src" "$dest" >"$stdout" 2>"$stderr" || fail "propagate returned non-zero"
  [ ! -s "$stdout" ] || fail "clean copy wrote to stdout"
  [ ! -s "$stderr" ] || fail "clean copy wrote to stderr"
  [ "$(cat "$dest/backlog-backend")" = manual ] || fail "backlog-backend not propagated"

  # 2. idempotent: an unchanged re-run does not churn the mtime
  m1=$(date -r "$dest/backlog-backend" +%s 2>/dev/null || stat -c %Y "$dest/backlog-backend")
  sleep 1
  stdout="$d/unchanged.out"
  stderr="$d/unchanged.err"
  propagate_inheritable_config "$src" "$dest" >"$stdout" 2>"$stderr"
  [ ! -s "$stdout" ] || fail "unchanged propagation wrote to stdout"
  [ ! -s "$stderr" ] || fail "unchanged propagation wrote to stderr"
  m2=$(date -r "$dest/backlog-backend" +%s 2>/dev/null || stat -c %Y "$dest/backlog-backend")
  [ "$m1" = "$m2" ] || fail "idempotent re-run churned mtime ($m1 -> $m2)"

  # 3. a changed source value converges downstream
  printf 'tasks-axi\n' > "$src/backlog-backend"
  propagate_inheritable_config "$src" "$dest"
  [ "$(cat "$dest/backlog-backend")" = tasks-axi ] || fail "changed backlog backend did not converge"

  outside="$d/outside-target"
  rm -f "$dest/backlog-backend" "$outside"
  printf 'outside\n' > "$outside"
  ln -s "$outside" "$dest/backlog-backend"
  printf 'manual\n' > "$src/backlog-backend"
  propagate_inheritable_config "$src" "$dest"
  [ ! -L "$dest/backlog-backend" ] || fail "destination symlink was not replaced"
  [ "$(cat "$dest/backlog-backend")" = manual ] || fail "destination symlink replacement has wrong content"
  [ "$(cat "$outside")" = outside ] || fail "destination symlink target was overwritten"

  # 4. removing the source mirrors absence downstream (primary-authoritative)
  rm -f "$src/backlog-backend"
  propagate_inheritable_config "$src" "$dest"
  [ -e "$dest/backlog-backend" ] && fail "backlog-backend absence not mirrored downstream"

  rm -f "$dest/backlog-backend"
  ln -s "$d/missing-target" "$dest/backlog-backend"
  propagate_inheritable_config "$src" "$dest"
  [ -L "$dest/backlog-backend" ] && fail "broken destination symlink not removed on absence mirror"

  mkdir -p "$dest/backlog-backend"
  stderr="$d/remove-error.err"
  if propagate_inheritable_config "$src" "$dest" 2>"$stderr"; then
    fail "failed absence mirror returned success"
  fi
  assert_contains "$(cat "$stderr")" "fm-config-inherit: error: failed to remove backlog-backend" \
    "remove error did not emit a stderr diagnostic"
  [ -d "$dest/backlog-backend" ] || fail "failed absence mirror removed the wrong path"
  rm -rf "$dest/backlog-backend"

  # 5. secondmate-harness is never inherited (not in the inheritable set)
  printf 'omp opus\n' > "$src/secondmate-harness"
  printf 'manual\n' > "$src/backlog-backend"
  rm -rf "$d/dest2"
  mkdir -p "$d/dest2"
  propagate_inheritable_config "$src" "$d/dest2"
  [ -e "$d/dest2/secondmate-harness" ] && fail "secondmate-harness was inherited (must not be)"
  [ "$(cat "$d/dest2/backlog-backend")" = manual ] || fail "backlog-backend not propagated alongside"

  # 6. nothing to propagate -> destination dir is never created (a true no-op)
  rm -rf "$d/src3" "$d/dest3"
  mkdir -p "$d/src3"
  propagate_inheritable_config "$d/src3" "$d/dest3/config"
  [ -e "$d/dest3/config" ] && fail "empty-source propagation created a destination dir"

  # 7. a git worktree that does not ignore an inherited item gets a visible
  # stderr warning and a skip, not a silent miss.
  guard_repo="$d/guard-repo"
  git init -q -b main "$guard_repo"
  printf 'config/crew-harness\n' > "$guard_repo/.gitignore"
  printf 'guard\n' > "$guard_repo/README.md"
  git -C "$guard_repo" add -A
  git -C "$guard_repo" commit -qm guard
  printf 'tasks-axi\n' > "$src/backlog-backend"
  stdout="$d/guard-skip.out"
  stderr="$d/guard-skip.err"
  FM_INHERITABLE_CONFIG=backlog-backend propagate_inheritable_config "$src" "$guard_repo/config" >"$stdout" 2>"$stderr" \
    || fail "guard skip should not make propagation fail"
  [ ! -s "$stdout" ] || fail "guard skip wrote to stdout"
  err_text=$(cat "$stderr")
  assert_contains "$err_text" "fm-config-inherit: warning: skipped backlog-backend" \
    "guard skip did not emit a stderr warning"
  [ ! -e "$guard_repo/config/backlog-backend" ] || fail "guard skip still copied the unignored item"

  pass "B1 propagate_inheritable_config: copy, idempotence, convergence, absence-mirror, exclusion, no-op, skip diagnostics"
}

# ===========================================================================
# B/A integration: a secondmate spawn resolves the secondmate harness and
# propagates the crew harness into the home's config.
# ===========================================================================

# A tmux stub that accepts every subcommand and prints nothing, so no window
# pre-exists and the spawn proceeds to write its meta. Echoes the fakebin dir.
make_noop_tmux() {
  local dir=$1 fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

# A minimal seeded secondmate home (validate_firstmate_home_for_spawn needs the
# seed marker, AGENTS.md, bin/, and a charter to launch). config/ is intentionally
# left absent so the spawn's propagation is what creates it.
make_seeded_home() {
  local home=$1 id=$2
  mkdir -p "$home/bin" "$home/data"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf 'charter\n' > "$home/data/charter.md"
}

# spawn_secondmate <world> <id> <home> [explicit-omp-arg]
# Runs fm-spawn.sh in secondmate mode. FM_ROOT is the real repo (so fm-harness.sh
# resolves). stderr is discarded (the local-HEAD ff sync harmlessly skips a
# non-worktree home). Inspect <world>/home/state/<id>.meta and <home>/config after.
spawn_secondmate() {
  local world=$1 id=$2 home=$3 harness=${4:-} fakebin
  mkdir -p "$world/home/state" "$world/home/data"
  fakebin=$(make_noop_tmux "$world/tmux-$id")
  # An empty harness must contribute zero args, not an empty positional; build the
  # arg list explicitly so the optional harness is omitted cleanly.
  local spawn_args=("$id" "$home")
  [ -n "$harness" ] && spawn_args+=("$harness")
  spawn_args+=(--secondmate)
  PATH="$fakebin:$BASE_PATH" TMUX='' \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$world/home" \
    FM_STATE_OVERRIDE="$world/home/state" FM_DATA_OVERRIDE="$world/home/data" \
    FM_PROJECTS_OVERRIDE="$world/home/projects" FM_CONFIG_OVERRIDE="$world/home/config" \
    FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "${spawn_args[@]}" >/dev/null 2>&1 || true
}

meta_harness() { grep '^harness=' "$1" 2>/dev/null | tail -1 | cut -d= -f2-; }

# Only backlog-backend is inherited now (crew-dispatch.json and crew-harness
# are no longer in FM_INHERITABLE_CONFIG). secondmate-harness still never propagates.
test_spawn_split_and_inherit() {
  local w sm meta
  w="$TMP_ROOT/spawn-split"
  sm="$w/sm"
  mkdir -p "$w/home/config"
  printf 'manual\n' > "$w/home/config/backlog-backend"
  printf 'omp opus\n' > "$w/home/config/secondmate-harness"
  make_seeded_home "$sm" sm

  spawn_secondmate "$w" sm "$sm"

  meta="$w/home/state/sm.meta"
  [ -f "$meta" ] || fail "split: no meta written"
  [ "$(meta_harness "$meta")" = omp ] \
    || fail "split: secondmate launched on '$(meta_harness "$meta")', expected omp"
  [ "$(cat "$sm/config/backlog-backend" 2>/dev/null)" = manual ] \
    || fail "split: home backlog-backend not inherited as manual"
  [ -e "$sm/config/secondmate-harness" ] \
    && fail "split: secondmate-harness leaked into the secondmate home"
  pass "B2 spawn: secondmate launches on omp; backlog-backend inherits; secondmate-harness does not"
}

# Backward-compat: no secondmate-harness, no config at all → omp, no propagation side effects.
test_spawn_backward_compat_crew_fallback() {
  local w sm meta
  w="$TMP_ROOT/spawn-compat"
  sm="$w/sm"
  make_seeded_home "$sm" sm

  spawn_secondmate "$w" sm "$sm"

  meta="$w/home/state/sm.meta"
  [ "$(meta_harness "$meta")" = omp ] \
    || fail "compat: secondmate launched on '$(meta_harness "$meta")', expected omp"
  pass "B3 spawn: an absent secondmate-harness spawns on omp"
}

# Bare: no config at all. Spawns on omp; no propagation side effects.
test_spawn_bare_backward_compat() {
  local w sm meta
  w="$TMP_ROOT/spawn-bare"
  sm="$w/sm"
  make_seeded_home "$sm" sm

  spawn_secondmate "$w" sm "$sm"

  meta="$w/home/state/sm.meta"
  [ "$(meta_harness "$meta")" = omp ] \
    || fail "bare: secondmate launched on '$(meta_harness "$meta")', expected omp"
  [ -e "$sm/config/backlog-backend" ] && fail "bare: an unset primary still created a home backlog-backend"
  pass "B4 spawn: no config at all -> omp harness and no propagation side effects"
}

# An explicit per-spawn "omp" arg still works (uses the omp launch template).
test_spawn_explicit_harness_wins() {
  local w sm meta
  w="$TMP_ROOT/spawn-explicit"
  sm="$w/sm"
  make_seeded_home "$sm" sm

  spawn_secondmate "$w" sm "$sm" omp

  meta="$w/home/state/sm.meta"
  [ "$(meta_harness "$meta")" = omp ] \
    || fail "explicit: launched on '$(meta_harness "$meta")', expected omp"
  pass "B5 spawn: an explicit 'omp' harness arg still resolves and launches"
}

# The unverified-adapter guard still rejects an explicit unknown harness arg.
test_spawn_explicit_unknown_harness_refused() {
  local w sm fakebin err rc
  w="$TMP_ROOT/spawn-unknown"
  sm="$w/sm"
  mkdir -p "$w/home/config" "$w/home/state"
  make_seeded_home "$sm" sm
  fakebin=$(make_noop_tmux "$w/tmux")
  err="$w/spawn.err"
  rc=0
  PATH="$fakebin:$BASE_PATH" TMUX='' \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$w/home" \
    FM_STATE_OVERRIDE="$w/home/state" FM_DATA_OVERRIDE="$w/home/data" \
    FM_PROJECTS_OVERRIDE="$w/home/projects" FM_CONFIG_OVERRIDE="$w/home/config" \
    FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" sm "$sm" bogus --secondmate >/dev/null 2>"$err" || rc=$?

  [ "$rc" -ne 0 ] || fail "unknown-harness: spawn should have failed"
  assert_contains "$(cat "$err")" "unknown harness 'bogus'" \
    "unknown-harness: error names the rejected harness"
  [ -e "$w/home/state/sm.meta" ] && fail "unknown-harness: a meta was written despite the abort"
  pass "B6 spawn: an explicit unknown harness arg is refused (omp is the only adapter)"
}

# ===========================================================================
# C integration: config/secondmate-harness's optional model/effort tokens thread
# into the secondmate launch command and meta, durably and without a new file.
# ===========================================================================

meta_field() { grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2-; }

# A tmux stub that behaves like make_noop_tmux but also captures the literal
# `send-keys -l <cmd>` launch command into FM_FAKE_LAUNCH_LOG, mirroring the
# capture technique in fm-spawn-dispatch-profile.test.sh so the constructed
# launch command (not just meta) can be asserted on. Also answers the
# `#{pane_current_path}` probe from FM_FAKE_PANE_PATH so this same stub works
# for a crew/scout (non-secondmate) spawn's treehouse-worktree wait loop.
make_launch_capturing_tmux() {
  local dir=$1 fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = "-l" ]; then
          printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        fi
        prev=$a
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

# spawn_secondmate_capture <world> <id> <home> <launchlog> [extra fm-spawn.sh args...]
# Same shape as spawn_secondmate but captures the launch command into <launchlog>
# and does not discard stderr, so callers can assert on both.
spawn_secondmate_capture() {
  local world=$1 id=$2 home=$3 launchlog=$4 fakebin
  shift 4
  mkdir -p "$world/home/state" "$world/home/data"
  fakebin=$(make_launch_capturing_tmux "$world/tmux-$id")
  : > "$launchlog"
  PATH="$fakebin:$BASE_PATH" TMUX='' \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$world/home" \
    FM_STATE_OVERRIDE="$world/home/state" FM_DATA_OVERRIDE="$world/home/data" \
    FM_PROJECTS_OVERRIDE="$world/home/projects" FM_CONFIG_OVERRIDE="$world/home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_LAUNCH_LOG="$launchlog" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$home" "$@" --secondmate
}

# A bare "<harness>" secondmate-harness file must launch with NO --model/--thinking
# flag at all, and meta records model=default, effort=default.
test_spawn_bare_harness_no_model_effort_flag() {
  local w sm meta launchlog launch out status
  w="$TMP_ROOT/spawn-bare-tokens"
  sm="$w/sm"
  launchlog="$w/launch.log"
  mkdir -p "$w/home/config"
  printf 'omp\n' > "$w/home/config/secondmate-harness"
  make_seeded_home "$sm" sm

  out=$(spawn_secondmate_capture "$w" sm "$sm" "$launchlog" 2>&1); status=$?
  expect_code 0 "$status" "bare-harness secondmate spawn should succeed"

  meta="$w/home/state/sm.meta"
  [ "$(meta_field "$meta" harness)" = omp ] || fail "bare-tokens: meta harness not omp"
  [ "$(meta_field "$meta" model)" = default ] || fail "bare-tokens: meta model not default (got '$(meta_field "$meta" model)')"
  [ "$(meta_field "$meta" effort)" = default ] || fail "bare-tokens: meta effort not default (got '$(meta_field "$meta" effort)')"
  launch=$(cat "$launchlog")
  assert_contains "$launch" "omp --auto-approve" "bare-tokens: launch must use omp"
  assert_not_contains "$launch" "--model" "bare-tokens: launch must not carry a --model flag"
  assert_not_contains "$launch" "--thinking" "bare-tokens: launch must not carry a --thinking flag"
  pass "C2 spawn: a bare omp secondmate-harness launches with no model/thinking flag (backward-compat)"
}

# "<harness> <model>" threads --model into the secondmate launch and records it
# in meta, with no --thinking flag.
test_spawn_secondmate_harness_model_token() {
  local w sm meta launchlog launch
  w="$TMP_ROOT/spawn-model-token"
  sm="$w/sm"
  launchlog="$w/launch.log"
  mkdir -p "$w/home/config"
  printf 'omp opus\n' > "$w/home/config/secondmate-harness"
  make_seeded_home "$sm" sm

  spawn_secondmate_capture "$w" sm "$sm" "$launchlog" >/dev/null 2>&1

  meta="$w/home/state/sm.meta"
  [ "$(meta_field "$meta" harness)" = omp ] || fail "model-token: meta harness not omp"
  [ "$(meta_field "$meta" model)" = opus ] || fail "model-token: meta model not opus (got '$(meta_field "$meta" model)')"
  [ "$(meta_field "$meta" effort)" = default ] || fail "model-token: meta effort not default (got '$(meta_field "$meta" effort)')"
  launch=$(cat "$launchlog")
  assert_contains "$launch" "omp --auto-approve --model 'opus'" \
    "model-token: launch did not carry omp + --model opus"
  assert_not_contains "$launch" "--thinking" "model-token: launch must not carry a --thinking flag"
  pass "C3 spawn: config/secondmate-harness's model token threads --model into the omp launch and meta"
}

# "<harness> <model> <effort>" threads both flags into the launch and meta.
# omp uses --thinking for effort (not --effort).
test_spawn_secondmate_harness_model_and_effort_tokens() {
  local w sm meta launchlog launch
  w="$TMP_ROOT/spawn-model-effort-tokens"
  sm="$w/sm"
  launchlog="$w/launch.log"
  mkdir -p "$w/home/config"
  printf 'omp opus high\n' > "$w/home/config/secondmate-harness"
  make_seeded_home "$sm" sm

  spawn_secondmate_capture "$w" sm "$sm" "$launchlog" >/dev/null 2>&1

  meta="$w/home/state/sm.meta"
  [ "$(meta_field "$meta" harness)" = omp ] || fail "model-effort-tokens: meta harness not omp"
  [ "$(meta_field "$meta" model)" = opus ] || fail "model-effort-tokens: meta model not opus"
  [ "$(meta_field "$meta" effort)" = high ] || fail "model-effort-tokens: meta effort not high (got '$(meta_field "$meta" effort)')"
  launch=$(cat "$launchlog")
  assert_contains "$launch" "omp --auto-approve --model 'opus' --thinking 'high'" \
    "model-effort-tokens: launch did not carry omp + --model opus + --thinking high"
  pass "C4 spawn: config/secondmate-harness's model+effort tokens thread into the omp launch and meta"
}

# Precedence: an explicit per-spawn --model overrides the file's model token.
test_spawn_explicit_model_overrides_secondmate_harness_token() {
  local w sm meta launchlog launch
  w="$TMP_ROOT/spawn-explicit-model"
  sm="$w/sm"
  launchlog="$w/launch.log"
  mkdir -p "$w/home/config"
  printf 'omp opus high\n' > "$w/home/config/secondmate-harness"
  make_seeded_home "$sm" sm

  spawn_secondmate_capture "$w" sm "$sm" "$launchlog" --model sonnet >/dev/null 2>&1

  meta="$w/home/state/sm.meta"
  [ "$(meta_field "$meta" model)" = sonnet ] \
    || fail "explicit-model: meta model not sonnet (got '$(meta_field "$meta" model)'), explicit flag did not win over file token"
  [ "$(meta_field "$meta" effort)" = high ] || fail "explicit-model: file's effort token should still apply"
  launch=$(cat "$launchlog")
  assert_contains "$launch" "--model 'sonnet'" "explicit-model: launch did not use the explicit --model"
  assert_not_contains "$launch" "--model 'opus'" "explicit-model: launch leaked the file's model token"
  pass "C5 spawn: an explicit --model overrides config/secondmate-harness's model token; the file's effort token still applies"
}

# Precedence: an explicit per-spawn --effort overrides the file's effort token.
# omp uses --thinking for effort.
test_spawn_explicit_effort_overrides_secondmate_harness_token() {
  local w sm meta launchlog launch
  w="$TMP_ROOT/spawn-explicit-effort"
  sm="$w/sm"
  launchlog="$w/launch.log"
  mkdir -p "$w/home/config"
  printf 'omp opus high\n' > "$w/home/config/secondmate-harness"
  make_seeded_home "$sm" sm

  spawn_secondmate_capture "$w" sm "$sm" "$launchlog" --effort low >/dev/null 2>&1

  meta="$w/home/state/sm.meta"
  [ "$(meta_field "$meta" model)" = opus ] || fail "explicit-effort: file's model token should still apply"
  [ "$(meta_field "$meta" effort)" = low ] \
    || fail "explicit-effort: meta effort not low (got '$(meta_field "$meta" effort)'), explicit flag did not win over file token"
  launch=$(cat "$launchlog")
  assert_contains "$launch" "--thinking 'low'" "explicit-effort: launch did not use the explicit --thinking low"
  assert_not_contains "$launch" "--thinking 'high'" "explicit-effort: launch leaked the file's effort token"
  pass "C6 spawn: an explicit --effort overrides config/secondmate-harness's effort token; the file's model token still applies"
}

# An explicit --harness omp (the only adapter) starts with clean model/effort
# defaults: it does NOT inherit model/effort from config/secondmate-harness even
# when that file has tokens (explicit harness arg bypasses the file's token read).
test_spawn_explicit_harness_does_not_inherit_secondmate_harness_tokens() {
  local w sm meta launchlog launch
  w="$TMP_ROOT/spawn-explicit-harness-no-tokens"
  sm="$w/sm"
  launchlog="$w/launch.log"
  mkdir -p "$w/home/config"
  printf 'omp opus high\n' > "$w/home/config/secondmate-harness"
  make_seeded_home "$sm" sm

  spawn_secondmate_capture "$w" sm "$sm" "$launchlog" --harness omp >/dev/null 2>&1

  meta="$w/home/state/sm.meta"
  [ "$(meta_field "$meta" harness)" = omp ] || fail "explicit-harness-no-tokens: meta harness not omp"
  [ "$(meta_field "$meta" model)" = default ] || fail "explicit-harness-no-tokens: meta model should stay default"
  [ "$(meta_field "$meta" effort)" = default ] || fail "explicit-harness-no-tokens: meta effort should stay default"
  launch=$(cat "$launchlog")
  assert_contains "$launch" "omp --auto-approve" "explicit-harness-no-tokens: launch did not use omp"
  assert_not_contains "$launch" "--model" "explicit-harness-no-tokens: launch must not carry a --model flag"
  assert_not_contains "$launch" "--thinking" "explicit-harness-no-tokens: launch must not carry a --thinking flag"
  pass "C7 spawn: an explicit --harness omp starts with clean model/effort defaults (file tokens not read)"
}

# An explicit --harness omp with explicit --model and --effort flags threads them
# into the launch and meta, still ignoring the file's tokens.
test_spawn_explicit_harness_uses_explicit_profile_axes() {
  local w sm meta launchlog launch
  w="$TMP_ROOT/spawn-explicit-harness-explicit-axes"
  sm="$w/sm"
  launchlog="$w/launch.log"
  mkdir -p "$w/home/config"
  printf 'omp opus high\n' > "$w/home/config/secondmate-harness"
  make_seeded_home "$sm" sm

  spawn_secondmate_capture "$w" sm "$sm" "$launchlog" --harness omp --model sonnet --effort medium >/dev/null 2>&1

  meta="$w/home/state/sm.meta"
  [ "$(meta_field "$meta" harness)" = omp ] || fail "explicit-harness-explicit-axes: meta harness not omp"
  [ "$(meta_field "$meta" model)" = sonnet ] || fail "explicit-harness-explicit-axes: meta model did not use explicit value"
  [ "$(meta_field "$meta" effort)" = medium ] || fail "explicit-harness-explicit-axes: meta effort did not use explicit value"
  launch=$(cat "$launchlog")
  assert_contains "$launch" "--model 'sonnet'" "explicit-harness-explicit-axes: launch did not use the explicit --model"
  assert_contains "$launch" "--thinking 'medium'" "explicit-harness-explicit-axes: launch did not use the explicit --thinking"
  assert_not_contains "$launch" "--model 'opus'" "explicit-harness-explicit-axes: launch leaked the file's model token"
  assert_not_contains "$launch" "--thinking 'high'" "explicit-harness-explicit-axes: launch leaked the file's effort token"
  pass "C8 spawn: explicit --harness omp still honors explicit model/effort flags"
}

# Crew/scout (non-secondmate) launch is entirely unaffected by the model/effort token
# feature: no model/effort is invented even when secondmate-harness has tokens.
test_spawn_fallback_chain_and_crew_scout_unaffected() {
  local w sm meta home proj wt fakebin launchlog id launch
  w="$TMP_ROOT/spawn-fallback-and-crew"
  sm="$w/sm"
  launchlog="$w/launch.log"
  make_seeded_home "$sm" sm

  # secondmate: no tokens, harness=omp, model/effort stay default
  spawn_secondmate_capture "$w" sm "$sm" "$launchlog" >/dev/null 2>&1

  meta="$w/home/state/sm.meta"
  [ "$(meta_field "$meta" harness)" = omp ] \
    || fail "fallback: secondmate harness not omp"
  [ "$(meta_field "$meta" model)" = default ] || fail "fallback: meta model should stay default with no tokens"
  [ "$(meta_field "$meta" effort)" = default ] || fail "fallback: meta effort should stay default with no tokens"

  # Crew/scout launch: must NOT read config/secondmate-harness tokens.
  id="crew-unaffected-z1"
  home="$w/home"
  proj="$w/crew-project"
  wt="$w/crew-wt"
  fakebin=$(make_launch_capturing_tmux "$w/tmux-crew")
  fm_git_worktree "$proj" "$wt" "wt-crew"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'brief\n' > "$home/data/$id/brief.md"
  printf 'omp sonnet medium\n' > "$home/config/secondmate-harness"
  : > "$launchlog"
  PATH="$fakebin:$BASE_PATH" TMUX="fake,1,0" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" FM_FAKE_LAUNCH_LOG="$launchlog" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" >/dev/null 2>&1
  meta="$home/state/$id.meta"
  [ "$(meta_field "$meta" kind)" = ship ] || fail "crew-unaffected: expected an ordinary ship task"
  [ "$(meta_field "$meta" harness)" = omp ] || fail "crew-unaffected: crew harness not omp"
  [ "$(meta_field "$meta" model)" = default ] || fail "crew-unaffected: crew task must not invent a model"
  [ "$(meta_field "$meta" effort)" = default ] || fail "crew-unaffected: crew task must not invent an effort"
  launch=$(cat "$launchlog")
  assert_not_contains "$launch" "--model" "crew-unaffected: crew launch must not carry a --model flag"
  assert_not_contains "$launch" "--thinking" "crew-unaffected: crew launch must not carry a --thinking flag"
  pass "C9 spawn: no tokens in secondmate-harness → defaults; crew/scout launches are unaffected by model/effort tokens"
}

# ===========================================================================
# B integration: spawn, bootstrap, and config push propagate inherited local
# material and keep it converged on the primary (independent of tracked-file ff
# status).
# ===========================================================================

# A PRIMARY firstmate repo on main with one commit + a home dir, mirroring the
# real gitignore (config/crew-harness ignored, so a propagated value never dirties
# the secondmate worktree on a later sweep). Echoes the world dir.
new_world() {
  local name=$1 dispatch_ignore=${2:-yes} w
  w="$TMP_ROOT/$name"
  mkdir -p "$w/home/state" "$w/home/data" "$w/home/config"
  touch "$w/home/state/.last-watcher-beat"
  git init -q -b main "$w/main"
  {
    printf 'projects/\nstate/\ndata/\n.no-mistakes/\n'
    [ "$dispatch_ignore" = no ] || printf 'config/crew-dispatch.json\n'
    printf 'config/crew-harness\nconfig/secondmate-harness\nconfig/backlog-backend\n'
  } > "$w/main/.gitignore"
  printf 'v1\n' > "$w/main/AGENTS.md"
  printf 'r1\n' > "$w/main/README.md"
  mkdir -p "$w/main/bin"
  printf 'echo a\n' > "$w/main/bin/tool.sh"
  git -C "$w/main" add -A
  git -C "$w/main" commit -qm c1
  printf '%s\n' "$w"
}

# A live secondmate home as a DETACHED worktree of the primary at <commit>, with
# its seed marker and a live kind=secondmate meta.
add_sm_worktree() {
  local w=$1 id=$2 commit=$3
  git -C "$w/main" worktree add -q --detach "$w/$id" "$commit"
  printf '%s\n' "$id" > "$w/$id/.fm-secondmate-home"
  {
    printf 'window=firstmate:fm-%s\n' "$id"
    printf 'kind=secondmate\n'
    printf 'home=%s/%s\n' "$w" "$id"
  } > "$w/home/state/$id.meta"
}

make_fake_toolchain() {
  local dir=$1 fakebin
  fakebin="$dir/fakebin"
  mkdir -p "$fakebin"
  fm_fake_exit0 "$fakebin" tmux node gh-axi chrome-devtools-axi lavish-axi
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/gh"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'Usage: treehouse get [--lease]'
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'no-mistakes version v1.31.2 (fake)'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
  printf '%s\n' "$fakebin"
}

run_bootstrap() {
  local w=$1 fakebin
  fakebin=$(make_fake_toolchain "$w")
  PATH="$fakebin:$BASE_PATH" FM_HOME="$w/home" FM_ROOT_OVERRIDE="$w/main" \
    "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null
}

run_config_push() {
  local w=$1
  PATH="$BASE_PATH" FM_HOME="$w/home" FM_ROOT_OVERRIDE="$w/main" \
    "$ROOT/bin/fm-config-push.sh"
}

# The sweep pushes the primary's declared inherited config (backlog-backend) into
# a live home, re-converges it when the primary changes it, and mirrors absence
# when the primary clears it - all while never inheriting secondmate-harness.
test_bootstrap_sweep_propagates_and_reconverges() {
  local w c1
  w=$(new_world boot-prop)
  c1=$(git -C "$w/main" rev-parse HEAD)
  add_sm_worktree "$w" sm "$c1"

  # Initial push: primary backlog-backend=manual; secondmate-harness must NOT flow.
  printf 'manual\n' > "$w/home/config/backlog-backend"
  printf 'omp opus\n' > "$w/home/config/secondmate-harness"
  run_bootstrap "$w" >/dev/null
  [ "$(cat "$w/sm/config/backlog-backend" 2>/dev/null)" = manual ] \
    || fail "sweep: backlog-backend not pushed into the live home"
  [ -e "$w/sm/config/secondmate-harness" ] \
    && fail "sweep: secondmate-harness was inherited (must not be)"

  # Re-converge: primary changes backlog-backend; the home follows on the next sweep.
  printf 'tasks-axi\n' > "$w/home/config/backlog-backend"
  run_bootstrap "$w" >/dev/null
  [ "$(cat "$w/sm/config/backlog-backend" 2>/dev/null)" = tasks-axi ] \
    || fail "sweep: home did not re-converge to the primary's new backlog-backend"

  # Mirror absence: primary clears inherited config; the home's copy is removed.
  rm -f "$w/home/config/backlog-backend"
  run_bootstrap "$w" >/dev/null
  [ -e "$w/sm/config/backlog-backend" ] \
    && fail "sweep: home backlog-backend not removed after the primary cleared it"
  pass "B7 bootstrap sweep pushes, re-converges, and mirrors absence; never inherits secondmate-harness"
}

# Convergence is independent of the tracked-files fast-forward: a home already
# current on tracked files still receives a config change.
test_bootstrap_sweep_propagates_when_tracked_current() {
  local w head
  w=$(new_world boot-prop-current)
  head=$(git -C "$w/main" rev-parse HEAD)
  add_sm_worktree "$w" sm "$head"   # already on the primary's HEAD (ff is a no-op)

  printf 'manual\n' > "$w/home/config/backlog-backend"
  run_bootstrap "$w" >/dev/null
  [ "$(cat "$w/sm/config/backlog-backend" 2>/dev/null)" = manual ] \
    || fail "backlog-backend did not propagate to a tracked-current home"
  pass "B8 bootstrap sweep propagates config even when the home's tracked files are already current"
}

# Backward-compat: with no inherited config set, the sweep is a no-op for the
# home's config/ - exactly as before this feature - and ordinary sweep behavior
# (fast-forward) is unaffected.
test_bootstrap_sweep_no_inheritance_is_noop() {
  local w c1 head
  w=$(new_world boot-noop)
  c1=$(git -C "$w/main" rev-parse HEAD)
  add_sm_worktree "$w" sm "$c1"
  # Advance the primary so the sweep has a real fast-forward to perform.
  printf 'v2\n' > "$w/main/AGENTS.md"
  git -C "$w/main" add -A
  git -C "$w/main" commit -qm c2
  head=$(git -C "$w/main" rev-parse HEAD)

  run_bootstrap "$w" >/dev/null

  [ -e "$w/sm/config" ] && fail "no-inheritance sweep created a home config/ dir"
  [ "$(git -C "$w/sm" rev-parse HEAD)" = "$head" ] \
    || fail "no-inheritance sweep did not still fast-forward the tracked files"
  pass "B10 bootstrap sweep with no inherited config is a config no-op and still fast-forwards"
}

test_bootstrap_sweep_surfaces_config_propagation_failure() {
  local w c1 out fail_line
  w=$(new_world boot-prop-fail)
  c1=$(git -C "$w/main" rev-parse HEAD)
  add_sm_worktree "$w" sm "$c1"
  # Poison backlog-backend as a directory so the copy fails.
  printf 'manual\n' > "$w/home/config/backlog-backend"
  mkdir -p "$w/sm/config/backlog-backend"

  out=$(run_bootstrap "$w")

  fail_line=$(printf '%s\n' "$out" | grep '^SECONDMATE_SYNC: secondmate sm: skipped: inheritance failed' || true)
  [ -n "$fail_line" ] || fail "bootstrap did not surface inheritance propagation failure (got: $out)"
  [ -d "$w/sm/config/backlog-backend" ] || fail "failed propagation removed the wrong path"
  pass "B11 bootstrap sweep surfaces config propagation failures"
}

test_config_push_propagates_reports_without_ff_or_nudge() {
  local w c1 sm_real old_head out err status out2 tmp
  w=$(new_world config-push-basic)
  c1=$(git -C "$w/main" rev-parse HEAD)
  add_sm_worktree "$w" sm "$c1"
  sm_real=$(cd "$w/sm" && pwd -P)
  printf -- '- sm - config push target (home: %s; scope: config; projects: alpha; added 2026-06-30)\n' "$sm_real" > "$w/home/data/secondmates.md"
  tmp="$w/home/state/sm.meta.tmp"
  grep -v '^home=' "$w/home/state/sm.meta" > "$tmp"
  mv "$tmp" "$w/home/state/sm.meta"

  printf 'v2\n' > "$w/main/AGENTS.md"
  git -C "$w/main" add AGENTS.md
  git -C "$w/main" commit -qm c2
  old_head=$(git -C "$w/sm" rev-parse HEAD)

  printf 'manual\n' > "$w/home/config/backlog-backend"
  err="$w/config-push-basic.err"
  out=$(run_config_push "$w" 2>"$err"); status=$?

  expect_code 0 "$status" "config push should succeed"
  assert_contains "$out" "config-push: $w/home -> live secondmate homes" \
    "config push lacked the header"
  assert_contains "$out" "secondmate sm ($sm_real):" \
    "config push did not discover the live secondmate through registry fallback"
  assert_contains "$out" "backlog-backend: pushed" \
    "config push did not report backlog-backend as pushed"
  assert_not_contains "$out" "NUDGE_SECONDMATES" \
    "config push must not nudge secondmates"
  [ "$(git -C "$w/sm" rev-parse HEAD)" = "$old_head" ] \
    || fail "config push fast-forwarded tracked files"
  [ ! -s "$err" ] || fail "clean config push wrote unexpected stderr: $(cat "$err")"

  out2=$(run_config_push "$w" 2>"$err"); status=$?
  expect_code 0 "$status" "idempotent config push should succeed"
  assert_contains "$out2" "backlog-backend: unchanged" \
    "idempotent config push did not report backlog-backend as unchanged"
  pass "B12 config-push propagates via shared live discovery, reports items, and does not fast-forward or nudge"
}

test_config_push_reports_skips_dirty_and_invalid_home() {
  local w head out err status dirty_real bad_home err_text tmp
  w=$(new_world config-push-warnings)
  head=$(git -C "$w/main" rev-parse HEAD)
  add_sm_worktree "$w" dirty "$head"
  dirty_real=$(cd "$w/dirty" && pwd -P)

  printf 'local edit\n' >> "$w/dirty/README.md"

  bad_home="$w/not-secondmate"
  mkdir -p "$bad_home"
  {
    printf 'window=firstmate:fm-bad\n'
    printf 'kind=secondmate\n'
    printf 'home=%s\n' "$bad_home"
  } > "$w/home/state/bad.meta"

  printf 'manual\n' > "$w/home/config/backlog-backend"
  err="$w/config-push-warnings.err"
  out=$(run_config_push "$w" 2>"$err"); status=$?

  expect_code 0 "$status" "warnings-only config push should exit zero"
  assert_contains "$out" "secondmate dirty ($dirty_real):" \
    "config push did not report dirty home"
  assert_contains "$out" "home: dirty working tree - local-material push continuing" \
    "config push did not surface dirty state"
  assert_contains "$out" "secondmate bad ($bad_home): skipped - unsafe home: not a seeded secondmate home" \
    "config push did not report invalid secondmate home"
  pass "B13 config-push reports dirty and invalid homes without failing warnings-only runs"
}

test_config_push_exits_nonzero_on_copy_error() {
  local w head out err status sm_real err_text
  w=$(new_world config-push-error)
  head=$(git -C "$w/main" rev-parse HEAD)
  add_sm_worktree "$w" sm "$head"
  sm_real=$(cd "$w/sm" && pwd -P)
  printf 'manual\n' > "$w/home/config/backlog-backend"
  mkdir -p "$w/sm/config/backlog-backend"

  err="$w/config-push-error.err"
  out=$(run_config_push "$w" 2>"$err"); status=$?

  expect_code 1 "$status" "copy-error config push should exit non-zero"
  assert_contains "$out" "secondmate sm ($sm_real):" \
    "config push error output missed the home"
  assert_contains "$out" "backlog-backend: error - failed to copy" \
    "config push did not report the per-item copy error"
  err_text=$(cat "$err")
  assert_contains "$err_text" "fm-config-inherit: error: failed to copy backlog-backend" \
    "copy error did not emit a stderr diagnostic"
  pass "B14 config-push exits nonzero on real propagation errors"
}

test_harness_resolution
test_secondmate_model_effort_tokens
test_propagate_lib
test_spawn_split_and_inherit
test_spawn_backward_compat_crew_fallback
test_spawn_bare_backward_compat
test_spawn_explicit_harness_wins
test_spawn_explicit_unknown_harness_refused
test_spawn_bare_harness_no_model_effort_flag
test_spawn_secondmate_harness_model_token
test_spawn_secondmate_harness_model_and_effort_tokens
test_spawn_explicit_model_overrides_secondmate_harness_token
test_spawn_explicit_effort_overrides_secondmate_harness_token
test_spawn_explicit_harness_does_not_inherit_secondmate_harness_tokens
test_spawn_explicit_harness_uses_explicit_profile_axes
test_spawn_fallback_chain_and_crew_scout_unaffected
test_bootstrap_sweep_propagates_and_reconverges
test_bootstrap_sweep_propagates_when_tracked_current
test_bootstrap_sweep_no_inheritance_is_noop
test_bootstrap_sweep_surfaces_config_propagation_failure
test_config_push_propagates_reports_without_ff_or_nudge
test_config_push_reports_skips_dirty_and_invalid_home
test_config_push_exits_nonzero_on_copy_error

echo "# all fm-secondmate-harness tests passed"
