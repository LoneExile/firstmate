# Primary turn-end supervision guard

This is the authoritative contract for the "no turn ends blind" primary guard referenced from AGENTS.md section 8.
The shared predicate lives in `bin/fm-turnend-guard.sh`.
Its primary-checkout scope lives in `bin/fm-primary-scope-lib.sh`, shared with the native session-start nudge documented in `docs/sessionstart-nudge.md`.
The omp turn-end extension adapts OMP's real turn-end mechanism to that shared predicate.
Two related but separate PreToolUse seatbelts deny a bad command shape before it runs rather than detecting a blind turn end afterward: the watcher-arm seatbelt (`bin/fm-arm-pretool-check.sh`, `docs/arm-pretool-check.md`) and the cd-guard (`bin/fm-cd-pretool-check.sh`, `docs/cd-guard.md`).
Each seatbelt's own document defines its scope; they do not share the turn-end guard's marker-aware primary detection.

## Gap Closed

`bin/fm-guard.sh` is pull-based: it warns whenever some other supervision script happens to run, and prints nothing otherwise.
The primary can otherwise end a turn after handling wakes without resuming supervision, then sit blind until another fleet command happens to run.
On 2026-07-04, that exact gap left a parked no-mistakes gate unwatched for about nine hours.

`bin/fm-turnend-guard.sh` closes the gap by checking the primary's own turn-end path.
When tasks are in flight and there is no live identity-matched watcher with a fresh beacon, the omp turn-end extension forces one bounded follow-up turn that tells the primary to repair the missing or failed watcher cycle using the recovery instruction in its emitted session-start protocol.

## Shared Predicate

The guard first calls the shared primary scope (`bin/fm-primary-scope-lib.sh`) to constrain itself to a real primary checkout.
A secondmate home runs its own primary firstmate session, so a genuine `.fm-secondmate-home` marker force-includes it whether treehouse leased it as a linked worktree or it is a git-cloned plain checkout.
The marker must be a regular non-symlink file whose first line, after all whitespace is removed, contains a non-empty identifier made only of letters, digits, dots, underscores, and dashes.
An unmarked checkout, or one with an invalid marker, falls through to the git-dir check.
That check keeps crewmate and scout worktrees inert because firstmate provisions them as linked git worktrees, where `git rev-parse --git-dir` differs from `git rev-parse --git-common-dir`.
It also requires `AGENTS.md`, `bin/`, and the effective state directory to exist.

For an in-scope primary checkout, it counts in-flight work from `state/*.meta`.
If no task is in flight, it exits silently.
If work is in flight, it requires `fm_watcher_healthy <state-dir> <watch-path> [grace-seconds] [home]` from `bin/fm-wake-lib.sh`.
That is the same identity-matched live lock and fresh beacon check used by `bin/fm-watch-arm.sh`.
A stale beacon blocks even if a watcher pid is still live.
A fresh leftover beacon blocks if the watcher lock is missing, dead, or identity-mismatched.

`FM_STATE_OVERRIDE` wins over `FM_HOME/state`, and `FM_HOME` wins over repo-root `state/`.
`FM_GUARD_GRACE` controls the beacon freshness window and defaults to 300 seconds.
If `jq` is missing or hook stdin is empty, the guard fails open and exits 0 because it cannot safely read loop-guard fields.

## OMP Integration

`-` `omp`: `.omp/extensions/fm-primary-turnend-guard.ts` listens for `turn_end` (OMP has no `agent_settled` event), marks the extension version loaded for session-start checks, runs the shared guard, and uses `pi.sendUserMessage(..., { deliverAs: "followUp" })` to force one follow-up prompt when the guard returns 2.
Because `turn_end` fires per turn (not per logical run), it re-nags on each blind turn until supervision is armed.
The extension provides its own in-process loop guard so the forced follow-up does not recursively schedule another follow-up.
If the extension cannot deliver the follow-up, it fails open and relies on the pull-based `fm-guard.sh` warning at the next fleet command.
That warning uses `bin/fm-supervision-instructions.sh --repair-line`, so it points back to the omp protocol.

VERIFIED 2026-07-10 by `tests/fm-omp-primary-live-e2e.test.sh` (guard fired, watcher armed + re-armed after a wake, clean `/quit` reaped both children).

### 2026-07-12: secondmate-home enablement and the autonomous background-notify wake

The guard originally early-exited in every secondmate home on the `.fm-secondmate-home` marker.
That was a scoping choice inherited from the guard's primary-only origin, not a defense against any secondmate-specific hazard.
A genuinely marked secondmate home is now force-included as a guarded primary regardless of whether it is a treehouse-leased linked worktree or a git-cloned plain checkout.
Only unmarked child worktrees fall through to the linked-worktree exemption, and marker validation prevents an empty, malformed, or symlink marker from spoofing inclusion.

"No turn ends blind" for a secondmate is delivered by the same two mechanisms the main primary relies on.
Mechanism B, the turn-end backstop, is this guard; its secondmate-home behavior is covered by hermetic tests in `tests/fm-turnend-guard.test.sh` (`test_hook_blocks_in_secondmate_own_home`, `test_hook_blocks_in_treehouse_leased_secondmate_home`, `test_hook_silent_in_idle_secondmate_home`, `test_hook_secondmate_loop_guard_allows_retry`, `test_hook_secondmate_reinvoke_recovery_loop`, `test_hook_silent_in_secondmate_child_worktree`, and `test_hook_exempts_linked_worktree_with_stray_marker`).
Mechanism A, the autonomous wake, is a harness property; the emitted supervision protocol owns whether the model or the omp extension continues the watcher cycle after delivering that wake.
Mechanism A cannot be a hermetic CI assertion because it requires a live model session, so it is recorded here as a dated first-hand measurement while `test_hook_secondmate_reinvoke_recovery_loop` covers the guard's deterministic half of the same recovery loop.

Autonomous-re-invoke measurement, run first-hand on Claude Code 2.1.207 (Darwin 25.5.0) on 2026-07-12.
Procedure: launch a detached `run_in_background` Bash task that models a one-shot watcher - it records a launch epoch, runs `sleep 25`, then records a completion epoch just before exit, writing only to the session scratchpad - then end the turn with no further tool calls and no pending question, a genuinely idle session with no human input.
Observed marker timestamps:

```
launch_epoch    = 1783890980   (14:16:20)   turn ends, session goes idle
complete_epoch  = 1783891005   (14:16:45)   background task exits, 25s idle
reinvoke_epoch  = 1783891016   (14:16:56)   MODEL RE-INVOKED
--------------------------------------------------------------
wake latency (task complete -> model re-invoked): 11s, with ZERO human input
```

The re-invocation arrived as a `<task-notification>` whose accompanying system notice stated verbatim "No human input has been received since the last genuine user message in this conversation".
So the model was re-invoked solely by the background task's completion while idle, which is Mechanism A - the same background-notify wake the omp supervision protocol relies on for the main primary.
This matches the harness tool contract that a `run_in_background` task "keeps running across turns and re-invokes you when it exits", and reproduces the 11s latency the task audit measured independently on the same harness version.
No Herdr command was issued and no fleet state was touched; the experiment wrote only to the session scratchpad, which was discarded.

## Tests

`tests/fm-turnend-guard.test.sh` covers the shared predicate, primary scoping (including a secondmate's own home being guarded like the main primary while its child worktrees stay exempt), `FM_HOME` and `FM_STATE_OVERRIDE` precedence, fail-open behavior without `jq`, and the omp extension's loop-guard behavior.
The omp extension is typechecked by `tests/fm-omp-primary-types.test.sh` and exercised by the opt-in live e2e below.
The default behavior suite does not invoke live language-model harnesses.
`FM_OMP_LIVE_E2E=1 tests/fm-omp-primary-live-e2e.test.sh` opts into the isolated interactive OMP regression recorded above.
