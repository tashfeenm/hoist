#!/usr/bin/env bash
#
# hoist prepare — build a clean worktree off <remote>/<target> and copy the
# current state of the named files into it.
#
# The dirty repo's working tree and index are never modified. A temporary
# worktree and a new branch are created under <repo>/.hoist/<id>/ (excluded
# from status by an owned line in .git/info/exclude); hoist cleanup removes
# them.
#
# Usage:
#   hoist prepare --target BRANCH [options] -- FILE [FILE...]
#
#   --repo DIR                 the dirty repo (default: cwd)
#   --target BRANCH            branch to hoist onto (required)
#   --remote NAME              remote holding the target (default: origin)
#   --branch NAME              name for the new branch (default: hoist/<id>)
#   --no-fetch                 do not fetch; use the local remote-tracking ref
#                              (recorded — scan reports drift as stale)
#   --allow-unrelated-history  proceed without a merge-base (recorded — the
#                              drift check cannot run and stays a finding)
#
# Paths are relative to the repo root. A path that no longer exists in the
# working tree is treated as a deletion. Spaces and leading dashes are fine;
# TAB, LF, CR and ':' in a path are rejected (see README).
#
# Prints "state: <path>" on stderr and the path alone on stdout. Every later
# command takes --state <that path>. Exit 0 ok, 1 nothing to hoist, 2 error.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/hoist-lib.sh
. "$HERE/hoist-lib.sh"

usage() {
	print_help "${BASH_SOURCE[0]}"
	exit "${1:-0}"
}

REPO="$PWD" TARGET="" REMOTE="origin" BRANCH="" FETCH=1 UNRELATED_OK=0
FILES=()

while [ $# -gt 0 ]; do
	case "$1" in
	--repo)
		REPO="${2:?--repo needs a directory}"
		shift 2
		;;
	--target)
		TARGET="${2:?--target needs a branch}"
		shift 2
		;;
	--remote)
		REMOTE="${2:?--remote needs a name}"
		shift 2
		;;
	--branch)
		BRANCH="${2:?--branch needs a name}"
		shift 2
		;;
	--no-fetch)
		FETCH=0
		shift
		;;
	--allow-unrelated-history)
		UNRELATED_OK=1
		shift
		;;
	-h | --help) usage 0 ;;
	--)
		shift
		FILES+=("$@")
		break
		;;
	-*) die "unknown option: $1" ;;
	*)
		FILES+=("$1")
		shift
		;;
	esac
done

[ -n "$TARGET" ] || usage 2
[ "${#FILES[@]}" -gt 0 ] || die "no files given — hoist promotes only what you name"

# --- the repo --------------------------------------------------------------

REPO="$(repo_root "$REPO")"
git_common_dir "$REPO" >/dev/null || die "cannot locate the git directory of $REPO"

git -C "$REPO" rev-parse --verify -q HEAD >/dev/null 2>&1 || die "repo has no commits yet"
[ "$(git -C "$REPO" rev-parse --is-shallow-repository 2>/dev/null)" != "true" ] ||
	die "this is a shallow clone — the drift check needs history. Run: git fetch --unshallow"

git -C "$REPO" remote get-url -- "$REMOTE" >/dev/null 2>&1 || die "no such remote: $REMOTE"
git check-ref-format --branch "$TARGET" >/dev/null 2>&1 || die "not a valid branch name: $TARGET"
! has_control "$TARGET$REMOTE" || die "target/remote contain control characters"

ID="$(date +%Y%m%d-%H%M%S)-$RANDOM"
BRANCH="${BRANCH:-hoist/$ID}"
git check-ref-format --branch "$BRANCH" >/dev/null 2>&1 || die "not a valid branch name: $BRANCH"
! has_control "$BRANCH" || die "branch name contains control characters"
[ "$BRANCH" != "$TARGET" ] || die "the new branch cannot be the target itself"
! git -C "$REPO" rev-parse --verify -q "refs/heads/$BRANCH" >/dev/null 2>&1 ||
	die "branch already exists: $BRANCH (pass --branch to pick another name)"

# --- normalise, dedupe and vet the paths -----------------------------------

PATHS=()
seen=""
for path in "${FILES[@]}"; do
	case "$path" in "$REPO"/*) path="${path#"$REPO"/}" ;; esac
	while [ "${path#./}" != "$path" ]; do path="${path#./}"; done
	reject_bad_path "$path"
	case "$seen" in *"
$path
"*) continue ;; esac
	seen="$seen
$path
"
	PATHS+=("$path")
done

# --- locate the target -----------------------------------------------------

if [ "$FETCH" -eq 1 ]; then
	dim "fetching $REMOTE/$TARGET ..."
	fetch_err="$(git -C "$REPO" fetch -q "$REMOTE" "$TARGET" 2>&1 >/dev/null | scrub_urls)" ||
		die "could not fetch $REMOTE/$TARGET: ${fetch_err:-no details from git}. Fix the connection, or pass --no-fetch to hoist against the local copy (drift will then be reported as stale)."
fi

BASE_REF="refs/remotes/$REMOTE/$TARGET"
git -C "$REPO" rev-parse --verify -q "$BASE_REF" >/dev/null 2>&1 ||
	die "no such branch: $REMOTE/$TARGET (is the remote configured and fetched?)"
BASE_SHA="$(git -C "$REPO" rev-parse "$BASE_REF")"

# The merge-base is what upstream-drift detection compares against: work that
# landed on the target after this point is work our file states predate.
MERGE_BASE="$(git -C "$REPO" merge-base HEAD "$BASE_REF" 2>/dev/null || true)"
UNRELATED=0
if [ -z "$MERGE_BASE" ]; then
	[ "$UNRELATED_OK" -eq 1 ] ||
		die "no shared history between HEAD and $REMOTE/$TARGET — the drift check cannot run. Pass --allow-unrelated-history to proceed anyway (drift stays a standing finding)."
	UNRELATED=1
fi

# Vet each path against the repo (index side) and the target tree.
for path in "${PATHS[@]}"; do
	path_check_parents "$REPO" "$path"
	path_check_gitlink "$REPO" "$BASE_REF" "$path"
	[ ! -d "$REPO/$path" ] || [ -L "$REPO/$path" ] ||
		die "directories are not supported, name files: $path"
	if [ ! -e "$REPO/$path" ] && [ ! -L "$REPO/$path" ]; then
		flag="$(GIT_LITERAL_PATHSPECS=1 git -C "$REPO" ls-files -v -- "$path" 2>/dev/null | head -1 | cut -c1)"
		case "$flag" in
		S | s) die "$path is tracked but not checked out (sparse/skip-worktree) — materialise it first; hoist will not treat its absence as a deletion" ;;
		esac
	fi
done

# --- the workspace: <repo>/.hoist/<id>/ ------------------------------------

CREATED_TMP=0 CREATED_WT=0 COMMITTED=0 ROLLED=0
rollback() {
	[ "$ROLLED" -eq 0 ] || return 0
	ROLLED=1
	[ "$COMMITTED" -eq 1 ] && {
		unlock_repo
		return 0
	}
	if [ "$CREATED_WT" -eq 1 ]; then
		git_h -C "$REPO" worktree remove --force -- "$WORKTREE" >/dev/null 2>&1 || true
		git -C "$REPO" branch -D -- "$BRANCH" >/dev/null 2>&1 || true
	fi
	if [ "$CREATED_TMP" -eq 1 ] && [ -d "$TMP" ] && [ -f "$TMP/.hoist-state" ]; then
		rm -r -- "$TMP"
		rmdir -- "$HDIR" 2>/dev/null || true
	fi
	unlock_repo
}
on_exit() {
	local rc=$?
	rollback
	exit "$rc"
}
on_sig() {
	rollback
	trap - EXIT
	exit "$1"
}
lock_repo "$REPO"
trap on_exit EXIT
trap 'on_sig 130' INT
trap 'on_sig 143' TERM
trap 'on_sig 129' HUP

HDIR="$REPO/.hoist"
[ ! -L "$HDIR" ] || die "$HDIR is a symlink — refusing to use it as hoist's workspace"
[ ! -e "$HDIR" ] || [ -d "$HDIR" ] || die "$HDIR exists and is not a directory"
[ -z "$(git -C "$REPO" ls-files -- .hoist 2>/dev/null | head -1)" ] ||
	die "$HDIR contains tracked files — hoist needs it as an untracked workspace"

# One owned, root-anchored exclude rule, written once and left in place.
excl="$(git -C "$REPO" rev-parse --git-path info/exclude)"
case "$excl" in /*) ;; *) excl="$REPO/$excl" ;; esac
[ ! -L "$excl" ] || die "$excl is a symlink — refusing to edit it"
mkdir -p -- "$(dirname -- "$excl")"
[ -e "$excl" ] || : >"$excl"
if ! grep -qFx -- '/.hoist/' "$excl"; then
	# keep a pre-existing last line intact if it lacks its newline
	[ -z "$(tail -c1 -- "$excl")" ] || printf '\n' >>"$excl"
	printf '# hoist: temporary worktrees (this line is owned by hoist and safe to keep)\n/.hoist/\n' >>"$excl"
fi
git -C "$REPO" check-ignore -q -- .hoist/probe 2>/dev/null ||
	die "the /.hoist/ exclude rule does not take effect (a higher-precedence negation?) — refusing to create an unignored worktree inside your repo"

TMP="$HDIR/$ID"
WORKTREE="$TMP/tree"
STATE="$TMP/state"
MANIFEST="$TMP/manifest"


(
	umask 077
	mkdir -p -- "$HDIR" && mkdir -- "$TMP"
) || die "could not create $TMP"
CREATED_TMP=1
(
	umask 077
	: >"$TMP/.hoist-state"
)

git_h -C "$REPO" -c core.sparseCheckout=false worktree add -q -b "$BRANCH" -- "$WORKTREE" "$BASE_REF" ||
	die "could not create the worktree"
CREATED_WT=1
[ -z "$(git -C "$WORKTREE" ls-files -v 2>/dev/null | grep -E '^[Ss] ' | head -1)" ] ||
	die "the temporary worktree came out sparse — hoist needs a full checkout"

# --- copy the named file states --------------------------------------------

: >"$MANIFEST"
for path in "${PATHS[@]}"; do
	path_check_parents "$WORKTREE" "$path"
	src="$REPO/$path"
	dst="$WORKTREE/$path"

	base_type="$(GIT_LITERAL_PATHSPECS=1 git -C "$WORKTREE" ls-tree -z HEAD -- "$path" 2>/dev/null |
		tr '\0' '\n' | awk -F'\t' -v p="$path" '$2==p {split($1,m," "); print m[2]; exit}')"
	case "$base_type" in
	tree) die "$path is a directory on $REMOTE/$TARGET — name files inside it instead" ;;
	commit) die "$path is a submodule on $REMOTE/$TARGET" ;;
	esac

	if [ -e "$src" ] || [ -L "$src" ]; then
		if git -C "$REPO" check-ignore -q -- "$path" 2>/dev/null; then
			warn "  $path is gitignored in this repo — hoisting it anyway, but check it is really shareable"
		fi
		mkdir -p -- "$(dirname -- "$dst")"
		copy_state "$src" "$dst"
	else
		[ "$base_type" = "blob" ] ||
			die "$path is not in your working tree and not on $REMOTE/$TARGET — nothing to hoist"
		rm -f -- "$dst"
	fi
	printf '%s\n' "$path" >>"$MANIFEST"
done

restage "$WORKTREE" "$MANIFEST"

# --- record and report -----------------------------------------------------

HOIST_VERSION=1
HOIST_ID="$ID"
HOIST_REPO="$REPO"
HOIST_WORKTREE="$WORKTREE"
HOIST_TMP="$TMP"
HOIST_MANIFEST="$MANIFEST"
HOIST_BRANCH="$BRANCH"
HOIST_TARGET="$TARGET"
HOIST_REMOTE="$REMOTE"
HOIST_BASE_SHA="$BASE_SHA"
HOIST_MERGE_BASE="$MERGE_BASE"
HOIST_FETCHED="$FETCH"
HOIST_UNRELATED="$UNRELATED"
state_write "$STATE"

info ""
info "${C_BOLD}hoisted onto $BRANCH${C_OFF}  (base: $REMOTE/$TARGET @ ${BASE_SHA:0:9})"
info ""
added=0 modified=0 deleted=0 typechg=0
while IFS= read -r -d '' st && IFS= read -r -d '' path; do
	case "$st" in
	A)
		info "  ${C_GRN}new${C_OFF}       $path"
		added=$((added + 1))
		;;
	M)
		info "  ${C_GRN}modified${C_OFF}  $path"
		modified=$((modified + 1))
		;;
	D)
		info "  ${C_RED}deleted${C_OFF}   $path"
		deleted=$((deleted + 1))
		;;
	T)
		info "  ${C_YEL}type${C_OFF}      $path (file/symlink type changed)"
		typechg=$((typechg + 1))
		;;
	*) info "  $st         $path" ;;
	esac
done < <(staged_status "$WORKTREE")
npaths=${#PATHS[@]}
unchanged=$((npaths - added - modified - deleted - typechg))
while IFS= read -r path; do
	[ -n "$path" ] || continue
	if ! staged_status "$WORKTREE" | tr '\0' '\n' | grep -qFx -- "$path"; then
		info "  ${C_DIM}unchanged $path — already identical on $TARGET${C_OFF}"
	fi
done <"$MANIFEST"
info ""
dim "  worktree  .hoist/$ID/tree  (inside your repo, excluded from status)"
dim "  $added new, $modified modified, $deleted deleted, $typechg type-changed, $unchanged unchanged"
[ "$FETCH" -eq 1 ] || warn "  --no-fetch: $REMOTE/$TARGET is whatever was fetched last; drift will be reported as stale"
[ "$UNRELATED" -eq 0 ] || warn "  --allow-unrelated-history: no merge-base; the drift check cannot run"
info ""

if [ "$((added + modified + deleted + typechg))" -eq 0 ]; then
	warn "nothing differs from $REMOTE/$TARGET — there is nothing to hoist (rolled back)"
	exit 1
fi

info "state: $STATE"
printf '%s\n' "$STATE"
COMMITTED=1
