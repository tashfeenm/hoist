#!/usr/bin/env bash
#
# make-fixture.sh — build a throwaway repo that reproduces every case the
# promotion flow has to handle.
#
# The result is two directories:
#
#   <dest>/origin.git   a bare remote, whose main branch has moved on
#   <dest>/workshop     a clone with a realistically dirty working tree
#
# `workshop` is what you point the skill at. Every planted case is listed in
# the README's eval table, including the decoy that must NOT be flagged.
#
# Usage:
#   fixtures/make-fixture.sh [dest]     # default: ./.fixture (gitignored)
#
set -euo pipefail

DEST="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.fixture}"

case "${1:-}" in
-h | --help)
	sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
	exit 0
	;;
esac

ORIGIN="$DEST/origin.git"
WORKSHOP="$DEST/workshop"
SEED="$DEST/.seed"

rm -rf "$DEST"
mkdir -p "$DEST"

# Keep the fixture hermetic: no user identity, no signing, no local hooks.
git_seed() { git -C "$SEED" "$@"; }
git_shop() { git -C "$WORKSHOP" "$@"; }

commit() { # commit <repo-fn> <message>
	local fn="$1" msg="$2"
	"$fn" add -A
	"$fn" -c user.name=Fixture -c user.email=fixture@example.com \
		-c commit.gpgsign=false commit -q -m "$msg"
}

# ---------------------------------------------------------------------------
# 1. Seed the upstream repo. This is the shared history everyone agrees on.
# ---------------------------------------------------------------------------

git init -q --bare --initial-branch=main "$ORIGIN"
git init -q --initial-branch=main "$SEED"

mkdir -p "$SEED/src" "$SEED/t/fixtures" "$SEED/scripts"

cat >"$SEED/Makefile" <<'EOF'
.PHONY: test lint
test:
	@t/run.sh
lint:
	@bash -n src/*.sh t/run.sh $(wildcard scripts/*.sh)
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

render_row() {
	local label="$1" value="$2"
	printf '%-*s %s\n' "$REPORT_WIDTH" "$label" "$value"
}
EOF

cat >"$SEED/src/legacy.sh" <<'EOF'
#!/usr/bin/env bash
# Deprecated: superseded by parse_key/parse_value in parser.sh.

legacy_split() {
	echo "$1" | tr '=' ' '
}
EOF

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
commit git_seed "initial widget"
git_seed remote add origin "$ORIGIN"
git_seed push -q origin main

# ---------------------------------------------------------------------------
# 2. Clone the workshop. This is the developer's dirty repo.
# ---------------------------------------------------------------------------

git clone -q "$ORIGIN" "$WORKSHOP"

# ---------------------------------------------------------------------------
# 3. Upstream moves on AFTER the clone — this is the drift case. A teammate
#    hardened parse_key against unset input. Promoting our parser.sh state
#    verbatim would silently revert this.
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

commit git_seed "harden parser against unset input"
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
#     only what you name, and this file proves it.
cat >"$WORKSHOP/src/config.sh" <<'EOF'
#!/usr/bin/env bash
# Runtime configuration defaults.

CONFIG_ROOT="${CONFIG_ROOT:-/Users/tashfeen/Projects/widget/etc}"
CACHE_DIR="${CACHE_DIR:-/Users/tashfeen/.cache/widget}"
LOG_LEVEL="${LOG_LEVEL:-trace}"
EOF

# (c) MIXED HUNKS, tracked+modified. One file, two intentions: a real
#     alignment fix, plus a personal output path and a debug echo. The
#     personal hunks must be stripped from the clean copy before commit.
cat >"$WORKSHOP/src/report.sh" <<'EOF'
#!/usr/bin/env bash
# Render a two-column report.

REPORT_WIDTH="${REPORT_WIDTH:-24}"
REPORT_OUT="${REPORT_OUT:-/Users/tashfeen/Desktop/widget-report.txt}"

render_row() {
	local label="$1" value="$2"
	echo "[debug] render_row $label" >&2
	# Pad to at least the label width so long labels do not eat the column.
	local width="$REPORT_WIDTH"
	if [ "${#label}" -gt "$width" ]; then
		width="${#label}"
	fi
	printf '%-*s %s\n' "$width" "$label" "$value"
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

# (f) UNTRACKED hook, executable, carrying a PLANTED SECRET. Exactly the
#     shape of thing that lives untracked in a dirty repo for months and is
#     genuinely worth sharing — once the token is out of it.
mkdir -p "$WORKSHOP/scripts"
cat >"$WORKSHOP/scripts/pre-commit.sh" <<'EOF'
#!/usr/bin/env bash
# Pre-commit hook: refuse to commit a file containing a merge conflict marker.
set -euo pipefail

AWS_ACCESS_KEY_ID=AKIA_PLANTED_ID_REDACTED
AWS_SECRET_ACCESS_KEY=PLANTED_SECRET_REDACTED
NOTIFY_HOOK=https://hooks.slack.invalid/PLANTED_HOOK_REDACTED

staged=$(git diff --cached --name-only --diff-filter=ACM)
for f in $staged; do
	if grep -qE '^(<<<<<<<|>>>>>>>) ' "$f"; then
		echo "conflict marker in $f" >&2
		exit 1
	fi
done

curl -sf -X POST -d '{"text":"commit ok"}' "$NOTIFY_HOOK" >/dev/null || true
EOF
chmod +x "$WORKSHOP/scripts/pre-commit.sh"

# (g) UNTRACKED scratch. Noise that should never be promoted.
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
My widget checkout lives at /Users/tashfeen/Projects/widget.
EOF

# ---------------------------------------------------------------------------
# 5. Report what was built.
# ---------------------------------------------------------------------------

cat <<EOF

fixture built

  remote    $ORIGIN        (main is 1 commit ahead of the clone)
  workshop  $WORKSHOP      (dirty working tree, nothing committed)

planted cases
  src/parser.sh       shareable fix   + UPSTREAM DRIFT (also changed on main)
  src/report.sh       MIXED hunks     (alignment fix + personal path/debug)
  src/config.sh       personal only   (must not leak — never list it)
  src/legacy.sh       DELETED         (dangling ref if t/run.sh is omitted)
  t/run.sh            test update     (pairs with the deletion)
  scripts/pre-commit.sh  UNTRACKED, exec bit, PLANTED SECRET (must flag)
  t/fixtures/keys.txt    DECOY — AWS doc example key (must NOT flag)
  notes/scratch.md, CLAUDE.local.md   untracked noise

try it
  cd $WORKSHOP && git status --short

EOF
