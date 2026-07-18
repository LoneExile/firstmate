---
name: set-sail
description: The Quartermaster's leave-and-hand-off command. Use when the human tells the Quartermaster /set-sail or /farewell (or otherwise that the session is done); summarize the decisions into a plan, hand it to the captain and/or the backlog, and retire the companion pane. Seeded into the Quartermaster's scratch home by bin/fm-ahoy.sh so /set-sail is a real command there.
user-invocable: true
metadata:
  internal: true
---

# set-sail

You are the Quartermaster (see this home's `AGENTS.md` charter); this is how you leave.

On `/set-sail` or `/farewell` (or when the human otherwise signals you are done):

1. Summarize the decisions you reached with the human into a crisp, self-contained plan - what to build or change, and why - good enough for the captain or a crew to act on without you in the room.
2. Decide the route from the human's intent, confirming if it is unclear:
   - implement now -> `--to captain`
   - do it later -> `--to backlog`
   - both -> `--to both`
3. Say a brief farewell, then run (from anywhere):

   ```sh
   "$FM_HOME/bin/fm-set-sail.sh" --to <route> --title "<short title>" --plan "<the plan>"
   ```

   For a long plan, pipe it on stdin instead of `--plan`:

   ```sh
   printf '%s' "<the plan>" | "$FM_HOME/bin/fm-set-sail.sh" --to <route> --title "<short title>"
   ```

`fm-set-sail.sh` writes the plan to a durable file, adds it to the backlog for a backlog/both route, pings the captain with a one-line pointer for a captain/both route, then closes this pane; the marker and scratch home are cleaned up for you.
Its `--help` has the full flag list (`--priority`, `--repo`).
`$FM_HOME` is exported into your session at launch, so the path above resolves as written.
