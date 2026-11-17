---
id: "01a1e96b-8f38-730d-8554-f67f7266899d"
title: "ISSUE-001: Vendor the reference runtime and the grammars and mirror the C ABI"
type: "Issue"
kind: "issue"
tags:
  - "issue"
  - "phase-1"
  - "vendor"
  - "closed"
created: "2026-11-17T06:11:42-06:00"
timestamp: "2026-11-17T06:16:26-06:00"
description: "Vendor the reference runtime and the grammars and mirror the C ABI."
---

# ISSUE-001: Vendor the reference runtime and the grammars and mirror the C ABI

**Status:** closed · **Phase:** 1

## Description
Vendor the reference runtime and the five grammars into `third_party/`. Mirror the C ABI structs in `src/abi.zig`.

## Acceptance Criteria
- [x] `third_party/tree-sitter/` holds the pinned reference runtime with its licence and pin file.
- [x] `third_party/grammars/<lang>/` holds go, zig, python, c and rust at the pinned tags.
- [x] `build.zig` compiles each grammar with the Zig C compiler.
- [x] `src/abi.zig` mirrors `TSLanguage` for ABI 14 and 15, `TSLexer`, `TSParseAction` and `TSLexMode`.
- [x] A test loads each language and asserts its ABI version, symbol count and state count.
- [x] `zmake check` reports zero errors and zero warnings.

## Notes
The Zig grammar uses ABI 14. The other grammars use ABI 15.

## Related
- [ADR-0003](/decisions/adr-0003-adapt-the-nasa-power-of-10-rules-to-ztree--01a1e96b8f17.md) (Power of 10) and [ADR-0004](/decisions/adr-0004-a-batch-tree-sitter-runtime-for-abi-14-and-15--01a1e96b8f27.md) (scope).
- [ztree architecture overview](/architecture/ztree-architecture-overview--01a1e96b8ee5.md)

## Resolution
- `third_party/` holds the reference runtime v0.27.2 and the five grammars. Each directory has a `PIN` file with the tag and the commit.
- `src/abi.zig` mirrors the ABI. `Language15` embeds `Language14`, because ABI 15 appends fields to the ABI 14 layout.
- ABI 14 stores 4-byte lex modes and ABI 15 stores 6-byte lex modes. `abi.lexMode` reads the right stride.
- A lex mode with `lex_state` 0xffff marks a state that only holds non-terminal extras.
- `tests/abi_test.zig` compares the layout with C `offsetof` probes, the counts with the `parser.c` defines, and the symbol names with the reference runtime.
