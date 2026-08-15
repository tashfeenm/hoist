#!/usr/bin/env bash
#
# hoist-cleanup.sh — remove the temporary worktree and its branch.
#
# Safe to run at any point. Your repo's working tree is never touched; this
# only undoes what hoist-prepare.sh created.
#
# Usage:
#   hoist-cleanup.sh --state FILE [--keep-branch]
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/hoist-lib.sh
. "$HERE/hoist-lib.sh"

STATE="" KEEP=0
while [ $# -gt 0 ]; do
	case "$1" in
	--state)
		STATE="${2:?--state needs a file}"
		shift 2
		;;
	--keep-branch)
		KEEP=1
		shift
		;;
	-h | --help)
		sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
		exit 0
		;;
	*) die "unknown argument: $1" ;;
	esac
done
[ -n "$STATE" ] || die "--state is required"
state_load "$STATE"

# Uncommitted work in the worktree is work Claude or the human did there —
# say so rather than discarding it quietly.
if [ -d "$HOIST_WORKTREE" ] && ! git -C "$HOIST_WORKTREE" diff --cached --quiet 2>/dev/null; then
	warn "discarding staged-but-uncommitted changes in $HOIST_WORKTREE"
fi

git -C "$HOIST_REPO" worktree remove --force "$HOIST_WORKTREE" 2>/dev/null || true
git -C "$HOIST_REPO" worktree prune

if [ "$KEEP" -eq 0 ]; then
	# -D, not -d: the branch is usually unmerged by design at this point.
	git -C "$HOIST_REPO" branch -D "$HOIST_BRANCH" >/dev/null 2>&1 ||
		dim "branch $HOIST_BRANCH was already gone"
fi

rm -rf "$HOIST_TMP"
info "cleaned up"
dim "  removed worktree $HOIST_WORKTREE"
[ "$KEEP" -eq 1 ] && dim "  kept branch $HOIST_BRANCH"
exit 0
