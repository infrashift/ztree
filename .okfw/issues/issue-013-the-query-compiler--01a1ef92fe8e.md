---
id: "01a1ef92-fe8e-76dc-a815-27170f3a9f39"
title: "ISSUE-013: The query compiler"
type: "Issue"
kind: "issue"
tags:
  - "issue"
  - "phase-11"
  - "query"
  - "closed"
created: "2026-11-18T10:52:30-06:00"
timestamp: "2026-11-18T15:55:46-06:00"
description: "The query compiler."
---

# ISSUE-013: The query compiler

**Status:** closed · **Phase:** 11

## Description
Parse the Tree-sitter query language and write a compiled query blob into caller memory ([ADR-0008](/decisions/adr-0008-a-flat-tree-and-a-compiled-query-blob-in-caller-memory--01a1ef929e5c.md)).

## Acceptance Criteria
- [x] `src/query.zig` reads named and anonymous nodes, wildcards, fields, negated fields, captures, quantifiers, alternations, groups, anchors and the text predicates.
- [x] An unknown node type, field, capture or predicate gives an error with its kind, row and column.
- [x] `ztree_query_compile` is in `include/ztree.h`.
- [x] `zmake check` reports zero errors and zero warnings.

## Resolution
- `src/query.zig` and `src/query_analysis.zig` port `ts_query_new` and its parse-table analysis ([ADR-0011](/decisions/adr-0011-a-structural-port-of-the-reference-query-compiler--01a1f0a8133a.md)). `src/query_predicates.zig` checks the text predicates as go-tree-sitter does. `src/query_blob.zig` writes the blob.
- The C ABI is version 5: `ztree_query_compile`, `ztree_query_error` and `ZTREE_ERROR_QUERY`.
- `tests/query_test.zig` compares a dump of each compiled query with the private state of the reference `TSQuery`. 3,148 queries match: the upstream `queries/*.scm` files of five grammars, 59 hand-written queries and their mutations. 2,615 of them are error cases with equal kinds and offsets.
- Supertypes and directives give `ZTREE_QUERY_ERROR_UNSUPPORTED` (ADR-0007).

## Related
- [ADR-0007](/decisions/adr-0007-ztree-is-the-tree-sitter-service-of-lexis-and-semscope--01a1ef926073.md), [ADR-0008](/decisions/adr-0008-a-flat-tree-and-a-compiled-query-blob-in-caller-memory--01a1ef929e5c.md)
