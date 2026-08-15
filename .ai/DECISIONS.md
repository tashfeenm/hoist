# Architectural Decisions

<!--
This file captures WHY we made non-obvious choices.
Append new decisions at the top. Never delete entries.
Format: Problem -> Options -> Chosen -> Rationale

ROTATION: When this file exceeds ~20 decisions, archive older entries to
.ai/decisions/YYYY.md and keep the most recent 10 here. Reference the
archive with "See .ai/decisions/ for historical decisions."
Create the .ai/decisions/ directory when first needed.
-->

<!-- Add new decisions below this line -->

## 2026-08-15: Skill and repo named `hoist`

**Problem:** The project needed a public-facing name. Working name `clean-promote`
was descriptive but inert, and the skill command name goes into SKILL.md
frontmatter, the README title, and every example — expensive to change later.

**Options considered:**
1. Mechanism names — `airlock`, `cleanroom`, `porcelain` — describe how it works
2. Human/domestic names — `mudroom`, `company`, `sunday-best` — describe the feeling
3. Outcome names — `shipshape`, `immaculate` — describe the resulting state
4. Coinages — `nift`, `hoik`, `branchmint` — blank slate, maximum namespace clearance
5. `hoist` — noun and verb already, aligned meaning, near-clear namespace

**Chosen:** Option 5 — `hoist`, skill `/hoist`, repo `hoist`.

**Rationale:** Tashfeen set the bar across four rounds: playful and memorable,
functionally true, legible to a git-literate audience, and — decisively — "a noun
waiting to become a verb, like Google." `hoist` is already both, so it takes -ed
and -ing with no forcing ("hoist it up to main", "I hoisted the fix").

Two named constraints killed earlier front-runners, and both are worth keeping:

- **No misleading collision with existing vocabulary.** `porcelain` died here:
  git's own porcelain/plumbing split made it lovely, but `git status --porcelain`
  means machine-readable output — the opposite connotation, so git users misread
  it. `hoist` has a prior meaning too (JS declaration hoisting, compiler LICM),
  but it points the SAME way — lift something from an inner scope to an outer
  one — so it costs a beat of recognition, not a wrong turn.
- **No namespace crowding.** `shipshape` was Tashfeen's favourite until screening:
  269★ archived Google project owning the search term, 83★ active Swift project,
  three separate Claude Code tools (`dmytri`, `lucasyhzhu-debug`, `KevNev19`), plus
  occupied npm and an actively-published PyPI name. `hoist`'s top exact GitHub
  match is an 18★ self-described placeholder; npm (2013) and PyPI (2019) squatters
  are both long dead. Nobody owns the term.

Verified during screening: every short, meaningful English verb is already taken —
`skiff`, `sloop`, `sprig`, `nib`, `scoop`, `lift`, `pare`, `whittle`, `winnow`,
`quarry`, `decant`, `drydock` all have real owners, several in agent tooling.
Verbable AND available generally means coined or rare; `hoist` is the exception.

Process note worth keeping: **screen names for collisions BEFORE presenting them.**
Two front-runners died post-presentation. Codex ran the search that caught this,
but it also fabricated its most damning citation (`sasonov/shipshape`, a 404) —
every collision claim here was independently re-verified via `gh` and the
registries before being acted on.

---

<!-- Template for new entries:

## YYYY-MM-DD: Brief title
**Problem:** What triggered this decision
**Options considered:**
1. Option A - description
2. Option B - description

**Chosen:** Option N - brief label
**Rationale:** Why this option over others

---

-->
