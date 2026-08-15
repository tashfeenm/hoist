# hoist

**Work dirty. Ship clean.**

A Claude Code skill that lifts the current state of specific files out of your
dirty repo onto a clean branch, checks them, shows you exactly what would land,
and pushes only on your say-so — in a later turn, as a separate step.

![hoist promoting seven files out of a dirty repo](demo.gif)

*Scripted CLI demo recorded against the fixture in this repo — `vhs demo.tape`
reproduces it. It drives the same scripts the skill drives; it is not a
recording of the skill inside Claude Code.*

---

Your working repo is a mess, and that is fine. It has your CLAUDE.md tweaks,
your local hooks, half an experiment, a scratch file, three machine-specific
paths. It has been like that for months and it will be like that next month —
that is how people actually work.

Somewhere in there is a real bug fix. A useful script. Something a teammate
would want. Shipping it means branching, stashing, staging hunks one at a time,
and hoping you did not drag your Desktop path along with it. So it sits there,
unshipped.

hoist takes a list of files and a target branch:

```
> /hoist src/parser.sh scripts/pre-commit.sh to main
```

It branches off `origin/main` in a temporary worktree, copies in the current
**state** of just those files, runs four checks, has Claude read the diff, shows
you the full diff, and pushes only when you say so.

**What is enforced, mechanically:** scan → full diff → receipt → your yes → push,
all bound to one tree hash. The scan writes an attestation only when all four
checks ran on the final tree; the dry run writes a receipt bound to that
attestation; `push` is a separate command that refuses unless both still bind
the tree that is staged *right now*, every finding is acknowledged by ID, and
the target has not moved. Your yes is a separate turn and a separate permission
prompt — the skill does not pre-approve `push`. Your working-tree files and
index are never modified.

## Install

```bash
git clone https://github.com/tashfeen/hoist ~/.claude/skills/hoist
```

That is the install. Then, in any repo:

```
> /hoist these files to main
```

**Requires** git (2.20+), bash (macOS's 3.2 is fine), and Claude Code 2.1.129+
(for `${CLAUDE_SKILL_DIR}`). **Optional but recommended:** `gitleaks` for real
secret scanning, `gh` to open the PR for you (without it, hoist pushes and
prints the compare link).

The scripts also work as a plain CLI — `scripts/hoist help` — which is what the
tests and the demo drive.

## What it does

```
your dirty repo                    <repo>/.hoist/<id>/tree  (worktree off origin/main)
─────────────────                  ──────────────────────────────────────────────
 M src/parser.sh    ── named ──▶    src/parser.sh      (state copied; drift merged)
 M src/report.sh    ── named ──▶    src/report.sh      (personal hunk stripped)
 D src/legacy.sh    ── named ──▶    src/legacy.sh      (deleted)
 M t/run.sh         ── named ──▶    t/run.sh           (state copied)
?? scripts/hook.sh  ── named ──▶    scripts/hook.sh    (mode 755 preserved)
 M src/config.sh       stays               ·
?? notes/scratch.md    stays               ·
?? CLAUDE.local.md     stays               ·
                                           │
                            scan ─▶ full diff ─▶ your yes ─▶ one commit ─▶ push ─▶ PR
```

**The unit of promotion is the file's current state, never a commit.** Your
dirty repo's history is irrelevant, so hoist never cherry-picks and never
rebases. Deletions and untracked files work. Exec bits survive (set on the
index, so `core.filemode=false` cannot lose them). The temporary worktree lives
inside your project under `.hoist/` (excluded from `git status` by one owned
line in `.git/info/exclude`) so Claude can edit there without extra permission
prompts, and Ctrl-C debris is findable.

## The four checks

Each produces named findings with stable IDs. Findings are not failures — they
are what you and Claude read before deciding. Findings can be fixed (edit the
copy, re-scan) or acknowledged by ID with a reason, which lands in the commit as
a `Hoist-Acknowledged:` trailer. What can *not* be acknowledged: a check that did
not run, a gate that modified a hoisted file, an operational error — those
simply produce no attestation, and `push` refuses.

| Check | Catches |
|---|---|
| **gates** | The repo's own lint and tests, run *first* in the clean worktree so the other three checks see the post-gate tree. This is what can catch a reference left dangling because you forgot to include a file. Autodetected (`make lint/test/check`, npm `test`, `just test`) but never run silently — the scan prints the command and Claude passes `--run-gates` (or asks you) — and it is only as complete as the repo's own tests. Gates run the repository's own code with your credentials and network; the worktree isolates file state, not a security sandbox. Gate failures are absolute, not proven regressions against the target. There is no timeout; Ctrl-C is cancellation. |
| **secrets** | Credentials in the hoisted files, scanned from the exact index blobs that would be committed. Shells out to `gitleaks` (exit-code aware; a report it cannot parse becomes an aggregate finding, never "clean"), layered over a small always-on pattern set for its known gaps. The AWS documentation examples are excluded by exact matched token — never by filename or surrounding text — because a scanner that cries wolf gets ignored. |
| **personal** | Home directories, usernames, hostnames, personal email — checked against the lines you are *adding*, not the whole file, so upstream's paths stay out of your report. Exact values are matched as fixed strings; only the generic path shapes are regexes. |
| **drift** | A hoisted file that also moved on the target since your merge-base. Copying your state over it would **silently revert a teammate's work.** Compares content *and* mode/type. This is the check that is easy to miss and expensive to get wrong. |

Then Claude reads the diff, which is the part a script cannot do: stripping the
personal hunk out of a file that also carries a real fix, merging the upstream
change instead of overwriting it, noticing this is really two PRs, and writing
the PR description.

## Try it — the fixture

`fixtures/make-fixture.sh` builds a throwaway repo containing every case hoist
has to handle. It is the demo and the substrate the test suite runs on.

```bash
./fixtures/make-fixture.sh
cd .fixture/workshop
```

Then, in Claude Code:

```
> /hoist src/parser.sh src/report.sh src/legacy.sh t/run.sh scripts/pre-commit.sh bin/widget t/fixtures/keys.txt to main
```

Here is what should happen, case by case:

| Case | Where | Expected |
|---|---|---|
| Shareable fix **+ upstream drift** | `src/parser.sh` | The same file was hardened on `origin/main` after your clone. hoist warns; Claude merges both changes rather than reverting theirs; the finding clears on re-scan. |
| **Mixed hunks** | `src/report.sh` | One file, two hunks: a personal Desktop path near the top, a real alignment fix further down. The personal hunk gets stripped from the clean copy. |
| **Personal only** | `src/config.sh` | Home paths and `LOG_LEVEL=trace`. Never listed, never hoisted — this is the file that proves hoist takes only what you name. |
| **Deletion + dangling ref** | `src/legacy.sh` deleted | Leave `t/run.sh` off the list and the gates fail: the clean worktree still sources a file that is gone. |
| **Untracked exec hook** | `scripts/pre-commit.sh` | Untracked file gets hoisted, mode `755` survives. |
| **Planted secrets** | same hook | AWS key ID (line 5), AWS secret (line 6), Slack webhook (line 7) — all three flagged *with gitleaks installed*; the fallback pattern set alone catches the key ID and the webhook. |
| **Mode-only drift** | `bin/widget` | Upstream ran `chmod +x` after your clone; your copy edits the content at 644. Flagged as "mode changed upstream" until the copy is 755 — a content-only drift check would miss this. |
| **Decoy — must NOT flag** | `t/fixtures/keys.txt` | Modified locally (a comment), so it is listed and actually scanned. Contains `AKIAIOSFODNN7EXAMPLE`, the AWS documentation key. Stays clean. |
| **Local hooks must not fire** | `.git/hooks/pre-commit`, `pre-push`, `post-checkout` | The workshop has hooks that refuse commits and pushes and drop a marker on checkout — the "personal local hooks" of the problem statement. hoist's own git commands run with hooks disabled, so none of them fire. |
| **Untracked noise** | `notes/scratch.md`, `CLAUDE.local.md` | Never hoisted. |

### A finding worth keeping

On the planted hook, **gitleaks catches the AWS secret key and the Slack webhook
but walks past the `AKIA...` access key ID on the line above.** We left that in
the fixture rather than tuning it away.

hoist's own pattern set catches that one, and Claude reading the diff is the
layer after that. Three layers, because any single layer misses things — and a
tool that shows you where its scanner is blind is worth more than one that
claims a clean sweep.

## Tests

`tests/run.sh` runs the regression suite (`tests/t-*.sh`); `tests/run.sh --bash
/bin/bash` runs it under macOS's bash 3.2. Every test builds its own fixture
under `mktemp` and drives the real scripts. It covers: state-file containment
(forged, symlinked, malformed, values with `=`); the manifest-only index (a gate
that stages a stray file and edits an unlisted file gets neither committed) and
the workshop's index/status/HEAD being byte-identical after every step; gates
running first, failing honestly (`false | true`, `false; echo ok`), never
running silently, and being unable to smuggle a mutated tree or a foreign
commit past the attestation; and the protocol — push without scan, finish
without scan, `--only`/`--skip-gates` yielding no attestation, edit-after-scan
refusal, acknowledgement by ID, push refusing while findings are open. It does
not yet cover every edge case listed below; those are the next matrix.

## Honest edge cases

- **Mixed-hunk files are the genuinely painful case.** hoist does not do hunk
  surgery on your repo. Claude edits the copy in the clean worktree instead —
  which works, but it means Claude is rewriting a file rather than picking
  hunks, so read the dry-run diff. The real fix is upstream of the tool: keep
  personal customizations in never-promoted paths (see below).
- **Drift resolution is a judgment call, and the self-clear is a text
  heuristic.** For ordinary text blobs, the finding clears once a three-way
  merge of your copy against upstream over the merge-base is a no-op. Mode-only
  and symlink/type changes, binaries, upstream renames (which appear as
  delete + add), upstream deletions and add/add collisions are labelled
  "manual review" — hoist detects them and stops; it does not infer intent.
- **The provenance limit.** Drift means "the target changed since the
  merge-base of your HEAD and the target". If you restore a file locally from
  `HEAD~10`, hoisting it reverts ten commits and drift says nothing, because
  the target did not move. The final diff is the authority; that is why the
  dry run shows all of it.
- **Gates are only as good as the repo's own tests**, run the repo's own code
  with your credentials, and can fail for reasons already present on the target.
  There is no static import scanner — that is language-specific and brittle.
- **Filenames.** Spaces and leading dashes are fine. Paths containing TAB, LF,
  CR or `:` are rejected (every `file:line` reporter would mis-split; colons are
  illegal on Windows anyway), as are `.git` as any component (case-insensitive),
  paths under a symlinked parent, paths inside or across submodules, and
  directories (name files).
- **Sparse checkouts.** A tracked file that is absent because of
  skip-worktree is refused, not treated as a deletion. Materialise it first.
- **Hooks, signing, filters, LFS.** hoist's own git commands (worktree add,
  add, commit, push) run with hooks disabled — that is how your local hooks stay
  local. Commit signing is left as you have it configured, so it may prompt or
  fail. Clean/smudge filters are untouched (they are still executable code with
  your ambient access); the secrets scan reads the index blobs, so scanned bytes
  are committed bytes. Because pre-push hooks are off, **Git LFS is
  unsupported**.
- **`--no-fetch` and unrelated histories.** Fetch failure is fatal unless you
  pass `--no-fetch`, in which case drift is reported as a standing "stale"
  finding. No merge-base is fatal unless you pass `--allow-unrelated-history`,
  in which case drift cannot run and stays a finding. Shallow clones are
  refused (`git fetch --unshallow`).
- **The target moves after prepare.** `push` re-reads the remote and refuses;
  prepare again from the new target — your yes was for the old tree.
- **Ctrl-C, concurrency, cleanup.** prepare rolls back on interrupt. Two hoists
  in one repo at once are refused by a lock rather than corrupting anything.
  cleanup refuses to delete unpushed or unshipped work without `--discard`.
- **`.hoist/`.** The worktree lives at `<repo>/.hoist/<id>/tree`, ignored via
  one owned `/.hoist/` line in `.git/info/exclude` that hoist writes once and
  leaves in place. Don't `git clean -ffdx` while a hoist is active (it would
  delete the worktree and leave git's metadata stale — `git worktree prune`
  fixes that); `git add -f .hoist` bypasses the ignore; IDE watchers may index
  the duplicate checkout.
- **Whole files only. One commit per hoist. Same-repo only.** hoist branches
  off `origin/<target>` in the repo you are standing in; promoting between two
  unrelated repos has no shared merge-base, which means drift detection would
  silently degrade to nothing — so hoist does not pretend to do it.
- **Not portable to claude.ai skill uploads unchanged.** The frontmatter uses
  Claude Code extensions (`allowed-tools`, `disable-model-invocation`,
  `${CLAUDE_SKILL_DIR}`).
- **Opens a PR** with `gh` when the remote is GitHub and `gh` is authenticated;
  otherwise it pushes the branch and prints the GitHub compare link, the GitLab
  merge-request link, or "open the PR in your host's UI".

## The convention that prevents the pain

Keep personal customizations in paths that never get promoted:

- a `.local/` directory, gitignored
- `CLAUDE.local.md` rather than edits to a shared `CLAUDE.md`
- plain untracked files

A file that holds both shared and personal content is the only case that needs
per-file surgery. Everything else is just `.gitignore` doing its job. hoist's own
repo works this way — the maintainer's tooling is all gitignored, which is why
cloning it gets you git, bash, and nothing else.

## Why "hoist"?

It had to be a noun already waiting to become a verb — you hoist a thing, you
hoisted it, it got hoisted, no forcing required.

Nearly every short, meaningful English verb is taken: `skiff`, `sloop`, `sprig`,
`nib`, `scoop`, `lift`, `pare`, `whittle`, `winnow`, `quarry`, `decant`,
`drydock` all have real owners, several in agent tooling. `porcelain` was lovely
until you remember `git status --porcelain` means *machine-readable output* — the
exact opposite connotation, aimed at exactly the audience who would misread it.
`shipshape` lost to a crowded namespace.

`hoist` has a prior meaning in programming too — declaration hoisting, loop
hoisting — but it points the same direction: lift something from an inner scope
to an outer one. That costs a beat of recognition, not a wrong turn.

## License

MIT. See [LICENSE](LICENSE).
