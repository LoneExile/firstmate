#!/usr/bin/env bash
# Tests for the tracked OMP (Oh My Pi) primary watcher extension, focused on the
# extension-owned watcher continuity ported from upstream #693: after an
# actionable child close the adapter starts and verifies ONE singleton successor
# arm BEFORE it delivers the wake (Option B), with single-flight, bounded
# exponential retry, ownership recheck, and a typed continuity-restoration
# failure. The omp twin of tests/fm-pi-watch-extension.test.sh's Pi cases.
#
# Each case imports the REAL extension .ts under Node type-stripping with a fake
# `pi` (ExtensionAPI stub) and a fake bin/fm-watch-arm.sh whose readiness/close
# timing is env-driven, so the actual close handler runs. The type-only
# @oh-my-pi/pi-coding-agent import is erased at runtime, so no package stub is
# needed; the fake pi supplies `zod` for the tool schema.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-omp-watch-extension)
EXT="$ROOT/.omp/extensions/fm-primary-omp-watch.ts"
# Node warns when these test-only dynamic imports load ESM from a clean checkout;
# the assertions intentionally require empty plugin output, so silence it.
export NODE_NO_WARNINGS=1

install_omp_watch_extension_fixture() {
  local repo=$1
  mkdir -p "$repo/.omp/extensions"
  cp "$EXT" "$repo/.omp/extensions/fm-primary-omp-watch.ts"
}

test_omp_extension_present_and_self_hashing() {
  local text
  assert_present "$EXT" "tracked OMP primary watcher extension is missing"
  text=$(cat "$EXT")
  assert_contains "$text" "fm_watch_arm_omp" "tracked extension missing tool name"
  assert_contains "$text" "fm-watch-arm-omp" "tracked extension missing command name"
  assert_contains "$text" "fm-watch-arm.sh" "tracked extension missing watcher arm"
  assert_contains "$text" "sendUserMessage" "tracked extension missing OMP wake API"
  assert_contains "$text" "deliverAs: \"followUp\"" "tracked extension missing followUp delivery"
  assert_contains "$text" ".omp-watch-extension-loaded" "tracked extension missing loaded marker"
  assert_contains "$text" 'createHash("sha256").update(readFileSync(extensionFile)).digest("hex")' "tracked extension does not self-hash its own content"
  assert_contains "$text" 'fileURLToPath(import.meta.url)' "tracked extension does not self-locate via import.meta.url"
  assert_contains "$text" 'type LockOwnership = "owned" | "missing" | "other"' "tracked extension does not distinguish missing lock from another owner"
  assert_contains "$text" 'if (ownership === "other") return { ok: false' "tracked extension arm does not preserve the live-other read-only refusal"
  assert_contains "$text" "no live session holds the lock" "tracked extension arm missing stale-lock recovery guidance"
  assert_contains "$text" "call fm_watch_arm_omp to re-arm" "tracked extension arm does not direct supervision re-arm"
  assert_contains "$text" "FM_WATCH_ARM_SCRIPT: armScript" "tracked extension does not pass the effective watcher arm script"
  assert_contains "$text" "FM_WATCH_PREDECESSOR_ARM_PID: predecessorArmPid" "tracked extension does not pass the predecessor arm identity to the successor"
  assert_contains "$text" "exec \\\"\$FM_WATCH_ARM_SCRIPT\\\" --restart" "tracked extension does not restart into an OMP-owned watcher child"
  assert_contains "$text" 'parameters: pi.zod.object({})' "tracked extension tool is not using OMP's canonical pi.zod schema"
  assert_contains "$text" 'ctx.ui.notify' "tracked extension command does not notify through OMP's UI"
  assert_contains "$text" 'process.once("exit", cleanupOnProcessExit)' "tracked extension lacks clean-process-exit cleanup"
  # Continuity contract (#693): successor-before-wake, single-flight, typed failure.
  assert_contains "$text" "restoreAfterActionableClose" "tracked extension does not restore a successor after an actionable close"
  assert_contains "$text" "Promise.withResolvers" "tracked extension does not use the repo-canonical Promise.withResolvers"
  assert_contains "$text" "could not restore watcher continuity after" "tracked extension lacks the typed continuity-restoration failure"
  assert_contains "$text" "Watcher continuity is extension-owned" "tracked extension wake prompt does not declare extension-owned continuity"
  assert_not_contains "$text" 'ReturnType<typeof setTimeout>' "tracked extension publishes a timer type through ReturnType instead of NodeJS.Timeout"
  pass "OMP primary watcher extension is tracked, self-hashing, and continuity-wired"
}

test_omp_actionable_close_starts_single_successor_before_delivery() {
  local repo home plugin log stop out status
  repo="$TMP_ROOT/omp-continuous-rearm-root"
  home="$TMP_ROOT/omp-continuous-rearm-home"
  log="$TMP_ROOT/omp-continuous-rearm.log"
  stop="$TMP_ROOT/omp-continuous-rearm.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_omp_watch_extension_fixture "$repo"
  plugin="$repo/.omp/extensions/fm-primary-omp-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s predecessor=%s\n' "$$" "${FM_WATCH_PREDECESSOR_ARM_PID:-none}" >> "${FM_ARM_LOG:?}"
count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
if [ "$count" -eq 1 ]; then
  printf 'signal: synthetic actionable close\n'
  exit 0
fi
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
let deliveryStarted = false;
let rowsAtDelivery = 0;
const { promise: deliveryBlocked, resolve: releaseDelivery } = Promise.withResolvers();
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_omp") tool = candidate;
  },
  zod: { object: () => ({}) },
  sendUserMessage: async () => {
    rowsAtDelivery = existsSync(process.env.FM_ARM_LOG)
      ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").length
      : 0;
    deliveryStarted = true;
    await deliveryBlocked;
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute();
for (let i = 0; i < 250; i += 1) {
  const rows = existsSync(process.env.FM_ARM_LOG)
    ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
    : [];
  if (rows.length >= 2 && deliveryStarted) break;
  await new Promise((resolve) => setTimeout(resolve, 10));
}
const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (rows.length !== 2) throw new Error(`expected one successor arm, got ${rows.length}: ${rows.join(" | ")}`);
if (!deliveryStarted) throw new Error("wake delivery did not begin");
if (rowsAtDelivery !== 2) throw new Error(`wake delivery began before successor establishment (${rowsAtDelivery} arm rows)`);
if (!/predecessor=[0-9]+/.test(rows[1])) throw new Error(`successor did not receive predecessor identity: ${rows[1]}`);
await new Promise((resolve) => setTimeout(resolve, 100));
const stableRows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (stableRows.length !== 2) throw new Error(`single-flight violation launched ${stableRows.length} arms`);
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
releaseDelivery();
process.exit(0);
EOF
  )
  status=$?
  expect_code 0 "$status" "OMP actionable close must start one successor before wake delivery settles"
  [ -z "$out" ] || fail "OMP continuous-rearm test printed output: $out"
  pass "OMP actionable close starts one successor before wake delivery settles"
}

test_omp_hung_successor_falls_back_to_typed_wake() {
  local repo home plugin log out status
  repo="$TMP_ROOT/omp-hung-successor-root"
  home="$TMP_ROOT/omp-hung-successor-home"
  log="$TMP_ROOT/omp-hung-successor.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_omp_watch_extension_fixture "$repo"
  plugin="$repo/.omp/extensions/fm-primary-omp-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: synthetic wake\n'
  exit 0
fi
trap 'exit 0' TERM INT
while :; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_OMP_ARM_READY_TIMEOUT_MS=250 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
let prompt = "";
let rowsAtPrompt = 0;
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_omp") tool = candidate;
  },
  zod: { object: () => ({}) },
  sendUserMessage: async (message) => {
    prompt += message;
    rowsAtPrompt = existsSync(process.env.FM_ARM_LOG)
      ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").length
      : 0;
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute();
for (let i = 0; i < 500 && !prompt; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
const rows = existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
  : [];
if (rows.length !== 4) throw new Error(`expected one successor plus two retries, got ${rows.length}: ${rows.join(" | ")}`);
if (rowsAtPrompt !== 4) throw new Error(`wake arrived before restoration exhausted (${rowsAtPrompt} arm rows)`);
if (!prompt.includes("signal: synthetic wake")) throw new Error(`original wake was lost: ${prompt}`);
if (!prompt.includes("could not restore watcher continuity after 2 retries")) throw new Error(`missing typed restoration failure: ${prompt}`);
await new Promise((resolve) => setTimeout(resolve, 100));
const stableRows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (stableRows.length !== 4) throw new Error(`single-flight recovery launched ${stableRows.length} arms`);
EOF
)
  status=$?
  expect_code 0 "$status" "OMP must deliver the actionable wake after bounded hung-successor recovery"
  [ -z "$out" ] || fail "OMP hung-successor test printed output: $out"
  pass "OMP hung successor falls back to one typed actionable wake"
}

test_omp_unretired_successor_falls_back_without_retry() {
  local repo home plugin log release out status
  repo="$TMP_ROOT/omp-unretired-successor-root"
  home="$TMP_ROOT/omp-unretired-successor-home"
  log="$TMP_ROOT/omp-unretired-successor.log"
  release="$TMP_ROOT/omp-unretired-successor.release"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_omp_watch_extension_fixture "$repo"
  plugin="$repo/.omp/extensions/fm-primary-omp-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ -f "$FM_ARM_LOG" ]; then
  count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
else
  count=0
fi
if [ "$count" -eq 0 ]; then
  printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: synthetic wake\n'
  exit 0
fi
trap '' TERM INT
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
while [ ! -e "$FM_RELEASE_FILE" ]; do sleep 0.1; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_RELEASE_FILE="$release" FM_OMP_ARM_READY_TIMEOUT_MS=250 FM_WATCH_ARM_RETIRE_TIMEOUT_MS=20 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
let prompt = "";
let rowsAtPrompt = 0;
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_omp") tool = candidate;
  },
  zod: { object: () => ({}) },
  sendUserMessage: async (message) => {
    prompt += message;
    rowsAtPrompt = existsSync(process.env.FM_ARM_LOG)
      ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").length
      : 0;
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute();
for (let i = 0; i < 500 && !prompt; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
const rows = existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
  : [];
if (rows.length !== 2) throw new Error(`unretired arm overlapped a retry: ${rows.join(" | ")}`);
if (rowsAtPrompt !== 2) throw new Error(`wake arrived after an overlapping retry (${rowsAtPrompt} arm rows)`);
if (!prompt.includes("signal: synthetic wake")) throw new Error(`original wake was lost: ${prompt}`);
if (!prompt.includes("unready successor arm did not exit within 20ms")) throw new Error(`missing unretired-arm failure: ${prompt}`);
writeFileSync(process.env.FM_RELEASE_FILE, "release\n");
await new Promise((resolve) => setTimeout(resolve, 80));
EOF
)
  status=$?
  expect_code 0 "$status" "OMP must fall back without overlapping an unretired successor"
  [ -z "$out" ] || fail "OMP unretired-successor test printed output: $out"
  pass "OMP unretired successor falls back without an overlapping retry"
}

test_omp_empty_close_retries_instead_of_disappearing() {
  local repo home plugin log stop out status
  repo="$TMP_ROOT/omp-empty-close-root"
  home="$TMP_ROOT/omp-empty-close-home"
  log="$TMP_ROOT/omp-empty-close.log"
  stop="$TMP_ROOT/omp-empty-close.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_omp_watch_extension_fixture "$repo"
  plugin="$repo/.omp/extensions/fm-primary-omp-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
if [ "$count" -eq 1 ]; then exit 0; fi
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
let prompts = 0;
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_omp") tool = candidate;
  },
  zod: { object: () => ({}) },
  sendUserMessage: async () => {
    prompts += 1;
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute();
for (let i = 0; i < 250; i += 1) {
  const rows = existsSync(process.env.FM_ARM_LOG)
    ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
    : [];
  if (rows.length >= 2) break;
  await new Promise((resolve) => setTimeout(resolve, 10));
}
const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (rows.length !== 2) throw new Error(`clean empty close was ignored: ${rows.join(" | ")}`);
if (prompts !== 0) throw new Error(`restored transient close surfaced ${prompts} failure prompts`);
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
process.exit(0);
EOF
  )
  status=$?
  expect_code 0 "$status" "OMP clean empty close must trigger a bounded continuity retry"
  [ -z "$out" ] || fail "OMP empty-close retry test printed output: $out"
  pass "OMP clean empty close triggers a bounded continuity retry"
}

test_omp_actionable_close_rechecks_session_lock() {
  local repo home plugin log release out status
  repo="$TMP_ROOT/omp-close-lock-root"
  home="$TMP_ROOT/omp-close-lock-home"
  log="$TMP_ROOT/omp-close-lock.log"
  release="$TMP_ROOT/omp-close-lock.release"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_omp_watch_extension_fixture "$repo"
  plugin="$repo/.omp/extensions/fm-primary-omp-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
while [ ! -e "$FM_RELEASE_FILE" ]; do sleep 0.02; done
printf 'signal: lock handoff\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_RELEASE_FILE="$release" node --input-type=module 2>&1 <<'EOF'
import { spawn } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
let prompt = "";
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_omp") tool = candidate;
  },
  zod: { object: () => ({}) },
  sendUserMessage: async (message) => {
    prompt += message;
  },
};
const lock = `${process.env.FM_HOME}/state/.lock`;
writeFileSync(lock, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute();
const other = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], { stdio: "ignore" });
try {
  writeFileSync(lock, `${other.pid}\n`);
  writeFileSync(process.env.FM_RELEASE_FILE, "release\n");
  for (let i = 0; i < 250 && !prompt.includes("no longer owns the lock"); i += 1) {
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
  if (rows.length !== 1) throw new Error(`successor launched after lock loss: ${rows.join(" | ")}`);
  if (!prompt.includes("no longer owns the lock")) throw new Error(`missing lock-loss failure: ${prompt}`);
} finally {
  other.kill("SIGTERM");
}
EOF
  )
  status=$?
  [ "$status" -eq 0 ] || fail "OMP close handler must verify session-lock ownership before successor launch: $out"
  [ -z "$out" ] || fail "OMP close lock test printed output: $out"
  pass "OMP close handler verifies session-lock ownership before successor launch"
}

test_omp_process_exit_cleanup_stops_arm_child() {
  local repo home plugin cleanup_log pid_file out status pid i
  repo="$TMP_ROOT/omp-process-exit-root"
  home="$TMP_ROOT/omp-process-exit-home"
  cleanup_log="$TMP_ROOT/omp-process-exit-cleaned"
  pid_file="$TMP_ROOT/omp-process-exit-child.pid"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_omp_watch_extension_fixture "$repo"
  plugin="$repo/.omp/extensions/fm-primary-omp-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
trap 'printf "cleaned\n" > "$FM_CLEANUP_LOG"; exit 0' TERM
printf '%s\n' "$$" > "$FM_CHILD_PID_FILE"
while :; do sleep 1; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_CLEANUP_LOG="$cleanup_log" FM_CHILD_PID_FILE="$pid_file" node --input-type=module 2>&1 <<'EOF'
import { existsSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_omp") tool = candidate;
  },
  zod: { object: () => ({}) },
  sendUserMessage: async () => {},
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute();
for (let i = 0; i < 250 && !existsSync(process.env.FM_CHILD_PID_FILE); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!existsSync(process.env.FM_CHILD_PID_FILE)) throw new Error("arm child did not start");
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "OMP process exit must run the watcher cleanup fallback"
  [ -z "$out" ] || fail "OMP process-exit cleanup test printed output: $out"
  i=0
  while [ "$i" -lt 250 ] && [ ! -f "$cleanup_log" ]; do
    sleep 0.02
    i=$((i + 1))
  done
  [ -f "$cleanup_log" ] || fail "OMP process-exit fallback did not deliver TERM to the arm child"
  pid=$(cat "$pid_file")
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    fail "OMP arm child $pid survived process-exit cleanup"
  fi
  pass "OMP process-exit cleanup stops the attached arm child"
}

# --- R2a: queue-truth banner idempotency ------------------------------------
#
# The extension's deliverRoutineWake skips a redundant banner while a prior poke
# is pending (state/.wake-banner-pending) AND the deduped durable queue still has
# undrained items - but fails OPEN (always pokes when the queue is empty or no
# marker exists) so the last wake is never dropped. These cases drive one real
# actionable close (which reaches the routine-delivery path once the successor is
# ready) and count sendUserMessage deliveries.

install_r2a_fixture() {  # <repo> -> also (re)writes the shared node driver
  local repo=$1
  install_omp_watch_extension_fixture "$repo"
  mkdir -p "$repo/bin"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
if [ "$count" -eq 1 ]; then
  printf 'signal: synthetic actionable close\n'
  exit 0
fi
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  cat > "$TMP_ROOT/r2a-driver.mjs" <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
let tool = null;
let sends = 0;
const pi = {
  on() {}, registerCommand() {},
  registerTool(c) { if (c.name === "fm_watch_arm_omp") tool = c; },
  zod: { object: () => ({}) },
  sendUserMessage: async () => { sends += 1; },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute();
const expect = Number(process.env.EXPECT_SENDS);
if (expect === 1) {
  for (let i = 0; i < 400 && sends < 1; i += 1) await new Promise((r) => setTimeout(r, 10));
} else {
  // Suppressed: wait for the successor arm (2 rows) then settle past delivery.
  for (let i = 0; i < 300; i += 1) {
    const rows = existsSync(process.env.FM_ARM_LOG)
      ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").length : 0;
    if (rows >= 2) break;
    await new Promise((r) => setTimeout(r, 10));
  }
  await new Promise((r) => setTimeout(r, 300));
}
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
if (sends !== expect) throw new Error(`expected ${expect} send(s), got ${sends}`);
if (expect === 1 && !existsSync(`${process.env.FM_HOME}/state/.wake-banner-pending`)) {
  throw new Error("a delivered poke did not create the banner-pending marker");
}
process.exit(0);
EOF
}

r2a_run() {  # <tag> <expect-sends>; caller pre-seeds $home/state before this
  local repo=$1 home=$2 expect=$3 out status
  out=$(PLUGIN="$repo/.omp/extensions/fm-primary-omp-watch.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" \
    FM_ARM_LOG="$TMP_ROOT/r2a.log.$$" FM_STOP_FILE="$TMP_ROOT/r2a.stop.$$" EXPECT_SENDS="$expect" \
    node "$TMP_ROOT/r2a-driver.mjs" 2>&1)
  status=$?
  rm -f "$TMP_ROOT/r2a.log.$$" "$TMP_ROOT/r2a.stop.$$"
  R2A_OUT=$out
  return "$status"
}

test_omp_routine_wake_suppressed_when_poke_pending() {
  local repo home
  repo="$TMP_ROOT/r2a-suppress-root"; home="$TMP_ROOT/r2a-suppress-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_r2a_fixture "$repo"
  # A prior poke is pending AND the deduped queue still has undrained items.
  printf 'pending\n' > "$home/state/.wake-banner-pending"
  printf '1\t1\tstale\tdefault:wG:pQ\tstale: default:wG:pQ\n' > "$home/state/.wake-queue"
  r2a_run "$repo" "$home" 0 || fail "R2a suppress case exited non-zero: $R2A_OUT"
  pass "R2a: a routine watcher wake is suppressed while a prior poke is pending and the queue is undrained"
}

test_omp_routine_wake_sends_and_marks_when_none_pending() {
  local repo home
  repo="$TMP_ROOT/r2a-send-root"; home="$TMP_ROOT/r2a-send-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_r2a_fixture "$repo"
  # No marker, no queue: the first poke must send AND create the pending marker.
  r2a_run "$repo" "$home" 1 || fail "R2a send case exited non-zero: $R2A_OUT"
  pass "R2a: a routine wake with no poke pending sends once and creates the banner-pending marker"
}

test_omp_routine_wake_fails_open_when_queue_empty() {
  local repo home
  repo="$TMP_ROOT/r2a-failopen-root"; home="$TMP_ROOT/r2a-failopen-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_r2a_fixture "$repo"
  # A stale marker but an EMPTY queue must NOT suppress the only poke (fail open):
  # this is the trap - suppressing on the marker alone would drop the last wake.
  printf 'pending\n' > "$home/state/.wake-banner-pending"
  r2a_run "$repo" "$home" 1 || fail "R2a fail-open case exited non-zero: $R2A_OUT"
  pass "R2a: a stale marker with an empty queue still pokes (fail open, never drop the only wake)"
}

test_omp_extension_present_and_self_hashing
test_omp_actionable_close_starts_single_successor_before_delivery
test_omp_hung_successor_falls_back_to_typed_wake
test_omp_unretired_successor_falls_back_without_retry
test_omp_empty_close_retries_instead_of_disappearing
test_omp_actionable_close_rechecks_session_lock
test_omp_process_exit_cleanup_stops_arm_child
test_omp_routine_wake_suppressed_when_poke_pending
test_omp_routine_wake_sends_and_marks_when_none_pending
test_omp_routine_wake_fails_open_when_queue_empty
