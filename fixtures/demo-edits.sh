#!/usr/bin/env bash
#
# demo-edits.sh — the edits Claude makes during a real hoist, scripted.
#
# In actual use there is nothing to script here: Claude reads the diff and
# edits the copies in the clean worktree itself. This file exists so the demo
# recording and the smoke test are reproducible, and so you can see exactly
# what "the judgment layer" concretely does to the fixture:
#
#   src/parser.sh          merge upstream's hardening with the local trim fix,
#                          instead of reverting it
#   src/report.sh          strip the personal output path and the debug echo,
#                          keep the column-alignment fix
#   scripts/pre-commit.sh  replace the three planted credentials with an
#                          environment read
#
# Usage: demo-edits.sh <worktree>
#
set -euo pipefail

WT="${1:?usage: demo-edits.sh <worktree>}"
[ -d "$WT" ] || {
	echo "no such worktree: $WT" >&2
	exit 1
}

# Upstream hardened both functions against unset input; the local change trims
# whitespace around keys. Both survive.
cat >"$WT/src/parser.sh" <<'EOF'
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
cat >"$WT/src/report.sh" <<'EOF'
#!/usr/bin/env bash
# Render a two-column report.

REPORT_WIDTH="${REPORT_WIDTH:-24}"

render_row() {
	local label="$1" value="$2"
	# Pad to at least the label width so long labels do not eat the column.
	local width="$REPORT_WIDTH"
	if [ "${#label}" -gt "$width" ]; then
		width="${#label}"
	fi
	printf '%-*s %s\n' "$width" "$label" "$value"
}
EOF

# Credentials come out of the file, not out of the PR description.
hook="$WT/scripts/pre-commit.sh"
tmp="$hook.tmp"
{
	sed -n '1,4p' "$hook"
	printf '# Set NOTIFY_HOOK in the environment to enable commit notifications.\n'
	printf 'NOTIFY_HOOK="${NOTIFY_HOOK:-}"\n'
	sed -n '8,16p' "$hook"
	printf 'if [ -n "$NOTIFY_HOOK" ]; then\n'
	printf '\tprintf %s "commit ok" >&2\n' "'%s\\n'"
	printf 'fi\n'
} >"$tmp"
mv "$tmp" "$hook"
chmod +x "$hook"

echo "applied the edits a real hoist would make by hand"
