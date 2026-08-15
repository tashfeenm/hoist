#!/usr/bin/env bash
# t-04-drift — the drift matrix: incorporated text, mode-only, add/add,
# upstream delete, rename, binary, type change, --no-fetch, unrelated
# history, shallow clone, detached HEAD.
. "$(dirname "$0")/lib.sh"

fixture_new
UP="$(tmpdir)/up"
git clone -q "$ORIGIN" "$UP"
# upstream_commit <msg> — commit whatever is in $UP and push it to origin/main
upstream_commit() {
	git -C "$UP" add -A
	git -C "$UP" -c commit.gpgsign=false commit -q -m "$1"
	git -C "$UP" push -q origin main
}
drift_ids() { grep '^finding=drift-' "$1/attest" | sed 's/finding=//' | tr '\n' ' '; }

# --- (a) the fixture: text drift, then incorporated; mode-only drift --------
FILES="src/parser.sh src/report.sh src/legacy.sh t/run.sh scripts/pre-commit.sh bin/widget t/fixtures/keys.txt"
# shellcheck disable=SC2086
hoist prepare --repo "$WORKSHOP" --target main -- $FILES
S="$(state_path)"
TMP="$(state_get "$S" HOIST_TMP)"
hoist scan --state "$S" --only drift
assert_not_grep 'warning:' "$HOIST_ERR" "no shell warnings in the scan output (NUL bytes never pass through \$(...))"
assert_grep 'src/parser\.sh .*also changed on main' "$HOIST_ERR" "text drift on parser.sh"
assert_grep 'bin/widget .*mode changed upstream \(100644→100755\)' "$HOIST_ERR" "mode-only drift on bin/widget"
assert_not_grep 't/fixtures/keys\.txt' "$HOIST_ERR" "no drift on a file upstream did not touch"
"$ROOT/fixtures/demo-edits.sh" --state "$S" >/dev/null 2>&1
hoist scan --state "$S" --only drift
assert_not_grep '\[drift-' "$HOIST_ERR" "no drift finding after merging upstream's change and matching the mode"
assert_grep 'already incorporated' "$HOIST_ERR" "parser.sh reported as incorporated"
assert_grep 'upstream changed only the mode, and your copy matches' "$HOIST_ERR" "widget reported as mode-matched"
hoist cleanup --state "$S" --discard >/dev/null 2>&1

# --- (b) add/add: both sides add the same new path with different content --
printf 'upstream version\n' >"$UP/NEW.md"
upstream_commit "add NEW.md upstream"
printf 'local version\n' >"$WORKSHOP/NEW.md"
hoist prepare --repo "$WORKSHOP" --target main -- NEW.md
S="$(state_path)"
TMP="$(state_get "$S" HOIST_TMP)"
hoist scan --state "$S" --only drift
assert_grep 'NEW\.md .*add/add' "$HOIST_ERR" "add/add is flagged for manual review"
hoist cleanup --state "$S" --discard >/dev/null 2>&1
rm "$WORKSHOP/NEW.md"

# --- (c) upstream deleted a file we still carry -----------------------------
git -C "$UP" rm -q src/config.sh
upstream_commit "delete config.sh upstream"
printf '# local edit\n' >>"$WORKSHOP/src/config.sh"
hoist prepare --repo "$WORKSHOP" --target main -- src/config.sh
S="$(state_path)"
hoist scan --state "$S" --only drift
assert_grep 'src/config\.sh .*deleted upstream' "$HOIST_ERR" "upstream deletion is flagged"
assert_grep 'rename upstream shows as delete\+add' "$HOIST_ERR" "and the rename caveat is stated"
hoist cleanup --state "$S" --discard >/dev/null 2>&1

# --- (d) we delete a file that changed upstream -----------------------------
printf '# upstream touch\n' >>"$UP/Makefile"
upstream_commit "touch Makefile upstream"
rm "$WORKSHOP/Makefile"
hoist prepare --repo "$WORKSHOP" --target main -- Makefile
S="$(state_path)"
hoist scan --state "$S" --only drift
assert_grep 'Makefile .*you delete it, but it changed upstream' "$HOIST_ERR" "delete-vs-change is flagged"
hoist cleanup --state "$S" --discard >/dev/null 2>&1
git -C "$WORKSHOP" checkout -q -- Makefile

# --- (e) upstream rename: appears as delete + add ---------------------------
git -C "$UP" mv src/legacy.sh src/oldparse.sh
upstream_commit "rename legacy.sh upstream"
# workshop still has (its deletion of) legacy.sh; hoisting the deletion is fine,
# hoisting a re-added legacy.sh shows as delete+add
git -C "$WORKSHOP" checkout -q HEAD -- src/legacy.sh
printf '# local\n' >>"$WORKSHOP/src/legacy.sh"
hoist prepare --repo "$WORKSHOP" --target main -- src/legacy.sh
S="$(state_path)"
hoist scan --state "$S" --only drift
assert_grep 'src/legacy\.sh .*deleted upstream' "$HOIST_ERR" "renamed-away file is reported as deleted upstream (rename identity is not inferred)"
hoist cleanup --state "$S" --discard >/dev/null 2>&1
rm "$WORKSHOP/src/legacy.sh"

# --- (f) binary changed upstream --------------------------------------------
printf 'BIN\000\001\002v1\n' >"$UP/blob.bin"
upstream_commit "add binary"
git -C "$WORKSHOP" fetch -q origin main
git -C "$WORKSHOP" checkout -q origin/main -- blob.bin 2>/dev/null || cp "$UP/blob.bin" "$WORKSHOP/blob.bin"
git -C "$WORKSHOP" reset -q -- blob.bin 2>/dev/null || true
# the workshop's HEAD predates blob.bin, so its "merge-base" lacks it: use a
# fresh clone at this point to get a base that HAS the binary, then move it
git -C "$UP" pull -q origin main
printf 'BIN\000\001\002v2\n' >"$UP/blob.bin"
upstream_commit "change binary upstream"
W2="$(tmpdir)/w2"
git clone -q "$ORIGIN" "$W2"
git -C "$W2" reset -q --hard HEAD~1
printf 'BIN\000\003\004local\n' >"$W2/blob.bin"
hoist prepare --repo "$W2" --target main -- blob.bin
assert_status 0 $? "prepare on a binary"
S="$(state_path)"
hoist scan --state "$S" --only drift
assert_grep 'blob\.bin .*binary' "$HOIST_ERR" "binary drift is flagged for manual resolution"
hoist cleanup --state "$S" --discard >/dev/null 2>&1

# --- (g) type change: file → symlink upstream -------------------------------
git -C "$UP" rm -q src/report.sh
ln -s parser.sh "$UP/src/report.sh"
upstream_commit "report.sh becomes a symlink upstream"
W3="$(tmpdir)/w3"
git clone -q "$ORIGIN" "$W3"
git -C "$W3" reset -q --hard HEAD~1
printf '# local edit\n' >>"$W3/src/report.sh"
hoist prepare --repo "$W3" --target main -- src/report.sh
S="$(state_path)"
hoist scan --state "$S" --only drift
assert_grep 'src/report\.sh .*type' "$HOIST_ERR" "file/symlink type change is flagged"
hoist cleanup --state "$S" --discard >/dev/null 2>&1

# --- (h) --no-fetch: standing "stale" finding -------------------------------
W4="$(tmpdir)/w4"
git clone -q "$ORIGIN" "$W4"
printf '# edit\n' >>"$W4/Makefile"
hoist prepare --repo "$W4" --target main --no-fetch -- Makefile
assert_status 0 $? "prepare --no-fetch"
S="$(state_path)"
TMP="$(state_get "$S" HOIST_TMP)"
assert_eq "0" "$(state_get "$S" HOIST_FETCHED)" "HOIST_FETCHED=0 recorded"
hoist scan --state "$S" --gates true
assert_grep 'prepared with --no-fetch' "$HOIST_ERR" "stale finding present"
assert_file "$TMP/attest" "attestation still possible (the finding is acknowledgeable)"
hoist cleanup --state "$S" --discard >/dev/null 2>&1

# --- (i) fetch failure is fatal without --no-fetch ---------------------------
git -C "$W4" remote set-url origin "$W4/../does-not-exist.git"
hoist prepare --repo "$W4" --target main -- Makefile
assert_status 2 $? "fetch failure is fatal"
assert_grep 'could not fetch' "$HOIST_ERR" "  …with git's reason"
assert_no_file "$W4/.hoist" "  …and nothing left behind"
git -C "$W4" remote set-url origin "$ORIGIN"

# --- (j) unrelated history ---------------------------------------------------
W5="$(tmpdir)/w5"
git init -q "$W5" && git -C "$W5" remote add origin "$ORIGIN" && git -C "$W5" fetch -q origin main
printf 'x\n' >"$W5/README.x" && git -C "$W5" add README.x && git -C "$W5" -c commit.gpgsign=false commit -q -m unrelated
printf 'y\n' >"$W5/Makefile"
hoist prepare --repo "$W5" --target main -- Makefile
assert_status 2 $? "no merge-base is fatal by default"
assert_grep 'no shared history' "$HOIST_ERR" "  …with the reason"
hoist prepare --repo "$W5" --target main --allow-unrelated-history -- Makefile
assert_status 0 $? "--allow-unrelated-history proceeds"
S="$(state_path)"
TMP="$(state_get "$S" HOIST_TMP)"
assert_eq "1" "$(state_get "$S" HOIST_UNRELATED)" "HOIST_UNRELATED=1 recorded"
hoist scan --state "$S" --gates true
assert_grep 'no shared history' "$HOIST_ERR" "drift is a standing finding"
assert_file "$TMP/attest" "attestation with the standing finding"
hoist cleanup --state "$S" --discard >/dev/null 2>&1

# --- (k) shallow clone is refused -------------------------------------------
W6="$(tmpdir)/w6"
git clone -q --depth 1 "file://$ORIGIN" "$W6"
printf 'z\n' >>"$W6/Makefile"
hoist prepare --repo "$W6" --target main -- Makefile
assert_status 2 $? "shallow clone refused"
assert_grep 'shallow' "$HOIST_ERR" "  …with the unshallow hint"

# --- (l) detached HEAD works ------------------------------------------------
W7="$(tmpdir)/w7"
git clone -q "$ORIGIN" "$W7"
git -C "$W7" checkout -q --detach "$(git -C "$W7" rev-list --max-parents=0 HEAD)"
printf '# detached edit\n' >>"$W7/Makefile"
hoist prepare --repo "$W7" --target main -- Makefile
assert_status 0 $? "detached HEAD prepare"
S="$(state_path)"
hoist scan --state "$S" --only drift
assert_grep 'Makefile .*also changed on main' "$HOIST_ERR" "drift computed from the detached commit's merge-base"
hoist cleanup --state "$S" --discard >/dev/null 2>&1

done_testing
