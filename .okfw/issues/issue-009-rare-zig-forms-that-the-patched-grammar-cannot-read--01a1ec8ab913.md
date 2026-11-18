---
id: "01a1ec8a-b913-72f7-8b35-58c6db4785c2"
title: "ISSUE-009: Rare Zig forms that the patched grammar cannot read"
type: "Issue"
kind: "issue"
tags:
  - "issue"
  - "open"
  - "grammar"
  - "zig"
created: "2026-11-17T20:44:36-06:00"
timestamp: "2026-11-17T20:44:36-06:00"
description: "Three rare Zig forms give syntax errors in 5 of 579 files of the Zig 0.17.1 standard library and zmake."
---

# ISSUE-009: Rare Zig forms that the patched grammar cannot read

# ISSUE-009: Rare Zig forms that the patched grammar cannot read

**Status:** open · **Phase:** none

## Description
After [ADR-0006](/decisions/adr-0006-a-patched-zig-grammar-for-zig-0-17-and-empty-containers--01a1ec8a934e.md), the Zig grammar gives syntax errors in 5 of 579 files of the Zig 0.17.1 standard library and zmake. Three forms cause them:

| Form | Example | Files |
|---|---|---|
| An error set as a field type | `w: error{A},` or `struct { error{foo} }` | `Progress.zig`, `zon/parse.zig`, `zon/Serializer.zig` |
| A slice of an `if` type | `[]if (c) A else B` | `Io/Dispatch.zig` |
| An identifier as the asm clobbers | `: clobbers);` | `os/linux/aarch64.zig` |

The parser reads the error set as the left side of a `range_expression` and inserts a MISSING `..`. ztree and the reference runtime give the same tree. The comments of these files come out correctly.

## Acceptance Criteria
- [ ] Add the three forms to the container field type, the slice type and `asm_clobbers` in `zig-0.17.patch`.
- [ ] The generator reports no new conflicts.
- [ ] The differential step on the Zig 0.17.1 standard library shows 0 trees with errors.
- [ ] `zmake check` reports zero errors and zero warnings.

## Related
- [ISSUE-008](/issues/issue-008-zig-0-17-keywords-in-the-zig-grammar--01a1ebfde99b.md)
