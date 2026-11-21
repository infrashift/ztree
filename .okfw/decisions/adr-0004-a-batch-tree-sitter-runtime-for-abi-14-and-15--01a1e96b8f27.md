---
id: "01a1e96b-8f27-7ac5-90a7-415ea0a6c5f2"
title: "ADR-0004: A batch Tree-sitter runtime for ABI 14 and 15"
type: "ADR"
tags:
  - "adr"
  - "scope"
created: "2026-11-17T06:11:42-06:00"
timestamp: "2026-11-17T06:11:42-06:00"
description: "ztree parses whole files with generated grammars of ABI 14 and 15 and extracts comments, with no incremental edits or queries."
---

# ADR-0004: A batch Tree-sitter runtime for ABI 14 and 15

**Status:** Accepted. [ADR-0007](/decisions/adr-0007-ztree-is-the-tree-sitter-service-of-lexis-and-semscope--01a1ef926073.md) replaces the scope lines. The pin table stays valid.
**Date:** 2026-11-17
**Source:** User request: a Tree-sitter runtime in Zig under the Power of 10 rules, for comment extraction in lexis.

## Context
lexis lints prose in source comments. It needs the comments of Go, Zig, Python, C and Rust files. The full Tree-sitter runtime has incremental edits, a query engine and WASM support. lexis needs none of these.

## Decision
ztree is a batch runtime with this scope:

- Load generated grammars with `TSLanguage` ABI version 14 or 15.
- Parse one source text from start to end: lex, shift, reduce, accept and GLR stack versions.
- Recover from syntax errors with ERROR and MISSING nodes. Use the cost model of the reference runtime.
- Walk the finished tree with an iterative cursor and print S-expressions for the tests.
- Extract comment spans with one table of comment node types per language.
- Export a C ABI with a caller-owned, bounded output buffer and no callbacks.

These features are outside the scope: incremental reparse and edits, the query engine, WASM, included ranges and the grammar generator.

**Pinned versions** (checked on 2026-11-17):

| Source | Tag | ABI version | External tokens |
|---|---|---|---|
| tree-sitter (reference runtime) | v0.27.2 | 15 (reads 13 to 15) | n/a |
| tree-sitter-go | v0.25.0 | 15 | 0 |
| tree-sitter-python | v0.25.0 | 15 | 12 |
| tree-sitter-c | v0.24.2 | 15 | 0 |
| tree-sitter-rust | v0.24.2 | 15 | 11 |
| tree-sitter-zig (tree-sitter-grammars) | v1.1.2 with a patch (ADR-0006, ADR-0015) | 14 | 0 |
| tree-sitter-cpp (added by ADR-0007, checked on 2026-11-18) | v0.23.4 | 14 | 2 |
| tree-sitter-c-sharp (added by ADR-0019, checked on 2026-11-21) | v0.24.0 | 15 | 14 |

## Consequences
- ztree supports two struct layouts because the Zig grammar uses ABI 14.
- The Python and Rust grammars call their external scanners through the scanner bridge.
- The conformance step compares ztree trees with the corpus tests of each grammar and with the reference runtime.

## Alternatives considered
- **Hand-written comment lexers in Go inside lexis.** Rejected by the user in favour of a Tree-sitter runtime.
- **Link the reference runtime through cgo.** Rejected: the C runtime does not follow the Power of 10 rules.
- **A full port that includes the generator and incremental edits.** Rejected: the size of the work is many times larger than the need.
