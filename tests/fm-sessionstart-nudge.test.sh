#!/usr/bin/env bash
# Behavior + omp-wiring tests for the native session-start nudge.
# The wrapper (bin/fm-sessionstart-nudge.sh) is harness-agnostic; the omp turn-end
# extension is the only tracked transport in this omp-only fork.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset NO_MISTAKES_GATE

TMP_ROOT=$(fm_test_tmproot fm-sessionstart-nudge)
NUDGE="$ROOT/bin/fm-sessionstart-nudge.sh"
NUDGE_LINE="Run \`bin/fm-session-start.sh\` now, exactly once, before executing any other instructions."
export NODE_NO_WARNINGS=1
fm_git_identity fmtest fmtest@example.invalid

make_primary() {
  local dir=$1
  mkdir -p "$dir/bin" "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
}

run_nudge() {
  local root=$1
  FM_GATE_REFUSE_BYPASS=0 FM_ROOT_OVERRIDE="$root" FM_HOME="$root" "$NUDGE"
}

expect_silent_zero() {
  local label=$1
  shift
  local out status=0
  out=$("$@" 2>&1) || status=$?
  expect_code 0 "$status" "$label must exit 0"
  [ -z "$out" ] || fail "$label must be silent, got: $out"
}

test_genuine_primary_nudges() {
  local root="$TMP_ROOT/primary" out status=0
  make_primary "$root"
  out=$(run_nudge "$root") || status=$?
  expect_code 0 "$status" "genuine primary nudge"
  [ "$out" = "$NUDGE_LINE" ] || fail "genuine primary printed unexpected output: $out"
  pass "fm-sessionstart-nudge: a genuine primary gets exactly one instruction line"
}

test_gate_env_is_silent() {
  local root="$TMP_ROOT/gate-env"
  make_primary "$root"
  expect_silent_zero "gate env nudge" env NO_MISTAKES_GATE=1 FM_GATE_REFUSE_BYPASS=0 \
    FM_ROOT_OVERRIDE="$root" FM_HOME="$root" "$NUDGE"
  pass "fm-sessionstart-nudge: NO_MISTAKES_GATE is silent"
}

test_gate_common_dir_is_silent() {
  local source="$TMP_ROOT/gate-source" bare="$TMP_ROOT/.no-mistakes/repos/gate.git"
  local root="$TMP_ROOT/gate-worktree"
  fm_git_init_commit "$source"
  mkdir -p "$(dirname "$bare")"
  git clone --quiet --bare "$source" "$bare"
  git --git-dir="$bare" worktree add --quiet -b gate-test "$root" HEAD
  mkdir -p "$root/bin" "$root/state"
  : > "$root/AGENTS.md"
  printf 'gate-test\n' > "$root/.fm-secondmate-home"
  expect_silent_zero "gate common-dir nudge" env FM_GATE_REFUSE_BYPASS=0 \
    FM_ROOT_OVERRIDE="$root" FM_HOME="$root" "$NUDGE"
  pass "fm-sessionstart-nudge: .no-mistakes gate common-dir is silent"
}

test_unmarked_linked_worktree_is_silent() {
  local base="$TMP_ROOT/worktree-base" root="$TMP_ROOT/worktree-child"
  fm_git_worktree "$base" "$root" fm/sessionstart-linked
  mkdir -p "$root/bin" "$root/state"
  : > "$root/AGENTS.md"
  expect_silent_zero "linked worktree nudge" run_nudge "$root"
  pass "fm-sessionstart-nudge: an unmarked linked task worktree is silent"
}

test_linked_secondmate_primary_nudges() {
  local base="$TMP_ROOT/secondmate-base" root="$TMP_ROOT/secondmate-home" out status=0
  fm_git_worktree "$base" "$root" fm/sessionstart-secondmate
  mkdir -p "$root/bin" "$root/state"
  : > "$root/AGENTS.md"
  printf 'sessionstart-sm\n' > "$root/.fm-secondmate-home"
  out=$(run_nudge "$root") || status=$?
  expect_code 0 "$status" "linked secondmate nudge"
  [ "$out" = "$NUDGE_LINE" ] || fail "linked secondmate printed unexpected output: $out"
  pass "fm-sessionstart-nudge: a marked linked secondmate home is a primary"
}

test_missing_state_is_silent() {
  local root="$TMP_ROOT/missing-state"
  make_primary "$root"
  rmdir "$root/state"
  expect_silent_zero "missing state nudge" run_nudge "$root"
  pass "fm-sessionstart-nudge: a checkout without state is silent"
}

test_owned_lock_is_silent() {
  local root="$TMP_ROOT/already-ran"
  make_primary "$root"
  printf '%s\n' "$$" > "$root/state/.lock"
  expect_silent_zero "owned lock nudge" run_nudge "$root"
  pass "fm-sessionstart-nudge: a lock holder in process ancestry is already run"
}

test_omp_extension_wires_sessionstart_nudge() {
  local ext
  ext=$(cat "$ROOT/.omp/extensions/fm-primary-turnend-guard.ts")
  assert_contains "$ext" 'fm-sessionstart-nudge.sh' "omp extension does not invoke the session-start nudge wrapper"
  assert_contains "$ext" 'firstmate-sessionstart-nudge' "omp extension does not inject the custom nudge message"
  assert_contains "$ext" 'pi.sendMessage' "omp extension does not use the context-safe message API"
  assert_contains "$ext" '"session_start"' "omp extension does not handle session_start"
  pass "omp turn-end extension wires the session-start nudge on session_start"
}

test_omp_extension_delivers_nudge_on_session_start() {
  # Behavioral: drive the REAL omp extension's session_start handler with a fake
  # pi and prove it delivers exactly one hidden custom message carrying the
  # wrapper's nudge line. Copies the extension + the three bash files into a
  # genuine primary so the extension resolves its own root/bin.
  local root="$TMP_ROOT/omp-ext-delivers" out status=0
  make_primary "$root"
  mkdir -p "$root/.omp/extensions"
  cp "$ROOT/.omp/extensions/fm-primary-turnend-guard.ts" "$root/.omp/extensions/"
  cp "$ROOT/bin/fm-sessionstart-nudge.sh" "$ROOT/bin/fm-primary-scope-lib.sh" \
    "$ROOT/bin/fm-gate-refuse-lib.sh" "$root/bin/"
  chmod +x "$root/bin/fm-sessionstart-nudge.sh"
  out=$(PLUGIN="$root/.omp/extensions/fm-primary-turnend-guard.ts" \
    FM_HOME="$root" FM_ROOT_OVERRIDE="$root" EXPECTED="$NUDGE_LINE" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const handlers = {};
const sent = [];
const pi = {
  on(name, handler) {
    handlers[name] = handler;
  },
  sendMessage(payload) {
    sent.push(payload);
  },
  sendUserMessage: async () => {},
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (typeof handlers["session_start"] !== "function") throw new Error("no session_start handler registered");
await handlers["session_start"]({ type: "session_start" });
if (sent.length !== 1) throw new Error(`expected one custom message, got ${sent.length}`);
if (sent[0].customType !== "firstmate-sessionstart-nudge") throw new Error(`wrong customType: ${sent[0].customType}`);
if (sent[0].content !== process.env.EXPECTED) throw new Error(`wrong content: ${sent[0].content}`);
if (sent[0].display !== false) throw new Error("nudge must be a hidden message (display=false)");
EOF
  ) || status=$?
  expect_code 0 "$status" "omp session_start nudge delivery"
  [ -z "$out" ] || fail "omp session_start nudge delivery printed output: $out"
  pass "omp extension delivers the exact wrapper nudge as a hidden custom message on session_start"
}

test_genuine_primary_nudges
test_gate_env_is_silent
test_gate_common_dir_is_silent
test_unmarked_linked_worktree_is_silent
test_linked_secondmate_primary_nudges
test_missing_state_is_silent
test_owned_lock_is_silent
test_omp_extension_wires_sessionstart_nudge
test_omp_extension_delivers_nudge_on_session_start
