---
x-okfw-id: "01a1e96b-8f58-7e69-8e12-78aaa8f0b1c6"
title: "ISSUE-003: Parser core with the subtree arena and the GLR stack"
type: "Issue"
x-okfw-kind: "issue"
tags:
  - "issue"
  - "phase-3"
  - "parser"
  - "closed"
x-okfw-created: "2026-11-17T06:11:42-06:00"
x-okfw-timestamp: "2026-11-17T16:58:13-06:00"
description: "Parser core with the subtree arena and the GLR stack."
---

# ISSUE-003: Parser core with the subtree arena and the GLR stack

**Status:** closed · **Phase:** 3

## Description
Add the subtree arena, the GLR stack, the LR loop and the external scanner bridge.

## Acceptance Criteria
- [x] `src/subtree.zig` allocates subtrees from one arena with hard limits.
- [x] `src/stack.zig` merges equal versions. The parser keeps at most 6 versions after each round.
- [x] `src/parser.zig` runs shift, reduce and accept until the parse ends.
- [x] The scanner bridge calls create, scan, serialize and deserialize for Python and Rust.
- [x] Valid sample files for each grammar parse with no ERROR node.
- [x] `zmake check` reports zero errors and zero warnings.

## Notes
No recursion. Each loop has a hard limit.

## Related
- [ADR-0003](/decisions/adr-0003-adapt-the-nasa-power-of-10-rules-to-ztree--01a1e96b8f17.md) (Power of 10) and [ADR-0004](/decisions/adr-0004-a-batch-tree-sitter-runtime-for-abi-14-and-15--01a1e96b8f27.md) (scope).
- [ztree architecture overview](/architecture/ztree-architecture-overview--01a1e96b8ee5.md)

## Resolution
- `src/subtree.zig`, `src/stack.zig`, `src/language.zig` and `src/parser.zig` port the reference runtime. [ADR-0005](/decisions/adr-0005-one-arena-per-parse-no-reference-counts-and-no-balance-step--01a1ebbb7488.md) records the differences.
- The reference runtime also recovers from errors on valid input. After an accept, the other stack versions fail at the end of the input and recover. So Phase 3 includes the recovery code of phase 4 (`src/recover.zig`).
- The stack holds at most 6 versions after each round. During a round, it can hold up to 10 more, as in the reference. A hard limit of 64 versions guards the stack.
- `tests/parser_test.zig` parses 436 inputs with both runtimes and compares each flattened node. The inputs are each corpus example of four grammars, 16 source files and 11 inputs with keywords or syntax errors. 35 corpus trees contain errors, and they match too.
- Mutation checks: each of these changes makes the test fail.
  - A reversed tree order.
  - A sort of the reduce actions in the wrong order.
  - A lost dynamic precedence.
  - A disabled token cache.
  - A disabled recovery strategy.
- One path has no test: the switch from an invalid keyword to the word token. No input reaches it. A search of each keyword in 24 contexts in each grammar found no input.
