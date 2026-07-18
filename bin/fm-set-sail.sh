#!/usr/bin/env bash
# fm-set-sail.sh - hand the Quartermaster's plan to the captain and/or the
# backlog, then retire the Quartermaster pane. Run by the Quartermaster itself
# (see its charter) when the human says /set-sail or /farewell.
#
# Usage: fm-set-sail.sh [--to captain|backlog|both] [--title <t>] [--priority 0-4]
#                       [--repo <name>] [--plan <text>]
#   The plan text comes from --plan or, if omitted, stdin. --to defaults to
#   'both' when a captain pane was recorded at summon time, else 'backlog'.
#   The plan is always written to a durable handoff file under state/ and, for
#   backlog routes, added via tasks-axi; the captain is only ever pinged with a
#   one-line pointer (never a multi-line steer). With no plan text it skips
#   delivery and still retires the pane. Idempotent: no Quartermaster aboard is
#   a clean no-op.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

case "${1:-}" in
  -h|--help) grep '^#' "${BASH_SOURCE[0]}" | sed '1d;s/^# \{0,1\}//'; exit 0 ;;
esac

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# The Quartermaster runs on herdr (fm-ahoy is herdr-only), so load that adapter
# for the pane kill at teardown; fm_backend.sh sources adapters lazily.
fm_backend_source herdr >/dev/null 2>&1 || true

MARKER="${FM_QM_MARKER:-$STATE/.quartermaster}"
if [ ! -f "$MARKER" ]; then
  echo "set-sail: no Quartermaster is aboard (no $MARKER); nothing to do."
  exit 0
fi

WINDOW=$(grep '^window=' "$MARKER" | cut -d= -f2-)
SCRATCH=$(grep '^scratch=' "$MARKER" | cut -d= -f2-)
CAPTAIN=$(grep '^captain=' "$MARKER" | cut -d= -f2-)

TO=""
TITLE=""
PRIORITY=""
REPO=""
PLAN=""
while [ $# -gt 0 ]; do
  case "$1" in
    --to) TO=${2:-}; shift 2 ;;
    --title) TITLE=${2:-}; shift 2 ;;
    --priority) PRIORITY=${2:-}; shift 2 ;;
    --repo) REPO=${2:-}; shift 2 ;;
    --plan) PLAN=${2:-}; shift 2 ;;
    *) echo "set-sail: unknown argument '$1' (see --help)" >&2; exit 2 ;;
  esac
done

# Plan from --plan, else stdin when piped.
if [ -z "$PLAN" ] && [ ! -t 0 ]; then
  PLAN=$(cat || true)
fi
[ -n "$TITLE" ] || TITLE="Quartermaster plan $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Default route: both when a captain pane is known, else backlog only. A
# captain-in-route with no captain pane recorded degrades to backlog.
if [ -z "$TO" ]; then
  if [ -n "$CAPTAIN" ]; then TO=both; else TO=backlog; fi
fi
case "$TO" in
  captain|backlog|both) : ;;
  *) echo "set-sail: --to must be captain, backlog, or both (got '$TO')" >&2; exit 2 ;;
esac
if { [ "$TO" = captain ] || [ "$TO" = both ]; } && [ -z "$CAPTAIN" ]; then
  echo "set-sail: no captain pane was recorded at summon time; routing to backlog." >&2
  TO=backlog
fi

delivered=""
mint_id=""
PLAN_FILE=""
if [ -n "$PLAN" ]; then
  PLAN_FILE="$STATE/quartermaster-plan-$(date -u +%Y%m%dT%H%M%SZ).md"
  printf '# %s\n\n%s\n' "$TITLE" "$PLAN" > "$PLAN_FILE"

  if [ "$TO" = backlog ] || [ "$TO" = both ]; then
    if command -v tasks-axi >/dev/null 2>&1; then
      add_args=(add --mint "$TITLE" --body-file "$PLAN_FILE" --json)
      [ -z "$REPO" ] || add_args+=(--repo "$REPO")
      [ -z "$PRIORITY" ] || add_args+=(--priority "$PRIORITY")
      if add_out=$(cd "$FM_HOME" && tasks-axi "${add_args[@]}" 2>/dev/null); then
        mint_id=$(printf '%s' "$add_out" | jq -r '.id // empty' 2>/dev/null || true)
        delivered="${delivered}backlog "
      else
        echo "set-sail: tasks-axi add failed; plan kept at $PLAN_FILE but NOT queued." >&2
      fi
    else
      echo "set-sail: tasks-axi not available; plan kept at $PLAN_FILE but NOT queued." >&2
    fi
  fi

  if [ "$TO" = captain ] || [ "$TO" = both ]; then
    msg="Quartermaster set sail: $TITLE - implement now."
    [ -z "$mint_id" ] || msg="$msg queued=$mint_id."
    msg="$msg plan=$PLAN_FILE"
    if FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-send.sh" "$CAPTAIN" "$msg" >/dev/null 2>&1; then
      delivered="${delivered}captain "
    else
      echo "set-sail: could not ping the captain ($CAPTAIN); the plan is at $PLAN_FILE${mint_id:+ and queued as $mint_id}." >&2
    fi
  fi
else
  echo "set-sail: no plan text provided; skipping handoff, just retiring the Quartermaster."
fi

# Retire: clear marker + scratch first, then close the pane. Closing the pane
# kills THIS process when run from inside the Quartermaster, so it must be last;
# the plan file under state/ is deliberately kept for the captain to read.
rm -f "$MARKER"
if [ -n "$SCRATCH" ] && [ "$SCRATCH" != / ] && [ -d "$SCRATCH" ]; then
  rm -rf "$SCRATCH"
fi
echo "set-sail: handed off to [${delivered:-nothing}] and retiring the Quartermaster (window=$WINDOW)."
[ -z "$WINDOW" ] || fm_backend_herdr_kill "$WINDOW"
