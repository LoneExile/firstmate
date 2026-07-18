#!/usr/bin/env bash
# fm-ahoy.sh - summon (or refocus) the Quartermaster: an interactive companion
# pane the human can talk to (brainstorm, plan, small scratch tasks) while the
# captain stays heads-down supervising the fleet. The Quartermaster is a new,
# human-driven role - not an autonomous crewmate/scout and not a supervisor
# secondmate. End a session with its own /set-sail (bin/fm-set-sail.sh), which
# hands the plan to the captain and/or the backlog and retires the pane.
#
# Usage: fm-ahoy.sh [--help]
#   Spawns ONE Quartermaster at a time in this home's herdr workspace, in a
#   scratch home (state/quartermaster-home/) seeded with a companion charter
#   (AGENTS.md), launched as a plain interactive omp the human drives. Re-running
#   while one is already aboard refocuses it instead of spawning a second (an
#   unreadable pane fails safe toward refocus, never a second spawn).
#
#   Captain handoff target: fm-ahoy records the captain's own pane
#   (discover_supervisor_target) so /set-sail can ping it. Run from a shell where
#   that cannot be resolved, the Quartermaster still works and /set-sail records
#   the plan to the backlog only.
#
#   Backend: herdr only for now (the default). Other backends are refused loudly;
#   tmux/orca/zellij parity is a follow-up.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

case "${1:-}" in
  -h|--help) grep '^#' "${BASH_SOURCE[0]}" | sed '1d;s/^# \{0,1\}//'; exit 0 ;;
  "") : ;;
  *) echo "ahoy: unexpected argument '$1' (see --help)" >&2; exit 2 ;;
esac

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-supervisor-target-lib.sh
. "$SCRIPT_DIR/fm-supervisor-target-lib.sh"

MARKER="$STATE/.quartermaster"
SCRATCH="$STATE/quartermaster-home"

# Resolve backend: explicit override, ambient detection, configured default, herdr.
BACKEND="${FM_BACKEND:-}"
[ -n "$BACKEND" ] || BACKEND="$(fm_backend_detect 2>/dev/null || true)"
[ -n "$BACKEND" ] || BACKEND="$(cat "$FM_HOME/config/backend" 2>/dev/null || true)"
[ -n "$BACKEND" ] || BACKEND=herdr
if [ "$BACKEND" != herdr ]; then
  echo "ahoy: the Quartermaster currently supports the herdr backend only (resolved '$BACKEND'); tmux/orca/zellij parity is a follow-up." >&2
  exit 1
fi
fm_backend_source herdr || { echo "ahoy: could not load the herdr backend adapter" >&2; exit 1; }

mkdir -p "$STATE"

# Already aboard? Refocus rather than spawn a second, unless the recorded pane is
# confidently dead (unknown fails safe toward refocus, never a second spawn).
if [ -f "$MARKER" ]; then
  existing_window=$(grep '^window=' "$MARKER" | cut -d= -f2-)
  existing_ses=$(grep '^herdr_session=' "$MARKER" | cut -d= -f2-)
  existing_tab=$(grep '^herdr_tab_id=' "$MARKER" | cut -d= -f2-)
  alive=$(fm_backend_herdr_agent_alive "$existing_window" 2>/dev/null || echo unknown)
  if [ "$alive" != dead ]; then
    if [ -n "$existing_ses" ] && [ -n "$existing_tab" ]; then
      fm_backend_herdr_cli "$existing_ses" tab focus "$existing_tab" >/dev/null 2>&1 || true
    fi
    echo "ahoy: the Quartermaster is already aboard (window=$existing_window, state=$alive); refocused. Use /set-sail in that pane to dismiss it."
    exit 0
  fi
  rm -f "$MARKER"
fi

# The captain's own pane, so /set-sail can ping it. discover_supervisor_target
# returns 0 only on a real resolution; a bare fallback (returns 1) is treated as
# "no captain pane known" so the handoff routes to the backlog instead of a
# bogus default target.
if CAPTAIN="$(discover_supervisor_target)"; then
  CAPTAIN_BACKEND="$(discover_supervisor_backend 2>/dev/null || true)"
else
  CAPTAIN=""
  CAPTAIN_BACKEND=""
fi

# Fresh scratch home + companion charter (the Quartermaster's whole AGENTS.md).
rm -rf "$SCRATCH"
mkdir -p "$SCRATCH"
cat > "$SCRATCH/AGENTS.md" <<EOF
# Quartermaster - operating charter

You are the **Quartermaster** aboard this firstmate: the human's interactive planning partner.
The captain (firstmate) stays heads-down supervising the fleet, so you exist to give the human someone to think out loud with.

## Your job
Converse with the human: brainstorm, reason through problems, plan new tasks, and do small scratch-sized work together.
You are driven by the human turn by turn - you do NOT run autonomously and you have no task to "finish".
Ask good questions, offer options with tradeoffs, and keep a running sense of the decisions you reach together.

## Boundaries (you are NOT the captain)
Do not dispatch crews or scouts, do not arm watchers, and do not run the fleet.
Do not touch the fleet's crew worktrees or any \`state/<id>.meta\` under the firstmate home.
Do not edit the primary firstmate checkout; keep hands-on work inside this scratch home unless the human explicitly says otherwise.
Read fleet state for context freely.

## Reading the code
Project code is READ-ONLY and browsable at \`./projects/<name>/\` (read it, grep it, point codegraph at it) - the same read-only view the captain has; the firstmate home itself is at \`${FM_HOME}\`.
Prototype throwaway experiments here in the scratch home; for a real change to a project, capture it in the plan and hand off via \`/set-sail\` to a crew rather than editing \`projects/\` yourself.

## Handing off and leaving (/set-sail, /farewell)
When the human says \`/set-sail\` or \`/farewell\` (or otherwise signals you are done), load the **set-sail** skill and follow it: it summarizes the plan, hands it to the captain and/or the backlog, then closes this pane.
EOF

# Seed the set-sail skill into the scratch home so the Quartermaster discovers
# /set-sail as a real command (omp agents provider, project scope = cwd).
if [ -d "$FM_HOME/.agents/skills/set-sail" ]; then
  mkdir -p "$SCRATCH/.agents/skills"
  cp -R "$FM_HOME/.agents/skills/set-sail" "$SCRATCH/.agents/skills/set-sail"
else
  echo "ahoy: warning - $FM_HOME/.agents/skills/set-sail not found; the Quartermaster will rely on its charter for /set-sail." >&2
fi

# Give the Quartermaster the captain's own READ-ONLY view of project code so
# brainstorming about a project can actually see it. A symlink, not a treehouse
# slot: the Quartermaster reads/plans; isolated edits are a crew's job via /set-sail.
if [ -d "$FM_HOME/projects" ]; then
  ln -s "$FM_HOME/projects" "$SCRATCH/projects"
fi

# Create the pane in this home's herdr workspace, cwd = the scratch home.
CONTAINER_RAW=$(fm_backend_herdr_container_ensure "$FM_HOME") || { echo "ahoy: failed to ensure this home's herdr workspace" >&2; exit 1; }
CONTAINER=${CONTAINER_RAW%%$'\t'*}
SEEDED_TAB=${CONTAINER_RAW#*$'\t'}
SES=${CONTAINER%%:*}
WSID=${CONTAINER#*:}
IDS=$(fm_backend_herdr_create_task "$CONTAINER" quartermaster "$SCRATCH" "$SEEDED_TAB") || { echo "ahoy: failed to create the Quartermaster pane" >&2; exit 1; }
read -r TAB_ID PANE_ID <<EOF
$IDS
EOF
if [ -z "$TAB_ID" ] || [ -z "$PANE_ID" ]; then
  echo "ahoy: herdr did not return a tab/pane id for the Quartermaster" >&2
  exit 1
fi
WINDOW="$SES:$PANE_ID"

# Record the marker BEFORE launch so a crashed launch still leaves a
# teardownable Quartermaster (fm-set-sail reads exactly these fields).
{
  echo "window=$WINDOW"
  echo "herdr_session=$SES"
  echo "herdr_workspace_id=$WSID"
  echo "herdr_tab_id=$TAB_ID"
  echo "herdr_pane_id=$PANE_ID"
  echo "scratch=$SCRATCH"
  echo "captain=$CAPTAIN"
  echo "captain_backend=$CAPTAIN_BACKEND"
  echo "started=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$MARKER"

# Launch a plain interactive omp the human drives. No --auto-approve (the human
# is present and approves the Quartermaster's actions, unlike an autonomous crew)
# and no turn-end supervision hook. The charter is auto-loaded from AGENTS.md.
PROMPT="Ahoy! You are the Quartermaster; read AGENTS.md in this directory for your charter. Greet me in one line, then ask what we are brainstorming, planning, or building."
LAUNCH=$(printf 'exec env FM_HOME=%q FM_QM_MARKER=%q FM_QM_CAPTAIN=%q FM_QM_CAPTAIN_BACKEND=%q omp %q' \
  "$FM_HOME" "$MARKER" "$CAPTAIN" "$CAPTAIN_BACKEND" "$PROMPT")
if ! fm_backend_herdr_send_text_line "$WINDOW" "$LAUNCH"; then
  echo "ahoy: created the Quartermaster pane but failed to launch omp in it (window=$WINDOW); run '/set-sail' or fm-set-sail.sh to clean up." >&2
  exit 1
fi

fm_backend_herdr_cli "$SES" tab focus "$TAB_ID" >/dev/null 2>&1 || true

echo "ahoy: Quartermaster aboard - window=$WINDOW tab=$TAB_ID scratch=$SCRATCH captain=${CAPTAIN:-none}"
echo "talk to it in that pane; end with /set-sail (or /farewell) to hand off and dismiss."
