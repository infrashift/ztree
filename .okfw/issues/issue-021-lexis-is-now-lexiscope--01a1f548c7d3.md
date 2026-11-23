---
x-okfw-id: "01a1f548-c7d3-75de-b200-3e376d02e9e1"
title: "ISSUE-021: lexis is now lexiscope"
type: "Issue"
x-okfw-kind: "issue"
tags:
  - "issue"
  - "phase-20"
  - "docs"
  - "closed"
x-okfw-created: "2026-11-19T13:29:10-06:00"
x-okfw-timestamp: "2026-11-19T13:34:25-06:00"
description: "The documentation linter lexis has the new name lexiscope, so the docs-lexis task and the current documents of ztree use an old name."
---

# ISSUE-021: lexis is now lexiscope

**Status:** closed · **Phase:** 20

## Description
The documentation linter lexis has the official name lexiscope (lexiscope commit c8963c9, its ADR-0012). `lexis` stays as a short alias: `~/.local/bin/lexis` is a symbolic link to `lexiscope`. The repository moves to `github.com/infrashift/lexiscope`.

Phase 19 added the `docs-lexis` task with the variable `LEXIS` ([ADR-0018](/decisions/adr-0018-lexis-checks-the-documentation-with-a-repository-vocabulary--01a1f525ba3d.md)). The task and the current documents of ztree use the old name.

## Acceptance Criteria
- [x] `ZMakefile` and `Makefile` have the task `docs-lexiscope` and the variables `LEXISCOPE`, `DOCS_LEXISCOPE_PATHS` and `DOCS_LEXISCOPE_FLAGS`. `check` runs the task after `docs-style`.
- [x] `zmake -n check` and `make -n check` print the same commands.
- [x] With `LEXISCOPE` set to a command that does not exist, the task prints a message and passes.
- [x] `CLAUDE.md`, `PLAN.md`, `vocabulary.cue` and the current wiki concepts name the tool lexiscope.
- [x] ADR-0018 has a dated note about the new name.
- [x] The lexiscope scan of `CLAUDE.md`, `PLAN.md` and `.okfw` gives 0 errors, 0 warnings and 0 notes.
- [x] `zmake check` and `make check` pass.

## Notes
- Records keep the old name: the ADRs, the closed issues, the daily notes and the text of the completed phases of `PLAN.md`. The record files keep their names.
- The change needs no new ADR. This issue and the note in ADR-0018 record it.

## Related
- [ISSUE-020](/issues/issue-020-lexis-checks-the-documentation-of-ztree--01a1f524fb01.md): lexis checks the documentation of ztree.
- [Wiki conventions](/wiki-conventions--01a1e96b8eb9.md)
- [Development workflow](/development-workflow--01a1e96b8ed2.md)

## Resolution
`ZMakefile` and `Makefile` have the task `docs-lexiscope` and the variables `LEXISCOPE`, `DOCS_LEXISCOPE_PATHS` and `DOCS_LEXISCOPE_FLAGS`. `zmake -n check` and `make -n check` print the same commands. With `LEXISCOPE` set to `no-such-tool`, the task prints a message and passes. `CLAUDE.md`, `PLAN.md`, `vocabulary.cue`, the development workflow, the wiki conventions and the C ABI spec name the tool lexiscope. `CLAUDE.md` and the wiki conventions say that `lexis` is a short alias. ADR-0018 has a dated note. The lexiscope scan gives 0 errors, 0 warnings and 0 notes. `zmake check` and `make check` pass.
