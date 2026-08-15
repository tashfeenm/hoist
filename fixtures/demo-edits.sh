#!/usr/bin/env bash
#
# demo-edits.sh — the edits Claude makes during a real hoist, scripted.
#
# In actual use there is nothing to script here: Claude reads the diff and
# edits the copies in the clean worktree itself. This file exists so the demo
# recording and the test suite are reproducible, and so you can see exactly
# what "the judgment layer" concretely does to the fixture:
#
#   src/parser.sh          merge upstream's hardening with the local trim fix,
#                          instead of reverting it
#   src/report.sh          strip the personal output path and the debug echo,
#                          keep the column-alignment fix
#   scripts/pre-commit.sh  take the three planted credentials out; keep the
#                          notification (NOTIFY_HOOK from the environment) and
#                          the NUL-safe file loop
#   bin/widget             chmod 755, matching upstream's mode-only change
#
# Usage: demo-edits.sh --state FILE
#
# Refuses anything but a hoist state that points at THIS fixture (sentinel
# next to the workshop, root commit "initial widget"), and only rewrites
# regular files.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/hoist-lib.sh
. "$HERE/../scripts/hoist-lib.sh"

STATE=""
while [ $# -gt 0 ]; do
	case "$1" in
	--state)
		STATE="${2:?--state needs a file}"
		shift 2
		;;
	-h | --help)
		print_help "${BASH_SOURCE[0]}"
		exit 0
		;;
	*) die "usage: demo-edits.sh --state FILE" ;;
	esac
done
[ -n "$STATE" ] || die "usage: demo-edits.sh --state FILE"

state_load "$STATE"
WT="$HOIST_WORKTREE"

# Only the fixture: sentinel beside the workshop, and the known root commit.
[ -f "$(dirname -- "$HOIST_REPO")/.hoist-fixture" ] ||
	die "this state does not point at a make-fixture.sh fixture (no .hoist-fixture sentinel beside the repo) — refusing"
root_subject="$(git -C "$HOIST_REPO" log --max-parents=0 --format=%s HEAD 2>/dev/null | tail -1)"
[ "$root_subject" = "initial widget" ] ||
	die "this repo's root commit is '$root_subject', not the fixture's — refusing"

tmp="$(mktemp "$HOIST_TMP/demo-edit.XXXXXX")"
trap 'rm -f -- "$tmp"' EXIT

# put <path> — replace a regular file in the worktree with stdin, keeping its
# mode; refuse anything that is not a plain file.
put() {
	local f="$WT/$1"
	[ -f "$f" ] && [ ! -L "$f" ] || die "not a regular file in the worktree: $1"
	cat >"$tmp"
	cat -- "$tmp" >"$f"
}

# Upstream hardened both functions against unset input; the local change trims
# whitespace around keys. Both survive.
put src/parser.sh <<'EOF'
#!/usr/bin/env bash
# Parse "key=value" configuration lines.

parse_key() {
	local line="${1-}"
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
	local line="${1-}"
	printf '%s\n' "${line#*=}"
}
EOF

# The alignment fix is worth sharing. The Desktop path and the debug echo
# are not.
put src/report.sh <<'EOF'
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
	# Pad to at least the label width so long labels do not eat the column.
	local width="$REPORT_WIDTH"
	if [ "${#label}" -gt "$width" ]; then
		width="${#label}"
	fi
	printf '%-*s%s%s\n' "$width" "$label" "$REPORT_SEP" "$value"
}
EOF

# Credentials come out of the file — not out of the PR description — and the
# notification stays, driven by the environment.
put scripts/pre-commit.sh <<'EOF'
#!/usr/bin/env bash
# Pre-commit hook: refuse to commit a file containing a merge conflict marker.
set -euo pipefail

# Set NOTIFY_HOOK in the environment to enable commit notifications.
NOTIFY_HOOK="${NOTIFY_HOOK:-}"

git diff --cached --name-only -z --diff-filter=ACM | while IFS= read -r -d '' f; do
	if grep -qE -- '^(<<<<<<<|>>>>>>>) ' "$f"; then
		echo "conflict marker in $f" >&2
		exit 1
	fi
done

[ -n "$NOTIFY_HOOK" ] && curl -sf -X POST -d '{"text":"commit ok"}' "$NOTIFY_HOOK" >/dev/null || true
EOF
chmod +x "$WT/scripts/pre-commit.sh"

# Upstream made bin/widget executable; carry that along with the content edit.
[ -f "$WT/bin/widget" ] && [ ! -L "$WT/bin/widget" ] || die "bin/widget is not a regular file in the worktree"
chmod 755 "$WT/bin/widget"

echo "applied the edits a real hoist would make by hand"
