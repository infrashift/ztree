---
id: "01a1f2f0-4d37-7806-a8a7-4c5e9ce70c9e"
title: "ISSUE-017: An overflow of repeat_depth on large repetitions"
type: "Issue"
kind: "issue"
tags:
  - "issue"
  - "open"
  - "parser"
  - "crash"
created: "2026-11-19T02:33:17-06:00"
timestamp: "2026-11-19T02:33:17-06:00"
description: "summarizeEnds adds 1 to the u16 repeat_depth for each item of a repetition, so a table of more than 65,535 items panics in a safe build."
---

# ISSUE-017: An overflow of repeat_depth on large repetitions

**Status:** open · **Phase:** 15

## Description
`summarizeEnds` in `src/subtree.zig` adds 1 to `repeat_depth`, a `u16`, for each node of a hidden repetition. ztree does not balance repetitions ([ADR-0005](/decisions/adr-0005-one-arena-per-parse-no-reference-counts-and-no-balance-step--01a1ebbb7488.md)), so a repetition of n items gives a left-deep chain with a depth of n. When n is more than 65,535, the add overflows. A safe build panics with `integer overflow`. The C ABI cannot return an error for a panic, so the process of the caller stops.

The scan for [ADR-0013](/decisions/adr-0013-a-bound-of-256-glr-stack-heads--01a1f2f0124a.md) found two files:
- `src/crypto/internal/fips140/nistec/p256_table.go` of Go 1.27.3 (Go grammar)
- `c/common/dictionary_inc.h` of brotli in Node.js (C grammar)

Both are large tables of literals. The reference runtime also keeps `repeat_depth` in a `uint16_t`, but the C add wraps. The reference reads `repeat_depth` only in its balance step. ztree reads it nowhere.

## Acceptance Criteria
- [ ] No input makes `repeat_depth` or a similar summary field overflow.
- [ ] Find the other summary adds of `summarizeChildren` that a valid input can overflow, and make each one safe.
- [ ] Add a test with a repetition of more than 65,535 items for each affected grammar.
- [ ] The two files parse with the same tree as the reference.
- [ ] `zmake check` reports zero errors and zero warnings.

## Related
- [ISSUE-016](/issues/issue-016-the-glr-stack-limit-of-64-heads--01a1f080f76c.md), [ADR-0003](/decisions/adr-0003-adapt-the-nasa-power-of-10-rules-to-ztree--01a1e96b8f17.md)
