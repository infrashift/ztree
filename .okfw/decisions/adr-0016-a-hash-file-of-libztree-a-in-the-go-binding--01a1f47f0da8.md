---
id: "01a1f47f-0da8-73f3-86f7-8cdc0797e0a8"
title: "ADR-0016: A hash file of libztree.a in the Go binding"
type: "ADR"
tags:
  - "adr"
  - "binding"
  - "go"
  - "build"
created: "2026-11-19T09:48:49-06:00"
timestamp: "2026-11-19T09:48:49-06:00"
description: "zig build lib writes the SHA-256 of libztree.a into bindings/go/libhash.go, so the Go build cache links a new library, and a Debug library holds the UBSan runtime."
---

# ADR-0016: A hash file of libztree.a in the Go binding

**Status:** Accepted
**Date:** 2026-11-19
**Source:** [ISSUE-018](/issues/issue-018-the-go-build-cache-does-not-see-a-new-libztree-a--01a1f47872d7.md)

## Context
The Go binding links `zig-out/lib/libztree.a` with `#cgo LDFLAGS: -L… -lztree`. The Go build cache hashes the Go source files and the cgo files of a package. It does not hash a library that `-l` names. The link step of Go keys on the content of each compiled package, not on its source. After a new `libztree.a`, `go build` and `go test` gave the old binary from the cache. The tests of lexis and semscope could then run against an old library.

A Debug library has a second problem. `zig build` installs a Debug `libztree.a`, and its C code calls the runtime of UBSan. Go could not link it: `undefined reference to __ubsan_handle_type_mismatch_v1`. The cache hid this problem, because Go did not link again.

## Decision
- `tools/libhash.zig` reads `libztree.a` and writes `bindings/go/libhash.go`. The step `lib` of `build.zig` runs it after each build of the library, so `zig build` and `zig build lib` both write the file.
- `libhash.go` holds the constant `libHash` and the function `LibraryHash`. The function puts the hash in the compiled package, so the content of the package changes with the library. The Go link step then runs again.
- `libhash.go` is a build output. `.gitignore` holds it.
- `TestLibraryHash` of the binding fails when `libhash.go` does not hold the hash of `zig-out/lib/libztree.a`.
- A Debug library holds the runtime of UBSan (`bundle_ubsan_rt`), so cgo can link it. The ReleaseSafe library does not change.

## Measurements
Each step built the engine tests of lexis with `go test -c`.
- **Without the hash file:** a Debug library in place of the ReleaseSafe library gave the same test binary, from the cache. `go test -c -a` with the Debug library failed with an UBSan link error. So the cached build did not read the new library.
- **With the hash file:** the Debug library made Go link again. Without `bundle_ubsan_rt`, the link failed with the UBSan error. With it, the lexis tests and the binding tests passed. The ReleaseSafe library then gave the first binary again, from the cache.
- **A constant without a function:** two values of an unused constant in the binding gave the same test binary. With a function that returns the constant, the two binaries differ.
- The ReleaseSafe library keeps the same SHA-256 with the new build step and with `bundle_ubsan_rt`.

## Consequences
- After a new library, the next Go build of the binding, of lexis or of semscope links the new library. `go clean -cache` is not necessary.
- The binding needs `zig build lib` before `go vet`, because `libhash.go` defines `libHash`. The binding already needed the library to link.
- `LibraryHash` is a public function. A caller can log the hash of the linked library.
- A Go link with a Debug library gave one linker warning: `capi.o` has no `.note.GNU-stack` section. The ReleaseSafe library gives no warning. [ADR-0017](/decisions/adr-0017-llvm-builds-libztree-a-in-each-mode--01a1f4eaab0a.md) fixes the warning ([ISSUE-019](/issues/issue-019-an-executable-stack-with-a-debug-libztree-a--01a1f4eaab02.md)).

## Alternatives considered
- **Commit `libhash.go`.** Rejected: the hash depends on the host and the toolchain. A build on another host then changes a committed file.
- **A constant without a function.** Rejected: an unused constant does not change the compiled package, so the link step stays in the cache. The measurements show it.
- **Put the library in the package as a `.syso` file.** Rejected: Go expects an object file in a `.syso` file, and `libztree.a` is an archive. It also puts a build output in the source tree.
- **Tell each caller to run `go clean -cache`.** Rejected: a step that a person must remember fails without a sign.
