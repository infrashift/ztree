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
description: "The C ABI of libztree.a: ztree_extract_comments, ztree_parse, the language functions, the status codes, the memory rules and the Go binding in bindings/go."
---

# ztree C ABI

**Version:** 4 (`ZTREE_ABI_VERSION`). Version 2 adds `ZTREE_LANG_CPP`. Version 3 adds `ztree_parse` and the language functions. Version 4 adds `ztree_regex_match` and status codes 7 and 8 ([ADR-0010](/decisions/adr-0010-a-pike-vm-for-an-re2-subset--01a1f0902c3e.md)) ([ADR-0008](/decisions/adr-0008-a-flat-tree-and-a-compiled-query-blob-in-caller-memory--01a1ef929e5c.md), [ADR-0009](/decisions/adr-0009-field-overrides-and-the-node-rules-of-the-flat-tree--01a1f080b1ed.md)).
**Header:** `include/ztree.h`
**Library:** `zig-out/lib/libztree.a`, from `zig build lib --release`
**Source:** [ISSUE-007](/issues/issue-007-c-abi-and-static-library-for-go-callers--01a1e96b8f9a.md), [ISSUE-011](/issues/issue-011-the-flat-tree-and-the-node-api--01a1ef92fe81.md)

## Purpose
The C ABI gives the comment spans and the syntax tree of a source file to a C or Go caller. lexis uses the comment spans through cgo. semscope uses the syntax tree.

## Build
- `zig build lib --release` writes `zig-out/lib/libztree.a` and `zig-out/include/ztree.h`. The library uses ReleaseSafe, so the assertions stay active ([ADR-0003](/decisions/adr-0003-adapt-the-nasa-power-of-10-rules-to-ztree--01a1e96b8f17.md)).
- The library holds the six grammars, the Zig code and compiler-rt. It needs only libc: `malloc`, `free`, `write`, `abort` and the `isw*` functions of the scanners.
- The code is position independent, so a linker can put it into a PIE.
- The library does not hold the reference runtime.

## Functions
### `uint32_t ztree_abi_version(void)`
Returns the ABI version of the library. A caller compares it with `ZTREE_ABI_VERSION` of its header before the first call.

### `int32_t ztree_extract_comments(lang, src, len, spans_out, max_spans, count_out)`
| Parameter | Type | Rule |
|---|---|---|
| `lang` | `uint32_t` | One of `ZTREE_LANG_GO` (0), `ZTREE_LANG_ZIG` (1), `ZTREE_LANG_PYTHON` (2), `ZTREE_LANG_C` (3), `ZTREE_LANG_RUST` (4) and `ZTREE_LANG_CPP` (5). |
| `src` | `const uint8_t *` | The source bytes. NULL is valid when `len` is 0. ztree reads the bytes and does not keep the pointer. |
| `len` | `size_t` | The number of source bytes. The maximum is `ZTREE_MAX_SOURCE_BYTES` (16 MiB). |
| `spans_out` | `ztree_span *` | The output buffer that the caller owns. NULL is valid when `max_spans` is 0. |
| `max_spans` | `size_t` | The number of spans in `spans_out`. |
| `count_out` | `size_t *` | Receives the number of comments in the source. It must not be NULL. |

The function parses the source, walks the tree in source order and writes one `ztree_span` for each comment node. The comment node types come from the `node-types.json` of each grammar: `comment` for Go, Zig, Python, C and C++; `line_comment` and `block_comment` for Rust. A comment node with children, such as a Rust doc comment, gives one span. A source with syntax errors still gives its comments.

### `int32_t ztree_parse(lang, src, len, nodes_out, max_nodes, node_count_out, overrides_out, max_overrides, override_count_out)`
The function parses the source and writes the syntax tree as two arrays in the buffers of the caller:
- `ztree_node` records: the nodes that a Tree-sitter cursor visits, in pre-order. Node 0 is the root. The first child of a node with children is at the next index.
- `ztree_field_override` records: the field lookups that the first-child rule does not give, in node order.

`lang`, `src` and `len` follow the rules of `ztree_extract_comments`. Each buffer can be NULL when its size is 0. Each count pointer must not be NULL. The status codes are those of `ztree_extract_comments`. `ZTREE_ERROR_BUFFER_TOO_SMALL` means that one count or both counts are more than the size of the buffer. Both counts are then valid, and each buffer holds its first records.

### Language functions
Each function takes a `ZTREE_LANG_*` value and gives 0 or NULL for an unknown value. A name points into the static data of the library.

| Function | Result |
|---|---|
| `ztree_language_abi_version(lang)` | The Tree-sitter ABI version of the grammar: 14 or 15. |
| `ztree_language_symbol_count(lang)` | The number of symbols, aliases included (`ts_language_symbol_count`). |
| `ztree_language_field_count(lang)` | The largest field id. Field ids start at 1. |
| `ztree_language_symbol_name(lang, symbol)` | The name, `"ERROR"` for `ZTREE_SYMBOL_ERROR` (0xffff), or NULL. |
| `ztree_language_symbol_flags(lang, symbol)` | The bits `ZTREE_SYMBOL_VISIBLE`, `ZTREE_SYMBOL_NAMED` and `ZTREE_SYMBOL_SUPERTYPE`. |
| `ztree_language_field_name(lang, field)` | The name, or NULL for 0 and out of range. |

### `int32_t ztree_regex_match(pattern, pattern_len, text, text_len, matched_out, error_offset_out)`
The function compiles a regex and writes 1 to `*matched_out` when it matches somewhere in the text, as `regexp.Match` of Go does. It uses the engine of the `#match?` predicate. [ADR-0010](/decisions/adr-0010-a-pike-vm-for-an-re2-subset--01a1f0902c3e.md) gives the syntax subset. A pattern error gives code 7 or 8 and the byte offset of the error in `*error_offset_out`. A program that is too large gives code 5.

## Nodes
`ztree_node` has 48 bytes. Each field gives the result of one function of the reference `TSNode` API.

| Field | Type | Value |
|---|---|---|
| `start_byte` … `end_column` | 6 × `uint32_t` | The range and the points, with the rules of `ztree_span`. |
| `parent` | `uint32_t` | The index of the parent, or `ZTREE_NONE` for the root. |
| `next_sibling` | `uint32_t` | The index of the next sibling in cursor order, or `ZTREE_NONE`. |
| `child_count`, `named_child_count` | `uint32_t` | `ts_node_child_count` and `ts_node_named_child_count`. |
| `symbol` | `uint16_t` | `ts_node_symbol`: the public symbol, with the alias applied. |
| `field_id` | `uint16_t` | `ts_tree_cursor_current_field_id`, or 0. |
| `flags` | `uint16_t` | `ZTREE_NODE_NAMED`, `_EXTRA`, `_MISSING`, `_ERROR` and `_HAS_ERROR`. |
| `reserved` | `uint16_t` | 0. |

`ztree_field_override` has 12 bytes: `node`, `child` (or `ZTREE_NONE`), `field_id` and `reserved`. The result of `ts_node_child_by_field_id(node, field_id)` is the child of the override when one exists. Else it is the first child of the node whose `field_id` is the field, or no node. [ADR-0009](/decisions/adr-0009-field-overrides-and-the-node-rules-of-the-flat-tree--01a1f080b1ed.md) gives the cases.

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
| 7 | `ZTREE_ERROR_REGEX_SYNTAX` | Only `ztree_regex_match`: the Go `regexp` package rejects the pattern too. | — |
| 8 | `ZTREE_ERROR_REGEX_UNSUPPORTED` | Only `ztree_regex_match`: valid RE2 syntax that ztree does not read. | — |

Code 5 means that the parse reached a hard limit of `limits` in `src/root.zig`: subtrees, stack nodes, stack versions, tree depth or operations. To get all spans after code 1, call the function again with a buffer of `*count_out` spans. The second call parses the source again.

## Memory and threads
- Each call creates one arena on the C heap and frees it before it returns. The library keeps no memory between calls.
- The library has no global state that changes. Two threads can call the functions at the same time. The external scanners keep their state in a payload for each parse.
- The functions take no callbacks.

## Failures
A failed assertion or a safety check is a bug in ztree. The panic handler writes `ztree: panic: <message>` to stderr and calls `abort()`. It prints no stack trace and starts no thread. A caller cannot recover from it.

## Go binding
`bindings/go` is the Go module `github.com/infrashift/ztree/bindings/go`, package `ztree`. Go owns all memory, so no type has a `Close` method.
- `ExtractComments(lang Lang, src []byte) ([]Span, error)` sizes the buffer from the source length. On code 1 it parses again with a buffer of the exact size.
- `Span` has the same layout as `ztree_span`. Compile-time checks fail the build when the layouts differ.
- `ExtractComments` and `Parser.Parse` return `ErrABIMismatch` when the header and the library have different ABI versions.
- `NewLanguage(lang)` gives the metadata of a grammar: `NodeKindForId`, `NodeKindIsNamed`, `NodeKindIsVisible`, `FieldNameForId`, `FieldIdForName` and the counts.
- `Parser.Parse(src)` makes one cgo call and returns a `*Tree`. It keeps a size hint for each buffer, so one goroutine at a time can use a `Parser`. Two goroutines can read one `Tree` at the same time. The tree keeps no reference to `src`.
- `Node` and `TreeCursor` have the method names of go-tree-sitter. `Node` has `Kind`, `Child`, `NamedChild`, `ChildByFieldName`, `Parent`, the sibling methods, the positions, `Utf8Text`, `HasError`, `Equals`, `ToSexp` and `Walk`. `TreeCursor` has `GotoFirstChild`, `GotoNextSibling`, `GotoParent` and `FieldName`. Each method reads Go memory only.
- `Parse` returns `(*Tree, error)`. go-tree-sitter returns a nil tree on failure.
- The cgo flags read `../../zig-out/include` and `../../zig-out/lib`. Run `zig build lib --release` before `go build`.
- The default C compiler works. With `CC="zig cc"` on a host with two GCC installations, add `-Wno-gcc-install-dir-libstdcxx`. Without it, cgo fails on a warning in `runtime/cgo`.

## Tests
- `src/capi.zig`: the status codes, the bad arguments, the language values, `ztree_parse` and the language functions.
- `tests/capi_test.c`: a C caller of `libztree.a` through `include/ztree.h`. It checks the layouts, each grammar, the points, the buffer rules, the bad arguments, the nodes of a parse and the language functions. `zig build test` runs it.
- `bindings/go`: each grammar, the buffer growth, the errors and calls from 8 goroutines. It compares the comments of the Go files in five GOROOT package trees with `go/parser`, and their functions with `go/ast`. It checks the node API, the cursor and the rules of ADR-0009. `zmake go` runs the tests with the race detector.
- `bindings/go/regex_test.go`: `ztree_regex_match` against the `regexp` package on a table, on 20,000 random patterns and in the fuzz target `FuzzRegex`.
- `zig build differential`: each node of each tree against the reference `TSNode` API, and each field lookup against `ts_node_child_by_field_id`.
