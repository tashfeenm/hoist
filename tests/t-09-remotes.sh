#!/usr/bin/env bash
# t-09-remotes — remote URL handling (scp-style SSH, authenticated HTTPS,
# non-GitHub), no userinfo in any output, an existing remote branch, gh
# failing after the push, target moved after prepare, target gone.
. "$(dirname "$0")/lib.sh"
. "$ROOT/scripts/hoist-lib.sh"

# --- (1) URL parsing (unit) ---------------------------------------------------
assert_eq "github.com owner/repo" "$(web_host_path 'git@github.com:owner/repo.git')" "scp-style SSH"
assert_eq "github.com owner/repo" "$(web_host_path 'https://user:TOKEN@github.com/owner/repo.git')" "authenticated HTTPS loses its userinfo"
assert_eq "gitlab.com group/proj" "$(web_host_path 'ssh://git@gitlab.com:2222/group/proj.git')" "ssh:// with port"
assert_eq "example.com x/y" "$(web_host_path 'https://example.com/x/y/')" "generic https, trailing slash"
assert_eq "" "$(web_host_path '/srv/git/repo.git')" "local path is not a web host"
assert_eq "" "$(web_host_path '../origin.git')" "relative path is not a web host"
assert_eq "hidden.example.com" "$(printf 'fatal: unable to access https://u:s3cret@hidden.example.com/x\n' | scrub_urls | sed 's/.*https:\/\///; s/\/.*//')" "scrub_urls strips userinfo"

fixture_new
FILES="src/parser.sh src/report.sh src/legacy.sh t/run.sh scripts/pre-commit.sh bin/widget t/fixtures/keys.txt"
UP="$(tmpdir)/up"
git clone -q "$ORIGIN" "$UP"

# ready_state — prepare + edits + full scan + finish; sets S, TMP, BRANCH
ready_state() {
	# shellcheck disable=SC2086
	hoist prepare --repo "$WORKSHOP" --target main "$@" -- $FILES
	assert_status 0 $? "prepare"
	S="$(state_path)"
	BRANCH="$(state_get "$S" HOIST_BRANCH)"
	"$ROOT/fixtures/demo-edits.sh" --state "$S" >/dev/null 2>&1
	hoist scan --state "$S" --run-gates >/dev/null 2>&1
	hoist finish --state "$S" --title "fix: trim keys" >/dev/null 2>&1
}

# --- (2) authenticated HTTPS remote that cannot be reached: no token anywhere --
git -C "$WORKSHOP" remote add auth 'https://user:TOKEN-SHOULD-NOT-LEAK@github.invalid/o/r.git'
git -C "$WORKSHOP" update-ref refs/remotes/auth/main refs/remotes/origin/main
hoist prepare --repo "$WORKSHOP" --target main --remote auth -- src/parser.sh
assert_status 2 $? "fetching an unreachable authenticated remote fails"
assert_not_grep 'TOKEN-SHOULD-NOT-LEAK' "$HOIST_ERR" "the token is not in prepare's output"
hoist prepare --repo "$WORKSHOP" --target main --remote auth --no-fetch -- src/parser.sh
assert_status 0 $? "--no-fetch prepare against the local remote-tracking ref"
S="$(state_path)"
hoist scan --state "$S" --gates true >/dev/null 2>&1
# shellcheck disable=SC2046  # the IDs are meant to split
hoist acknowledge --state "$S" --reason "test" $(grep '^finding=' "$(state_get "$S" HOIST_TMP)/attest" | sed 's/finding=/--finding /') >/dev/null 2>&1
hoist finish --state "$S" --title "x" >/dev/null 2>&1
hoist push --state "$S" --no-pr
assert_status 2 $? "push cannot reach the remote"
assert_grep 'could not reach auth' "$HOIST_ERR" "  …and says so"
assert_not_grep 'TOKEN-SHOULD-NOT-LEAK' "$HOIST_ERR" "  …without leaking the token"
hoist cleanup --state "$S" --discard >/dev/null 2>&1
git -C "$WORKSHOP" remote remove auth

# --- (3) the branch already exists on the remote -----------------------------
ready_state --branch feature/taken
git -C "$UP" push -q origin "main:refs/heads/feature/taken"
hoist push --state "$S" --no-pr
assert_status 2 $? "push refuses when the branch exists remotely"
assert_grep 'already exists on origin' "$HOIST_ERR" "  …with the reason"
assert_eq "$(git -C "$ORIGIN" rev-parse main)" "$(git -C "$ORIGIN" rev-parse feature/taken)" "the remote branch was not advanced"
hoist cleanup --state "$S" --discard >/dev/null 2>&1
git -C "$UP" push -q origin --delete feature/taken

# --- (4) the lease itself: branch appears between the check and the push ------
# simulate with a pre-push race: create the remote branch from a background
# helper that waits on a FIFO signal the fake `git` wrapper fires. Simpler and
# deterministic: point push at a remote where the branch already exists but
# ls-remote lies. We cannot make ls-remote lie without a wrapper, so this case
# is covered by (3) plus inspection: the push uses --force-with-lease=<ref>:
assert_grep 'force-with-lease="refs/heads/\$B:"' "$(cat "$ROOT/scripts/hoist-push.sh")" "push uses an expect-absent lease (TOCTOU closed at the push itself)"

# --- (5) target moved after prepare -----------------------------------------
ready_state
printf '# moved\n' >>"$UP/Makefile"
git -C "$UP" add -A && git -C "$UP" -c commit.gpgsign=false commit -q -m "target moves" && git -C "$UP" push -q origin main
hoist push --state "$S" --no-pr
assert_status 2 $? "push refuses after the target moved"
assert_grep 'target moved' "$HOIST_ERR" "  …with the reason"
assert_false "nothing reached origin" origin_branch_exists "$ORIGIN" "$BRANCH"
assert_eq "$(state_get "$S" HOIST_BASE_SHA)" "$(git -C "$WORKSHOP" rev-parse "refs/heads/$BRANCH")" "local branch untouched (commit undone or never made)"
hoist cleanup --state "$S" --discard >/dev/null 2>&1

# --- (6) gh present but failing after the push: link fallback ---------------
# origin URL looks like GitHub; an insteadOf rewrite sends the traffic to the
# local bare repo, and a gh stub authenticates but cannot create the PR.
git -C "$WORKSHOP" remote set-url origin https://github.com/acme/widget.git
git -C "$WORKSHOP" config url."$ORIGIN".insteadOf https://github.com/acme/widget.git
SHIM="$(tmpdir)/shim"
mkdir -p "$SHIM"
printf '#!/bin/sh\ncase "$1" in auth) exit 0;; pr) echo "gh: boom" >&2; exit 1;; esac\n' >"$SHIM/gh"
chmod +x "$SHIM/gh"
ready_state
PATH="$SHIM:$PATH" hoist push --state "$S"
assert_status 0 $? "push succeeds even though gh pr create fails"
assert_true "branch reached origin" origin_branch_exists "$ORIGIN" "$BRANCH"
assert_grep 'gh pr create failed after the push' "$HOIST_ERR" "the gh failure is reported"
assert_grep "https://github.com/acme/widget/compare/main\.\.\.$BRANCH" "$HOIST_ERR" "and the compare link is printed"
hoist cleanup --state "$S" >/dev/null 2>&1

# --- (7) no gh at all: compare link; gitlab: MR link; other host: instruction --
BARE_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
[ -x /usr/bin/git ] || ln -s "$(command -v git)" "$SHIM/git"
[ -x /usr/bin/bash ] || [ -x /bin/bash ] || ln -s "$(command -v bash)" "$SHIM/bash"
rm -f "$SHIM/gh"
ready_state
PATH="$SHIM:$BARE_PATH" hoist push --state "$S"
assert_status 0 $? "push without gh"
assert_grep "open the PR:" "$HOIST_ERR" "compare link offered"
assert_grep "https://github.com/acme/widget/compare/main\.\.\.$BRANCH\?expand=1" "$HOIST_ERR" "  …with the right URL"
hoist cleanup --state "$S" >/dev/null 2>&1

git -C "$WORKSHOP" config --unset url."$ORIGIN".insteadOf
git -C "$WORKSHOP" remote set-url origin git@gitlab.com:acme/widget.git
git -C "$WORKSHOP" config url."$ORIGIN".insteadOf git@gitlab.com:acme/widget.git
ready_state
hoist push --state "$S"
assert_status 0 $? "push to a gitlab-looking remote"
assert_grep 'merge_requests/new\?merge_request\[source_branch\]=' "$HOIST_ERR" "GitLab merge-request link"
hoist cleanup --state "$S" >/dev/null 2>&1

git -C "$WORKSHOP" config --unset url."$ORIGIN".insteadOf
git -C "$WORKSHOP" remote set-url origin ssh://git@git.example.org/acme/widget.git
git -C "$WORKSHOP" config url."$ORIGIN".insteadOf ssh://git@git.example.org/acme/widget.git
ready_state
hoist push --state "$S"
assert_status 0 $? "push to an unknown host"
assert_grep "open the PR in your host's UI" "$HOIST_ERR" "generic instruction for unknown hosts"
hoist cleanup --state "$S" >/dev/null 2>&1
git -C "$WORKSHOP" config --unset url."$ORIGIN".insteadOf
git -C "$WORKSHOP" remote set-url origin "$ORIGIN"

# --- (8) target branch gone from the remote ---------------------------------
ready_state
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/other
git -C "$ORIGIN" update-ref -d refs/heads/main
hoist push --state "$S" --no-pr
assert_status 2 $? "push refuses when the target no longer exists"
assert_grep 'no longer exists' "$HOIST_ERR" "  …with the reason"
hoist cleanup --state "$S" --discard >/dev/null 2>&1

done_testing
