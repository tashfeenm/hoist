#!/usr/bin/env bash
#
# hoist-lib.sh — helpers shared by the hoist scripts.
#
# Sourced, never executed. Nothing here needs anything beyond git and bash
# (bash 3.2 included: no mapfile, no ${var,,}, no associative arrays).
#
# Conventions:
#   - humans read stderr; stdout carries data a caller may capture
#   - die exits 2 (operational error); only a completed scan exits 1
#   - every git command hoist itself issues on the worktree goes through git_h,
#     which disables hooks; the repo's own gates run with hooks as configured

# shellcheck disable=SC2034  # colour vars are consumed by the sourcing scripts

HOIST_VERSION_STRING="0.1.0"

# --- output ----------------------------------------------------------------

hoist_is_tty() { [ -t 2 ]; }

if hoist_is_tty && [ -z "${NO_COLOR:-}" ]; then
	C_DIM=$'\033[2m' C_BOLD=$'\033[1m' C_RED=$'\033[31m'
	C_YEL=$'\033[33m' C_GRN=$'\033[32m' C_OFF=$'\033[0m'
else
	C_DIM='' C_BOLD='' C_RED='' C_YEL='' C_GRN='' C_OFF=''
fi

info() { printf '%s\n' "$*" >&2; }
dim() { printf '%s%s%s\n' "$C_DIM" "$*" "$C_OFF" >&2; }
warn() { printf '%s%s%s\n' "$C_YEL" "$*" "$C_OFF" >&2; }
die() {
	printf '%shoist: %s%s\n' "$C_RED" "$*" "$C_OFF" >&2
	exit 2
}

# print_help <script> — the script's leading comment block: skip the shebang,
# print every "#" line, stop at the first line that is not a comment.
print_help() {
	awk 'NR==1 && /^#!/ {next}
	     /^#/ {sub(/^# ?/, ""); print; next}
	     {exit}' "$1" >&2
}

# sanitize_line <text> [max] — one line, bounded, no control or escape bytes.
# Used for titles, reasons and anything that lands in a trailer or PR text.
sanitize_line() {
	local max="${2:-200}" esc
	esc="$(printf '\033')"
	printf '%s\n' "$1" | sed -e "s/$esc\\[[0-9;]*[A-Za-z]//g" |
		tr -d '\000-\010\013-\037\177' | tr '\n\t' '  ' | cut -c1-"$max" |
		sed -e 's/[[:space:]]*$//' -e 's/^[[:space:]]*//'
}

# has_control <text> — true if the text contains control bytes (TAB/LF/CR
# included) or ESC.
has_control() {
	case "$1" in
	*[[:cntrl:]]*) return 0 ;;
	esac
	return 1
}

# --- digests ---------------------------------------------------------------
#
# git hash-object is the one hashing primitive we can rely on everywhere.

digest_str() { printf '%s' "$1" | git hash-object --stdin; }
digest_file() { git hash-object -- "$1"; }

# --- paths -----------------------------------------------------------------

# canon_dir <dir> — physical absolute path, or fail.
canon_dir() { (cd -- "$1" 2>/dev/null && pwd -P); }

# canon_file <path> — physical absolute path of an existing file (its
# directory is canonicalised; the leaf is kept as named, so a symlinked leaf
# stays visible to [ -L ]).
canon_file() {
	local d
	d="$(canon_dir "$(dirname -- "$1")")" || return 1
	printf '%s/%s\n' "$d" "$(basename -- "$1")"
}

# reject_bad_path <path> — refuse anything hoist cannot promote safely.
# Purely syntactic; the filesystem-side checks are in path_check_parents and
# path_check_gitlink. Called on every user-supplied path, before any mkdir,
# rm or redirection.
#
# Rejected, with the exact byte list documented in the README: TAB, LF, CR
# and ':' (every file:line reporter would mis-split), leading ':' pathspec
# magic (implied by the colon rule), '.git' as any component (case-
# insensitively — case-insensitive filesystems make .GIT the same directory),
# '.hoist' as the first component (that is hoist's own workspace), empty
# components ('a//b', trailing '/'), '.' and '..' components, absolute paths.
# Spaces and leading dashes are fine.
reject_bad_path() {
	local p="$1" rest comp lower
	[ -n "$p" ] || die "empty path in file list"
	case "$p" in
	/*) die "path must be relative to the repo root: $p" ;;
	esac
	case "$p" in
	*$'\t'* | *$'\n'* | *$'\r'*) die "path contains a tab, newline or carriage return — hoist does not support these (see README): $p" ;;
	*:*) die "path contains ':' — hoist does not support colons in filenames (see README): $p" ;;
	esac
	rest="$p/"
	while [ -n "$rest" ]; do
		comp="${rest%%/*}"
		rest="${rest#*/}"
		[ -n "$comp" ] || die "path has an empty component: $p"
		case "$comp" in
		. | ..) die "path contains '.' or '..' components: $p" ;;
		esac
		lower="$(printf '%s' "$comp" | tr '[:upper:]' '[:lower:]')"
		[ "$lower" != ".git" ] || die "refusing to hoist git internals: $p"
	done
	case "$p" in
	.hoist | .hoist/*) die "refusing to hoist from hoist's own workspace: $p" ;;
	esac
}

# path_check_parents <root> <path> — every existing ancestor of <root>/<path>
# must be a real directory: symlinked parents could read or write outside the
# repository, so they are rejected before anything is created or removed.
path_check_parents() {
	local root="$1" p="$2" prefix="" rest comp
	rest="$(dirname -- "$p")"
	[ "$rest" != "." ] || return 0
	rest="$rest/"
	while [ -n "$rest" ]; do
		comp="${rest%%/*}"
		rest="${rest#*/}"
		prefix="${prefix:+$prefix/}$comp"
		if [ -L "$root/$prefix" ]; then
			die "$p: parent '$prefix' is a symlink — hoist refuses symlinked parents"
		fi
		if [ -e "$root/$prefix" ] && [ ! -d "$root/$prefix" ]; then
			die "$p: parent '$prefix' exists and is not a directory"
		fi
	done
}

# path_check_gitlink <repo> <ref> <path> — refuse a path that lives inside a
# submodule (gitlink) either in the repo's index or in the target tree, and
# refuse the path itself being a gitlink.
path_check_gitlink() {
	local repo="$1" ref="$2" p="$3" prefix="" rest comp entry meta
	rest="$p/"
	while [ -n "$rest" ]; do
		comp="${rest%%/*}"
		rest="${rest#*/}"
		prefix="${prefix:+$prefix/}$comp"
		# index: "<mode> <sha> <stage>\t<path>" — exact path match only
		while IFS= read -r -d '' entry; do
			[ "${entry#*"$(printf '\t')"}" = "$prefix" ] || continue
			meta="${entry%%"$(printf '\t')"*}"
			[ "${meta%% *}" != "160000" ] ||
				die "$p: '$prefix' is a submodule — hoist does not promote into or across submodules"
		done < <(GIT_LITERAL_PATHSPECS=1 git -C "$repo" ls-files -s -z -- "$prefix" 2>/dev/null)
		# target tree: "<mode> <type> <sha>\t<path>"
		while IFS= read -r -d '' entry; do
			[ "${entry#*"$(printf '\t')"}" = "$prefix" ] || continue
			meta="${entry%%"$(printf '\t')"*}"
			case "$meta" in
			*" commit "*) die "$p: '$prefix' is a submodule on the target — hoist does not promote into or across submodules" ;;
			esac
		done < <(git -C "$repo" ls-tree -z "$ref" -- "$prefix" 2>/dev/null)
	done
}

# --- git -------------------------------------------------------------------

# git_h — git with hooks disabled, for hoist's own lifecycle commands
# (worktree add, checkout, add, rm, read-tree, commit, push). /dev/null is
# unpopulatable, so a gate cannot recreate a hooks directory hoist would run.
git_h() { git -c core.hooksPath=/dev/null "$@"; }

# repo_root <dir> — physical absolute path of the working tree root, or die.
repo_root() {
	local top
	top="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" ||
		die "not a git repository (or a bare one): $1"
	canon_dir "$top" || die "cannot resolve repository root: $top"
}

# git_common_dir <dir> — physical absolute path of the common git dir.
git_common_dir() {
	local d
	d="$(git -C "$1" rev-parse --git-common-dir 2>/dev/null)" || return 1
	case "$d" in
	/*) ;;
	*) d="$(canon_dir "$1")/$d" ;;
	esac
	canon_dir "$d"
}

# git_01 <git args...> — run a git command whose status 0/1 is an answer
# (diff --quiet, ls-remote --exit-code, …) and return it; any other status is
# an operational error and dies rather than being mistaken for an answer.
git_01() {
	local rc=0
	git "$@" 2>/dev/null || rc=$?
	case "$rc" in
	0 | 1) return "$rc" ;;
	*) die "git failed (exit $rc): git $*" ;;
	esac
}

# --- locks -----------------------------------------------------------------
#
# mkdir is atomic on every filesystem we care about. The state lock guards
# one hoist; the repo lock guards the repo-wide mutations prepare and cleanup
# make (exclude edit, worktree add/remove) and is held only across those.

_HOIST_REPO_LOCK=""
lock_repo() { # lock_repo <repo>
	local common
	common="$(git_common_dir "$1")" || die "cannot locate the git directory of $1"
	_HOIST_REPO_LOCK="$common/hoist.lock"
	if ! mkdir "$_HOIST_REPO_LOCK" 2>/dev/null; then
		die "another hoist command holds the repository lock ($_HOIST_REPO_LOCK, pid $(cat "$_HOIST_REPO_LOCK/pid" 2>/dev/null || echo '?')). If it is stale, remove that directory."
	fi
	printf '%s\n' "$$" >"$_HOIST_REPO_LOCK/pid"
}
unlock_repo() {
	[ -n "$_HOIST_REPO_LOCK" ] || return 0
	rm -f "$_HOIST_REPO_LOCK/pid"
	rmdir "$_HOIST_REPO_LOCK" 2>/dev/null || true
	_HOIST_REPO_LOCK=""
}

_HOIST_STATE_LOCK=""
lock_state() { # requires HOIST_TMP
	_HOIST_STATE_LOCK="$HOIST_TMP/lock"
	if ! mkdir "$_HOIST_STATE_LOCK" 2>/dev/null; then
		die "another hoist command is running on this state ($_HOIST_STATE_LOCK, pid $(cat "$_HOIST_STATE_LOCK/pid" 2>/dev/null || echo '?')). If it is stale, remove that directory."
	fi
	printf '%s\n' "$$" >"$_HOIST_STATE_LOCK/pid"
}
unlock_state() {
	[ -n "$_HOIST_STATE_LOCK" ] || return 0
	rm -f "$_HOIST_STATE_LOCK/pid"
	rmdir "$_HOIST_STATE_LOCK" 2>/dev/null || true
	_HOIST_STATE_LOCK=""
}

# --- files -----------------------------------------------------------------

# copy_state <src> <dst> — reproduce src at dst: content and symlink-ness.
# Accepts only a regular file or a symlink (a FIFO would block cat forever;
# a directory is not a file state). The exec bit is applied to the INDEX by
# restage (git update-index --chmod), so core.filemode=false cannot lose it.
copy_state() {
	local src="$1" dst="$2"
	if [ -L "$src" ]; then
		rm -f -- "$dst"
		cp -PR -- "$src" "$dst" || die "could not copy symlink $src"
		return
	fi
	[ -f "$src" ] || die "not a regular file or symlink: $src"
	rm -f -- "$dst"
	cat -- "$src" >"$dst" || die "could not copy $src"
	if [ -x "$src" ]; then chmod +x "$dst"; else chmod -x "$dst"; fi
}

# --- key=value files -------------------------------------------------------
#
# State, attestation, receipt and acknowledgement files are all strict
# key=value: one pair per line, split on the FIRST '=', no quoting, values
# may not contain newlines. Nothing is ever sourced.

# kv_set <file> <key> <value> — append one pair.
kv_set() {
	case "$3" in
	*$'\n'*) die "internal: value for $2 contains a newline" ;;
	esac
	printf '%s=%s\n' "$2" "$3" >>"$1"
}

# kv_get <file> <key> — print the value of the first matching key; fail if
# absent.
kv_get() {
	local line
	[ -f "$1" ] || return 1
	while IFS= read -r line || [ -n "$line" ]; do
		if [ "${line%%=*}" = "$2" ]; then
			printf '%s\n' "${line#*=}"
			return 0
		fi
	done <"$1"
	return 1
}

# kv_get_all <file> <key> — every value for a repeated key, one per line.
kv_get_all() {
	local line
	[ -f "$1" ] || return 0
	while IFS= read -r line || [ -n "$line" ]; do
		[ "${line%%=*}" = "$2" ] && printf '%s\n' "${line#*=}"
	done <"$1"
	return 0
}

# --- state -----------------------------------------------------------------
#
# prepare writes $HOIST_TMP/state; every later command loads it through
# state_load, which parses strictly and validates that the state describes a
# real hoist under <repo>/.hoist/<id>/ before any path in it is used. This
# prevents accidental destruction (a stale or hand-edited state file); it is
# not a defence against a same-user adversary, who could edit the repo
# directly anyway.

HOIST_STATE_KEYS="HOIST_VERSION HOIST_ID HOIST_REPO HOIST_WORKTREE HOIST_TMP HOIST_MANIFEST HOIST_MANIFEST_DIGEST HOIST_BRANCH HOIST_TARGET HOIST_REMOTE HOIST_REMOTE_URL HOIST_PUSH_URL HOIST_FETCH_EFFECTIVE HOIST_PUSH_EFFECTIVE HOIST_BASE_SHA HOIST_MERGE_BASE HOIST_FETCHED HOIST_UNRELATED"

# state_write <file> — write the state from the HOIST_* variables currently
# set. Files 0600, written whole then moved into place.
state_write() {
	local f="$1" k tmp
	tmp="$f.tmp.$$"
	(
		umask 077
		: >"$tmp"
	)
	for k in $HOIST_STATE_KEYS; do
		eval "kv_set \"\$tmp\" \"$k\" \"\${$k-}\""
	done
	mv -f -- "$tmp" "$f"
}

# state_load <file> [lenient] — parse and validate. With "lenient" (cleanup
# only) the worktree may already be gone; the layout is still enforced.
state_load() {
	local f="$1" lenient="${2:-}" line k v seen="" canon dir common wt_common
	[ -n "$f" ] || die "--state is required"
	[ ! -L "$f" ] || die "state file is a symlink — refusing: $f"
	[ -f "$f" ] || die "no state file at $f — run hoist prepare first"

	for k in $HOIST_STATE_KEYS; do unset "$k"; done
	while IFS= read -r line || [ -n "$line" ]; do
		[ -n "$line" ] || die "state file has an empty line: $f"
		case "$line" in
		*=*) ;;
		*) die "state file line is not key=value: $line" ;;
		esac
		k="${line%%=*}"
		v="${line#*=}"
		case " $HOIST_STATE_KEYS " in
		*" $k "*) ;;
		*) die "state file has an unknown key: $k" ;;
		esac
		case " $seen " in
		*" $k "*) die "state file repeats key: $k" ;;
		esac
		seen="$seen $k"
		eval "$k=\$v"
	done <"$f"
	for k in $HOIST_STATE_KEYS; do
		case " $seen " in
		*" $k "*) ;;
		*)
			# the effective-endpoint keys arrived after the first states were
			# written; an older state still parses (so cleanup can remove it)
			# and is refused below for everything but cleanup
			case "$k" in
			HOIST_FETCH_EFFECTIVE | HOIST_PUSH_EFFECTIVE) eval "$k=" ;;
			*) die "state file is missing key: $k" ;;
			esac
			;;
		esac
	done

	# --- values ---
	[ "$HOIST_VERSION" = "1" ] || die "unsupported state version: $HOIST_VERSION"
	case "$HOIST_ID" in
	[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]-[0-9]*) ;;
	*) die "state has a malformed id: $HOIST_ID" ;;
	esac
	case "$HOIST_ID" in *[!0-9-]*) die "state has a malformed id: $HOIST_ID" ;; esac
	case "$HOIST_BASE_SHA" in
	[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) [ "${#HOIST_BASE_SHA}" -eq 40 ] || [ "${#HOIST_BASE_SHA}" -eq 64 ] || die "state has a malformed base sha" ;;
	*) die "state has a malformed base sha" ;;
	esac
	case "$HOIST_MERGE_BASE" in
	'') ;;
	*[!0-9a-f]*) die "state has a malformed merge base" ;;
	*) [ "${#HOIST_MERGE_BASE}" -eq "${#HOIST_BASE_SHA}" ] || die "state has a malformed merge base" ;;
	esac
	case "$HOIST_MANIFEST_DIGEST" in
	*[!0-9a-f]*) die "state has a malformed manifest digest" ;;
	esac
	[ "${#HOIST_MANIFEST_DIGEST}" -eq "${#HOIST_BASE_SHA}" ] || die "state has a malformed manifest digest"
	! has_control "$HOIST_REMOTE_URL$HOIST_PUSH_URL$HOIST_FETCH_EFFECTIVE$HOIST_PUSH_EFFECTIVE" || die "state has control characters in remote URLs"
	[ -n "$HOIST_REMOTE_URL" ] || die "state has no remote URL"
	if [ -z "$lenient" ]; then
		[ -n "$HOIST_FETCH_EFFECTIVE" ] && [ -n "$HOIST_PUSH_EFFECTIVE" ] ||
			die "state has no effective remote endpoints (written by an older hoist?) — hoist cleanup --discard, then prepare again"
	fi
	case "$HOIST_FETCHED$HOIST_UNRELATED" in 00 | 01 | 10 | 11) ;; *) die "state has malformed flags" ;; esac
	[ -n "$HOIST_BRANCH" ] && [ -n "$HOIST_TARGET" ] && [ -n "$HOIST_REMOTE" ] || die "state has an empty branch/target/remote"
	! has_control "$HOIST_BRANCH$HOIST_TARGET$HOIST_REMOTE" || die "state has control characters in branch/target/remote"

	# --- containment ---
	for v in "$HOIST_REPO" "$HOIST_TMP" "$HOIST_WORKTREE" "$HOIST_MANIFEST"; do
		case "$v" in /*) ;; *) die "state path is not absolute: $v" ;; esac
		! has_control "$v" || die "state path contains control characters"
	done
	[ -d "$HOIST_REPO" ] && [ ! -L "$HOIST_REPO" ] || die "state repo is not a directory: $HOIST_REPO"
	canon="$(repo_root "$HOIST_REPO")"
	[ "$canon" = "$HOIST_REPO" ] || die "state repo is not a canonical repository root: $HOIST_REPO (root is $canon)"
	common="$(git_common_dir "$HOIST_REPO")" || die "cannot resolve the git directory of $HOIST_REPO"

	[ "$HOIST_TMP" = "$HOIST_REPO/.hoist/$HOIST_ID" ] ||
		die "state tmp is not <repo>/.hoist/<id>: $HOIST_TMP"
	[ "$HOIST_WORKTREE" = "$HOIST_TMP/tree" ] || die "state worktree is not <tmp>/tree: $HOIST_WORKTREE"
	[ "$HOIST_MANIFEST" = "$HOIST_TMP/manifest" ] || die "state manifest is not <tmp>/manifest: $HOIST_MANIFEST"
	for v in "$HOIST_TMP" "$HOIST_WORKTREE"; do
		case "$v" in
		/ | "${HOME:-/nonexistent}" | "$HOIST_REPO" | "$common" | "$common"/*) die "state points at a forbidden location: $v" ;;
		esac
	done
	[ ! -L "$HOIST_REPO/.hoist" ] || die "<repo>/.hoist is a symlink — refusing"
	[ -d "$HOIST_TMP" ] && [ ! -L "$HOIST_TMP" ] || die "state directory missing or a symlink: $HOIST_TMP"
	dir="$(canon_dir "$HOIST_TMP")" || die "cannot resolve $HOIST_TMP"
	[ "$dir" = "$HOIST_TMP" ] || die "state directory is not canonical: $HOIST_TMP"
	[ -f "$HOIST_TMP/.hoist-state" ] || die "state directory lacks the hoist sentinel: $HOIST_TMP"
	canon="$(canon_file "$f")" || die "cannot resolve state file path"
	[ "$canon" = "$HOIST_TMP/state" ] || die "state file must be <tmp>/state, got $canon"
	[ -f "$HOIST_MANIFEST" ] && [ ! -L "$HOIST_MANIFEST" ] || die "manifest missing or a symlink: $HOIST_MANIFEST"
	[ -n "$lenient" ] && return 0

	# the manifest is frozen at prepare: a gate (or anyone) rewriting it is
	# refused here, before any command trusts it (cleanup checks it itself,
	# and only when it needs the manifest for its loss audit)
	[ "$(manifest_digest "$HOIST_MANIFEST")" = "$HOIST_MANIFEST_DIGEST" ] ||
		die "the manifest has been modified since prepare — refusing (run hoist cleanup --discard and prepare again)"

	[ -d "$HOIST_WORKTREE" ] && [ ! -L "$HOIST_WORKTREE" ] || die "worktree missing: $HOIST_WORKTREE (run hoist cleanup)"
	git -C "$HOIST_REPO" worktree list --porcelain 2>/dev/null | grep -Fx -- "worktree $HOIST_WORKTREE" >/dev/null ||
		die "worktree is not registered with the repository: $HOIST_WORKTREE"
	wt_common="$(git_common_dir "$HOIST_WORKTREE")" || die "cannot resolve the git directory of the worktree"
	[ "$wt_common" = "$common" ] || die "worktree belongs to a different repository"
	[ "$(git -C "$HOIST_WORKTREE" symbolic-ref --quiet HEAD 2>/dev/null)" = "refs/heads/$HOIST_BRANCH" ] ||
		die "worktree does not have $HOIST_BRANCH checked out"
}

# --- index -----------------------------------------------------------------

# manifest_paths <manifest> — the allowed set, one per line (as stored).
manifest_paths() { cat -- "$1"; }

# in_manifest <manifest> <path>
in_manifest() { grep -qFx -- "$2" "$1"; }

# restage <worktree> <manifest> — rebuild the index as HEAD plus the current
# on-disk state of exactly the manifest paths, then prove it.
#
# Claude edits the copies in the worktree, gates may format them, so every
# later step re-reads disk rather than a snapshot. Starting from HEAD each
# time is what makes "hoist commits exactly the files you named" mechanical:
# whatever a gate or hook staged is dropped, and the staged set is verified
# to be a subset of the manifest before returning.
restage() {
	local wt="$1" manifest="$2" p f
	git_h -C "$wt" read-tree HEAD || die "could not reset the worktree index"
	while IFS= read -r p || [ -n "$p" ]; do
		[ -n "$p" ] || continue
		path_check_parents "$wt" "$p"
		if [ -L "$wt/$p" ]; then
			GIT_LITERAL_PATHSPECS=1 git_h -C "$wt" add -f -- "$p" || die "could not stage $p"
		elif [ -d "$wt/$p" ]; then
			die "$p is now a directory in the worktree — hoist names files"
		elif [ -e "$wt/$p" ]; then
			[ -f "$wt/$p" ] || die "$p is not a regular file in the worktree"
			GIT_LITERAL_PATHSPECS=1 git_h -C "$wt" add -f -- "$p" || die "could not stage $p"
			if [ -x "$wt/$p" ]; then
				git_h -C "$wt" update-index --chmod=+x -- "$p" || die "could not set mode on $p"
			else
				git_h -C "$wt" update-index --chmod=-x -- "$p" || die "could not set mode on $p"
			fi
		else
			GIT_LITERAL_PATHSPECS=1 git_h -C "$wt" rm -q --cached --ignore-unmatch -- "$p" || die "could not unstage $p"
		fi
	done <"$manifest"
	# (a producer's failure inside a process substitution is invisible to the
	# loop, so the list goes through a status-checked file)
	local list="$HOIST_TMP/.staged.$$"
	git -C "$wt" diff --cached --no-renames --name-only -z HEAD >"$list" || {
		rm -f -- "$list"
		die "could not list the staged paths"
	}
	while IFS= read -r -d '' f; do
		in_manifest "$manifest" "$f" || {
			rm -f -- "$list"
			die "index contains a path outside the manifest: $f"
		}
	done <"$list"
	rm -f -- "$list"
}

# staged_tree <worktree> — tree hash of the current index.
# write-tree also updates the index's cache-tree, i.e. writes the index — so
# it too runs with hooks off (post-index-change would fire otherwise; t-08
# pins it)
staged_tree() { git_h -C "$1" write-tree || die "could not write the staged tree"; }

# staged_status <worktree> — NUL-delimited "X\0path\0" pairs, index vs HEAD,
# no rename detection (so status is only A/M/D/T).
staged_status() { git -C "$1" diff --cached --no-renames --name-status -z HEAD; }

# manifest_digest <manifest>
manifest_digest() { digest_file "$1"; }

# --- attestation / receipt / acknowledgement -------------------------------
#
# Every artifact is strict key=value with a fixed schema; unknown, duplicate
# (unless repeatable) or malformed lines are refused, not ignored.

# kv_strict <file> <what> <keys> <repeatable-keys-or-prefixes> — die unless
# every line is key=value with a known key, non-repeatable keys occur once,
# and every listed key occurs at least once. Prefix keys end with '.'.
kv_strict() {
	local f="$1" what="$2" keys="$3" rep="$4" line k seen="" ok r
	[ -f "$f" ] && [ ! -L "$f" ] || die "$what missing or a symlink: $f"
	while IFS= read -r line || [ -n "$line" ]; do
		[ -n "$line" ] || die "$what has an empty line"
		case "$line" in *=*) ;; *) die "$what has a malformed line: $line" ;; esac
		k="${line%%=*}"
		ok=0
		case " $keys " in *" $k "*) ok=1 ;; esac
		for r in $rep; do
			case "$r" in
			*.) case "$k" in "$r"*) ok=2 ;; esac ;;
			*) [ "$k" = "$r" ] && ok=2 ;;
			esac
		done
		[ "$ok" -ne 0 ] || die "$what has an unknown key: $k"
		if [ "$ok" -eq 1 ]; then
			case " $seen " in *" $k "*) die "$what repeats key: $k" ;; esac
			seen="$seen $k"
		fi
	done <"$f"
	for k in $keys; do
		case " $seen " in *" $k "*) ;; *) die "$what is missing key: $k" ;; esac
	done
}

ATTEST_KEYS="version id base target branch tree manifest check.gates check.secrets check.personal check.drift gates_cmd gates_cmd_text findings findings_digest"
RECEIPT_KEYS="version id tree attest message ack"
ACK_KEYS="version id base tree attest findings"

# attest_verify <attest-file> <tree> — die unless the attestation exists,
# is well-formed, and is bound to this hoist (id, base, target, branch),
# to <tree>, and to the frozen manifest; and its finding list is consistent
# with its own count and digest.
attest_verify() {
	local f="$1" tree="$2" v n ids
	[ -f "$f" ] && [ ! -L "$f" ] || die "no attestation — run hoist scan (all four checks) first"
	kv_strict "$f" "attestation" "$ATTEST_KEYS" "finding"
	[ "$(kv_get "$f" version)" = "1" ] || die "unsupported attestation version"
	[ "$(kv_get "$f" id)" = "$HOIST_ID" ] || die "attestation belongs to a different hoist"
	[ "$(kv_get "$f" base)" = "$HOIST_BASE_SHA" ] || die "attestation is for a different base — re-run hoist prepare"
	[ "$(kv_get "$f" target)" = "$HOIST_REMOTE/$HOIST_TARGET" ] || die "attestation is for a different target — the state or the attestation was altered; re-run hoist scan"
	[ "$(kv_get "$f" branch)" = "$HOIST_BRANCH" ] || die "attestation is for a different branch — the state or the attestation was altered; re-run hoist scan"
	[ "$(kv_get "$f" manifest)" = "$HOIST_MANIFEST_DIGEST" ] || die "attestation is for a different manifest — re-run hoist scan"
	for v in gates secrets personal drift; do
		case "$(kv_get "$f" "check.$v")" in
		*:clean | *:findings) ;;
		*) die "attestation records check '$v' as not run — this attestation is not push-capable" ;;
		esac
	done
	ids="$(kv_get_all "$f" finding | sort)"
	n="$(printf '%s' "$ids" | grep -c . || true)"
	[ "$(kv_get "$f" findings)" = "$n" ] || die "attestation finding count does not match its list"
	[ "$(kv_get "$f" findings_digest)" = "$(digest_str "$ids")" ] || die "attestation findings digest does not match its list"
	v="$(kv_get "$f" tree)"
	[ "$v" = "$tree" ] ||
		die "re-run hoist scan (tree changed since last scan: attested ${v:0:9}, now ${tree:0:9})"
}

# ack_valid <ack-file> <tree> <findings-digest> <attest-digest> — true if a
# well-formed acknowledgement exists and is bound to this hoist, base, tree,
# findings set and attestation.
ack_valid() {
	local f="$1"
	[ -f "$f" ] && [ ! -L "$f" ] || return 1
	kv_strict "$f" "acknowledgement" "$ACK_KEYS" "ack." 2>/dev/null || return 1
	[ "$(kv_get "$f" version)" = "1" ] || return 1
	[ "$(kv_get "$f" id)" = "$HOIST_ID" ] || return 1
	[ "$(kv_get "$f" base)" = "$HOIST_BASE_SHA" ] || return 1
	[ "$(kv_get "$f" tree)" = "$2" ] || return 1
	[ "$(kv_get "$f" findings)" = "$3" ] || return 1
	[ "$(kv_get "$f" attest)" = "$4" ] || return 1
}

# text_looks_sensitive <text> — succeed (and print why to stderr) if the text
# carries a credential-shaped token or a personal identifier. Applied to
# titles, bodies and acknowledgement reasons before they reach a commit.
text_looks_sensitive() {
	local t="$1" why="" user host email
	if printf '%s\n' "$t" | grep -qE 'AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|https://hooks\.slack\.com/services/[A-Za-z0-9/]{20,}|eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.'; then
		why="a credential-shaped token"
	elif printf '%s\n' "$t" | grep -qE '/Users/[A-Za-z0-9._-]+|/home/[A-Za-z0-9._-]+|/(Desktop|Downloads|Documents)/'; then
		why="a home or desktop path"
	else
		user="$(id -un 2>/dev/null || true)"
		host="$(hostname -s 2>/dev/null || true)"
		email="$(git -C "${HOIST_REPO:-.}" config user.email 2>/dev/null || true)"
		if [ -n "${HOME:-}" ] && [ "$HOME" != "/" ] && printf '%s\n' "$t" | grep -qF -- "$HOME"; then
			why="your home directory"
		elif [ -n "$email" ] && printf '%s\n' "$t" | grep -qF -- "$email"; then
			why="your email address"
		elif [ -n "$user" ] && [ "$user" != root ] && printf '%s\n' "$t" | grep -qFw -- "$user"; then
			why="your username"
		elif [ -n "$host" ] && [ "$host" != localhost ] && printf '%s\n' "$t" | grep -qFw -- "$host"; then
			why="your hostname"
		fi
	fi
	[ -n "$why" ] || return 1
	printf '%s\n' "$why" >&2
	return 0
}

# --- remote URLs -----------------------------------------------------------

# scrub_urls — strip userinfo (user:token@) out of URLs in text hoist echoes
# from git, then run redact_secrets over it, so an authenticated remote never
# leaks a token into a terminal or a session log — whether the credential sits
# in the userinfo or in a ?token= query. scp-style "user@host:" carries no
# password. Every place git's stderr is shown goes through this.
scrub_urls() { sed -E 's#(://)[^/@[:space:]]*@#\1#g' | redact_secrets; }

# redact_secrets — replace credential-shaped spans (the same shapes the
# fallback scanner knows, plus token=/password= query values) with
# [redacted]. Applied to every excerpt and gate-log tail hoist prints.
redact_secrets() {
	sed -E \
		-e 's/AKIA[0-9A-Z]{16}/[redacted]/g' \
		-e 's/gh[pousr]_[A-Za-z0-9]{20,}/[redacted]/g' \
		-e 's#https://hooks\.slack\.com/services/[A-Za-z0-9/]{20,}#[redacted]#g' \
		-e 's/eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]*/[redacted]/g' \
		-e 's/-----BEGIN [A-Z ]*PRIVATE KEY-----.*/[redacted]/' \
		-e 's/([?&](token|access_token|password|secret|api_key|apikey|key)=)[^&[:space:]]*/\1[redacted]/gi'
}

# url_encode <text> — percent-encode everything but unreserved characters
# and '/', for branch names in compare/MR links.
url_encode() {
	local s="$1" i c out=""
	# bytewise: under a UTF-8 locale ${s:i:1} would yield whole characters and
	# "'$c" their code point (é → %E9); percent-encoding is defined on bytes
	# (é → %C3%A9), and git accepts such branch names
	local LC_ALL=C
	i=0
	while [ "$i" -lt "${#s}" ]; do
		c="${s:$i:1}"
		case "$c" in
		[A-Za-z0-9._~/-]) out="$out$c" ;;
		*) out="$out$(printf '%%%02X' "'$c")" ;;
		esac
		i=$((i + 1))
	done
	printf '%s' "$out"
}

# web_host_path <remote-url> — "host path" (no scheme, no userinfo, no port,
# no .git), or nothing if the URL shape is not recognised.
web_host_path() {
	local u="$1" scheme rest hostport host path
	case "$u" in
	*://*)
		scheme="${u%%://*}"
		rest="${u#*://}"
		hostport="${rest%%/*}"
		path="${rest#*/}"
		[ "$path" != "$rest" ] || path=""
		hostport="${hostport##*@}"
		host="${hostport%%:*}"
		case "$scheme" in http | https | ssh | git) ;; *) return 0 ;; esac
		;;
	*@*:* | *:*)
		# scp-like: [user@]host:path
		case "$u" in /* | ./*) return 0 ;; esac
		host="${u%%:*}"
		host="${host##*@}"
		path="${u#*:}"
		;;
	*) return 0 ;;
	esac
	# a ?query or #fragment is never part of the repository path — and it is
	# where a credential-bearing remote keeps its token, so it must not reach
	# the compare/MR link hoist prints
	path="${path%%\?*}"
	path="${path%%#*}"
	host="${host%%\?*}"
	host="${host%%#*}"
	path="${path%/}"
	path="${path%.git}"
	path="${path#/}"
	[ -n "$host" ] && [ -n "$path" ] || return 0
	printf '%s %s\n' "$host" "$path"
}

