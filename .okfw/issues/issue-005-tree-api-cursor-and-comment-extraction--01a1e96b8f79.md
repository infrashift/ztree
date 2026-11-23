---
x-okfw-id: "01a1e96b-8f79-7815-b30c-f126009fdc2b"
title: "ISSUE-005: Tree API, cursor and comment extraction"
type: "Issue"
x-okfw-kind: "issue"
tags:
  - "issue"
  - "phase-5"
  - "tree"
  - "closed"
x-okfw-created: "2026-11-17T06:11:42-06:00"
x-okfw-timestamp: "2026-11-17T17:55:30-06:00"
description: "Tree API, cursor and comment extraction."
---

# ISSUE-005: Tree API, cursor and comment extraction

**Status:** closed · **Phase:** 5

## Description
Build the node and cursor API, the S-expression output and comment extraction.

## Acceptance Criteria
- [x] `src/tree.zig` gives nodes and an iterative cursor.
- [x] The S-expression output matches the format of the reference runtime.
- [x] `src/comments.zig` maps each language to its comment node types.
- [x] `extractComments(lang, src, out)` returns the spans in source order.
- [x] Tests cover line comments, block comments and doc comments in each language.
- [x] `zmake check` reports zero errors and zero warnings.

## Notes
A span holds the byte range and the start and end points.

## Related
- [ADR-0003](/decisions/adr-0003-adapt-the-nasa-power-of-10-rules-to-ztree--01a1e96b8f17.md) (Power of 10) and [ADR-0004](/decisions/adr-0004-a-batch-tree-sitter-runtime-for-abi-14-and-15--01a1e96b8f27.md) (scope).
- [ztree architecture overview](/architecture/ztree-architecture-overview--01a1e96b8ee5.md)

## Resolution
- `src/tree.zig` holds `Node`, the `Walker` over the visible nodes and `writeSexp`. The walker and the writer use explicit stacks.
- `src/comments.zig` holds the comment node types and `extractComments`. Go, Zig, Python and C use `comment`. Rust uses `line_comment` and `block_comment`.
- A Rust line comment ends before the newline. A Rust doc comment includes the newline, because the grammar puts the newline in its `doc_comment` child.
- `tests/parser_test.zig` compares three outputs with the reference runtime for each input:
  - `writeSexp` against `ts_node_string`.
  - The walk against a `TSTreeCursor` walk: type, byte range and named flag of each node.
  - The comment spans against a `TSTreeCursor` walk. The inputs hold 399 comments.
- Mutation checks: these changes each make a test fail.
  - Inherited field names dropped.
  - Aliases ignored in the walk.
  - Child sizes left out of the walk offsets.
  - Extras counted as structural children (a Go input with a comment after a dot covers it).
  - MISSING names always in quotes.
  - A wrong output for a newline in an ERROR leaf (a unit test of `writeChar` covers it).
- A lesson about the mutation checks: judge a mutant by the exit code of `zig build test`. A search for the word "failed" in the output also finds the line that the build prints when a test writes to stderr.
