---
id: "01a1e96b-8f79-7815-b30c-f126009fdc2b"
title: "ISSUE-005: Tree API, cursor and comment extraction"
type: "Issue"
kind: "issue"
tags:
  - "issue"
  - "open"
  - "phase-5"
  - "tree"
created: "2026-11-17T06:11:42-06:00"
timestamp: "2026-11-17T06:11:42-06:00"
description: "Tree API, cursor and comment extraction."
---

# ISSUE-005: Tree API, cursor and comment extraction

**Status:** open · **Phase:** 5

## Description
Build the node and cursor API, the S-expression output and comment extraction.

## Acceptance Criteria
- [ ] `src/tree.zig` gives nodes and an iterative cursor.
- [ ] The S-expression output matches the format of the reference runtime.
- [ ] `src/comments.zig` maps each language to its comment node types.
- [ ] `extractComments(lang, src, out)` returns the spans in source order.
- [ ] Tests cover line comments, block comments and doc comments in each language.
- [ ] `zmake check` reports zero errors and zero warnings.

## Notes
A span holds the byte range and the start and end points.

## Related
- [ADR-0003](/decisions/adr-0003-adapt-the-nasa-power-of-10-rules-to-ztree--01a1e96b8f17.md) (Power of 10) and [ADR-0004](/decisions/adr-0004-a-batch-tree-sitter-runtime-for-abi-14-and-15--01a1e96b8f27.md) (scope).
- [ztree architecture overview](/architecture/ztree-architecture-overview--01a1e96b8ee5.md)
