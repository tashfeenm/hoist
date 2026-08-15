#!/usr/bin/env bash
#
# hoist-scan.sh — the four checks, each producing named findings.
#
#   secrets      credentials in the hoisted files (gitleaks, plus a small
#                always-on pattern set for what it misses)
#   personal     home directories, usernames, machine paths, personal email —
#                checked against the lines this hoist ADDS
#   drift        files that also moved on the target since your merge-base.
#                Hoisting them verbatim would silently revert that work.
#   gates        the target repo's own lint/test, run in the clean worktree
#
# Usage:
#   hoist-scan.sh --state FILE [options]
#
#   --state FILE     state file printed by hoist-prepare.sh (required)
#   --gates CMD      command to run as the gates (default: autodetected)
#   --skip-gates     do not run gates
#   --only CHECK     run one check: secrets|personal|drift|gates
#
# Exit: 0 clean, 1 findings to review, 2 error. Findings are not failures —
# they are what the human and Claude read before deciding to push.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/hoist-lib.sh
. "$HERE/hoist-lib.sh"

usage() {
	sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
	exit "${1:-0}"
}

STATE="" GATES_CMD="" RUN_GATES=1 ONLY=""
while [ $# -gt 0 ]; do
	case "$1" in
	--state)
		STATE="${2:?--state needs a file}"
		shift 2
		;;
	--gates)
		GATES_CMD="${2:?--gates needs a command}"
		shift 2
		;;
	--skip-gates)
		RUN_GATES=0
		shift
		;;
	--only)
		ONLY="${2:?--only needs a check name}"
		shift 2
		;;
	-h | --help) usage 0 ;;
	*) die "unknown argument: $1" ;;
	esac
done
[ -n "$STATE" ] || usage 2
state_load "$STATE"

WT="$HOIST_WORKTREE"
FINDINGS=0
wants() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }

section() { info "${C_BOLD}$1${C_OFF}"; }
clean() { printf '  %sclean%s  %s\n' "$C_GRN" "$C_OFF" "$1" >&2; }

# Findings are buffered so a section can report one line per location. Two
# scanners naming the same line is one problem to fix, not two; the first
# reporter wins, which keeps the more precise tool's label.
FBUF=""
findings_begin() { FBUF="$(mktemp)"; }
finding_now() { # for checks that report at most one finding per location
	printf '  %s%-34s%s %s\n' "$C_YEL" "$1" "$C_OFF" "$2" >&2
	FINDINGS=$((FINDINGS + 1))
}
finding() { # finding <file:line> <text>
	printf '%s\t%s\n' "$1" "$2" >>"$FBUF"
}
findings_flush() { # findings_flush <message-if-none>
	local n=0 loc text
	while IFS=$'\t' read -r loc text; do
		printf '  %s%-34s%s %s\n' "$C_YEL" "$loc" "$C_OFF" "$text" >&2
		n=$((n + 1))
	done < <(awk -F'\t' '!seen[$1]++' "$FBUF" | sort -t: -k1,1 -k2,2n)
	rm -f "$FBUF"
	FINDINGS=$((FINDINGS + n))
	[ "$n" -gt 0 ] || clean "$1"
}

# Files whose content this hoist puts on the branch (deletions excluded).
present_files() { awk -F'\t' '$1=="A"||$1=="M"{print $2}' "$HOIST_MANIFEST"; }
changed_files() { awk -F'\t' '$1!="U"{print $2}' "$HOIST_MANIFEST"; }

# Always scan what is in the worktree now, not what prepare staged — the
# whole point of re-running the scan is to check Claude's edits.
restage "$WT" "$HOIST_MANIFEST"

info ""
info "${C_BOLD}hoist scan${C_OFF}  $HOIST_BRANCH -> $HOIST_REMOTE/$HOIST_TARGET"
info ""

# ---------------------------------------------------------------------------
# 1. Secrets
# ---------------------------------------------------------------------------

scan_secrets() {
	section "secrets"
	local scanroot="$HOIST_TMP/scanroot"
	rm -rf "$scanroot"
	mkdir -p "$scanroot"
	local any=0
	while IFS= read -r p; do
		[ -n "$p" ] || continue
		any=1
		mkdir -p "$scanroot/$(dirname "$p")"
		cp "$WT/$p" "$scanroot/$p"
	done < <(present_files)

	if [ "$any" -eq 0 ]; then
		clean "nothing added or modified"
		return
	fi

	findings_begin

	if command -v gitleaks >/dev/null 2>&1; then
		# gitleaks 8.19+ replaced `detect --no-git --source` with `dir`.
		# Support both; do not guess from the version string.
		local out
		if gitleaks dir --help >/dev/null 2>&1; then
			out="$(gitleaks dir --no-banner --report-format json \
				--report-path - "$scanroot" 2>/dev/null || true)"
		else
			out="$(gitleaks detect --no-banner --no-git --source "$scanroot" \
				--report-format json --report-path - 2>/dev/null || true)"
		fi
		while IFS=$'\t' read -r rule file line; do
			[ -n "$rule" ] || continue
			# gitleaks reports whatever path form it walked; make it
			# repo-relative whichever way it came back.
			file="${file#"$scanroot"/}"
			file="${file##*/scanroot/}"
			finding "$file:$line" "$rule ${C_DIM}(gitleaks)${C_OFF}"
		done < <(printf '%s' "$out" | awk '
			/"RuleID":/    { r=$0; sub(/^[^:]*: *"/,"",r); sub(/",?$/,"",r) }
			/"StartLine":/ { l=$0; sub(/^[^:]*: */,"",l); sub(/,$/,"",l) }
			/"File":/      { f=$0; sub(/^[^:]*: *"/,"",f); sub(/",?$/,"",f) }
			/"Fingerprint":/ { if (r != "") print r "\t" f "\t" l; r=""; f=""; l="" }
		')
	else
		warn "  gitleaks not installed — falling back to hoist's own patterns only"
		warn "  install it for real coverage:  brew install gitleaks"
	fi

	# Always-on patterns. These are deliberately few and high-signal: they are
	# a backstop for known scanner gaps, not a secret detector. The exclusion
	# list keeps documentation examples from crying wolf — a scanner that
	# flags AKIAIOSFODNN7EXAMPLE is too noisy to trust.
	local re_aws='AKIA[0-9A-Z]{16}'
	local re_gh='gh[pousr]_[A-Za-z0-9]{20,}'
	local re_pk='-----BEGIN [A-Z ]*PRIVATE KEY-----'
	local re_slack='https://hooks\.slack\.com/services/[A-Za-z0-9/]{20,}'
	local re_jwt='eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.'
	local decoy='EXAMPLE|example|xxxx|XXXX|placeholder|PLACEHOLDER|changeme|CHANGEME|YOUR_|<[a-z-]*>'

	local rx name
	for rx in "aws-access-key-id:$re_aws" "github-token:$re_gh" \
		"private-key:$re_pk" "slack-webhook:$re_slack" "jwt:$re_jwt"; do
		name="${rx%%:*}"
		while IFS=: read -r file line _; do
			[ -n "$file" ] || continue
			finding "${file#"$scanroot"/}:$line" "$name ${C_DIM}(hoist pattern)${C_OFF}"
		done < <(grep -rnE "${rx#*:}" "$scanroot" 2>/dev/null |
			grep -vE "$decoy" || true)
	done

	findings_flush "no credentials in the hoisted files"
}

# ---------------------------------------------------------------------------
# 2. Personal identifiers
# ---------------------------------------------------------------------------

scan_personal() {
	section "personal identifiers"
	findings_begin
	local me user host email

	user="$(id -un 2>/dev/null || echo '')"
	host="$(hostname -s 2>/dev/null || echo '')"
	email="$(git -C "$HOIST_REPO" config user.email 2>/dev/null || echo '')"
	me="$(printf '%s' "${HOME:-}" | sed 's/[][\.*^$/]/\\&/g')"

	local pats=(
		'/Users/[A-Za-z0-9._-]+'
		'/home/[A-Za-z0-9._-]+'
		'/(Desktop|Downloads|Documents)/'
	)
	[ -n "$me" ] && pats+=("$me")
	[ -n "$user" ] && [ "$user" != root ] && pats+=("\\b$user\\b")
	[ -n "$host" ] && pats+=("\\b$host\\b")
	[ -n "$email" ] && pats+=("$(printf '%s' "$email" | sed 's/[][\.*^$/]/\\&/g')")

	# Only the lines this hoist adds. Pre-existing paths on the target branch
	# are not ours to report, and reporting them makes the check unreadable.
	local diff_added
	diff_added="$(git -C "$WT" diff --cached -U0 |
		awk '/^\+\+\+ b\//{f=substr($0,7)} /^@@/{split($3,a,",");l=a[1];sub(/^\+/,"",l);next}
		     /^\+/&&!/^\+\+\+/{print f ":" l ": " substr($0,2); l++}')"

	local p
	for p in "${pats[@]}"; do
		while IFS= read -r hit; do
			[ -n "$hit" ] || continue
			finding "${hit%%: *}" "looks personal: ${C_DIM}$(printf '%s' "${hit#*: }" | cut -c1-60)${C_OFF}"
		done < <(printf '%s\n' "$diff_added" | grep -E "$p" || true)
	done

	findings_flush "no home paths, usernames or machine-specific values in the added lines"
}

# ---------------------------------------------------------------------------
# 3. Upstream drift
# ---------------------------------------------------------------------------

# incorporated <path> <tmpdir> — true if our copy of the file already contains
# the change upstream made since the merge-base.
#
# Three-way merge of ours against theirs over the common ancestor: if the
# merge changes nothing and does not conflict, their work survives our hoist.
incorporated() {
	local p="$1" tmp="$2" safe
	safe="$(printf '%s' "$p" | tr / _)"
	git -C "$HOIST_REPO" show "$HOIST_MERGE_BASE:$p" >"$tmp/$safe.base" 2>/dev/null || return 1
	git -C "$HOIST_REPO" show "$HOIST_BASE_SHA:$p" >"$tmp/$safe.theirs" 2>/dev/null || return 1
	cp "$WT/$p" "$tmp/$safe.ours"
	git merge-file -q -p "$tmp/$safe.ours" "$tmp/$safe.base" "$tmp/$safe.theirs" \
		>"$tmp/$safe.merged" 2>/dev/null || return 1
	cmp -s "$tmp/$safe.ours" "$tmp/$safe.merged"
}

scan_drift() {
	section "upstream drift"
	if [ -z "${HOIST_MERGE_BASE:-}" ]; then
		warn "  unavailable — no shared history with $HOIST_REMOTE/$HOIST_TARGET"
		FINDINGS=$((FINDINGS + 1))
		return
	fi

	local before="$FINDINGS" p n drifted=0
	local tmp="$HOIST_TMP/drift"
	mkdir -p "$tmp"

	while IFS= read -r p; do
		[ -n "$p" ] || continue
		git -C "$HOIST_REPO" diff --quiet "$HOIST_MERGE_BASE" "$HOIST_BASE_SHA" -- "$p" && continue
		drifted=1
		n="$(git -C "$HOIST_REPO" rev-list --count \
			"$HOIST_MERGE_BASE..$HOIST_BASE_SHA" -- "$p")"

		# Upstream moving is not by itself a problem — reverting it is. If our
		# copy already contains their change, a three-way merge against it is
		# a no-op, and there is nothing for the human to decide.
		if [ -f "$WT/$p" ] && incorporated "$p" "$tmp"; then
			dim "  $p — upstream's $n commit(s) already incorporated"
			continue
		fi

		finding_now "$p" "also changed on $HOIST_TARGET ($n commit(s) since your merge-base)"
		git -C "$HOIST_REPO" log --no-merges --format="      %h %s ${C_DIM}(%an)${C_OFF}" \
			"$HOIST_MERGE_BASE..$HOIST_BASE_SHA" -- "$p" >&2
	done < <(changed_files)

	if [ "$FINDINGS" -gt "$before" ]; then
		info ""
		dim "  Hoisting these verbatim would revert that work. Review with:"
		dim "    git -C $HOIST_REPO diff $HOIST_MERGE_BASE $HOIST_REMOTE/$HOIST_TARGET -- <file>"
		dim "  then merge upstream's change into the copy in $WT."
	elif [ "$drifted" -eq 1 ]; then
		clean "upstream moved, and every hoisted file already carries that work"
	else
		clean "no hoisted file moved on $HOIST_TARGET since your merge-base"
	fi
}

# ---------------------------------------------------------------------------
# 4. Gates
# ---------------------------------------------------------------------------

detect_gates() {
	if [ -f "$WT/Makefile" ] || [ -f "$WT/makefile" ]; then
		local t cmd=""
		for t in lint test check; do
			grep -qE "^$t:" "$WT/Makefile" 2>/dev/null && cmd="$cmd${cmd:+ && }make $t"
		done
		[ -n "$cmd" ] && {
			printf '%s' "$cmd"
			return
		}
	fi
	if [ -f "$WT/package.json" ] && grep -q '"test"' "$WT/package.json"; then
		printf 'npm test'
		return
	fi
	if [ -f "$WT/justfile" ] && grep -qE '^test:' "$WT/justfile"; then
		printf 'just test'
		return
	fi
}

scan_gates() {
	section "gates"
	if [ "$RUN_GATES" -eq 0 ]; then
		dim "  skipped (--skip-gates)"
		return
	fi
	[ -n "$GATES_CMD" ] || GATES_CMD="$(detect_gates)"
	if [ -z "$GATES_CMD" ]; then
		warn "  no lint/test target detected — pass --gates 'CMD' to run the repo's own checks"
		warn "  this is the check that catches references dangling after a partial hoist"
		FINDINGS=$((FINDINGS + 1))
		return
	fi

	dim "  \$ $GATES_CMD"
	local log="$HOIST_TMP/gates.log" rc=0
	(cd "$WT" && eval "$GATES_CMD") >"$log" 2>&1 || rc=$?
	if [ "$rc" -eq 0 ]; then
		clean "$GATES_CMD passed in the clean worktree"
	else
		finding_now "gates" "exit $rc — the hoisted state does not stand on its own"
		sed 's/^/      /' "$log" | tail -25 >&2
		dim "      full output: $log"
	fi
}

# ---------------------------------------------------------------------------

for check in secrets personal drift gates; do
	wants "$check" || continue
	case "$check" in
	secrets) scan_secrets ;;
	personal) scan_personal ;;
	drift) scan_drift ;;
	gates) scan_gates ;;
	esac
	info ""
done

if [ "$FINDINGS" -eq 0 ]; then
	info "${C_GRN}all four checks clean${C_OFF}"
	exit 0
fi
info "${C_YEL}$FINDINGS finding(s) — review before pushing${C_OFF}"
exit 1
