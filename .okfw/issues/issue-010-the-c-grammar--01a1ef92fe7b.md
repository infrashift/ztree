---
id: "01a1ef92-fe7b-7716-bdd2-2914327309d4"
title: "ISSUE-010: The C++ grammar"
type: "Issue"
kind: "issue"
tags:
  - "issue"
  - "open"
  - "phase-8"
  - "grammar"
created: "2026-11-18T10:52:30-06:00"
timestamp: "2026-11-18T10:52:30-06:00"
description: "The C++ grammar."
---

# ISSUE-010: The C++ grammar

**Status:** open · **Phase:** 8

## Description
Vendor tree-sitter-cpp and add it as the sixth grammar. semscope lints C++ files ([ADR-0007](/decisions/adr-0007-ztree-is-the-tree-sitter-service-of-lexis-and-semscope--01a1ef926073.md)).

## Acceptance Criteria
- [ ] `third_party/grammars/cpp/` holds tree-sitter-cpp v0.23.4: `src/`, `LICENSE`, `test/corpus/` and a `PIN` file.
- [ ] `grammars.Lang` has `cpp`. `build.zig` compiles `parser.c` and `scanner.c`.
- [ ] The comment kinds of C++ give the same spans as the reference runtime.
- [ ] `include/ztree.h` has `ZTREE_LANG_CPP`. The Go binding has `LangCPP`.
- [ ] The conformance step reads the C++ corpus. The differential step reads C++ files.
- [ ] `zmake check` reports zero errors and zero warnings.

## Related
- [ADR-0007](/decisions/adr-0007-ztree-is-the-tree-sitter-service-of-lexis-and-semscope--01a1ef926073.md)
- [ADR-0004](/decisions/adr-0004-a-batch-tree-sitter-runtime-for-abi-14-and-15--01a1e96b8f27.md) (pin table)
