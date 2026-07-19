# Native session-start nudge

AGENTS.md section 3 remains the single authoritative behavioral contract for session start.
The tracked omp adapter is an enforcement layer that injects one instruction and never runs the digest, lock acquisition, bootstrap sweeps, wake drain, or supervision arm itself.
The injected line is exactly ``Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions.``

## Shared wrapper and safety

`bin/fm-sessionstart-nudge.sh` is the command the omp adapter invokes.
It sources `bin/fm-gate-refuse-lib.sh` and stays silent for a no-mistakes gate agent identified by `NO_MISTAKES_GATE` or a `.no-mistakes/repos/*.git` git-common-dir.
It shares `bin/fm-primary-scope-lib.sh` with `bin/fm-turnend-guard.sh`, so the two hooks cannot drift on primary detection.
The Shared Predicate section of `docs/turnend-guard.md` remains authoritative for marker validation, plain-checkout detection, and the required firstmate-shaped paths.

Before printing, the wrapper reads `state/.lock` and walks at most eight parents from its own pid, matching `bin/fm-lock.sh` and the extension's `lockOwnership()` ancestry depth.
If the lock names a live pid in that ancestry, session-start already ran in this harness session and the wrapper stays silent.
Every path exits 0, so a nudge failure can never block session initialization.

## omp transport

The omp primary loads `.omp/extensions/fm-primary-turnend-guard.ts`, which also owns the turn-end guard and the PreToolUse seatbelts.
On the omp `session_start` event it runs the wrapper and, when the wrapper prints, injects the line with `pi.sendMessage({ customType: "firstmate-sessionstart-nudge", content, display: false })`.
`sendMessage` (not `sendUserMessage`) enters model context as a hidden custom message that the first normal prompt consumes, so it never races the launch prompt with an "Agent is already processing" error.
Unlike Pi's adapter, omp does not gate on a session-start reason: omp's `SessionStartEvent` carries no reason and fires only on initial session load, so the wrapper's own lock-in-ancestry check provides the fire-once-per-session idempotency.

## Regression coverage

`tests/fm-sessionstart-nudge.test.sh` proves wrapper silence for both gate signals, an unmarked linked worktree, a missing state directory, and an already-owned lock, and exact one-line output for a plain primary and a marked linked secondmate primary.
It also drives the real omp extension's `session_start` handler with a fake `pi` to prove it delivers exactly one hidden `firstmate-sessionstart-nudge` message carrying the wrapper line.
