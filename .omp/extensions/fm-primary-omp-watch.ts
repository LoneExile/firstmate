// Firstmate primary watcher bridge for OMP (Oh My Pi).
//
// The .omp/extensions/ twin of .pi/extensions/fm-primary-pi-watch.ts (kept in
// lockstep with the Pi watcher). OMP is a Pi fork with a Pi-compatible extension
// API; the OMP adaptations are the import specifier, the marker filename, "OMP"
// wording, a `pi.zod` (not typebox) tool schema, a typed ChildProcess (this
// repo's TS lint disallows `any`), `Promise.withResolvers` (per this repo's TS
// lint), and the `FM_OMP_ARM_READY_TIMEOUT_MS` knob. OMP auto-loads
// `.omp/extensions/`, never `.pi/`.
//
// Watcher continuity is extension-owned (port of upstream #693): the watcher
// stays intentionally one-shot (one actionable reason closes one cycle), and
// this adapter re-arms across the process boundary instead of depending on the
// model remembering a re-arm step. After an actionable child close it starts and
// verifies ONE singleton successor arm BEFORE it delivers the wake (Option B: the
// fleet is protected before the model handles the wake whenever restoration
// succeeds), with bounded exponential retry and a typed continuity-restoration
// failure so the model is never left blind when restoration fails. It reads the
// arm layer's existing `watcher: started|attached` readiness lines, so the
// safety-critical bin/fm-watch-arm.sh loop is untouched.
import { type ChildProcess, spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";

type ArmResult = {
  ok: boolean;
  message: string;
};

type LockOwnership = "owned" | "missing" | "other";

type CloseClassification = {
  kind: "actionable" | "failure";
  message: string;
};

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const root = resolve(extensionDir, "../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const fmRoot = process.env.FM_ROOT_OVERRIDE || root;
const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
const config = process.env.FM_CONFIG_OVERRIDE || `${fmHome}/config`;
const armScript = `${fmRoot}/bin/fm-watch-arm.sh`;
const marker = `${state}/.omp-watch-extension-loaded`;
const extensionVersion = `sha256:${createHash("sha256").update(readFileSync(extensionFile)).digest("hex")}`;
const retryBaseMs = positiveInteger("FM_WATCH_REARM_RETRY_BASE_MS", 250);
const retryMaxMs = positiveInteger("FM_WATCH_REARM_RETRY_MAX_MS", 4000);
const retryLimit = positiveInteger("FM_WATCH_REARM_RETRY_LIMIT", 5);
const armReadyTimeoutMs = positiveInteger("FM_OMP_ARM_READY_TIMEOUT_MS", 12000);
const armRetireTimeoutMs = positiveInteger("FM_WATCH_ARM_RETIRE_TIMEOUT_MS", 1000);

let child: ChildProcess | null = null;
let retryTimer: NodeJS.Timeout | null = null;
let retryFailures = 0;
let stopping = false;
let seq = 0;
let restoring = false;
const armReadiness = new WeakMap<ChildProcess, Promise<boolean>>();
const armClose = new WeakMap<ChildProcess, Promise<void>>();
// The arm layer prints this once it has confirmed a live watcher (a fresh child
// or an attached successor); it is the readiness signal continuity waits on.
const armEstablishedPattern = /^watcher: (?:started|attached)\b/m;

function positiveInteger(name: string, fallback: number): number {
  const value = Number(process.env[name]);
  if (!Number.isFinite(value) || value <= 0) return fallback;
  return Math.floor(value);
}

function parentPid(pid: string): string {
  const result = spawnSync("ps", ["-o", "ppid=", "-p", pid], { encoding: "utf8" });
  if (result.status !== 0) return "";
  return result.stdout.trim();
}

function pidAlive(pid: string): boolean {
  try {
    process.kill(Number(pid), 0);
    return true;
  } catch {
    return false;
  }
}

function lockOwnership(): LockOwnership {
  let lockPid = "";
  try {
    lockPid = readFileSync(`${state}/.lock`, "utf8").trim();
  } catch {
    return "missing";
  }
  if (!/^[0-9]+$/.test(lockPid) || lockPid === "1") return "other";
  let pid = String(process.pid);
  for (let i = 0; i < 8; i += 1) {
    if (pid === lockPid) return "owned";
    pid = parentPid(pid);
    if (!pid || pid === "1") break;
  }
  return pidAlive(lockPid) ? "other" : "missing";
}

function markLoaded(): void {
  if (lockOwnership() === "other") return;
  mkdirSync(state, { recursive: true });
  writeFileSync(marker, `${extensionVersion}\n${process.pid}\n`);
}

function actionableLine(output: string): string {
  const lines = output.split(/\r?\n/);
  return lines.find((line) => /^(signal:|stale:|check:|heartbeat($|:))/.test(line)) || "";
}

function classifyClose(stdout: string, stderr: string, code: number | null, signal: NodeJS.Signals | null): CloseClassification {
  const combined = `${stdout}\n${stderr}`.trim();
  const reason = actionableLine(combined);
  if (reason) return { kind: "actionable", message: reason };
  const healthy = combined.split(/\r?\n/).find((line) => /^watcher: healthy\b/.test(line));
  if (healthy) {
    return {
      kind: "failure",
      message: `watcher: FAILED - OMP extension arm child found an external healthy watcher instead of owning wake delivery\n${healthy}`,
    };
  }
  const failed = combined.split(/\r?\n/).find((line) => /^watcher: FAILED/.test(line));
  if (failed) return { kind: "failure", message: failed };
  if (signal) {
    return {
      kind: "failure",
      message: `watcher: FAILED - OMP extension arm child ended from ${signal}${combined ? `\n${combined}` : ""}`,
    };
  }
  if (code && code !== 0) {
    return {
      kind: "failure",
      message: `watcher: FAILED - fm-watch-arm.sh exited ${code}${combined ? `\n${combined}` : ""}`,
    };
  }
  return {
    kind: "failure",
    message: "watcher: FAILED - OMP extension arm cycle ended without an actionable reason",
  };
}

export default function (pi: ExtensionAPI) {
  function stopArm(): void {
    stopping = true;
    clearTimeout(retryTimer ?? undefined);
    retryTimer = null;
    if (child) child.kill("SIGTERM");
    child = null;
  }

  const cleanupOnProcessExit = () => {
    stopArm();
  };
  process.once("exit", cleanupOnProcessExit);

  async function sendWake(message: string): Promise<void> {
    await pi.sendUserMessage(
      `FIRSTMATE WATCHER WAKE: ${message}\n\nRun bin/fm-wake-drain.sh first and handle the queued wake, then resume OMP supervision. Watcher continuity is extension-owned; no manual re-arm is needed.`,
      { deliverAs: "followUp" },
    );
  }

  function surfaceFailure(message: string): void {
    void sendWake(message).catch(() => {
      // OMP owns delivery errors; continuity restoration never waits on prompting.
    });
  }

  function retryDelay(attempt: number): number {
    return Math.min(retryMaxMs, retryBaseMs * 2 ** Math.max(0, attempt - 1));
  }

  function waitForRetry(attempt: number): Promise<void> {
    const { promise, resolve } = Promise.withResolvers<void>();
    const timer = setTimeout(() => resolve(), retryDelay(attempt));
    timer.unref();
    return promise;
  }

  function waitForReadiness(armChild: ChildProcess): Promise<boolean> {
    const readiness = armReadiness.get(armChild);
    if (!readiness) return Promise.resolve(false);
    const { promise, resolve } = Promise.withResolvers<boolean>();
    const timer = setTimeout(() => resolve(false), armReadyTimeoutMs);
    timer.unref();
    void readiness.then((ready) => {
      clearTimeout(timer);
      resolve(ready);
    });
    return promise;
  }

  async function retireArm(armChild: ChildProcess | null): Promise<boolean> {
    if (!armChild) return true;
    armChild.kill("SIGTERM");
    const closed = armClose.get(armChild);
    if (!closed) return false;
    const { promise, resolve } = Promise.withResolvers<boolean>();
    const timer = setTimeout(() => resolve(false), armRetireTimeoutMs);
    timer.unref();
    void closed.then(() => {
      clearTimeout(timer);
      resolve(true);
    });
    return promise;
  }

  async function restoreAfterActionableClose(predecessorArmPid: string): Promise<string> {
    let failure = "";
    for (let attempt = 0; attempt <= retryLimit; attempt += 1) {
      if (stopping) return "";
      const replacement = startArm(predecessorArmPid);
      const successorChild = child;
      if (replacement.ok && successorChild && (await waitForReadiness(successorChild))) return "";
      if (replacement.ok) {
        failure = "watcher: FAILED - OMP extension could not verify a ready successor watcher";
        if (!(await retireArm(successorChild))) {
          return `${failure}\nwatcher: FAILED - OMP extension could not restore watcher continuity because the unready successor arm did not exit within ${armRetireTimeoutMs}ms`;
        }
      } else {
        failure = /(?:read-only|no live session)/.test(replacement.message)
          ? `watcher: FAILED - OMP extension cannot restore continuity because this session no longer owns the lock\n${replacement.message}`
          : `watcher: FAILED - OMP extension could not start the successor watcher cycle\n${replacement.message}`;
        if (/(?:read-only|no live session)/.test(replacement.message)) break;
      }
      if (attempt === retryLimit) break;
      await waitForRetry(attempt + 1);
    }
    return `${failure}\nwatcher: FAILED - OMP extension could not restore watcher continuity after ${retryLimit} retries`;
  }

  function scheduleRetry(message: string, predecessorArmPid: string): void {
    if (stopping || child || retryTimer) return;
    const ownership = lockOwnership();
    if (ownership !== "owned") {
      surfaceFailure(`watcher: FAILED - OMP extension cannot restore continuity because this session no longer owns the lock\n${message}`);
      return;
    }
    retryFailures += 1;
    if (retryFailures > retryLimit) {
      surfaceFailure(`watcher: FAILED - OMP extension could not restore watcher continuity after ${retryLimit} retries\n${message}`);
      return;
    }
    const timer = setTimeout(() => {
      if (retryTimer === timer) retryTimer = null;
      const result = startArm(predecessorArmPid);
      if (!result.ok) {
        surfaceFailure(`watcher: FAILED - OMP extension could not launch a continuity retry\n${result.message}`);
      }
    }, retryDelay(retryFailures));
    timer.unref();
    retryTimer = timer;
  }

  function startArm(predecessorArmPid = ""): ArmResult {
    if (stopping) return { ok: false, message: "watcher: not armed - OMP session is shutting down" };
    const ownership = lockOwnership();
    if (ownership === "other") return { ok: false, message: "watcher: read-only - session lock is held by another firstmate session" };
    if (ownership === "missing") {
      return {
        ok: false,
        message: "watcher: not armed - no live session holds the lock; run bin/fm-session-start.sh to reclaim it, then call fm_watch_arm_omp to re-arm",
      };
    }
    markLoaded();
    if (child) return { ok: true, message: "watcher: healthy - OMP extension already has an arm child" };
    if (retryTimer) return { ok: true, message: "watcher: continuity retry already scheduled by the OMP extension" };
    const id = ++seq;
    const env = {
      ...process.env,
      FM_HOME: fmHome,
      FM_ROOT_OVERRIDE: fmRoot,
      FM_CONFIG_OVERRIDE: config,
      FM_WATCH_ARM_SCRIPT: armScript,
      FM_WATCH_PREDECESSOR_ARM_PID: predecessorArmPid,
    };
    const armChild = spawn("bash", ["-lc", "config_dir=\"${FM_CONFIG_OVERRIDE:-$FM_HOME/config}\"; [ -f \"$config_dir/x-mode.env\" ] && . \"$config_dir/x-mode.env\"; exec \"$FM_WATCH_ARM_SCRIPT\" --restart"], {
      cwd: fmRoot,
      env,
      stdio: ["ignore", "pipe", "pipe"],
    });
    child = armChild;
    let stdout = "";
    let stderr = "";
    let settled = false;
    let readinessSettled = false;
    const { promise: readiness, resolve: resolveReadiness } = Promise.withResolvers<boolean>();
    armReadiness.set(armChild, readiness);
    const { promise: closed, resolve: resolveClosed } = Promise.withResolvers<void>();
    armClose.set(armChild, closed);
    const settleReadiness = (ready: boolean): void => {
      if (readinessSettled) return;
      readinessSettled = true;
      resolveReadiness(ready);
    };
    armChild.stdout?.on("data", (chunk: Buffer) => {
      stdout += chunk.toString();
      if (armEstablishedPattern.test(`${stdout}\n${stderr}`)) settleReadiness(true);
    });
    armChild.stderr?.on("data", (chunk: Buffer) => {
      stderr += chunk.toString();
      if (armEstablishedPattern.test(`${stdout}\n${stderr}`)) settleReadiness(true);
    });
    armChild.on("close", (code: number | null, signal: NodeJS.Signals | null) => {
      if (settled) return;
      settled = true;
      resolveClosed();
      settleReadiness(false);
      if (child === armChild) child = null;
      if (stopping) return;
      const classification = classifyClose(stdout, stderr, code, signal);
      const predecessor = String(armChild.pid ?? "");
      if (classification.kind === "actionable") {
        retryFailures = 0;
        restoring = true;
        void (async () => {
          const failure = await restoreAfterActionableClose(predecessor);
          restoring = false;
          if (stopping) return;
          const message = failure ? `${classification.message}\n\n${failure}` : classification.message;
          await sendWake(message);
        })().catch(() => {
          // OMP owns delivery errors; fail open so the extension never wedges the session.
        });
        return;
      }
      if (restoring) return;
      scheduleRetry(classification.message, predecessor);
    });
    armChild.on("error", (error: Error) => {
      if (settled) return;
      settled = true;
      resolveClosed();
      settleReadiness(false);
      if (child === armChild) child = null;
      if (stopping) return;
      if (restoring) return;
      scheduleRetry(`watcher: FAILED - OMP extension arm child ${id} failed: ${error.message}`, String(armChild.pid ?? ""));
    });
    return { ok: true, message: `watcher: started OMP extension arm child ${id}` };
  }

  pi.on?.("session_start", () => {
    markLoaded();
  });
  pi.on?.("session_shutdown", () => {
    stopArm();
    process.off("exit", cleanupOnProcessExit);
  });

  pi.registerCommand?.("fm-watch-arm-omp", {
    description: "Arm firstmate watcher supervision through the OMP extension instead of foreground bash.",
    handler: async (_args, ctx) => {
      const result = startArm();
      ctx.ui.notify(result.message, result.ok ? "info" : "warning");
    },
  });

  // The command above is the primary arm path. The tool mirrors it for tool-driven
  // arming. OMP's ToolDefinition has no promptSnippet/promptGuidelines fields
  // (Pi 0.80.5-only), so they are omitted, and the schema uses pi.zod (OMP-canonical)
  // rather than Pi's typebox Type.Object({}). Guarded so an OMP-specific schema or
  // registration difference can never break the watcher extension load.
  try {
    pi.registerTool?.({
      name: "fm_watch_arm_omp",
      label: "Arm firstmate watcher",
      description: "Arm OMP watcher supervision. Always use this tool instead of running bin/fm-watch-arm.sh through bash.",
      parameters: pi.zod.object({}),
      execute: async () => {
        const result = startArm();
        return {
          content: [{ type: "text", text: result.message }],
          details: result,
        };
      },
    });
  } catch {
    // Optional tool; the /fm-watch-arm-omp command remains available.
  }

  markLoaded();
}
