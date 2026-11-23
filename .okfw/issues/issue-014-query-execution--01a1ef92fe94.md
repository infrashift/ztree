---
x-okfw-id: "01a1ef92-fe94-7afc-8922-90cd0ceddb73"
title: "ISSUE-014: Query execution"
type: "Issue"
x-okfw-kind: "issue"
tags:
  - "issue"
  - "phase-12"
  - "query"
  - "closed"
x-okfw-created: "2026-11-18T10:52:30-06:00"
x-okfw-timestamp: "2026-11-18T15:56:02-06:00"
description: "Query execution."
---

# ISSUE-014: Query execution

**Status:** closed · **Phase:** 12

## Description
Match a compiled query against a flat tree. Give the matches in the order of the reference runtime ([ADR-0008](/decisions/adr-0008-a-flat-tree-and-a-compiled-query-blob-in-caller-memory--01a1ef929e5c.md)).

## Acceptance Criteria
- [x] `src/query_exec.zig` matches with bounded state and no recursion.
- [x] `ztree_query_exec` is in `include/ztree.h`.
- [x] The Go binding has `NewQuery`, `QueryCursor.Matches` and the capture names.
- [x] `zig build query-diff` compares the matches with the reference query cursor. `zmake check` runs it.
- [x] `zmake check` reports zero errors and zero warnings.

## Resolution
- `src/query_exec.zig` ports `ts_query_cursor__advance` and `ts_query_cursor_next_match` over the flat tree ([ADR-0012](/decisions/adr-0012-a-port-of-the-reference-query-cursor-over-the-flat-tree--01a1f111feba.md)). It runs the text predicates as go-tree-sitter does.
- The flat tree keeps the cursor status of each node: `status_field_id` and `ZTREE_NODE_LATER_FIELD`. The differential step compares both values with `ts_tree_cursor_current_status`.
- The C ABI is version 6: `ztree_query_exec`, `ztree_match`, `ztree_capture` and the blob accessors.
- The Go binding has `NewQuery`, `Query`, `QueryError`, `QueryCursor.Matches`, `QueryMatches` and `ErrLanguageMismatch`. The tests run the `ast_query` rules of semscope.
- `zig build query-diff` compares each match with the reference query cursor. `zmake check` runs it. A run over `go/ast` gives 256,583 equal matches.

## Related
- [ADR-0007](/decisions/adr-0007-ztree-is-the-tree-sitter-service-of-lexis-and-semscope--01a1ef926073.md), [ADR-0008](/decisions/adr-0008-a-flat-tree-and-a-compiled-query-blob-in-caller-memory--01a1ef929e5c.md)
