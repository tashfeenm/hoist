#!/usr/bin/env bash
#
# make-fixture.sh — build a throwaway repo that reproduces every case the
# promotion flow has to handle.
#
# The result:
#
#   <dest>/origin.git      a bare remote whose main branch has moved on
#   <dest>/workshop        a clone with a realistically dirty working tree
#   <dest>/.hoist-fixture  sentinel (a versioned magic value): marks <dest>
#                          as something this script made and may destroy
#
# `workshop` is what you point the skill at. Every planted case is listed in
# the README's eval table, including the decoy that must NOT be flagged.
#
# Usage:
#   fixtures/make-fixture.sh [dest]     # default: ./.fixture (gitignored)
#
# <dest> must not exist, or must contain the sentinel from a previous run;
# anything else is refused rather than deleted. Pass a NONEXISTENT path
# (e.g. "$(mktemp -d)/fixture") for a private copy.
#
# The fixture is hermetic against git CONFIG (identity, hooks, templates,
# attributes and signing are pinned here), not against the environment.
# Needs git 2.20+.
#
set -euo pipefail

HOIST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

case "${1:-}" in
-h | --help)
	awk 'NR==1 && /^#!/ {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "${BASH_SOURCE[0]}"
	exit 0
	;;
esac

DEST_ARG="${1:-$HOIST_ROOT/.fixture}"
SENTINEL_NAME=".hoist-fixture"

# --- refuse to destroy anything we did not create ------------------------------

canon_parent="$(cd -- "$(dirname -- "$DEST_ARG")" 2>/dev/null && pwd -P)" ||
	{ echo "make-fixture: parent directory does not exist: $(dirname -- "$DEST_ARG")" >&2; exit 2; }
DEST="$canon_parent/$(basename -- "$DEST_ARG")"
case "$DEST" in
/ | "${HOME:-/nonexistent}" | "$HOIST_ROOT" | "$HOIST_ROOT/.git" | "$HOIST_ROOT"/.git/*)
	echo "make-fixture: refusing to use $DEST as a fixture directory" >&2
	exit 2
	;;
esac
if [ -L "$DEST" ]; then
	echo "make-fixture: $DEST is a symlink — refusing" >&2
	exit 2
fi
if [ -e "$DEST" ]; then
	if [ ! -d "$DEST" ] || [ -L "$DEST/$SENTINEL_NAME" ] || [ ! -f "$DEST/$SENTINEL_NAME" ] ||
		[ "$(cat "$DEST/$SENTINEL_NAME" 2>/dev/null)" != "hoist-fixture-v1" ]; then
		echo "make-fixture: $DEST exists and does not carry $SENTINEL_NAME — refusing to delete it." >&2
		echo "  Pass a nonexistent path, or remove that directory yourself if it really is a stale fixture." >&2
		exit 2
	fi
	chmod -R u+w "$DEST" 2>/dev/null || true
	rm -rf -- "$DEST"
fi
mkdir -p -- "$DEST"
printf 'hoist-fixture-v1\n' >"$DEST/$SENTINEL_NAME"

ORIGIN="$DEST/origin.git"
WORKSHOP="$DEST/workshop"
SEED="$DEST/.seed"

# --- hermetic git ---------------------------------------------------------------

export GIT_AUTHOR_NAME="Fixture" GIT_AUTHOR_EMAIL="fixture@example.com"
export GIT_COMMITTER_NAME="Fixture" GIT_COMMITTER_EMAIL="fixture@example.com"
export GIT_AUTHOR_DATE="2026-01-01T00:00:00Z" GIT_COMMITTER_DATE="2026-01-01T00:00:00Z"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_WORK_TREE GIT_LITERAL_PATHSPECS 2>/dev/null || true

# every git call the fixture makes: no hooks, no signing, no attributes file
g() { git -c core.hooksPath=/dev/null -c commit.gpgsign=false -c core.attributesFile=/dev/null "$@"; }
git_seed() { g -C "$SEED" "$@"; }

commit() { # commit <message>
	git_seed add -A
	git_seed commit -q -m "$1"
	# bump the clock so commit order is unambiguous
	GIT_AUTHOR_DATE="$(printf '2026-01-01T00:%02d:00Z' "$((seq_no += 1))")"
	GIT_COMMITTER_DATE="$GIT_AUTHOR_DATE"
	export GIT_AUTHOR_DATE GIT_COMMITTER_DATE
}
seq_no=0

# Planted secrets are assembled from fragments at build time so that this
# tracked source is scanner-clean while the generated fixture is not.
AWS_ID="AKIA"'Z7QK4NP2''XW9DLM3B'
AWS_SECRET="kQ9dR2mZ7x"'Vn4TbL8jHs''3PwYcE6fA1uK5gN0iObX'
SLACK_HOOK="https://hooks.slack.com/services/"'T0AB12CD3/'"B9XY87ZW6/"'qL4mNvR8tKdY2pWsE7hGbXcZ'

# ---------------------------------------------------------------------------
# 1. Seed the upstream repo. This is the shared history everyone agrees on.
# ---------------------------------------------------------------------------

g init -q --bare --template= "$ORIGIN"
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
g init -q --template= "$SEED"
git_seed symbolic-ref HEAD refs/heads/main

mkdir -p "$SEED/src" "$SEED/t/fixtures" "$SEED/scripts" "$SEED/bin"

cat >"$SEED/Makefile" <<'EOF'
.PHONY: test lint
test:
	@t/run.sh
lint:
	@bash -n src/*.sh t/run.sh bin/widget $(wildcard scripts/*.sh)
	@echo "lint ok"
EOF

cat >"$SEED/src/parser.sh" <<'EOF'
#!/usr/bin/env bash
# Parse "key=value" configuration lines.

parse_key() {
	local line="$1"
	case "$line" in
	'' | '#'*) return 1 ;;
	esac
	printf '%s\n' "${line%%=*}"
}

parse_value() {
	local line="$1"
	printf '%s\n' "${line#*=}"
}
EOF

cat >"$SEED/src/config.sh" <<'EOF'
#!/usr/bin/env bash
# Runtime configuration defaults.

CONFIG_ROOT="${CONFIG_ROOT:-/etc/widget}"
CACHE_DIR="${CACHE_DIR:-/var/cache/widget}"
LOG_LEVEL="${LOG_LEVEL:-warn}"
EOF

cat >"$SEED/src/report.sh" <<'EOF'
#!/usr/bin/env bash
# Render a two-column report.

REPORT_WIDTH="${REPORT_WIDTH:-24}"

# Column separator, printed between the label and the value.
REPORT_SEP="${REPORT_SEP:- }"

# Header printed once above the rows, if non-empty.
REPORT_HEADER="${REPORT_HEADER:-}"

render_header() {
	[ -n "$REPORT_HEADER" ] || return 0
	printf '%s\n' "$REPORT_HEADER"
}

render_row() {
	local label="$1" value="$2"
	printf '%-*s%s%s\n' "$REPORT_WIDTH" "$label" "$REPORT_SEP" "$value"
}
EOF

cat >"$SEED/src/legacy.sh" <<'EOF'
#!/usr/bin/env bash
# Deprecated: superseded by parse_key/parse_value in parser.sh.

legacy_split() {
	echo "$1" | tr '=' ' '
}
EOF

# A tiny CLI whose MODE will change upstream after the clone (mode-only drift).
cat >"$SEED/bin/widget" <<'EOF'
#!/usr/bin/env bash
# widget — print the widget version.
echo "widget 1.0"
EOF
chmod 644 "$SEED/bin/widget"

# Test data containing a well-known DOCUMENTATION example key. This is the
# decoy: a scanner that flags it is too noisy to trust.
cat >"$SEED/t/fixtures/keys.txt" <<'EOF'
# Sample credentials used by the parser tests. These are the public example
# values from the AWS documentation, not real credentials.
aws_access_key_id=AKIAIOSFODNN7EXAMPLE
aws_secret_access_key=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
EOF

cat >"$SEED/t/run.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

. src/parser.sh
. src/report.sh
. src/legacy.sh

fail=0
check() { # check <name> <expected> <actual>
	if [ "$2" = "$3" ]; then
		printf 'ok   %s\n' "$1"
	else
		printf 'FAIL %s: expected %q, got %q\n' "$1" "$2" "$3"
		fail=1
	fi
}

check "parse_key"        "host"    "$(parse_key 'host=example.com')"
check "parse_value"      "example.com" "$(parse_value 'host=example.com')"
check "legacy_split"     "host example.com" "$(legacy_split 'host=example.com')"
check "render_row width" "label                    value" "$(render_row label value)"

exit "$fail"
EOF

chmod +x "$SEED/t/run.sh"
commit "initial widget"
git_seed remote add origin "$ORIGIN"
git_seed push -q origin main

# ---------------------------------------------------------------------------
# 2. Clone the workshop. This is the developer's dirty repo.
# ---------------------------------------------------------------------------

g clone -q --template= "$ORIGIN" "$WORKSHOP"

# ---------------------------------------------------------------------------
# 3. Upstream moves on AFTER the clone — this is the drift case. A teammate
#    hardened parse_key against unset input. Promoting our parser.sh state
#    verbatim would silently revert this. Separately, bin/widget was made
#    executable upstream — a mode-only change that a content-only drift check
#    would miss.
# ---------------------------------------------------------------------------

cat >"$SEED/src/parser.sh" <<'EOF'
#!/usr/bin/env bash
# Parse "key=value" configuration lines.

parse_key() {
	local line="${1-}"
	case "$line" in
	'' | '#'*) return 1 ;;
	esac
	printf '%s\n' "${line%%=*}"
}

parse_value() {
	local line="${1-}"
	printf '%s\n' "${line#*=}"
}
EOF
commit "harden parser against unset input"

chmod 755 "$SEED/bin/widget"
commit "make bin/widget executable"
git_seed push -q origin main

# ---------------------------------------------------------------------------
# 4. Dirty up the workshop. Everything below is uncommitted working state —
#    the skill promotes file STATES, so none of this is ever committed here.
# ---------------------------------------------------------------------------

# (a) SHAREABLE FIX, tracked+modified. Keys were not trimmed, so " host = x"
#     parsed as " host ". Genuine bug, genuinely worth upstreaming.
#     Note this file ALSO changed upstream in step 3 → drift.
cat >"$WORKSHOP/src/parser.sh" <<'EOF'
#!/usr/bin/env bash
# Parse "key=value" configuration lines.

parse_key() {
	local line="$1"
	case "$line" in
	'' | '#'*) return 1 ;;
	esac
	local key="${line%%=*}"
	# Trim surrounding whitespace: " host = x" should yield "host".
	key="${key#"${key%%[![:space:]]*}"}"
	key="${key%"${key##*[![:space:]]}"}"
	printf '%s\n' "$key"
}

parse_value() {
	local line="$1"
	printf '%s\n' "${line#*=}"
}
EOF

# (b) PURELY PERSONAL, tracked+modified. Machine-specific paths and a debug
#     level nobody else wants. Never listed for promotion — the skill takes
#     only what you name, and this file proves it. (The persona is "pat", a
#     fictional developer: nothing here is anyone's real path.)
cat >"$WORKSHOP/src/config.sh" <<'EOF'
#!/usr/bin/env bash
# Runtime configuration defaults.

CONFIG_ROOT="${CONFIG_ROOT:-/Users/pat/Projects/widget/etc}"
CACHE_DIR="${CACHE_DIR:-/Users/pat/.cache/widget}"
LOG_LEVEL="${LOG_LEVEL:-trace}"
EOF

# (c) MIXED HUNKS, tracked+modified. One file, two intentions: a personal
#     output path near the top, and a real alignment fix further down, with
#     enough unchanged lines between them that they are two separate hunks.
#     The personal hunk must be stripped from the clean copy before commit.
cat >"$WORKSHOP/src/report.sh" <<'EOF'
#!/usr/bin/env bash
# Render a two-column report.

REPORT_WIDTH="${REPORT_WIDTH:-24}"
REPORT_OUT="${REPORT_OUT:-/Users/pat/Desktop/widget-report.txt}"

# Column separator, printed between the label and the value.
REPORT_SEP="${REPORT_SEP:- }"

# Header printed once above the rows, if non-empty.
REPORT_HEADER="${REPORT_HEADER:-}"

render_header() {
	[ -n "$REPORT_HEADER" ] || return 0
	printf '%s\n' "$REPORT_HEADER"
}

render_row() {
	local label="$1" value="$2"
	echo "[debug] render_row $label" >&2
	# Pad to at least the label width so long labels do not eat the column.
	local width="$REPORT_WIDTH"
	if [ "${#label}" -gt "$width" ]; then
		width="${#label}"
	fi
	printf '%-*s%s%s\n' "$width" "$label" "$REPORT_SEP" "$value"
}
EOF

# (d) DELETION. legacy_split is superseded; the developer removed it.
rm "$WORKSHOP/src/legacy.sh"

# (e) The corresponding test update. If this file is left out of the
#     promotion list, the clean worktree still sources src/legacy.sh and the
#     repo's own gates catch the dangling reference.
cat >"$WORKSHOP/t/run.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

. src/parser.sh
. src/report.sh

fail=0
check() { # check <name> <expected> <actual>
	if [ "$2" = "$3" ]; then
		printf 'ok   %s\n' "$1"
	else
		printf 'FAIL %s: expected %q, got %q\n' "$1" "$2" "$3"
		fail=1
	fi
}

check "parse_key"          "host"        "$(parse_key 'host=example.com')"
check "parse_key trims"    "host"        "$(parse_key ' host = example.com')"
check "parse_value"        "example.com" "$(parse_value 'host=example.com')"
check "render_row width"   "label                    value" "$(render_row label value 2>/dev/null)"
check "render_row long"    "a-label-longer-than-the-column value" \
	"$(render_row a-label-longer-than-the-column value 2>/dev/null)"

exit "$fail"
EOF
chmod +x "$WORKSHOP/t/run.sh"

# (f) UNTRACKED hook, executable, carrying PLANTED SECRETS. Exactly the shape
#     of thing that lives untracked in a dirty repo for months and is genuinely
#     worth sharing — once the tokens are out of it. It handles filenames
#     properly (NUL-delimited, `--`), so the shareable version is a good hook.
mkdir -p "$WORKSHOP/scripts"
cat >"$WORKSHOP/scripts/pre-commit.sh" <<EOF
#!/usr/bin/env bash
# Pre-commit hook: refuse to commit a file containing a merge conflict marker.
set -euo pipefail

AWS_ACCESS_KEY_ID=$AWS_ID
AWS_SECRET_ACCESS_KEY=$AWS_SECRET
NOTIFY_HOOK=$SLACK_HOOK

git diff --cached --name-only -z --diff-filter=ACM | while IFS= read -r -d '' f; do
	if grep -qE -- '^(<<<<<<<|>>>>>>>) ' "\$f"; then
		echo "conflict marker in \$f" >&2
		exit 1
	fi
done

curl -sf -X POST -d '{"text":"commit ok"}' "\$NOTIFY_HOOK" >/dev/null || true
EOF
chmod +x "$WORKSHOP/scripts/pre-commit.sh"

# (g) MODE-ONLY DRIFT. bin/widget was made executable upstream after the clone;
#     the workshop edits its content and still has it as 644. Hoisting the
#     content with the old mode would silently revert the upstream chmod.
cat >"$WORKSHOP/bin/widget" <<'EOF'
#!/usr/bin/env bash
# widget — print the widget version.
echo "widget 1.1"
EOF
chmod 644 "$WORKSHOP/bin/widget"

# (h) DECOY IN THE FLOW. A benign local edit to the decoy file, so that it is
#     modified, gets listed, and is actually scanned — and must stay clean.
cat >>"$WORKSHOP/t/fixtures/keys.txt" <<'EOF'
# (these are the AWS docs' published placeholders; safe to keep in tests)
EOF

# (i) UNTRACKED scratch. Noise that should never be promoted.
mkdir -p "$WORKSHOP/notes"
cat >"$WORKSHOP/notes/scratch.md" <<'EOF'
# scratch

- try trimming keys in parse_key -- DONE, works
- ask about the report width thing
- TODO: stop hardcoding my desktop path before anyone sees this
EOF

cat >"$WORKSHOP/CLAUDE.local.md" <<'EOF'
# Local overrides

Always run `make test` before claiming anything works.
My widget checkout lives at /Users/pat/Projects/widget.
EOF

# (j) LOCAL HOOKS in the workshop's .git/hooks — the "personal local hooks"
#     from the problem statement. Linked worktrees share them, so if hoist did
#     not disable hooks for its own commands, these would fire: pre-commit and
#     pre-push refuse loudly, post-checkout leaves a marker file.
mkdir -p "$WORKSHOP/.git/hooks"
for h in pre-commit pre-push; do
	cat >"$WORKSHOP/.git/hooks/$h" <<EOF
#!/bin/sh
echo "workshop $h hook fired — hoist must not run repo hooks" >&2
exit 1
EOF
	chmod +x "$WORKSHOP/.git/hooks/$h"
done
cat >"$WORKSHOP/.git/hooks/post-checkout" <<EOF
#!/bin/sh
: >"$WORKSHOP/.git/hoist-fixture-hook-fired"
exit 0
EOF
chmod +x "$WORKSHOP/.git/hooks/post-checkout"

# ---------------------------------------------------------------------------
# 5. Assert what we built, drop the seed, report.
# ---------------------------------------------------------------------------

rm -rf -- "$SEED"

n="$(git -C "$ORIGIN" rev-list --count main)"
[ "$n" -eq 3 ] || { echo "make-fixture: expected 3 commits on origin/main, got $n" >&2; exit 2; }
n="$(git -C "$WORKSHOP" rev-list --count HEAD)"
[ "$n" -eq 1 ] || { echo "make-fixture: expected the workshop to be 1 commit behind, got $n" >&2; exit 2; }
m="$(git -C "$ORIGIN" ls-tree main bin/widget | cut -c1-6)"
[ "$m" = "100755" ] || { echo "make-fixture: expected bin/widget 100755 upstream, got $m" >&2; exit 2; }
m="$(git -C "$WORKSHOP" ls-tree HEAD bin/widget | cut -c1-6)"
[ "$m" = "100644" ] || { echo "make-fixture: expected bin/widget 100644 at the clone, got $m" >&2; exit 2; }
[ -x "$WORKSHOP/t/run.sh" ] || { echo "make-fixture: t/run.sh should be executable" >&2; exit 2; }
[ ! -x "$WORKSHOP/bin/widget" ] || { echo "make-fixture: bin/widget should be 644 in the workshop" >&2; exit 2; }
grep -q "$AWS_ID" "$WORKSHOP/scripts/pre-commit.sh" || { echo "make-fixture: planted secret missing" >&2; exit 2; }

cat <<EOF

fixture built

  remote    $ORIGIN        (main is 2 commits ahead of the clone)
  workshop  $WORKSHOP      (dirty working tree, nothing committed)

planted cases
  src/parser.sh          shareable fix   + UPSTREAM DRIFT (also changed on main)
  src/report.sh          MIXED hunks     (alignment fix + personal path/debug, two hunks)
  src/config.sh          personal only   (must not leak — never list it)
  src/legacy.sh          DELETED         (dangling ref if t/run.sh is omitted)
  t/run.sh               test update     (pairs with the deletion)
  scripts/pre-commit.sh  UNTRACKED, exec bit, PLANTED SECRETS (must flag)
  bin/widget             MODE-ONLY DRIFT (upstream chmod +x; workshop edits content at 644)
  t/fixtures/keys.txt    DECOY, modified — AWS doc example key (must NOT flag)
  .git/hooks/*           local pre-commit/pre-push/post-checkout hooks (must NOT fire)
  notes/scratch.md, CLAUDE.local.md   untracked noise

try it
  cd $WORKSHOP && git status --short

EOF
