---
id: "01a1ebfd-e99b-7f2b-91a7-0eb5c44fc3f8"
title: "ISSUE-008: Zig 0.17 keywords in the Zig grammar"
type: "Issue"
kind: "issue"
tags:
  - "issue"
  - "open"
  - "grammar"
  - "zig"
created: "2026-11-17T18:10:48-06:00"
timestamp: "2026-11-17T18:10:48-06:00"
description: "tree-sitter-zig v1.1.2 reserves async, await and usingnamespace, so Zig 0.17 code that uses them as identifiers gives syntax errors."
---

# ISSUE-008: Zig 0.17 keywords in the Zig grammar

**Status:** open · **Phase:** none

## Description
tree-sitter-zig v1.1.2 reserves the keywords `async`, `await` and `usingnamespace`. Zig 0.17 removed them, and the Zig 0.17.1 standard library uses `await` as an identifier. The grammar gives syntax errors on 71 of 563 files of the Zig 0.17.1 standard library.

## Acceptance Criteria
- [ ] Decide in an ADR: keep the release grammar, or vendor a patched grammar.
- [ ] A patched grammar keeps ABI 14 or 15 and records its generator version in `PIN`.
- [ ] The differential step on the Zig 0.17.1 standard library shows fewer trees with errors.
- [ ] `zmake check` reports zero errors and zero warnings.

## Notes
- semscope solved the same problem (semscope ADR-0010, commit f00fb15). It removes the three keyword rules from `grammar.js` and generates `src/parser.c` with tree-sitter-cli 0.25.10.
- The comments still come out of a tree with errors, and they match the reference runtime. lexis does not need this fix for comment extraction.

## Related
- [ISSUE-006](/issues/issue-006-conformance-with-grammar-corpus-tests-and-the-reference-runtime--01a1e96b8f8a.md) (the differential step found the errors).
