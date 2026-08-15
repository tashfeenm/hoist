#!/usr/bin/env bash
#
# hoist cleanup — remove the temporary worktree, its branch and the state
# directory. Your repo's working tree and index are never touched; this only
# undoes what hoist prepare created (the owned /.hoist/ line in
# .git/info/exclude is left in place on purpose).
#
# Usage:
#   hoist cleanup --state FILE [--discard] [--keep-branch]
#
#   --discard      also remove work that exists nowhere else: unstaged edits,
#                  untracked files, or an unpushed commit in the worktree.
#                  Without it, cleanup refuses and lists what it found.
#   --keep-branch  keep the local branch (the worktree still goes)
#
# Cleanup validates the state file like every other command: it will not
# remove anything outside <repo>/.hoist/<id>/, and it will not delete a
# branch or worktree the state does not describe. Exit 0 ok, 1 refused
# (work would be lost), 2 error.
#
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/hoist-lib.sh
. "$HERE/hoist-lib.sh"

usage() {
	print_help "${BASH_SOURCE[0]}"
	exit "${1:-0}"
}

STATE="" KEEP=0 DISCARD=0
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
	--discard)
		DISCARD=1
		shift
		;;
	-h | --help) usage 0 ;;
	*) die "unknown argument: $1" ;;
	esac
done
[ -n "$STATE" ] || usage 2

state_load "$STATE" lenient
lock_repo "$HOIST_REPO"
lock_state
trap 'unlock_state; unlock_repo' EXIT
trap 'unlock_state; unlock_repo; trap - EXIT; exit 130' INT
trap 'unlock_state; unlock_repo; trap - EXIT; exit 143' TERM
trap 'unlock_state; unlock_repo; trap - EXIT; exit 129' HUP
trap 'die "cleanup aborted — operational error (line $LINENO)"' ERR

REPO="$HOIST_REPO" WT="$HOIST_WORKTREE" TMP="$HOIST_TMP" B="$HOIST_BRANCH"

registered=0
git -C "$REPO" worktree list --porcelain >"$TMP/wt.list" 2>/dev/null || die "git worktree list failed — refusing to guess"
grep -Fx -- "worktree $WT" "$TMP/wt.list" >/dev/null && registered=1
present=0
[ -d "$WT" ] && [ ! -L "$WT" ] && present=1

# a worktree directory git no longer knows about cannot be audited for
# unique work: refuse unless told to discard
if [ "$present" -eq 1 ] && [ "$registered" -eq 0 ] && [ "$DISCARD" -eq 0 ]; then
	warn "cleanup refused — the worktree directory exists but git no longer lists it, so its contents cannot be audited"
	dim "  re-run with --discard to remove it (branch $B, worktree $WT)"
	exit 1
fi

# --- would anything unique be lost? ----------------------------------------
#
# (ignored files — build outputs a gate left behind — are treated as
# disposable; everything else in the worktree is audited)

# Unique work = an unpushed commit, staged state that never shipped, or an
# unstaged edit to a MANIFEST path. Non-manifest leftovers (build artifacts,
# a gate's scratch files) can never be committed by hoist; after a verified
# push they are listed and removed, before one they block like everything
# else — the hoist itself has not shipped yet.
if [ "$present" -eq 1 ] && [ "$registered" -eq 1 ] && [ "$DISCARD" -eq 0 ]; then
	[ "$(manifest_digest "$HOIST_MANIFEST")" = "$HOIST_MANIFEST_DIGEST" ] || {
		warn "cleanup refused — the manifest was modified since prepare, so unique work cannot be told apart"
		dim "  re-run with --discard to remove the worktree anyway (branch $B, worktree $WT)"
		exit 1
	}
	lost="" extra="" pushed=0
	head_sha="$(git -C "$WT" rev-parse HEAD 2>/dev/null || true)"
	if [ -n "$head_sha" ] && [ "$head_sha" != "$HOIST_BASE_SHA" ]; then
		if [ -f "$TMP/pushed" ] && [ "$(cat "$TMP/pushed")" = "$head_sha" ]; then
			pushed=1
		else
			lost="$lost
  an unpushed commit: ${head_sha:0:9}"
		fi
	fi
	staged="$(git -C "$WT" diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')"
	[ "$staged" -eq 0 ] || lost="$lost
  $staged staged file(s) — the hoisted state (with any edits made in the worktree), not pushed"
	while IFS= read -r -d '' p; do
		if in_manifest "$HOIST_MANIFEST" "$p"; then
			lost="$lost
  unstaged edit to a hoisted file: $p"
		else
			extra="$extra $p"
		fi
	done < <(git -C "$WT" diff --name-only -z 2>/dev/null)
	while IFS= read -r -d '' p; do
		if in_manifest "$HOIST_MANIFEST" "$p"; then
			lost="$lost
  untracked hoisted file: $p"
		else
			extra="$extra $p"
		fi
	done < <(git -C "$WT" ls-files --others --exclude-standard -z 2>/dev/null)
	if [ -n "$extra" ] && [ "$pushed" -eq 0 ]; then
		lost="$lost
  non-manifest path(s) in the worktree:$extra"
	fi
	if [ -n "$lost" ]; then
		warn "cleanup refused — the worktree holds work that exists nowhere else:$lost"
		dim "  re-run with --discard to remove it anyway (the branch is $B; the worktree is $WT)"
		exit 1
	fi
	[ -z "$extra" ] || dim "removing non-manifest leftovers (gate artifacts):$extra"
fi

# --- remove ----------------------------------------------------------------

problems=""
wt_branch_ok=1
if [ "$registered" -eq 1 ] && [ "$present" -eq 1 ]; then
	[ "$(git -C "$WT" symbolic-ref --quiet HEAD 2>/dev/null || true)" = "refs/heads/$B" ] || wt_branch_ok=0
elif [ "$registered" -eq 0 ] && [ "$present" -eq 0 ]; then
	# nothing left to prove the branch is ours; delete only if the state
	# says so AND the branch exists — same as before, but say so
	:
fi
if [ "$registered" -eq 1 ] && [ "$present" -eq 1 ]; then
	git_h -C "$REPO" worktree remove --force -- "$WT" 2>"$TMP/wt-remove.err" ||
		problems="$problems
  could not remove the worktree: $(tr '\n' ' ' <"$TMP/wt-remove.err")"
elif [ "$registered" -eq 1 ]; then
	problems="$problems
  the worktree directory is already gone but git still lists it — run:  $(printf 'git -C %q worktree prune' "$REPO")  then hoist cleanup again"
elif [ "$present" -eq 1 ]; then
	# not registered (git already pruned it) but the directory is still here,
	# inside our own state dir — remove it with the state dir below
	:
fi

if [ -z "$problems" ] && [ "$KEEP" -eq 0 ]; then
	# only the branch the worktree actually had checked out is ours to delete
	if [ "$wt_branch_ok" -eq 0 ]; then
		dim "branch $B kept — the worktree was not on it, so it is not provably hoist's"
	elif git -C "$REPO" rev-parse --verify -q "refs/heads/$B" >/dev/null 2>&1; then
		# -D, not -d: the branch is usually unmerged by design at this point.
		git_h -C "$REPO" branch -D -- "$B" >/dev/null 2>"$TMP/branch.err" ||
			problems="$problems
  could not delete branch $B: $(tr '\n' ' ' <"$TMP/branch.err")"
	else
		dim "branch $B was already gone"
	fi
fi

if [ -n "$problems" ]; then
	warn "cleanup incomplete:$problems"
	dim "  state kept at $STATE"
	exit 2
fi

# The state directory is exactly <repo>/.hoist/<id> (validated by state_load).
unlock_state
rm -r -- "$TMP"
rmdir -- "$REPO/.hoist" 2>/dev/null || true

# --- verify -----------------------------------------------------------------

wl="$(git -C "$REPO" worktree list --porcelain 2>/dev/null)" || die "git worktree list failed after cleanup — check the repository"
! printf '%s\n' "$wl" | grep -Fx -- "worktree $WT" >/dev/null ||
	die "worktree still registered after cleanup: $WT"
[ ! -e "$WT" ] || die "worktree directory still present: $WT"
[ ! -e "$TMP" ] || die "state directory still present: $TMP"
if [ "$KEEP" -eq 0 ] && [ "$wt_branch_ok" -eq 1 ]; then
	! git -C "$REPO" rev-parse --verify -q "refs/heads/$B" >/dev/null 2>&1 || die "branch still present: $B"
fi

info "cleaned up"
dim "  removed worktree .hoist/$HOIST_ID/tree and its state"
[ "$KEEP" -eq 0 ] || dim "  kept branch $B"
exit 0
