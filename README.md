# hoist

**Work dirty. Ship clean.**

A Claude Code skill that lifts the current state of specific files out of your
dirty repo onto a clean branch, checks them, and opens a PR.

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
you exactly what would land, and pushes only when you say so.

Your working tree is never touched. Nothing is pushed without your word.

## Install

```bash
git clone https://github.com/tashfeen/hoist ~/.claude/skills/hoist
```

That is the install. Then, in any repo:

```
> /hoist these files to main
```

**Requires** git and bash. **Optional but recommended:** `gitleaks` for secret
scanning, `gh` to open the PR for you (without it, hoist pushes and prints the
compare URL).

## What it does

```
your dirty repo                    a temporary worktree off origin/main
─────────────────                  ────────────────────────────────────
 M src/parser.sh    ── named ──▶    src/parser.sh      (state copied)
 M src/report.sh    ── named ──▶    src/report.sh      (personal hunk stripped)
 D src/legacy.sh    ── named ──▶    src/legacy.sh      (deleted)
 M t/run.sh         ── named ──▶    t/run.sh           (state copied)
?? scripts/hook.sh  ── named ──▶    scripts/hook.sh    (mode 755 preserved)
 M src/config.sh       stays               ·
?? notes/scratch.md    stays               ·
?? CLAUDE.local.md     stays               ·
                                           │
                                    one commit ─▶ push ─▶ PR
```

**The unit of promotion is the file's current state, never a commit.** Your
dirty repo's history is irrelevant, so hoist never cherry-picks and never
rebases. Deletions and untracked files work. Exec bits survive.

## The four checks

Each produces a named, human-readable finding. Findings are not failures — they
are what you and Claude read before deciding.

| Check | Catches |
|---|---|
| **secrets** | Credentials in the hoisted files. Shells out to `gitleaks`, layered over a small always-on pattern set for its known gaps. Documentation examples are excluded — a scanner that cries wolf gets ignored. |
| **personal identifiers** | Home directories, usernames, hostnames, personal email — checked against the lines you are *adding*, not the whole file, so upstream's paths stay out of your report. |
| **upstream drift** | A hoisted file that also moved on the target since your merge-base. Copying your state over it would **silently revert a teammate's work.** This is the check that is easy to miss and expensive to get wrong. |
| **gates** | The repo's own lint and tests, run in the clean worktree. This is what catches a reference left dangling because you forgot to include a file. |

Then Claude reads the diff, which is the part a script cannot do: stripping the
personal hunk out of a file that also carries a real fix, merging the upstream
change instead of overwriting it, noticing this is really two PRs, and writing
the PR description.

## Try it — the fixture is the eval

`fixtures/make-fixture.sh` builds a throwaway repo containing every case hoist
has to handle. It is the test suite, the demo, and a public eval at once.

```bash
./fixtures/make-fixture.sh
cd .fixture/workshop
```

Then, in Claude Code:

```
> /hoist src/parser.sh src/report.sh src/legacy.sh t/run.sh scripts/pre-commit.sh to main
```

Here is what should happen, case by case:

| Case | Where | Expected |
|---|---|---|
| Shareable fix **+ upstream drift** | `src/parser.sh` | The same file was hardened on `origin/main` after your clone. hoist warns; Claude merges both changes rather than reverting theirs. |
| **Mixed hunks** | `src/report.sh` | One file, a real alignment fix plus a personal Desktop path and a debug echo. The personal hunks get stripped from the clean copy. |
| **Personal only** | `src/config.sh` | Home paths and `LOG_LEVEL=trace`. Never listed, never hoisted — this is the file that proves hoist takes only what you name. |
| **Deletion + dangling ref** | `src/legacy.sh` deleted | Leave `t/run.sh` off the list and the gates fail: the clean worktree still sources a file that is gone. |
| **Untracked exec hook** | `scripts/pre-commit.sh` | Untracked file gets hoisted, mode `755` survives. |
| **Planted secrets** | same hook | AWS key ID (line 5), AWS secret (line 6), Slack webhook (line 7) — all three flagged. |
| **Decoy — must NOT flag** | `t/fixtures/keys.txt` | `AKIAIOSFODNN7EXAMPLE`, the AWS documentation key. Stays clean. A scanner that flags this is too noisy to trust. |
| **Untracked noise** | `notes/scratch.md`, `CLAUDE.local.md` | Never hoisted. |

### A finding worth keeping

On the planted hook, **gitleaks catches the AWS secret key and the Slack webhook
but walks past the `AKIA...` access key ID on the line above.** We left that in
the fixture rather than tuning it away.

hoist's own pattern set catches that one, and Claude reading the diff is the
layer after that. Three layers, because any single layer misses things — and a
tool that shows you where its scanner is blind is worth more than one that
claims a clean sweep.

## Honest edge cases

- **Mixed-hunk files are the genuinely painful case.** hoist does not do hunk
  surgery on your repo. Claude edits the copy in the clean worktree instead —
  which works, but it means Claude is rewriting a file rather than picking
  hunks, so read the dry-run diff. The real fix is upstream of the tool: keep
  personal customizations in never-promoted paths (see below).
- **Upstream drift resolution is a judgment call.** hoist detects it reliably
  and refuses to silently revert. Merging the two versions is Claude's edit, and
  you should read it.
- **Gates are only as good as the repo's own tests.** hoist autodetects `make
  lint`/`make test`, an npm `test` script, or a justfile `test` target; pass
  `--gates 'CMD'` otherwise. There is no static import scanner — that is
  language-specific and brittle, and a repo's own gates are the honest catch.
- **Whole files only.** hoist promotes states of named files. It does not
  promote a directory, and it will tell you so rather than guess.
- **One commit per hoist.** If your change wants three commits, hoist is the
  wrong shape for it.
- **Same-repo only.** hoist branches off `origin/<target>` in the repo you are
  standing in. Promoting between two unrelated repos has no shared merge-base,
  which means drift detection would silently degrade to nothing — so hoist does
  not pretend to do it.

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
