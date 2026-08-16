#!/usr/bin/env bash
#
# hoist push — commit the attested tree as one commit, push the branch, and
# open the PR (or hand you the link).
#
# Usage:
#   hoist push --state FILE [--no-pr]
#
#   --state FILE   state file from hoist prepare (required)
#   --no-pr        push the branch but do not open a PR
#
# Refuses unless ALL of these hold for the CURRENT staged tree:
#   - a full-scan attestation is bound to it (hoist scan)
#   - a dry-run receipt is bound to it and to that attestation (hoist finish)
#   - every finding in the attestation is acknowledged (hoist acknowledge)
#   - <remote>/<target> still equals the base commit (fresh ls-remote), and
#     the branch does not already exist on the remote
#   - the worktree's HEAD is the base commit
# Then commits (hooks disabled; signing as configured — it may prompt or
# fail), verifies exactly one commit on top of the base whose tree is the
# attested tree and whose paths are within the manifest, and pushes with a
# lease that expects the remote branch to be absent.
#
# This command is deliberately NOT in the skill's allowed-tools: it runs in a
# later turn, on the human's explicit yes for this exact tree.
#
# Exit 0 ok, 2 refused/error.
#
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/hoist-lib.sh
. "$HERE/hoist-lib.sh"

usage() {
	print_help "${BASH_SOURCE[0]}"
	exit "${1:-0}"
}

STATE="" MAKE_PR=1
while [ $# -gt 0 ]; do
	case "$1" in
	--state)
		STATE="${2:?--state needs a file}"
		shift 2
		;;
	--no-pr)
		MAKE_PR=0
		shift
		;;
	-h | --help) usage 0 ;;
	*) die "unknown argument: $1" ;;
	esac
done
[ -n "$STATE" ] || usage 2

state_load "$STATE"
lock_state
trap 'unlock_state' EXIT
trap 'unlock_state; trap - EXIT; exit 130' INT
trap 'unlock_state; trap - EXIT; exit 143' TERM
trap 'unlock_state; trap - EXIT; exit 129' HUP
trap 'die "push aborted — operational error (line $LINENO)"' ERR
WT="$HOIST_WORKTREE"
TMP="$HOIST_TMP"
B="$HOIST_BRANCH"
umask 077

# --- everything must be bound to the tree that is staged right now ---------

restage "$WT" "$HOIST_MANIFEST"
TREE="$(staged_tree "$WT")"
A="$TMP/attest"
attest_verify "$A" "$TREE"

R="$TMP/receipt"
[ -f "$R" ] && [ ! -L "$R" ] || die "no dry-run receipt — run hoist finish first (and show the human the full diff)"
kv_strict "$R" "receipt" "$RECEIPT_KEYS" ""
ADIGEST="$(digest_file "$A")"
[ "$(kv_get "$R" version)" = "1" ] || die "unsupported receipt version"
[ "$(kv_get "$R" id)" = "$HOIST_ID" ] || die "receipt belongs to a different hoist"
[ "$(kv_get "$R" tree)" = "$TREE" ] || die "receipt is for a different tree — re-run hoist finish"
[ "$(kv_get "$R" attest)" = "$ADIGEST" ] || die "receipt is for a different attestation — re-run hoist finish"
[ -f "$TMP/message" ] && [ ! -L "$TMP/message" ] && [ "$(kv_get "$R" message)" = "$(digest_file "$TMP/message")" ] ||
	die "receipt does not match the message — re-run hoist finish"

FD="$(kv_get "$A" findings_digest)"
NF="$(kv_get "$A" findings)"
open=""
if [ "$NF" -gt 0 ]; then
	ack_valid "$TMP/ack" "$TREE" "$FD" "$ADIGEST" || die "$NF finding(s) unacknowledged — fix and re-scan, or hoist acknowledge each by ID (then finish again)"
	[ "$(kv_get "$R" ack)" = "$(digest_file "$TMP/ack")" ] ||
		die "the acknowledgements changed after the dry run — re-run hoist finish so the trailers are shown"
	while IFS= read -r id; do
		[ -n "$id" ] || continue
		kv_get "$TMP/ack" "ack.$id" >/dev/null 2>&1 || open="$open $id"
	done < <(kv_get_all "$A" finding)
	[ -z "$open" ] || die "unacknowledged finding(s):$open — fix and re-scan, or hoist acknowledge each by ID"
else
	[ "$(kv_get "$R" ack)" = "-" ] || die "receipt records acknowledgements for a clean attestation — re-run hoist finish"
fi

# --- the remote must be the one prepare bound ------------------------------

cur_url="$(git -C "$HOIST_REPO" config --get "remote.$HOIST_REMOTE.url" 2>/dev/null || true)"
[ "$cur_url" = "$HOIST_REMOTE_URL" ] || die "the URL of remote $HOIST_REMOTE changed since prepare — refusing (hoist cleanup --discard, then prepare again)"
n_push="$(git -C "$HOIST_REPO" config --get-all "remote.$HOIST_REMOTE.pushurl" 2>/dev/null | grep -c . || true)"
[ "${n_push:-0}" -le 1 ] || die "remote $HOIST_REMOTE now has several push URLs — refusing"
cur_push="$(git -C "$HOIST_REPO" config --get "remote.$HOIST_REMOTE.pushurl" 2>/dev/null || true)"
[ "$cur_push" = "$HOIST_PUSH_URL" ] || die "the push URL of remote $HOIST_REMOTE changed since prepare — refusing (hoist cleanup --discard, then prepare again)"
# The EFFECTIVE endpoints — every configured URL, url.*.insteadOf and
# pushInsteadOf applied — must be the single ones prepare bound. A second
# remote.<name>.url (git would push to both) or a rewrite added since then
# shows up here even though the stored values above are unchanged.
cur_eff="$(git -C "$HOIST_REPO" remote get-url --all -- "$HOIST_REMOTE" 2>/dev/null || true)"
[ "$cur_eff" = "$HOIST_FETCH_EFFECTIVE" ] || die "the effective fetch URL of remote $HOIST_REMOTE changed since prepare (a URL was added or a url.*.insteadOf rewrite changed) — refusing (hoist cleanup --discard, then prepare again)"
cur_eff="$(git -C "$HOIST_REPO" remote get-url --push --all -- "$HOIST_REMOTE" 2>/dev/null || true)"
[ "$cur_eff" = "$HOIST_PUSH_EFFECTIVE" ] || die "the effective push URL of remote $HOIST_REMOTE changed since prepare (a URL was added or a url.*.pushInsteadOf rewrite changed) — refusing (hoist cleanup --discard, then prepare again)"

[ "$(git -C "$WT" rev-parse HEAD)" = "$HOIST_BASE_SHA" ] ||
	die "the worktree's HEAD is not the base commit — run hoist cleanup --discard and prepare again"
[ "$(git -C "$WT" symbolic-ref --quiet HEAD)" = "refs/heads/$B" ] || die "worktree is not on $B"

# --- the remote must still be where we prepared from ------------------------

dim "checking $HOIST_REMOTE/$HOIST_TARGET ..."
# (status-bearing commands never run inside $(...): with errtrace, bash 3.2
# would fire the ERR trap in the subshell and replace git's status with 2)
rc=0
git -C "$HOIST_REPO" ls-remote --exit-code -- "$HOIST_REMOTE" "refs/heads/$HOIST_TARGET" >"$TMP/ls-remote.out" 2>"$TMP/ls-remote.err" || rc=$?
remote_sha="$(cut -f1 <"$TMP/ls-remote.out")"
case "$rc" in
0) ;;
2) die "$HOIST_REMOTE/$HOIST_TARGET no longer exists on the remote" ;;
*) die "could not reach $HOIST_REMOTE (ls-remote exit $rc): $(scrub_urls <"$TMP/ls-remote.err" | tr '\n' ' ')" ;;
esac
[ "$remote_sha" = "$HOIST_BASE_SHA" ] ||
	die "target moved: $HOIST_REMOTE/$HOIST_TARGET is now ${remote_sha:0:9} (prepared from ${HOIST_BASE_SHA:0:9}) — hoist cleanup --discard, then prepare again from the new target"
rc=0
git -C "$HOIST_REPO" ls-remote --exit-code -- "$HOIST_REMOTE" "refs/heads/$B" >/dev/null 2>&1 || rc=$?
case "$rc" in
0) die "branch $B already exists on $HOIST_REMOTE — pick another name (hoist prepare --branch)" ;;
2) ;;
*) die "could not reach $HOIST_REMOTE (ls-remote exit $rc)" ;;
esac

# --- commit ------------------------------------------------------------------
#
# The message file from finish is the whole commit message (trailers
# included), committed verbatim and verified byte-for-byte below.

MSG="$TMP/message"
if ! git_h -C "$WT" commit -q --cleanup=verbatim -F "$MSG" 2>"$TMP/commit.err"; then
	scrub_urls <"$TMP/commit.err" | sed 's/^/  /' >&2
	die "commit failed (identity or signing not configured? hoist leaves signing as configured)"
fi
NEW="$(git -C "$WT" rev-parse HEAD)"

undo() { git_h -C "$WT" reset -q --soft "$HOIST_BASE_SHA" >/dev/null 2>&1 || true; }
verify_fail() {
	undo
	die "$1 — the commit was undone; nothing was pushed"
}
[ "$(git -C "$WT" rev-parse "$NEW^" 2>/dev/null || true)" = "$HOIST_BASE_SHA" ] || verify_fail "the new commit's parent is not the base"
[ "$(git -C "$WT" rev-list --count "$HOIST_BASE_SHA..$NEW" 2>/dev/null || true)" = "1" ] || verify_fail "more than one commit on top of the base"
[ "$(git -C "$WT" rev-parse "$NEW^{tree}" 2>/dev/null || true)" = "$TREE" ] || verify_fail "the committed tree is not the attested tree"
git -C "$WT" cat-file commit "$NEW" 2>/dev/null | sed '1,/^$/d' >"$TMP/commit.msg" || verify_fail "could not read the new commit"
cmp -s "$TMP/commit.msg" "$MSG" || verify_fail "the commit message is not the reviewed message"
git -C "$WT" diff-tree --no-commit-id --no-renames --name-only -r -z "$NEW" >"$TMP/commit.paths" || verify_fail "could not list the committed paths"
while IFS= read -r -d '' p; do
	in_manifest "$HOIST_MANIFEST" "$p" || verify_fail "the commit touches a path outside the manifest: $p"
done <"$TMP/commit.paths"
info "committed ${NEW:0:9}  ${C_DIM}tree ${TREE:0:9}${C_OFF}"

# the target is re-read once more, as late as possible (signing may have
# taken a while); the window between this and the push itself is documented
rc=0
git -C "$HOIST_REPO" ls-remote --exit-code -- "$HOIST_REMOTE" "refs/heads/$HOIST_TARGET" >"$TMP/ls-remote.out" 2>"$TMP/ls-remote.err" || rc=$?
[ "$rc" -eq 0 ] && [ "$(cut -f1 <"$TMP/ls-remote.out")" = "$HOIST_BASE_SHA" ] ||
	verify_fail "target moved while committing — hoist cleanup --discard, then prepare again"

# --- push --------------------------------------------------------------------

# push the verified object, not the mutable branch ref
if ! git_h -C "$WT" push -q --force-with-lease="refs/heads/$B:" -- "$HOIST_REMOTE" "$NEW:refs/heads/$B" 2>"$TMP/push.err"; then
	scrub_urls <"$TMP/push.err" | sed 's/^/  /' >&2
	undo
	die "push failed — the local commit was undone so hoist push can be re-run once the cause is fixed"
fi
rc=0
git -C "$HOIST_REPO" ls-remote --exit-code -- "$HOIST_REMOTE" "refs/heads/$B" >"$TMP/ls-remote.out" 2>/dev/null || rc=$?
if [ "$rc" -ne 0 ] || [ "$(cut -f1 <"$TMP/ls-remote.out")" != "$NEW" ]; then
	warn "pushed, but the remote does not report ${NEW:0:9} at refs/heads/$B — check the remote before opening a PR"
fi
printf '%s\n' "$NEW" >"$TMP/pushed"
info "pushed    $B -> $HOIST_REMOTE"

# --- pull request ------------------------------------------------------------

# the URL as configured (get-url would expand insteadOf rewrites, hiding the
# host the user actually thinks of this remote as)
remote_url="$(git -C "$WT" config --get "remote.$HOIST_REMOTE.url" 2>/dev/null ||
	git -C "$WT" remote get-url -- "$HOIST_REMOTE" 2>/dev/null || true)"
hp="$(web_host_path "$remote_url")"
host="${hp%% *}"
path="${hp#* }"
title="$(head -1 "$TMP/message")"
eB="$(url_encode "$B")"
eT="$(url_encode "$HOIST_TARGET")"

if [ "$MAKE_PR" -eq 0 ]; then
	info ""
	dim "branch pushed; PR not requested (--no-pr)"
elif [ "$host" = "github.com" ] && command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
	body_file="$TMP/prbody"
	if [ "$(wc -l <"$TMP/message")" -gt 2 ]; then
		# body + trailers, as reviewed
		tail -n +3 "$TMP/message" >"$body_file"
	else
		printf 'Hoisted with hoist — https://github.com/tashfeen/hoist\n' >"$body_file"
	fi
	if ! (cd "$WT" && gh pr create --repo "$path" --base "$HOIST_TARGET" --head "$B" \
		--title "$title" --body-file "$body_file") >&2; then
		warn "gh pr create failed after the push — the branch is up; open the PR here:"
		info "  https://github.com/$path/compare/$eT...$eB?expand=1"
	fi
elif [ "$host" = "github.com" ]; then
	info ""
	info "${C_BOLD}open the PR:${C_OFF}"
	info "  https://github.com/$path/compare/$eT...$eB?expand=1"
elif [ "$host" = "gitlab.com" ]; then
	info ""
	info "${C_BOLD}open the merge request:${C_OFF}"
	info "  https://gitlab.com/$path/-/merge_requests/new?merge_request[source_branch]=$eB&merge_request[target_branch]=$eT"
else
	info ""
	info "branch $B is pushed to $HOIST_REMOTE — open the PR in your host's UI"
fi

info ""
dim "when the PR is up:  $(printf 'hoist cleanup --state %q' "$STATE")"
exit 0
