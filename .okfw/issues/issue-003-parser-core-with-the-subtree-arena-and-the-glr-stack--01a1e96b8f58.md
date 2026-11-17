---
id: "01a1e96b-8f58-7e69-8e12-78aaa8f0b1c6"
title: "ISSUE-003: Parser core with the subtree arena and the GLR stack"
type: "Issue"
kind: "issue"
tags:
  - "issue"
  - "open"
  - "phase-3"
  - "parser"
created: "2026-11-17T06:11:42-06:00"
timestamp: "2026-11-17T06:11:42-06:00"
description: "Parser core with the subtree arena and the GLR stack."
---

# ISSUE-003: Parser core with the subtree arena and the GLR stack

**Status:** open · **Phase:** 3

## Description
Implement the subtree arena, the GLR stack, the LR loop and the external scanner bridge.

## Acceptance Criteria
- [ ] `src/subtree.zig` allocates subtrees from one arena with hard limits.
- [ ] `src/stack.zig` holds at most 6 stack versions and merges equal versions.
- [ ] `src/parser.zig` runs shift, reduce and accept until the parse ends.
- [ ] The scanner bridge calls create, scan, serialize and deserialize for Python and Rust.
- [ ] Valid sample files for each grammar parse with no ERROR node.
- [ ] `zmake check` reports zero errors and zero warnings.

## Notes
No recursion. Each loop has a hard limit.

## Related
- [ADR-0003](/decisions/adr-0003-adapt-the-nasa-power-of-10-rules-to-ztree--01a1e96b8f17.md) (Power of 10) and [ADR-0004](/decisions/adr-0004-a-batch-tree-sitter-runtime-for-abi-14-and-15--01a1e96b8f27.md) (scope).
- [ztree architecture overview](/architecture/ztree-architecture-overview--01a1e96b8ee5.md)
