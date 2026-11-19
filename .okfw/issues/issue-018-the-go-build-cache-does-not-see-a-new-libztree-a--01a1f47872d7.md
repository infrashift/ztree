---
id: "01a1f478-72d7-7e54-a692-5b3502ac2f64"
title: "ISSUE-018: The Go build cache does not see a new libztree.a"
type: "Issue"
kind: "issue"
tags:
  - "issue"
  - "open"
  - "binding"
  - "go"
created: "2026-11-19T09:41:36-06:00"
timestamp: "2026-11-19T09:41:36-06:00"
description: "cgo links libztree.a through -l, so the Go build cache can link an old library after a new zig build lib."
---

# ISSUE-018: The Go build cache does not see a new libztree.a

**Status:** open · **Phase:** none

## Description
The Go binding links `zig-out/lib/libztree.a` with `#cgo LDFLAGS: -L${SRCDIR}/../../zig-out/lib -lztree`. The Go build cache does not hash a library that `-l` names. After a new `libztree.a`, `go build` and `go test` can link the old library from the cache. `-count=1` does not help, because it disables only the cache of test results.

Evidence (2026-11-19, the engine tests of lexis):
1. `go test -c` with the ReleaseSafe `libztree.a` gave a test binary with the SHA-256 `d73e1189…`.
2. `zig build lib` (Debug) wrote a different `libztree.a`.
3. `go test -c` again gave the same binary, `d73e1189…`.
4. `go test -c -a` with the Debug library failed to link, because the Debug library needs the UBSan runtime. So the cached build did not read the new library.

lexis and semscope link the binding. After each new `libztree.a`, their tests can run against an old library. semscope has the same trap for the `parser.c` of its Zig grammar, and keeps the SHA-256 of `parser.c` in `binding.go` (semscope ADR-0010).

## Proposed change
- `zig build lib` writes the SHA-256 of `libztree.a` into a Go file of the binding, for example `bindings/go/libhash.go`. A new library then changes a Go source file, so the cache builds again.
- A binding test fails when the file does not hold the hash of the library on disk.
- Until then, run `go clean -cache` or `go test -a` after a new `libztree.a`.

## Acceptance Criteria
- [ ] A new `libztree.a` makes the next `go test` of the binding and of its callers link the new library.
- [ ] A test fails when the recorded hash and the library differ.
- [ ] The C ABI spec and the migration guide describe the step.

## Related
- [ISSUE-007](/issues/issue-007-c-abi-and-static-library-for-go-callers--01a1e96b8f9a.md)
- [ztree C ABI](/specs/ztree-c-abi--01a1ec92dc4f.md)
