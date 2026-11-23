---
x-okfw-id: "01a1ef92-6073-7739-971c-c048af8a1244"
title: "ADR-0007: ztree is the Tree-sitter service of lexis and semscope"
type: "ADR"
tags:
  - "adr"
  - "scope"
  - "semscope"
x-okfw-created: "2026-11-18T10:51:50-06:00"
x-okfw-timestamp: "2026-11-18T10:51:50-06:00"
description: "ztree adds the C++ grammar, a flat-tree node API, a query engine and a bounded regex engine so that semscope can replace go-tree-sitter."
---

# ADR-0007: ztree is the Tree-sitter service of lexis and semscope

**Status:** Accepted
**Date:** 2026-11-18
**Source:** User request. semscope replaces go-tree-sitter with ztree. Each linter then uses a Power of 10 runtime.

## Context
semscope lints Go, C, C++, Zig, Python and Rust code against the Power of 10 rules. It uses go-tree-sitter v0.25.0 through cgo. That C runtime does not follow the Power of 10 rules. lexis already uses ztree for comments. [ADR-0004](/decisions/adr-0004-a-batch-tree-sitter-runtime-for-abi-14-and-15--01a1e96b8f27.md) limits ztree to comment extraction and puts the query engine outside the scope.

semscope uses these parts of go-tree-sitter:
- A full parse of each file. It uses no incremental parse and no included ranges.
- A pre-order cursor over each visible node, anonymous nodes too.
- Node access: kind, field children, named children, all children, parent, previous named sibling, byte ranges, points, text, equality and `HasError`.
- The query engine with captures and the predicates `#eq?`, `#any-of?` and `#match?`. Users write queries in CUE rule sets, so the full query language is part of the contract of semscope.
- Compiled queries that many goroutines share at the same time.

## Decision
ztree becomes the Tree-sitter service of lexis and semscope. This ADR replaces the scope lines of ADR-0004. The pin table of ADR-0004 stays valid.

The scope adds these features:
- The C++ grammar (tree-sitter-cpp v0.23.4, ABI 14, an external scanner).
- The finished tree as a flat array of nodes through the C ABI ([ADR-0008](/decisions/adr-0008-a-flat-tree-and-a-compiled-query-blob-in-caller-memory--01a1ef929e5c.md)).
- A Go node API with the method names of go-tree-sitter.
- A query compiler and a query matcher in Zig, with the predicates `#eq?`, `#not-eq?`, `#any-of?`, `#not-any-of?`, `#match?` and `#not-match?`.
- A bounded regex engine in Zig for `#match?`. It reads a subset of the RE2 syntax.

These features stay outside the scope: incremental reparse and edits, included ranges, WASM, the grammar generator, query directives such as `#set!`, and supertype patterns.

The grammar pins of ztree win. semscope adapts to tree-sitter-c v0.24.2, tree-sitter-rust v0.24.2 and the Zig grammar of [ADR-0006](/decisions/adr-0006-a-patched-zig-grammar-for-zig-0-17-and-empty-containers--01a1ec8a934e.md).

The query engine and the regex engine are in Zig, not in Go. The nasa-lint gate then checks each part of the service.

## Consequences
- `PLAN.md` gets phases 8 to 13, with ISSUE-010 to ISSUE-015.
- The C ABI gets a new version. `ztree_extract_comments` stays the same, so lexis needs no code change.
- The conformance step and the differential step get node API and query checks against the reference runtime.
- semscope removes its patched copy of the Zig grammar and its cgo grammar modules. Its own `PLAN.md` holds that work.
- The query engine and the regex engine add a large amount of code. Each part uses explicit stacks and hard limits ([ADR-0003](/decisions/adr-0003-adapt-the-nasa-power-of-10-rules-to-ztree--01a1e96b8f17.md)).

## Alternatives considered
- **A query engine in Go in the binding.** Rejected by the user: the engine is then outside the Zig gates.
- **A hybrid engine.** Zig matches the patterns, and Go evaluates `#match?` with the `regexp` package. Rejected by the user for the same reason.
- **Keep go-tree-sitter in semscope.** Rejected: the C runtime does not follow the Power of 10 rules.
- **The grammar pins of semscope.** Rejected: lexis and the conformance step already use the pins of ztree.
