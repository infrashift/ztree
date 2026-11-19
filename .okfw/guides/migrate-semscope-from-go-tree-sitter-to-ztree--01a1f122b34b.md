---
id: "01a1f122-b34b-7a0e-82cc-522d5fb0d05c"
title: "Migrate semscope from go-tree-sitter to ztree"
type: "Guide"
tags:
  - "guide"
  - "semscope"
  - "go"
created: "2026-11-18T18:09:05-06:00"
timestamp: "2026-11-18T18:09:05-06:00"
description: "The steps, the API map, the error changes, the grammar pin changes and the measured parity and speed for moving semscope to the ztree Go binding."
---

# Migrate semscope from go-tree-sitter to ztree

# Migrate semscope from go-tree-sitter to ztree

This guide moves semscope from go-tree-sitter v0.25.0 to the ztree Go binding ([ADR-0007](/decisions/adr-0007-ztree-is-the-tree-sitter-service-of-lexis-and-semscope--01a1ef926073.md)). The [C ABI spec](/specs/ztree-c-abi--01a1ec92dc4f.md) gives the full API. A local semscope branch `ztree-runtime` holds the change and passes the checks below ([ISSUE-015](/issues/issue-015-handoff-to-semscope--01a1ef92fe9b.md)).

## Steps
1. Run `zmake lib` in ztree. It writes `zig-out/lib/libztree.a` and `zig-out/include/ztree.h`.
2. Add `github.com/infrashift/ztree/bindings/go` to `go.mod` with a `replace` to the ztree checkout.
3. Change the import `github.com/tree-sitter/go-tree-sitter` to the ztree binding. Keep the alias `ts`.
4. Remove the six grammar modules. Use `ts.NewLanguage(ts.LangGo)` and the other `Lang` values.
5. Change `Parse(src, nil)` to `Parse(src)`, and handle its error.
6. Remove each `Close` call on a parser, tree, cursor, query or query cursor.
7. After each `Matches` call, read `QueryMatches.Err`.
8. Run `go mod tidy`, the tests and the parity step.

## API map
| go-tree-sitter | ztree | Note |
|---|---|---|
| `ts.NewLanguage(tsgo.Language())` | `ts.NewLanguage(ts.LangGo)` | One `Language` value for each grammar. |
| `ts.NewParser()`, `SetLanguage` | The same | One goroutine at a time uses a `Parser`. |
| `Parser.Parse(src, old) *Tree` | `Parser.Parse(src) (*Tree, error)` | No incremental parse. A hard limit gives an error. |
| `Tree.RootNode`, `Tree.Walk` | The same | Two goroutines can read one `Tree`. |
| `Node` methods | The same names | `Kind`, `Child`, `NamedChild`, `ChildByFieldName`, `Parent`, the siblings, the positions, `Utf8Text`, `HasError`, `ToSexp`, `Walk`. |
| `TreeCursor` | The same names | `GotoFirstChild`, `GotoNextSibling`, `GotoParent`, `Node`, `FieldName`. |
| `ts.NewQuery(lang, src)` | The same | `*QueryError` adds `Offset` and two kinds. |
| `QueryCursor.Matches(q, node, src)` | The same | Add a check of `Err()`. |
| `QueryMatch.Captures`, `QueryCapture.Index` | The same | `Node` is a value, as in go-tree-sitter. |
| `Close` methods | None | Go owns all memory. |

ztree does not have `Tree.Edit`, included ranges or `QueryCursor.Captures`. A query cursor has no byte or point ranges, no match limit and no timeout. ztree has no logger. semscope uses none of these parts.

## Errors
- `Parse` gives `ErrLimitReached` for a source past a hard limit of the parser. go-tree-sitter gives a tree in this case. semscope now stops the scan on this error. semscope can change this to report the file and go on.
- `NewQuery` gives kind `QueryErrorPredicate` for an unknown predicate or a bad regex. go-tree-sitter keeps an unknown predicate and ignores it.
- `NewQuery` gives kind `QueryErrorUnsupported` for a supertype, a directive (`#set!`, `#is?`, `#is-not?`) or a regex outside the subset of [ADR-0010](/decisions/adr-0010-a-pike-vm-for-an-re2-subset--01a1f0902c3e.md).
- `QueryMatches.Err` gives `ErrLanguageMismatch` for a tree of another grammar, and `ErrLimitReached` past a limit of the query cursor.

## Grammar pins and node shapes
ztree pins the grammars in `third_party/grammars/*/PIN`. Three pins differ from the modules of semscope.

| Grammar | semscope | ztree | Node type changes |
|---|---|---|---|
| C | v0.23.4 | v0.24.2 | None in `node-types.json`. The parse tables change, so the trees of files with syntax errors can change. |
| Rust | v0.23.2 | v0.24.2 | See the list below. |
| Zig | v1.1.2, patched | v1.1.2, patched | None. ztree adds empty containers to the patch of semscope ([ADR-0006](/decisions/adr-0006-a-patched-zig-grammar-for-zig-0-17-and-empty-containers--01a1ec8a934e.md)). |
| Go, Python, C++ | v0.25.0, v0.25.0, v0.23.4 | The same | None. |

The Rust changes:
- `type_parameters` holds `type_parameter` and `lifetime_parameter` nodes. The nodes `constrained_type_parameter` and `optional_type_parameter` are gone.
- `range_pattern` has the fields `left` and `right`.
- New nodes: `generic_pattern`, `use_bounds`, and the anonymous `expr_2021` and `pat_param`.
- `const_parameter` has the field `value`. `abstract_type` and `dynamic_type` accept more trait types. `foreign_mod_item` has no `visibility_modifier`.

No semscope rule or Rust walker reads these node types.

## The runtime version
ztree follows the reference runtime v0.27.2. go-tree-sitter v0.25.0 holds an older runtime. The two runtimes give the same trees for valid sources. Error recovery can differ for a source with syntax errors. In the Go files of the benchmark, one file has a syntax error: `encoding/json/v2/arshal_test.go`. go-tree-sitter gives 131,274 nodes for it, and ztree and the reference v0.27.2 give 129,773.

## Results of the semscope branch
- `go test ./...` passes.
- The parity step passes on 10 corpora: the Zig fixture, zmake, the Zig 0.17.1 standard library, the Go fixture and six Go modules. The default corpus list needs the go-tree-sitter module in `go.mod`. With ztree, give the module list in `SEMSCOPE_PARITY_GO_CORPUS`.
- `semscope scan --format json` gives the same output with both runtimes on nine source trees. These trees hold 10,109 findings: semscope, zmake, two GOROOT trees, two Python trees, two Rust crates and the Zig standard library.
- libstdc++ `bits/` headers parse as C, so most have syntax errors. `stl_algobase.h` needs 81 stack heads. It failed with the old bound of 64 ([ISSUE-016](/issues/issue-016-the-glr-stack-limit-of-64-heads--01a1f080f76c.md)). Since Phase 14, the bound is 256 and ztree gives the same tree as the reference ([ADR-0013](/decisions/adr-0013-a-bound-of-256-glr-stack-heads--01a1f2f0124a.md)). The other 132 headers give 849 findings with ztree and 813 with go-tree-sitter. With tree-sitter-c v0.24.2 in go-tree-sitter, the count is 846. The other differences come from the runtime version.

## Performance
`go test -bench . ./bindings/go` measures one goroutine on 512 Go files (7.1 MB) of GOROOT. The go-tree-sitter numbers come from the same files and the same query. The machine is an Intel i7-9700K.

| Step | go-tree-sitter v0.25.0 | ztree |
|---|---|---|
| Parse | 4.8 to 5.2 MB/s | 3.8 to 4.2 MB/s |
| Walk of each node with a cursor | 8.5 MB/s | 400 to 480 MB/s |
| Query with three text predicates | 17 MB/s | 57 to 60 MB/s |

A ztree walk and a query read Go memory, with no cgo call for each node. A parse is one cgo call. In a semscope scan the parse is the largest cost. In the scans above, ztree took the same time or less on each tree.
