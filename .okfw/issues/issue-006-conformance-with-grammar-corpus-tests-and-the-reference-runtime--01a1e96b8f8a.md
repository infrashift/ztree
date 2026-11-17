---
id: "01a1e96b-8f8a-71c9-b3ed-b1d2e3a79d80"
title: "ISSUE-006: Conformance with grammar corpus tests and the reference runtime"
type: "Issue"
kind: "issue"
tags:
  - "issue"
  - "open"
  - "phase-6"
  - "conformance"
created: "2026-11-17T06:11:42-06:00"
timestamp: "2026-11-17T06:11:42-06:00"
description: "Conformance with grammar corpus tests and the reference runtime."
---

# ISSUE-006: Conformance with grammar corpus tests and the reference runtime

**Status:** open · **Phase:** 6

## Description
Compare ztree with the grammar corpus tests and with the reference runtime.

## Acceptance Criteria
- [ ] `zig build conformance` runs each `test/corpus/*.txt` file of each grammar.
- [ ] Each corpus test matches the expected S-expression.
- [ ] A differential step parses real source files with both runtimes and compares the trees.
- [ ] `ZMakefile` and `Makefile` have a `conformance` target, and `check` runs it.
- [ ] `zmake check` reports zero errors and zero warnings.

## Notes
tree-sitter-zig v1.1.2 has no `test/corpus/` directory. For Zig, only the differential step applies.
Record each corpus test that ztree skips, and the reason, in this issue.

## Related
- [ADR-0003](/decisions/adr-0003-adapt-the-nasa-power-of-10-rules-to-ztree--01a1e96b8f17.md) (Power of 10) and [ADR-0004](/decisions/adr-0004-a-batch-tree-sitter-runtime-for-abi-14-and-15--01a1e96b8f27.md) (scope).
- [ztree architecture overview](/architecture/ztree-architecture-overview--01a1e96b8ee5.md)
