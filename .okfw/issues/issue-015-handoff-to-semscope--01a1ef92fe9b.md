---
x-okfw-id: "01a1ef92-fe9b-73fd-b2d9-fc21a23a1cb1"
title: "ISSUE-015: Handoff to semscope"
type: "Issue"
x-okfw-kind: "issue"
tags:
  - "issue"
  - "closed"
  - "phase-13"
  - "semscope"
x-okfw-created: "2026-11-18T10:52:30-06:00"
x-okfw-timestamp: "2026-11-18T10:52:30-06:00"
description: "Handoff to semscope."
---

# ISSUE-015: Handoff to semscope

**Status:** closed · **Phase:** 13

## Description
Document the new C ABI and the Go API. Give semscope a guide to migrate to ztree ([ADR-0007](/decisions/adr-0007-ztree-is-the-tree-sitter-service-of-lexis-and-semscope--01a1ef926073.md)).

## Acceptance Criteria
- [x] The C ABI spec defines each new function.
- [x] A Go benchmark measures a parse, a walk and a query.
- [x] A wiki concept maps the go-tree-sitter API to the ztree API and lists the node shape changes of the grammar pins.
- [x] A local semscope branch with ztree passes its tests and its parity step.
- [x] `zmake check` reports zero errors and zero warnings.

## Resolution
- The [C ABI spec](/specs/ztree-c-abi--01a1ec92dc4f.md) defines each function of version 6 and the Go query API.
- `bindings/go/bench_test.go` measures a parse, a walk and a query on 512 Go files of GOROOT.
- The [guide to migrate semscope](/guides/migrate-semscope-from-go-tree-sitter-to-ztree--01a1f122b34b.md) maps the go-tree-sitter API to ztree. It lists the error changes, the grammar pin changes and the measured parity and speed.
- The local semscope branch `ztree-runtime` (commit `6e42166`, not pushed) uses ztree. Its tests, its parity step on 10 corpora and its `zmake check` pass. Its scan output equals the output of go-tree-sitter on nine source trees with 10,109 findings.
- The benchmark found that `Parser.Parse` sized each node buffer from the largest earlier parse. A small tree then kept a large buffer. The buffer now scales with the source, and a test checks it.
- [ISSUE-016](/issues/issue-016-the-glr-stack-limit-of-64-heads--01a1f080f76c.md) stays open. One libstdc++ header stops a semscope scan with ztree.

## Related
- [ADR-0007](/decisions/adr-0007-ztree-is-the-tree-sitter-service-of-lexis-and-semscope--01a1ef926073.md), [ztree architecture overview](/architecture/ztree-architecture-overview--01a1e96b8ee5.md)
