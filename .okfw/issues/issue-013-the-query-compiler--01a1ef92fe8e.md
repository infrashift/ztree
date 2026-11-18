---
id: "01a1ef92-fe8e-76dc-a815-27170f3a9f39"
title: "ISSUE-013: The query compiler"
type: "Issue"
kind: "issue"
tags:
  - "issue"
  - "open"
  - "phase-11"
  - "query"
created: "2026-11-18T10:52:30-06:00"
timestamp: "2026-11-18T10:52:30-06:00"
description: "The query compiler."
---

# ISSUE-013: The query compiler

**Status:** open · **Phase:** 11

## Description
Parse the Tree-sitter query language and write a compiled query blob into caller memory ([ADR-0008](/decisions/adr-0008-a-flat-tree-and-a-compiled-query-blob-in-caller-memory--01a1ef929e5c.md)).

## Acceptance Criteria
- [ ] `src/query.zig` reads named and anonymous nodes, wildcards, fields, negated fields, captures, quantifiers, alternations, groups, anchors and the text predicates.
- [ ] An unknown node type, field, capture or predicate gives an error with its kind, row and column.
- [ ] `ztree_query_compile` is in `include/ztree.h`.
- [ ] `zmake check` reports zero errors and zero warnings.

## Related
- [ADR-0007](/decisions/adr-0007-ztree-is-the-tree-sitter-service-of-lexis-and-semscope--01a1ef926073.md), [ADR-0008](/decisions/adr-0008-a-flat-tree-and-a-compiled-query-blob-in-caller-memory--01a1ef929e5c.md)
