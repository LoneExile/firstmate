#!/usr/bin/env bash
# Contract tests for the multi-instance Quartermaster handoff wording.
#
# The captain recognizes a Quartermaster handoff by the exact message prefix
# fm-set-sail.sh emits, and the multi-instance contract (per-label handoffs,
# bare-summon auto-label, soft cap, ping-on-every-route) is stated in the
# ahoy/set-sail skills. Pin the shared phrases so the emitter, the always-loaded
# captain reference (AGENTS.md), and the skills cannot drift apart silently -
# e.g. a backlog-route filing whose prefix the captain was never taught reads as
# unknown chatter and strands the plan.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

test_set_sail_emits_both_handoff_verbs() {
  local setsail="$ROOT/bin/fm-set-sail.sh"
  assert_grep 'Quartermaster set sail:' "$setsail" \
    "fm-set-sail no longer emits the implement-now handoff prefix"
  assert_grep 'Quartermaster filed to backlog (do it later):' "$setsail" \
    "fm-set-sail no longer emits the backlog handoff prefix"
  pass "fm-set-sail emits both the implement-now and backlog handoff prefixes"
}

test_agents_teaches_both_handoff_verbs() {
  local agents="$ROOT/AGENTS.md"
  assert_grep 'Quartermaster set sail:' "$agents" \
    "AGENTS.md does not teach the captain the implement-now handoff prefix"
  assert_grep 'Quartermaster filed to backlog (do it later):' "$agents" \
    "AGENTS.md does not teach the captain the backlog handoff prefix (a filed plan reads as unknown chatter)"
  pass "AGENTS.md teaches the captain both Quartermaster handoff prefixes"
}

test_ahoy_skill_pins_multi_instance_contract() {
  local ahoy="$ROOT/.agents/skills/ahoy/SKILL.md"
  assert_grep 'qm-1' "$ahoy" \
    "ahoy skill lost the bare-summon auto-label contract (qm-1, qm-2, ...)"
  assert_grep 'qm=<label>' "$ahoy" \
    "ahoy skill no longer documents the per-instance label carried on the handoff"
  assert_grep 'past three live instances' "$ahoy" \
    "ahoy skill lost the soft-cap warning contract"
  pass "ahoy skill pins the multi-instance contract (auto-label, per-instance label, soft cap)"
}

test_set_sail_skill_pins_ping_every_route() {
  local sail="$ROOT/.agents/skills/set-sail/SKILL.md"
  assert_grep 'on every route' "$sail" \
    "set-sail skill lost the ping-on-every-route contract"
  assert_grep 'do it later' "$sail" \
    "set-sail skill no longer names the backlog-route ping"
  pass "set-sail skill pins captain pinging on every route including the backlog filing"
}

test_set_sail_emits_both_handoff_verbs
test_agents_teaches_both_handoff_verbs
test_ahoy_skill_pins_multi_instance_contract
test_set_sail_skill_pins_ping_every_route
