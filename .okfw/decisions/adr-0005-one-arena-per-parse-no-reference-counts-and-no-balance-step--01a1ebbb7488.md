---
id: "01a1ebbb-7488-75b0-aeda-b3b851777c9e"
title: "ADR-0005: One arena per parse, no reference counts and no balance step"
type: "ADR"
tags:
  - "adr"
  - "memory"
  - "parser"
created: "2026-11-17T16:58:13-06:00"
timestamp: "2026-11-17T16:58:13-06:00"
description: "ztree allocates each parse from one arena, copies on makeMut, and leaves out balancing and incremental reuse, with the same visible tree as the reference."
---

# ADR-0005: One arena per parse, no reference counts and no balance step

**Status:** Accepted
**Date:** 2026-11-17
**Source:** Phase 3. A study of `parser.c`, `stack.c` and `subtree.c` of the reference runtime v0.27.2.

## Context
The reference runtime counts references on subtrees and stack nodes. It frees a subtree when the count reaches 0. `ts_subtree_make_mut` changes a subtree in place when the count is 1, and copies it otherwise. After a parse, the reference balances repetition subtrees and supports incremental reuse of an old tree. ADR-0003 asks for no allocation after initialization and no recursion.

## Decision
- **One arena per parse.** Subtrees, child arrays, stack nodes and pop slices come from one arena. ztree frees nothing before the parse ends. Hard limits cap the subtrees and the stack nodes.
- **No reference counts.** `makeMut` always copies. Each other change in place in `parser.c` touches a new subtree that no other holder can see. The tree is therefore the same.
- **No inline subtrees.** Every subtree is a heap subtree. The equality checks of the stack compare the same fields, so the result is the same.
- **No balance step.** The balance step rotates hidden repetition nodes only. The visible tree does not change. The tests flatten repetition nodes before they compare trees.
- **No incremental reuse.** Each lookahead is a leaf, so no stack link is pending. `breakdown_top_of_stack` and `pop_pending` have no effect, and ztree leaves them out.
- **Explicit stacks.** The merge of stack nodes in `stack_node_add_link` uses a frame stack. The frame stack keeps the depth-first order of the recursion, because the link order sets the order of the slices.

## Consequences
- Memory grows with the work of the parse. The limits `max_subtrees` and `max_stack_nodes` in `src/root.zig` bound it.
- Repetition subtrees stay deep on the left side. Each walk of the tree uses an explicit stack.
- ztree keeps no `repeat_depth`, because only the balance step reads it ([ADR-0014](/decisions/adr-0014-no-repeat-depth-in-a-subtree--01a1f309a44d.md)).
- `tests/parser_test.zig` compares each node of the flattened tree with the reference runtime.

## Alternatives considered
- **Port the reference counts.** Rejected: the counts only decide between a copy and a change in place. They add code and give the same tree.
- **Port the balance step.** Rejected for now: it changes no visible node.
