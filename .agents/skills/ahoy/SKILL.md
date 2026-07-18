---
name: ahoy
description: Summon the Quartermaster, an interactive companion pane the human can talk to (brainstorm, plan, small scratch tasks) while the captain stays heads-down on the fleet. Use when the human invokes /ahoy (e.g. "/ahoy", "summon the quartermaster", "I want to brainstorm/plan"), or when a "Quartermaster set sail:" handoff message arrives.
user-invocable: true
metadata:
  internal: true
---

# ahoy

The Quartermaster is a human-facing companion, not a crew member.
A crewmate/scout is autonomous and a secondmate is an idle supervisor; the Quartermaster instead runs interactively so the human has someone to think out loud with while the captain keeps supervising the fleet.
It is summoned by the human, does no fleet work, and ends by handing a plan back to the captain and/or the backlog.

## Summon it

Run `bin/fm-ahoy.sh` (mechanics and flags in its `--help`).
It spawns ONE Quartermaster at a time in this home's herdr workspace, in a scratch home seeded with a companion charter, launched as a plain interactive omp the human drives.
Re-running while one is aboard refocuses it rather than spawning a second.
The summon is a quick, one-shot spawn, so the captain can do it between wakes without breaking supervision; the human then talks to the companion pane, not the captain.
The human may also run `bin/fm-ahoy.sh` directly from a shell, fully decoupled from the captain's turn.

Backend: herdr only for now (the default); other backends are refused loudly, and tmux/orca/zellij parity is a follow-up.

## The handoff back (/set-sail, /farewell)

The Quartermaster leaves via its own `set-sail` skill (seeded into its scratch home by `fm-ahoy.sh`, so `/set-sail` is a real command there): on `/set-sail` or `/farewell` it summarizes the decisions into a plan and runs `bin/fm-set-sail.sh`, which records the plan and, for a captain route, pings the captain, then retires the pane.
So the captain sees the result as an incoming `Quartermaster set sail:` message carrying `plan=<path>` (and `queued=<id>` when it was also backlogged).
Intake that message as ordinary work: read the plan file, then implement it now or leave it in the backlog exactly as the message says.
Nothing about the Quartermaster's own pane, scratch home, or marker is captain business - `fm-set-sail.sh` cleans all of it up.
