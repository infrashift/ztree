# issues

<!-- okfw:generated — maintained by okfw; edits here are overwritten -->

## Concepts

* [ISSUE-001: Vendor the reference runtime and the grammars and mirror the C ABI](issue-001-vendor-the-reference-runtime-and-the-grammars-and-mirror-the-c-abi--01a1e96b8f38.md) - Vendor the reference runtime and the grammars and mirror the C ABI.
* [ISSUE-002: Lexer bridge for the lex function and the external scanners](issue-002-lexer-bridge-for-the-lex-function-and-the-external-scanners--01a1e96b8f48.md) - Lexer bridge for the lex function and the external scanners.
* [ISSUE-003: Parser core with the subtree arena and the GLR stack](issue-003-parser-core-with-the-subtree-arena-and-the-glr-stack--01a1e96b8f58.md) - Parser core with the subtree arena and the GLR stack.
* [ISSUE-004: Error recovery with ERROR and MISSING nodes](issue-004-error-recovery-with-error-and-missing-nodes--01a1e96b8f69.md) - Error recovery with ERROR and MISSING nodes.
* [ISSUE-005: Tree API, cursor and comment extraction](issue-005-tree-api-cursor-and-comment-extraction--01a1e96b8f79.md) - Tree API, cursor and comment extraction.
* [ISSUE-006: Conformance with grammar corpus tests and the reference runtime](issue-006-conformance-with-grammar-corpus-tests-and-the-reference-runtime--01a1e96b8f8a.md) - Conformance with grammar corpus tests and the reference runtime.
* [ISSUE-007: C ABI and static library for Go callers](issue-007-c-abi-and-static-library-for-go-callers--01a1e96b8f9a.md) - C ABI and static library for Go callers.
* [ISSUE-008: Zig 0.17 keywords in the Zig grammar](issue-008-zig-0-17-keywords-in-the-zig-grammar--01a1ebfde99b.md) - tree-sitter-zig v1.1.2 reserves async, await and usingnamespace, so Zig 0.17 code that uses them as identifiers gives syntax errors.
* [ISSUE-009: Rare Zig forms that the patched grammar cannot read](issue-009-rare-zig-forms-that-the-patched-grammar-cannot-read--01a1ec8ab913.md) - Three rare Zig forms give syntax errors in 5 of 579 files of the Zig 0.17.1 standard library and zmake.
* [ISSUE-010: The C++ grammar](issue-010-the-c-grammar--01a1ef92fe7b.md) - The C++ grammar.
* [ISSUE-011: The flat tree and the node API](issue-011-the-flat-tree-and-the-node-api--01a1ef92fe81.md) - The flat tree and the node API.
* [ISSUE-012: A bounded regex engine for match predicates](issue-012-a-bounded-regex-engine-for-match-predicates--01a1ef92fe88.md) - A bounded regex engine for match predicates.
* [ISSUE-013: The query compiler](issue-013-the-query-compiler--01a1ef92fe8e.md) - The query compiler.
* [ISSUE-014: Query execution](issue-014-query-execution--01a1ef92fe94.md) - Query execution.
* [ISSUE-015: Handoff to semscope](issue-015-handoff-to-semscope--01a1ef92fe9b.md) - Handoff to semscope.
* [ISSUE-016: The GLR stack limit of 64 heads](issue-016-the-glr-stack-limit-of-64-heads--01a1f080f76c.md) - The C grammar needs more than 64 stack heads for one libstdc++ header, so ztree returns TooManyVersions where the reference runtime gives a tree.
* [ISSUE-017: An overflow of repeat_depth on large repetitions](issue-017-an-overflow-of-repeat-depth-on-large-repetitions--01a1f2f04d37.md) - summarizeEnds adds 1 to the u16 repeat_depth for each item of a repetition, so a table of more than 65,535 items panics in a safe build.
* [ISSUE-018: The Go build cache does not see a new libztree.a](issue-018-the-go-build-cache-does-not-see-a-new-libztree-a--01a1f47872d7.md) - cgo links libztree.a through -l, so the Go build cache can link an old library after a new zig build lib.

