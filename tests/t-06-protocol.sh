#!/usr/bin/env bash
# t-06-protocol — scan → finish → push are bound to one tree; nothing skips a
# step, and any edit after the scan invalidates what came before it.
. "$(dirname "$0")/lib.sh"

fixture_new
FILES="src/parser.sh src/report.sh src/legacy.sh t/run.sh scripts/pre-commit.sh"

# shellcheck disable=SC2086
hoist prepare --repo "$WORKSHOP" --target main -- $FILES
assert_status 0 $? "prepare succeeds"
S="$(state_path)"
WT="$(state_get "$S" HOIST_WORKTREE)"
TMP="$(state_get "$S" HOIST_TMP)"
BRANCH="$(state_get "$S" HOIST_BRANCH)"
BASE="$(state_get "$S" HOIST_BASE_SHA)"

# --- push without a scan -----------------------------------------------------
hoist push --state "$S" --no-pr
assert_ne 0 $? "push without a scan is refused"
assert_grep 'attest|scan' "$HOIST_ERR" "push says why"
assert_eq "$BASE" "$(git -C "$WORKSHOP" rev-parse "refs/heads/$BRANCH")" "branch not advanced"
assert_false "nothing reached origin" origin_branch_exists "$ORIGIN" "$BRANCH"

# --- finish without a scan ---------------------------------------------------
hoist finish --state "$S" --title "x"
assert_ne 0 $? "finish without a scan is refused"
assert_no_file "$TMP/receipt" "no receipt without a scan"

# --- a full scan on the raw state: findings, but 4 of 4 ran → attestation ---
hoist scan --state "$S" --run-gates
assert_status 1 $? "scan on the raw fixture reports findings"
assert_file "$TMP/attest" "attestation written when all four checks ran"
attest_before="$(cat "$TMP/attest")"

# --- a partial scan never produces a push-capable attestation ---------------
hoist scan --state "$S" --only secrets
assert_status 1 $? "--only secrets reports findings"
assert_no_file "$TMP/attest" "--only removes/withholds the attestation"
hoist push --state "$S" --no-pr
assert_ne 0 $? "push after a partial scan is refused"

hoist scan --state "$S" --skip-gates
assert_no_file "$TMP/attest" "--skip-gates never yields an attestation"

# --- restore a full attestation, then edit after the scan -------------------
hoist scan --state "$S" --run-gates
assert_status 1 $? "full scan again"
assert_eq "$attest_before" "$(cat "$TMP/attest")" "attestation is deterministic for the same tree"
printf '\n# a late edit\n' >>"$WT/src/report.sh"
hoist finish --state "$S" --title "x"
assert_ne 0 $? "finish after an edit is refused"
assert_grep 'tree changed|re-run hoist scan' "$HOIST_ERR" "finish names the reason"
hoist push --state "$S" --no-pr
assert_ne 0 $? "push after an edit is refused"
assert_false "still nothing on origin" origin_branch_exists "$ORIGIN" "$BRANCH"

# --- acknowledge is bound to the current tree, and refuses unknown IDs ------
hoist scan --state "$S" --run-gates
assert_status 1 $? "rescan after the edit"
ids="$(grep '^finding=' "$TMP/attest" | sed 's/^finding=//')"
first="$(printf '%s\n' "$ids" | head -1)"
assert_ne "" "$first" "attestation lists finding IDs"
hoist acknowledge --state "$S" --finding nope-00000000 --reason "not a real id"
assert_ne 0 $? "acknowledging an unknown ID is refused"
hoist acknowledge --state "$S" --finding "$first" --reason "reviewed: fixture secret, test only"
assert_status 0 $? "acknowledging a real ID works"
assert_file "$TMP/ack" "acknowledgement written"

# --- push refuses while any finding is unacknowledged ----------------------
hoist finish --state "$S" --title "x"
assert_status 0 $? "finish (dry run) works with open findings"
hoist push --state "$S" --no-pr
assert_ne 0 $? "push refuses with unacknowledged findings"
assert_false "still nothing on origin (2)" origin_branch_exists "$ORIGIN" "$BRANCH"

hoist cleanup --state "$S" --discard
assert_status 0 $? "cleanup --discard"

done_testing
