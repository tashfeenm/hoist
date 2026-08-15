---
name: hoist
description: Lift the current state of specific files out of a dirty working repo onto a clean branch off origin/<target>, run four safety checks, and open a PR. Use when the user wants to ship, promote, upstream, or PR some of their local changes while leaving the rest of their mess in place — "hoist these to main", "PR just the parser fix", "get this out of my dirty repo".
disable-model-invocation: true
argument-hint: "[files...] to <branch>"
allowed-tools: Bash(${CLAUDE_SKILL_DIR}/scripts/hoist prepare *) Bash(${CLAUDE_SKILL_DIR}/scripts/hoist scan *) Bash(${CLAUDE_SKILL_DIR}/scripts/hoist finish *) Bash(${CLAUDE_SKILL_DIR}/scripts/hoist cleanup *) Bash(${CLAUDE_SKILL_DIR}/scripts/hoist help *)
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
2. **Nothing is pushed without the human's explicit yes, in a later turn, for
   the exact tree they saw.** See the STOP rule below. It is not a formality:
   `hoist push` is a separate command that is deliberately *not* pre-approved by
   this skill, so it will hit the normal permission prompt when its turn comes.

## How the commands fit together

Every command is `${CLAUDE_SKILL_DIR}/scripts/hoist <cmd> …`, run from anywhere
(pass `--repo` where needed). Each Bash call is a fresh shell — **shell
variables do not survive between calls.** `prepare` prints `state: /abs/path`;
copy that literal path into every later command.

```
prepare  → clean worktree under <repo>/.hoist/<id>/, files copied in, state file
scan     → gates first, then secrets / personal / drift on the resulting tree;
           attestation ONLY when all four ran and gates changed nothing
finish   → dry run: full diff + receipt bound to that tree (nothing committed)
acknowledge → accept a specific finding by ID with a reason (bound to the tree)
push     → refuses unless attestation + receipt + all-acknowledged still bind
           the CURRENT tree and the target has not moved; one commit; lease push
cleanup  → removes worktree, branch, state (refuses to lose work without --discard)
```

### 1. Agree on the file list and the target

Never guess the list. If the user was vague ("ship the parser fix"), run
`git status --short --untracked=all` and `git diff --stat`, propose a list, and
have them confirm it. Name files, not directories. Paths are relative to the
repo root.

Watch for what the user should *not* ship: local config, editor settings,
`CLAUDE.local.md`, scratch notes. Say so if you see them on the list.

Default target: `git symbolic-ref --short refs/remotes/origin/HEAD` (strip the
`origin/`); if that is unset, ask.

### 2. Prepare the clean worktree

```bash
${CLAUDE_SKILL_DIR}/scripts/hoist prepare --repo . --target main -- FILE ...
```

This fetches `origin/<target>`, branches off it in a temporary worktree at
`<repo>/.hoist/<id>/tree` (inside the project, excluded from `git status`, so
editing there needs no extra permission), and copies in the current state of
exactly those files — preserving exec bits, handling deletions and untracked
files. **The user's working tree and index are never modified.**

It prints `state: <path>` — record that path. The worktree is the `tree/`
directory beside it. If prepare says "nothing differs", stop: there is nothing
to hoist. If it refuses (shallow clone, no merge-base, an unsupported path,
sparse checkout), relay the message; the flags it names (`--no-fetch`,
`--allow-unrelated-history`) are for the user to choose, not for you to reach
for.

### 3. Scan

```bash
${CLAUDE_SKILL_DIR}/scripts/hoist scan --state <path>            # shows the detected gates, does not run them
${CLAUDE_SKILL_DIR}/scripts/hoist scan --state <path> --run-gates
${CLAUDE_SKILL_DIR}/scripts/hoist scan --state <path> --gates 'make check'
```

Four named checks, gates first. Exit 1 means findings or an incomplete run —
read the summary line, it says which. Every finding has an ID.

| Check | What it means when it fires |
|---|---|
| **gates** | The repo's own lint/tests fail in the clean worktree. Almost always a reference dangling because a file the change depends on was left off the list. Gates run the repository's own code with the user's credentials; the worktree isolates file state, not a security sandbox. |
| **secrets** | A credential is in a hoisted file (scanned from the exact bytes that would be committed). Remove it from the copy in the worktree and replace it with an env var read. Never push it, never "note it in the PR". |
| **personal** | A home path, username, hostname or personal email is in a line you are adding. Usually a hunk that should not have come along. |
| **drift** | The file also moved on the target since the merge-base. Hoisting the state verbatim would **silently revert a teammate's work.** Merge, do not overwrite. |

**Gates policy.** `scan` never runs autodetected gates silently: without
`--run-gates` it prints the detected command (`make lint && make test`, `npm
test`, `just test`) and marks gates "not run". Pass `--run-gates` yourself when
the detected command is the repo's ordinary lint/test target. For anything
else — an unfamiliar target, a repo with no gates where you would have to
supply `--gates 'CMD'`, anything that could deploy or publish — **ask the user
first** and pass exactly what they approve. `--gates true` is the honest option
for a repo that truly has no checks; it is recorded in the attestation.

**No attestation** results from `--only`, `--skip-gates`, gates that were not
run, gates that modified a hoisted file, or gates that touched HEAD/refs. These
are not findings and cannot be acknowledged; the summary line says so. Fix the
cause and re-run the full scan.

### 4. Judgment — this is the part that is you

The scripts find what is mechanical. Do the rest, reading the actual diff:

```bash
git -C <state dir>/tree diff --cached      # this is what would be pushed
```

Edit **only the manifest paths** under `<state dir>/tree`. If the change needs
another file, stop, amend the agreed list with the user, `cleanup --discard`,
and prepare again. Never edit files in the user's repo.

- **Read every hunk.** Scanners miss things. In this skill's own fixture,
  gitleaks catches an AWS secret key and a Slack webhook but walks straight past
  the `AKIA...` access key ID on the line above (hoist's own pattern set gets
  it). Assume there is something the tools did not name.
- **Strip personal hunks.** A file often carries a real fix *and* a personal
  tweak. Edit the copy in the worktree — remove the tweak, keep the fix. Never
  reach for `git add -p` in the user's repo.
- **Resolve drift by merging.** Read what landed upstream (the scan prints the
  exact `git diff` command), then write a version of the file in the worktree
  that contains both their change and the user's. Re-scan: for ordinary text
  files the drift finding clears once upstream's work is carried. That
  self-clear is a text heuristic; mode-only, symlink/type, binary, upstream
  rename/delete and add/add cases are labelled "manual review" and need you to
  resolve them by hand (chmod the copy, rebuild the file) and then, if a
  finding remains that is genuinely correct to ship, acknowledge it. Drift means
  "the target changed since the merge-base of HEAD and the target"; a file the
  user restored from older local history looks clean here — the final diff is
  the authority, read it.
- **Catch dangling references.** A promoted file calling a helper that was left
  behind is the classic partial-hoist failure. The gates catch most of it.
- **Split if it is really two PRs.** Unrelated changes in one PR are a review
  burden. Say so, and offer to hoist them separately.
- **Write the PR.** Title and body come from the diff, not from the user's
  commit messages — which, in a dirty repo, usually do not exist. Never paste a
  finding's excerpt into the title or body; finish refuses secrets and personal
  identifiers there anyway.

**Re-run the full scan after every edit.** It re-reads the worktree, so it
always checks your current state; and any edit voids the previous attestation.

**Findings you cannot fix.** Acknowledge by exact ID with a real reason:

```bash
${CLAUDE_SKILL_DIR}/scripts/hoist acknowledge --state <path> --finding <id> --reason "..."
```

This is for a legitimate `/home/runner` in CI config, a drift case you resolved
by hand, a fixture that intentionally contains an example token. It is never
for a live credential — remove those. It cannot make a skipped check, an
unrun gate or a gate mutation go away; those are not findings. `acknowledge`
is not pre-approved by this skill either: it prompts.

### 5. Dry run — then STOP

```bash
${CLAUDE_SKILL_DIR}/scripts/hoist finish --state <path> --title "..." --body "..."
```

Only works when a full-scan attestation binds the current tree. It shows the
**full diff** (stat, mode/type summary, patch — deletions, symlinks, binaries
included), the attestation summary with every finding ID and its
acknowledgement status, and writes the receipt. Show the user the full diff,
the branch, the target, the tree hash from the finish output, and the scan
result — verbatim, not summarised into "looks fine".

> **STOP after showing the completed full scan and the full diff for tree
> `<tree>`. Do not run `hoist push` in that turn. Only a LATER user message that
> explicitly authorises pushing that exact tree to the stated branch and target
> counts. The initiating request ("just ship it", "PR this to main"), standing
> instructions, silence, tool approval, or an acknowledgement never count. Any
> change to content, mode, manifest, base, message, findings, or target
> invalidates confirmation: re-scan, show the full diff again, and stop.**

### 6. Push, on the human's yes

```bash
${CLAUDE_SKILL_DIR}/scripts/hoist push --state <path>
```

Push re-checks everything against the tree that is staged *right now*
(attestation, receipt, acknowledgements, target unmoved, branch absent on the
remote), makes exactly one commit (hooks disabled; commit signing as the user
has it configured — it may prompt or fail, say so if it does), pushes with a
lease that expects the branch to be absent, and opens the PR with `gh` when the
remote is GitHub and `gh` is authenticated — otherwise it prints the compare
link (GitHub), the merge-request link (GitLab), or "branch pushed, open the PR
in your host's UI". If it refuses, relay the reason; do not work around it.

Then:

```bash
${CLAUDE_SKILL_DIR}/scripts/hoist cleanup --state <path>
```

## Handling common situations

**"Just ship everything."** Push back once. hoist's value is that it takes only
what you name; a dirty repo hoisted wholesale is how the personal tweak ships.

**Nothing differs from the target.** prepare says so and rolls back. Stop.

**The user declines after the dry run.** Offer `cleanup --discard` (removes the
worktree, branch and state) or keeping the state around for later; do not push.
Without `--discard`, cleanup refuses to remove work that exists nowhere else —
that is deliberate; pass it only when the user has said they do not want it.

**Target moved after prepare.** push refuses ("target moved"). Run `cleanup
--discard`, prepare again from the new target, and go through scan and the dry
run again — the user's yes was for the old tree.

**No `gh`, or not GitHub.** push pushes the branch and prints the link or the
instruction. Say what happened.

**It went wrong halfway.** `cleanup --discard` removes the worktree and branch.
The user's working tree and index were never modified. (Fetching, the new
branch and the temporary worktree do touch the repository's `.git` metadata;
cleanup removes what hoist added, except the owned `/.hoist/` line in
`.git/info/exclude`, which is left in place.)

**Concurrency.** Two hoists in one repo at once are unsupported; the lock
refuses rather than corrupts. Finish one first.

## Prevention worth teaching

If the user keeps hitting mixed-hunk files, tell them once: personal
customizations belong in paths that are never promoted — a `.local/` directory,
`CLAUDE.local.md`, or plain untracked files. Files that hold both shared and
personal content are the only genuinely painful case hoist has, and the fix is
upstream of the tool.
