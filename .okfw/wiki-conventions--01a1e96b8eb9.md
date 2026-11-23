---
x-okfw-id: "01a1e96b-8eb9-78e6-a0de-ad0aeed80965"
title: "Wiki conventions"
type: "Guide"
tags:
  - "conventions"
  - "meta"
x-okfw-created: "2026-11-17T06:11:42-06:00"
x-okfw-timestamp: "2026-11-17T06:11:42-06:00"
description: "Layout, writing style and authoring rules for architecture notes, specs, ADRs, issues and daily notes in this wiki."
---

# Wiki conventions

This guide defines how the ztree OKF wiki (`.okfw/`) stores project knowledge.

- Create concepts with `okfw create` or the okfw MCP `create` tool. Do not write frontmatter by hand.
- Search before you write. Link to related concepts.
- Keep one idea per concept. Give each concept a one-sentence `description`.
- Do not start a `--body` with `# Title`. okfw writes the H1 from the title.

## Layout
| Path | Type | Contents |
|---|---|---|
| `architecture/` | `Architecture` | System overview, module boundaries, data flow. |
| `specs/` | `Spec` | Contracts, for example the C ABI for Go callers. |
| `decisions/` | `ADR` | Architecture decision records. |
| `issues/` | `Issue` (kind `issue`) | Tracked work: one issue per `PLAN.md` phase, plus bugs and design debt. |
| `daily/` | daily note | `okfw daily`: what changed, what you learned, what is next. |

## PLAN.md and issues
`PLAN.md` is the phase checklist. Each phase has a mirror issue: phases 1 to 7 have ISSUE-001 to ISSUE-007, and phases 8 to 13 have ISSUE-010 to ISSUE-015. Each phase heading in `PLAN.md` has an `Issue:` line that links to its issue. When you finish a phase, tick the `PLAN.md` checkboxes and the acceptance criteria of the issue.

## ADRs (`decisions/`)
- Title: `ADR-NNNN: <decision>`. Number ADRs in sequence. Do not reuse a number.
- Command: `okfw create "ADR-NNNN: <title>" --path decisions --type ADR --tags adr,<topic> -d "<one sentence>" --body "<markdown>"`
- Body: **Status** (Proposed, Accepted, or Superseded by ADR-XXXX), **Date**, **Source**, then **Context**, **Decision**, **Consequences**, **Alternatives considered**.
- To supersede an ADR, write the new ADR with a link to the old ADR. Update the Status line of the old ADR. Run `okfw set-lifecycle <id> deprecated`.
- Write an ADR before you add a dependency or a vendored source tree.

## Issues (`issues/`)
- Title: `ISSUE-NNN: <summary>`. Number issues in sequence.
- Command: `okfw create "ISSUE-NNN: <title>" --kind issue --path issues --type Issue --tags issue,open,phase-<n>,<area> -d "<summary>" --body "<markdown>"`
- Body: a **Status/Phase** line, **Description**, **Acceptance Criteria** (checkboxes), **Notes**, **Related**.
- okfw has no status field for issues. Tags carry the state: `open`, then `in-progress`, then `closed`. Use `okfw remove-tags` and `okfw add-tags`. Keep the Status line the same as the tags. Add a **Resolution** section when you close an issue.
- Find open work with `okfw search --path issues --tag open`.

## Writing style
All documentation follows ASD-STE100 Simplified Technical English. This includes the wiki, `README.md`, `PLAN.md` and `CLAUDE.md`.

- Use active voice and simple present tense: "The parser pushes the subtree."
- Start each procedural step with an imperative verb: Run, Read, Inspect, Verify, Add, Set.
- Keep procedural steps to 20 words or fewer. Keep descriptive sentences to 25 words or fewer.
- Use a verb, not a noun form: "The cursor visits the node", not "A visit of the node occurs".
- Use one term for one concept. This wiki uses these terms:
  - *runtime*: the ztree Zig code that loads a grammar and parses source text.
  - *reference runtime*: the upstream Tree-sitter C library. ztree uses it as a test oracle only.
  - *grammar*: the generated C files of one language: `parser.c`, `tree_sitter/parser.h` and an optional `scanner.c`.
  - *ABI version*: the layout version of the `TSLanguage` struct. ztree reads versions 14 and 15.
  - *parse table*, *lex function* (the generated `ts_lex`) and *external scanner* (the hand-written `scanner.c`).
  - *subtree*: one node in the arena while the parse runs. *node*: one node of the finished tree.
  - *stack version*: one GLR branch of the parse stack.
  - *cursor*: the iterative walker over the finished tree.
  - *span*: the byte range and the row and column points of one comment.
  - *phase*: one unit of work in `PLAN.md`.
- Do not use the words `should`, `will`, `would`, `please`, `simply`, `just`, `very`, `really` or `easily`. Do not use marketing language.
- Run `zmake docs-style`. The check (`scripts/ste-check.py`) reports banned words and long sentences as errors. It reports possible passive voice as warnings. Fix the warnings too.
- Run `zmake docs-lexiscope`. lexiscope also reports noun forms of verbs, `-ing` forms and marketing words. Each finding fails the check. Put a technical term in `vocabulary.cue` only when it names a concept of the project, a tool or a standard. Reword other text ([ADR-0018](/decisions/adr-0018-lexis-checks-the-documentation-with-a-repository-vocabulary--01a1f525ba3d.md)). `lexis` is the old name of lexiscope and a short alias of it. Records before Phase 20 use the old name.

## Housekeeping
- Use `okfw move` and `okfw delete`. Do not use `mv` or `rm`. The okfw commands repair links and update the `index.md` listings.
- `status` is the OKF lifecycle field (`draft`, `stable` or `deprecated`). It is not the task state. Mark superseded knowledge `deprecated`. Do not delete it.
- Do not edit `index.md` or `log.md`. okfw writes them.
- Run `zmake wiki` before you commit wiki changes.

See [Development workflow](/development-workflow--01a1e96b8ed2.md).
