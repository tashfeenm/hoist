# demo.tape — the recording, and a smoke test.
#
#   vhs demo.tape        # from the repo root; writes demo.gif
#
# Everything here runs against the fixture, so if the recording completes the
# flow still works. In real use Claude runs these steps for you — you type
# /hoist and answer one question at the end.

Output demo.gif

Require git
Require bash

Set Shell bash
Set FontSize 14
Set Width 1180
Set Height 860
Set Padding 24
Set TypingSpeed 22ms
Set Theme "Catppuccin Mocha"

# --- setup, not recorded ---------------------------------------------------
Hide
Type "clear && ./fixtures/make-fixture.sh >/dev/null && cd .fixture/workshop" Enter
Sleep 3s
Type "export PS1='$ ' && export HOIST=../../scripts && export NO_COLOR= && clear" Enter
Sleep 1s
Show

# --- the mess --------------------------------------------------------------
Type "# a normal, permanently dirty repo" Sleep 400ms Enter
Type "git status --short --untracked=all" Sleep 300ms Enter
Sleep 3s

Type "# ship three of these. leave the rest alone." Sleep 400ms Enter
Sleep 1.5s

# --- prepare ---------------------------------------------------------------
Type "FILES='src/parser.sh src/report.sh src/legacy.sh t/run.sh scripts/pre-commit.sh'" Sleep 300ms Enter
Type "STATE=$($HOIST/hoist-prepare.sh --target main -- $FILES)" Sleep 300ms Enter
Sleep 4s

# --- scan ------------------------------------------------------------------
Type "$HOIST/hoist-scan.sh --state $STATE" Sleep 300ms Enter
Sleep 6s

Type "# secrets, a Desktop path, and a file that moved upstream." Sleep 300ms Enter
Type "# this is where Claude reads the diff and fixes the copy:" Sleep 400ms Enter
Sleep 1.5s
Type "../../fixtures/demo-edits.sh $(. $STATE; echo $HOIST_WORKTREE)" Sleep 300ms Enter
Sleep 2s

# --- rescan ----------------------------------------------------------------
Type "$HOIST/hoist-scan.sh --state $STATE" Sleep 300ms Enter
Sleep 6s

# --- dry run ---------------------------------------------------------------
Type "$HOIST/hoist-finish.sh --state $STATE --title 'fix: trim keys when parsing'" Sleep 300ms Enter
Sleep 5s

Type "# nothing pushed. --push when you say so." Sleep 400ms Enter
Sleep 3s

Type "git status --short --untracked=all" Sleep 300ms Enter
Sleep 1s
Type "# and your repo is exactly as messy as you left it." Sleep 400ms Enter
Sleep 3.5s
