---
x-okfw-id: "01a1e96b-8f06-7d05-ad97-ead9a95fe574"
title: "ADR-0002: Zig 0.17.1, the standard library and vendored C grammars"
type: "ADR"
tags:
  - "adr"
  - "toolchain"
  - "dependencies"
x-okfw-created: "2026-11-17T06:11:42-06:00"
x-okfw-timestamp: "2026-11-17T06:11:42-06:00"
description: "ztree uses Zig 0.17.1 and its standard library, and vendors pinned Tree-sitter C sources in third_party/."
---

# ADR-0002: Zig 0.17.1, the standard library and vendored C grammars

**Status:** Accepted
**Date:** 2026-11-17
**Source:** User request.

## Context
ztree replaces the Tree-sitter C runtime with Zig code. ztree still needs the grammars, and each grammar comes as generated C. The differential tests need the reference runtime as an oracle.

## Decision
- ztree uses Zig 0.17.1 and the Zig standard library. `build.zig.zon` sets `minimum_zig_version`.
- ztree has no package-manager dependencies.
- `third_party/` holds pinned copies of upstream C source. Each copy keeps its licence file and records its upstream tag and commit.
- `zig build` compiles the vendored grammar C files with the Zig C compiler.
- The reference runtime compiles into the test and conformance steps only. The library and the C ABI never link it.
- Write an ADR before you add a dependency or a vendored source tree.

## Consequences
- One toolchain builds the runtime, the grammars and the oracle.
- An update of a grammar is one commit that replaces its `third_party/` directory and its pin.

## Alternatives considered
- **Fetch the grammars with `build.zig.zon` dependencies.** Rejected for now: a vendored copy keeps the build offline and the diff reviewable.
