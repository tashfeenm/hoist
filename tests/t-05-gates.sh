#!/usr/bin/env bash
# t-05-gates — gates run first, cannot false-pass, and cannot smuggle an
# unscanned tree or a foreign commit past the attestation.
. "$(dirname "$0")/lib.sh"

FILES="src/parser.sh src/report.sh src/legacy.sh t/run.sh scripts/pre-commit.sh"
# a detector-grade token, assembled so this file stays scanner-clean
TOKEN="AKIA"'Q2W3E4R5''T6Y7U8I9'

# --- (1) a passing gate that appends a secret to a hoisted file ------------
fixture_new
# shellcheck disable=SC2086
hoist prepare --repo "$WORKSHOP" --target main -- $FILES
assert_status 0 $? "prepare"
S="$(state_path)"
TMP="$(state_get "$S" HOIST_TMP)"
WT="$(state_get "$S" HOIST_WORKTREE)"

# first run mutates the tree (and exits 0); a marker makes it converge on the
# second run, the way an idempotent formatter would
GATE="if [ ! -f .gate-ran ]; then printf '\nAWS_KEY=$TOKEN\n' >>src/parser.sh; touch .gate-ran; fi"
hoist scan --state "$S" --gates "$GATE"
assert_status 1 $? "scan reports the mutation"
assert_grep 'changed across the gates run' "$HOIST_ERR" "mutation is named"
assert_grep 'NO attestation' "$HOIST_ERR" "no attestation announced"
assert_no_file "$TMP/attest" "no attestation after a gate mutation"
hoist push --state "$S" --no-pr
assert_ne 0 $? "push refused after a gate mutation"

# second run: the gate converges, and the secrets check now sees the appended
# token in the NEW tree (T1 is scanned, not T0)
hoist scan --state "$S" --gates "$GATE"
assert_status 1 $? "second scan completes with findings"
assert_file "$TMP/attest" "attestation on the converged tree"
assert_grep 'src/parser\.sh:[0-9]+ .*(aws|generic-api-key)' "$HOIST_ERR" "the token the gate appended is caught in the post-gate tree"
assert_eq "$(git -C "$WT" write-tree)" "$(grep '^tree=' "$TMP/attest" | sed 's/tree=//')" "attested tree is the post-gate tree"
hoist cleanup --state "$S" --discard >/dev/null 2>&1

# --- (2) a gate that creates a commit -------------------------------------
fixture_new
# shellcheck disable=SC2086
hoist prepare --repo "$WORKSHOP" --target main -- $FILES
assert_status 0 $? "prepare (2)"
S="$(state_path)"
TMP="$(state_get "$S" HOIST_TMP)"
hoist scan --state "$S" --gates 'git -c core.hooksPath=/dev/null commit -q --allow-empty -m sneaky'
assert_status 1 $? "scan reports the commit"
assert_grep 'changed HEAD or refs' "$HOIST_ERR" "HEAD/refs change is named"
assert_no_file "$TMP/attest" "no attestation after a gate commit"
hoist push --state "$S" --no-pr
assert_ne 0 $? "push refused after a gate commit"
hoist scan --state "$S" --run-gates
assert_status 2 $? "a later scan refuses to proceed on a moved HEAD"
assert_grep 'HEAD is not the base' "$HOIST_ERR" "and says why"
hoist cleanup --state "$S" --discard
assert_status 0 $? "cleanup --discard still works"

# --- (3) exit status honesty ------------------------------------------------
fixture_new
# shellcheck disable=SC2086
hoist prepare --repo "$WORKSHOP" --target main -- $FILES
S="$(state_path)"
TMP="$(state_get "$S" HOIST_TMP)"
hoist scan --state "$S" --gates 'false | true'
assert_grep 'gates.*exit [0-9]+' "$HOIST_ERR" "'false | true' fails (pipefail)"
hoist scan --state "$S" --gates 'false; echo ok'
assert_grep 'gates.*exit [0-9]+' "$HOIST_ERR" "'false; echo ok' fails (errexit)"
hoist scan --state "$S" --gates 'true'
assert_grep 'clean  true passed' "$HOIST_ERR" "'true' passes"
assert_file "$TMP/attest" "attestation with --gates true (recorded)"
assert_grep '^gates_cmd=' "$(cat "$TMP/attest")" "gates command digest recorded"

# --- (4) gates never run silently -------------------------------------------
hoist scan --state "$S"
assert_grep 'detected: make lint && make test' "$HOIST_ERR" "autodetected command is shown"
assert_grep 'not run' "$HOIST_ERR" "and not run without --run-gates"
assert_no_file "$TMP/attest" "no attestation when gates were not run"
hoist scan --state "$S" --run-gates
assert_grep 'make lint && make test passed' "$HOIST_ERR" "--run-gates runs it"
assert_file "$TMP/attest" "attestation with --run-gates"

# --- (5) --skip-gates and --only never attest -------------------------------
hoist scan --state "$S" --skip-gates
assert_no_file "$TMP/attest" "--skip-gates: no attestation"
hoist scan --state "$S" --only gates --run-gates
assert_no_file "$TMP/attest" "--only gates: no attestation"
hoist scan --state "$S" --only nope
assert_status 2 $? "--only with an unknown check is an error"

# --- (6) the dangling-reference case the gates exist for -------------------
hoist cleanup --state "$S" --discard >/dev/null 2>&1
hoist prepare --repo "$WORKSHOP" --target main -- src/parser.sh src/legacy.sh
S="$(state_path)"
hoist scan --state "$S" --run-gates
assert_grep 'gates.*exit [0-9]+' "$HOIST_ERR" "deleting legacy.sh without t/run.sh fails the gates"
hoist cleanup --state "$S" --discard >/dev/null 2>&1

done_testing
