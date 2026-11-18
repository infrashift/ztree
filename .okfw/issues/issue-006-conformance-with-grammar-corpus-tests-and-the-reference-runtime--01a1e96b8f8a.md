---
id: "01a1e96b-8f8a-71c9-b3ed-b1d2e3a79d80"
title: "ISSUE-006: Conformance with grammar corpus tests and the reference runtime"
type: "Issue"
kind: "issue"
tags:
  - "issue"
  - "phase-6"
  - "conformance"
  - "closed"
created: "2026-11-17T06:11:42-06:00"
timestamp: "2026-11-17T18:10:48-06:00"
description: "Conformance with grammar corpus tests and the reference runtime."
---

# ISSUE-006: Conformance with grammar corpus tests and the reference runtime

**Status:** closed · **Phase:** 6

## Description
Compare ztree with the grammar corpus tests and with the reference runtime.

## Acceptance Criteria
- [x] `zig build conformance` runs each `test/corpus/*.txt` file of each grammar.
- [x] Each corpus test matches the expected S-expression.
- [x] A differential step parses real source files with both runtimes and compares the trees, the S-expressions, the walks and the comments.
- [x] `ZMakefile` and `Makefile` have a `conformance` target, and `check` runs it.
- [x] `zmake check` reports zero errors and zero warnings.

## Notes
tree-sitter-zig v1.1.2 has no `test/corpus/` directory. For Zig, only the differential step applies.
Record each corpus test that ztree skips, and the reason, in this issue.

## Related
- [ADR-0003](/decisions/adr-0003-adapt-the-nasa-power-of-10-rules-to-ztree--01a1e96b8f17.md) (Power of 10) and [ADR-0004](/decisions/adr-0004-a-batch-tree-sitter-runtime-for-abi-14-and-15--01a1e96b8f27.md) (scope).
- [ztree architecture overview](/architecture/ztree-architecture-overview--01a1e96b8ee5.md)

## Resolution
- `tests/conformance_test.zig` ports the corpus reader of the tree-sitter CLI v0.27.2 (`crates/cli/src/test.rs`). It handles header suffixes, attribute lines, the longest divider, the input bytes and the output normalization.
- `zig build conformance`: 420 of 420 corpus examples give the expected tree. No example fails on the reference runtime either. The step also checks the reference, so it can tell a ztree failure from an upstream failure.
- `zig build differential` parses each Go, Zig, Python, C and Rust file of the directories in `-Ddiff-dirs`. It compares the node dump, the S-expression, the walk and the comment spans with the reference runtime. By default it reads `src`, `tests`, `scripts` and the reference runtime source, and `zmake check` runs it.
- External runs on 2026-11-17, all with 0 differences:
  - Zig: zmake `src` and the Zig 0.17.1 standard library. 579 files, 46691 comments.
  - Go: semscope, cobra, go-sarif and CUE. 1065 files.
  - Python: the Python 3.12 standard library. 582 files.
  - Rust: regex, regex-syntax, anyhow, clap_builder, syn and tokio. 817 files.
  - The Go, Python, Rust and C run held 173922 comments.
- Command for an external run: `zig build differential --release -Ddiff-dirs=<dir> -Ddiff-dirs=<dir>`. Add `-Ddiff-list-errors=true` to list each tree with errors.
- A mutation check: wrong field names make the conformance step fail.
- tree-sitter-zig v1.1.2 gives syntax errors on 71 files of the Zig 0.17.1 standard library. ztree matches the reference runtime on these files. [ISSUE-008](/issues/issue-008-zig-0-17-keywords-in-the-zig-grammar--01a1ebfde99b.md) tracks the grammar.
