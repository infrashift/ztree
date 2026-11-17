---
id: "01a1e96b-8f48-7e9f-8534-1811c6447f2e"
title: "ISSUE-002: Lexer bridge for the lex function and the external scanners"
type: "Issue"
kind: "issue"
tags:
  - "issue"
  - "open"
  - "phase-2"
  - "lexer"
created: "2026-11-17T06:11:42-06:00"
timestamp: "2026-11-17T06:11:42-06:00"
description: "Lexer bridge for the lex function and the external scanners."
---

# ISSUE-002: Lexer bridge for the lex function and the external scanners

**Status:** open · **Phase:** 2

## Description
Implement the `TSLexer` that the lex function and the external scanners call.

## Acceptance Criteria
- [ ] `src/lexer.zig` decodes UTF-8 and tracks byte, row and column positions.
- [ ] The lexer bridge supports `advance`, `mark_end`, `get_column` and `eof`.
- [ ] Tests lex the first tokens of a sample file for each grammar.
- [ ] A test compares the token stream with the reference runtime.
- [ ] `zmake check` reports zero errors and zero warnings.

## Notes
An invalid UTF-8 byte becomes U+FFFD, as in the reference runtime.

## Related
- [ADR-0003](/decisions/adr-0003-adapt-the-nasa-power-of-10-rules-to-ztree--01a1e96b8f17.md) (Power of 10) and [ADR-0004](/decisions/adr-0004-a-batch-tree-sitter-runtime-for-abi-14-and-15--01a1e96b8f27.md) (scope).
- [ztree architecture overview](/architecture/ztree-architecture-overview--01a1e96b8ee5.md)
