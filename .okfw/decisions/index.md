# decisions

<!-- okfw:generated — maintained by okfw; edits here are overwritten -->

## Concepts

* [ADR-0001: Adopt an OKF wiki (okfw) for project knowledge](adr-0001-adopt-an-okf-wiki-okfw-for-project-knowledge--01a1e96b8ef6.md) - ztree records decisions, scope and open work in an OKF wiki that okfw manages and validates.
* [ADR-0002: Zig 0.17.1, the standard library and vendored C grammars](adr-0002-zig-0-17-1-the-standard-library-and-vendored-c-grammars--01a1e96b8f06.md) - ztree uses Zig 0.17.1 and its standard library, and vendors pinned Tree-sitter C sources in third_party/.
* [ADR-0003: Adapt the NASA Power of 10 rules to ztree](adr-0003-adapt-the-nasa-power-of-10-rules-to-ztree--01a1e96b8f17.md) - ztree follows the Power of 10 rules in its Zig runtime, with deviations for the arena, the C ABI callbacks and generated C.
* [ADR-0004: A batch Tree-sitter runtime for ABI 14 and 15](adr-0004-a-batch-tree-sitter-runtime-for-abi-14-and-15--01a1e96b8f27.md) - ztree parses whole files with generated grammars of ABI 14 and 15 and extracts comments, with no incremental edits or queries.
* [ADR-0005: One arena per parse, no reference counts and no balance step](adr-0005-one-arena-per-parse-no-reference-counts-and-no-balance-step--01a1ebbb7488.md) - ztree allocates each parse from one arena, copies on makeMut, and leaves out balancing and incremental reuse, with the same visible tree as the reference.

