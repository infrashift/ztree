---
id: "01a1f080-f76c-775c-a591-dd7bd7e7886c"
title: "ISSUE-016: The GLR stack limit of 64 heads"
type: "Issue"
kind: "issue"
tags:
  - "issue"
  - "parser"
  - "phase-14"
  - "closed"
created: "2026-11-18T15:12:26-06:00"
timestamp: "2026-11-19T02:34:40-06:00"
description: "The C grammar needs more than 64 stack heads for one libstdc++ header, so ztree returns TooManyVersions where the reference runtime gives a tree."
---

# ISSUE-016: The GLR stack limit of 64 heads

**Status:** closed · **Phase:** 14

## Description
The GLR stack of ztree holds at most `max_heads` = 64 heads (`src/stack.zig`). The reference runtime has no such limit. A reduce can split the stack into more versions for a short time. The parser then condenses them to 6. The C grammar on the libstdc++ header `/usr/include/c++/13/bits/stl_algobase.h` (C++ code read as C, with many syntax errors) needs more than 64 heads. ztree then returns `TooManyVersions`, and the C ABI returns `ZTREE_ERROR_LIMIT_REACHED`. The reference runtime gives a tree.

With `max_heads` = 256, ztree gives the same tree as the reference for this file. The differential step found the file during [ISSUE-011](/issues/issue-011-the-flat-tree-and-the-node-api--01a1ef92fe81.md). It is the only failure in 903 files.

The file also stops a semscope scan of the libstdc++ headers with ztree: `Parse` gives `ErrLimitReached`, and semscope stops at the first file error. See the [guide to migrate semscope](/guides/migrate-semscope-from-go-tree-sitter-to-ztree--01a1f122b34b.md).

## Acceptance Criteria
- [x] Find the largest head count that the reference runtime reaches on the differential corpus and on large C and C++ trees.
- [x] Set `max_heads` from that count with a margin, and record the bound in an ADR ([ADR-0003](/decisions/adr-0003-adapt-the-nasa-power-of-10-rules-to-ztree--01a1e96b8f17.md) needs a fixed bound).
- [x] Add a test sample that needs more than 64 heads.

## Resolution
- A temporary counter recorded the largest head count of each parse on 73,701 files of all six grammars. The largest count is 90, on `src/base/template-utils.h` of V8. Three files need more than 64 heads. Each is C++ code that the C grammar reads.
- `limits.max_stack_heads` in `src/root.zig` is 256, and `stack.max_heads` reads it. [ADR-0013](/decisions/adr-0013-a-bound-of-256-glr-stack-heads--01a1f2f0124a.md) records the bound and the measured counts.
- `tests/parser_test.zig` has two inputs that need 87 and 71 heads. With 64 heads, the test fails with `TooManyVersions`.
- A release differential run on libstdc++ `bits/`, V8 `src/base` and V8 `src/objects` compares 660 files with the reference. It finds 0 failures.
- The scan also found a panic on tables of more than 65,535 items ([ISSUE-017](/issues/issue-017-an-overflow-of-repeat-depth-on-large-repetitions--01a1f2f04d37.md)).

## Related
- [ISSUE-003](/issues/issue-003-parser-core-with-the-subtree-arena-and-the-glr-stack--01a1e96b8f58.md)
