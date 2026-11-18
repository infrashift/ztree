---
id: "01a1ef92-fe9b-73fd-b2d9-fc21a23a1cb1"
title: "ISSUE-015: Handoff to semscope"
type: "Issue"
kind: "issue"
tags:
  - "issue"
  - "open"
  - "phase-13"
  - "semscope"
created: "2026-11-18T10:52:30-06:00"
timestamp: "2026-11-18T10:52:30-06:00"
description: "Handoff to semscope."
---

# ISSUE-015: Handoff to semscope

**Status:** open · **Phase:** 13

## Description
Document the new C ABI and the Go API. Give semscope a migration guide ([ADR-0007](/decisions/adr-0007-ztree-is-the-tree-sitter-service-of-lexis-and-semscope--01a1ef926073.md)).

## Acceptance Criteria
- [ ] The C ABI spec defines each new function.
- [ ] A Go benchmark measures a parse, a walk and a query.
- [ ] A wiki concept maps the go-tree-sitter API to the ztree API and lists the node shape changes of the grammar pins.
- [ ] A local semscope branch with ztree passes its tests and its parity step.
- [ ] `zmake check` reports zero errors and zero warnings.

## Related
- [ADR-0007](/decisions/adr-0007-ztree-is-the-tree-sitter-service-of-lexis-and-semscope--01a1ef926073.md), [ztree architecture overview](/architecture/ztree-architecture-overview--01a1e96b8ee5.md)
