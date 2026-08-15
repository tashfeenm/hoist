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

HOIST_STATE_KEYS="HOIST_VERSION HOIST_ID HOIST_REPO HOIST_WORKTREE HOIST_TMP HOIST_MANIFEST HOIST_BRANCH HOIST_TARGET HOIST_REMOTE HOIST_BASE_SHA HOIST_MERGE_BASE HOIST_FETCHED HOIST_UNRELATED"

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
		*) die "state file is missing key: $k" ;;
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
	*) [ "${#HOIST_MERGE_BASE}" -eq "${#HOIST_BASE_SHA}" ] || die "state has a malformed merge base" ;;
	esac
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
	while IFS= read -r -d '' f; do
		in_manifest "$manifest" "$f" || die "index contains a path outside the manifest: $f"
	done < <(git -C "$wt" diff --cached --no-renames --name-only -z HEAD)
}

# staged_tree <worktree> — tree hash of the current index.
staged_tree() { git -C "$1" write-tree || die "could not write the staged tree"; }

# staged_status <worktree> — NUL-delimited "X\0path\0" pairs, index vs HEAD,
# no rename detection (so status is only A/M/D/T).
staged_status() { git -C "$1" diff --cached --no-renames --name-status -z HEAD; }

# manifest_digest <manifest>
manifest_digest() { digest_file "$1"; }

# --- attestation / receipt / acknowledgement -------------------------------

# attest_verify <attest-file> <tree> — die unless the attestation exists and
# is bound to this hoist (id, base), to <tree>, and to the current manifest.
attest_verify() {
	local f="$1" tree="$2" v
	[ -f "$f" ] && [ ! -L "$f" ] || die "no attestation — run hoist scan (all four checks) first"
	[ "$(kv_get "$f" version || true)" = "1" ] || die "unsupported attestation version"
	v="$(kv_get "$f" id || true)"
	[ "$v" = "$HOIST_ID" ] || die "attestation belongs to a different hoist"
	v="$(kv_get "$f" base || true)"
	[ "$v" = "$HOIST_BASE_SHA" ] || die "attestation is for a different base — re-run hoist prepare"
	v="$(kv_get "$f" manifest || true)"
	[ "$v" = "$(manifest_digest "$HOIST_MANIFEST")" ] || die "attestation is for a different manifest — re-run hoist scan"
	v="$(kv_get "$f" tree || true)"
	[ "$v" = "$tree" ] ||
		die "re-run hoist scan (tree changed since last scan: attested ${v:0:9}, now ${tree:0:9})"
}

# ack_valid <ack-file> <tree> <findings-digest> — true if an acknowledgement
# file exists and is bound to this tree and findings set.
ack_valid() {
	[ -f "$1" ] && [ ! -L "$1" ] || return 1
	[ "$(kv_get "$1" version 2>/dev/null || true)" = "1" ] || return 1
	[ "$(kv_get "$1" tree 2>/dev/null || true)" = "$2" ] || return 1
	[ "$(kv_get "$1" findings 2>/dev/null || true)" = "$3" ] || return 1
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
# from git, so an authenticated remote never leaks a token into a terminal
# or a session log.
scrub_urls() { sed -E 's#(://)[^/@[:space:]]*@#\1#g'; }

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
	path="${path%/}"
	path="${path%.git}"
	path="${path#/}"
	[ -n "$host" ] && [ -n "$path" ] || return 0
	printf '%s %s\n' "$host" "$path"
}

