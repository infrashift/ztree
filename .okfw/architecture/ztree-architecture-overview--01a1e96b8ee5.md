---
id: "01a1e96b-8ee5-74dc-a05a-d09bc1ab6d9d"
title: "ztree architecture overview"
type: "Architecture"
tags:
  - "architecture"
  - "overview"
created: "2026-11-17T06:11:42-06:00"
timestamp: "2026-11-17T06:11:42-06:00"
description: "The modules of ztree and the data flow of one parse, from source text to comment spans and the flat tree."
---

# ztree architecture overview

This note describes the modules of ztree and the data flow of one parse. [ADR-0004](/decisions/adr-0004-a-batch-tree-sitter-runtime-for-abi-14-and-15--01a1e96b8f27.md) and [ADR-0007](/decisions/adr-0007-ztree-is-the-tree-sitter-service-of-lexis-and-semscope--01a1ef926073.md) define the scope. Phases 9 to 12 add the flat tree, the regex engine and the query engine ([ADR-0008](/decisions/adr-0008-a-flat-tree-and-a-compiled-query-blob-in-caller-memory--01a1ef929e5c.md)).

## Data flow
1. The caller gives a language and a source text.
2. The lexer bridge feeds bytes to the lex function of the grammar.
3. For a grammar with an external scanner, the scanner bridge calls `scanner.c` first.
4. The parser reads the parse table and moves each stack version: shift, reduce or accept.
5. Error recovery adds ERROR and MISSING subtrees when no stack version can continue.
6. The parser turns the arena of subtrees into a tree.
7. The cursor walks the tree and collects the comment spans. Or the flattener writes the visible nodes as flat records and the field overrides ([ADR-0009](/decisions/adr-0009-field-overrides-and-the-node-rules-of-the-flat-tree--01a1f080b1ed.md)).
8. The C ABI copies the spans or the records into the buffers of the caller.

## Modules
| File | Responsibility | Phase |
|---|---|---|
| `src/root.zig` | Library root and hard limits. | 0 |
| `src/abi.zig` | `extern struct` mirrors of `TSLanguage` (ABI 14 and 15), `TSLexer` and the parse actions. The only file with function pointers. | 1 |
| `src/utf8.zig` | UTF-8 decode with the ICU `U8_NEXT` rules. | 2 |
| `src/length.zig` | `Point` and `Length`: byte, row and column positions. | 2 |
| `src/lexer.zig` | The `TSLexer` implementation for one source buffer. | 2 |
| `src/language.zig` | Parse table lookups and the lookahead iterator. | 3 |
| `src/subtree.zig` | Subtrees in the parse arena, with no reference counts (ADR-0005). | 3 |
| `src/stack.zig` | The GLR stack. The parser keeps at most 6 versions after each round. | 3 |
| `src/parser.zig` | The LR loop and the external scanner bridge. | 3 |
| `src/recover.zig` | Error recovery. Valid input uses it too. | 3 |
| `src/tree.zig` | Nodes, the cursor and S-expression output. | 5 |
| `src/comments.zig` | Comment node types per language and span extraction. | 5 |
| `src/query.zig` | The query parser: a port of `ts_query_new` with a frame stack ([ADR-0011](/decisions/adr-0011-a-structural-port-of-the-reference-query-compiler--01a1f0a8133a.md)). | 11 |
| `src/query_analysis.zig` | The parse-table analysis of each pattern: structure errors and fallible steps. | 11 |
| `src/query_predicates.zig` | The text predicates, checked as go-tree-sitter checks them. | 11 |
| `src/query_blob.zig` | The compiled query blob with no pointers, and its read view. | 11 |
| `src/query_exec.zig` | The query cursor: a port of `ts_query_cursor__advance` over the flat tree, and the text predicates ([ADR-0012](/decisions/adr-0012-a-port-of-the-reference-query-cursor-over-the-flat-tree--01a1f111feba.md)). | 12 |
| `src/regex.zig` | The regex engine of `#match?`: an RE2 subset and a Pike VM ([ADR-0010](/decisions/adr-0010-a-pike-vm-for-an-re2-subset--01a1f0902c3e.md)). | 10 |
| `src/flat.zig` | The flat tree: one record for each visible node with its cursor status, the field overrides, and the S-expression of the records. | 9, 12 |
| `src/capi.zig` | The exported C ABI and the panic handler of `libztree.a`. See the [C ABI spec](/specs/ztree-c-abi--01a1ec92dc4f.md). | 7 |
| `bindings/go/` | The Go binding (cgo) of the C ABI: `ExtractComments`, and `Parser`, `Tree`, `Node`, `TreeCursor`, `Query` and `QueryCursor` with the method names of go-tree-sitter. | 7, 9, 12 |

## Boundaries
- `libztree.a` needs only libc. It holds no reference runtime, prints no stack trace and starts no thread.
- The runtime never calls the reference runtime. Only the test and conformance steps link it.
- The vendored C in `third_party/` stays unchanged. One exception: ztree generates the Zig grammar from a patched `grammar.js` ([ADR-0006](/decisions/adr-0006-a-patched-zig-grammar-for-zig-0-17-and-empty-containers--01a1ec8a934e.md)). See [ADR-0002](/decisions/adr-0002-zig-0-17-1-the-standard-library-and-vendored-c-grammars--01a1e96b8f06.md) and [ADR-0003](/decisions/adr-0003-adapt-the-nasa-power-of-10-rules-to-ztree--01a1e96b8f17.md).
