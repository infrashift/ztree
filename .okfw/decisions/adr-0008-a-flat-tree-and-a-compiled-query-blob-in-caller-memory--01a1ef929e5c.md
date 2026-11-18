---
id: "01a1ef92-9e5c-773d-89fe-868e4fa84810"
title: "ADR-0008: A flat tree and a compiled query blob in caller memory"
type: "ADR"
tags:
  - "adr"
  - "capi"
  - "semscope"
created: "2026-11-18T10:52:05-06:00"
timestamp: "2026-11-18T10:52:05-06:00"
description: "The C ABI writes the finished tree as a flat node array and a compiled query as a pointer-free blob, both in caller memory, with no handles and no callbacks."
---

# ADR-0008: A flat tree and a compiled query blob in caller memory

**Status:** Accepted
**Date:** 2026-11-18
**Source:** [ADR-0007](/decisions/adr-0007-ztree-is-the-tree-sitter-service-of-lexis-and-semscope--01a1ef926073.md). The semscope use of go-tree-sitter.

## Context
The C ABI of ztree takes no callbacks, keeps no global state and writes into buffers that the caller owns ([C ABI spec](/specs/ztree-c-abi--01a1ec92dc4f.md)). Two threads can call it at the same time. semscope needs node access, a cursor and queries. go-tree-sitter gives these through opaque handles and one cgo call for each node method. semscope calls node methods millions of times for each scan, and it shares each compiled query across worker goroutines.

## Decision
Keep the current ABI style. Each new function is a pure function of its arguments. No memory stays on the C heap between calls.

1. **Flat tree.** `ztree_parse` writes the visible nodes of the tree in pre-order into an array of `ztree_node` records. A record holds:
   - the byte range and the start and end points,
   - the index of the parent and of the next sibling, the child count and the named child count,
   - the public symbol, with the alias applied, as `ts_node_symbol` gives it,
   - the field id of the node in its parent, inherited through hidden nodes,
   - the flags named, extra, missing, error and has_error.

   The first child of a node with children is at the next index. A buffer that is too small gives `ZTREE_ERROR_BUFFER_TOO_SMALL` and the node count, as `ztree_extract_comments` does.
2. **Language metadata.** Functions return the symbol and field counts, the ABI version, the symbol names and flags, and the field names. Names point into the static data of the grammar.
3. **Compiled query blob.** `ztree_query_compile` writes a compiled query into caller memory. The blob holds no pointers, so the caller can copy it and share it. A compile error gives its kind and its position in the query text.
4. **Query execution.** `ztree_query_exec` reads a blob, a flat tree and the source text. It writes capture records (match, pattern, capture, node) into caller memory, in the match order of the reference runtime.

The Go binding implements the node methods and the cursor over a Go slice of records. A node method then needs no cgo call. Go owns all memory, so the binding has no `Close` method.

## Consequences
- The binding is fast: one cgo call parses a file, and one cgo call runs a query over a tree.
- Thread safety needs no lock. A blob and a flat tree are read-only after the call that writes them.
- A record takes about 48 bytes. A tree holds at most `max_subtrees` nodes, so a tree takes at most about 200 MB.
- A caller that guesses a small buffer parses the file twice. The Go binding keeps a size hint for each parser, so this is rare.
- The flat tree is a copy of the subtree arena. Each node method of the binding must give the same result as the reference runtime. The differential step checks each node against the reference `TSNode` API.

## Alternatives considered
- **Opaque handles for trees and queries.** Rejected: the C heap then keeps memory between calls, and each node method needs a cgo call.
- **A callback for each match.** Rejected: the ABI takes no callbacks ([ADR-0003](/decisions/adr-0003-adapt-the-nasa-power-of-10-rules-to-ztree--01a1e96b8f17.md), rule 9).
- **Parse and query in one call.** Rejected: semscope walks each tree and runs many queries over it. One call for each query then parses the file again.
