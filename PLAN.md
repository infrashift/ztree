# PLAN.md — ztree

ztree is a batch Tree-sitter runtime in Zig 0.17.1 under the NASA Power of 10 rules. lexiscope uses it to extract the comments of source files. semscope uses its trees and queries in place of go-tree-sitter (ADR-0007).

Work on one phase at a time (`CLAUDE.md` rule 1). Each phase from 1 to 20 has a mirror issue in the OKF wiki (`.okfw/issues/`). When you finish a phase, tick this checklist and the acceptance criteria of the issue.

Loop: do one task, run `zmake check`, and repeat until green. Then update the wiki and commit once per phase.

- Architecture: [ztree architecture overview](.okfw/architecture/ztree-architecture-overview--01a1e96b8ee5.md)
- Decisions, part 1: [ADR-0001 wiki](.okfw/decisions/adr-0001-adopt-an-okf-wiki-okfw-for-project-knowledge--01a1e96b8ef6.md) · [ADR-0002 toolchain](.okfw/decisions/adr-0002-zig-0-17-1-the-standard-library-and-vendored-c-grammars--01a1e96b8f06.md) · [ADR-0003 Power of 10](.okfw/decisions/adr-0003-adapt-the-nasa-power-of-10-rules-to-ztree--01a1e96b8f17.md) · [ADR-0004 scope](.okfw/decisions/adr-0004-a-batch-tree-sitter-runtime-for-abi-14-and-15--01a1e96b8f27.md)
- Decisions, part 2: [ADR-0005 arena](.okfw/decisions/adr-0005-one-arena-per-parse-no-reference-counts-and-no-balance-step--01a1ebbb7488.md) · [ADR-0006 Zig grammar](.okfw/decisions/adr-0006-a-patched-zig-grammar-for-zig-0-17-and-empty-containers--01a1ec8a934e.md) · [ADR-0007 semscope scope](.okfw/decisions/adr-0007-ztree-is-the-tree-sitter-service-of-lexis-and-semscope--01a1ef926073.md) · [ADR-0008 flat tree ABI](.okfw/decisions/adr-0008-a-flat-tree-and-a-compiled-query-blob-in-caller-memory--01a1ef929e5c.md) · [ADR-0009 field overrides](.okfw/decisions/adr-0009-field-overrides-and-the-node-rules-of-the-flat-tree--01a1f080b1ed.md) · [ADR-0011 query compiler](.okfw/decisions/adr-0011-a-structural-port-of-the-reference-query-compiler--01a1f0a8133a.md) · [ADR-0010 regex](.okfw/decisions/adr-0010-a-pike-vm-for-an-re2-subset--01a1f0902c3e.md)
- Decisions, part 3: [ADR-0012 query cursor](.okfw/decisions/adr-0012-a-port-of-the-reference-query-cursor-over-the-flat-tree--01a1f111feba.md) · [ADR-0013 stack heads](.okfw/decisions/adr-0013-a-bound-of-256-glr-stack-heads--01a1f2f0124a.md) · [ADR-0014 repeat depth](.okfw/decisions/adr-0014-no-repeat-depth-in-a-subtree--01a1f309a44d.md) · [ADR-0015 Zig forms](.okfw/decisions/adr-0015-three-rare-zig-forms-in-the-patched-grammar--01a1f3e617cd.md) · [ADR-0016 Go cache](.okfw/decisions/adr-0016-a-hash-file-of-libztree-a-in-the-go-binding--01a1f47f0da8.md) · [ADR-0017 stack note](.okfw/decisions/adr-0017-llvm-builds-libztree-a-in-each-mode--01a1f4eaab0a.md) · [ADR-0018 vocabulary](.okfw/decisions/adr-0018-lexis-checks-the-documentation-with-a-repository-vocabulary--01a1f525ba3d.md)
- Rules: ADR-0003 for the code. ASD-STE100 for all documentation.

## Phase 0 — Bootstrap
- [x] Create the git repo, `.gitignore`, `build.zig` and `build.zig.zon` with Zig 0.17.1
- [x] Copy `scripts/nasa-lint.py` and `scripts/ste-check.py` from zmake without changes
- [x] Create the OKF wiki (`okfw init`, `okfw install --platform claude`) and `.mcp.json`
- [x] Write `ZMakefile` and `Makefile` with the same targets
- [x] Write `CLAUDE.md` and `PLAN.md`
- [x] Seed the wiki: guides, architecture, ADR-0001 to ADR-0004, ISSUE-001 to ISSUE-007

## Phase 1 — Vendor and ABI
Issue: [ISSUE-001](.okfw/issues/issue-001-vendor-the-reference-runtime-and-the-grammars-and-mirror-the-c-abi--01a1e96b8f38.md)
- [x] Vendor the reference runtime and the five grammars at the pinned tags into `third_party/`
- [x] Compile each grammar in `build.zig` with the Zig C compiler
- [x] Mirror `TSLanguage` (ABI 14 and 15), `TSLexer`, `TSParseAction` and `TSLexMode` in `src/abi.zig`
- [x] Test each language: ABI version, symbol count and state count

## Phase 2 — Lexer bridge
Issue: [ISSUE-002](.okfw/issues/issue-002-lexer-bridge-for-the-lex-function-and-the-external-scanners--01a1e96b8f48.md)
- [x] Write `TSLexer` in `src/lexer.zig`: UTF-8 decode, byte, row and column positions
- [x] Compare the lex results of each grammar with the reference lexer at sampled positions and in each lex state

## Phase 3 — Parser core
Issue: [ISSUE-003](.okfw/issues/issue-003-parser-core-with-the-subtree-arena-and-the-glr-stack--01a1e96b8f58.md)
- [x] Add the subtree arena (`src/subtree.zig`) and the GLR stack (`src/stack.zig`)
- [x] Add the LR loop and the external scanner bridge (`src/parser.zig`)
- [x] Parse valid sample files of each grammar with no ERROR node

## Phase 4 — Error recovery
Phase 3 delivers this phase: the reference runtime runs its recovery code for valid input too.
Issue: [ISSUE-004](.okfw/issues/issue-004-error-recovery-with-error-and-missing-nodes--01a1e96b8f69.md)
- [x] Add ERROR and MISSING nodes and token skips (`src/recover.zig`)
- [x] Match the trees of the reference runtime for invalid sample files

## Phase 5 — Tree API and comments
Issue: [ISSUE-005](.okfw/issues/issue-005-tree-api-cursor-and-comment-extraction--01a1e96b8f79.md)
- [x] Add nodes, the iterative cursor and S-expression output (`src/tree.zig`)
- [x] Add comment node types per language and `extractComments` (`src/comments.zig`)

## Phase 6 — Conformance
Issue: [ISSUE-006](.okfw/issues/issue-006-conformance-with-grammar-corpus-tests-and-the-reference-runtime--01a1e96b8f8a.md)
- [x] Run the corpus tests of each grammar in `zig build conformance`
- [x] Compare trees with the reference runtime for real source files
- [x] Add the `conformance` target to `ZMakefile`, `Makefile` and `check`

## Open issues
None.

Closed: [ISSUE-018](.okfw/issues/issue-018-the-go-build-cache-does-not-see-a-new-libztree-a--01a1f47872d7.md) by [ADR-0016](.okfw/decisions/adr-0016-a-hash-file-of-libztree-a-in-the-go-binding--01a1f47f0da8.md) in Phase 17. [ISSUE-009](.okfw/issues/issue-009-rare-zig-forms-that-the-patched-grammar-cannot-read--01a1ec8ab913.md) by [ADR-0015](.okfw/decisions/adr-0015-three-rare-zig-forms-in-the-patched-grammar--01a1f3e617cd.md) in Phase 16. [ISSUE-017](.okfw/issues/issue-017-an-overflow-of-repeat-depth-on-large-repetitions--01a1f2f04d37.md) by [ADR-0014](.okfw/decisions/adr-0014-no-repeat-depth-in-a-subtree--01a1f309a44d.md) in Phase 15. [ISSUE-016](.okfw/issues/issue-016-the-glr-stack-limit-of-64-heads--01a1f080f76c.md) by [ADR-0013](.okfw/decisions/adr-0013-a-bound-of-256-glr-stack-heads--01a1f2f0124a.md) in Phase 14. [ISSUE-008](.okfw/issues/issue-008-zig-0-17-keywords-in-the-zig-grammar--01a1ebfde99b.md) by [ADR-0006](.okfw/decisions/adr-0006-a-patched-zig-grammar-for-zig-0-17-and-empty-containers--01a1ec8a934e.md).

## Phase 7 — C ABI for Go
Issue: [ISSUE-007](.okfw/issues/issue-007-c-abi-and-static-library-for-go-callers--01a1e96b8f9a.md)
- [x] Write `libztree.a` and `include/ztree.h` with `zig build lib`
- [x] Export `ztree_extract_comments` with a bounded output buffer and no callbacks
- [x] Add the Go binding in `bindings/go/` with its tests, and the C ABI spec

## Phase 8 — C++ grammar
Issue: [ISSUE-010](.okfw/issues/issue-010-the-c-grammar--01a1ef92fe7b.md)
- [x] Vendor tree-sitter-cpp v0.23.4 into `third_party/grammars/cpp/` and compile `parser.c` and `scanner.c`
- [x] Add `cpp` to `grammars.Lang`, the comment kinds, the C ABI and the Go binding
- [x] Add the C++ corpus to `conformance` and C++ files to `differential`

## Phase 9 — Flat tree and node API
Issue: [ISSUE-011](.okfw/issues/issue-011-the-flat-tree-and-the-node-api--01a1ef92fe81.md)
- [x] Flatten the finished tree into node records (`src/flat.zig`) and compare its S-expression with `tree.writeSexp`
- [x] Export `ztree_parse` and the language metadata functions
- [x] Compare each flat node with the reference `TSNode` API in the differential step
- [x] Add `Parser`, `Tree`, `Node` and `TreeCursor` to the Go binding

## Phase 10 — Bounded regex
Issue: [ISSUE-012](.okfw/issues/issue-012-a-bounded-regex-engine-for-match-predicates--01a1ef92fe88.md)
- [x] Add an RE2-subset compiler and a Pike VM (`src/regex.zig`), and record the subset in an ADR
- [x] Compare the results with the Go `regexp` package on a table of patterns and inputs

## Phase 11 — Query compiler
Issue: [ISSUE-013](.okfw/issues/issue-013-the-query-compiler--01a1ef92fe8e.md)
- [x] Parse the query language into a compiled blob (`src/query.zig`)
- [x] Check node types, fields, captures and predicates, and report the position of each error
- [x] Export `ztree_query_compile`

## Phase 12 — Query execution
Issue: [ISSUE-014](.okfw/issues/issue-014-query-execution--01a1ef92fe94.md)
- [x] Match a compiled query against a flat tree (`src/query_exec.zig`) and export `ztree_query_exec`
- [x] Add `NewQuery` and `QueryCursor` to the Go binding
- [x] Compare the matches with the reference query cursor in `zig build query-diff`, and add the target to `check`

## Phase 13 — Handoff to semscope
Issue: [ISSUE-015](.okfw/issues/issue-015-handoff-to-semscope--01a1ef92fe9b.md)
- [x] Update the C ABI spec and add a Go benchmark
- [x] Write a guide in the wiki to migrate semscope to ztree
- [x] Run the tests and the parity step of a local semscope branch with ztree

## Phase 14 — The GLR stack bound
Issue: [ISSUE-016](.okfw/issues/issue-016-the-glr-stack-limit-of-64-heads--01a1f080f76c.md)
- [x] Measure the largest head count on large C, C++, Go, Python, Rust and Zig trees
- [x] Set `limits.max_stack_heads` to 256 and record the bound in ADR-0013
- [x] Add test inputs that need more than 64 heads

## Phase 15 — The overflow of repeat_depth
Issue: [ISSUE-017](.okfw/issues/issue-017-an-overflow-of-repeat-depth-on-large-repetitions--01a1f2f04d37.md)
- [x] Make each summary field of a subtree safe for repetitions of more than 65,535 items
- [x] Add tests with large tables for the affected grammars
- [x] Parse the two files of ISSUE-017 with the same tree as the reference

## Phase 16 — Three rare Zig forms
Issue: [ISSUE-009](.okfw/issues/issue-009-rare-zig-forms-that-the-patched-grammar-cannot-read--01a1ec8ab913.md)
- [x] Add the three forms to `zig-0.17.patch` and generate the parser again
- [x] Add test inputs for the three forms
- [x] Parse the Zig 0.17.1 standard library and zmake with 0 trees with errors

## Phase 17 — The Go build cache and libztree.a
Issue: [ISSUE-018](.okfw/issues/issue-018-the-go-build-cache-does-not-see-a-new-libztree-a--01a1f47872d7.md)
- [x] Write the SHA-256 of `libztree.a` into `bindings/go/libhash.go` in `zig build lib`
- [x] Add a binding test that compares the hash with the library
- [x] Prove that a new library makes Go link again

## Phase 18 — An executable stack with a Debug libztree.a
Issue: [ISSUE-019](.okfw/issues/issue-019-an-executable-stack-with-a-debug-libztree-a--01a1f4eaab02.md)
- [x] Build `libztree.a` with LLVM in each mode, so each object has a `.note.GNU-stack` section
- [x] Check each object of the library in `zig build lib` and `zig build test`
- [x] Add a binding test that the stack of a Go program is not executable

## Phase 19 — lexis checks the documentation
Issue: [ISSUE-020](.okfw/issues/issue-020-lexis-checks-the-documentation-of-ztree--01a1f524fb01.md)
- [x] Add `vocabulary.cue` with the technical terms of ztree, and reword the other findings of lexis
- [x] Add the `docs-lexis` task to `ZMakefile` and `Makefile`, and run it in `check` after `docs-style`
- [x] Record the gate in ADR-0018, and update `CLAUDE.md` and the wiki guides

Acceptance criteria:
- [x] The lexis scan of `CLAUDE.md`, `PLAN.md` and `.okfw` gives 0 errors, 0 warnings and 0 notes
- [x] `zmake -n check` and `make -n check` print the same commands
- [x] `zmake check` and `make check` pass

## Phase 20 — lexis is now lexiscope
Issue: [ISSUE-021](.okfw/issues/issue-021-lexis-is-now-lexiscope--01a1f548c7d3.md)
- [x] Rename the task `docs-lexis` to `docs-lexiscope` and the variable `LEXIS` to `LEXISCOPE` in `ZMakefile` and `Makefile`
- [x] Name the tool lexiscope in `CLAUDE.md`, `vocabulary.cue` and the current wiki concepts
- [x] Keep the old name in the records, and add a dated note to ADR-0018

Acceptance criteria:
- [x] The lexiscope scan of `CLAUDE.md`, `PLAN.md` and `.okfw` gives 0 errors, 0 warnings and 0 notes
- [x] With `LEXISCOPE` set to a command that does not exist, `zmake docs-lexiscope` prints a message and passes
- [x] `zmake -n check` and `make -n check` print the same commands
- [x] `zmake check` and `make check` pass
