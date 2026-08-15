#!/usr/bin/env bash
#
# hoist-finish.sh — commit the hoisted state, and on request push it and open
# the PR.
#
# Without --push this is a dry run: it shows exactly what would land and stops.
# That is the default on purpose. hoist never pushes silently.
#
# Usage:
#   hoist-finish.sh --state FILE --title "..." [options]
#
#   --state FILE   state file from hoist-prepare.sh (required)
#   --title TEXT   commit subject and PR title (required)
#   --body TEXT    commit body and PR description
#   --push         actually commit, push, and open the PR
#   --no-pr        push the branch but do not open a PR
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/hoist-lib.sh
. "$HERE/hoist-lib.sh"

usage() {
	sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
	exit "${1:-0}"
}

STATE="" TITLE="" BODY="" PUSH=0 MAKE_PR=1
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
	--push)
		PUSH=1
		shift
		;;
	--no-pr)
		MAKE_PR=0
		shift
		;;
	-h | --help) usage 0 ;;
	*) die "unknown argument: $1" ;;
	esac
done
[ -n "$STATE" ] && [ -n "$TITLE" ] || usage 2
state_load "$STATE"
WT="$HOIST_WORKTREE"

# Claude may have edited the copies in the worktree since prepare (stripping
# personal hunks, merging an upstream change), so commit what is there now —
# still scoped to the files you named.
restage "$WT" "$HOIST_MANIFEST"

git -C "$WT" diff --cached --quiet &&
	die "nothing staged in the worktree — there is nothing to hoist"

info ""
info "${C_BOLD}$TITLE${C_OFF}"
[ -n "$BODY" ] && { printf '%s\n' "$BODY" | sed 's/^/  /' >&2; }
info ""
git -C "$WT" diff --cached --stat >&2
info ""
info "  branch  $HOIST_BRANCH"
info "  onto    $HOIST_REMOTE/$HOIST_TARGET @ ${HOIST_BASE_SHA:0:9}"
info ""

if [ "$PUSH" -eq 0 ]; then
	info "${C_BOLD}dry run — nothing has been pushed.${C_OFF}"
	dim "  inspect   git -C $WT diff --cached"
	dim "  ship it   $(basename "$0") --state $STATE --title ... --push"
	dim "  discard   $HERE/hoist-cleanup.sh --state $STATE"
	info ""
	exit 0
fi

# --- commit ----------------------------------------------------------------

if [ -n "$BODY" ]; then
	git -C "$WT" commit -q -m "$TITLE" -m "$BODY"
else
	git -C "$WT" commit -q -m "$TITLE"
fi
info "committed $(git -C "$WT" rev-parse --short HEAD)"

# --- push ------------------------------------------------------------------

git -C "$WT" push -q -u "$HOIST_REMOTE" "$HOIST_BRANCH"
info "pushed   $HOIST_BRANCH -> $HOIST_REMOTE"

# --- pull request ----------------------------------------------------------

# Turn a remote URL into a browsable https base, for the gh-less path.
web_url() {
	local u="$1"
	case "$u" in
	git@*:*) u="https://${u#git@}" && u="${u/://}" ;;
	ssh://git@*) u="https://${u#ssh://git@}" ;;
	esac
	u="${u%.git}"
	case "$u" in https://*) printf '%s' "$u" ;; esac
}

if [ "$MAKE_PR" -eq 0 ]; then
	info ""
	dim "branch pushed; PR not requested (--no-pr)"
	exit 0
fi

remote_url="$(git -C "$WT" remote get-url "$HOIST_REMOTE" 2>/dev/null || true)"

if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1 &&
	[[ "$remote_url" == *github.com* ]]; then
	(cd "$WT" && gh pr create --base "$HOIST_TARGET" --head "$HOIST_BRANCH" \
		--title "$TITLE" --body "${BODY:-Hoisted with https://github.com/tashfeen/hoist}") >&2
else
	# gh is optional, and so is GitHub. Never fail at the last step for
	# want of either — print the link a human can click instead.
	compare="$(web_url "$remote_url")"
	info ""
	if [ -n "$compare" ]; then
		info "${C_BOLD}open the PR:${C_OFF}"
		info "  $compare/compare/$HOIST_TARGET...$HOIST_BRANCH?expand=1"
	else
		info "branch is pushed — open the PR in your host's UI"
	fi
fi

info ""
dim "when the PR is up:  $HERE/hoist-cleanup.sh --state $STATE"
