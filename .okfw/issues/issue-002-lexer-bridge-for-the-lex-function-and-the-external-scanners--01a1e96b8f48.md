---
x-okfw-id: "01a1e96b-8f48-7e9f-8534-1811c6447f2e"
title: "ISSUE-002: Lexer bridge for the lex function and the external scanners"
type: "Issue"
x-okfw-kind: "issue"
tags:
  - "issue"
  - "phase-2"
  - "lexer"
  - "closed"
x-okfw-created: "2026-11-17T06:11:42-06:00"
x-okfw-timestamp: "2026-11-17T16:35:38-06:00"
description: "Lexer bridge for the lex function and the external scanners."
---

# ISSUE-002: Lexer bridge for the lex function and the external scanners

**Status:** closed · **Phase:** 2

## Description
Write the `TSLexer` that the lex function and the external scanners call.

## Acceptance Criteria
- [x] `src/lexer.zig` decodes UTF-8 and tracks byte, row and column positions.
- [x] The lexer bridge supports `advance`, `mark_end`, `get_column` and `eof`.
- [x] Tests lex the first tokens of a sample file for each grammar.
- [x] A test compares the lex results with the reference lexer at sampled positions, in each lex state.
- [x] `zmake check` reports zero errors and zero warnings.

## Notes
An ill-formed UTF-8 sequence gives the lookahead `TS_DECODE_ERROR` (-1) with a size of 1 byte, as in the reference runtime. It does not give U+FFFD.

## Related
- [ADR-0003](/decisions/adr-0003-adapt-the-nasa-power-of-10-rules-to-ztree--01a1e96b8f17.md) (Power of 10) and [ADR-0004](/decisions/adr-0004-a-batch-tree-sitter-runtime-for-abi-14-and-15--01a1e96b8f27.md) (scope).
- [ztree architecture overview](/architecture/ztree-architecture-overview--01a1e96b8ee5.md)

## Resolution
- `src/utf8.zig` decodes with the validity rules of ICU `U8_NEXT`. A test compares it with the reference decoder for each sequence of 1 to 3 bytes and for each 4-byte lead.
- `src/lexer.zig` ports `lexer.c` for one buffer and one included range. `src/length.zig` holds `Point` and `Length`.
- `tests/lexer_test.zig` drives the reference lexer through `tests/ref_shim.c`. At sampled code point positions, it compares each lex state, the keyword lexer, each external scanner row and `get_column`.
- Inputs: two corpus files per grammar, `src/lexer.zig` for Zig, and edge inputs (BOM, ill-formed UTF-8, CRLF, NUL, empty, truncated sequences).
- Mutation checks: a BOM column error, an off-by-one in the lookahead end and a lost skip on the fast path each make the test fail.
- Differences from the reference:
  - No logger. No vendored scanner calls `log`.
  - No included ranges and no UTF-16 input.
  - No refetch after a decode error. One buffer gives the same bytes.
- No vendored scanner calls `get_column` or `is_at_included_range_start`. The direct `get_column` mode of the test covers them.
