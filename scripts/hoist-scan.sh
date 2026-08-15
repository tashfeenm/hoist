#!/usr/bin/env bash
#
# hoist scan — the four checks, each producing named findings, and — only
# when all four ran on the final tree — an attestation that push consumes.
#
#   gates        the target repo's own lint/test, run FIRST in the clean
#                worktree so what the other checks see is the post-gate tree
#   secrets      credentials in the staged blobs (gitleaks, plus a small
#                always-on pattern set for what it misses)
#   personal     home directories, usernames, machine paths, personal email —
#                checked against the lines this hoist ADDS
#   drift        files that also moved on the target since your merge-base.
#                Hoisting them verbatim would silently revert that work.
#
# Usage:
#   hoist scan --state FILE [options]
#
#   --state FILE     state file printed by hoist prepare (required)
#   --run-gates      run the autodetected gates command (scan never runs it
#                    silently: without this flag it prints the command and
#                    marks gates "not run")
#   --gates CMD      run CMD as the gates (bash -e -o pipefail -c CMD, in the
#                    worktree, stdin closed, no timeout)
#   --skip-gates     do not run gates (no attestation can result)
#   --only CHECK     run one check (repeatable): secrets|personal|drift|gates
#                    (no attestation can result)
#
# Attestation: written to <state dir>/attest only when all four checks ran
# and gates did not modify any hoisted file. Any earlier attestation is
# deleted when a scan starts. Findings get stable IDs; acknowledge them with
# `hoist acknowledge`. Skipped checks, gate mutation and operational errors
# are never acknowledgeable — they simply yield no attestation.
#
# Exit: 0 all four ran and are clean; 1 findings, or fewer than four checks
# ran, or gates modified the tree; 2 operational error.
#
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/hoist-lib.sh
. "$HERE/hoist-lib.sh"

usage() {
	print_help "${BASH_SOURCE[0]}"
	exit "${1:-0}"
}

STATE="" GATES_CMD="" RUN_GATES=0 SKIP_GATES=0 ONLY=""
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
	--run-gates)
		RUN_GATES=1
		shift
		;;
	--skip-gates)
		SKIP_GATES=1
		shift
		;;
	--only)
		case "${2:-}" in
		secrets | personal | drift | gates) ONLY="$ONLY ${2}" ;;
		*) die "--only takes one of: secrets personal drift gates (got '${2:-}')" ;;
		esac
		shift 2
		;;
	-h | --help) usage 0 ;;
	*) die "unknown argument: $1" ;;
	esac
done
[ -n "$STATE" ] || usage 2
[ -z "$GATES_CMD" ] || [ "$SKIP_GATES" -eq 0 ] || die "--gates and --skip-gates are contradictory"

state_load "$STATE"
lock_state
trap 'unlock_state' EXIT
trap 'unlock_state; trap - EXIT; exit 130' INT
trap 'unlock_state; trap - EXIT; exit 143' TERM
trap 'unlock_state; trap - EXIT; exit 129' HUP
# Backstop only: bash 3.2 ERR traps miss conditionals, functions and process
# substitutions, so every step below also checks its own status explicitly.
trap 'die "scan aborted — operational error (line $LINENO)"' ERR

WT="$HOIST_WORKTREE"
TMP="$HOIST_TMP"
ATTEST="$TMP/attest"
FINDINGS_FILE="$TMP/findings.txt"
umask 077

# Any earlier attestation is void the moment a rescan starts.
rm -f -- "$ATTEST"
: >"$FINDINGS_FILE"

wants() {
	[ -z "$ONLY" ] && return 0
	case " $ONLY " in *" $1 "*) return 0 ;; esac
	return 1
}
section() { info "${C_BOLD}$1${C_OFF}"; }
clean() { printf '  %sclean%s  %s\n' "$C_GRN" "$C_OFF" "$1" >&2; }

# --- findings --------------------------------------------------------------
#
# finding <check> <location> <rule> <text> — record one finding with a stable
# ID derived from check:location:rule (short digest). Two reporters naming the
# same check+location count once; the first reporter wins.
NFIND=0
finding() {
	local check="$1" loc="$2" rule="$3" text="$4" id
	if grep -qF -- "	$check	$loc	" "$FINDINGS_FILE" 2>/dev/null; then return 0; fi
	id="$check-$(digest_str "$check:$loc:$rule" | cut -c1-8)"
	printf '%s\t%s\t%s\t%s\n' "$id" "$check" "$loc" "$(sanitize_line "$text" 160)" >>"$FINDINGS_FILE"
	printf '  %s%-34s%s %s  %s[%s]%s\n' "$C_YEL" "$loc" "$C_OFF" "$text" "$C_DIM" "$id" "$C_OFF" >&2
	NFIND=$((NFIND + 1))
}

# --- what is staged now ----------------------------------------------------
#
# The manifest is only the allowed set; current actions come from the index.

restage "$WT" "$HOIST_MANIFEST"
[ "$(git -C "$WT" rev-parse HEAD)" = "$HOIST_BASE_SHA" ] ||
	die "the worktree's HEAD is not the base commit — something committed in it. Run hoist cleanup --discard and prepare again"

PRESENT="$TMP/scan.present" # staged paths that exist in the index (A/M/T)
CHANGED="$TMP/scan.changed" # every staged difference (A/M/D/T)
refresh_lists() {
	: >"$PRESENT"
	: >"$CHANGED"
	while IFS= read -r -d '' st && IFS= read -r -d '' p; do
		printf '%s\n' "$p" >>"$CHANGED"
		case "$st" in A | M | T) printf '%s\n' "$p" >>"$PRESENT" ;; esac
	done < <(staged_status "$WT")
}
refresh_lists

info ""
info "${C_BOLD}hoist scan${C_OFF}  $HOIST_BRANCH -> $HOIST_REMOTE/$HOIST_TARGET"
info ""

# per-check status: clean | findings | not-run | skipped   (errors die → 2)
ST_GATES="not-run" ST_SECRETS="not-run" ST_PERSONAL="not-run" ST_DRIFT="not-run"
ENG_GATES="none" ENG_SECRETS="none" ENG_PERSONAL="patterns" ENG_DRIFT="merge-base"
GATES_DIGEST="-"
MUTATED=0

# ---------------------------------------------------------------------------
# 1. Gates — first, so the tree the other checks see is the post-gate tree
# ---------------------------------------------------------------------------

detect_gates() {
	local mk="" t cmd=""
	for mk in GNUmakefile makefile Makefile; do
		[ -f "$WT/$mk" ] && break
		mk=""
	done
	if [ -n "$mk" ]; then
		for t in lint test check; do
			grep -qE "^$t:" "$WT/$mk" 2>/dev/null && cmd="$cmd${cmd:+ && }make $t"
		done
	fi
	if [ -f "$WT/package.json" ] &&
		awk '/"scripts"[[:space:]]*:/ {s=1} s && /"test"[[:space:]]*:/ {found=1} s && /^[[:space:]]*}/ {s=0} END {exit !found}' "$WT/package.json"; then
		cmd="$cmd${cmd:+ && }npm test"
	fi
	for t in justfile Justfile .justfile; do
		if [ -f "$WT/$t" ] && grep -qE '^test:' "$WT/$t"; then
			cmd="$cmd${cmd:+ && }just test"
			break
		fi
	done
	printf '%s' "$cmd"
}

refs_snapshot() { git -C "$WT" for-each-ref --format='%(refname) %(objectname)' 2>/dev/null; }

scan_gates() {
	section "gates"
	if [ "$SKIP_GATES" -eq 1 ]; then
		dim "  skipped (--skip-gates) — no attestation can be written"
		ST_GATES="skipped"
		return 0
	fi
	local cmd="$GATES_CMD" detected=""
	if [ -z "$cmd" ]; then
		detected="$(detect_gates)"
		if [ -n "$detected" ] && [ "$RUN_GATES" -eq 1 ]; then
			cmd="$detected"
		elif [ -n "$detected" ]; then
			warn "  detected: $detected"
			warn "  not run — re-run with --run-gates to execute it, or --gates 'CMD' for something else"
			dim "  (gates execute the repository's own code with your credentials and network; the worktree isolates file state, not a security sandbox)"
			ST_GATES="not-run"
			return 0
		else
			warn "  no lint/test target detected — pass --gates 'CMD' to run the repo's own checks"
			warn "  (this is the check that catches references dangling after a partial hoist;"
			warn "   for a repo with truly no checks, --gates true is honest and gets recorded)"
			ST_GATES="not-run"
			return 0
		fi
	fi
	ENG_GATES="bash"
	GATES_DIGEST="$(digest_str "$cmd")"
	dim "  \$ $cmd"

	local t0 t1 refs0 refs1 log="$TMP/gates.log" rc=0 changed
	t0="$(staged_tree "$WT")"
	refs0="$(refs_snapshot)"
	(cd "$WT" && exec bash -e -o pipefail -c "$cmd") </dev/null >"$log" 2>&1 || rc=$?

	# Whatever the gates did to the index is dropped; whatever they did to the
	# hoisted files on disk is what we now stage — and compare.
	restage "$WT" "$HOIST_MANIFEST"
	t1="$(staged_tree "$WT")"
	refs1="$(refs_snapshot)"
	refresh_lists

	if [ "$rc" -eq 0 ]; then
		clean "$cmd passed in the clean worktree"
		ST_GATES="clean"
	else
		finding gates "gates" "exit" "exit $rc — the hoisted state does not stand on its own"
		sed 's/^/      /' "$log" | tail -25 >&2
		dim "      full output: $log"
		ST_GATES="findings"
	fi
	if [ "$refs0" != "$refs1" ] || [ "$(git -C "$WT" rev-parse HEAD)" != "$HOIST_BASE_SHA" ]; then
		finding gates "gates" "refs" "the gates changed HEAD or refs in the repository — no attestation; run hoist cleanup --discard and prepare again"
		MUTATED=1
	fi
	if [ "$t0" != "$t1" ]; then
		changed="$(git -C "$WT" diff-tree -r --no-renames --name-only "$t0" "$t1" | tr '\n' ' ')"
		finding gates "gates" "mutated" "hoisted files changed across the gates run ($changed): a formatter, or a nondeterministic clean filter — no attestation; re-run hoist scan (an idempotent formatter converges)"
		MUTATED=1
	fi
	local extra
	extra="$(git -C "$WT" status --porcelain --untracked=all -z 2>/dev/null | tr '\0' '\n' | awk 'NF' | while IFS= read -r l; do
		p="${l#???}"
		in_manifest "$HOIST_MANIFEST" "$p" || printf 'x\n'
	done | wc -l | tr -d ' ')"
	[ "${extra:-0}" -eq 0 ] || dim "  ($extra non-manifest path(s) left in the worktree by the gates — ignored; they cannot be committed)"
	return 0
}

# ---------------------------------------------------------------------------
# 2. Secrets — read from the INDEX blobs, so scanned bytes are committed bytes
# ---------------------------------------------------------------------------

scan_secrets() {
	section "secrets"
	local scanroot="$TMP/scanroot" p any=0
	rm -rf -- "$scanroot"
	mkdir -p -- "$scanroot"
	while IFS= read -r p; do
		[ -n "$p" ] || continue
		any=1
		mkdir -p -- "$scanroot/$(dirname -- "$p")"
		git -C "$WT" cat-file blob ":0:$p" >"$scanroot/$p" || die "could not read staged blob for $p"
	done <"$PRESENT"
	ST_SECRETS="clean"
	if [ "$any" -eq 0 ]; then
		ENG_SECRETS="none-needed"
		clean "nothing added or modified"
		return 0
	fi

	local before="$NFIND"
	if command -v gitleaks >/dev/null 2>&1; then
		ENG_SECRETS="gitleaks+patterns"
		local report="$TMP/gitleaks.json" log="$TMP/gitleaks.log" rc=0 parsed=0 reported=0 own=""
		rm -f -- "$report"
		# gitleaks 8.19+ replaced `detect --no-git --source` with `dir`.
		if gitleaks dir --help >/dev/null 2>&1; then
			gitleaks dir --no-banner --report-format json --report-path "$report" \
				"$scanroot" >"$log" 2>&1 || rc=$?
		else
			gitleaks detect --no-banner --no-git --source "$scanroot" \
				--report-format json --report-path "$report" >"$log" 2>&1 || rc=$?
		fi
		case "$rc" in
		0) ;;
		1)
			# Leaks. Parse for per-line detail — and never let a parse gap
			# turn into "clean": if we parsed fewer records than gitleaks
			# reported (or none), add one aggregate finding.
			while IFS=$'\t' read -r rule file line; do
				[ -n "$rule" ] || continue
				file="${file#"$scanroot"/}"
				file="${file##*/scanroot/}"
				finding secrets "$file:$line" "$rule" "$rule ${C_DIM}(gitleaks)${C_OFF}"
				parsed=$((parsed + 1))
			done < <(awk '
				# strict, one-field-per-line shapes only; anything else parses
				# as zero records and becomes the aggregate finding below
				/^[[:space:]]*"RuleID":[[:space:]]*"[^"]*",?[[:space:]]*$/    { r=$0; sub(/^[^:]*:[[:space:]]*"/,"",r); sub(/",?[[:space:]]*$/,"",r) }
				/^[[:space:]]*"StartLine":[[:space:]]*[0-9]+,?[[:space:]]*$/ { l=$0; sub(/^[^:]*:[[:space:]]*/,"",l); sub(/,?[[:space:]]*$/,"",l) }
				/^[[:space:]]*"File":[[:space:]]*"[^"]*",?[[:space:]]*$/      { f=$0; sub(/^[^:]*:[[:space:]]*"/,"",f); sub(/",?[[:space:]]*$/,"",f) }
				/^[[:space:]]*"Fingerprint":/ { if (r != "" && f != "" && l != "") print r "\t" f "\t" l; r=""; f=""; l="" }
			' "$report" 2>/dev/null || true)
			reported="$(grep -c '"Fingerprint"' "$report" 2>/dev/null || true)"
			own="$(sed -n 's/.*leaks found: *\([0-9][0-9]*\).*/\1/p' "$log" | tail -1)"
			[ -n "$own" ] && [ "$own" -gt "$reported" ] 2>/dev/null && reported="$own"
			if [ "$parsed" -eq 0 ] || [ "$parsed" -lt "${reported:-0}" ]; then
				finding secrets "gitleaks" "aggregate" "gitleaks reported leaks (exit 1) — ${reported:-?} record(s), $parsed parsed; see $report"
			fi
			;;
		*)
			sed 's/^/      /' "$log" | tail -10 >&2
			die "gitleaks failed (exit $rc) — see $log"
			;;
		esac
	else
		ENG_SECRETS="patterns"
		warn "  gitleaks not installed — falling back to hoist's own patterns only"
		warn "  install it for real coverage:  brew install gitleaks"
	fi

	# Always-on patterns. Deliberately few and high-signal: a backstop for
	# known scanner gaps, not a secret detector. The decoy list is applied to
	# the MATCHED TOKEN only — never to the filename or the rest of the line —
	# and names exact AWS documentation values plus tokens containing EXAMPLE.
	local re_aws='AKIA[0-9A-Z]{16}'
	local re_gh='gh[pousr]_[A-Za-z0-9]{20,}'
	local re_pk='-----BEGIN [A-Z ]*PRIVATE KEY-----'
	local re_slack='https://hooks\.slack\.com/services/[A-Za-z0-9/]{20,}'
	local re_jwt='eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.'
	local rx name file line tok
	for rx in "aws-access-key-id:$re_aws" "github-token:$re_gh" \
		"private-key:$re_pk" "slack-webhook:$re_slack" "jwt:$re_jwt"; do
		name="${rx%%:*}"
		while IFS= read -r hit; do
			[ -n "$hit" ] || continue
			file="${hit%%:*}"
			file="${file#./}"
			line="${hit#*:}"
			tok="${line#*:}"
			line="${line%%:*}"
			# AWS documentation values (the secret keys are here for
			# completeness — the pattern set does not match them anyway)
			case "$tok" in
			AKIAIOSFODNN7EXAMPLE | AKIAI44QH8DHBEXAMPLE) continue ;;
			wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY | je7MtGbClwBF/2Zp9Utk/h3yCo8nvbEXAMPLEKEY) continue ;;
			*EXAMPLE*) continue ;;
			esac
			finding secrets "$file:$line" "$name" "$name ${C_DIM}(hoist pattern)${C_OFF}"
		done < <(cd "$scanroot" && grep -rnoE -- "${rx#*:}" . 2>/dev/null || true)
	done

	[ "$NFIND" -gt "$before" ] && ST_SECRETS="findings"
	[ "$NFIND" -gt "$before" ] || clean "no credentials in the staged blobs"
	return 0
}

# ---------------------------------------------------------------------------
# 3. Personal identifiers — against the lines this hoist adds
# ---------------------------------------------------------------------------

scan_personal() {
	section "personal identifiers"
	local before="$NFIND" p user host email locs="$TMP/personal.locs" txt="$TMP/personal.txt"
	: >"$locs"
	: >"$txt"

	# Per file, so no diff-header parsing is needed: after the first @@ of a
	# single-file -U0 diff, every leading '+' is content (a "++foo" line is a
	# content line, not a header).
	while IFS= read -r p; do
		[ -n "$p" ] || continue
		GIT_LITERAL_PATHSPECS=1 git -C "$WT" diff --cached -U0 --no-color --no-ext-diff HEAD -- "$p" |
			awk -v p="$p" -v locs="$locs" -v txt="$txt" '
				/^@@/ { s=$3; sub(/^\+/,"",s); split(s,a,","); l=a[1]+0; inh=1; next }
				inh && /^\+/ { print p ":" l >> locs; print substr($0,2) >> txt; l++; next }
			' || die "could not diff $p"
	done <"$PRESENT"

	user="$(id -un 2>/dev/null || true)"
	host="$(hostname -s 2>/dev/null || true)"
	email="$(git -C "$HOIST_REPO" config user.email 2>/dev/null || true)"

	report() { # report <grep args...> — grep -n over the content lines
		local n content
		while IFS= read -r hit; do
			[ -n "$hit" ] || continue
			n="${hit%%:*}"
			content="${hit#*:}"
			finding personal "$(sed -n "${n}p" "$locs")" "personal" \
				"looks personal: ${C_DIM}$(sanitize_line "$content" 60)${C_OFF}"
		done < <(grep -n "$@" "$txt" 2>/dev/null || true)
	}
	# generic path shapes: regex
	report -E '/Users/[A-Za-z0-9._-]+'
	report -E '/home/[A-Za-z0-9._-]+'
	report -E '/(Desktop|Downloads|Documents)/'
	# exact values: fixed strings (word-bounded for user and host)
	[ -n "${HOME:-}" ] && [ "$HOME" != "/" ] && report -F -- "$HOME"
	[ -n "$email" ] && report -F -- "$email"
	[ -n "$user" ] && [ "$user" != root ] && report -Fw -- "$user"
	[ -n "$host" ] && [ "$host" != localhost ] && report -Fw -- "$host"

	if [ "$NFIND" -gt "$before" ]; then
		ST_PERSONAL="findings"
	else
		ST_PERSONAL="clean"
		clean "no home paths, usernames or machine-specific values in the added lines"
	fi
	rm -f -- "$locs" "$txt"
	return 0
}

# ---------------------------------------------------------------------------
# 4. Upstream drift
# ---------------------------------------------------------------------------

# tree_entry <rev> <path> — "mode sha" of a path in a commit's tree, or "".
tree_entry() {
	GIT_LITERAL_PATHSPECS=1 git -C "$HOIST_REPO" ls-tree -z "$1" -- "$2" 2>/dev/null |
		tr '\0' '\n' | awk -F'\t' -v p="$2" '$2==p {split($1,m," "); print m[1] " " m[3]; exit}'
}
# index_entry <path> — "mode sha" from the worktree index, or "".
index_entry() {
	GIT_LITERAL_PATHSPECS=1 git -C "$WT" ls-files -s -z -- "$1" 2>/dev/null |
		tr '\0' '\n' | awk -F'\t' -v p="$1" '$2==p {split($1,m," "); print m[1] " " m[2]; exit}'
}

# incorporated <path> — true if our staged copy already contains the change
# upstream made since the merge-base: a three-way merge of ours against
# theirs over the base is a no-op. Text blobs only.
incorporated() {
	local p="$1" d
	d="$(mktemp -d "$TMP/drift.XXXXXX")" || return 1
	git -C "$HOIST_REPO" show "$HOIST_MERGE_BASE:$p" >"$d/base" 2>/dev/null || {
		rm -r -- "$d"
		return 1
	}
	git -C "$HOIST_REPO" show "$HOIST_BASE_SHA:$p" >"$d/theirs" 2>/dev/null || {
		rm -r -- "$d"
		return 1
	}
	git -C "$WT" cat-file blob ":0:$p" >"$d/ours" 2>/dev/null || {
		rm -r -- "$d"
		return 1
	}
	local rc=0
	git merge-file -q -p "$d/ours" "$d/base" "$d/theirs" >"$d/merged" 2>/dev/null || rc=$?
	if [ "$rc" -eq 0 ] && cmp -s "$d/ours" "$d/merged"; then
		rm -r -- "$d"
		return 0
	fi
	rm -r -- "$d"
	return 1
}

scan_drift() {
	section "upstream drift"
	local before="$NFIND" p n drifted=0 mb tg ix mb_mode tg_mode ix_mode kind rule
	if [ "$HOIST_UNRELATED" = "1" ]; then
		finding drift "drift" "unrelated" "no shared history with $HOIST_REMOTE/$HOIST_TARGET (prepared with --allow-unrelated-history) — the drift check cannot run; the final diff is the only authority"
		ST_DRIFT="findings"
		return 0
	fi
	if [ "$HOIST_FETCHED" = "0" ]; then
		finding drift "drift" "stale" "prepared with --no-fetch — $HOIST_REMOTE/$HOIST_TARGET may be stale; drift below is against the last fetch"
	fi

	while IFS= read -r p; do
		[ -n "$p" ] || continue
		mb="$(tree_entry "$HOIST_MERGE_BASE" "$p")"
		tg="$(tree_entry "$HOIST_BASE_SHA" "$p")"
		[ "$mb" != "$tg" ] || continue # upstream did not touch it
		drifted=1
		ix="$(index_entry "$p")"
		mb_mode="${mb%% *}"
		tg_mode="${tg%% *}"
		ix_mode="${ix%% *}"
		n="$(git -C "$HOIST_REPO" rev-list --count "$HOIST_MERGE_BASE..$HOIST_BASE_SHA" -- "$p" 2>/dev/null || echo '?')"

		kind="" rule=""
		if [ -z "$tg" ]; then
			rule="deleted" kind="deleted upstream — your copy re-adds it (a rename upstream shows as delete+add); manual review"
		elif [ -z "$mb" ]; then
			rule="add-add" kind="also added upstream (add/add) — merge by hand; manual review"
		elif [ -z "$ix" ]; then
			rule="delete-vs-change" kind="you delete it, but it changed upstream ($n commit(s)) — manual review"
		elif [ "$mb_mode" = 120000 ] || [ "$tg_mode" = 120000 ] || [ "$ix_mode" = 120000 ]; then
			rule="type" kind="file/symlink type involved (upstream ${mb_mode}→${tg_mode}, yours $ix_mode) — manual review"
		elif [ "$mb_mode" != "$tg_mode" ] && [ "$ix_mode" != "$tg_mode" ]; then
			rule="mode" kind="mode changed upstream (${mb_mode}→${tg_mode}) but your copy is $ix_mode — chmod the copy in the worktree"
			[ "${mb#* }" = "${tg#* }" ] || kind="$kind (content changed upstream too)"
		elif git -C "$HOIST_REPO" diff --numstat "$HOIST_MERGE_BASE" "$HOIST_BASE_SHA" -- "$p" 2>/dev/null | grep -q "$(printf '^-\t-\t')"; then
			rule="binary" kind="binary — changed upstream ($n commit(s)); resolve by hand"
		elif [ "${mb#* }" = "${tg#* }" ]; then
			# mode-only upstream change and our mode already matches → nothing to carry
			dim "  $p — upstream changed only the mode, and your copy matches"
			continue
		elif incorporated "$p"; then
			dim "  $p — upstream's $n commit(s) already incorporated"
			continue
		else
			rule="changed" kind="also changed on $HOIST_TARGET ($n commit(s) since your merge-base) — hoisting verbatim would revert that work"
		fi
		finding drift "$p" "$rule" "$kind"
		git -C "$HOIST_REPO" log --no-merges --format="      %h %s ${C_DIM}(%an)${C_OFF}" \
			"$HOIST_MERGE_BASE..$HOIST_BASE_SHA" -- "$p" >&2 2>/dev/null || true
	done <"$CHANGED"

	if [ "$NFIND" -gt "$before" ]; then
		ST_DRIFT="findings"
		info ""
		dim "  Review upstream's change with:"
		dim "    $(printf 'git -C %q diff %s %s/%s -- FILE' "$HOIST_REPO" "${HOIST_MERGE_BASE:0:9}" "$HOIST_REMOTE" "$HOIST_TARGET")"
		dim "  then merge it into the copy in the worktree and re-run hoist scan."
		dim "  (drift = 'the target changed since your HEAD/target merge-base'; a file restored"
		dim "   locally from older history looks clean here — the final diff is the authority)"
	elif [ "$drifted" -eq 1 ]; then
		ST_DRIFT="clean"
		clean "upstream moved, and every hoisted file already carries that work"
	else
		ST_DRIFT="clean"
		clean "no hoisted file moved on $HOIST_TARGET since your merge-base"
	fi
	return 0
}

# ---------------------------------------------------------------------------

for check in gates secrets personal drift; do
	wants "$check" || continue
	case "$check" in
	gates) scan_gates ;;
	secrets) scan_secrets ;;
	personal) scan_personal ;;
	drift) scan_drift ;;
	esac
	info ""
done

# --- attestation -----------------------------------------------------------

ran=0
for s in "$ST_GATES" "$ST_SECRETS" "$ST_PERSONAL" "$ST_DRIFT"; do
	case "$s" in clean | findings) ran=$((ran + 1)) ;; esac
done

TREE="$(staged_tree "$WT")"
IDS="$(cut -f1 "$FINDINGS_FILE" | sort)"
FDIGEST="$(digest_str "$IDS")"

if [ "$ran" -eq 4 ] && [ "$MUTATED" -eq 0 ]; then
	tmpf="$ATTEST.tmp.$$"
	: >"$tmpf"
	kv_set "$tmpf" version 1
	kv_set "$tmpf" id "$HOIST_ID"
	kv_set "$tmpf" base "$HOIST_BASE_SHA"
	kv_set "$tmpf" target "$HOIST_REMOTE/$HOIST_TARGET"
	kv_set "$tmpf" branch "$HOIST_BRANCH"
	kv_set "$tmpf" tree "$TREE"
	kv_set "$tmpf" manifest "$(manifest_digest "$HOIST_MANIFEST")"
	kv_set "$tmpf" check.gates "$ENG_GATES:$ST_GATES"
	kv_set "$tmpf" check.secrets "$ENG_SECRETS:$ST_SECRETS"
	kv_set "$tmpf" check.personal "$ENG_PERSONAL:$ST_PERSONAL"
	kv_set "$tmpf" check.drift "$ENG_DRIFT:$ST_DRIFT"
	kv_set "$tmpf" gates_cmd "$GATES_DIGEST"
	kv_set "$tmpf" findings "$NFIND"
	while IFS= read -r id; do
		[ -n "$id" ] && kv_set "$tmpf" finding "$id"
	done <<EOF
$IDS
EOF
	kv_set "$tmpf" findings_digest "$FDIGEST"
	mv -f -- "$tmpf" "$ATTEST"
fi

# --- summary ---------------------------------------------------------------

if [ "$ran" -eq 4 ] && [ "$MUTATED" -eq 0 ] && [ "$NFIND" -eq 0 ]; then
	info "${C_GRN}all four checks ran and are clean${C_OFF}  ${C_DIM}attestation written for tree ${TREE:0:9}${C_OFF}"
	exit 0
fi

msg="$ran of 4 checks ran"
[ "$NFIND" -eq 0 ] || msg="$msg, $NFIND finding(s): $(printf '%s' "$IDS" | tr '\n' ' ')"
if [ "$MUTATED" -eq 1 ]; then
	info "${C_YEL}$msg — gates modified the tree or refs: NO attestation; re-run hoist scan${C_OFF}"
elif [ "$ran" -lt 4 ]; then
	info "${C_YEL}$msg — fewer than four ran: NO attestation${C_OFF}"
else
	info "${C_YEL}$msg — review before pushing${C_OFF}  ${C_DIM}attestation written for tree ${TREE:0:9}; acknowledge findings by ID or fix and re-scan${C_OFF}"
fi
exit 1
