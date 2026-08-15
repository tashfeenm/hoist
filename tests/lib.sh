#!/usr/bin/env bash
#
# tests/lib.sh — assertion helpers for hoist's regression suite.
#
# Sourced by every tests/t-*.sh. Portable to macOS /bin/bash 3.2 and Linux:
# no mapfile, no ${var,,}, no associative arrays, no GNU-only flags.
#
# Each test builds its own fixture at a NONEXISTENT child of a fresh temp
# directory (make-fixture.sh refuses to reuse a directory it did not create):
#
#   fixture_new            # sets FIX, WORKSHOP, ORIGIN; cd is never changed
#
# and drives hoist through the dispatcher:
#
#   hoist prepare --repo "$WORKSHOP" --target main -- src/parser.sh
#
# Assertions record pass/fail; the file's exit status is 1 if anything failed.
#
set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$TESTS_DIR/.." && pwd -P)"
HOIST_BIN="$ROOT/scripts/hoist"

# Hermetic git: fixed identity, no user/system config, no templates.
export GIT_AUTHOR_NAME="Hoist Test" GIT_AUTHOR_EMAIL="test@example.invalid"
export GIT_COMMITTER_NAME="Hoist Test" GIT_COMMITTER_EMAIL="test@example.invalid"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export NO_COLOR=1
unset GIT_DIR GIT_WORK_TREE GIT_LITERAL_PATHSPECS 2>/dev/null || true

T_PASS=0 T_FAIL=0 T_NAME="${T_NAME:-$(basename "${0:-test}" .sh)}"
T_TMPS=""

_t_cleanup() {
	local d
	for d in $T_TMPS; do
		[ -d "$d" ] && chmod -R u+w "$d" 2>/dev/null && rm -rf "$d"
	done
	return 0
}
trap _t_cleanup EXIT

# tmpdir — a fresh temp directory, removed at exit.
tmpdir() {
	local d
	d="$(mktemp -d "${TMPDIR:-/tmp}/hoist-test.XXXXXX")" || {
		echo "mktemp failed" >&2
		exit 2
	}
	d="$(cd "$d" && pwd -P)"
	T_TMPS="$T_TMPS $d"
	printf '%s\n' "$d"
}

# fixture_new — build a fresh fixture; sets FIX, WORKSHOP, ORIGIN.
# shellcheck disable=SC2034  # consumed by the sourcing test
fixture_new() {
	local parent
	parent="$(tmpdir)"
	FIX="$parent/fixture"
	"$ROOT/fixtures/make-fixture.sh" "$FIX" >/dev/null 2>"$parent/make-fixture.err" || {
		echo "make-fixture.sh failed:" >&2
		cat "$parent/make-fixture.err" >&2
		exit 2
	}
	WORKSHOP="$FIX/workshop"
	ORIGIN="$FIX/origin.git"
}

# hoist <cmd> [args] — the dispatcher under test; stderr goes to $HOIST_ERR.
# Never dies: the exit status is returned for assertions.
HOIST_ERR=""
HOIST_OUT=""
hoist() {
	local errf outf rc=0
	errf="$(mktemp "${TMPDIR:-/tmp}/hoist-err.XXXXXX")"
	outf="$(mktemp "${TMPDIR:-/tmp}/hoist-out.XXXXXX")"
	"$HOIST_BIN" "$@" >"$outf" 2>"$errf" || rc=$?
	HOIST_OUT="$(cat "$outf")"
	HOIST_ERR="$(cat "$errf")"
	rm -f "$outf" "$errf"
	return "$rc"
}

# --- assertions -------------------------------------------------------------

_ok() {
	T_PASS=$((T_PASS + 1))
	printf 'ok %d - %s\n' $((T_PASS + T_FAIL)) "$1"
}
_fail() {
	T_FAIL=$((T_FAIL + 1))
	printf 'not ok %d - %s\n' $((T_PASS + T_FAIL)) "$1"
	shift
	local line
	for line in "$@"; do printf '#   %s\n' "$line"; done
}

# assert_eq <expected> <actual> <name>
assert_eq() {
	if [ "$1" = "$2" ]; then _ok "$3"; else _fail "$3" "expected: $1" "actual:   $2"; fi
}
# assert_ne <unexpected> <actual> <name>
assert_ne() {
	if [ "$1" != "$2" ]; then _ok "$3"; else _fail "$3" "did not expect: $1"; fi
}
# assert_status <expected> <actual> <name> — exit statuses; on failure show
# the captured stderr so a red test explains itself.
assert_status() {
	if [ "$1" = "$2" ]; then
		_ok "$3"
	else
		_fail "$3" "expected exit $1, got $2" "--- stderr ---" "$(printf '%s\n' "$HOIST_ERR" | tail -15)"
	fi
}
# assert_true <name> <cmd...>
assert_true() {
	local name="$1"
	shift
	if "$@"; then _ok "$name"; else _fail "$name" "command failed: $*"; fi
}
# assert_false <name> <cmd...>
assert_false() {
	local name="$1"
	shift
	if "$@"; then _fail "$name" "command unexpectedly succeeded: $*"; else _ok "$name"; fi
}
# assert_grep <pattern> <text> <name> — extended regex, any line.
assert_grep() {
	if printf '%s\n' "$2" | grep -qE -- "$1"; then
		_ok "$3"
	else
		_fail "$3" "pattern not found: $1" "--- text ---" "$(printf '%s\n' "$2" | tail -15)"
	fi
}
# assert_not_grep <pattern> <text> <name>
assert_not_grep() {
	if printf '%s\n' "$2" | grep -qE -- "$1"; then
		_fail "$3" "pattern unexpectedly found: $1" "$(printf '%s\n' "$2" | grep -E -- "$1" | head -5)"
	else
		_ok "$3"
	fi
}
# assert_file <path> <name> / assert_no_file <path> <name>
assert_file() { if [ -e "$1" ] || [ -L "$1" ]; then _ok "$2"; else _fail "$2" "missing: $1"; fi; }
assert_no_file() { if [ -e "$1" ] || [ -L "$1" ]; then _fail "$2" "exists: $1"; else _ok "$2"; fi; }

# --- helpers used by several suites ------------------------------------------

# state_path — the state file printed by the last `hoist prepare` (stdout).
state_path() { printf '%s\n' "$HOIST_OUT" | tail -1; }

# state_get <state-file> <KEY> — value of a key from a hoist state file.
state_get() {
	local line
	while IFS= read -r line; do
		[ "${line%%=*}" = "$2" ] && {
			printf '%s\n' "${line#*=}"
			return 0
		}
	done <"$1"
	return 1
}

# repo_snapshot <repo> <outdir> — porcelain status + raw index bytes, for the
# "workshop untouched" invariant. Status runs first so any stat refresh it
# performs is already reflected in the index copy.
repo_snapshot() {
	mkdir -p "$2"
	git -C "$1" status --porcelain --untracked=all >"$2/status"
	git -C "$1" status --porcelain --untracked=all >"$2/status"
	cp "$1/.git/index" "$2/index"
	git -C "$1" rev-parse HEAD >"$2/head"
}
# snapshot_same <dirA> <dirB> — true if two snapshots are byte-identical.
snapshot_same() {
	cmp -s "$1/status" "$2/status" && cmp -s "$1/index" "$2/index" && cmp -s "$1/head" "$2/head"
}

# origin_branch_exists <origin.git> <branch>
origin_branch_exists() { git -C "$1" rev-parse --verify -q "refs/heads/$2" >/dev/null 2>&1; }

# done_testing — print the summary line; exit 1 if anything failed.
done_testing() {
	printf '1..%d\n' $((T_PASS + T_FAIL))
	printf '# %s: %d passed, %d failed\n' "$T_NAME" "$T_PASS" "$T_FAIL"
	[ "$T_FAIL" -eq 0 ]
}
