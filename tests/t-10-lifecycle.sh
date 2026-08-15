#!/usr/bin/env bash
# t-10-lifecycle — locks, the .hoist workspace, the owned exclude line,
# rollback, Ctrl-C during a hanging gate, cleanup twice, cleanup after the
# worktree vanished, the dispatcher.
. "$(dirname "$0")/lib.sh"

fixture_new
FILES="src/parser.sh src/report.sh src/legacy.sh t/run.sh scripts/pre-commit.sh"

# --- (1) dispatcher ---------------------------------------------------------
hoist version
assert_status 0 $? "hoist version"
assert_grep '^hoist 0\.1\.0$' "$HOIST_OUT" "version string"
hoist help
assert_status 0 $? "hoist help"
assert_grep 'hoist prepare' "$HOIST_ERR" "help lists the commands"
assert_not_grep 'set -' "$HOIST_ERR" "help prints no code"
hoist help scan
assert_status 0 $? "hoist help scan"
assert_grep -- '--run-gates' "$HOIST_ERR" "subcommand help"
assert_not_grep 'set -euo|HERE=' "$HOIST_ERR" "subcommand help prints no code"
hoist bogus
assert_status 2 $? "unknown command exits 2"
assert_grep 'no such command: bogus' "$HOIST_ERR" "  …and says so"
hoist prepare --help
assert_status 0 $? "prepare --help"
assert_not_grep 'set -euo|HERE=' "$HOIST_ERR" "prepare help prints no code"
hoist scan
assert_status 2 $? "scan without --state exits 2 with usage"

# --- (2) the owned exclude line ---------------------------------------------
EXCL="$WORKSHOP/.git/info/exclude"
mkdir -p "$WORKSHOP/.git/info"
printf '# mine\n*.tmp' >"$EXCL" # pre-existing content, no trailing newline
# shellcheck disable=SC2086
hoist prepare --repo "$WORKSHOP" --target main -- $FILES
assert_status 0 $? "prepare"
S="$(state_path)"
assert_grep '^\*\.tmp$' "$(cat "$EXCL")" "pre-existing exclude line preserved intact"
assert_grep '^# mine$' "$(cat "$EXCL")" "pre-existing comment preserved"
assert_eq "1" "$(grep -c '^/\.hoist/$' "$EXCL")" "exactly one owned /.hoist/ line"
assert_true ".hoist is ignored" git -C "$WORKSHOP" check-ignore -q .hoist/anything
assert_eq "" "$(git -C "$WORKSHOP" status --porcelain --untracked=all | grep '\.hoist' || true)" ".hoist never shows in status"
hoist cleanup --state "$S" --discard >/dev/null 2>&1
# shellcheck disable=SC2086
hoist prepare --repo "$WORKSHOP" --target main -- $FILES
S="$(state_path)"
assert_eq "1" "$(grep -c '^/\.hoist/$' "$EXCL")" "still exactly one owned line after a second prepare (idempotent)"
hoist cleanup --state "$S" --discard >/dev/null 2>&1
assert_eq "1" "$(grep -c '^/\.hoist/$' "$EXCL")" "cleanup leaves the owned line in place"

# a higher-precedence negation defeats the rule → prepare refuses
printf '!/.hoist/\n' >>"$WORKSHOP/.gitignore"
# shellcheck disable=SC2086
hoist prepare --repo "$WORKSHOP" --target main -- $FILES
assert_status 2 $? "prepare refuses when /.hoist/ would not actually be ignored"
assert_grep 'exclude rule does not take effect' "$HOIST_ERR" "  …with the reason"
assert_no_file "$WORKSHOP/.hoist" "  …and creates nothing"
rm "$WORKSHOP/.gitignore"

# --- (3) a bad pre-existing .hoist ------------------------------------------
ln -s /tmp "$WORKSHOP/.hoist"
# shellcheck disable=SC2086
hoist prepare --repo "$WORKSHOP" --target main -- $FILES
assert_status 2 $? "symlinked .hoist refused"
rm "$WORKSHOP/.hoist"
printf 'x\n' >"$WORKSHOP/.hoist"
# shellcheck disable=SC2086
hoist prepare --repo "$WORKSHOP" --target main -- $FILES
assert_status 2 $? "non-directory .hoist refused"
rm "$WORKSHOP/.hoist"
mkdir -p "$WORKSHOP/.hoist" && printf 'x\n' >"$WORKSHOP/.hoist/tracked" && git -C "$WORKSHOP" add -f .hoist/tracked
# shellcheck disable=SC2086
hoist prepare --repo "$WORKSHOP" --target main -- $FILES
assert_status 2 $? "tracked files under .hoist refused"
assert_grep 'tracked' "$HOIST_ERR" "  …with the reason"
git -C "$WORKSHOP" rm -q --cached .hoist/tracked && rm -r "$WORKSHOP/.hoist"

# --- (4) locks --------------------------------------------------------------
# shellcheck disable=SC2086
hoist prepare --repo "$WORKSHOP" --target main -- $FILES
S="$(state_path)"
TMP="$(state_get "$S" HOIST_TMP)"
mkdir "$TMP/lock" && printf '99999\n' >"$TMP/lock/pid"
hoist scan --state "$S" --skip-gates
assert_status 2 $? "a held state lock refuses a second command"
assert_grep 'another hoist command is running.*pid 99999' "$HOIST_ERR" "  …naming the lock and pid"
rm -r "$TMP/lock"
COMMON="$WORKSHOP/.git"
mkdir "$COMMON/hoist.lock" && printf '99999\n' >"$COMMON/hoist.lock/pid"
hoist prepare --repo "$WORKSHOP" --target main -- src/parser.sh
assert_status 2 $? "a held repo lock refuses a second prepare"
assert_grep 'repository lock.*pid 99999' "$HOIST_ERR" "  …naming the lock"
hoist cleanup --state "$S" --discard
assert_status 2 $? "and refuses cleanup"
rm -r "$COMMON/hoist.lock"
hoist scan --state "$S" --skip-gates >/dev/null 2>&1
assert_no_file "$TMP/lock" "the state lock is released after a command"

# --- (5) Ctrl-C during a hanging gate ----------------------------------------
# Run the scan in its own process group (set -m), wait for the gate's marker,
# send SIGINT to the whole group like a terminal would, and wait on the exact
# pid. No sleeps as barriers.
WT="$(state_get "$S" HOIST_WORKTREE)"
rm -f "$WT/.gate-started"
set -m
"$HOIST_BIN" scan --state "$S" --gates 'touch .gate-started; sleep 60' >/dev/null 2>"$TMP/int.err" &
pid=$!
n=0
while [ ! -f "$WT/.gate-started" ] && [ "$n" -lt 200 ]; do
	sleep 0.05
	n=$((n + 1))
done
assert_file "$WT/.gate-started" "the hanging gate started"
kill -INT -- "-$pid" 2>/dev/null || kill -INT "$pid"
wait "$pid" 2>/dev/null
rc=$?
set +m
assert_ne 0 "$rc" "interrupted scan exits nonzero ($rc)"
assert_no_file "$TMP/attest" "no attestation after an interrupted scan"
assert_no_file "$TMP/lock" "state lock released on SIGINT"
hoist scan --state "$S" --gates true
assert_grep '4 of 4 checks ran' "$HOIST_ERR" "the next scan runs normally (no stale lock)"
hoist cleanup --state "$S" --discard >/dev/null 2>&1

# --- (6) cleanup twice, and cleanup after the worktree vanished --------------
# shellcheck disable=SC2086
hoist prepare --repo "$WORKSHOP" --target main -- $FILES
S="$(state_path)"
TMP="$(state_get "$S" HOIST_TMP)"
WT="$(state_get "$S" HOIST_WORKTREE)"
B="$(state_get "$S" HOIST_BRANCH)"
hoist cleanup --state "$S" --discard
assert_status 0 $? "cleanup"
hoist cleanup --state "$S" --discard
assert_status 2 $? "second cleanup: the state file is gone, refused cleanly"
assert_grep 'no state file' "$HOIST_ERR" "  …with the reason"

# shellcheck disable=SC2086
hoist prepare --repo "$WORKSHOP" --target main -- $FILES
S="$(state_path)"
TMP="$(state_get "$S" HOIST_TMP)"
WT="$(state_get "$S" HOIST_WORKTREE)"
B="$(state_get "$S" HOIST_BRANCH)"
rm -r "$WT" # someone deleted the worktree directory by hand
hoist cleanup --state "$S" --discard
assert_status 2 $? "cleanup with a vanished worktree reports what to do"
assert_grep 'git -C .* worktree prune' "$HOIST_ERR" "  …the exact prune command"
git -C "$WORKSHOP" worktree prune
hoist cleanup --state "$S" --discard
assert_status 0 $? "cleanup completes after the prune"
assert_no_file "$TMP" "state dir gone"
assert_false "branch gone" git -C "$WORKSHOP" rev-parse --verify -q "refs/heads/$B"

# --- (7) prepare refuses a branch that already exists ------------------------
git -C "$WORKSHOP" branch taken
hoist prepare --repo "$WORKSHOP" --target main --branch taken -- src/parser.sh
assert_status 2 $? "existing local branch name refused"
assert_grep 'already exists' "$HOIST_ERR" "  …with the reason"
git -C "$WORKSHOP" branch -D taken >/dev/null

# --- (8) prepare from a subdirectory with --repo . ---------------------------
(cd "$WORKSHOP/src" && "$HOIST_BIN" prepare --repo . --target main -- src/parser.sh >"$WORKSHOP/../out" 2>/dev/null)
assert_status 0 $? "prepare with --repo . from a subdirectory (paths are repo-root-relative)"
S="$(tail -1 "$WORKSHOP/../out")"
hoist cleanup --state "$S" --discard >/dev/null 2>&1

done_testing
