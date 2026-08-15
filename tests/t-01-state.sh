#!/usr/bin/env bash
# t-01-state — state file containment: a forged or misplaced state file must
# never steer cleanup (or anything else) at a directory hoist did not create.
. "$(dirname "$0")/lib.sh"

fixture_new
FILES="src/parser.sh src/report.sh src/legacy.sh t/run.sh scripts/pre-commit.sh"

# shellcheck disable=SC2086
hoist prepare --repo "$WORKSHOP" --target main -- $FILES
assert_status 0 $? "prepare succeeds"
S="$(state_path)"
TMP="$(state_get "$S" HOIST_TMP)"
WT="$(state_get "$S" HOIST_WORKTREE)"
BRANCH="$(state_get "$S" HOIST_BRANCH)"
BASE="$(state_get "$S" HOIST_BASE_SHA)"

# --- (a) a state file elsewhere, pointing at a directory that is not ours ----
victim="$(tmpdir)"
mkdir -p "$victim/home"
: >"$victim/home/marker"
cat >"$victim/state" <<EOF
HOIST_VERSION=1
HOIST_ID=20260101-000000-1
HOIST_REPO=$WORKSHOP
HOIST_WORKTREE=$victim/home
HOIST_TMP=$victim/home
HOIST_MANIFEST=$victim/manifest
HOIST_BRANCH=main
HOIST_TARGET=main
HOIST_REMOTE=origin
HOIST_BASE_SHA=$BASE
HOIST_MERGE_BASE=$BASE
HOIST_FETCHED=1
HOIST_UNRELATED=0
EOF
: >"$victim/manifest"
hoist cleanup --state "$victim/state" --discard
assert_status 2 $? "cleanup refuses a state file outside the hoist layout"
assert_file "$victim/home/marker" "the pointed-at directory survives"
assert_grep "^worktree $WT\$" "$(git -C "$WORKSHOP" worktree list --porcelain)" \
	"our real worktree is still registered"
assert_true "our real worktree survives" test -d "$WT"

# --- (b) the real state file, edited to name the repo root as the worktree --
cp "$S" "$victim/state.orig"
sed "s|^HOIST_WORKTREE=.*|HOIST_WORKTREE=$WORKSHOP|" "$victim/state.orig" >"$S"
hoist cleanup --state "$S" --discard
assert_status 2 $? "cleanup refuses when HOIST_WORKTREE is the repo root"
assert_file "$WORKSHOP/src/parser.sh" "repo root untouched"
assert_true "worktree still exists" test -d "$WT"
cp "$victim/state.orig" "$S"

# --- (c) the real state file, edited to point tmp at the victim -------------
sed "s|^HOIST_TMP=.*|HOIST_TMP=$victim/home|" "$victim/state.orig" >"$S"
hoist cleanup --state "$S" --discard
assert_status 2 $? "cleanup refuses when HOIST_TMP is not where the state file lives"
assert_file "$victim/home/marker" "victim untouched"
cp "$victim/state.orig" "$S"

# --- (d) a symlink to the real state file ------------------------------------
ln -s "$S" "$victim/link"
hoist cleanup --state "$victim/link" --discard
assert_status 2 $? "cleanup refuses a symlinked state file"
assert_true "worktree still exists after symlink refusal" test -d "$WT"

# --- (e) unknown / duplicate keys --------------------------------------------
{ cat "$victim/state.orig"; echo "HOIST_EVIL=1"; } >"$S"
hoist scan --state "$S" --skip-gates
assert_status 2 $? "unknown key in state is refused"
{ cat "$victim/state.orig"; echo "HOIST_BRANCH=other"; } >"$S"
hoist scan --state "$S" --skip-gates
assert_status 2 $? "duplicate key in state is refused"
grep -v '^HOIST_BASE_SHA=' "$victim/state.orig" >"$S"
hoist scan --state "$S" --skip-gates
assert_status 2 $? "missing mandatory key is refused"
cp "$victim/state.orig" "$S"

# --- (f) a value carrying '=' round-trips through the parser ---------------
# (branch names may contain '='; the parser splits on the FIRST '=' only)
hoist prepare --repo "$WORKSHOP" --target main --branch 'hoist/a=b=' -- src/parser.sh
assert_status 0 $? "prepare accepts a branch name containing '='"
S2="$(state_path)"
assert_eq 'hoist/a=b=' "$(state_get "$S2" HOIST_BRANCH)" "state stores the '=' value verbatim"
hoist scan --state "$S2" --only drift
assert_grep 'hoist/a=b=' "$HOIST_ERR" "scan reads the '=' value back intact"
hoist cleanup --state "$S2" --discard
assert_status 0 $? "cleanup of the second hoist succeeds"

# --- (g) genuine cleanup with a valid state still works ---------------------
hoist cleanup --state "$S" --discard
assert_status 0 $? "genuine cleanup succeeds"
assert_no_file "$TMP" "state directory removed"
assert_false "branch deleted" git -C "$WORKSHOP" rev-parse --verify -q "refs/heads/$BRANCH"
assert_not_grep "$WT" "$(git -C "$WORKSHOP" worktree list --porcelain)" "worktree unregistered"

done_testing
