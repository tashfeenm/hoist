#!/usr/bin/env bash
# t-11-integrity — the bindings the Sol v1 review asked for: frozen manifest,
# remote endpoints, target/branch in the attestation, acknowledgements in the
# receipt and the commit message, raw (no textconv) review, ref hooks,
# unregistered worktrees, secret acknowledgements, long bodies; and from the
# Sol v2 review: every attestation field (a table of single edits), the
# EFFECTIVE remote endpoints (extra url, insteadOf, pushInsteadOf), and
# cleanup with an edited branch and no worktree left to prove anything.
. "$(dirname "$0")/lib.sh"

fixture_new
FILES="src/parser.sh src/report.sh src/legacy.sh t/run.sh scripts/pre-commit.sh bin/widget t/fixtures/keys.txt"
UP="$(tmpdir)/up"
git clone -q "$ORIGIN" "$UP"

# ready — prepare + demo edits + full scan + finish; sets S TMP WT BRANCH
ready() {
	# shellcheck disable=SC2086
	hoist prepare --repo "$WORKSHOP" --target main -- $FILES
	assert_status 0 $? "prepare"
	S="$(state_path)"
	TMP="$(state_get "$S" HOIST_TMP)"
	WT="$(state_get "$S" HOIST_WORKTREE)"
	BRANCH="$(state_get "$S" HOIST_BRANCH)"
	"$ROOT/fixtures/demo-edits.sh" --state "$S" >/dev/null 2>&1
	hoist scan --state "$S" --run-gates >/dev/null 2>&1
	hoist finish --state "$S" --title "fix: trim keys" >/dev/null 2>&1
}

# --- (1) a gate that rewrites the manifest --------------------------------------
# shellcheck disable=SC2086
hoist prepare --repo "$WORKSHOP" --target main -- $FILES
S="$(state_path)"
TMP="$(state_get "$S" HOIST_TMP)"
hoist scan --state "$S" --gates 'echo src/config.sh >>../manifest'
assert_status 2 $? "a gate that appends to the manifest aborts the scan"
assert_grep 'modified the manifest' "$HOIST_ERR" "  …naming the reason"
assert_no_file "$TMP/attest" "  …with no attestation"
hoist scan --state "$S" --gates true
assert_status 2 $? "every later command refuses the altered manifest"
assert_grep 'manifest has been modified since prepare' "$HOIST_ERR" "  …at state load"
hoist cleanup --state "$S" --discard
assert_status 0 $? "cleanup --discard still works (lenient load, layout intact)"

# --- (2) a gate that adds a push URL; a push URL added after finish -----------
# shellcheck disable=SC2086
hoist prepare --repo "$WORKSHOP" --target main -- $FILES
S="$(state_path)"
TMP="$(state_get "$S" HOIST_TMP)"
hoist scan --state "$S" --gates 'git config remote.origin.pushurl /nowhere/else.git'
assert_status 1 $? "scan reports the configuration change"
assert_grep 'changed git configuration' "$HOIST_ERR" "  …as a gates finding"
assert_no_file "$TMP/attest" "  …with no attestation"
git -C "$WORKSHOP" config --unset remote.origin.pushurl
hoist cleanup --state "$S" --discard >/dev/null 2>&1

ready
git -C "$WORKSHOP" config remote.origin.pushurl /nowhere/else.git
hoist push --state "$S" --no-pr
assert_status 2 $? "push refuses when a push URL appeared after prepare"
assert_grep 'push URL .* changed since prepare' "$HOIST_ERR" "  …with the reason"
assert_false "nothing reached origin" origin_branch_exists "$ORIGIN" "$BRANCH"
git -C "$WORKSHOP" config --unset remote.origin.pushurl
git -C "$WORKSHOP" remote set-url origin "$ORIGIN.moved"
hoist push --state "$S" --no-pr
assert_status 2 $? "push refuses when the fetch URL changed after prepare"
git -C "$WORKSHOP" remote set-url origin "$ORIGIN"
hoist push --state "$S" --no-pr
assert_status 0 $? "push succeeds once the endpoints are back to what was bound"
hoist cleanup --state "$S" >/dev/null 2>&1

# --- (3) the target/branch in the state is edited after the dry run -----------
git -C "$ORIGIN" update-ref refs/heads/other refs/heads/main
git -C "$WORKSHOP" fetch -q origin
ready
sed "s|^HOIST_TARGET=.*|HOIST_TARGET=other|" "$S" >"$S.new" && mv "$S.new" "$S"
hoist push --state "$S" --no-pr
assert_status 2 $? "push refuses when the state's target no longer matches the attestation"
assert_grep 'different target' "$HOIST_ERR" "  …with the reason"
assert_false "nothing on origin/other-based branch" origin_branch_exists "$ORIGIN" "$BRANCH"
sed "s|^HOIST_TARGET=.*|HOIST_TARGET=main|" "$S" >"$S.new" && mv "$S.new" "$S"
hoist cleanup --state "$S" --discard >/dev/null 2>&1

# --- (4) acknowledgements are receipt-bound and land in the reviewed message --
# shellcheck disable=SC2086
hoist prepare --repo "$WORKSHOP" --target main -- $FILES
S="$(state_path)"
TMP="$(state_get "$S" HOIST_TMP)"
BRANCH="$(state_get "$S" HOIST_BRANCH)"
"$ROOT/fixtures/demo-edits.sh" --state "$S" >/dev/null 2>&1
printf '# /Users/pat/notes\n' >>"$(state_get "$S" HOIST_WORKTREE)/src/report.sh"
hoist scan --state "$S" --run-gates >/dev/null 2>&1
ids="$(grep '^finding=' "$TMP/attest" | sed 's/finding=//')"
assert_grep '^personal-' "$ids" "a personal finding to acknowledge"
hoist finish --state "$S" --title "fix: trim keys" >/dev/null 2>&1
assert_file "$TMP/receipt" "receipt before acknowledging"
for id in $ids; do hoist acknowledge --state "$S" --finding "$id" --reason "reviewed: fixture note" >/dev/null 2>&1; done
assert_no_file "$TMP/receipt" "acknowledging voids the receipt"
hoist push --state "$S" --no-pr
assert_status 2 $? "push refuses without a fresh receipt"
hoist finish --state "$S" --title "fix: trim keys"
assert_status 0 $? "finish again"
assert_grep 'acknowledged: reviewed: fixture note' "$HOIST_ERR" "finish shows the acknowledgement"
assert_grep '^Hoist-Acknowledged: personal-.* — reviewed: fixture note' "$(cat "$TMP/message")" "the trailer is part of the reviewed message"
# tamper with the acknowledgement after the dry run
sed 's/reviewed: fixture note/something else/' "$TMP/ack" >"$TMP/ack.new" && mv "$TMP/ack.new" "$TMP/ack"
hoist push --state "$S" --no-pr
assert_status 2 $? "push refuses an acknowledgement edited after the dry run"
sed 's/something else/reviewed: fixture note/' "$TMP/ack" >"$TMP/ack.new" && mv "$TMP/ack.new" "$TMP/ack"
hoist push --state "$S" --no-pr
assert_status 0 $? "push with the reviewed acknowledgement"
tip="$(git -C "$ORIGIN" rev-parse "refs/heads/$BRANCH")"
assert_eq "$(cat "$TMP/message")" "$(git -C "$ORIGIN" log -1 --format=%B "$tip" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')" "the commit message is byte-for-byte the reviewed message"
hoist cleanup --state "$S" >/dev/null 2>&1

# --- (5) secrets findings cannot be acknowledged without --allow-secret -------
# shellcheck disable=SC2086
hoist prepare --repo "$WORKSHOP" --target main -- $FILES
S="$(state_path)"
TMP="$(state_get "$S" HOIST_TMP)"
hoist scan --state "$S" --gates true >/dev/null 2>&1
sid="$(grep '^finding=secrets-' "$TMP/attest" | head -1 | sed 's/finding=//')"
hoist acknowledge --state "$S" --finding "$sid" --reason "test"
assert_status 2 $? "acknowledging a secrets finding is refused by default"
assert_grep 'remove the credential' "$HOIST_ERR" "  …with the instruction"
hoist acknowledge --state "$S" --finding "$sid" --reason "documented example value" --allow-secret
assert_status 0 $? "--allow-secret acknowledges it"
assert_grep 'allow-secret' "$(cat "$TMP/ack")" "  …and the flag is recorded in the reason"
hoist cleanup --state "$S" --discard >/dev/null 2>&1

# --- (6) textconv cannot hide raw content from the scan or the dry run --------
git -C "$WORKSHOP" config diff.hide.textconv 'sed s/pat/XX/g'
printf '*.note diff=hide\n' >"$WORKSHOP/.gitattributes"
printf 'home: /Users/pat/secret-notes\n' >"$WORKSHOP/private.note"
hoist prepare --repo "$WORKSHOP" --target main -- private.note .gitattributes
S="$(state_path)"
TMP="$(state_get "$S" HOIST_TMP)"
hoist scan --state "$S" --gates true
assert_grep 'private\.note:1 .*looks personal' "$HOIST_ERR" "personal check sees the raw blob despite textconv"
ids="$(grep '^finding=' "$TMP/attest" | sed 's/finding=//')"
for id in $ids; do hoist acknowledge --state "$S" --finding "$id" --reason "test" >/dev/null 2>&1; done
hoist finish --state "$S" --title "x"
assert_grep '\+home: /Users/pat/secret-notes' "$HOIST_ERR" "the dry-run diff shows the raw bytes, not the textconv output"
hoist cleanup --state "$S" --discard >/dev/null 2>&1
git -C "$WORKSHOP" config --unset diff.hide.textconv
rm -f "$WORKSHOP/.gitattributes" "$WORKSHOP/private.note"

# --- (7) a reference-transaction hook that refuses everything ------------------
if git -C "$WORKSHOP" --version | awk '{split($3,v,"."); exit !(v[1]>2 || (v[1]==2 && v[2]>=28))}'; then
	printf '#!/bin/sh\necho "reference-transaction hook fired" >&2\nexit 1\n' >"$WORKSHOP/.git/hooks/reference-transaction"
	chmod +x "$WORKSHOP/.git/hooks/reference-transaction"
	git -C "$WORKSHOP" update-ref refs/heads/probe HEAD 2>/dev/null
	assert_ne 0 $? "sanity: the hook refuses a direct ref update"
	ready
	hoist push --state "$S" --no-pr
	assert_status 0 $? "prepare, commit and push succeed with a refusing reference-transaction hook"
	assert_not_grep 'reference-transaction hook fired' "$HOIST_ERR" "  …and the hook never fired for hoist"
	hoist cleanup --state "$S"
	assert_status 0 $? "cleanup (branch -D) succeeds too"
	rm -f "$WORKSHOP/.git/hooks/reference-transaction"
else
	skip "reference-transaction hook needs git 2.28+"
fi

# --- (8) a present-but-unregistered worktree cannot be audited ------------------
# shellcheck disable=SC2086
hoist prepare --repo "$WORKSHOP" --target main -- $FILES
S="$(state_path)"
TMP="$(state_get "$S" HOIST_TMP)"
WT="$(state_get "$S" HOIST_WORKTREE)"
gitfile="$(cat "$WT/.git")"
gitdir="${gitfile#gitdir: }"
rm -r "$gitdir" # git forgets the worktree; the directory stays
hoist cleanup --state "$S"
assert_status 1 $? "cleanup refuses: present but unregistered, cannot audit"
assert_grep 'cannot be audited' "$HOIST_ERR" "  …with the reason"
hoist cleanup --state "$S" --discard
assert_status 0 $? "cleanup --discard removes it"
assert_no_file "$TMP" "  …state dir gone"

# --- (9) an edited HOIST_BRANCH cannot make cleanup delete an unrelated branch --
git -C "$WORKSHOP" branch victim
# shellcheck disable=SC2086
hoist prepare --repo "$WORKSHOP" --target main -- $FILES
S="$(state_path)"
sed "s|^HOIST_BRANCH=.*|HOIST_BRANCH=victim|" "$S" >"$S.new" && mv "$S.new" "$S"
hoist cleanup --state "$S" --discard
assert_status 0 $? "cleanup completes"
assert_true "the unrelated branch survives" git -C "$WORKSHOP" rev-parse --verify -q refs/heads/victim
assert_grep 'kept' "$HOIST_ERR" "  …and says the branch was kept"
git -C "$WORKSHOP" branch -D victim >/dev/null
git -C "$WORKSHOP" branch --list 'hoist/*' | sed 's/^[* ]*//' | while read -r b; do [ -n "$b" ] && git -C "$WORKSHOP" branch -D "$b" >/dev/null 2>&1; done

# --- (10) a very long body truncates instead of failing ------------------------
# shellcheck disable=SC2086
hoist prepare --repo "$WORKSHOP" --target main -- $FILES
S="$(state_path)"
TMP="$(state_get "$S" HOIST_TMP)"
"$ROOT/fixtures/demo-edits.sh" --state "$S" >/dev/null 2>&1
hoist scan --state "$S" --run-gates >/dev/null 2>&1
long="$(awk 'BEGIN{for(i=0;i<3000;i++) printf "line %d of a long body\n", i}')"
hoist finish --state "$S" --title "fix: trim keys" --body "$long"
assert_status 0 $? "finish with a 60KB body"
assert_true "message is bounded" test "$(wc -c <"$TMP/message")" -lt 4200
hoist finish --state "$S" --title "fix: trim keys" --body "$(printf 'carriage\r\nreturns\r\n')"
assert_status 0 $? "finish with CRLF body"
assert_eq "0" "$(tr -cd '\r' <"$TMP/message" | wc -c | tr -d ' ')" "CR stripped from the message"
hoist cleanup --state "$S" --discard >/dev/null 2>&1

# --- (11) every attestation field is verified — a table of single edits --------
# Each edit is made to a copy of the attestation written by a real full scan;
# push must refuse with the specific reason and nothing may reach origin.
ready
cp "$TMP/attest" "$TMP/attest.orig"
mutate() { # mutate <sed-expr> <label> <expected-reason>
	sed "$1" "$TMP/attest.orig" >"$TMP/attest"
	hoist push --state "$S" --no-pr
	assert_status 2 $? "push refuses: $2"
	assert_grep "$3" "$HOIST_ERR" "  …with the reason ($3)"
	assert_false "  …nothing reached origin" origin_branch_exists "$ORIGIN" "$BRANCH"
}
append() { # append <line> <label> <expected-reason>
	{ cat "$TMP/attest.orig"; printf '%s\n' "$1"; } >"$TMP/attest"
	hoist push --state "$S" --no-pr
	assert_status 2 $? "push refuses: $2"
	assert_grep "$3" "$HOIST_ERR" "  …with the reason ($3)"
	assert_false "  …nothing reached origin" origin_branch_exists "$ORIGIN" "$BRANCH"
}
mutate 's|^target=.*|target=origin/other|' 'edited target' 'different target'
mutate 's|^branch=.*|branch=hoist/other|' 'edited branch' 'different branch'
mutate 's|^base=.*|base=0000000000000000000000000000000000000000|' 'edited base' 'different base'
mutate 's|^tree=.*|tree=0000000000000000000000000000000000000000|' 'edited tree' 'tree changed'
mutate 's|^manifest=.*|manifest=0000000000000000000000000000000000000000|' 'edited manifest digest' 'different manifest'
for c in gates secrets personal drift; do
	mutate "s|^check.$c=.*|check.$c=bash:skipped|" "check.$c marked skipped" 'not run'
	mutate "s|^check.$c=.*|check.$c=bash:notrun|" "check.$c marked not run" 'not run'
done
mutate 's|^findings=.*|findings=7|' 'edited finding count' 'finding count'
mutate 's|^findings_digest=.*|findings_digest=0000000000000000000000000000000000000000|' 'edited findings digest' 'findings digest'
mutate 's|^id=.*|id=other|' 'edited id' 'different hoist'
mutate 's|^version=.*|version=2|' 'edited version' 'unsupported attestation version'
mutate '/^branch=/d' 'missing key' 'missing key'
append 'bogus=1' 'unknown key' 'unknown key'
append 'tree=deadbeef' 'duplicate key' 'repeats key'
append 'no-equals-sign' 'malformed line' 'malformed line'
append '' 'empty line' 'empty line'
cp "$TMP/attest.orig" "$TMP/attest"
hoist push --state "$S" --no-pr
assert_status 0 $? "the untouched attestation still pushes"
hoist cleanup --state "$S" >/dev/null 2>&1

# --- (12) the EFFECTIVE remote endpoints are bound, not just the stored values --
# git pushes to every remote.<name>.url when there is no pushurl, and
# url.<base>.insteadOf / pushInsteadOf rewrite the destination without touching
# either stored value; all three must be caught after finish.
ready
git -C "$WORKSHOP" config --add remote.origin.url /nowhere/second.git
hoist push --state "$S" --no-pr
assert_status 2 $? "push refuses when a second remote.origin.url appeared (git would push to both)"
assert_grep 'changed since prepare' "$HOIST_ERR" "  …with the reason"
assert_false "  …nothing reached origin" origin_branch_exists "$ORIGIN" "$BRANCH"
git -C "$WORKSHOP" config --unset remote.origin.url '/nowhere/second\.git'
git -C "$WORKSHOP" config url./nowhere/rewritten.git.insteadOf "$ORIGIN"
hoist push --state "$S" --no-pr
assert_status 2 $? "push refuses when an insteadOf rewrite redirects the remote (stored URL unchanged)"
assert_grep 'effective fetch URL' "$HOIST_ERR" "  …naming the effective endpoint"
assert_false "  …nothing reached origin" origin_branch_exists "$ORIGIN" "$BRANCH"
git -C "$WORKSHOP" config --unset url./nowhere/rewritten.git.insteadOf
git -C "$WORKSHOP" config url./nowhere/rewritten.git.pushInsteadOf "$ORIGIN"
hoist push --state "$S" --no-pr
assert_status 2 $? "push refuses when a pushInsteadOf rewrite redirects the push"
assert_grep 'effective push URL' "$HOIST_ERR" "  …naming the effective push endpoint"
assert_false "  …nothing reached origin" origin_branch_exists "$ORIGIN" "$BRANCH"
git -C "$WORKSHOP" config --unset url./nowhere/rewritten.git.pushInsteadOf
hoist push --state "$S" --no-pr
assert_status 0 $? "push succeeds once the effective endpoints are back to what was bound"
hoist cleanup --state "$S" >/dev/null 2>&1
git -C "$WORKSHOP" config --add remote.origin.url /nowhere/second.git
# shellcheck disable=SC2086
hoist prepare --repo "$WORKSHOP" --target main -- $FILES
assert_status 2 $? "prepare refuses a remote with two URLs"
assert_grep 'exactly one destination' "$HOIST_ERR" "  …with the reason"
git -C "$WORKSHOP" config --unset remote.origin.url '/nowhere/second\.git'

# --- (13) edited HOIST_BRANCH + a vanished, pruned worktree: branch still kept --
# (9) proved the live-worktree case; here the proof source is gone entirely.
git -C "$WORKSHOP" branch victim2
# shellcheck disable=SC2086
hoist prepare --repo "$WORKSHOP" --target main -- $FILES
S="$(state_path)"
WT="$(state_get "$S" HOIST_WORKTREE)"
REAL_BRANCH="$(state_get "$S" HOIST_BRANCH)"
sed "s|^HOIST_BRANCH=.*|HOIST_BRANCH=victim2|" "$S" >"$S.new" && mv "$S.new" "$S"
rm -r "$WT"
git -C "$WORKSHOP" worktree prune
hoist cleanup --state "$S" --discard
assert_status 0 $? "cleanup completes with no worktree left to prove anything"
assert_true "the unrelated branch survives" git -C "$WORKSHOP" show-ref --verify -q refs/heads/victim2
assert_grep 'kept' "$HOIST_ERR" "  …and says the branch was kept"
git -C "$WORKSHOP" branch -D victim2 >/dev/null
git -C "$WORKSHOP" branch -D "$REAL_BRANCH" >/dev/null 2>&1 || true

# --- (14) a state written before the effective-endpoint keys existed -----------
# It is refused for anything that could push, with the reason, and cleanup can
# still remove it.
# shellcheck disable=SC2086
hoist prepare --repo "$WORKSHOP" --target main -- $FILES
S="$(state_path)"
grep -v -e '^HOIST_FETCH_EFFECTIVE=' -e '^HOIST_PUSH_EFFECTIVE=' "$S" >"$S.new" && mv "$S.new" "$S"
hoist scan --state "$S" --gates true
assert_status 2 $? "scan refuses a state without the effective endpoints"
assert_grep 'no effective remote endpoints' "$HOIST_ERR" "  …with the reason"
hoist cleanup --state "$S" --discard
assert_status 0 $? "cleanup --discard still removes it"

done_testing
