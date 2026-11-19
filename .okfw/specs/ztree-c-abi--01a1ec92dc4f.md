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

**Version:** 6 (`ZTREE_ABI_VERSION`). Version 2 adds `ZTREE_LANG_CPP`. Version 3 adds `ztree_parse` and the language functions. Version 5 adds `ztree_query_compile` and status code 9 ([ADR-0011](/decisions/adr-0011-a-structural-port-of-the-reference-query-compiler--01a1f0a8133a.md)). Version 6 adds `ztree_query_exec`, the blob accessors, `status_field_id` and `ZTREE_NODE_LATER_FIELD` ([ADR-0012](/decisions/adr-0012-a-port-of-the-reference-query-cursor-over-the-flat-tree--01a1f111feba.md)). Version 4 adds `ztree_regex_match` and status codes 7 and 8 ([ADR-0010](/decisions/adr-0010-a-pike-vm-for-an-re2-subset--01a1f0902c3e.md)) ([ADR-0008](/decisions/adr-0008-a-flat-tree-and-a-compiled-query-blob-in-caller-memory--01a1ef929e5c.md), [ADR-0009](/decisions/adr-0009-field-overrides-and-the-node-rules-of-the-flat-tree--01a1f080b1ed.md)).
**Header:** `include/ztree.h`
**Library:** `zig-out/lib/libztree.a`, from `zig build lib --release`
**Source:** [ISSUE-007](/issues/issue-007-c-abi-and-static-library-for-go-callers--01a1e96b8f9a.md), [ISSUE-011](/issues/issue-011-the-flat-tree-and-the-node-api--01a1ef92fe81.md)

## Purpose
The C ABI gives the comment spans and the syntax tree of a source file to a C or Go caller. lexiscope uses the comment spans through cgo. semscope uses the syntax tree.

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

### `int32_t ztree_query_compile(lang, src, len, blob_out, blob_cap, blob_size_out, error_out)`
The function compiles a query for a grammar and writes a blob with no pointers to `blob_out`. The address of `blob_out` must be a multiple of 4. A caller can copy the blob and share it between threads. The blob is valid only for the library that wrote it: a header holds a magic number, a version and a CRC-32.

- Code 1 gives the size of the blob in `*blob_size_out`.
- Code 9 (`ZTREE_ERROR_QUERY`) fills `*error_out`: the kind, the byte offset, the row and the column. Rows and columns start at 0.
- Code 5 is a query of more than `ZTREE_MAX_QUERY_BYTES` (1 MiB), or a query that needs more than a hard limit.

| Kind | Name | Meaning |
|---|---|---|
| 1 | `ZTREE_QUERY_ERROR_SYNTAX` | As `TSQueryErrorSyntax`. |
| 2 | `ZTREE_QUERY_ERROR_NODE_TYPE` | An unknown node type. |
| 3 | `ZTREE_QUERY_ERROR_FIELD` | An unknown field. |
| 4 | `ZTREE_QUERY_ERROR_CAPTURE` | An unknown capture in a predicate. |
| 5 | `ZTREE_QUERY_ERROR_STRUCTURE` | A pattern that the grammar cannot produce. |
| 6 | `ZTREE_QUERY_ERROR_LANGUAGE` | A grammar of an unsupported ABI version. |
| 7 | `ZTREE_QUERY_ERROR_PREDICATE` | An unknown predicate, wrong arguments or an invalid regex. |
| 8 | `ZTREE_QUERY_ERROR_UNSUPPORTED` | A supertype, a directive or a regex outside the subset. |

### Blob accessors
`ztree_query_pattern_count(blob, blob_len)` and `ztree_query_capture_count(blob, blob_len)` give the counts of a blob, or 0 for a blob that fails its checks. `ztree_query_capture_name(blob, blob_len, index, length_out)` gives a pointer into the blob and the length of the name, or NULL. The name does not end with a zero byte.

### `int32_t ztree_query_exec(blob, blob_len, nodes, node_count, overrides, override_count, src, len, start_node, matches_out, max_matches, match_count_out, captures_out, max_captures, capture_count_out)`
The function runs a compiled query over the flat tree of `ztree_parse`, from the node `start_node` (0 for the root). It writes the matches in the order of `ts_query_cursor_next_match` ([ADR-0012](/decisions/adr-0012-a-port-of-the-reference-query-cursor-over-the-flat-tree--01a1f111feba.md)).
- `ztree_match` has 8 bytes: `pattern_index` and `capture_count`. `ztree_capture` has 8 bytes: `node` (an index into `nodes`) and `index` (a capture id).
- The captures of each match follow the captures of the match before it, in the order of the reference.
- `src[0..len)` is the source of the tree. The text predicates read it. A match that fails a text predicate is not in the result.
- Code 1 gives both counts. The caller then calls again with larger buffers.
- Code 2 is a blob that fails its checks, a tree with a bad link or range, or a start node out of range.
- Code 5 is a run past a hard limit: 65,536 states, 65,536 capture lists or 65,536 captures in one match.
- The tree must come from the grammar of the query. The function cannot check this, so the Go binding checks it.

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
| `flags` | `uint16_t` | `ZTREE_NODE_NAMED`, `_EXTRA`, `_MISSING`, `_ERROR`, `_HAS_ERROR` and `_LATER_FIELD`. |
| `status_field_id` | `uint16_t` | The field id of `ts_tree_cursor_current_status`. It differs from `field_id` only for an extra node in a hidden node with a field. |

`ZTREE_NODE_LATER_FIELD` is `can_have_later_siblings_with_this_field` of `ts_tree_cursor_current_status`. The query cursor reads it and `status_field_id`.

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
| 9 | `ZTREE_ERROR_QUERY` | Only `ztree_query_compile`: 0, and `*error_out` holds the error. | — |

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
- `Parser.Parse(src)` makes one cgo call and returns a `*Tree`. The node buffer scales with the source, with a node count for each KiB from earlier parses. The parser keeps this count, so one goroutine at a time can use a `Parser`. Two goroutines can read one `Tree` at the same time. The tree keeps no reference to `src`.
- `Node` and `TreeCursor` have the method names of go-tree-sitter. `Node` has `Kind`, `Child`, `NamedChild`, `ChildByFieldName`, `Parent`, the sibling methods, the positions, `Utf8Text`, `HasError`, `Equals`, `ToSexp` and `Walk`. `TreeCursor` has `GotoFirstChild`, `GotoNextSibling`, `GotoParent` and `FieldName`. Each method reads Go memory only.
- `Parse` returns `(*Tree, error)`. go-tree-sitter returns a nil tree on failure.
- `NewQuery(language, source)` compiles a query in one cgo call and returns `(*Query, *QueryError)`. `QueryError` has the kind, the row, the column, the offset and a message. `Query` has `PatternCount`, `CaptureNames`, `CaptureIndexForName` and `Language`. Two goroutines can use one `Query` at the same time.
- `QueryCursor.Matches(query, node, text)` runs the query in one cgo call and returns `QueryMatches`. `Next` gives each `QueryMatch` (`PatternIndex` and `Captures`), and `Err` gives the error of the run. A query and a tree of different grammars give `ErrLanguageMismatch`. One goroutine at a time can use a `QueryCursor`.
- The cgo flags read `../../zig-out/include` and `../../zig-out/lib`. Run `zig build lib --release` before `go build`.
- `zig build lib` also writes `libhash.go`, the SHA-256 of `libztree.a`. The Go build cache does not hash the library, so a new library changes this Go file, and the next Go build links again. `LibraryHash()` returns the hash. `TestLibraryHash` fails when the file is old ([ADR-0016](/decisions/adr-0016-a-hash-file-of-libztree-a-in-the-go-binding--01a1f47f0da8.md)).
- LLVM builds `libztree.a` in each mode, so each object marks the stack as not executable. `tools/stackcheck.zig` checks each object, and `TestStackNotExecutable` checks the stack of a Go program ([ADR-0017](/decisions/adr-0017-llvm-builds-libztree-a-in-each-mode--01a1f4eaab0a.md)).
- The default C compiler works. With `CC="zig cc"` on a host with two GCC installations, add `-Wno-gcc-install-dir-libstdcxx`. Without it, cgo fails on a warning in `runtime/cgo`.

## Tests
- `src/capi.zig`: the status codes, the bad arguments, the language values, `ztree_parse` and the language functions.
- `tests/capi_test.c`: a C caller of `libztree.a` through `include/ztree.h`. It checks the layouts, each grammar, the points, the buffer rules, the bad arguments, the nodes of a parse and the language functions. `zig build test` runs it.
- `bindings/go`: each grammar, the buffer growth, the errors and calls from 8 goroutines. It compares the comments of the Go files in five GOROOT package trees with `go/parser`, and their functions with `go/ast`. It checks the node API, the cursor and the rules of ADR-0009. `zmake go` runs the tests with the race detector.
- `zig build query-diff`: the matches of `ztree_query_exec` against `ts_query_cursor_next_match` on the upstream query files and the hand-written queries. Add directories with `-Dquery-dirs`.
- `bindings/go/query_test.go`: the text predicates, the query errors, the API, calls from 8 goroutines and the `ast_query` rules of semscope.
- `tests/query_test.zig`: `ztree_query_compile` against `ts_query_new` on the upstream query files, hand-written queries and their mutations ([ADR-0011](/decisions/adr-0011-a-structural-port-of-the-reference-query-compiler--01a1f0a8133a.md)).
- `bindings/go/bench_test.go`: the speed of a parse, a walk and a query. The [guide to migrate semscope](/guides/migrate-semscope-from-go-tree-sitter-to-ztree--01a1f122b34b.md) gives the results.
- `bindings/go/regex_test.go`: `ztree_regex_match` against the `regexp` package on a table, on 20,000 random patterns and in the fuzz target `FuzzRegex`.
- `zig build differential`: each node of each tree against the reference `TSNode` API, and each field lookup against `ts_node_child_by_field_id`.
