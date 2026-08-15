#!/usr/bin/env bash
#
# hoist finish — the dry run: show exactly what would land, and write the
# receipt that `hoist push` requires. Nothing is committed or pushed here.
#
# Usage:
#   hoist finish --state FILE --title "..." [--body "..."]
#
#   --state FILE   state file from hoist prepare (required)
#   --title TEXT   commit subject and PR title (required; one line, ≤200 chars)
#   --body TEXT    commit body and PR description (optional)
#
# Requires an attestation from a full `hoist scan` bound to the CURRENT
# staged tree; refuses otherwise ("re-run hoist scan"). Shows the full staged
# diff (stat, mode/type summary, patch), the attestation summary with finding
# IDs and their acknowledgement status, and the exact next command. Title and
# body are sanitized and run through the secret/personal safeguards.
#
# Writes <state dir>/message and <state dir>/receipt (bound to tree,
# attestation digest and message digest). Exit 0 ok, 2 error.
#
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/hoist-lib.sh
. "$HERE/hoist-lib.sh"

usage() {
	print_help "${BASH_SOURCE[0]}"
	exit "${1:-0}"
}

STATE="" TITLE="" BODY=""
while [ $# -gt 0 ]; do
	case "$1" in
	--state)
		STATE="${2:?--state needs a file}"
		shift 2
		;;
	--title)
		TITLE="${2:?--title needs text}"
		shift 2
		;;
	--body)
		BODY="${2:?--body needs text}"
		shift 2
		;;
	-h | --help) usage 0 ;;
	*) die "unknown argument: $1" ;;
	esac
done
[ -n "$STATE" ] && [ -n "$TITLE" ] || usage 2

state_load "$STATE"
lock_state
trap 'unlock_state' EXIT
trap 'die "finish aborted — operational error (line $LINENO)"' ERR
WT="$HOIST_WORKTREE"
TMP="$HOIST_TMP"
umask 077

# --- the tree, and the attestation for it ---------------------------------

restage "$WT" "$HOIST_MANIFEST"
[ "$(git -C "$WT" rev-parse HEAD)" = "$HOIST_BASE_SHA" ] ||
	die "the worktree's HEAD is not the base commit — run hoist cleanup --discard and prepare again"
TREE="$(staged_tree "$WT")"
attest_verify "$TMP/attest" "$TREE"
if git_01 -C "$WT" diff --cached --quiet HEAD; then
	die "nothing staged in the worktree — there is nothing to hoist"
fi

# --- title and body -------------------------------------------------------

title="$(sanitize_line "$TITLE" 200)"
[ -n "$title" ] || die "--title is empty after sanitizing"
esc="$(printf '\033')"
body="$(printf '%s\n' "$BODY" | sed -e "s/$esc\\[[0-9;]*[A-Za-z]//g" | tr -d '\000-\010\013\014\016-\037\177' | head -c 4000)"
if why="$(text_looks_sensitive "$title" 2>&1)"; then
	die "the title contains $why — hoist will not put that in a commit"
fi
if [ -n "$body" ] && why="$(text_looks_sensitive "$body" 2>&1)"; then
	die "the body contains $why — hoist will not put that in a commit"
fi
{
	printf '%s\n' "$title"
	if [ -n "$body" ]; then
		printf '\n%s\n' "$body"
	fi
} >"$TMP/message.tmp"
mv -f -- "$TMP/message.tmp" "$TMP/message"

# --- show everything that would land --------------------------------------

info ""
info "${C_BOLD}$title${C_OFF}"
[ -z "$body" ] || printf '%s\n' "$body" | sed 's/^/  /' >&2
info ""
info "  branch  $HOIST_BRANCH"
info "  onto    $HOIST_REMOTE/$HOIST_TARGET @ ${HOIST_BASE_SHA:0:9}"
info "  tree    ${TREE:0:9}"
info ""
git -C "$WT" diff --cached --no-renames --stat --summary HEAD >&2 || die "could not diff"
info ""
info "${C_BOLD}full diff — this is exactly what would land${C_OFF}"
git -C "$WT" diff --cached --no-renames --no-ext-diff HEAD >&2 || die "could not diff"
info ""

# --- attestation summary --------------------------------------------------

A="$TMP/attest"
info "${C_BOLD}scan${C_OFF}  (attestation for tree ${TREE:0:9})"
for c in gates secrets personal drift; do
	v="$(kv_get "$A" "check.$c")"
	printf '  %-9s %s\n' "$c" "$v" >&2
done
NF="$(kv_get "$A" findings)"
FD="$(kv_get "$A" findings_digest)"
unacked=""
if [ "$NF" -gt 0 ]; then
	info ""
	info "  ${C_YEL}$NF finding(s):${C_OFF}"
	while IFS= read -r id; do
		[ -n "$id" ] || continue
		txt="$(awk -F'\t' -v i="$id" '$1==i {print $3 "  " $4; exit}' "$TMP/findings.txt" 2>/dev/null || true)"
		if ack_valid "$TMP/ack" "$TREE" "$FD" && reason="$(kv_get "$TMP/ack" "ack.$id" 2>/dev/null)"; then
			printf '    %s%-20s%s %s  %sacknowledged: %s%s\n' "$C_DIM" "$id" "$C_OFF" "$txt" "$C_GRN" "$reason" "$C_OFF" >&2
		else
			printf '    %s%-20s%s %s  %sunacknowledged%s\n' "$C_YEL" "$id" "$C_OFF" "$txt" "$C_YEL" "$C_OFF" >&2
			unacked="$unacked $id"
		fi
	done < <(kv_get_all "$A" finding)
fi
info ""

# --- receipt --------------------------------------------------------------

R="$TMP/receipt.tmp"
: >"$R"
kv_set "$R" version 1
kv_set "$R" id "$HOIST_ID"
kv_set "$R" tree "$TREE"
kv_set "$R" attest "$(digest_file "$A")"
kv_set "$R" message "$(digest_file "$TMP/message")"
mv -f -- "$R" "$TMP/receipt"

info "${C_BOLD}dry run — nothing has been committed or pushed.${C_OFF} Receipt written for tree ${TREE:0:9}."
if [ -n "$unacked" ]; then
	dim "  unacknowledged findings block the push. Fix them in the worktree and re-run"
	dim "  hoist scan, or acknowledge each by ID with a real reason:"
	dim "    $(printf 'hoist acknowledge --state %q --finding ID --reason "..."' "$STATE")"
else
	dim "  to ship, in a later turn, once the human has said yes to THIS tree:"
	dim "    $(printf 'hoist push --state %q' "$STATE")"
fi
dim "  to discard:  $(printf 'hoist cleanup --state %q --discard' "$STATE")"
info ""
exit 0
