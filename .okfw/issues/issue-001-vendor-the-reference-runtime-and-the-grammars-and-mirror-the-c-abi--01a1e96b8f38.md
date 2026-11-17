---
id: "01a1e96b-8f38-730d-8554-f67f7266899d"
title: "ISSUE-001: Vendor the reference runtime and the grammars and mirror the C ABI"
type: "Issue"
kind: "issue"
tags:
  - "issue"
  - "open"
  - "phase-1"
  - "vendor"
created: "2026-11-17T06:11:42-06:00"
timestamp: "2026-11-17T06:11:42-06:00"
description: "Vendor the reference runtime and the grammars and mirror the C ABI."
---

# ISSUE-001: Vendor the reference runtime and the grammars and mirror the C ABI

**Status:** open · **Phase:** 1

## Description
Vendor the reference runtime and the five grammars into `third_party/`. Mirror the C ABI structs in `src/abi.zig`.

## Acceptance Criteria
- [ ] `third_party/tree-sitter/` holds the pinned reference runtime with its licence and pin file.
- [ ] `third_party/grammars/<lang>/` holds go, zig, python, c and rust at the pinned tags.
- [ ] `build.zig` compiles each grammar with the Zig C compiler.
- [ ] `src/abi.zig` mirrors `TSLanguage` for ABI 14 and 15, `TSLexer`, `TSParseAction` and `TSLexMode`.
- [ ] A test loads each language and asserts its ABI version, symbol count and state count.
- [ ] `zmake check` reports zero errors and zero warnings.

## Notes
The Zig grammar uses ABI 14. The other grammars use ABI 15.

## Related
- [ADR-0003](/decisions/adr-0003-adapt-the-nasa-power-of-10-rules-to-ztree--01a1e96b8f17.md) (Power of 10) and [ADR-0004](/decisions/adr-0004-a-batch-tree-sitter-runtime-for-abi-14-and-15--01a1e96b8f27.md) (scope).
- [ztree architecture overview](/architecture/ztree-architecture-overview--01a1e96b8ee5.md)
