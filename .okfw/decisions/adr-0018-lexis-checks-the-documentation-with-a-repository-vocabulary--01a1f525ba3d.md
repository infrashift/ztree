---
id: "01a1f525-ba3d-7eef-bda1-862a3dd7da82"
title: "ADR-0018: lexis checks the documentation with a repository vocabulary"
type: "ADR"
tags:
  - "adr"
  - "docs"
  - "lexis"
created: "2026-11-19T12:50:52-06:00"
timestamp: "2026-11-19T12:50:52-06:00"
description: "zmake docs-lexis scans CLAUDE.md, PLAN.md and the wiki with lexis and vocabulary.cue, fails on each finding, and runs only when lexis is on the PATH."
---

# ADR-0018: lexis checks the documentation with a repository vocabulary

**Status:** Accepted
**Date:** 2026-11-19
**Source:** [ISSUE-020](/issues/issue-020-lexis-checks-the-documentation-of-ztree--01a1f524fb01.md). User decision on 2026-11-19: add a repository vocabulary, reword the other text and add a gate.

## Context
lexis checks documentation against ASD-STE100 rules. Its `ste-100` ruleset has more rules than `scripts/ste-check.py`: noun forms of verbs (STE-100-06), `-ing` forms (STE-100-07) and marketing words (STE-100-09). A scan of `CLAUDE.md`, `PLAN.md` and `.okfw` gave 0 errors and 122 warnings in 43 files. Most warnings named technical terms of ztree, for example "conformance" and "repetition". The others were faults of style, for example `therefore`, `modern`, `is done` and `Implement`.

lexis links `libztree.a` through cgo, and its build runs `zig build lib` in this checkout. lexis made the same decision for its own self-check in its ADR-0009, "The self-check fails on each finding, with a repository vocabulary".

## Decision
- `vocabulary.cue` in the repository root holds the technical terms of ztree. Each term has a comment that names its concept. The scan loads it with `--ruleset ste-100 --ruleset vocabulary.cue`.
- A term goes into the vocabulary only when it names a concept of the project, a tool or a standard. The authors reword other text. The fix of the 122 warnings put 19 terms in the vocabulary and reworded the other 59 findings. The `Tracking:` label of `PLAN.md` became `Issue:`, as in lexis.
- `zmake docs-lexis` scans `CLAUDE.md`, `PLAN.md` and `.okfw` with `--fail-on note`, so each finding fails it. It excludes `.okfw/daily`, `.okfw/ephemeral`, `index.md` and `log.md`, as lexis does. `zmake check` runs it after `docs-style`.
- The task runs lexis only when lexis is on the PATH. Otherwise it prints a message and passes. `LEXIS` sets the command.

## Consequences
- New prose in `CLAUDE.md`, `PLAN.md` and the wiki must pass the extended rules of lexis and `scripts/ste-check.py`.
- ztree takes no build dependency on lexis. lexis links ztree, so a hard dependency makes a cycle: a new ztree needs a lexis binary, and a new lexis needs a ztree library.
- A host without lexis does not run the check. The lexis self-check and the ztree hosts with lexis find the faults.
- The vocabulary applies to STE-100-06 and STE-100-07 only. For other rules, such as STE-100-05 (unapproved words) and STE-100-10 (passive voice), the authors reword the text.
- Code comments in `src/`, `tools/`, `bindings/`, `include/` and `tests/` stay outside the scan.

## Alternatives considered
- **Put each flagged word in the vocabulary.** Rejected: a word such as `therefore` or `modern` is a fault, not a term.
- **Fail when lexis is not on the PATH.** Rejected: ztree then needs a lexis binary, and lexis needs `libztree.a` to build.
- **Report the findings, but do not fail.** Rejected: new findings then hide in the old ones, and each gate of ztree is free of warnings.

## Related
- [Wiki conventions](/wiki-conventions--01a1e96b8eb9.md)
- [ADR-0007](/decisions/adr-0007-ztree-is-the-tree-sitter-service-of-lexis-and-semscope--01a1ef926073.md): ztree is the Tree-sitter service of lexis and semscope.
