---
id: "01a1f0a8-133a-742c-8985-541a155ee7e9"
title: "ADR-0011: A structural port of the reference query compiler"
type: "ADR"
tags:
  - "adr"
  - "query"
  - "semscope"
created: "2026-11-18T15:55:09-06:00"
timestamp: "2026-11-18T15:55:09-06:00"
description: "src/query.zig and src/query_analysis.zig port ts_query_new and its parse-table analysis step for step, and the predicates follow NewQuery of go-tree-sitter."
---

# ADR-0011: A structural port of the reference query compiler

**Status:** Accepted
**Date:** 2026-11-18
**Source:** [ISSUE-013](/issues/issue-013-the-query-compiler--01a1ef92fe8e.md), [ADR-0008](/decisions/adr-0008-a-flat-tree-and-a-compiled-query-blob-in-caller-memory--01a1ef929e5c.md)

## Context
semscope users write Tree-sitter queries, so the query language is part of its contract ([ADR-0007](/decisions/adr-0007-ztree-is-the-tree-sitter-service-of-lexis-and-semscope--01a1ef926073.md)). The matches of the reference query cursor depend on details of the compiled query. These are the order of the steps, the alternative links, the pattern map and the flags of each step. The analysis of the reference walks the parse table of the grammar. It finds impossible patterns (a structure error) and the steps that can fail. The cursor splits a state at a fallible step, so the analysis changes the number of matches.

## Decision
1. **A structural port.** `src/query.zig` ports `ts_query_new` and `ts_query__parse_pattern` of the vendored `query.c`. An explicit frame stack replaces the recursion. `src/query_analysis.zig` ports `ts_query__analyze_patterns` and `ts_query__perform_analysis`. It keeps the order of each sorted set and the search rules of `array.h`. It keeps the limits: 8 stack entries, 256 iterations and 256 predecessors.
2. **Predicates as in go-tree-sitter.** `src/query_predicates.zig` checks the predicates as `NewQuery` of go-tree-sitter v0.25 does. It accepts the forms of `#eq?`, `#match?` and `#any-of?`. `#match?` compiles its regex with the engine of [ADR-0010](/decisions/adr-0010-a-pike-vm-for-an-re2-subset--01a1f0902c3e.md).
3. **Errors.** The kinds 1 to 6 are those of `TSQueryError`, with the same byte offsets. Kind 7 (predicate) is a predicate that go-tree-sitter rejects, an unknown predicate or an invalid regex. Kind 8 (unsupported) is a supertype pattern, a directive (`#set!`, `#is?`, `#is-not?`) or a regex outside the subset. go-tree-sitter keeps unknown predicates and directives, but ztree does not evaluate them, so it rejects them. The C ABI adds the row and the column.
4. **A blob.** `src/query_blob.zig` writes the compiled query into one blob with no pointers. The blob holds the steps, the pattern map, the patterns and the predicates. It also holds the symbol tables, the capture quantifiers and the regex programs. A header lists each section. A CRC-32 lets `ztree_query_exec` reject a damaged blob before it trusts an index.
5. **Undefined behavior of the reference.** The reference fails an assertion on a capture or a quantifier after a pattern with no step. It passes a null pointer to `strncmp` for a first string literal that is empty. ztree gives a syntax error or a normal result for this input. The tests do not run the reference on it.

## Consequences
- The test step compares ztree with `ts_query_new` on the upstream `queries/*.scm` files of five grammars, 59 hand-written queries and about 3,100 mutations of them. The dumps of steps, maps, flags, predicates and tables are equal, or the error kind and offset are equal.
- A query compile walks the parse table, as in the reference. The C++ grammar needs a predecessor map of about 5 MB for this walk.
- The tests copy the private structs of `query.c` (`tests/query_shim.c`). A new pin of the reference runtime needs a new copy.
- Identifiers and white space in a query are ASCII. The reference uses `iswalnum` and `iswspace` of the C locale, which give the same result for ASCII.

## Alternatives considered
- **A new query engine with its own design.** Rejected: the match order and the match count of the reference depend on the step layout and the analysis.
- **No analysis.** Rejected: ztree then gives no structure errors, and the cursor splits states at other steps.
- **Accept unknown predicates as go-tree-sitter does.** Rejected: a rule with a predicate that ztree ignores then gives false findings.
