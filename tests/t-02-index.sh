#!/usr/bin/env bash
# t-02-index — the index is manifest-only, and the workshop is never touched.
#
# A gate that stages a stray file and edits an unlisted tracked file must not
# get either into the commit; and the workshop's index bytes, porcelain status
# and HEAD are byte-identical after every lifecycle step.
. "$(dirname "$0")/lib.sh"

fixture_new
FILES="src/parser.sh src/report.sh src/legacy.sh t/run.sh scripts/pre-commit.sh"
SNAP="$(tmpdir)"
repo_snapshot "$WORKSHOP" "$SNAP/before"

# shellcheck disable=SC2086
hoist prepare --repo "$WORKSHOP" --target main -- $FILES
assert_status 0 $? "prepare succeeds"
S="$(state_path)"
WT="$(state_get "$S" HOIST_WORKTREE)"
TMP="$(state_get "$S" HOIST_TMP)"
BRANCH="$(state_get "$S" HOIST_BRANCH)"
BASE="$(state_get "$S" HOIST_BASE_SHA)"
repo_snapshot "$WORKSHOP" "$SNAP/prepare"
assert_true "workshop untouched by prepare" snapshot_same "$SNAP/before" "$SNAP/prepare"

# Claude's edits, scripted, so the scan can come back clean.
"$ROOT/fixtures/demo-edits.sh" --state "$S" >/dev/null 2>&1 ||
	_fail "demo-edits.sh --state applies"

# A gate that passes but tries to smuggle two extra paths into the index.
GATE='make test >/dev/null && echo stray >stray.txt && git add stray.txt && echo "# sneaky" >>src/config.sh && git add src/config.sh'
hoist scan --state "$S" --gates "$GATE"
rc=$?
assert_status 0 "$rc" "scan is clean after the edits (gate exit 0, no manifest mutation)"
assert_file "$TMP/attest" "attestation written"
staged="$(git -C "$WT" diff --cached --no-renames --name-only HEAD)"
assert_not_grep '^stray\.txt$' "$staged" "stray file staged by the gate is not in the index"
assert_not_grep '^src/config\.sh$' "$staged" "unlisted tracked file edited by the gate is not in the index"
assert_grep '^src/parser\.sh$' "$staged" "listed file is staged"
repo_snapshot "$WORKSHOP" "$SNAP/scan"
assert_true "workshop untouched by scan" snapshot_same "$SNAP/before" "$SNAP/scan"

hoist finish --state "$S" --title "fix: trim keys when parsing"
assert_status 0 $? "finish (dry run) succeeds"
assert_file "$TMP/receipt" "receipt written"
repo_snapshot "$WORKSHOP" "$SNAP/finish"
assert_true "workshop untouched by finish" snapshot_same "$SNAP/before" "$SNAP/finish"

hoist push --state "$S" --no-pr
assert_status 0 $? "push succeeds"
repo_snapshot "$WORKSHOP" "$SNAP/push"
assert_true "workshop untouched by push" snapshot_same "$SNAP/before" "$SNAP/push"

assert_true "branch exists on origin" origin_branch_exists "$ORIGIN" "$BRANCH"
tip="$(git -C "$ORIGIN" rev-parse "refs/heads/$BRANCH")"
assert_eq "$BASE" "$(git -C "$ORIGIN" rev-parse "$tip^")" "exactly one commit on top of the base"
committed="$(git -C "$ORIGIN" diff-tree --no-commit-id --no-renames --name-only -r "$tip")"
assert_not_grep '^stray\.txt$' "$committed" "stray file not committed"
assert_not_grep '^src/config\.sh$' "$committed" "unlisted file not committed"
for f in $FILES; do
	assert_grep "^$f\$" "$committed" "committed: $f"
done
assert_eq "$(printf '%s\n' $FILES | sort)" "$(printf '%s\n' "$committed" | sort)" \
	"committed paths are exactly the manifest"
assert_eq "100755" "$(git -C "$ORIGIN" ls-tree "$tip" scripts/pre-commit.sh | cut -c1-6)" \
	"exec bit survives"

hoist cleanup --state "$S"
assert_status 0 $? "cleanup after push needs no --discard"
repo_snapshot "$WORKSHOP" "$SNAP/cleanup"
assert_true "workshop untouched by cleanup" snapshot_same "$SNAP/before" "$SNAP/cleanup"
assert_no_file "$WT" "worktree gone"
assert_no_file "$TMP" "state dir gone"

done_testing
