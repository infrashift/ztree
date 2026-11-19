---
id: "01a1f524-fb01-77df-8f0d-556f8405ebf1"
title: "ISSUE-020: lexis checks the documentation of ztree"
type: "Issue"
kind: "issue"
tags:
  - "issue"
  - "phase-19"
  - "docs"
  - "closed"
created: "2026-11-19T12:50:03-06:00"
timestamp: "2026-11-19T12:52:06-06:00"
description: "A scan of the ztree documentation with the ste-100 ruleset of lexis gives 122 warnings, and no gate runs lexis."
---

# ISSUE-020: lexis checks the documentation of ztree

**Status:** closed · **Phase:** 19

## Description
lexis checks documentation against ASD-STE100 rules. lexis loads ztree for the comments of source files. On 2026-11-19, a scan of `CLAUDE.md`, `PLAN.md` and `.okfw` with the `ste-100` ruleset of lexis gave 0 errors and 122 warnings in 43 files. `scripts/ste-check.py` passes on the same files, because it has no rules for noun forms of verbs, `-ing` forms or marketing words.

Most warnings name technical terms of ztree, for example "conformance" (the conformance step) and "repetition" (a hidden repetition subtree). Other warnings are faults of style: `therefore`, `thus`, `modern`, `is done` and `Implement`.

## Acceptance Criteria
- [x] `vocabulary.cue` holds the technical terms of ztree, each with a comment that names its concept.
- [x] The scan of `CLAUDE.md`, `PLAN.md` and `.okfw` with `vocabulary.cue` gives 0 errors, 0 warnings and 0 notes.
- [x] `zmake docs-lexis` runs the scan with `--fail-on note`, so each finding fails it. When lexis is not on the PATH, it passes with a message.
- [x] `ZMakefile` and `Makefile` have the same target, and `zmake check` runs it after `docs-style`.
- [x] An ADR records the decision.

## Notes
- The scan excludes `.okfw/daily`, `.okfw/ephemeral`, `index.md` and `log.md`, as the self-check of lexis does.
- Code comments in `src/`, `tools/`, `bindings/`, `include/` and `tests/` are outside the scope of this issue.

## Related
- [Wiki conventions](/wiki-conventions--01a1e96b8eb9.md)
- [Development workflow](/development-workflow--01a1e96b8ed2.md)
- [ADR-0007](/decisions/adr-0007-ztree-is-the-tree-sitter-service-of-lexis-and-semscope--01a1ef926073.md): ztree is the Tree-sitter service of lexis and semscope.

## Resolution
`vocabulary.cue` holds 19 terms of ztree, each with a comment that names its concept. The terms cover 63 of the 122 warnings. The authors reworded the other 59 findings. STE-100-05 gave 8 of them, STE-100-06 gave 19 and STE-100-07 gave 27. STE-100-09 gave 2, and STE-100-10 gave 3. The 18 `Tracking:` labels of `PLAN.md` became `Issue:`. `zmake docs-lexis` runs the scan with `--fail-on note` when lexis is on the PATH ([ADR-0018](/decisions/adr-0018-lexis-checks-the-documentation-with-a-repository-vocabulary--01a1f525ba3d.md)). The scan gives 0 errors, 0 warnings and 0 notes. With `LEXIS` set to a command that does not exist, the task prints a message and passes.
