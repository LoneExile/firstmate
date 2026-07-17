#!/usr/bin/env bash
# firstmate runs exclusively on the omp (Oh My Pi) harness, so harness resolution
# is constant. This shim stays as the single source callers ask, and still parses
# the optional secondmate model/effort tokens (which parametrize the omp
# secondmate and are orthogonal to the - now fixed - harness choice).
# Usage: fm-harness.sh                  print own harness        (always: omp)
#        fm-harness.sh crew             print crewmate harness   (always: omp)
#        fm-harness.sh secondmate       print secondmate harness (always: omp)
#        fm-harness.sh secondmate-model    optional MODEL token from config/secondmate-harness
#        fm-harness.sh secondmate-effort   optional EFFORT token from config/secondmate-harness
# config/secondmate-harness format: a single line "<harness> [<model>] [<effort>]",
# whitespace-separated. The harness token is vestigial (omp is the only adapter),
# but the optional model/effort tokens still parametrize the omp secondmate. Write
# it as "omp <model> <effort>" to set them; only the first non-empty, non-comment
# line is parsed.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# Print the first non-empty, non-comment line of config/secondmate-harness
# (leading/trailing whitespace trimmed), or nothing when the file is absent or
# holds only blank/comment lines.
secondmate_line() {
  local line
  [ -f "$CONFIG/secondmate-harness" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    case "$line" in
      '#'*) continue ;;
    esac
    printf '%s\n' "$line"
    return 0
  done < "$CONFIG/secondmate-harness"
}

# Print the 1-based whitespace-separated token (1=harness, 2=model, 3=effort) of
# the resolved secondmate_line, or nothing if the line or that field is absent.
secondmate_field() {
  local idx=$1 line
  line=$(secondmate_line)
  [ -n "$line" ] || return 0
  # shellcheck disable=SC2086  # deliberate word-splitting: tokenizing the line into fields
  set -- $line
  case "$idx" in
    1) printf '%s\n' "${1:-}" ;;
    2) printf '%s\n' "${2:-}" ;;
    3) printf '%s\n' "${3:-}" ;;
  esac
}

# Print the optional model token (2nd field) from config/secondmate-harness, or
# empty when the harness token is absent/"default" (harness-only file, same as
# today) or when no model token is present.
resolve_secondmate_model() {
  local sm
  sm=$(secondmate_field 1)
  [ -n "$sm" ] && [ "$sm" != "default" ] || return 0
  secondmate_field 2
}

# Print the optional effort token (3rd field) from config/secondmate-harness,
# the same way.
resolve_secondmate_effort() {
  local sm
  sm=$(secondmate_field 1)
  [ -n "$sm" ] && [ "$sm" != "default" ] || return 0
  secondmate_field 3
}

case "${1:-}" in
  secondmate-model) resolve_secondmate_model ;;
  secondmate-effort) resolve_secondmate_effort ;;
  *) echo omp ;;
esac
