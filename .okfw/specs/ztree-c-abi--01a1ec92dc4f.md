---
id: "01a1ec92-dc4f-73ca-bb53-b874acc0bbdb"
title: "ztree C ABI"
type: "Spec"
tags:
  - "spec"
  - "capi"
  - "go"
created: "2026-11-17T20:53:30-06:00"
timestamp: "2026-11-17T20:53:30-06:00"
description: "The C ABI of libztree.a: ztree_extract_comments, its status codes, its memory rules and the Go binding in bindings/go."
---

# ztree C ABI

# ztree C ABI

**Version:** 1 (`ZTREE_ABI_VERSION`)
**Header:** `include/ztree.h`
**Library:** `zig-out/lib/libztree.a`, from `zig build lib --release`
**Source:** [ISSUE-007](/issues/issue-007-c-abi-and-static-library-for-go-callers--01a1e96b8f9a.md)

## Purpose
The C ABI gives the comment spans of a source file to a C or Go caller. lexis uses it through cgo.

## Build
- `zig build lib --release` writes `zig-out/lib/libztree.a` and `zig-out/include/ztree.h`. The library uses ReleaseSafe, so the assertions stay active ([ADR-0003](/decisions/adr-0003-adapt-the-nasa-power-of-10-rules-to-ztree--01a1e96b8f17.md)).
- The library holds the five grammars, the Zig code and compiler-rt. It needs only libc: `malloc`, `free`, `write`, `abort` and the `isw*` functions of the scanners.
- The code is position independent, so a linker can put it into a PIE.
- The library does not hold the reference runtime.

## Functions
### `uint32_t ztree_abi_version(void)`
Returns the ABI version of the library. A caller compares it with `ZTREE_ABI_VERSION` of its header before the first call.

### `int32_t ztree_extract_comments(lang, src, len, spans_out, max_spans, count_out)`
| Parameter | Type | Rule |
|---|---|---|
| `lang` | `uint32_t` | One of `ZTREE_LANG_GO` (0), `ZTREE_LANG_ZIG` (1), `ZTREE_LANG_PYTHON` (2), `ZTREE_LANG_C` (3) and `ZTREE_LANG_RUST` (4). |
| `src` | `const uint8_t *` | The source bytes. NULL is valid when `len` is 0. ztree reads the bytes and does not keep the pointer. |
| `len` | `size_t` | The number of source bytes. The maximum is `ZTREE_MAX_SOURCE_BYTES` (16 MiB). |
| `spans_out` | `ztree_span *` | The output buffer that the caller owns. NULL is valid when `max_spans` is 0. |
| `max_spans` | `size_t` | The number of spans in `spans_out`. |
| `count_out` | `size_t *` | Receives the number of comments in the source. It must not be NULL. |

The function parses the source, walks the tree in source order and writes one `ztree_span` for each comment node. The comment node types come from the `node-types.json` of each grammar: `comment` for Go, Zig, Python and C; `line_comment` and `block_comment` for Rust. A comment node with children, such as a Rust doc comment, gives one span. A source with syntax errors still gives its comments.

## Spans
`ztree_span` holds six `uint32_t` fields: `start_byte`, `end_byte`, `start_row`, `start_column`, `end_row` and `end_column`. The size is 24 bytes.
- Bytes are offsets into `src`. The end is exclusive.
- Rows start at 0. A column counts bytes from the start of its row, as in the Tree-sitter reference runtime.
- The text of a span is the text of the comment node. A Rust doc comment includes its newline. Other line comments do not.

## Status codes
| Code | Name | `*count_out` | `spans_out` |
|---|---|---|---|
| 0 | `ZTREE_OK` | The number of comments, at most `max_spans`. | Holds `*count_out` spans. |
| 1 | `ZTREE_ERROR_BUFFER_TOO_SMALL` | The number of comments, more than `max_spans`. | Holds the first `max_spans` spans. |
| 2 | `ZTREE_ERROR_INVALID_ARGUMENT` | 0, or no write when `count_out` is NULL. | No change. |
| 3 | `ZTREE_ERROR_SOURCE_TOO_LARGE` | 0 | No change. |
| 4 | `ZTREE_ERROR_OUT_OF_MEMORY` | 0 | Unspecified. |
| 5 | `ZTREE_ERROR_LIMIT_REACHED` | 0 | Unspecified. |
| 6 | `ZTREE_ERROR_UNSUPPORTED_GRAMMAR` | 0 | Unspecified. |

Code 5 means that the parse reached a hard limit of `limits` in `src/root.zig`: subtrees, stack nodes, stack versions, tree depth or operations. To get all spans after code 1, call the function again with a buffer of `*count_out` spans. The second call parses the source again.

## Memory and threads
- Each call creates one arena on the C heap and frees it before it returns. The library keeps no memory between calls.
- The library has no global state that changes. Two threads can call the functions at the same time. The external scanners keep their state in a payload for each parse.
- The functions take no callbacks.

## Failures
A failed assertion or a safety check is a bug in ztree. The panic handler writes `ztree: panic: <message>` to stderr and calls `abort()`. It prints no stack trace and starts no thread. A caller cannot recover from it.

## Go binding
`bindings/go` is the Go module `github.com/infrashift/ztree/bindings/go`, package `ztree`.
- `ExtractComments(lang Lang, src []byte) ([]Span, error)` sizes the buffer from the source length. On code 1 it parses again with a buffer of the exact size.
- `Span` has the same layout as `ztree_span`. Compile-time checks fail the build when the layouts differ.
- `ExtractComments` returns `ErrABIMismatch` when the header and the library have different ABI versions.
- The cgo flags read `../../zig-out/include` and `../../zig-out/lib`. Run `zig build lib --release` before `go build`.
- The default C compiler works. With `CC="zig cc"` on a host with two GCC installations, add `-Wno-gcc-install-dir-libstdcxx`. Without it, cgo fails on a warning in `runtime/cgo`.

## Tests
- `src/capi.zig`: the status codes, the bad arguments and the language values.
- `tests/capi_test.c`: a C caller of `libztree.a` through `include/ztree.h`. It checks the layout, each grammar, the points, the buffer rules and the bad arguments. `zig build test` runs it.
- `bindings/go`: each grammar, the buffer growth, the errors and calls from 8 goroutines. It also compares the comments of the Go files in five GOROOT package trees with `go/parser`. `zmake go` runs the tests with the race detector.
