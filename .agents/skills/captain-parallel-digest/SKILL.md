---
name: captain-parallel-digest
description: >-
  Agent-only reference for speeding up the captain's own turn when several analysis-heavy items pile up at once, by fanning their READ-ONLY analysis out to omp subagents and then serializing every decision on the captain.
  Use only on the omp harness, and only when two or more queued items each need real reading, reviewing, or scoping before the captain can act.
  Covers what may and may not be delegated to a subagent, the fan-out-then-serialize flow, and why authoritative actions and shared-state writes stay on the captain.
user-invocable: false
metadata:
  internal: true
---

# captain-parallel-digest

The captain is a single serialization point: it drains one wake queue in one turn-stream, and section 8 allows exactly one live supervision cycle.
When several analysis-heavy items land together - two finished scouts to read and relay, a couple of crew diffs to review, a new request that needs project investigation before a brief - reading and scoping them one after another is the slow part of the turn.
On the omp harness you can shorten that turn by running the read-only analysis in parallel through subagents, then making every real decision yourself, in order.
This is an omp-only capability because it relies on omp subagents (the `task` tool); it adds nothing on a harness without them.

This never makes the captain "parallel".
It parallelizes only the reading and drafting, and leaves the captain the single actor for everything that changes the world.

## When to use it

Use it inside a single wake-handling or intake turn when BOTH hold:

- The primary harness is omp.
- Two or more queued items each need genuine analysis before the captain can act - a finished scout report to digest, a crew diff or PR to review, or a new request to scope against the project and turn into a section 11 brief.

Do not reach for it for a single item, or for light items that need no analysis (a `done: PR ... green` wake is just `bin/fm-pr-check.sh` plus a one-line report).
A single scout subagent for one heavy item is fine; the parallel win only exists at two or more.

## What a subagent may do

Delegate only read-only analysis that returns text and touches no shared state.
Use the read-only `scout` agent for each, and give each one fully self-contained context, because a subagent starts blank with none of this turn's conversation:

- Digest a finished scout's `data/<id>/report.md` into the findings and recommendation to relay.
- Review a finished crew's diff or PR and return the concrete findings.
- Scope a new request: read the project, classify ship vs scout and dispatchable vs blocked, and draft the section 11 brief text.
- Any investigation whose product is knowledge, not a change.

## What stays on the captain, always

Never let a subagent take an authoritative or state-changing action.
omp subagents share the captain's filesystem and home, so a writing subagent can violate hard rule 1 (never write to a project) or race another on shared state, and parallel decisions conflict (double dispatch, double merge).
The captain performs all of the following itself, serially, after collecting subagent results:

- Spawning or steering crew (`bin/fm-spawn.sh`, `bin/fm-send.sh`).
- Merging, landing, or tearing down (`bin/fm-pr-merge.sh`, `bin/fm-merge-local.sh`, `bin/fm-teardown.sh`).
- Resolving or routing decision-holds, ask-user findings, and any approval.
- Writing shared state: `data/backlog.md`, `data/secondmates.md`, task meta, anything under `state/` or `config/`.
- The single live supervision cycle; a subagent never runs supervision and never opens a second cycle.

## Flow

1. In one turn, list the piled-up analysis-heavy items.
2. Fan out one read-only scout subagent per item, each carrying its own complete context and a clear "return this" instruction.
3. Collect every result.
4. Then act serially as the captain: relay outcomes, dispatch, merge, and write state in a safe order, exactly as the task lifecycle and supervision protocol require.
5. Resume the single supervision cycle as the final action of the turn, per section 8.

## Relationship to the rest of the fleet

Crew and scouts already parallelize project work as separate omp sessions in isolated worktrees.
A secondmate delegates a whole scoped sub-fleet under its own home.
This skill is narrower than both: it parallelizes only the captain's own read-only analysis within a single turn, and changes nothing about who is allowed to act.
