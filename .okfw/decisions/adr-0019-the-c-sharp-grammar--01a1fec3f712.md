---
x-okfw-id: "01a1fec3-f712-72e3-93e5-4a5159f33103"
title: "ADR-0019: The C# grammar"
type: "ADR"
tags:
  - "adr"
  - "grammar"
  - "scope"
x-okfw-created: "2026-11-21T09:40:18-06:00"
x-okfw-timestamp: "2026-11-21T09:40:23-06:00"
description: "ztree vendors tree-sitter-c-sharp v0.24.0 as its seventh grammar, with ZTREE_LANG_CSHARP and C ABI version 7, so semscope and lexiscope can read C# files."
---

# ADR-0019: The C# grammar

**Status:** Accepted
**Date:** 2026-11-21
**Source:** User request on 2026-11-21: semscope and lexiscope check C# files. [ISSUE-023](/issues/issue-023-the-c-sharp-grammar--01a1fec3b918.md) records the work.

## Context
ztree has six grammars ([ADR-0007](/decisions/adr-0007-ztree-is-the-tree-sitter-service-of-lexis-and-semscope--01a1ef926073.md)). semscope checks the Power of 10 rules, and lexiscope checks the comments, only in files that a grammar of ztree reads. Neither tool reads C# files. ADR-0002 requires an ADR before a new vendored source tree.

tree-sitter-c-sharp v0.24.0 is the last release. Its `parser.c` uses ABI 15 and is 37 MB. Its external scanner has 14 tokens for the strings, the raw strings and the interpolated strings. It has 9,756 states and 575 symbols. These counts are larger than the counts of the C++ grammar, but each count fits in the `u16` ids of `src/abi.zig`.

## Decision
- Vendor tree-sitter-c-sharp v0.24.0 (commit `d4bbe18103c3380c6454085e589d2610938da142`) into `third_party/grammars/c-sharp/`: `src/`, `LICENSE`, `test/corpus/` and a `PIN` file. Copy the upstream `highlights.scm` to `tests/queries/csharp/`. Make no local change.
- `grammars.Lang` gets `csharp`. Its comment kind is `comment`. One node of this kind holds a `//`, `///` or `/* */` comment.
- The C ABI gets `ZTREE_LANG_CSHARP` (6), and its version becomes 7. The Go binding gets `LangCSharp`, with the name `csharp`.
- The conformance step reads the 19 files of the C# corpus. The lexer, parser and query tests get C# inputs.

## Consequences
- The pin table of ADR-0004 gets a row for tree-sitter-c-sharp.
- A build of `libztree.a` compiles one more large `parser.c`, so the first build takes more time.
- The C ABI version changes, but no function changes. lexiscope and semscope build with the new library and need no change for the six old grammars.
- The C# grammar has nine visible supertypes: `declaration`, `expression`, `non_lvalue_expression`, `lvalue_expression`, `literal`, `statement`, `type`, `type_declaration` and `pattern`. ztree does not compile a supertype pattern ([ADR-0007](/decisions/adr-0007-ztree-is-the-tree-sitter-service-of-lexis-and-semscope--01a1ef926073.md)). So a C# query of semscope must name the concrete node types, for example `predefined_type` in place of `type`. The upstream `tags.scm` uses the pattern `(type ...)`, so the query corpus does not hold it.
- The default differential step reads no C# file, because the upstream repository has no `examples/`. A manual run on real C# code checks the grammar against the reference runtime. The Resolution of ISSUE-023 records the result.

## Alternatives considered
- **A C# grammar with a lower ABI or an older tag.** Rejected: ztree reads ABI 14 and 15, and the last tag has the newest C# syntax.
- **Vendor the upstream `bindings/` and `examples/` too.** Rejected: ztree uses its own binding, and the upstream repository has no examples.

## Related
- [ADR-0004](/decisions/adr-0004-a-batch-tree-sitter-runtime-for-abi-14-and-15--01a1e96b8f27.md) (pin table)
- [ztree C ABI](/specs/ztree-c-abi--01a1ec92dc4f.md)
