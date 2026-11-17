---
id: "01a1e96b-8f9a-7eb7-98bd-418889fa7058"
title: "ISSUE-007: C ABI and static library for Go callers"
type: "Issue"
kind: "issue"
tags:
  - "issue"
  - "open"
  - "phase-7"
  - "capi"
created: "2026-11-17T06:11:42-06:00"
timestamp: "2026-11-17T06:11:42-06:00"
description: "C ABI and static library for Go callers."
---

# ISSUE-007: C ABI and static library for Go callers

**Status:** open · **Phase:** 7

## Description
Export a static library and a C header for Go callers through cgo.

## Acceptance Criteria
- [ ] `zig build lib` writes `libztree.a` and `include/ztree.h`.
- [ ] `ztree_extract_comments(lang, src, len, spans_out, max_spans)` takes no callbacks.
- [ ] The function returns an error code when the buffer is too small.
- [ ] `examples/go/` holds a cgo smoke test that extracts the comments of a Go file.
- [ ] A spec in `specs/` defines the C ABI.
- [ ] `zmake check` reports zero errors and zero warnings.

## Notes
lexis uses this library. lexis builds it with `CC="zig cc"`.

## Related
- [ADR-0003](/decisions/adr-0003-adapt-the-nasa-power-of-10-rules-to-ztree--01a1e96b8f17.md) (Power of 10) and [ADR-0004](/decisions/adr-0004-a-batch-tree-sitter-runtime-for-abi-14-and-15--01a1e96b8f27.md) (scope).
- [ztree architecture overview](/architecture/ztree-architecture-overview--01a1e96b8ee5.md)
