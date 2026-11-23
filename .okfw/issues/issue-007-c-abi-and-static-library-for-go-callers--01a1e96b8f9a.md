---
x-okfw-id: "01a1e96b-8f9a-7eb7-98bd-418889fa7058"
title: "ISSUE-007: C ABI and static library for Go callers"
type: "Issue"
x-okfw-kind: "issue"
tags:
  - "issue"
  - "closed"
  - "phase-7"
  - "capi"
x-okfw-created: "2026-11-17T06:11:42-06:00"
x-okfw-timestamp: "2026-11-17T06:11:42-06:00"
description: "C ABI and static library for Go callers."
---

# ISSUE-007: C ABI and static library for Go callers

**Status:** closed · **Phase:** 7

## Description
Export a static library and a C header for Go callers through cgo.

## Acceptance Criteria
- [x] `zig build lib` writes `libztree.a` and `include/ztree.h`.
- [x] `ztree_extract_comments(lang, src, len, spans_out, max_spans, count_out)` takes no callbacks.
- [x] The function returns an error code when the buffer is too small.
- [x] `bindings/go/` holds the cgo binding. Its tests extract the comments of Go files.
- [x] A spec in `specs/` defines the C ABI.
- [x] `zmake check` reports zero errors and zero warnings.

## Notes
lexis uses this library. lexis builds it with `CC="zig cc"`.

## Resolution
- The [C ABI spec](/specs/ztree-c-abi--01a1ec92dc4f.md) defines the functions, the spans, the status codes, the memory rules and the Go binding.
- `ztree_extract_comments` has a sixth parameter, `count_out`. On `ZTREE_ERROR_BUFFER_TOO_SMALL` it holds the number of comments, so the caller can size the buffer and call again.
- `src/capi.zig` is the root of `libztree.a`. Its panic handler writes the message and calls `abort()`. The default handler of Zig linked stack-trace code that calls `fork`, `execve` and sockets. The archive went from 10.9 MB to 6.6 MB, and it needs only libc.
- The Go binding is in `bindings/go/`, not in `examples/go/`. lexis imports the package, so it does not copy the cgo code. The tests of the package are the smoke test.
- `bindings/go` compares 40,400 comments of five GOROOT package trees with `go/parser`. All match. The tests also run 8 goroutines at the same time under the race detector.
- A mutation check: an `end_byte` that is 1 byte short makes the Go tests fail.
- `CC="zig cc"` needs `-Wno-gcc-install-dir-libstdcxx` on a host with two GCC installations. The default C compiler needs no flag.

## Related
- [ADR-0003](/decisions/adr-0003-adapt-the-nasa-power-of-10-rules-to-ztree--01a1e96b8f17.md) (Power of 10) and [ADR-0004](/decisions/adr-0004-a-batch-tree-sitter-runtime-for-abi-14-and-15--01a1e96b8f27.md) (scope).
- [ztree architecture overview](/architecture/ztree-architecture-overview--01a1e96b8ee5.md)
