---
x-okfw-id: "01a1f4ea-ab02-7301-9852-aa78ca1d5883"
title: "ISSUE-019: An executable stack with a Debug libztree.a"
type: "Issue"
x-okfw-kind: "issue"
tags:
  - "issue"
  - "closed"
  - "phase-18"
  - "binding"
  - "build"
x-okfw-created: "2026-11-19T11:46:22-06:00"
x-okfw-timestamp: "2026-11-19T11:46:22-06:00"
description: "The self-hosted backend of a Debug build writes capi.o without a .note.GNU-stack section, so GNU ld gives a cgo program an executable stack."
---

# ISSUE-019: An executable stack with a Debug libztree.a

**Status:** closed · **Phase:** 18

## Description
A Go program that links a Debug `libztree.a` gets one GNU ld warning:

```
/usr/bin/ld: warning: capi.o: missing .note.GNU-stack section implies executable stack
```

The warning is not only noise. GNU ld gives the program an executable stack. On 2026-11-19, the Debug test program of the binding had a `GNU_STACK` segment with the flags `RWE`. A ReleaseSafe library gives `RW` and no warning. [ADR-0016](/decisions/adr-0016-a-hash-file-of-libztree-a-in-the-go-binding--01a1f47f0da8.md) recorded the warning, but did not fix it.

Cause: Zig 0.17.1 uses its self-hosted x86_64 backend for a Debug build. That backend writes `capi.o` without a `.note.GNU-stack` section. A release build uses LLVM, and its object `ztree_zcu.o` has the section. The C objects of the grammars and `compiler_rt.o` have the section in each mode.

## Acceptance Criteria
- [x] Each object of a Debug and of a ReleaseSafe `libztree.a` has a `.note.GNU-stack` section that is not executable.
- [x] A Go program that links a Debug library gets no linker warning and a stack that is not executable.
- [x] A check fails when an object of the library has no such section. `zmake check` runs it on a Debug library.
- [x] The ReleaseSafe library does not change.

## Resolution
`build.zig` sets `lib.use_llvm = true` ([ADR-0017](/decisions/adr-0017-llvm-builds-libztree-a-in-each-mode--01a1f4eaab0a.md)). The new tool `tools/stackcheck.zig` reads each ELF object of the archive in each `zig build lib` and in `zig build test`. It fails on the old Debug library with `capi.o has no .note.GNU-stack section`. The binding test `TestStackNotExecutable` reads the `PT_GNU_STACK` header of the test program. It fails with the old Debug library (`PF_X+PF_W+PF_R`) and passes with the new one. The ReleaseSafe library keeps the SHA-256 `2cc1ddd1…`. The engine tests of lexis pass with the new Debug library.
