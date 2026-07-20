#!/usr/bin/env bash
# fm-ahoy.sh - summon (or refocus) a Quartermaster: an interactive companion
# pane the human can talk to (brainstorm, plan, small scratch tasks) while the
# captain stays heads-down supervising the fleet. The Quartermaster is a new,
# human-driven role - not an autonomous crewmate/scout and not a supervisor
# secondmate. End a session with its own /set-sail (bin/fm-set-sail.sh), which
# hands the plan to the captain and/or the backlog and retires the pane.
#
# Usage: fm-ahoy.sh [<label>] [--list] [--reap <label>] [--help]
#   Summons a Quartermaster in this home's herdr workspace, in a per-instance
#   scratch home (state/quartermaster-home-<label>/) seeded with a companion
#   charter (AGENTS.md), launched as a plain interactive omp the human drives.
#
#   Instances are keyed by <label>, so more than one can run at once:
#     fm-ahoy.sh              bare: spawn a fresh auto-labelled instance
#                            (qm-1, qm-2, ...) every time - parallel planning
#                            threads, each its own pane and scratch home.
#     fm-ahoy.sh <label>     spawn instance <label>, or refocus it if already
#                            aboard (an unreadable pane fails safe toward
#                            refocus, never a duplicate spawn).
#     fm-ahoy.sh --list      print the roster of Quartermasters aboard.
#     fm-ahoy.sh --reap <l>  force-retire instance <label> (kill pane + clean).
#   Confidently-dead instances are reaped automatically on every summon/list.
#   There is no hard cap; past 3 live instances a warning prints (each is a live
#   omp session costing tokens/memory).
#
#   Captain handoff target: fm-ahoy records the captain's own pane
#   (discover_supervisor_target) per instance so /set-sail can ping it. Run from
#   a shell where that cannot be resolved, the Quartermaster still works and
#   /set-sail records the plan to the backlog only.
#
#   Backend: herdr only for now (the default). Other backends are refused loudly;
#   tmux/orca/zellij parity is a follow-up.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

MODE=spawn
REQ_LABEL=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) grep '^#' "${BASH_SOURCE[0]}" | sed '1d;s/^# \{0,1\}//'; exit 0 ;;
    --list) MODE=list; shift ;;
    --reap) MODE=reap; REQ_LABEL=${2:-}; shift 2 ;;
    --) shift ;;
    -*) echo "ahoy: unexpected option '$1' (see --help)" >&2; exit 2 ;;
    *)
      if [ -n "$REQ_LABEL" ]; then
        echo "ahoy: unexpected extra argument '$1' (see --help)" >&2; exit 2
      fi
      REQ_LABEL=$1; shift ;;
  esac
done

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-supervisor-target-lib.sh
. "$SCRIPT_DIR/fm-supervisor-target-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
# Portable stale-tolerant mutex (fm_lock_try_acquire/fm_lock_release) for the
# same-label spawn claim below; this is the home's one lock convention.
. "$SCRIPT_DIR/fm-wake-lib.sh"

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

# --- instance helpers ---------------------------------------------------------

# Sanitize a requested label: it becomes a filesystem path, so reject anything
# that could traverse or collide with internal names. Allowed: [A-Za-z0-9._-],
# no leading '.'/'-', no '..', length <= 32. Prints the label or returns 1.
qm_sanitize_label() {
  local l=$1
  case "$l" in
    ''|.*|-*) return 1 ;;
    *..*) return 1 ;;
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#l}" -le 32 ] || return 1
  printf '%s' "$l"
}

qm_marker_for()  { printf '%s/.quartermaster-%s' "$STATE" "$1"; }
qm_scratch_for() { printf '%s/quartermaster-home-%s' "$STATE" "$1"; }

# Every instance marker: the labelled ones plus a legacy singleton marker from
# before multi-instance (so a pre-upgrade Quartermaster is never orphaned).
# Skips the glob-literal, the .lock claim dirs, and any .tmp mid-write file.
qm_markers() {
  local m
  for m in "$STATE"/.quartermaster "$STATE"/.quartermaster-*; do
    [ -f "$m" ] || continue
    case "$m" in *.tmp) continue ;; esac
    printf '%s\n' "$m"
  done
}

qm_label_of() {  # <marker-path> -> label (from label= field, else basename)
  local m=$1 lbl
  lbl=$(grep '^label=' "$m" 2>/dev/null | cut -d= -f2- || true)
  if [ -z "$lbl" ]; then
    case "${m##*/}" in
      .quartermaster-*) lbl=${m##*/.quartermaster-} ;;
      *) lbl='(legacy)' ;;
    esac
  fi
  printf '%s' "$lbl"
}

qm_alive_of() {  # <marker-path> -> alive|dead|unknown
  local w
  w=$(grep '^window=' "$1" 2>/dev/null | cut -d= -f2- || true)
  fm_backend_herdr_agent_alive "$w" 2>/dev/null || echo unknown
}

# Remove confidently-dead instances (marker + its scratch home). Silent.
qm_reap_dead() {
  local m sc
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    [ "$(qm_alive_of "$m")" = dead ] || continue
    sc=$(grep '^scratch=' "$m" 2>/dev/null | cut -d= -f2- || true)
    rm -f "$m"
    if [ -n "$sc" ] && [ "$sc" != / ] && [ -d "$sc" ]; then rm -rf "$sc"; fi
  done <<EOF
$(qm_markers)
EOF
}

qm_live_count() {  # count instances whose pane is not confidently dead
  local m n=0
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    [ "$(qm_alive_of "$m")" != dead ] && n=$((n + 1))
  done <<EOF
$(qm_markers)
EOF
  printf '%s' "$n"
}

qm_auto_label() {  # lowest-free qm-N (skips a marker or an in-flight claim)
  local n=1
  while [ -f "$(qm_marker_for "qm-$n")" ] || [ -d "$(qm_marker_for "qm-$n").lock" ]; do
    n=$((n + 1))
  done
  printf 'qm-%s' "$n"
}

# Refocus an existing instance of this label instead of spawning a duplicate.
# Prints the refocus notice and exits 0 when the marker is present and its pane
# is not confidently dead (unknown fails safe toward refocus); removes a
# confidently-dead marker and returns 1 so the caller proceeds to spawn; returns
# 1 with no action when no marker exists. Called twice: once before the spawn
# claim (the common explicit-label case) and once again right after the claim is
# taken, to close the window where a concurrent same-label summon completed its
# whole spawn between our marker check and our claim (else we would rm -rf and
# respawn over the live sibling).
qm_refocus_if_aboard() {  # <marker> <label>
  local marker=$1 label=$2 existing_window existing_ses existing_tab alive
  [ -f "$marker" ] || return 1
  existing_window=$(grep '^window=' "$marker" | cut -d= -f2- || true)
  existing_ses=$(grep '^herdr_session=' "$marker" | cut -d= -f2- || true)
  existing_tab=$(grep '^herdr_tab_id=' "$marker" | cut -d= -f2- || true)
  alive=$(fm_backend_herdr_agent_alive "$existing_window" 2>/dev/null || echo unknown)
  if [ "$alive" != dead ]; then
    if [ -n "$existing_ses" ] && [ -n "$existing_tab" ]; then
      fm_backend_herdr_cli "$existing_ses" tab focus "$existing_tab" >/dev/null 2>&1 || true
    fi
    echo "ahoy: Quartermaster '$label' is already aboard (window=$existing_window, state=$alive); refocused. Use /set-sail in that pane to dismiss it."
    exit 0
  fi
  rm -f "$marker"
  return 1
}

# --- modes --------------------------------------------------------------------

if [ "$MODE" = list ]; then
  qm_reap_dead
  markers=$(qm_markers)
  if [ -z "$markers" ]; then echo "ahoy: no Quartermasters aboard."; exit 0; fi
  printf '%-16s %-7s %-22s %-22s %s\n' LABEL STATE WINDOW STARTED CAPTAIN
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    printf '%-16s %-7s %-22s %-22s %s\n' \
      "$(qm_label_of "$m")" "$(qm_alive_of "$m")" \
      "$(grep '^window=' "$m" | cut -d= -f2- || true)" \
      "$(grep '^started=' "$m" | cut -d= -f2- || true)" \
      "$(grep '^captain=' "$m" | cut -d= -f2- || true)"
  done <<EOF
$markers
EOF
  exit 0
fi

if [ "$MODE" = reap ]; then
  lbl=$(qm_sanitize_label "$REQ_LABEL") || { echo "ahoy: --reap needs a valid label" >&2; exit 2; }
  m=$(qm_marker_for "$lbl")
  if [ ! -f "$m" ]; then echo "ahoy: no Quartermaster labelled '$lbl' aboard."; exit 0; fi
  w=$(grep '^window=' "$m" | cut -d= -f2- || true)
  sc=$(grep '^scratch=' "$m" | cut -d= -f2- || true)
  rm -f "$m"
  if [ -n "$sc" ] && [ "$sc" != / ] && [ -d "$sc" ]; then rm -rf "$sc"; fi
  [ -z "$w" ] || fm_backend_herdr_kill "$w" 2>/dev/null || true
  echo "ahoy: reaped Quartermaster '$lbl' (window=$w)."
  exit 0
fi

# --- spawn --------------------------------------------------------------------

# Sweep confidently-dead instances first so they neither linger in the roster
# nor count toward the soft cap.
qm_reap_dead

# Resolve the label: an explicit (sanitized) one, else a fresh auto-label for a
# bare summon (bare /ahoy always opens a new parallel thread).
if [ -n "$REQ_LABEL" ]; then
  LABEL=$(qm_sanitize_label "$REQ_LABEL") || {
    echo "ahoy: invalid label '$REQ_LABEL' - use [A-Za-z0-9._-], no leading dot/dash, no '..', <= 32 chars." >&2
    exit 2
  }
else
  LABEL=$(qm_auto_label)
fi
MARKER=$(qm_marker_for "$LABEL")
SCRATCH=$(qm_scratch_for "$LABEL")

# Explicit label already aboard? Refocus rather than spawn a duplicate (unknown
# fails safe toward refocus). A bare/auto label is always fresh, so this only
# fires for an explicitly-requested label; a confidently-dead marker is cleaned
# so we fall through and spawn.
qm_refocus_if_aboard "$MARKER" "$LABEL" || true

# Soft cap: no hard limit, but warn past 3 live instances (each is a live omp
# session). The count excludes the one about to spawn.
live=$(qm_live_count)
if [ "$live" -ge 3 ]; then
  echo "ahoy: $live Quartermasters already aboard - spawning '$LABEL' anyway. Consider /set-sail-ing idle ones; each is a live omp session." >&2
fi

# Atomic claim against a concurrent summon of the SAME label: two shells would
# otherwise both see no marker and both spawn, stranding one pane. The mutex is
# stale-tolerant (a crashed prior claim is auto-stolen), so it never wedges; a
# genuinely LIVE concurrent claim makes us decline instead of duplicating.
LOCKDIR="$MARKER.lock"
if ! fm_lock_try_acquire "$LOCKDIR"; then
  echo "ahoy: another summon for '$LABEL' is in progress; not spawning a duplicate." >&2
  exit 0
fi
trap 'fm_lock_release "$LOCKDIR"' EXIT

# Re-check now that the claim is ours: a concurrent same-label summon may have
# finished its entire spawn (marker written, its own claim released) in the
# window between our pre-claim marker check and acquiring this lock. Refocus that
# live sibling instead of rebuilding its scratch and spawning a duplicate over it.
qm_refocus_if_aboard "$MARKER" "$LABEL" || true

# The captain's own pane, so /set-sail can ping it. discover_supervisor_target
# returns 0 only on a real resolution; a bare fallback (returns 1) is treated as
# "no captain pane known" so the handoff routes to the backlog instead of a
# bogus default target.
if ! CAPTAIN="$(discover_supervisor_target)"; then
  CAPTAIN=""
fi

# Fresh scratch home + companion charter (this instance's whole AGENTS.md). Only
# this label's home is rebuilt, so a sibling Quartermaster is never disturbed.
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
# teardownable Quartermaster (fm-set-sail reads exactly these fields). Written
# via tmp->mv so a concurrent --list/reap never reads a half-written marker.
{
  echo "label=$LABEL"
  echo "window=$WINDOW"
  echo "herdr_session=$SES"
  echo "herdr_workspace_id=$WSID"
  echo "herdr_tab_id=$TAB_ID"
  echo "herdr_pane_id=$PANE_ID"
  echo "scratch=$SCRATCH"
  echo "captain=$CAPTAIN"
  echo "started=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$MARKER.tmp"
mv -f "$MARKER.tmp" "$MARKER"

# Launch a plain interactive omp the human drives. No --auto-approve (the human
# is present and approves the Quartermaster's actions, unlike an autonomous crew)
# and no turn-end supervision hook. The charter is auto-loaded from AGENTS.md.
# FM_QM_MARKER is this instance's own marker, so /set-sail tears down exactly it.
PROMPT="Ahoy! You are the Quartermaster; read AGENTS.md in this directory for your charter. Greet me in one line, then ask what we are brainstorming, planning, or building."
LAUNCH=$(printf 'exec env FM_HOME=%q FM_QM_MARKER=%q FM_QM_LABEL=%q FM_QM_CAPTAIN=%q omp %q' \
  "$FM_HOME" "$MARKER" "$LABEL" "$CAPTAIN" "$PROMPT")
if ! fm_backend_herdr_send_text_line "$WINDOW" "$LAUNCH"; then
  echo "ahoy: created the Quartermaster pane but failed to launch omp in it (window=$WINDOW); run '/set-sail' or fm-set-sail.sh to clean up." >&2
  exit 1
fi

fm_backend_herdr_cli "$SES" tab focus "$TAB_ID" >/dev/null 2>&1 || true

echo "ahoy: Quartermaster '$LABEL' aboard - window=$WINDOW tab=$TAB_ID scratch=$SCRATCH captain=${CAPTAIN:-none}"
echo "talk to it in that pane; end with /set-sail (or /farewell) to hand off and dismiss."
