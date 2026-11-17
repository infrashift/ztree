# PLAN.md — ztree

ztree is a batch Tree-sitter runtime in Zig 0.17.1 under the NASA Power of 10 rules. lexis uses it to extract the comments of Go, Zig, Python, C and Rust files.

Work on one phase at a time (`CLAUDE.md` rule 1). Each phase from 1 to 7 has a mirror issue in the OKF wiki (`.okfw/issues/`). When a phase is done, tick this checklist and the acceptance criteria of the issue.

Loop: implement one task, run `zmake check`, and repeat until green. Then update the wiki and commit once per phase.

- Architecture: [ztree architecture overview](.okfw/architecture/ztree-architecture-overview--01a1e96b8ee5.md)
- Decisions: [ADR-0001 wiki](.okfw/decisions/adr-0001-adopt-an-okf-wiki-okfw-for-project-knowledge--01a1e96b8ef6.md) · [ADR-0002 toolchain](.okfw/decisions/adr-0002-zig-0-17-1-the-standard-library-and-vendored-c-grammars--01a1e96b8f06.md) · [ADR-0003 Power of 10](.okfw/decisions/adr-0003-adapt-the-nasa-power-of-10-rules-to-ztree--01a1e96b8f17.md) · [ADR-0004 scope](.okfw/decisions/adr-0004-a-batch-tree-sitter-runtime-for-abi-14-and-15--01a1e96b8f27.md) · [ADR-0005 arena](.okfw/decisions/adr-0005-one-arena-per-parse-no-reference-counts-and-no-balance-step--01a1ebbb7488.md)
- Rules: ADR-0003 for the code. ASD-STE100 for all documentation.

## Phase 0 — Bootstrap
- [x] Create the git repo, `.gitignore`, `build.zig` and `build.zig.zon` with Zig 0.17.1
- [x] Copy `scripts/nasa-lint.py` and `scripts/ste-check.py` from zmake without changes
- [x] Create the OKF wiki (`okfw init`, `okfw install --platform claude`) and `.mcp.json`
- [x] Write `ZMakefile` and `Makefile` with the same targets
- [x] Write `CLAUDE.md` and `PLAN.md`
- [x] Seed the wiki: guides, architecture, ADR-0001 to ADR-0004, ISSUE-001 to ISSUE-007

## Phase 1 — Vendor and ABI
Tracking: [ISSUE-001](.okfw/issues/issue-001-vendor-the-reference-runtime-and-the-grammars-and-mirror-the-c-abi--01a1e96b8f38.md)
- [x] Vendor the reference runtime and the five grammars at the pinned tags into `third_party/`
- [x] Compile each grammar in `build.zig` with the Zig C compiler
- [x] Mirror `TSLanguage` (ABI 14 and 15), `TSLexer`, `TSParseAction` and `TSLexMode` in `src/abi.zig`
- [x] Test each language: ABI version, symbol count and state count

## Phase 2 — Lexer bridge
Tracking: [ISSUE-002](.okfw/issues/issue-002-lexer-bridge-for-the-lex-function-and-the-external-scanners--01a1e96b8f48.md)
- [x] Implement `TSLexer` in `src/lexer.zig`: UTF-8 decode, byte, row and column positions
- [x] Compare the lex results of each grammar with the reference lexer at sampled positions and in each lex state

## Phase 3 — Parser core
Tracking: [ISSUE-003](.okfw/issues/issue-003-parser-core-with-the-subtree-arena-and-the-glr-stack--01a1e96b8f58.md)
- [x] Add the subtree arena (`src/subtree.zig`) and the GLR stack (`src/stack.zig`)
- [x] Add the LR loop and the external scanner bridge (`src/parser.zig`)
- [x] Parse valid sample files of each grammar with no ERROR node

## Phase 4 — Error recovery
Phase 3 delivers this phase: the reference runtime runs its recovery code for valid input too.
Tracking: [ISSUE-004](.okfw/issues/issue-004-error-recovery-with-error-and-missing-nodes--01a1e96b8f69.md)
- [x] Add ERROR and MISSING nodes and token skips (`src/recover.zig`)
- [x] Match the trees of the reference runtime for invalid sample files

## Phase 5 — Tree API and comments
Tracking: [ISSUE-005](.okfw/issues/issue-005-tree-api-cursor-and-comment-extraction--01a1e96b8f79.md)
- [ ] Add nodes, the iterative cursor and S-expression output (`src/tree.zig`)
- [ ] Add comment node types per language and `extractComments` (`src/comments.zig`)

## Phase 6 — Conformance
Tracking: [ISSUE-006](.okfw/issues/issue-006-conformance-with-grammar-corpus-tests-and-the-reference-runtime--01a1e96b8f8a.md)
- [ ] Run the corpus tests of each grammar in `zig build conformance`
- [ ] Compare trees with the reference runtime for real source files
- [ ] Add the `conformance` target to `ZMakefile`, `Makefile` and `check`

## Phase 7 — C ABI for Go
Tracking: [ISSUE-007](.okfw/issues/issue-007-c-abi-and-static-library-for-go-callers--01a1e96b8f9a.md)
- [ ] Write `libztree.a` and `include/ztree.h` with `zig build lib`
- [ ] Export `ztree_extract_comments` with a bounded output buffer and no callbacks
- [ ] Add a cgo smoke test in `examples/go/` and the C ABI spec
