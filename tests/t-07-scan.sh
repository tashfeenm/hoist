#!/usr/bin/env bash
# t-07-scan — secrets/personal semantics: gitleaks present, missing, erroring
# or unparseable; the decoy; the -U0 parser; fixed-string personal matching;
# stale attestations; excerpt hygiene.
. "$(dirname "$0")/lib.sh"

fixture_new
FILES="src/parser.sh src/report.sh src/legacy.sh t/run.sh scripts/pre-commit.sh bin/widget t/fixtures/keys.txt"

# A minimal PATH: a shim dir plus the system dirs, so we control whether a
# `gitleaks` is found and what it does. git/bash/awk/etc. come from the
# system dirs (or are linked into the shim if they live elsewhere).
SHIM="$(tmpdir)/shim"
mkdir -p "$SHIM"
for tool in git bash gitleaks; do
	p="$(command -v "$tool" 2>/dev/null || true)"
	[ -n "$p" ] && ln -s "$p" "$SHIM/$tool"
done
BASE_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
with_gitleaks_real() { PATH="$SHIM:$BASE_PATH" hoist "$@"; }
without_gitleaks() { rm -f "$SHIM/gitleaks"; PATH="$SHIM:$BASE_PATH" hoist "$@"; }
with_gitleaks_stub() { # with_gitleaks_stub <script-body> <hoist args...>
	local body="$1"
	shift
	rm -f "$SHIM/gitleaks" # never write through the symlink to the real binary
	printf '#!/bin/sh\ncase "$1 $2" in "dir --help") exit 0 ;; esac\n%s\n' "$body" >"$SHIM/gitleaks"
	chmod +x "$SHIM/gitleaks"
	PATH="$SHIM:$BASE_PATH" hoist "$@"
}
restore_gitleaks() { rm -f "$SHIM/gitleaks"; ln -s "$(command -v gitleaks)" "$SHIM/gitleaks"; }

# shellcheck disable=SC2086
hoist prepare --repo "$WORKSHOP" --target main -- $FILES
assert_status 0 $? "prepare"
S="$(state_path)"
TMP="$(state_get "$S" HOIST_TMP)"

# --- (1) real gitleaks: three planted secrets, decoy clean -----------------
if command -v gitleaks >/dev/null 2>&1; then
	with_gitleaks_real scan --state "$S" --only secrets
	assert_grep 'scripts/pre-commit\.sh:5 .*aws-access-key-id \(hoist pattern\)' "$HOIST_ERR" "AWS key id caught by the pattern set (gitleaks walks past it)"
	assert_grep 'scripts/pre-commit\.sh:6 .*\(gitleaks\)' "$HOIST_ERR" "AWS secret caught by gitleaks"
	assert_grep 'scripts/pre-commit\.sh:7 .*\(gitleaks\)' "$HOIST_ERR" "Slack webhook caught by gitleaks"
	assert_not_grep 't/fixtures/keys\.txt' "$HOIST_ERR" "the decoy is scanned and stays clean (gitleaks + patterns)"
	assert_eq "3" "$(printf '%s\n' "$HOIST_ERR" | grep -c '\[secrets-')" "exactly three secrets findings"
else
	printf '# gitleaks not installed — real-gitleaks assertions skipped\n'
fi

# --- (2) gitleaks missing: fallback patterns, honest engine label -----------
without_gitleaks scan --state "$S" --only secrets
assert_grep 'gitleaks not installed' "$HOIST_ERR" "missing gitleaks is announced"
assert_grep 'scripts/pre-commit\.sh:5 .*aws-access-key-id' "$HOIST_ERR" "fallback catches the key id"
assert_grep 'scripts/pre-commit\.sh:7 .*slack-webhook' "$HOIST_ERR" "fallback catches the webhook"
assert_not_grep 'scripts/pre-commit\.sh:6 ' "$HOIST_ERR" "fallback does NOT catch the AWS secret (documented gap)"
assert_not_grep 't/fixtures/keys\.txt' "$HOIST_ERR" "decoy still clean under the fallback"

# --- (3) gitleaks erroring → operational error, exit 2, no attestation ------
with_gitleaks_stub 'case "$1" in dir|detect) echo "boom" >&2; exit 3;; esac; exit 0' scan --state "$S" --gates true
assert_status 2 $? "a gitleaks failure (exit 3) aborts the scan with exit 2"
assert_grep 'gitleaks failed' "$HOIST_ERR" "  …and says so"
assert_no_file "$TMP/attest" "  …and leaves no attestation"

# --- (4) gitleaks exit 1 with an unparseable report → aggregate finding -----
with_gitleaks_stub 'case "$1" in dir|detect) shift; while [ $# -gt 1 ]; do case "$1" in --report-path) printf "{\"not\":\"a list\"}" >"$2";; esac; shift; done; echo "WRN leaks found: 2" >&2; exit 1;; esac; exit 0' scan --state "$S" --only secrets
assert_grep 'gitleaks reported leaks \(exit 1\)' "$HOIST_ERR" "unparseable leak report becomes an aggregate finding, never clean"
# compact JSON on one line: still parses zero records → aggregate finding
with_gitleaks_stub 'case "$1" in dir|detect) shift; while [ $# -gt 1 ]; do case "$1" in --report-path) printf "[{\"RuleID\":\"x\",\"StartLine\":1,\"File\":\"f\",\"Fingerprint\":\"f:x:1\"}]" >"$2";; esac; shift; done; exit 1;; esac; exit 0' scan --state "$S" --only secrets
assert_grep 'gitleaks reported leaks \(exit 1\)' "$HOIST_ERR" "compact one-line JSON: aggregate finding rather than a silent miss"
restore_gitleaks

# --- (5) attestation is deleted at the start of a rescan --------------------
hoist scan --state "$S" --gates true
assert_file "$TMP/attest" "attestation from a full scan"
with_gitleaks_stub 'exit 3' scan --state "$S" --gates true
assert_status 2 $? "rescan aborts"
assert_no_file "$TMP/attest" "the earlier attestation did not survive the failed rescan"
restore_gitleaks
hoist cleanup --state "$S" --discard >/dev/null 2>&1

# --- (6) personal: the -U0 parser and fixed-string matching ----------------
git -C "$WORKSHOP" config user.email 'a+b@example.com'
cat >"$WORKSHOP/notes.txt" <<'EOF'
++ a line starting with two pluses and /Users/pat/here
plain line
contact: a+b@example.com
not the email: aab@example.com
home: HOMEDIR_PLACEHOLDER
almost home: HOMEALMOST_PLACEHOLDER
EOF
FAKEHOME="$(tmpdir)/h.o.m.e"
mkdir -p "$FAKEHOME"
sed -i.bak -e "s|HOMEDIR_PLACEHOLDER|$FAKEHOME|" -e "s|HOMEALMOST_PLACEHOLDER|$(printf '%s' "$FAKEHOME" | sed 's/\./X/g')|" "$WORKSHOP/notes.txt" && rm -f "$WORKSHOP/notes.txt.bak"
hoist prepare --repo "$WORKSHOP" --target main -- notes.txt
S="$(state_path)"
TMP="$(state_get "$S" HOIST_TMP)"
HOME="$FAKEHOME" hoist scan --state "$S" --only personal
assert_grep 'notes\.txt:1 ' "$HOIST_ERR" "a '++'-prefixed added line is content, at the right line number"
assert_grep 'notes\.txt:3 ' "$HOIST_ERR" "email with '+' matched as a fixed string"
assert_not_grep 'notes\.txt:4 ' "$HOIST_ERR" "'aab@' is not matched (no regex semantics for '+')"
assert_grep 'notes\.txt:5 ' "$HOIST_ERR" "\$HOME with dots matched as a fixed string"
assert_not_grep 'notes\.txt:6 ' "$HOIST_ERR" "dots in \$HOME are not wildcards"
git -C "$WORKSHOP" config --unset user.email
hoist cleanup --state "$S" --discard >/dev/null 2>&1

# --- (7) excerpt hygiene: no raw control bytes reach stderr or findings.txt --
printf '/Users/pat/\033[31mred\007bell\n' >"$WORKSHOP/ctl.txt"
hoist prepare --repo "$WORKSHOP" --target main -- ctl.txt
S="$(state_path)"
TMP="$(state_get "$S" HOIST_TMP)"
hoist scan --state "$S" --only personal
assert_grep 'ctl\.txt:1 ' "$HOIST_ERR" "personal finding on the control-char line"
assert_eq "0" "$(printf '%s' "$HOIST_ERR" | tr -cd '\033\007' | wc -c | tr -d ' ')" "no ESC/BEL bytes in the scan output"
assert_eq "0" "$(tr -cd '\033\007' <"$TMP/findings.txt" | wc -c | tr -d ' ')" "no ESC/BEL bytes in findings.txt"
hoist cleanup --state "$S" --discard >/dev/null 2>&1

# --- (8) --only validation and per-check status in the summary --------------
hoist prepare --repo "$WORKSHOP" --target main -- src/parser.sh
S="$(state_path)"
hoist scan --state "$S" --only secrets --only personal
assert_grep '2 of 4 checks ran' "$HOIST_ERR" "summary counts the checks that ran"
assert_grep 'NO attestation' "$HOIST_ERR" "and says there is no attestation"
hoist cleanup --state "$S" --discard >/dev/null 2>&1

done_testing
