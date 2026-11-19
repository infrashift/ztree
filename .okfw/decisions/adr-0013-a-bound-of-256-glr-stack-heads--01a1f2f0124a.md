---
id: "01a1f2f0-124a-7921-8ea2-b3f47199648f"
title: "ADR-0013: A bound of 256 GLR stack heads"
type: "ADR"
tags:
  - "adr"
  - "parser"
  - "limits"
created: "2026-11-19T02:33:02-06:00"
timestamp: "2026-11-19T02:33:02-06:00"
description: "The GLR stack of ztree holds at most 256 heads, about 2.8 times the largest count on 73,701 files, so C++ headers read as C parse as in the reference."
---

# ADR-0013: A bound of 256 GLR stack heads

**Status:** Accepted
**Date:** 2026-11-19
**Source:** [ISSUE-016](/issues/issue-016-the-glr-stack-limit-of-64-heads--01a1f080f76c.md), [ADR-0003](/decisions/adr-0003-adapt-the-nasa-power-of-10-rules-to-ztree--01a1e96b8f17.md)

## Context
The GLR stack of ztree held at most 64 heads. The reference runtime has no such bound. After each reduce, the reference keeps at most 10 versions plus the halted versions. But the pop of the reduce adds one version for each stack path before this trim. A pop follows at most 64 paths at one time (`MAX_ITERATOR_COUNT`). An extra token on one path makes the paths finish in different rounds, so a pop can add more versions than that. C++ code that the C grammar reads has many such paths. On `stl_algobase.h` of libstdc++, ztree returned `TooManyVersions` and the C ABI returned `ZTREE_ERROR_LIMIT_REACHED`. The reference gave a tree. semscope stops its scan at the first file error ([ADR-0007](/decisions/adr-0007-ztree-is-the-tree-sitter-service-of-lexis-and-semscope--01a1ef926073.md)).

## Decision
1. **The bound is 256 heads.** `limits.max_stack_heads` in `src/root.zig` holds the bound. `stack.max_heads` reads it. The bound is approximately 2.8 times the largest count that we measured.
2. **The measurement.** A temporary counter recorded the largest head count of each parse. The bound was 65,536 for the run. Seven runs parsed 73,701 files of all six grammars:

| Corpus | Files | Largest count |
|---|---|---|
| `/usr/include`, with libstdc++ | 3,158 | 81 (`stl_algobase.h`) |
| Linux and NVIDIA kernel headers | 6,882 | 61 |
| V8 of Node.js | 5,540 | 90 (`src/base/template-utils.h`) |
| OpenSSL of Node.js | 5,062 | 13 |
| Other C and C++ dependencies of Node.js | 5,018 | 28 |
| libcxx, libtsan, musl and std of Zig 0.17.1 | 3,855 | 17 |
| Go `src`, Python 3.12, the cargo registry, semscope, zmake, ztree | 44,186 | 49 |

Three files need more than 64 heads. Each is C++ code that the C grammar reads (`.h`). 99.9% of the files need 16 heads or fewer.
3. **A test.** `tests/parser_test.zig` has two inputs that need 87 and 71 heads. A delta reduction of the V8 file and of `stl_algobase.h` gave them. The identifiers are new. With 64 heads, the test fails with `TooManyVersions`.

## Consequences
- ztree gives the same tree as the reference on the three files and on the directories that contain them.
- The bound costs no memory. The head list grows in the parse arena only when the parse adds a version.
- An input that needs more than 256 heads still fails with `ZTREE_ERROR_LIMIT_REACHED`. The reference accepts it ([ADR-0003](/decisions/adr-0003-adapt-the-nasa-power-of-10-rules-to-ztree--01a1e96b8f17.md)).
- The scan found an integer overflow of `repeat_depth` on large tables ([ISSUE-017](/issues/issue-017-an-overflow-of-repeat-depth-on-large-repetitions--01a1f2f04d37.md)).

## Alternatives considered
- **No bound, as in the reference.** Rejected: ADR-0003 needs a fixed bound for each loop and each list.
- **A bound of 128.** Rejected: the margin over 90 is too small for unknown C++ headers. A larger bound costs nothing until a parse uses it.
- **Trim the versions during the pop.** Rejected: the order of the versions then differs from the reference, and the trees can differ.
