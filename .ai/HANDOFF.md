# hoist — session handoff

Paste the block below into a fresh session. Everything above the rule is context
for Tashfeen; everything below it is the prompt.

---

We're building **hoist** — a public, standalone Claude Code skill. Tagline:
**"Work dirty. Ship clean."** Repo `hoist`, skill command `/hoist`, MIT licensed.

The name is LOCKED. Do not reopen it — it cost four rounds, two advisory
consults, and ~22 screened candidates. Rationale is in `.ai/DECISIONS.md`; read
that entry before touching naming anywhere.

## What hoist does

A developer's working repo is permanently dirty and personalized: their own
CLAUDE.md tweaks, local hooks, scratch files, experiments, machine-specific
paths. Real shareable work happens in that mess — a genuine bug fix, a useful
script — but shipping it is miserable, so it sits there unshipped. The mess is a
permanent condition of how humans work, not a temporary state.

You point hoist at a list of files and a target branch. It hoists the current
STATE of just those files onto a clean branch and opens a PR.

## Design decisions — already made, do NOT relitigate

1. **Flow:** fresh branch off `origin/<target>` in a temporary git worktree
   (dirty repo never touched) -> copy current state of only the listed files ->
   single commit with a generated message -> push -> open PR.
2. **The promotion unit is the file state, never the commit.** The dirty repo's
   history is irrelevant, so there is no cherry-picking or rebase surgery, ever.
   Deletions and untracked files are explicitly supported (untracked hooks and
   scripts are common in dirty repos). File mode/exec bits are preserved.
3. **Mixed-hunk files** (one file = shareable fix + personal tweak): no
   `git add -p` machinery. Claude edits the copy in the clean worktree to strip
   the personal hunks before committing, then re-runs the safety checks on the
   edited state. Prevention is documented as a convention in the README:
   personal customizations belong in never-promoted paths (`.local/` dir,
   `CLAUDE.local.md`, untracked files).
4. **Four named pre-push checks**, each producing a human-readable finding:
   - **Secrets** — shell out to `gitleaks` if installed; fall back to a small
     regex set plus Claude reading the diff. Do NOT reimplement secret detection.
   - **Personal identifiers** — home dirs, usernames, machine-specific paths,
     personal URLs.
   - **Upstream drift** — if a hoisted file also changed on `origin/<target>`
     since the dirty repo's merge-base, copying our state would silently REVERT
     that work. Detect per-file, warn, and have Claude propose a merged state.
     Never push a silent revert. This one is critical and easy to miss.
   - **Gates** — run the target repo's own lint/build/tests inside the clean
     worktree. This is the generic dangling-reference catch. A static import
     scanner is explicitly OUT OF SCOPE (language-specific, brittle).
5. **Judgment layer** — what makes this a skill and not a script: Claude walks
   the hoisted diff, catches dangling references and leaks the scanners miss,
   proposes whether the changes are one PR or several, and writes the PR title
   and description from the diff.
6. **Dry-run is first-class and the default ending.** Show files, hunks, base
   branch, scan results, gates output — then require explicit confirmation
   before pushing. Never push silently.
7. **`gh` is optional.** If absent, push and print the compare/PR-create URL
   rather than failing.
8. **Zero dependencies** beyond git + bash (+ optional `gh`, `gitleaks`). No
   Latch, no private tooling. Must work for a stranger in ten minutes — this
   constraint wins every tradeoff.

## Working style

- This is a public credibility artifact: **finish quality > scope.** Cut
  features before cutting polish.
- Keep the skill honest about what it can't do. The README's edge-case section
  is a feature, not an admission.
- Test everything against the fixture before claiming it works. The demo must be
  reproducible from a clean clone.
- Commit as you go with conventional prefixes (`feat:`, `docs:`, ...).
- **Don't push anywhere until Tashfeen says where the remote is.** No remote is
  configured yet.

## What's already done

**`fixtures/make-fixture.sh` — committed, verified, works.** It builds a
throwaway repo at `.fixture/` (gitignored): a bare `origin.git` whose `main` has
advanced one commit past the clone, plus a `workshop` clone with a realistically
dirty working tree. Rebuild anytime — it's idempotent and destroys `.fixture/`
first. This fixture is the test suite, the demo, and a public eval all at once.

Every planted case is verified to actually fire:

| Case | Where | Expected finding |
|---|---|---|
| Shareable fix + upstream drift | `src/parser.sh` | Same file moved on `origin/main` since merge-base — hoisting it verbatim reverts a teammate's hardening fix. Must warn and propose a merge. |
| Mixed hunks | `src/report.sh` | Real alignment fix + personal Desktop path + debug echo, one file. Personal hunks must be stripped in the clean worktree. |
| Personal-only | `src/config.sh` | Home paths, `LOG_LEVEL=trace`. Never listed for promotion — proves hoist takes only what you name. |
| Deletion + dangling ref | `src/legacy.sh` deleted, `t/run.sh` updated | If `t/run.sh` is omitted from the list, the clean worktree still sources `src/legacy.sh` and the gates catch it. |
| Untracked exec hook | `scripts/pre-commit.sh` | Mode 755 must survive the hoist. |
| Planted secret | same hook | AWS key id (line 5), AWS secret (line 6), Slack webhook (line 7). |
| **Decoy — must NOT flag** | `t/fixtures/keys.txt` | The AWS documentation example key. A scanner that flags this is too noisy to trust. Verified: gitleaks returns 0 findings. |
| Untracked noise | `notes/scratch.md`, `CLAUDE.local.md` | Must never be hoisted. |

Both sides are green — the dirty tree and the upstream baseline each pass the
fixture's own gates — so any gate failure during a hoist is attributable to the
hoist itself.

**Two findings from building it, both worth preserving:**

- **gitleaks 8.30 removed `detect`.** The surface is now `gitleaks dir <path>`
  and `gitleaks git <repo>`, with `--report-path -` for stdout. The scan script
  needs a version shim, since older installs still use `detect --no-git
  --source`. Don't assume either form.
- **gitleaks misses the `AKIA...` access key ID** on line 5 of the planted hook.
  It catches the secret key and the Slack webhook but not the key id. KEEP THIS.
  It's the honest argument for the judgment layer, and a README that shows a
  scanner missing something Claude then catches is a far better credibility
  story than a clean sweep. Document it in the eval table as a known scanner gap.

## What's next, in order

1. **`SKILL.md`** — the skill itself, the instructions Claude follows. Frontmatter
   `name: hoist`. This is the core artifact; everything else supports it.
2. **`scripts/`** — the deterministic parts: worktree setup, file copy (preserving
   modes, handling deletions and untracked files), scan helpers. Bash, no deps.
3. **The four-check scan**, each producing a named, human-readable finding.
4. **`README.md`** — 30-second demo, clear before/after (messy repo -> clean PR),
   the eval table above with expected findings including the decoy, and honest
   edge-case docs (mixed hunks, upstream drift, dangling refs).
5. **`LICENSE`** (MIT) and the `.local/`-convention doc.
6. **Demo GIF via `vhs`** (Charmbracelet). NOTE: vhs is NOT installed on this
   machine — `brew install vhs` first. Script the tape off the fixture so it
   doubles as a smoke test.

## Open question for Tashfeen — ask before assuming

This repo currently carries his private Latch scaffold: `.ai/`, `.claude/`,
`tasks/`, `CLAUDE.md`, `SETTINGS_GUIDE.md`, `requirements-latch.txt`, `.github/`.
hoist is meant to be public and zero-dependency, and a stranger cloning it
shouldn't be met with Latch pipeline config, presence artifacts, and hooks.

Three options, unresolved: (a) gitignore the scaffold, keeping it on disk so his
workflow tools keep working while the public tree stays just `SKILL.md`,
`scripts/`, `fixtures/`, `README.md`, `LICENSE`; (b) commit everything; (c) commit
a trimmed contributor-facing `CLAUDE.md` only and gitignore the rest. Ask him
early — it determines what the first public commit looks like.

Only `.gitignore` and `fixtures/make-fixture.sh` are committed so far, so this is
still cheap to decide.
