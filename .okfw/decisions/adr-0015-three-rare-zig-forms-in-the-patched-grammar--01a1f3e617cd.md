---
id: "01a1f3e6-17cd-7547-b958-1ff08d00bd6e"
title: "ADR-0015: Three rare Zig forms in the patched grammar"
type: "ADR"
tags:
  - "adr"
  - "grammar"
  - "zig"
created: "2026-11-19T07:01:45-06:00"
timestamp: "2026-11-19T07:01:45-06:00"
description: "The Zig grammar patch accepts an error set as a container field, a slice of an if type and an identifier as the asm clobbers."
---

# ADR-0015: Three rare Zig forms in the patched grammar

**Status:** Accepted
**Date:** 2026-11-19
**Source:** [ISSUE-009](/issues/issue-009-rare-zig-forms-that-the-patched-grammar-cannot-read--01a1ec8ab913.md), [ADR-0006](/decisions/adr-0006-a-patched-zig-grammar-for-zig-0-17-and-empty-containers--01a1ec8a934e.md)

## Context
After ADR-0006, the Zig grammar gives syntax errors in 5 files of the Zig 0.17.1 standard library. Three forms cause them:
- An error set as the type of a container field, such as `w: error{A},`. An error set as a tuple field, such as `struct { error{foo} }`.
- A slice of an `if` type, such as `[]if (c) A else B`.
- An identifier as the asm clobbers, such as `: clobbers);`. Zig 0.15 accepts any comptime value of the type `std.lang.assembly.Clobbers` there.

The grammar reads the error set as the left side of a `range_expression` and inserts a MISSING `..`. It reads the slice element as an expression. It puts the clobbers identifier in an ERROR node.

## Decision
Add three changes to `zig-0.17.patch`:
- `container_field` accepts `error_set_declaration` as the field type and as the tuple field.
- `slice_type` accepts `if_type_expression` as the element type, as `nullable_type` does.
- `asm_clobbers` accepts an `identifier`.

tree-sitter-cli 0.25.10 generates `src/` again. The generator reports no new conflicts. `PIN` records the new SHA-256 values.

## Measurements
| Check | Before | After |
|---|---|---|
| Zig 0.17.1 standard library and zmake: files with errors | 5 of 585 | 0 of 585 |
| Files with a different tree from the old grammar | — | 5, the files of ISSUE-009 |
| Parser states | 1,840 | 1,854 |
| Large parser states | 932 | 936 |

The trees of the other 580 files do not change. `node-types.json` keeps the same node types. Only the child types of `asm_clobbers`, `container_field` and `slice_type` get one more type each. Queries on the trees of the other files see the same nodes.

## Consequences
- ztree reads the Zig 0.17.1 standard library and zmake without syntax errors.
- semscope takes the same `grammar.js` (semscope ADR-0012, 2026-11-19). The two generated parsers are the same, byte for byte.
- `tests/abi_test.zig` holds the new state counts and lex modes of the Zig parser.
- `tests/parser_test.zig` holds one input for each form. Each input gives errors with the grammar of ADR-0006.

## Alternatives considered
- **Accept any expression in `asm_clobbers`.** Rejected: the generator reports a conflict between `asm_clobbers` and the struct literal of `type_expression`. Only an identifier occurs in the standard library.
- **Accept `comptime_type_expression` in `slice_type`.** Rejected: Zig does not accept `[]comptime T`.
- **Take `type_expression` for the container field type.** Rejected: the generator accepts it, and it gives the same trees on the 585 files. But it also accepts forms that are not types, such as `.{}`. The decision adds only the form that ISSUE-009 found.
