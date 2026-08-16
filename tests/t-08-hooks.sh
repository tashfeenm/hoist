#!/usr/bin/env bash
# t-08-hooks — the workshop's hooks never fire for hoist's own commands;
# clean filters are honoured (scanned bytes are committed bytes) and a
# nondeterministic filter cannot be attested; a failing signer fails loudly.
. "$(dirname "$0")/lib.sh"

fixture_new
FILES="src/parser.sh src/report.sh src/legacy.sh t/run.sh scripts/pre-commit.sh bin/widget t/fixtures/keys.txt"

# --- (1) hooks are live in the workshop … --------------------------------------
git -C "$WORKSHOP" -c user.email=x@example.invalid -c user.name=x commit -q --allow-empty -m probe 2>/dev/null
assert_ne 0 $? "sanity: the workshop's pre-commit hook refuses a direct commit"
assert_no_file "$WORKSHOP/.git/hoist-fixture-hook-fired" "sanity: no checkout marker yet"
# post-index-change fires on every index write (add, restage, worktree add);
# hoist writes the worktree index many times, so this pins the hooks-off claim
# on the one hook the fixture does not plant
printf '#!/bin/sh\ntouch "$(git rev-parse --git-common-dir)/hoist-pic-fired"\n' >"$WORKSHOP/.git/hooks/post-index-change"
chmod +x "$WORKSHOP/.git/hooks/post-index-change"
git -C "$WORKSHOP" add -A >/dev/null 2>&1
git -C "$WORKSHOP" reset -q >/dev/null 2>&1
assert_file "$WORKSHOP/.git/hoist-pic-fired" "sanity: post-index-change hook is live for the workshop's own index writes"
rm -f "$WORKSHOP/.git/hoist-pic-fired"

# … but never for hoist's commands: prepare (worktree add / checkout), push (commit, push)
# shellcheck disable=SC2086
hoist prepare --repo "$WORKSHOP" --target main -- $FILES
assert_status 0 $? "prepare"
S="$(state_path)"
TMP="$(state_get "$S" HOIST_TMP)"
BRANCH="$(state_get "$S" HOIST_BRANCH)"
assert_no_file "$WORKSHOP/.git/hoist-fixture-hook-fired" "post-checkout hook did not fire on worktree add"
"$ROOT/fixtures/demo-edits.sh" --state "$S" >/dev/null 2>&1
hoist scan --state "$S" --run-gates
assert_status 0 $? "scan clean"
hoist finish --state "$S" --title "fix: trim keys" >/dev/null 2>&1
hoist push --state "$S" --no-pr
assert_status 0 $? "push succeeds although pre-commit and pre-push hooks would refuse"
assert_true "branch reached origin" origin_branch_exists "$ORIGIN" "$BRANCH"
assert_not_grep 'workshop .* hook fired' "$HOIST_ERR" "no hook output anywhere"
assert_no_file "$WORKSHOP/.git/hoist-fixture-hook-fired" "post-checkout hook still silent after the whole lifecycle"
assert_no_file "$WORKSHOP/.git/hoist-pic-fired" "post-index-change hook never fired for hoist's index writes"
hoist cleanup --state "$S"
assert_status 0 $? "cleanup"
assert_no_file "$WORKSHOP/.git/hoist-pic-fired" "  …nor for cleanup"
rm -f "$WORKSHOP/.git/hooks/post-index-change"

# --- (2) a deterministic clean filter: scanned bytes are committed bytes --------
# The filter upper-cases; a lower-case token becomes detector-grade only in
# the index blob. The scan must see it — it reads the index, not the disk.
git -C "$WORKSHOP" config filter.up.clean 'tr a-z A-Z'
git -C "$WORKSHOP" config filter.up.smudge cat
printf '*.up filter=up\n' >"$WORKSHOP/.gitattributes"
printf 'akia%s\n' 'q2w3e4r5t6y7u8i9' >"$WORKSHOP/token.up"
hoist prepare --repo "$WORKSHOP" --target main -- token.up .gitattributes
assert_status 0 $? "prepare with a clean filter configured"
S="$(state_path)"
WT="$(state_get "$S" HOIST_WORKTREE)"
assert_eq "AKIA"'Q2W3E4R5T6Y7U8I9' "$(git -C "$WT" cat-file blob :0:token.up)" "the index blob is the filtered (upper-case) content"
assert_eq "akiaq2w3e4r5t6y7u8i9" "$(cat "$WT/token.up")" "the worktree file is the unfiltered content"
hoist scan --state "$S" --only secrets
assert_grep 'token\.up:1 .*aws' "$HOIST_ERR" "the token that exists only after the filter is flagged (index blobs are scanned)"
hoist cleanup --state "$S" --discard >/dev/null 2>&1

# --- (3) a nondeterministic clean filter cannot be attested ---------------------
git -C "$WORKSHOP" config filter.up.clean 'sh -c "cat; echo $$"'
hoist prepare --repo "$WORKSHOP" --target main -- token.up .gitattributes
S="$(state_path)"
TMP="$(state_get "$S" HOIST_TMP)"
hoist scan --state "$S" --gates true
assert_grep 'changed across the gates run' "$HOIST_ERR" "scan notices the tree is not stable across a restage"
assert_no_file "$TMP/attest" "  …and writes no attestation"
hoist finish --state "$S" --title "x"
assert_status 2 $? "finish refuses: nothing attests this tree"
hoist push --state "$S" --no-pr
assert_ne 0 $? "push refuses too"
hoist cleanup --state "$S" --discard >/dev/null 2>&1
git -C "$WORKSHOP" config --unset filter.up.clean
git -C "$WORKSHOP" config --unset filter.up.smudge
rm -f "$WORKSHOP/.gitattributes" "$WORKSHOP/token.up"

# --- (4) signing is left as configured: a failing signer fails the push loudly --
SIGNER="$(tmpdir)/gpg"
printf '#!/bin/sh\necho "fake signer: refusing" >&2\nexit 2\n' >"$SIGNER"
chmod +x "$SIGNER"
git -C "$WORKSHOP" config commit.gpgsign true
git -C "$WORKSHOP" config gpg.program "$SIGNER"
git -C "$WORKSHOP" config user.signingkey FAKE
# shellcheck disable=SC2086
hoist prepare --repo "$WORKSHOP" --target main -- $FILES
S="$(state_path)"
BRANCH="$(state_get "$S" HOIST_BRANCH)"
"$ROOT/fixtures/demo-edits.sh" --state "$S" >/dev/null 2>&1
hoist scan --state "$S" --run-gates >/dev/null 2>&1
hoist finish --state "$S" --title "fix: trim keys" >/dev/null 2>&1
hoist push --state "$S" --no-pr
assert_status 2 $? "push fails when the configured signer fails"
assert_grep 'signing' "$HOIST_ERR" "  …and mentions signing"
assert_grep 'fake signer: refusing' "$HOIST_ERR" "  …showing git's own error"
assert_false "nothing reached origin" origin_branch_exists "$ORIGIN" "$BRANCH"
git -C "$WORKSHOP" config --unset commit.gpgsign
git -C "$WORKSHOP" config --unset gpg.program
git -C "$WORKSHOP" config --unset user.signingkey
# with signing off again the same state pushes fine (state survived the failure)
hoist push --state "$S" --no-pr
assert_status 0 $? "push succeeds once signing is fixed — no re-prepare needed"
hoist cleanup --state "$S" >/dev/null 2>&1

done_testing
