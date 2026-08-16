# hoist

[![tests](https://github.com/tashfeenm/hoist/actions/workflows/tests.yml/badge.svg)](https://github.com/tashfeenm/hoist/actions/workflows/tests.yml)

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

**What the scripts enforce, mechanically:** scan → full diff → receipt →
push, all bound to one tree hash, one remote (its stored URLs *and* its
effective fetch and push endpoints — every `url` value, `insteadOf` and
`pushInsteadOf` applied — bound at prepare, exactly one of each, re-derived at
push), one target and one branch. The scan writes an attestation only when all
four checks ran on the final tree and nothing else moved (the hoisted files,
refs, git config, the frozen manifest); the dry run writes a receipt bound to
that attestation, the acknowledgements and the exact commit message; `push` is
a separate command that refuses unless all of that still binds the tree that is
staged *right now*, every finding is acknowledged by ID, the remote's stored
and effective URLs are the ones bound at prepare, and the target has not moved.

**What the skill enforces, by protocol:** your yes is a *later* message, for
the tree you saw. That is a rule in `SKILL.md` backed by Claude Code's
permission prompt (`push` and `acknowledge` are not pre-approved by the skill),
not something a script can prove — say so plainly: no artifact records that a
human spoke.

hoist itself never writes to your working-tree files or index. Repository
gates and configured git helpers (filters, textconv, hooks the *gates* run) are
the repository's own code and are not sandboxed by hoist.

## Install

```bash
git clone https://github.com/tashfeenm/hoist ~/.claude/skills/hoist
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
| **secrets** | Credentials in the hoisted files, scanned from the exact index blobs that would be committed. Shells out to `gitleaks` (exit-code aware; a report it cannot parse becomes an aggregate finding, never "clean"), layered over a small always-on pattern set for its known gaps (a text-shaped grep run over the raw bytes; not a binary-format scanner). Exactly two published AWS documentation key IDs are excluded, by exact matched token — never a substring rule, never a filename — because a scanner that cries wolf gets ignored. |
| **personal** | Home directories, usernames, hostnames, personal email — checked against the lines you are *adding*, not the whole file, so upstream's paths stay out of your report. Exact values are matched as fixed strings; only the generic path shapes are regexes. |
| **drift** | A hoisted file that also moved on the target since your merge-base. Copying your state over it would **silently revert a teammate's work.** Compares content *and* mode/type. This is the check that is easy to miss and expensive to get wrong. |

Then Claude reads the diff, which is the part a script cannot do: stripping the
personal hunk out of a file that also carries a real fix, merging the upstream
change instead of overwriting it, noticing this is really two PRs, and writing
the PR description.

## Try it — the fixture

`fixtures/make-fixture.sh` builds a throwaway repo containing the canonical
demo cases. It is the demo and the substrate the test suite runs on; the
adversarial cases live in `tests/`.

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

`tests/run.sh` runs the regression suite (`tests/t-*.sh`, eleven files, ~520
assertions); `tests/run.sh --bash /bin/bash` runs it under macOS's bash 3.2;
`HOIST_TEST_STRICT=1` turns the environment-dependent skips (no gitleaks, no
submodule support, git older than 2.28 for the `reference-transaction` hook)
into failures for CI. That is exactly what
[`.github/workflows/tests.yml`](.github/workflows/tests.yml) runs on every
push and pull request: Linux with bash 5, and macOS with both `/bin/bash` 3.2
and Homebrew bash 5, gitleaks pinned by checksum. Every test builds its own fixture
under `mktemp` and drives the real scripts. Suites: state containment (forged,
symlinked, malformed, edited target/branch, values with `=`); manifest-only
index and untouched workshop; filenames and index edge cases; the drift matrix;
gates (mutation, foreign commit, false-pass, silent-run, dangling ref, Ctrl-C);
the scan→finish→acknowledge→push protocol; scan semantics (gitleaks present,
missing, erroring, unparseable; the decoy; excerpt hygiene); hooks, filters and
a failing signer; remotes and push (URLs, no token leaks, existing branch,
target moved, `gh` failure, hosts); lifecycle and locks; and integrity
(frozen manifest, push-URL swap, edited state, receipt-bound acknowledgements,
textconv, `reference-transaction` hooks, unregistered worktrees, secret
acknowledgement, long bodies). Not covered, by design: a real race between the
final target check and the push (see below), and anything a deliberately
malicious same-user process does to the state directory.

**Forward eval.** Every pull request in this repository is opened with hoist.
[`docs/eval-transcript.md`](docs/eval-transcript.md) is the session
transcript of the first one, rendered straight from the session log (two path
substitutions, disclosed in its header) — prepare, gates-first scan, the raw diff read hunk
by hunk, the dry run, the stop, the human's yes in a later turn, the push, CI on
both operating systems, the merge and the cleanup — including what the tooling
refused along the way and the caveats about how faithfully it exercised the
skill. [`docs/eval-2-foreign-repo.md`](docs/eval-2-foreign-repo.md) is the
second run: hoist opening *another* repository's first pull request the next
day, under a delegated instruction, with the STOP holding for hours until a
real yes arrived — and what that run showed about hoist (unset `origin/HEAD`,
no gate autodetection for Python, pre-existing red tests on the target, version
skew between the dry run and the push).

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
- **Hooks, signing, filters, LFS.** Every git command hoist itself issues
  (fetch, worktree add, add, status, commit, branch delete, push) runs with
  hooks disabled — that is how your local hooks stay local, `reference-
  transaction` and `post-index-change` included; the tests pin it. Commit signing is left as you have it configured, so it may prompt or
  fail. Clean/smudge filters are untouched (they are still executable code with
  your ambient access); the secrets scan reads the index blobs, so scanned bytes
  are committed bytes. Because pre-push hooks are off, **Git LFS is
  unsupported**.
- **`--no-fetch` and unrelated histories.** Fetch failure is fatal unless you
  pass `--no-fetch`, in which case drift is reported as a standing "stale"
  finding. No merge-base is fatal unless you pass `--allow-unrelated-history`,
  in which case drift cannot run and stays a finding. Shallow clones are
  refused (`git fetch --unshallow`).
- **The target moves after prepare.** `push` re-reads the remote before
  committing and again right before pushing, and refuses; prepare again from
  the new target — your yes was for the old tree. The push itself carries a
  lease only on the *new* branch (git has no cross-ref lease), so a target
  that moves in the instant between that last check and the push lands as a
  PR against a moved target — the PR page shows it; hoist cannot prevent it.
- **Ctrl-C, concurrency, cleanup.** prepare rolls back on interrupt (and
  inspects what a half-made `worktree add` actually left). Two hoists in one
  repo at once are refused by a lock rather than corrupting anything. cleanup
  refuses to delete unpushed or unshipped work, or a worktree git no longer
  lists, without `--discard`; ignored files (build outputs) are treated as
  disposable; the branch is deleted only when the live worktree is on it — if
  the worktree has vanished, nothing proves the branch is hoist's rather than
  one named by an edited state file, so it is kept and the `git branch -D` is
  printed for you.
- **Gates can do anything the repo's code can**, including reach the network
  or your main checkout, before your yes. hoist prints the command and never
  runs an autodetected one silently, watches the hoisted files, refs, config
  and the manifest across the run, and refuses to attest if any of those moved
  (other files a gate touches in the worktree are its own business and are
  never committed) — but that is detection after the fact, not a sandbox.
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
