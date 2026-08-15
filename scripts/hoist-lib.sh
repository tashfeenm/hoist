#!/usr/bin/env bash
#
# hoist-lib.sh — helpers shared by the hoist scripts.
#
# Sourced, never executed. Nothing here needs anything beyond git and bash.

# shellcheck disable=SC2034  # colour vars are consumed by the sourcing scripts

# --- output ----------------------------------------------------------------
#
# Everything humans read goes to stderr, so stdout stays usable for data
# (manifests, paths) that a caller may want to capture.

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

# --- files -----------------------------------------------------------------

# file_is_exec <path> — true if the file carries an exec bit.
file_is_exec() { [ -x "$1" ]; }

# reject_bad_path <path> — refuse anything that could escape the repo or
# rewrite git's own state. Called on every user-supplied path.
reject_bad_path() {
	local p="$1"
	case "$p" in
	/*) die "path must be relative to the repo root: $p" ;;
	../* | */../* | */..) die "path escapes the repo: $p" ;;
	.git | .git/*) die "refusing to hoist git internals: $p" ;;
	'') die "empty path in file list" ;;
	esac
}

# copy_state <src> <dst> — reproduce src at dst: content, exec bit, symlinks.
# Creates parent directories. The destination is overwritten.
copy_state() {
	local src="$1" dst="$2"
	mkdir -p "$(dirname "$dst")"
	rm -f "$dst"
	if [ -L "$src" ]; then
		ln -s "$(readlink "$src")" "$dst"
		return
	fi
	cat "$src" >"$dst"
	if file_is_exec "$src"; then chmod +x "$dst"; else chmod -x "$dst"; fi
}

# --- state -----------------------------------------------------------------
#
# prepare writes a state file; scan and finish read it. Values are shell-quoted
# on write, so the file is safe to source.

state_set() { # state_set <file> <key> <value>
	printf '%s=%q\n' "$2" "$3" >>"$1"
}

state_load() { # state_load <file>
	[ -f "$1" ] || die "no state file at $1 — run hoist-prepare.sh first"
	# shellcheck disable=SC1090
	. "$1"
}

# --- git -------------------------------------------------------------------

# repo_root <dir> — absolute path to the working tree root, or die.
repo_root() {
	git -C "$1" rev-parse --show-toplevel 2>/dev/null ||
		die "not a git repository: $1"
}

# restage <worktree> <manifest> — bring the index in line with what is on
# disk in the worktree right now, for the named files only.
#
# Claude edits the copies in the worktree (stripping personal hunks, merging
# an upstream change), so every later step has to re-read that state rather
# than the snapshot prepare took. Staging is scoped to the manifest on
# purpose: hoist commits exactly the files you named and nothing else.
restage() {
	local wt="$1" manifest="$2" path
	while IFS=$'\t' read -r _ path; do
		[ -n "$path" ] || continue
		if [ -e "$wt/$path" ] || [ -L "$wt/$path" ]; then
			git -C "$wt" add -f -- "$path"
		else
			git -C "$wt" rm -q --ignore-unmatch -- "$path"
		fi
	done <"$manifest"
}

# slugify <text> — a branch-name-safe fragment.
slugify() {
	printf '%s' "$1" | tr '[:upper:]' '[:lower:]' |
		sed -e 's/[^a-z0-9]\{1,\}/-/g' -e 's/^-//' -e 's/-$//' | cut -c1-40
}
