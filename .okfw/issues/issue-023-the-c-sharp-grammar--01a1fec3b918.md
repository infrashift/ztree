---
id: "01a1fec3-b918-79cb-bf1a-20b589ebbad8"
title: "ISSUE-023: The C# grammar"
type: "Issue"
kind: "issue"
tags:
  - "issue"
  - "phase-22"
  - "grammar"
  - "closed"
created: "2026-11-21T09:40:02-06:00"
timestamp: "2026-11-21T09:40:09-06:00"
description: "Vendor tree-sitter-c-sharp and add it as the seventh grammar, so semscope and lexiscope can read C# files."
---

# ISSUE-023: The C# grammar

**Status:** closed · **Phase:** 22

## Description
Vendor tree-sitter-c-sharp and add it as the seventh grammar. semscope checks the Power of 10 rules in C# files, and lexiscope checks their comments ([ADR-0019](/decisions/adr-0019-the-c-sharp-grammar--01a1fec3f712.md)).

## Acceptance Criteria
- [x] `third_party/grammars/c-sharp/` holds tree-sitter-c-sharp v0.24.0: `src/`, `LICENSE`, `test/corpus/` and a `PIN` file.
- [x] `grammars.Lang` has `csharp`. `build.zig` compiles `parser.c` and `scanner.c`.
- [x] The comment kind of C# gives the same spans as the reference runtime.
- [x] `include/ztree.h` has `ZTREE_LANG_CSHARP`, and the C ABI version is 7. The Go binding has `LangCSharp`.
- [x] The conformance step reads the C# corpus. The lexer, parser and query tests have C# inputs.
- [x] A differential run on real C# code agrees with the reference runtime.
- [x] `zmake check` and `make check` pass.

## Related
- [ADR-0004](/decisions/adr-0004-a-batch-tree-sitter-runtime-for-abi-14-and-15--01a1e96b8f27.md) (pin table)
- [ISSUE-010](/issues/issue-010-the-c-grammar--01a1ef92fe7b.md): the C++ grammar

## Resolution
- tree-sitter-c-sharp v0.24.0 is the last release. Its grammar uses ABI 15, and its external scanner has 14 tokens. It has 9,756 states and 575 symbols, more than the C++ grammar.
- The conformance step passes all 193 C# corpus examples. The total is 792 examples.
- A manual differential run read 15,651 C# files of the EF Core and ASP.NET Core sources: `zig build differential --release -Ddiff-dirs=<dir>`. Each tree, each flat node and each comment span equals the reference. 638 files have syntax errors in both runtimes, so error recovery also matches. No parse reached the bound of 256 stack heads ([ADR-0013](/decisions/adr-0013-a-bound-of-256-glr-stack-heads--01a1f2f0124a.md)).
- The first run found 46 files where `tree.writeVisibleSexp` and the flat tree disagree. Each file has an ERROR node with hidden children only. The flat tree shows such a node as a leaf, as the cursor does. `tree.writeVisibleSexp` now does the same, and a dated note in [ADR-0009](/decisions/adr-0009-field-overrides-and-the-node-rules-of-the-flat-tree--01a1f080b1ed.md) records the rule. A test in `src/flat.zig` holds the reduced input `int x)\n[A] T h,\n`.
- The upstream `tags.scm` uses the supertype pattern `(type ...)`, and ztree does not compile supertype patterns (ADR-0007). `tests/queries/csharp/` holds `highlights.scm` only. ADR-0019 records the limit for C# queries.
- The C ABI version is now 7. lexiscope and semscope build with the new library.

