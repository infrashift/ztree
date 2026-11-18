---
id: "01a1ebfd-e99b-7f2b-91a7-0eb5c44fc3f8"
title: "ISSUE-008: Zig 0.17 keywords in the Zig grammar"
type: "Issue"
kind: "issue"
tags:
  - "issue"
  - "closed"
  - "grammar"
  - "zig"
created: "2026-11-17T18:10:48-06:00"
timestamp: "2026-11-17T18:10:48-06:00"
description: "tree-sitter-zig v1.1.2 reserves async, await and usingnamespace, so Zig 0.17 code that uses them as identifiers gives syntax errors."
---

# ISSUE-008: Zig 0.17 keywords in the Zig grammar

**Status:** closed · **Phase:** none

## Description
tree-sitter-zig v1.1.2 reserves the keywords `async`, `await` and `usingnamespace`. Zig 0.17 removed them, and the Zig 0.17.1 standard library uses `await` as an identifier. The grammar gives syntax errors on 71 of 563 files of the Zig 0.17.1 standard library.

## Acceptance Criteria
- [x] Decide in an ADR: keep the release grammar, or vendor a patched grammar.
- [x] A patched grammar keeps ABI 14 or 15 and records its generator version in `PIN`.
- [x] The differential step on the Zig 0.17.1 standard library shows fewer trees with errors.
- [x] `zmake check` reports zero errors and zero warnings.

## Notes
- semscope solved the same problem (semscope ADR-0010, commit f00fb15). It removes the three keyword rules from `grammar.js` and generates `src/parser.c` with tree-sitter-cli 0.25.10.
- The comments still come out of a tree with errors, and they match the reference runtime. lexis does not need this fix for comment extraction.

## Resolution
- [ADR-0006](/decisions/adr-0006-a-patched-zig-grammar-for-zig-0-17-and-empty-containers--01a1ec8a934e.md) records the decision: the semscope patch plus optional container members.
- `third_party/grammars/zig/` holds `grammar.js`, `zig-0.17.patch` and the generated `src/`. The patch applies to the v1.1.2 `grammar.js` and gives the same bytes.
- With the semscope patch only, tree-sitter-cli 0.25.10 gives a `parser.c` that is the same, byte for byte, as the semscope parser.
- The differential step on the Zig 0.17.1 standard library and zmake: 579 files, 0 differences, 46691 comments. Trees with errors went from 71 to 5.
- `tests/parser_test.zig` has a test for Zig 0.17 identifiers, struct clobbers and empty containers. The test fails with the release grammar and with the semscope grammar.
- [ISSUE-009](/issues/issue-009-rare-zig-forms-that-the-patched-grammar-cannot-read--01a1ec8ab913.md) tracks the 5 files that still give errors.

## Related
- [ISSUE-006](/issues/issue-006-conformance-with-grammar-corpus-tests-and-the-reference-runtime--01a1e96b8f8a.md) (the differential step found the errors).
