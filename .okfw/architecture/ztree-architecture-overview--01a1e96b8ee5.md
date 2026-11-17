---
id: "01a1e96b-8ee5-74dc-a05a-d09bc1ab6d9d"
title: "ztree architecture overview"
type: "Architecture"
tags:
  - "architecture"
  - "overview"
created: "2026-11-17T06:11:42-06:00"
timestamp: "2026-11-17T06:11:42-06:00"
description: "The planned modules of ztree and the data flow of one parse, from source text to comment spans."
---

# ztree architecture overview

This note describes the planned modules of ztree and the data flow of one parse. [ADR-0004](/decisions/adr-0004-a-batch-tree-sitter-runtime-for-abi-14-and-15--01a1e96b8f27.md) defines the scope.

## Data flow
1. The caller gives a language and a source text.
2. The lexer bridge feeds bytes to the lex function of the grammar.
3. For a grammar with an external scanner, the scanner bridge calls `scanner.c` first.
4. The parser reads the parse table and moves each stack version: shift, reduce or accept.
5. Error recovery adds ERROR and MISSING subtrees when no stack version can continue.
6. The parser turns the arena of subtrees into a tree.
7. The cursor walks the tree and collects the comment spans.
8. The C ABI copies the spans into the buffer of the caller.

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
| `src/capi.zig` | The exported C ABI. | 7 |

## Boundaries
- The runtime never calls the reference runtime. Only the test and conformance steps link it.
- The vendored C in `third_party/` stays unchanged. See [ADR-0002](/decisions/adr-0002-zig-0-17-1-the-standard-library-and-vendored-c-grammars--01a1e96b8f06.md) and [ADR-0003](/decisions/adr-0003-adapt-the-nasa-power-of-10-rules-to-ztree--01a1e96b8f17.md).
