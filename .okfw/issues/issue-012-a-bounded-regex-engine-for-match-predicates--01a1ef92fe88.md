---
id: "01a1ef92-fe88-73e6-83e8-f034251d44bd"
title: "ISSUE-012: A bounded regex engine for match predicates"
type: "Issue"
kind: "issue"
tags:
  - "issue"
  - "open"
  - "phase-10"
  - "regex"
created: "2026-11-18T10:52:30-06:00"
timestamp: "2026-11-18T10:52:30-06:00"
description: "A bounded regex engine for match predicates."
---

# ISSUE-012: A bounded regex engine for match predicates

**Status:** open · **Phase:** 10

## Description
Add a regex engine in Zig for the `#match?` predicate. It reads a subset of the RE2 syntax and runs a Pike VM in linear time ([ADR-0003](/decisions/adr-0003-adapt-the-nasa-power-of-10-rules-to-ztree--01a1e96b8f17.md)).

## Acceptance Criteria
- [ ] `src/regex.zig` compiles a pattern into a bounded program and matches it with no recursion.
- [ ] An ADR records the syntax subset. Other syntax gives a compile error.
- [ ] A Go test compares ztree with the Go `regexp` package on a table of patterns and inputs, with the regexes of semscope.
- [ ] `zmake check` reports zero errors and zero warnings.

## Related
- [ADR-0007](/decisions/adr-0007-ztree-is-the-tree-sitter-service-of-lexis-and-semscope--01a1ef926073.md)
