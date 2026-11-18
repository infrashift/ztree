---
id: "01a1ef92-fe88-73e6-83e8-f034251d44bd"
title: "ISSUE-012: A bounded regex engine for match predicates"
type: "Issue"
kind: "issue"
tags:
  - "issue"
  - "phase-10"
  - "regex"
  - "closed"
created: "2026-11-18T10:52:30-06:00"
timestamp: "2026-11-18T15:29:24-06:00"
description: "A bounded regex engine for match predicates."
---

# ISSUE-012: A bounded regex engine for match predicates

**Status:** closed · **Phase:** 10

## Description
Add a regex engine in Zig for the `#match?` predicate. It reads a subset of the RE2 syntax and runs a Pike VM in linear time ([ADR-0003](/decisions/adr-0003-adapt-the-nasa-power-of-10-rules-to-ztree--01a1e96b8f17.md)).

## Acceptance Criteria
- [x] `src/regex.zig` compiles a pattern into a bounded program and matches it with no recursion.
- [x] An ADR records the syntax subset. Other syntax gives a compile error.
- [x] A Go test compares ztree with the Go `regexp` package on a table of patterns and inputs, with the regexes of semscope.
- [x] `zmake check` reports zero errors and zero warnings.

## Resolution
- `src/regex.zig` compiles an ASCII subset of RE2 into a program of `Inst` and `Range` records with no pointers. A Pike VM matches in time O(text × program) ([ADR-0010](/decisions/adr-0010-a-pike-vm-for-an-re2-subset--01a1f0902c3e.md)).
- The compiler uses an explicit group stack and fixed arrays. A repetition copies its fragment. Limits: 4096 instructions, 4096 ranges, 256 nested groups and counts to 1000.
- The C ABI is version 4: `ztree_regex_match` and the status codes `ZTREE_ERROR_REGEX_SYNTAX` and `ZTREE_ERROR_REGEX_UNSUPPORTED`.
- `bindings/go/regex_test.go` compares ztree with `regexp` on 106 table patterns, on 20,000 random patterns and in `FuzzRegex`. The four semscope regexes compile and match as in Go. A 2-minute fuzz run did 11 million cases with no difference.

## Related
- [ADR-0007](/decisions/adr-0007-ztree-is-the-tree-sitter-service-of-lexis-and-semscope--01a1ef926073.md), [ADR-0010](/decisions/adr-0010-a-pike-vm-for-an-re2-subset--01a1f0902c3e.md)
