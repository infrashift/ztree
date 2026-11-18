---
id: "01a1ef92-fe94-7afc-8922-90cd0ceddb73"
title: "ISSUE-014: Query execution"
type: "Issue"
kind: "issue"
tags:
  - "issue"
  - "open"
  - "phase-12"
  - "query"
created: "2026-11-18T10:52:30-06:00"
timestamp: "2026-11-18T10:52:30-06:00"
description: "Query execution."
---

# ISSUE-014: Query execution

**Status:** open · **Phase:** 12

## Description
Match a compiled query against a flat tree. Give the matches in the order of the reference runtime ([ADR-0008](/decisions/adr-0008-a-flat-tree-and-a-compiled-query-blob-in-caller-memory--01a1ef929e5c.md)).

## Acceptance Criteria
- [ ] `src/query_exec.zig` matches with bounded state and no recursion.
- [ ] `ztree_query_exec` is in `include/ztree.h`.
- [ ] The Go binding has `NewQuery`, `QueryCursor.Matches` and the capture names.
- [ ] `zig build query-diff` compares the matches with the reference query cursor. `zmake check` runs it.
- [ ] `zmake check` reports zero errors and zero warnings.

## Related
- [ADR-0007](/decisions/adr-0007-ztree-is-the-tree-sitter-service-of-lexis-and-semscope--01a1ef926073.md), [ADR-0008](/decisions/adr-0008-a-flat-tree-and-a-compiled-query-blob-in-caller-memory--01a1ef929e5c.md)
