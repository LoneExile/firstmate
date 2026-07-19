#!/usr/bin/env bash
# tests/spawn-fakes.sh - shared crew-spawn fakebin stubs.
#
# The thin `treehouse get --lease` fake used by suites that drive fm-spawn's
# crew/ship path under a sanitized PATH lives here, not in tests/lib.sh (which
# deliberately omits behavior-specific mocks) and not in secondmate-helpers.sh
# (whose treehouse fake is the thicker home-lease contract).
#
# One owner of the crew-lease fake contract: when the production lease path
# changes, update this helper once; every crew-spawn suite that sources it
# picks the new behavior up. Inline heredoc copies are how the 29bc820
# migration missed fm-secondmate-harness's crew case.
#
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# fm_fake_treehouse_lease <fakebin>
#
# Install <fakebin>/treehouse implementing the crew-spawn lease contract:
#   get  -> print $FM_FAKE_PANE_PATH to stdout (path only; banners would be stderr)
#   *    -> exit 0 (return and other subcommands are no-ops)
#
# Callers set FM_FAKE_PANE_PATH to a real isolated worktree path before invoking
# fm-spawn so validate_spawn_worktree and meta recording run against a path the
# test controls. Does not implement home-lease / lease-holder recording - that
# is secondmate-helpers.sh's make_fake_tmux.
fm_fake_treehouse_lease() {
  local fakebin=$1
  cat >"$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
# get --lease prints the acquired worktree path to stdout; echo the test's
# controlled FM_FAKE_PANE_PATH so validate_spawn_worktree / meta recording run
# against a path we chose (authoritative-lease model from 29bc820).
if [ "${1:-}" = get ]; then printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
}
