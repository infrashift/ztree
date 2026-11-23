---
x-okfw-id: "01a1f111-feba-73be-a57f-7e24008de5fb"
title: "ADR-0012: A port of the reference query cursor over the flat tree"
type: "ADR"
tags:
  - "adr"
  - "query"
  - "semscope"
x-okfw-created: "2026-11-18T17:50:50-06:00"
x-okfw-timestamp: "2026-11-18T17:50:50-06:00"
description: "src/query_exec.zig ports ts_query_cursor__advance and next_match over the flat tree, with the cursor status in each node and the text predicates of go-tree-sitter."
---

# ADR-0012: A port of the reference query cursor over the flat tree

# ADR-0012: A port of the reference query cursor over the flat tree

**Status:** Accepted
**Date:** 2026-11-18
**Source:** [ISSUE-014](/issues/issue-014-query-execution--01a1ef92fe94.md), [ADR-0008](/decisions/adr-0008-a-flat-tree-and-a-compiled-query-blob-in-caller-memory--01a1ef929e5c.md)

## Context
semscope reports a finding for each match of a rule. So the matches of ztree must equal the matches of go-tree-sitter: the same patterns, order and captures ([ADR-0007](/decisions/adr-0007-ztree-is-the-tree-sitter-service-of-lexis-and-semscope--01a1ef926073.md)). The reference cursor walks the tree with a `TSTreeCursor` and reads `ts_tree_cursor_current_status` at each node. The status has the field id, the later siblings and a flag for a later sibling with the same field. The flat tree of [ADR-0009](/decisions/adr-0009-field-overrides-and-the-node-rules-of-the-flat-tree--01a1f080b1ed.md) did not keep the last two values.

## Decision
1. **A structural port.** `src/query_exec.zig` ports `ts_query_cursor__advance` and `ts_query_cursor_next_match` of the vendored `query.c`. It keeps the state list, the capture list pool and the list of finished states in FIFO order. The reference cursor also enters hidden nodes, but it changes its states only on visible nodes. So a walk over the flat records in pre-order gives the same events.
2. **The status in the flat tree.** The flattener writes `status_field_id` and the flag `ZTREE_NODE_LATER_FIELD` into each `ztree_node`. `status_field_id` differs from `field_id` only for an extra node in a hidden node with a field. The flag is true when a later child can have the field of the node. The production of the parent, or of a hidden node between them, gives this child. The cursor computes the later-sibling bits from the `next_sibling` links.
3. **The quirks of the reference.** `start_depth` is a `uint16_t` in the reference and wraps for a pattern that starts at its DONE step. ztree keeps the `u16` and the wrap, so an empty match of `[...]*` has the same result.
4. **Text predicates as in go-tree-sitter.** The reference cursor does not run predicates. ztree runs them as `SatisfiesTextPredicate` of go-tree-sitter v0.25 does, and drops a match that fails one. The `any-` forms pass when no node of the capture is a hit. `#eq?` with two captures compares the nodes in pairs, and passes only when both lists have the same length.
5. **Hard limits.** One run has at most 65,536 states and 65,536 capture lists, and one match has at most 65,536 captures. A run past a limit gives `ZTREE_ERROR_LIMIT_REACHED`. The reference has no default limit. It drops states only after a caller sets a match limit. ztree reports its limit, so a caller does not get a partial result.
6. **The C ABI is version 6.** `ztree_query_exec` takes the blob, the flat tree, the source and a start node. It writes `ztree_match` and `ztree_capture` records to caller memory. The captures of each match follow the captures of the match before it. `ztree_query_pattern_count`, `ztree_query_capture_count` and `ztree_query_capture_name` read the blob. The function checks the blob CRC and the links of the tree before it walks the tree.

## Consequences
- `zig build query-diff` compares ztree with `ts_query_cursor_next_match` of the reference. It runs each upstream query file and each hand-written query over the grammar corpus and this repository. `zmake check` runs it. The run disables the text predicates on both sides.
- A run over `go/ast` of the Go source tree gives 256,583 equal matches and 155,133 equal captures.
- `ztree_node` keeps 48 bytes: `status_field_id` uses the old `reserved` field. A tree from an ABI version 5 library has no status values, so a caller must parse again.
- A run needs the text of the tree for the predicates. The tree does not keep a reference to it.

## Alternatives considered
- **A new matcher with its own design.** Rejected: the match order and the duplicate matches of the reference depend on the state list. They also depend on the split of a state at each fallible step.
- **Compute the status from the parse table at run time.** Rejected: the cursor then needs the hidden nodes, which the flat tree does not keep.
- **Run the predicates in Go.** Rejected: ADR-0008 sets one cgo call for each run. The Go caller then also needs a regex engine equal to the engine of the compiler.
