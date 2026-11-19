---
id: "01a1f4ea-ab0a-7550-b0ce-acd58559fb62"
title: "ADR-0017: LLVM builds libztree.a in each mode"
type: "ADR"
tags:
  - "adr"
  - "build"
  - "binding"
  - "security"
created: "2026-11-19T11:46:22-06:00"
timestamp: "2026-11-19T11:46:22-06:00"
description: "libztree.a uses the LLVM backend in each mode, so each object has a .note.GNU-stack section, and a build tool checks the section."
---

# ADR-0017: LLVM builds libztree.a in each mode

**Status:** Accepted
**Date:** 2026-11-19
**Source:** [ISSUE-019](/issues/issue-019-an-executable-stack-with-a-debug-libztree-a--01a1f4eaab02.md). User request on 2026-11-19: fix the Debug-only linker warning.

## Context
GNU ld gives a program an executable stack when one input object has no `.note.GNU-stack` section. Zig 0.17.1 builds a Debug x86_64 object with its self-hosted backend, and that backend writes no such section. So a cgo program that links a Debug `libztree.a` gets an executable stack and a linker warning. The release modes use LLVM, which writes the section.

## Decision
- The library step sets `use_llvm = true`. LLVM builds `libztree.a` in each mode.
- `tools/stackcheck.zig` reads each ELF object of the archive. It fails when an object has no `.note.GNU-stack` section, or when the section has the flag `SHF_EXECINSTR`. `zig build lib` and `zig build test` run it.
- The binding test `TestStackNotExecutable` checks the `PT_GNU_STACK` header of the test program.
- The other artifacts of ztree keep the default backend. The Zig linker links them, and it does not make the stack executable.

## Consequences
- A Debug library gives no linker warning, and a cgo program that links it has a stack that is not executable.
- The ReleaseSafe library does not change, byte for byte. It already used LLVM.
- A Debug build of `libztree.a` takes longer, because LLVM is slower than the self-hosted backend. With the C objects in the cache, it took 5.5 s on this host.
- `zmake check` runs `zig build test` in Debug, so the stack check reads a Debug library in each gate.

## Alternatives considered
- **Add `-Wl,-z,noexecstack` to the cgo flags of the binding.** Rejected: it hides the defect for Go only. A C caller with GNU ld still gets an executable stack.
- **Keep the warning ([ADR-0016](/decisions/adr-0016-a-hash-file-of-libztree-a-in-the-go-binding--01a1f47f0da8.md)).** Rejected: the stack is executable, not only a warning.
- **Wait for a fix of the self-hosted backend.** Rejected: the defect is in Zig 0.17.1, the pinned version.

## Related
- [ADR-0016](/decisions/adr-0016-a-hash-file-of-libztree-a-in-the-go-binding--01a1f47f0da8.md): the hash file of `libztree.a`.
- [C ABI spec](/specs/ztree-c-abi--01a1ec92dc4f.md)
