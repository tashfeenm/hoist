#!/usr/bin/env bash
# t-03-paths — the filename contract and index-side edge cases: what is
# supported (spaces, leading dashes, symlink files, exec bits without
# core.filemode) and what is rejected with an exact reason (TAB/LF/CR/colon,
# .git in any case, pathspec magic, symlinked parents, submodules, directories).
. "$(dirname "$0")/lib.sh"

fixture_new
TAB="$(printf '\t')"

# --- supported spellings ----------------------------------------------------
printf 'echo spaced\n' >"$WORKSHOP/src/with space.sh"
printf 'echo dashed\n' >"$WORKSHOP/-leading-dash.sh"
ln -s src/parser.sh "$WORKSHOP/parser-link"
hoist prepare --repo "$WORKSHOP" --target main -- 'src/with space.sh' -leading-dash.sh parser-link ./src/parser.sh "$WORKSHOP/src/parser.sh" src/parser.sh
assert_status 0 $? "spaces, leading dash, symlink file, ./ and absolute-in-repo spellings accepted"
S="$(state_path)"
WT="$(state_get "$S" HOIST_WORKTREE)"
M="$(state_get "$S" HOIST_MANIFEST)"
assert_eq "4" "$(wc -l <"$M" | tr -d ' ')" "duplicate spellings deduplicated to one manifest entry"
assert_true "symlink is staged as a symlink" test -L "$WT/parser-link"
assert_eq "120000" "$(git -C "$WT" ls-files -s parser-link | cut -c1-6)" "symlink blob mode 120000 in the index"
staged="$(git -C "$WT" diff --cached --name-only HEAD)"
assert_grep '^src/with space\.sh$' "$staged" "spaced path staged"
assert_grep '^-leading-dash\.sh$' "$staged" "leading-dash path staged"
hoist cleanup --state "$S" --discard >/dev/null 2>&1

# --- rejected paths, each with an exact reason ------------------------------
reject() { # reject <path> <pattern> <name>
	hoist prepare --repo "$WORKSHOP" --target main -- "$1"
	assert_status 2 $? "rejected: $3"
	assert_grep "$2" "$HOIST_ERR" "  …with the reason ($3)"
	assert_no_file "$WORKSHOP/.hoist" "  …and nothing left behind ($3)"
}
reject "src/a${TAB}b.sh" 'tab, newline or carriage return' "TAB in path"
reject "src/a
b.sh" 'tab, newline or carriage return' "LF in path"
reject "src/a$(printf '\r')b.sh" 'tab, newline or carriage return' "CR in path"
reject "src/a:b.sh" "contains ':'" "colon in path"
reject ":(glob)src/*.sh" "contains ':'" "pathspec magic (starts with colon)"
reject ".git/config" 'git internals' ".git as a component"
reject "src/.GIT/x" 'git internals' ".GIT (case-insensitive) as a component"
reject "src//parser.sh" 'empty component' "empty component"
reject "src/parser.sh/" 'empty component' "trailing slash"
reject "src/../src/parser.sh" "'\\.' or '\\.\\.'" ".. component"
reject "/etc/passwd" 'relative to the repo root' "absolute path outside the repo"
reject "src" 'directories are not supported' "a directory"
reject ".hoist/x" "hoist's own workspace" ".hoist as first component"

# --- symlinked parent in the source repo -----------------------------------
mkdir -p "$WORKSHOP/real"
printf 'x\n' >"$WORKSHOP/real/file.sh"
ln -s real "$WORKSHOP/alias"
reject "alias/file.sh" 'symlink' "symlinked parent directory"

# --- symlinked parent on the TARGET side (writes would escape the worktree) --
# upstream gains a symlink dir "out -> /tmp"; hoisting out/x must be refused
seed="$(tmpdir)"
git clone -q "$ORIGIN" "$seed/s" 2>/dev/null
ln -s /tmp "$seed/s/out"
git -C "$seed/s" add out && git -C "$seed/s" -c commit.gpgsign=false commit -q -m "symlink dir upstream" && git -C "$seed/s" push -q origin main
mkdir -p "$WORKSHOP/out"
printf 'escape\n' >"$WORKSHOP/out/x"
hoist prepare --repo "$WORKSHOP" --target main -- out/x
assert_status 2 $? "rejected: path under a symlinked parent on the target"
assert_grep 'symlink' "$HOIST_ERR" "  …with the reason"
assert_no_file "/tmp/x" "  …and nothing written through the link"
rm -rf "$WORKSHOP/out"

# --- submodule ancestor -----------------------------------------------------
sub="$(tmpdir)"
git init -q "$sub/mod" && printf 'm\n' >"$sub/mod/m.txt" && git -C "$sub/mod" add m.txt && git -C "$sub/mod" -c commit.gpgsign=false commit -q -m m
git -C "$WORKSHOP" -c protocol.file.allow=always submodule add -q "$sub/mod" vendor/mod >/dev/null 2>&1 || true
if [ -f "$WORKSHOP/vendor/mod/m.txt" ]; then
	reject "vendor/mod/m.txt" 'submodule' "path inside a submodule"
	reject "vendor/mod" 'submodule|directories are not supported' "the submodule path itself"
	git -C "$WORKSHOP" rm -q -f vendor/mod >/dev/null 2>&1 || true
	rm -rf "$WORKSHOP/.git/modules" "$WORKSHOP/vendor" "$WORKSHOP/.gitmodules"
	git -C "$WORKSHOP" reset -q >/dev/null 2>&1 || true
else
	printf '# skipped submodule cases (submodule add unavailable)\n'
fi

# --- a hoisted file that becomes a directory in the worktree ----------------
hoist prepare --repo "$WORKSHOP" --target main -- src/parser.sh
S="$(state_path)"
WT="$(state_get "$S" HOIST_WORKTREE)"
rm "$WT/src/parser.sh" && mkdir "$WT/src/parser.sh" && printf 'x\n' >"$WT/src/parser.sh/inner"
hoist scan --state "$S" --skip-gates
assert_status 2 $? "a manifest path turned directory is refused at restage"
assert_grep 'directory' "$HOIST_ERR" "  …with the reason"
rm -r "$WT/src/parser.sh"
hoist cleanup --state "$S" --discard >/dev/null 2>&1

# --- exec bit with core.filemode=false ------------------------------------
git -C "$WORKSHOP" config core.filemode false
hoist prepare --repo "$WORKSHOP" --target main -- scripts/pre-commit.sh bin/widget
assert_status 0 $? "prepare with core.filemode=false"
S="$(state_path)"
WT="$(state_get "$S" HOIST_WORKTREE)"
assert_eq "100755" "$(git -C "$WT" ls-files -s scripts/pre-commit.sh | cut -c1-6)" "exec bit recorded on the index despite core.filemode=false"
assert_eq "100644" "$(git -C "$WT" ls-files -s bin/widget | cut -c1-6)" "non-exec file stays 644 in the index"
chmod +x "$WT/bin/widget"
hoist scan --state "$S" --skip-gates
assert_eq "100755" "$(git -C "$WT" ls-files -s bin/widget | cut -c1-6)" "chmod in the worktree is picked up by restage under core.filemode=false"
hoist cleanup --state "$S" --discard >/dev/null 2>&1
git -C "$WORKSHOP" config --unset core.filemode

# --- sparse / skip-worktree absence is not a deletion ----------------------
git -C "$WORKSHOP" update-index --skip-worktree src/config.sh
rm "$WORKSHOP/src/config.sh"
hoist prepare --repo "$WORKSHOP" --target main -- src/config.sh
assert_status 2 $? "skip-worktree absence is refused"
assert_grep 'sparse|skip-worktree' "$HOIST_ERR" "  …with the reason"
git -C "$WORKSHOP" update-index --no-skip-worktree src/config.sh
git -C "$WORKSHOP" checkout -q -- src/config.sh

# --- a genuine deletion, and a path that exists nowhere ---------------------
hoist prepare --repo "$WORKSHOP" --target main -- src/legacy.sh
assert_status 0 $? "deleting a tracked file is a valid hoist"
S="$(state_path)"
assert_grep 'deleted   src/legacy.sh' "$HOIST_ERR" "reported as deleted"
hoist cleanup --state "$S" --discard >/dev/null 2>&1
hoist prepare --repo "$WORKSHOP" --target main -- src/nowhere.sh
assert_status 2 $? "a path absent locally and on the target is refused"
assert_grep 'nothing to hoist' "$HOIST_ERR" "  …with the reason"

# --- unchanged file only → nothing to hoist, rolled back --------------------
hoist prepare --repo "$WORKSHOP" --target main -- Makefile
assert_status 1 $? "an unchanged file alone is 'nothing to hoist' (exit 1)"
assert_no_file "$WORKSHOP/.hoist" "  …and the workspace is rolled back"
assert_eq "" "$(git -C "$WORKSHOP" branch --list 'hoist/*')" "  …and no branch is left"

done_testing
