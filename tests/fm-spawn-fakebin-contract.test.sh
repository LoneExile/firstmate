#!/usr/bin/env bash
# Structural contract for the crew-spawn lease fake.
#
# Failure mode this defends (29bc820 / fece311): a test drives fm-spawn's crew
# path under a sanitized fakebin PATH, sets FM_FAKE_PANE_PATH for the leased
# worktree, but never installs a treehouse stub that answers `get`. Spawn dies
# with `command not found`, no meta, and a useless kind!=ship assertion.
#
# Discovery is DYNAMIC over tests/*.test.sh so a *future* suite is covered, not
# only the three already migrated. Opt out with a line:
#   spawn-fakebin-contract: skip-lease
#
# Deliberately dumb: source greps + exercise the shared helper. No full spawn.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/spawn-fakes.sh
. "$(dirname "${BASH_SOURCE[0]}")/spawn-fakes.sh"

TESTS="$ROOT/tests"

# Every suite that sets FM_FAKE_PANE_PATH expects the thin lease contract
# (treehouse get -> that path). It must source spawn-fakes.sh and call
# fm_fake_treehouse_lease. Inline thin heredocs are forbidden (one owner).
test_fm_fake_pane_path_suites_use_shared_helper() {
  local f base misses=() line
  for f in "$TESTS"/*.test.sh; do
    base=$(basename "$f")
    [ "$base" = "fm-spawn-fakebin-contract.test.sh" ] && continue
    grep -q 'FM_FAKE_PANE_PATH' "$f" || continue
    if grep -q 'spawn-fakebin-contract: skip-lease' "$f"; then
      continue
    fi
    grep -q 'spawn-fakes.sh' "$f" \
      || misses+=("$base: sets FM_FAKE_PANE_PATH but does not source tests/spawn-fakes.sh")
    # Real call site (not a mention in a comment).
    if ! grep -E '^[[:space:]]*fm_fake_treehouse_lease[[:space:]]' "$f" >/dev/null; then
      misses+=("$base: sets FM_FAKE_PANE_PATH but never calls fm_fake_treehouse_lease")
    fi
    # Residue: a treehouse stub that still inlines FM_FAKE_PANE_PATH (tmux pane
    # probes may print it; those lines mention pane_current_path, not treehouse).
    while IFS= read -r line; do
      case "$line" in
        *fm_fake_treehouse_lease*) continue ;;
        *pane_current_path*) continue ;;
        *'#'*) continue ;;
      esac
      misses+=("$base: inline treehouse/FM_FAKE_PANE_PATH residue (use fm_fake_treehouse_lease): $line")
    done < <(grep -n 'treehouse' "$f" | grep -F 'FM_FAKE_PANE_PATH' || true)
  done
  if [ "${#misses[@]}" -gt 0 ]; then
    fail "thin crew-lease contract gaps:"$'\n'"$(printf '  - %s\n' "${misses[@]}")"
  fi
  # At least the known migrated suites must still be in the discovered set so a
  # rename/delete of FM_FAKE_PANE_PATH cannot silently empty the net.
  local found=0
  for f in fm-tangle-guard.test.sh fm-gate-refuse.test.sh fm-secondmate-harness.test.sh; do
    grep -q 'FM_FAKE_PANE_PATH' "$TESTS/$f" || fail "expected $f to still set FM_FAKE_PANE_PATH (discovery anchor)"
    found=$((found + 1))
  done
  [ "$found" -eq 3 ] || fail "discovery anchors incomplete"
  pass "every FM_FAKE_PANE_PATH suite sources spawn-fakes.sh and calls fm_fake_treehouse_lease"
}

test_shared_helper_get_prints_pane_path() {
  local dir fb out
  dir=$(fm_test_tmproot fm-spawn-fakebin-contract)
  fb=$(fm_fakebin "$dir")
  fm_fake_treehouse_lease "$fb"
  assert_present "$fb/treehouse" "fm_fake_treehouse_lease did not install treehouse"
  out=$(FM_FAKE_PANE_PATH="/leased/worktree/path" "$fb/treehouse" get --lease --lease-holder id)
  [ "$out" = "/leased/worktree/path" ] \
    || fail "shared lease fake get must print FM_FAKE_PANE_PATH, got '$out'"
  out=$(FM_FAKE_PANE_PATH="/leased/worktree/path" "$fb/treehouse" return --force /x)
  [ -z "$out" ] || fail "shared lease fake return must be silent on stdout, got '$out'"
  pass "fm_fake_treehouse_lease: get prints FM_FAKE_PANE_PATH; other subcommands no-op"
}

test_shared_helper_empty_pane_path_is_empty_stdout() {
  local dir fb out
  dir=$(fm_test_tmproot fm-spawn-fakebin-empty)
  fb=$(fm_fakebin "$dir")
  fm_fake_treehouse_lease "$fb"
  out=$(env -u FM_FAKE_PANE_PATH "$fb/treehouse" get)
  [ -z "$out" ] || fail "unset FM_FAKE_PANE_PATH must yield empty get stdout (spawn fails closed), got '$out'"
  pass "fm_fake_treehouse_lease: empty FM_FAKE_PANE_PATH yields empty get (lease fail-closed)"
}

test_guidelines_gate_names_spawn_fakes_owner() {
  local coding="$ROOT/.agents/skills/firstmate-coding-guidelines/SKILL.md"
  assert_grep 'External-binary / hot-path fixture gate' "$coding" \
    "coding-guidelines lost the external-binary fixture gate section"
  assert_grep 'spawn-fakes.sh' "$coding" \
    "coding-guidelines gate must name tests/spawn-fakes.sh as crew-lease owner"
  assert_grep 'fm_fake_treehouse_lease' "$coding" \
    "coding-guidelines gate must name fm_fake_treehouse_lease"
  pass "coding-guidelines external-binary gate names the shared crew-lease owner"
}

test_fm_fake_pane_path_suites_use_shared_helper
test_shared_helper_get_prints_pane_path
test_shared_helper_empty_pane_path_is_empty_stdout
test_guidelines_gate_names_spawn_fakes_owner
