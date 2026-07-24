# tmux runtime backend

tmux is a first-class, fully supported session backend and the fully verified baseline for secondmate support.
This is the setup guide; for the shared runtime-backend abstraction and selection order, see [`docs/architecture.md`](architecture.md) ("Runtime session backends") and [`docs/configuration.md`](configuration.md) ("Runtime backend").

## What it is and when to pick it

tmux is a terminal multiplexer.
Firstmate gives each crewmate its own tmux window inside a session, so you can attach and watch a task work, or type into its window to intervene directly.
Pick tmux as the explicit opt-in alternative to herdr - the first-class default - or when you prefer tmux's familiar window model over herdr's native agent-state detection. tmux is the fully verified baseline for secondmate homes; Orca and cmux do not support secondmate spawns.

## Prerequisites

- tmux itself: `brew install tmux` (or your platform's package manager).
- The universal firstmate prerequisites: a verified crew harness plus the required toolchain, detected at session start and installed only after you approve; [`docs/configuration.md`](configuration.md) owns both lists ("Harness support", "Toolchain").

## Selecting it

Select tmux by putting `tmux` in a local `config/backend` file - the durable way to pick it - or by exporting `FM_BACKEND=tmux` when you launch your harness for a one-off session; telling the first mate in chat to use tmux also works.
tmux is also resolved by runtime auto-detection when `$TMUX` is set (firstmate running inside an existing tmux session), and absent `backend=` in a task's meta still means `tmux` for legacy compatibility.
Explicit tmux selection is the recommended way to opt out of herdr (the default when no runtime marker is present) or cmux runtime auto-detection (see [`docs/herdr-backend.md`](herdr-backend.md) and [`docs/cmux-backend.md`](cmux-backend.md)).

## First run

Nothing to provision up front.
The first crewmate spawn creates whatever tmux session and window it needs.

## Run inside tmux for the best experience

Launch your harness from inside a tmux session (`tmux new -s firstmate` or similar, then start your agent).
Every crewmate window then lands in that same session, where you can watch the crew work in real time or type into any window to intervene.
When following the commands below, use that session's actual name.
Inside tmux, `tmux display-message -p '#S'` prints it.

## Outside tmux: the detached `firstmate` session

If you launch your harness outside of tmux, crewmate windows land in a detached session named `firstmate`, created on first use.
Attach to it any time with:

```sh
tmux attach -t firstmate
```

## Watching and typing into crew windows

Once attached, each crewmate is its own window named `fm-<id>`:

```sh
tmux list-windows -t <session-name>          # see every crew window
tmux select-window -t <session-name>:fm-<id> # jump to one, or use ctrl-b <n>
```

Use the current tmux session name when firstmate was launched inside tmux; use `firstmate` only for the detached outside-tmux path.
Typing directly into an attached window is authoritative direct intervention - the first mate treats it the same as any other captain instruction and reconciles at the next heartbeat.
You do not need to attach at all for routine supervision: from an active firstmate session, the first mate reads crew windows itself with `bin/fm-peek.sh fm-<id>` (a bounded, read-only capture) and steers a crew with `FM_HOME=<this-firstmate-home> bin/fm-send.sh fm-<id> "<text>"` unless `FM_HOME` is already set to the active firstmate home.

## Verifying it works

Ask the first mate for any small piece of work, or spawn a trivial scout task, and confirm a new window shows up:

```sh
tmux list-windows -t <session-name>
```

Use the current tmux session name for the run-inside-tmux path, or `firstmate` for the detached outside-tmux path.
You should see a `fm-<id>` window for the task, live and updating as the crewmate works.

## Agent liveness probe

`fm_backend_target_exists` (`bin/fm-backend.sh`) only checks that a window's pane still exists.
A secondmate agent that exits leaves its pane alive as a bare idle shell, which passes that check as "alive" - the gap `bin/fm-bootstrap.sh`'s session-start secondmate-liveness sweep exists to close (evidence 2026-07-07: every secondmate in one fleet was found sitting at a dead `zsh` shell, invisible to that check).

`fm_backend_tmux_agent_state` (`bin/backends/tmux.sh`) answers a deeper question: is a real harness-agent *process* running in the pane right now, or is the recorded endpoint authoritatively missing?
It reads tmux's own `#{pane_current_command}`, which reports the pane's live foreground process name - already resolved by tmux from the pty's controlling process group, not something this adapter derives itself.

Agent liveness and composer safety are separate checks.
During away-mode escalation delivery, `fm_tmux_composer_state` sends a bare shell glyph on an unbordered row to the shared composer classifier as `unknown`, and the daemon injects only into an affirmatively `empty` composer; see [Composer-emptiness safety](herdr-backend.md#composer-emptiness-safety-2026-07-10-fleet-wide-across-all-four-backends).

Verified empirically with real tmux 3.6a on macOS (Darwin 25.5.0), 2026-07-07:

```sh
$ tmux new-session -d -s fmtest -n testwin
$ tmux display-message -p -t fmtest:testwin '#{pane_current_command}'
zsh
$ tmux send-keys -t fmtest:testwin 'sleep 30' Enter
$ tmux display-message -p -t fmtest:testwin '#{pane_current_command}'
sleep
$ tmux send-keys -t fmtest:testwin C-c
$ tmux display-message -p -t fmtest:testwin '#{pane_current_command}'
zsh
```

An idle pane reports the shell's own name; a live foreground process reports its own name; the pane reverts to the shell's name the moment that process exits - exactly the alive/dead signal the probe needs.

A second case matters for a harness that shells out to subcommands while it runs (git, npm, no-mistakes, ...): does `pane_current_command` report the harness or the subcommand?
Verified the same session: a persisting parent process running a child command (`bash -c 'echo start; sleep 30; echo end'`, where the parent bash stays alive waiting on its own child) reports the PARENT's own name (`bash`) throughout, not the child's (`sleep`) - so a harness that survives while it shells out stays correctly classified as alive.
(A single-simple-command `bash -c "sleep 30"` is a different, unrelated case: bash execs directly into `sleep`, replacing itself, so the reported name changes because the process itself became `sleep` - not because tmux "saw through" to a child.)

The recovery classifier (`fm_backend_tmux_agent_state`) maps the observation to the shared detailed state owned by `fm_backend_agent_state` in `bin/fm-backend.sh`.
A recognized harness is `alive`, a bare shell is `dead`, and an unrecognized foreground process is `ambiguous`.
The classifier checks exact window-name membership in a readable session inventory before trusting `display-message`, because tmux silently redirects a missing named target to the active window.
It returns `missing` when `tmux list-windows` successfully reads the recorded session and omits the exact recorded window, or when tmux definitively reports that the recorded session or server is absent.
Any other failed inventory or pane read is `unreadable` and never authorizes recovery.
`fm_backend_tmux_agent_alive` remains the compatibility view that maps these detailed states back to `alive`, `dead`, or `unknown` for callers that do not need the reason.

Verified with real tmux 3.6a on macOS (Darwin 25.5.0), 2026-07-23, using the private `-L fm-target-check-<pid>` socket also exercised by `tests/fm-backend-tmux-smoke.test.sh`:

```sh
$ tmux -L "$socket" kill-window -t smoke:fm-smoke1
$ tmux -L "$socket" display-message -p -t smoke:fm-smoke1 '#{window_name}:#{pane_current_command}'
main:zsh
$ tmux -L "$socket" list-windows -t smoke -F '#{window_name}'
main
$ fm_backend_agent_state tmux smoke:fm-smoke1
missing
```

The first post-kill command exits 0 and reports the unrelated active `main` window, which is the earliest meaningful divergence that made process-only liveness inconclusive for missing omp windows.
The exact inventory check prevents that fallback from masquerading as an existing ambiguous process, while an unreadable inventory still preserves duplicate prevention.

### Known gap: `omp` cannot be confidently classified

`omp` (Oh My Pi) runs under the `bun` interpreter (the same ancestry fact `bin/fm-lock.sh` uses, matching omp in a `bun`/`node`/`python` process's args rather than by its own `comm`), so a live omp pane reports a bare interpreter name.
Confirmed 2026-07-17 by launching `omp` in a live tmux pane: `#{pane_current_command}` reads `bun`, and the pane's foreground child is `bun /Users/lex/.bun/bin/omp` (`bun` is a generic interpreter name that cannot be added to the `alive` set without misclassifying unrelated `bun` processes); omp's busy-state regex is tracked separately and still pending a tmux-backend live-pane run.
The classifier deliberately reports `ambiguous` for an existing bare-interpreter process (`bun`/`node`/`python`/`python3`) rather than guess - per the secondmate-liveness sweep's correctness bar, a wrong `alive` is harmless but a wrong `dead` spins up a duplicate agent, so an unresolvable existing process must never be treated as confidently dead.
Practical effect: an existing omp secondmate pane that reports `bun` is never auto-healed, preserving duplicate prevention.
A recorded omp secondmate window that is authoritatively absent is different: no process exists to misattribute, so the corroborated `missing` state safely relaunches it at session start.
Classifying an existing omp process more precisely would still need either an omp-specific marker inspectable from outside the process or accepting fragile argument inspection, neither of which this recovery path does.

## Limitations

None specific to tmux as a first-class alternative - it is fully verified for the secondmate path, while Orca and cmux are the backends without secondmate support.
The agent-liveness probe above retains one known gap for an existing omp process (`bun`, see above); authoritatively absent omp windows are covered.
