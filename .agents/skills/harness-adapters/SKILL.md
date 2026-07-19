---
name: harness-adapters
description: Agent-only reference for firstmate harness operations. Use before spawning or recovering a crewmate or secondmate, handling a trust dialog, sending a harness-specific skill invocation, interrupting or exiting an agent, resuming an exited agent, or verifying the omp adapter. Contains verified facts for omp (Oh My Pi), the sole supported harness.
user-invocable: false
metadata:
  internal: true
---

# harness-adapters

Use this reference before any harness-specific firstmate operation: spawn, recovery, trust-dialog handling, skill invocation, interrupt, exit, resume, or adapter verification.

Firstmate runs exclusively on the `omp` harness; all crewmates and secondmates also run on omp.
`config/secondmate-harness` may carry optional model and effort tokens for the secondmate on the same line (format `omp [<model>] [<effort>]`); the harness token is always omp and only the model and effort tokens parametrize the secondmate.

Each adapter splits into mechanics and knowledge.
The per-task mechanics, including launch command, autonomy flag, and crewmate turn-end hook, live in `bin/fm-spawn.sh`.
The primary-session "no turn ends blind" guard contract and harness hook installation paths live in `docs/turnend-guard.md`.
The primary-session watcher wake protocols are rendered from `docs/supervision-protocols/` by `bin/fm-supervision-instructions.sh`.
The supervision knowledge lives here: busy signature, exit command, interrupt, dialogs, resume behavior, skill invocation, and quirks.

## Detection

`bin/fm-harness.sh` prints firstmate's own harness (always `omp`).
`bin/fm-harness.sh crew` resolves the effective crewmate harness (always `omp`).
`bin/fm-harness.sh secondmate` resolves the secondmate-launch harness (always `omp`).
`bin/fm-harness.sh secondmate-model` and `bin/fm-harness.sh secondmate-effort` expose the optional tokens from `config/secondmate-harness`.
`bin/fm-spawn.sh` uses these on every spawn so the resolution is durable across respawns.

For stuck recovery, the target window's harness is recorded as `harness=` in `state/<id>.meta`.
Use that value for interrupt, exit, resume, and skill-invocation facts.

## Primary turn-end guard

The omp primary's turn-end guard AND PreToolUse seatbelt both live in `.omp/extensions/fm-primary-turnend-guard.ts`.
It listens for `turn_end` (omp has no `agent_settled` event) and uses `pi.sendUserMessage(..., { deliverAs: "followUp" })` to force one guarded follow-up when `bin/fm-turnend-guard.sh` returns 2.
The seatbelt returns `{ block: true }` from the `tool_call` handler when `bin/fm-arm-pretool-check.sh` denies a bash command.
The `guardFollowupActive` one-shot skip suppresses the guard on its own injected follow-up turn, re-nagging on each subsequent blind turn until supervision is armed.
The exact hook files, commands, validation transcripts, scoping rules, and fail-open tradeoffs are owned by `docs/turnend-guard.md`.
When changing any primary turn-end hook, validate the real harness behavior in a scratch project or throwaway home before trusting it, then update that doc.

## Primary pre-arm (PreToolUse) seatbelt

The omp seatbelt is wired into `.omp/extensions/fm-primary-turnend-guard.ts`: returning `{block: true}` from the `tool_call` handler denies a watcher-arm anti-pattern (shell `&`, truncating pipe, bundling, broad `pkill -f fm-watch`) before it runs.
The exact hook files, commands, and validation transcripts are owned by `docs/arm-pretool-check.md`.
When changing any primary PreToolUse hook, validate the real harness behavior in a scratch project before trusting it, then update that doc.

## Primary session-start nudge

AGENTS.md section 3 remains the behavioral owner for session start, while the tracked omp adapter invokes `bin/fm-sessionstart-nudge.sh` as an idempotent enforcement layer.
The wrapper prints only the instruction to run `bin/fm-session-start.sh`; it never runs the digest, wake drain, bootstrap sweeps, lock, or supervision arm itself.
Full mechanics, scoping, and fail-open behavior live in `docs/sessionstart-nudge.md`.

- omp: on the `session_start` event `.omp/extensions/fm-primary-turnend-guard.ts` runs the wrapper and, when it prints, injects the line with `pi.sendMessage({ customType: "firstmate-sessionstart-nudge", display: false })` so it enters model context without racing the launch prompt; omp's `session_start` carries no reason, so the wrapper's lock-in-ancestry check provides fire-once idempotency.

## Primary watcher supervision

At session start, `bin/fm-session-start.sh` prints the omp watcher supervision block.
omp (a Pi fork) uses the tracked `.omp/extensions/fm-primary-turnend-guard.ts` plus the tracked `.omp/extensions/fm-primary-omp-watch.ts`, both project-local extensions omp auto-discovers once trusted (omp scans `.omp/extensions/`, never `.pi/`).
When changing the primary watcher adapter, update `docs/supervision-protocols/omp.md` and `docs/turnend-guard.md` if a shared idle or turn-end hook changed.

## Launch profile axes

`bin/fm-spawn.sh` accepts concrete `--model` and `--effort` values chosen by firstmate at intake.

Effort precedence is an explicit per-task captain instruction first, then any applicable standing secondmate pin, then the generic fallback below.
Never replace an effort value supplied by either higher-precedence source.
Use the fallback only when neither the captain nor applicable standing configuration specifies effort.
Use `low` for well-understood work with an explicit bounded path and `xhigh` for ambiguous investigation or design.
Choose intermediate levels proportionally as complexity, uncertainty, blast radius, or open-ended reasoning increases.
When `xhigh` is requested but the harness does not support it, cap at the highest supported non-`max` level rather than omitting the intended effort silently.
Never select `max` from this fallback; use it only when the captain has explicitly expressed that per-task or standing preference.

The supported launch-profile flags below are verified locally; the row records its evidence.

| Harness | Model flag | Effort flag | Notes |
|---|---|---|---|
| omp | `--model <model>` | `--thinking <low\|medium\|high\|xhigh>` | Verified live 2026-07-10 (omp v16.3.15). omp is a Pi fork: `--thinking` also accepts `off\|minimal\|auto` but not `max` (omit it), `--auto-approve` grants autonomy, `-e/--extension` loads the turn-end/watch supervisors. |

When a requested effort value is outside the accepted set, `fm-spawn` records the requested `effort=` in meta but emits no effort flag.
This preserves launch success instead of passing a known-bad value.

## no-mistakes skill invocation

Send the validation skill using omp's skill invocation form.

- omp: `/no-mistakes` (omp supports slash-command skills, like claude); the skill must be discoverable by omp (a scope omp reads, e.g. `~/.omp/agent/skills/` or the project `.claude/skills/`).

Natural language is acceptable if the exact skill command is uncertain.

## omp (VERIFIED 2026-07-10, omp v16.3.15)

omp (Oh My Pi, https://omp.sh) is a Pi fork with a Pi-compatible extension API (`turn_end` / `tool_call` events, `{block:true}` from `tool_call`, `pi.sendUserMessage(..., { deliverAs: "followUp" })`). Live-verified 2026-07-10 (see the validation record below): detection, extension load, the turn-end guard + watcher re-arm loop, and crew dispatch on omp are all confirmed on a real session. A few narrow items remain unexercised and are flagged inline (seatbelt deny, tmux-backend busy signature, exit/interrupt keys).

| Fact | Value |
|---|---|
| Env marker | `OMPCODE=1` (omp also sets `CLAUDECODE=1`; `fm-harness.sh` checks `OMPCODE` first) |
| Busy-pane signature | herdr backend: native busy-state verified working 2026-07-10. tmux backend: `Working...`/`Working…` / `esc to interrupt` regex still PENDING a tmux-backend run; override with `FM_BUSY_REGEX` / `FM_COMPOSER_IDLE_RE` |
| Exit command | `/quit` - VERIFIED 2026-07-10 by `tests/fm-omp-primary-live-e2e.test.sh` (clean `OMP_EXIT=0`; watcher + arm children reaped on exit) |
| Interrupt | single Escape (not exercised by the e2e) |
| Skill invocation | `/<skill>` (e.g. `/no-mistakes`) |
| Autonomy | `--auto-approve` (omp HAS an approval system; fm-spawn passes it for crewmates - verified live 2026-07-10: two crewmates ran unattended and shipped PRs) |

omp is claude-compatible (sets `CLAUDECODE=1`) but does NOT implement Claude Code's `.claude/settings.json` `Stop`/`PreToolUse` event-hook contract - it uses its own `.omp/extensions/` runtime instead. Detection must resolve `omp`, not `claude`: a claude-detected omp session would install `.claude/settings.json` Stop/PreToolUse hooks that omp never fires, silently disabling supervision.

Project trust dialog can appear on the first omp run in any not-yet-trusted directory.
Accept with Enter.
The decision persists per path in omp's trust store, so later spawns in the same worktree slot skip it.

**Primary-session guard (VERIFIED live 2026-07-10).**
The primary's turn-end guard AND PreToolUse seatbelt both live in `.omp/extensions/fm-primary-turnend-guard.ts`. It listens for `turn_end` because OMP has no `agent_settled` event. The `guardFollowupActive` one-shot skip suppresses the guard on its OWN injected follow-up turn and re-nags on each subsequent blind turn until supervision is armed (the live e2e saw 3 injections before the model armed the watcher). On block it `await`s `pi.sendUserMessage(..., { deliverAs: "followUp" })` when `bin/fm-turnend-guard.sh` returns 2. The seatbelt returns `{ block: true }` from the `tool_call` handler when `bin/fm-arm-pretool-check.sh` denies a bash command.

**Primary watcher (VERIFIED live 2026-07-10).**
`.omp/extensions/fm-primary-omp-watch.ts` registers the `fm_watch_arm_omp` tool (primary path, called instead of a foreground bash arm) plus the `/fm-watch-arm-omp` command as a human fallback (the command notifies via `ctx.ui.notify`). Arming spawns `bin/fm-watch-arm.sh --restart` attached to the live omp process and sends a follow-up wake when the child exits with an actionable reason; a one-shot `process.once("exit")` listener (lifecycle fix #397) plus `session_shutdown` stop the arm child on exit. `bin/fm-session-start.sh` reports when the running omp session has not loaded both extensions (markers `state/.omp-turnend-extension-loaded` and `state/.omp-watch-extension-loaded`). Both are project-local `.omp/extensions/*.ts` files omp auto-discovers once the project is trusted (approve trust once per clone, or launch with `-e` as the trust-free fallback). The tool schema uses `pi.zod.object({})` (OMP-canonical), and OMP's ToolDefinition has no `promptSnippet`/`promptGuidelines` fields.

**Live validation record, 2026-07-10 (omp v16.3.15, herdr backend).**
A fresh `omp` in the firstmate home became the first mate (root `AGENTS.md` loaded via the `agents-md` provider), `bin/fm-harness.sh` and `bin/fm-lock.sh` both detected `omp`, and both `.omp/extensions/` loaded (markers written). It dispatched two crewmates (`fm-webull-broker-w7`, `fm-finnhub-free-f3`) - each a real omp session in its own treehouse worktree, running autonomously under `--auto-approve` - which shipped two green PRs. The turn-end guard fired on a real multi-turn primary ("TURN WOULD END BLIND ... 2 task(s) in flight, but no live watcher holds this home lock") and the primary re-armed the watcher (alive) instead of ending blind.

**Automated live E2E, 2026-07-10 (omp v16.4.0, tmux).**
`tests/fm-omp-primary-live-e2e.test.sh` (opt-in, `FM_OMP_LIVE_E2E=1`) passes: it launches omp on a private tmux socket with the tracked extensions via `-e`, drives bash/read turns, triggers the turn-end guard, arms `fm_watch_arm_omp`, delivers a watcher wake, drains + re-arms, and asserts one-or-more guard injections (omp re-nags per blind turn), NO foreground `bin/fm-watch-arm.sh` arm, a live re-armed watcher pid, and a clean `/quit` (`OMP_EXIT=0`) that reaps both the watcher and arm children. It uses the default (already-authed) agent dir because a fresh `PI_CODING_AGENT_DIR` triggers omp's blocking first-run setup wizard. Still not exercised anywhere: a seatbelt `{block:true}` deny of an arm anti-pattern, the tmux busy-footer regex (`FM_BUSY_REGEX`), and the interrupt (Escape) key.
