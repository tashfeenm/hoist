#!/usr/bin/env bash
#
# hoist-prepare.sh — build a clean worktree off origin/<target> and copy the
# current state of the named files into it.
#
# The dirty repo's working tree is never modified. A temporary worktree and a
# new branch are created; hoist-cleanup.sh removes both.
#
# Usage:
#   hoist-prepare.sh --target main [options] -- FILE [FILE...]
#
#   --repo DIR       the dirty repo (default: cwd)
#   --target BRANCH  branch to hoist onto (required)
#   --remote NAME    remote holding the target (default: origin)
#   --branch NAME    name for the new branch (default: hoist/<timestamp>)
#   --no-fetch       skip fetching the remote (offline / already current)
#
# Paths are relative to the repo root. A path that no longer exists in the
# working tree is treated as a deletion.
#
# Prints the path of the state file on stdout. Everything else goes to stderr.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/hoist-lib.sh
. "$HERE/hoist-lib.sh"

usage() {
	sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
	exit "${1:-0}"
}

REPO="$PWD" TARGET="" REMOTE="origin" BRANCH="" FETCH=1
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

REPO="$(repo_root "$REPO")"
BRANCH="${BRANCH:-hoist/$(date +%Y%m%d-%H%M%S)}"

git -C "$REPO" rev-parse --verify -q HEAD >/dev/null ||
	die "repo has no commits yet"

# --- locate the target -----------------------------------------------------

if [ "$FETCH" -eq 1 ]; then
	dim "fetching $REMOTE/$TARGET ..."
	git -C "$REPO" fetch -q "$REMOTE" "$TARGET" 2>/dev/null ||
		warn "could not fetch $REMOTE/$TARGET — using the local copy"
fi

BASE_REF="refs/remotes/$REMOTE/$TARGET"
git -C "$REPO" rev-parse --verify -q "$BASE_REF" >/dev/null ||
	die "no such branch: $REMOTE/$TARGET (is the remote configured?)"
BASE_SHA="$(git -C "$REPO" rev-parse "$BASE_REF")"

# The merge-base is what upstream-drift detection compares against: work that
# landed on the target after this point is work our file states predate.
MERGE_BASE="$(git -C "$REPO" merge-base HEAD "$BASE_REF" 2>/dev/null || true)"
[ -n "$MERGE_BASE" ] ||
	warn "no shared history with $REMOTE/$TARGET — the drift check will be unavailable"

# --- carve out the clean worktree ------------------------------------------

TMPBASE="${TMPDIR:-/tmp}"
TMP="$(mktemp -d "${TMPBASE%/}/hoist.XXXXXXXX")"
WORKTREE="$TMP/tree"
STATE="$TMP/state"
MANIFEST="$TMP/manifest"

git -C "$REPO" worktree add -q --no-checkout -b "$BRANCH" "$WORKTREE" "$BASE_REF" ||
	die "could not create worktree (does branch $BRANCH already exist?)"
git -C "$WORKTREE" checkout -q

# --- copy the named file states --------------------------------------------

: >"$MANIFEST"
added=0 modified=0 deleted=0 unchanged=0

for path in "${FILES[@]}"; do
	# Normalise "./src/x.sh" and absolute paths inside the repo.
	case "$path" in "$REPO"/*) path="${path#"$REPO"/}" ;; esac
	path="${path#./}"
	reject_bad_path "$path"

	src="$REPO/$path"
	dst="$WORKTREE/$path"
	in_base=0
	git -C "$WORKTREE" cat-file -e "HEAD:$path" 2>/dev/null && in_base=1

	if [ -e "$src" ] || [ -L "$src" ]; then
		[ -d "$src" ] && die "directories are not supported, name files: $path"

		# A file the target repo ignores is a strong signal it is personal.
		if git -C "$REPO" check-ignore -q "$path" 2>/dev/null; then
			warn "  $path is gitignored in this repo — hoisting it anyway, but check it is really shareable"
		fi

		copy_state "$src" "$dst"
		git -C "$WORKTREE" add -f -- "$path"

		if [ "$in_base" -eq 1 ]; then
			if git -C "$WORKTREE" diff --cached --quiet -- "$path"; then
				printf 'U\t%s\n' "$path" >>"$MANIFEST"
				unchanged=$((unchanged + 1))
				continue
			fi
			printf 'M\t%s\n' "$path" >>"$MANIFEST"
			modified=$((modified + 1))
		else
			printf 'A\t%s\n' "$path" >>"$MANIFEST"
			added=$((added + 1))
		fi
	else
		[ "$in_base" -eq 1 ] ||
			die "$path is not in your working tree and not on $REMOTE/$TARGET — nothing to hoist"
		git -C "$WORKTREE" rm -q -- "$path"
		printf 'D\t%s\n' "$path" >>"$MANIFEST"
		deleted=$((deleted + 1))
	fi
done

# --- record and report -----------------------------------------------------

: >"$STATE"
state_set "$STATE" HOIST_REPO "$REPO"
state_set "$STATE" HOIST_WORKTREE "$WORKTREE"
state_set "$STATE" HOIST_TMP "$TMP"
state_set "$STATE" HOIST_MANIFEST "$MANIFEST"
state_set "$STATE" HOIST_BRANCH "$BRANCH"
state_set "$STATE" HOIST_TARGET "$TARGET"
state_set "$STATE" HOIST_REMOTE "$REMOTE"
state_set "$STATE" HOIST_BASE_SHA "$BASE_SHA"
state_set "$STATE" HOIST_MERGE_BASE "${MERGE_BASE:-}"

info ""
info "${C_BOLD}hoisted onto $BRANCH${C_OFF}  (base: $REMOTE/$TARGET @ ${BASE_SHA:0:9})"
info ""
while IFS=$'\t' read -r action path; do
	case "$action" in
	A) info "  ${C_GRN}new${C_OFF}       $path" ;;
	M) info "  ${C_GRN}modified${C_OFF}  $path" ;;
	D) info "  ${C_RED}deleted${C_OFF}   $path" ;;
	U) info "  ${C_DIM}unchanged $path — already identical on $TARGET${C_OFF}" ;;
	esac
done <"$MANIFEST"
info ""
dim "  worktree  $WORKTREE"
dim "  $added new, $modified modified, $deleted deleted, $unchanged unchanged"
info ""

if [ "$((added + modified + deleted))" -eq 0 ]; then
	warn "nothing differs from $REMOTE/$TARGET — there is nothing to hoist"
fi

printf '%s\n' "$STATE"
