---
id: "01a1f309-a44d-7e6a-972b-cfead4db2fd9"
title: "ADR-0014: No repeat depth in a subtree"
type: "ADR"
tags:
  - "adr"
  - "parser"
  - "subtree"
created: "2026-11-19T03:00:57-06:00"
timestamp: "2026-11-19T03:00:57-06:00"
description: "ztree removes repeat_depth from Subtree, because only the balance step of the reference reads it and its u16 add panicked on tables of more than 65,535 items."
---

# ADR-0014: No repeat depth in a subtree

**Status:** Accepted
**Date:** 2026-11-19
**Source:** [ISSUE-017](/issues/issue-017-an-overflow-of-repeat-depth-on-large-repetitions--01a1f2f04d37.md), [ADR-0005](/decisions/adr-0005-one-arena-per-parse-no-reference-counts-and-no-balance-step--01a1ebbb7488.md)

## Context
The reference runtime keeps `repeat_depth`, a `uint16_t`, in each subtree. Only its balance step reads the value. ztree has no balance step ([ADR-0005](/decisions/adr-0005-one-arena-per-parse-no-reference-counts-and-no-balance-step--01a1ebbb7488.md)), so a repetition of n items is a left-deep chain of depth n. ztree kept the field as a `u16` and added 1 for each level of the chain. A table of more than 65,535 items made the add overflow. A safe build then panics, and the C ABI cannot give an error for a panic. Two real files caused this panic: a Go table of P-256 points and a C dictionary of brotli.

## Decision
1. **Remove the field.** `Subtree` has no `repeat_depth`, and `summarizeEnds` does not compute it. No part of ztree read it.
2. **A test for each grammar.** `tests/parser_test.zig` parses a table of 70,000 literals in each of the six grammars. It compares the result with the reference runtime.
3. **A linear check for wide nodes.** The sibling functions of the reference TSNode API scan the siblings of a node. So the comparison of the flat tree with that API costs time in the square of the child count. `checkWide` in `tests/differential.zig` does all checks of `check` except that comparison. It compares the flat tree with the S-expression of the tree. The table test uses `checkWide`.

## Consequences
- A long repetition can no longer stop the process of the caller.
- The other summary fields are `u32` or `i32`. The limits `max_subtrees` (4 Mi) and `max_source_bytes` (16 MiB) keep them in range ([ADR-0003](/decisions/adr-0003-adapt-the-nasa-power-of-10-rules-to-ztree--01a1e96b8f17.md)).
- The walks of `src/tree.zig` and `src/flat.zig` keep explicit stacks. Each stack returns `TreeTooDeep` at `max_tree_depth` (1 Mi).
- The flat tree of a table has the parent and sibling links of [ADR-0009](/decisions/adr-0009-field-overrides-and-the-node-rules-of-the-flat-tree--01a1f080b1ed.md). The table test checks the records through the S-expression. The other tests check the links against the reference.

## Alternatives considered
- **An add that wraps, as in C.** Rejected: the value is then of no use, and ztree does not read it.
- **A `u32` that saturates.** Rejected: this keeps a field that no code reads.
- **The full flat-tree comparison on a table of 70,000 items.** Rejected: one run took more than 10 minutes in a debug build.
