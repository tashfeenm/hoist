---
name: hoist
description: Lift the current state of specific files out of a dirty working repo onto a clean branch off origin/<target>, run four safety checks, and open a PR. Use when the user wants to ship, promote, upstream, or PR some of their local changes while leaving the rest of their mess in place — "hoist these to main", "PR just the parser fix", "get this out of my dirty repo".
---

# hoist

**Work dirty. Ship clean.**

The user's repo is dirty and personal — their own CLAUDE.md tweaks, local hooks,
scratch files, machine paths. Real shareable work is buried in that mess. Your
job is to lift the current **state** of the files they name onto a clean branch
and open a PR, without disturbing anything else.

Two rules that never bend:

1. **File states, never commits.** The dirty repo's history is irrelevant. There
   is no cherry-picking and no rebasing. Ever.
2. **Never push without explicit confirmation.** The dry run is the default
   ending. The user says go, or nothing is pushed.

## The flow

`$SKILL` below is this skill's directory.

### 1. Agree on the file list and the target

Never guess the list. If the user was vague ("ship the parser fix"), run
`git status --short --untracked=all` and `git diff --stat`, propose a list, and
have them confirm it. Name files, not directories.

Watch for what the user should *not* ship: local config, editor settings,
`CLAUDE.local.md`, scratch notes. Say so if you see them on the list.

Default the target to the repo's default branch unless told otherwise.

### 2. Prepare the clean worktree

```bash
STATE=$("$SKILL/scripts/hoist-prepare.sh" --repo . --target main -- FILE ...)
```

This branches off `origin/<target>` in a temporary worktree and copies in the
current state of exactly those files — preserving exec bits, handling deletions
and untracked files. It prints a state file path; every later step takes
`--state "$STATE"`. **The user's working tree is never modified.**

### 3. Scan

```bash
"$SKILL/scripts/hoist-scan.sh" --state "$STATE"
```

Four named checks. Exit 1 means findings to review — it is not a failure:

| Check | What it means when it fires |
|---|---|
| **secrets** | A credential is in a hoisted file. Remove it from the copy in the worktree and replace it with an env var read. Never push it, never "note it in the PR". |
| **personal identifiers** | A home path, username, hostname or personal email is in a line you are adding. Usually a hunk that should not have come along. |
| **upstream drift** | The file also moved on the target since the merge-base. Hoisting the state verbatim would **silently revert a teammate's work.** Merge, do not overwrite. |
| **gates** | The repo's own lint/tests fail in the clean worktree. Almost always a reference dangling because a file the change depends on was left off the list. |

If the repo's gates are not autodetected, pass `--gates 'make check'`.

### 4. Judgment — this is the part that is you

The scripts find what is mechanical. Do the rest, reading the actual diff:

The state file is a shell fragment, so sourcing it gives you the worktree path:

```bash
. "$STATE"                                 # sets HOIST_WORKTREE, HOIST_BRANCH, ...
git -C "$HOIST_WORKTREE" diff --cached     # this is what would be pushed
```

Edit files under `$HOIST_WORKTREE` freely — that is the clean copy, and it is
what the scan and the commit both read.

- **Read every hunk.** Scanners miss things. In this skill's own fixture,
  gitleaks catches an AWS secret key and a Slack webhook but walks straight past
  the `AKIA...` access key ID on the line above. Assume there is something the
  tools did not name.
- **Strip personal hunks.** A file often carries a real fix *and* a personal
  tweak. Edit the copy in the worktree — remove the tweak, keep the fix. Never
  reach for `git add -p` in the user's repo.
- **Resolve drift by merging.** Read what landed upstream
  (`git diff <merge-base> origin/<target> -- FILE`), then write a version of the
  file in the worktree that contains both their change and the user's. Then
  re-scan: the drift check clears itself once upstream's work is carried.
- **Catch dangling references.** A promoted file calling a helper that was left
  behind is the classic partial-hoist failure. The gates catch most of it.
- **Split if it is really two PRs.** Unrelated changes in one PR are a review
  burden. Say so, and offer to hoist them separately.
- **Write the PR.** Title and body come from the diff, not from the user's
  commit messages — which, in a dirty repo, usually do not exist.

**Re-run the scan after every edit.** `hoist-scan.sh` re-reads the worktree, so
it always checks your current state, not the original snapshot.

### 5. Dry run, confirm, push

```bash
"$SKILL/scripts/hoist-finish.sh" --state "$STATE" --title "..." --body "..."
```

Show the user the diffstat, the branch, and the scan result. Ask plainly whether
to push. Only after they say yes:

```bash
"$SKILL/scripts/hoist-finish.sh" --state "$STATE" --title "..." --body "..." --push
```

Then clean up:

```bash
"$SKILL/scripts/hoist-cleanup.sh" --state "$STATE"
```

## Handling common situations

**"Just ship everything."** Push back once. hoist's value is that it takes only
what you name; a dirty repo hoisted wholesale is how the personal tweak ships.

**Findings the user waves off.** Personal-identifier findings can be false
positives — a legitimate `/home/runner` in CI config, say. Judge it, say what you
think, and defer. Secrets are different: do not push a live credential because
the user said it was fine. Say what it is and let them remove it.

**Nothing differs from the target.** prepare says so. Stop; there is nothing to
hoist.

**No `gh`, or not GitHub.** finish pushes and prints the compare URL. This is
supported, not degraded.

**It went wrong halfway.** `hoist-cleanup.sh --state "$STATE"` removes the
worktree and branch. The user's repo is untouched regardless — nothing you did
happened inside it.

## Prevention worth teaching

If the user keeps hitting mixed-hunk files, tell them once: personal
customizations belong in paths that are never promoted — a `.local/` directory,
`CLAUDE.local.md`, or plain untracked files. Files that hold both shared and
personal content are the only genuinely painful case hoist has, and the fix is
upstream of the tool.
