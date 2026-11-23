---
x-okfw-id: "01a1ef92-fe81-7e8b-98a7-7cd25246ff59"
title: "ISSUE-011: The flat tree and the node API"
type: "Issue"
x-okfw-kind: "issue"
tags:
  - "issue"
  - "phase-9"
  - "tree"
  - "closed"
x-okfw-created: "2026-11-18T10:52:30-06:00"
x-okfw-timestamp: "2026-11-18T15:13:26-06:00"
description: "The flat tree and the node API."
---

# ISSUE-011: The flat tree and the node API

**Status:** closed · **Phase:** 9

## Description
Write the finished tree as a flat array of node records. Export it through the C ABI. Add a Go node API with the method names of go-tree-sitter ([ADR-0008](/decisions/adr-0008-a-flat-tree-and-a-compiled-query-blob-in-caller-memory--01a1ef929e5c.md)).

## Acceptance Criteria
- [x] `src/flat.zig` flattens a tree with one walk and an explicit stack.
- [x] An S-expression of the flat tree equals `tree.writeSexp` for each conformance and differential tree. [ADR-0009](/decisions/adr-0009-field-overrides-and-the-node-rules-of-the-flat-tree--01a1f080b1ed.md) changes the reference to `tree.writeVisibleSexp`: a cursor does not visit a hidden MISSING node.
- [x] `ztree_parse` and the language metadata functions are in `include/ztree.h`.
- [x] The differential step compares each flat node with the reference `TSNode`: kind, symbol, range, points, flags, parent and each field child.
- [x] The Go binding has `Parser`, `Tree`, `Node` and `TreeCursor`, with tests under the race detector.
- [x] `zmake check` reports zero errors and zero warnings.

## Resolution
- `src/flat.zig` writes one 48-byte record for each node that a cursor visits. A second pass runs the algorithm of `ts_node_child_by_field_id` with an explicit stack and writes field overrides ([ADR-0009](/decisions/adr-0009-field-overrides-and-the-node-rules-of-the-flat-tree--01a1f080b1ed.md)).
- The C ABI is version 3: `ztree_parse`, `ztree_field_override` and six language functions. See the [C ABI spec](/specs/ztree-c-abi--01a1ec92dc4f.md).
- The Go binding has `NewLanguage`, `Parser`, `Tree`, `Node` and `TreeCursor`. A node method reads Go memory only. The tests compare 8,110 functions of GOROOT files with `go/ast`.
- The conformance step compares the S-expression of each flat tree. The differential step compares each record, the parent, the siblings, the children and each field lookup with the reference `TSNode` API. `tests/flat/` holds a sample for each rule of ADR-0009.
- A run on 903 outside files (Go, Python, Rust, Zig, libstdc++ and semscope) compared 3.17 million nodes and 1 million field lookups. One file failed in the parser: [ISSUE-016](/issues/issue-016-the-glr-stack-limit-of-64-heads--01a1f080f76c.md).

## Related
- [ADR-0007](/decisions/adr-0007-ztree-is-the-tree-sitter-service-of-lexis-and-semscope--01a1ef926073.md), [ADR-0008](/decisions/adr-0008-a-flat-tree-and-a-compiled-query-blob-in-caller-memory--01a1ef929e5c.md), [ADR-0009](/decisions/adr-0009-field-overrides-and-the-node-rules-of-the-flat-tree--01a1f080b1ed.md)
