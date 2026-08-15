#!/usr/bin/env bash
#
# tests/run.sh — run hoist's regression suite.
#
#   tests/run.sh                    # every tests/t-*.sh
#   tests/run.sh t-01 t-03          # a subset, by prefix
#   tests/run.sh --bash /bin/bash   # run scripts AND tests under that bash
#                                   # (macOS ships 3.2 there; hoist must pass)
#
# Each test is a bash script printing TAP-ish lines; this runner counts files
# and lines and exits nonzero on any failure. Tests build their own fixtures
# under mktemp and never touch this repository.
#
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
BASH_BIN=""
PICK=()

while [ $# -gt 0 ]; do
	case "$1" in
	--bash)
		BASH_BIN="${2:?--bash needs a path}"
		shift 2
		;;
	-h | --help)
		sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	*)
		PICK+=("$1")
		shift
		;;
	esac
done

# --bash: put a shim first on PATH so `#!/usr/bin/env bash` in the scripts under
# test resolves to the requested interpreter too, not just this runner.
SHIM=""
if [ -n "$BASH_BIN" ]; then
	[ -x "$BASH_BIN" ] || {
		echo "not executable: $BASH_BIN" >&2
		exit 2
	}
	SHIM="$(mktemp -d "${TMPDIR:-/tmp}/hoist-bash-shim.XXXXXX")"
	ln -s "$BASH_BIN" "$SHIM/bash"
	export PATH="$SHIM:$PATH"
	trap 'rm -rf "$SHIM"' EXIT
else
	BASH_BIN="$(command -v bash)"
fi

echo "# hoist tests — $("$BASH_BIN" --version | head -1)"
echo "# git $(git --version | sed 's/^git version //')"

files=0 failed=0 pass_lines=0 fail_lines=0
for t in "$HERE"/t-*.sh; do
	[ -e "$t" ] || continue
	name="$(basename "$t" .sh)"
	if [ "${#PICK[@]}" -gt 0 ]; then
		keep=0
		for p in "${PICK[@]}"; do case "$name" in "$p"*) keep=1 ;; esac; done
		[ "$keep" -eq 1 ] || continue
	fi
	files=$((files + 1))
	echo "# --- $name"
	out="$(T_NAME="$name" "$BASH_BIN" "$t" 2>&1)"
	rc=$?
	printf '%s\n' "$out" | sed 's/^/    /'
	p="$(printf '%s\n' "$out" | grep -c '^ok ')"
	f="$(printf '%s\n' "$out" | grep -c '^not ok ')"
	pass_lines=$((pass_lines + p))
	fail_lines=$((fail_lines + f))
	if [ "$rc" -ne 0 ] || [ "$f" -gt 0 ]; then
		failed=$((failed + 1))
		echo "# FAIL $name (exit $rc)"
	fi
done

echo "#"
echo "# $files files, $pass_lines assertions passed, $fail_lines failed, $failed file(s) failing"
[ "$failed" -eq 0 ] && [ "$files" -gt 0 ]
