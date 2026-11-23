---
x-okfw-id: "01a1f56e-542c-7edc-b0b8-eec7da83fa4f"
title: "ISSUE-022: query-diff skips the queries with directives"
type: "Issue"
x-okfw-kind: "issue"
tags:
  - "issue"
  - "phase-21"
  - "query"
  - "test"
  - "closed"
x-okfw-created: "2026-11-19T14:10:10-06:00"
x-okfw-timestamp: "2026-11-19T14:22:07-06:00"
description: "query-diff does not run the queries that ztree rejects for their directives, so it compares no pattern of two corpus files, and the directives give two different error codes."
---

# ISSUE-022: query-diff skips the queries with directives

**Status:** closed · **Phase:** 21

## Description
The query differential step (`zig build query-diff`, [ISSUE-014](/issues/issue-014-query-execution--01a1ef92fe94.md)) runs a query only when ztree compiles the query and its predicates. ztree rejects the directives ([ADR-0007](/decisions/adr-0007-ztree-is-the-tree-sitter-service-of-lexis-and-semscope--01a1ef926073.md)), but `ts_query_new` accepts them. A check on 2026-11-19 found 22 queries that ztree rejects:

- 19 hand-written error cases. `ts_query_new` gives the same error kind and offset for each of them. `tests/query_test.zig` already compares these errors in `zig build test`.
- `tests/queries/go/tags.scm` with `#strip!` and `#set-adjacent!`, and `tests/queries/rust/injections.scm` with `#set!`. query-diff compares no pattern of these two files.
- One hand-written case with `#set!`.

The comparison of query-diff skips the text predicates, so query-diff can run these queries without their predicates.

The error codes of the directives also differ. `#set!`, `#is?` and `#is-not?` give `ZTREE_QUERY_ERROR_UNSUPPORTED`. Each other directive, for example `#strip!`, gives `ZTREE_QUERY_ERROR_PREDICATE`. The C ABI spec gives `ZTREE_QUERY_ERROR_UNSUPPORTED` to a directive.

## Acceptance Criteria
- [x] query-diff runs each query that ztree rejects only for its predicates, without the predicates.
- [x] query-diff compares the patterns of all 12 files of `tests/queries/`, and prints the number of queries that it runs without predicates.
- [x] Each predicate name that ends in `!` gives `ZTREE_QUERY_ERROR_UNSUPPORTED`. An unknown name that ends in `?` gives `ZTREE_QUERY_ERROR_PREDICATE`.
- [x] Tests show the error codes of `#set!`, `#strip!`, `#set-adjacent!` and an unknown predicate.
- [x] `include/ztree.h` and the C ABI spec state the rule for the directives.
- [x] `zmake check` and `make check` pass.

## Notes
- The new error code is a change of the C ABI. Before the change, find each use of `ZTREE_QUERY_ERROR_PREDICATE` in semscope.
- Record the rule for the directives as a dated note in [ADR-0011](/decisions/adr-0011-a-structural-port-of-the-reference-query-compiler--01a1f0a8133a.md), or in a new ADR.

## Related
- [ztree C ABI](/specs/ztree-c-abi--01a1ec92dc4f.md)
- [Development workflow](/development-workflow--01a1e96b8ed2.md)

## Resolution
query-diff runs a query without its text predicates when ztree rejects only a predicate. It prints the count of these queries, and it fails when a file of `tests/queries/` does not take part. The step now compares all 12 files: 4,824 runs against 4,539 before, with 3 queries without their predicates and 19 queries that do not compile. Each match and each capture equals the reference.

`src/query_predicates.zig` gives `unsupported` to each predicate name that ends in `!`. A test of `ztree_query_compile` and a test of the Go binding show the codes of `#set!`, `#strip!`, `#set-adjacent!`, `#nope!` and `#is?`. The test of an unknown predicate `#foo?` still expects `predicate`. `include/ztree.h`, the C ABI spec and a dated note in ADR-0011 state the rule. semscope does not read the error kind of a query, so the change does not affect it. `zmake check` and `make check` pass.
