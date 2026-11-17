---
id: "01a1e96b-8f69-73eb-84fb-c06917e2f98d"
title: "ISSUE-004: Error recovery with ERROR and MISSING nodes"
type: "Issue"
kind: "issue"
tags:
  - "issue"
  - "open"
  - "phase-4"
  - "recovery"
created: "2026-11-17T06:11:42-06:00"
timestamp: "2026-11-17T06:11:42-06:00"
description: "Error recovery with ERROR and MISSING nodes."
---

# ISSUE-004: Error recovery with ERROR and MISSING nodes

**Status:** open · **Phase:** 4

## Description
Recover from syntax errors with the cost model of the reference runtime.

## Acceptance Criteria
- [ ] `src/recover.zig` adds ERROR and MISSING nodes and skips tokens.
- [ ] Invalid sample files for each grammar produce the same tree as the reference runtime.
- [ ] A recovery that reaches its cost limit returns an error.
- [ ] `zmake check` reports zero errors and zero warnings.

## Notes
Comments in a file with syntax errors still come out in phase 5.

## Related
- [ADR-0003](/decisions/adr-0003-adapt-the-nasa-power-of-10-rules-to-ztree--01a1e96b8f17.md) (Power of 10) and [ADR-0004](/decisions/adr-0004-a-batch-tree-sitter-runtime-for-abi-14-and-15--01a1e96b8f27.md) (scope).
- [ztree architecture overview](/architecture/ztree-architecture-overview--01a1e96b8ee5.md)
