#!/usr/bin/env bash
#
# hoist acknowledge — accept specific findings, by ID, with a reason.
#
# Usage:
#   hoist acknowledge --state FILE --finding ID [--finding ID...] --reason "..."
#
# Only findings listed in the CURRENT attestation can be acknowledged (IDs are
# printed by scan and finish); the acknowledgement is bound to the attested
# tree and findings set, so any edit or rescan that changes either voids it.
# Skipped checks, gate mutation and operational errors are not findings and
# cannot be acknowledged — they yield no attestation in the first place.
#
# The reason is one line (≤200 chars), sanitized, and refused if it carries a
# credential-shaped token or a personal identifier. Acknowledged IDs and
# reasons are recorded in the commit as Hoist-Acknowledged: trailers.
#
# Exit 0 ok, 2 error.
#
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/hoist-lib.sh
. "$HERE/hoist-lib.sh"

usage() {
	print_help "${BASH_SOURCE[0]}"
	exit "${1:-0}"
}

STATE="" REASON="" IDS=""
while [ $# -gt 0 ]; do
	case "$1" in
	--state)
		STATE="${2:?--state needs a file}"
		shift 2
		;;
	--finding)
		[ -n "${2:-}" ] || die "--finding needs an ID"
		case "$2" in
		*[!A-Za-z0-9-]*) die "not a finding ID: $2" ;;
		esac
		IDS="$IDS $2"
		shift 2
		;;
	--reason)
		REASON="${2:?--reason needs text}"
		shift 2
		;;
	-h | --help) usage 0 ;;
	*) die "unknown argument: $1" ;;
	esac
done
[ -n "$STATE" ] && [ -n "$IDS" ] && [ -n "$REASON" ] || usage 2

state_load "$STATE"
lock_state
trap 'unlock_state' EXIT
trap 'unlock_state; trap - EXIT; exit 130' INT
trap 'unlock_state; trap - EXIT; exit 143' TERM
trap 'unlock_state; trap - EXIT; exit 129' HUP
trap 'die "acknowledge aborted — operational error (line $LINENO)"' ERR
WT="$HOIST_WORKTREE"
TMP="$HOIST_TMP"
umask 077

restage "$WT" "$HOIST_MANIFEST"
TREE="$(staged_tree "$WT")"
A="$TMP/attest"
attest_verify "$A" "$TREE"
FD="$(kv_get "$A" findings_digest)"

reason="$(sanitize_line "$REASON" 200)"
[ -n "$reason" ] || die "--reason is empty after sanitizing"
if why="$(text_looks_sensitive "$reason" 2>&1)"; then
	die "the reason contains $why — hoist will not put that in a commit trailer"
fi

known="$(kv_get_all "$A" finding)"
for id in $IDS; do
	printf '%s\n' "$known" | grep -qFx -- "$id" ||
		die "unknown finding ID for the current attestation: $id (current: $(printf '%s' "$known" | tr '\n' ' '))"
done

# Keep earlier acknowledgements only if they are bound to this same tree and
# findings set; otherwise start over.
NEW="$TMP/ack.tmp"
: >"$NEW"
kv_set "$NEW" version 1
kv_set "$NEW" id "$HOIST_ID"
kv_set "$NEW" tree "$TREE"
kv_set "$NEW" findings "$FD"
if ack_valid "$TMP/ack" "$TREE" "$FD"; then
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in
		ack.*=*)
			k="${line%%=*}"
			k="${k#ack.}"
			case " $IDS " in *" $k "*) continue ;; esac # re-acknowledged below
			printf '%s\n' "$line" >>"$NEW"
			;;
		esac
	done <"$TMP/ack"
fi
for id in $IDS; do
	kv_set "$NEW" "ack.$id" "$reason"
done
mv -f -- "$NEW" "$TMP/ack"

n=0
remaining=""
while IFS= read -r id; do
	[ -n "$id" ] || continue
	if kv_get "$TMP/ack" "ack.$id" >/dev/null 2>&1; then
		n=$((n + 1))
	else
		remaining="$remaining $id"
	fi
done <<EOF
$known
EOF
info "acknowledged: $(printf '%s' "$IDS" | sed 's/^ //')  ${C_DIM}— $reason${C_OFF}"
if [ -n "$remaining" ]; then
	info "$n acknowledged, still open:$remaining"
else
	info "$n acknowledged, none open — run hoist finish, then (in a later turn, on the human's yes) hoist push"
fi
exit 0
