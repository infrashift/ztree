---
x-okfw-id: "01a1ef92-fe7b-7716-bdd2-2914327309d4"
title: "ISSUE-010: The C++ grammar"
type: "Issue"
x-okfw-kind: "issue"
tags:
  - "issue"
  - "phase-8"
  - "grammar"
  - "closed"
x-okfw-created: "2026-11-18T10:52:30-06:00"
x-okfw-timestamp: "2026-11-18T10:57:45-06:00"
description: "The C++ grammar."
---

# ISSUE-010: The C++ grammar

**Status:** closed · **Phase:** 8

## Description
Vendor tree-sitter-cpp and add it as the sixth grammar. semscope lints C++ files ([ADR-0007](/decisions/adr-0007-ztree-is-the-tree-sitter-service-of-lexis-and-semscope--01a1ef926073.md)).

## Acceptance Criteria
- [x] `third_party/grammars/cpp/` holds tree-sitter-cpp v0.23.4: `src/`, `LICENSE`, `test/corpus/` and a `PIN` file.
- [x] `grammars.Lang` has `cpp`. `build.zig` compiles `parser.c` and `scanner.c`.
- [x] The comment kinds of C++ give the same spans as the reference runtime.
- [x] `include/ztree.h` has `ZTREE_LANG_CPP`. The Go binding has `LangCPP`.
- [x] The conformance step reads the C++ corpus. The differential step reads C++ files.
- [x] `zmake check` reports zero errors and zero warnings.

## Resolution
- tree-sitter-cpp v0.23.4 is the last release. Its grammar uses ABI 14, so the Zig grammar is no longer the only ABI 14 grammar. Its external scanner reads raw strings and has 2 tokens.
- `third_party/grammars/cpp/` also holds the upstream `examples/`. The default differential step reads them, so `zmake check` parses a C++ file.
- The conformance step passes all 179 C++ corpus examples, with the C examples of the C++ corpus. The total is 599 examples.
- The differential step agrees with the reference runtime on 149 files of the libc++, libc++abi and libunwind sources of Zig 0.17.1. 84 of 96 C++ files have syntax errors in both runtimes, so error recovery also matches.
- The C ABI version is now 2. lexis passes its tests with the new library and needs no code change.

## Related
- [ADR-0007](/decisions/adr-0007-ztree-is-the-tree-sitter-service-of-lexis-and-semscope--01a1ef926073.md)
- [ADR-0004](/decisions/adr-0004-a-batch-tree-sitter-runtime-for-abi-14-and-15--01a1e96b8f27.md) (pin table)
