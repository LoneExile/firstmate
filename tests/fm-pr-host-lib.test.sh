#!/usr/bin/env bash
# tests/fm-pr-host-lib.test.sh - the host-agnostic PR library (bin/fm-pr-host-lib.sh)
# that lets firstmate's check/merge/teardown machinery drive a Gitea PR the same
# way it drives a GitHub one.
#
# Matrix:
#   (a) host detection: github.com -> github, any other host -> gitea
#   (b) URL parse accepts GitHub /pull/ and Gitea /pulls/ with correct fields
#   (c) URL parse rejects unsafe segments and malformed URLs for BOTH hosts
#   (d) Gitea state/head/merge resolve via the REST API (mocked curl)
#   (e) GitHub dispatches via gh and never leaks to curl
#   (f) fm_pr_url_from_worktree builds canonical /pulls/ (Gitea) and /pull/ (GitHub)
#       URLs from https and git@ origins, and fails without an origin
#   (g) fm_pr_number_from_branch maps a Gitea branch head to its PR number
#   (h) teardown containment chain (no PR_URL): branch -> number -> url -> state,
#       including the fail-safe when a worktree has no origin (must NOT false-land)
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

LIB="$ROOT/bin/fm-pr-host-lib.sh"
# shellcheck source=bin/fm-pr-host-lib.sh
. "$LIB"

TMP_ROOT=$(fm_test_tmproot fm-pr-host-lib-tests)

# --- fakebin: curl / gh / gh-axi stubs that answer by URL, logging invocations.
# The curl stub returns exactly the Gitea REST shapes the real lib parses with jq
# (proven against the real lib), so these exercise the actual library code paths.
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
export FM_TEST_CURL_LOG="$TMP_ROOT/curl.log"
export FM_TEST_GH_AXI_LOG="$TMP_ROOT/gh-axi.log"
: > "$FM_TEST_CURL_LOG"
: > "$FM_TEST_GH_AXI_LOG"

cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "$FM_TEST_CURL_LOG"
url=""
for a in "$@"; do case "$a" in https://*) url=$a ;; esac; done
case "$url" in
  */pulls/70/merge) printf '' ;;
  */pulls/70) printf '{"merged":true,"state":"closed","head":{"sha":"deadbeefcafefeed0000000000000000deadbeef"}}' ;;
  */pulls/71) printf '{"merged":false,"state":"open","head":{"sha":"cafe000000000000000000000000000000000cafe"}}' ;;
  *"/pulls?"*) printf '[{"number":70,"head":{"ref":"feat/merged"}},{"number":71,"head":{"ref":"feat/open"}}]' ;;
  *) exit 22 ;;
esac
SH
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *headRefOid*) printf 'abc1230000000000000000000000000000000abc\n' ;;
  *) printf 'MERGED\n' ;;
esac
exit 0
SH
cat > "$FAKEBIN/gh-axi" <<'SH'
#!/usr/bin/env bash
printf 'gh-axi %s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
exit 0
SH
chmod +x "$FAKEBIN/curl" "$FAKEBIN/gh" "$FAKEBIN/gh-axi"
export PATH="$FAKEBIN:$PATH"
export FM_GITEA_TOKEN=testtoken

# Worktree fixtures with distinct origins (real repos so git remote get-url works).
GITEA_WT="$TMP_ROOT/gitea-wt"
git init -q "$GITEA_WT"
git -C "$GITEA_WT" remote add origin "https://apinant:tok@private-git.ocin.cloud/OpenCloud/core.git"
GH_WT="$TMP_ROOT/gh-wt"
git init -q "$GH_WT"
git -C "$GH_WT" remote add origin "https://github.com/o/r.git"
BARE_WT="$TMP_ROOT/no-origin-wt"
git init -q "$BARE_WT"

GITEA_PR="https://private-git.ocin.cloud/OpenCloud/core/pulls"
GH_PR="https://github.com/OpenCloud/console-backend/pull"

test_host_detection() {
  [ "$(fm_pr_host "$GH_PR/42")" = github ] || fail "host: github.com not detected as github"
  [ "$(fm_pr_host "$GITEA_PR/70")" = gitea ] || fail "host: gitea host not detected as gitea"
  pass "fm_pr_host maps github.com -> github and other hosts -> gitea"
}

test_parse_accepts_both_hosts() {
  fm_pr_parse "$GH_PR/42" || fail "parse: rejected a valid GitHub URL"
  [ "$PR_OWNER/$PR_REPO#$PR_NUMBER" = "OpenCloud/console-backend#42" ] \
    || fail "parse: github fields wrong ($PR_OWNER/$PR_REPO#$PR_NUMBER)"
  fm_pr_parse "$GITEA_PR/70" || fail "parse: rejected a valid Gitea /pulls/ URL"
  [ "$PR_OWNER/$PR_REPO#$PR_NUMBER" = "OpenCloud/core#70" ] \
    || fail "parse: gitea fields wrong ($PR_OWNER/$PR_REPO#$PR_NUMBER)"
  pass "fm_pr_parse accepts GitHub /pull/ and Gitea /pulls/ URLs with correct fields"
}

test_parse_rejects_unsafe_and_malformed() {
  local u
  # shellcheck disable=SC2016  # The literal $(...) is the unsafe input under test; it must NOT expand.
  for u in \
    'https://github.com/ow$(id)ner/repo/pull/1' \
    'https://github.com/owner-/repo/pull/1' \
    'https://github.com/-owner/repo/pull/1' \
    'https://github.com/owner/re po/pull/1' \
    'https://github.com/owner/repo/pull/abc' \
    'https://gitlab.com/example/repo/-/merge_requests/1'; do
    if fm_pr_parse "$u"; then fail "parse: accepted unsafe/malformed URL: $u"; fi
  done
  pass "fm_pr_parse rejects unsafe segments and malformed URLs for both hosts"
}

test_gitea_state_head() {
  [ "$(fm_pr_view_state "$GITEA_PR/70" "$GITEA_WT")" = MERGED ] || fail "gitea: merged PR not reported MERGED"
  [ "$(fm_pr_view_state "$GITEA_PR/71" "$GITEA_WT")" = OPEN ] || fail "gitea: open PR not reported OPEN"
  [ "$(fm_pr_view_head "$GITEA_PR/70" "$GITEA_WT")" = deadbeefcafefeed0000000000000000deadbeef ] \
    || fail "gitea: head sha wrong"
  pass "fm_pr_view_state/head resolve Gitea PR state and head via the REST API"
}

test_gitea_merge_posts_squash() {
  : > "$FM_TEST_CURL_LOG"
  fm_pr_merge "$GITEA_PR/70" squash "$GITEA_WT" || fail "gitea: merge returned non-zero"
  assert_grep '/pulls/70/merge' "$FM_TEST_CURL_LOG" "gitea: merge did not POST to /pulls/<n>/merge"
  assert_grep '"Do":"squash"' "$FM_TEST_CURL_LOG" "gitea: merge did not send Do:squash"
  pass "fm_pr_merge POSTs Do:squash to the Gitea /pulls/<n>/merge endpoint"
}

test_github_uses_gh_not_curl() {
  : > "$FM_TEST_CURL_LOG"
  [ "$(fm_pr_view_state "$GH_PR/5" "$GH_WT")" = MERGED ] || fail "github: view_state did not use gh"
  assert_no_grep 'github.com' "$FM_TEST_CURL_LOG" "github: state lookup leaked to curl"
  pass "fm_pr_view_state dispatches GitHub via gh, never curl"
}

test_url_from_worktree() {
  [ "$(fm_pr_url_from_worktree "$GITEA_WT" 88)" = "https://private-git.ocin.cloud/OpenCloud/core/pulls/88" ] \
    || fail "url_from_worktree: gitea https origin -> wrong URL"
  [ "$(fm_pr_url_from_worktree "$GH_WT" 88)" = "https://github.com/o/r/pull/88" ] \
    || fail "url_from_worktree: github https origin -> wrong URL"
  fm_pr_url_from_worktree "$BARE_WT" 88 >/dev/null 2>&1 \
    && fail "url_from_worktree: no-origin worktree must fail (teardown cannot false-land)"
  pass "fm_pr_url_from_worktree builds /pulls/ for Gitea, /pull/ for GitHub, fails without origin"
}

test_url_from_worktree_ssh() {
  local wt="$TMP_ROOT/ssh-wt"
  git init -q "$wt"
  git -C "$wt" remote add origin "git@private-git.ocin.cloud:OpenCloud/core.git"
  [ "$(fm_pr_url_from_worktree "$wt" 12)" = "https://private-git.ocin.cloud/OpenCloud/core/pulls/12" ] \
    || fail "url_from_worktree: gitea SSH origin -> wrong URL"
  pass "fm_pr_url_from_worktree parses git@host:owner/repo SSH remotes to https /pulls/"
}

test_gitea_number_from_branch() {
  [ "$(fm_pr_number_from_branch "$GITEA_WT" feat/merged)" = 70 ] || fail "number_from_branch: feat/merged -> not 70"
  [ "$(fm_pr_number_from_branch "$GITEA_WT" feat/open)" = 71 ] || fail "number_from_branch: feat/open -> not 71"
  fm_pr_number_from_branch "$GITEA_WT" no-such-branch >/dev/null 2>&1 \
    && fail "number_from_branch: unknown branch must fail"
  pass "fm_pr_number_from_branch maps a Gitea branch head to its PR number"
}

test_teardown_chain_merged() {
  local n url state
  n=$(fm_pr_number_from_branch "$GITEA_WT" feat/merged) || fail "chain(merged): number lookup failed"
  url=$(fm_pr_url_from_worktree "$GITEA_WT" "$n") || fail "chain(merged): url build failed"
  state=$(fm_pr_view_state "$url" "$GITEA_WT") || fail "chain(merged): state lookup failed"
  [ "$state" = MERGED ] || fail "chain(merged): resolved state is $state, not MERGED"
  pass "teardown chain (no PR_URL): merged branch resolves number->url->MERGED (cleanup allowed)"
}

test_teardown_chain_open() {
  local n url state
  n=$(fm_pr_number_from_branch "$GITEA_WT" feat/open) || fail "chain(open): number lookup failed"
  url=$(fm_pr_url_from_worktree "$GITEA_WT" "$n") || fail "chain(open): url build failed"
  state=$(fm_pr_view_state "$url" "$GITEA_WT") || fail "chain(open): state lookup failed"
  [ "$state" = OPEN ] || fail "chain(open): resolved state is $state, not OPEN"
  pass "teardown chain (no PR_URL): open branch resolves number->url->OPEN (cleanup refused)"
}

test_teardown_chain_failsafe_no_origin() {
  fm_pr_url_from_worktree "$BARE_WT" 1 >/dev/null 2>&1 \
    && fail "chain(fail-safe): a worktree with no origin must not resolve a PR URL"
  pass "teardown chain fail-safe: no origin -> no PR URL -> teardown cannot false-land unmerged work"
}

test_host_detection
test_parse_accepts_both_hosts
test_parse_rejects_unsafe_and_malformed
test_gitea_state_head
test_gitea_merge_posts_squash
test_github_uses_gh_not_curl
test_url_from_worktree
test_url_from_worktree_ssh
test_gitea_number_from_branch
test_teardown_chain_merged
test_teardown_chain_open
test_teardown_chain_failsafe_no_origin
