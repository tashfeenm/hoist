# demo.tape — a scripted CLI demo of hoist against the fixture, recorded with
# vhs. This is NOT a recording of the skill inside Claude Code: it drives the
# same scripts the skill drives, in one persistent shell, with the edits
# Claude would make applied by fixtures/demo-edits.sh.
#
#   vhs demo.tape        # from the repo root; writes demo.gif
#
# Hidden setup clones the COMMITTED tree to a temp path (nothing private, no
# maintainer path on screen), builds the fixture there and runs the
# manifest/index suite (t-02) in the recording shell — a failure exits that
# shell, so a GIF only comes out of a tree that passes it. The dry run is shown
# as its last 22 lines (the full diff scrolls above; the caption says so).
# Hidden teardown cleans the hoist up and removes the temp copy.

Output demo.gif

Require git
Require bash
Require make
Require gitleaks

Set Shell bash
Set FontSize 14
Set Width 1180
Set Height 900
Set Padding 24
Set TypingSpeed 22ms
Set Theme "Catppuccin Mocha"

# --- setup, not recorded ---------------------------------------------------
Hide
Type `export HD=$(mktemp -d) && git clone -q . "$HD/hoist" && cd "$HD/hoist" && ./fixtures/make-fixture.sh >/dev/null && cd .fixture/workshop && clear` Enter
Sleep 4s
Type `../../tests/run.sh t-02 >/dev/null 2>&1 || exit 1` Enter
Sleep 12s
Type "export PS1='$ ' HOIST=../../scripts/hoist NO_COLOR= && clear" Enter
Sleep 1s
Show

# --- the mess --------------------------------------------------------------
Type "# a normal, permanently dirty repo" Sleep 400ms Enter
Type "git status --short --untracked=all" Sleep 300ms Enter
Sleep 3s

Type "# ship seven of these. leave the rest alone." Sleep 400ms Enter
Sleep 1.5s

# --- prepare ---------------------------------------------------------------
Type "FILES=(src/parser.sh src/report.sh src/legacy.sh t/run.sh scripts/pre-commit.sh bin/widget t/fixtures/keys.txt)" Sleep 300ms Enter
Type `STATE=$("$HOIST" prepare --target main -- "${FILES[@]}")` Sleep 300ms Enter
Sleep 4s

# --- scan ------------------------------------------------------------------
Type `"$HOIST" scan --state "$STATE" --run-gates` Sleep 300ms Enter
Sleep 7s

Type "# secrets, a Desktop path, a mode flip and a file that moved upstream." Sleep 300ms Enter
Type "# this is where Claude reads the diff and fixes the copy:" Sleep 400ms Enter
Sleep 1.5s
Type `../../fixtures/demo-edits.sh --state "$STATE"` Sleep 300ms Enter
Sleep 2s

# --- rescan ----------------------------------------------------------------
Type `"$HOIST" scan --state "$STATE" --run-gates` Sleep 300ms Enter
Sleep 6s

# --- dry run ---------------------------------------------------------------
Type "# dry run — the full diff scrolls by; showing the last 22 lines:" Sleep 300ms Enter
Type `"$HOIST" finish --state "$STATE" --title 'fix: trim keys when parsing' 2>&1 | tail -22; test "${PIPESTATUS[0]}" -eq 0` Sleep 300ms Enter
Sleep 6s

Type "# nothing pushed. 'hoist push' is a separate command, for a later turn, on your yes." Sleep 400ms Enter
Sleep 3s

Type "git status --short --untracked=all" Sleep 300ms Enter
Sleep 1s
Type "# and your repo is exactly as messy as you left it." Sleep 400ms Enter
Sleep 3.5s

# --- teardown, not recorded ------------------------------------------------
Hide
Type `"$HOIST" cleanup --state "$STATE" --discard >/dev/null 2>&1; cd / && rm -rf "$HD"` Enter
Sleep 2s
