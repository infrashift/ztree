---
id: "01a1ef92-fe81-7e8b-98a7-7cd25246ff59"
title: "ISSUE-011: The flat tree and the node API"
type: "Issue"
kind: "issue"
tags:
  - "issue"
  - "open"
  - "phase-9"
  - "tree"
created: "2026-11-18T10:52:30-06:00"
timestamp: "2026-11-18T10:52:30-06:00"
description: "The flat tree and the node API."
---

# ISSUE-011: The flat tree and the node API

**Status:** open · **Phase:** 9

## Description
Write the finished tree as a flat array of node records. Export it through the C ABI. Add a Go node API with the method names of go-tree-sitter ([ADR-0008](/decisions/adr-0008-a-flat-tree-and-a-compiled-query-blob-in-caller-memory--01a1ef929e5c.md)).

## Acceptance Criteria
- [ ] `src/flat.zig` flattens a tree with one walk and an explicit stack.
- [ ] An S-expression of the flat tree equals `tree.writeSexp` for each conformance and differential tree.
- [ ] `ztree_parse` and the language metadata functions are in `include/ztree.h`.
- [ ] The differential step compares each flat node with the reference `TSNode`: kind, symbol, range, points, flags, parent and each field child.
- [ ] The Go binding has `Parser`, `Tree`, `Node` and `TreeCursor`, with tests under the race detector.
- [ ] `zmake check` reports zero errors and zero warnings.

## Related
- [ADR-0007](/decisions/adr-0007-ztree-is-the-tree-sitter-service-of-lexis-and-semscope--01a1ef926073.md), [ADR-0008](/decisions/adr-0008-a-flat-tree-and-a-compiled-query-blob-in-caller-memory--01a1ef929e5c.md)
