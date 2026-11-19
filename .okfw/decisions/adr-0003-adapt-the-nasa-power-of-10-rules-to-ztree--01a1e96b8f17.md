---
id: "01a1e96b-8f17-7389-869c-4709bcce5f4b"
title: "ADR-0003: Adapt the NASA Power of 10 rules to ztree"
type: "ADR"
tags:
  - "adr"
  - "safety"
  - "lint"
created: "2026-11-17T06:11:42-06:00"
timestamp: "2026-11-17T06:11:42-06:00"
description: "ztree follows the Power of 10 rules in its Zig runtime, with deviations for the arena, the C ABI callbacks and generated C."
---

# ADR-0003: Adapt the NASA Power of 10 rules to ztree

**Status:** Accepted
**Date:** 2026-11-17
**Source:** User request. Gerard J. Holzmann, "The Power of 10: Rules for Developing Safety-Critical Code" (2006). zmake ADR-0003.

## Context
The user requires the Power of 10 rules for the runtime. The rules target C. A GLR parser reads inputs of unknown size and creates stack versions while it runs. The `TSLanguage` ABI calls through function pointers. Some rules need an adaptation.

## Decision
| Rule | ztree adaptation | Check |
|---|---|---|
| R1 Simple control flow, no recursion | Explicit stacks with a fixed depth limit for subtree release, balance, cursor walks and error recovery. | `nasa-lint.py` call graph |
| R2 Fixed loop bounds | Loops iterate over slices or count toward a limit. A loop that reaches its limit returns an error. | `nasa-lint.py` bans `while (true)` |
| R3 No allocation after initialization | Deviation: each parse allocates from one arena and frees it after the parse. Hard limits cap the arena. | Review |
| R4 Short functions | A function has 60 lines or fewer. | `nasa-lint.py` |
| R5 Assertion density | An average of two or more `assert` calls per function. Assertions have no side effects. | `nasa-lint.py` |
| R6 Smallest scope | Declare data in the smallest block. The compiler rejects unused locals. | Compiler, review |
| R7 Check return values | Do not use `catch {}`, `else |_| {}`, `catch unreachable` or `_ = f()` without a reason. | `nasa-lint.py` |
| R8 Limited preprocessor | Use `comptime` for constants and types only. Do not use `@cImport`. Zig `extern struct` types mirror the C ABI. | Review |
| R9 Restricted pointers | Deviation: the `TSLexer` callbacks and the external scanner calls need function pointers. Only `src/abi.zig` declares them. | `nasa-lint.py` with `allow(R9)` |
| R10 Zero warnings | `zmake lint` runs `zig fmt --check` and `nasa-lint.py` on every change. | `zmake lint` |

**Generated and vendored C:** the lex function uses `goto` and the grammar headers use macros. The external scanners allocate. This C code is outside the runtime, and `nasa-lint.py` does not scan it. ztree does not edit it.

**Hard limits** (`src/root.zig`, `limits`): source size 16 MiB, 6 stack versions after each condense and 256 stack heads during a reduce ([ADR-0013](/decisions/adr-0013-a-bound-of-256-glr-stack-heads--01a1f2f0124a.md)). Each phase adds its limits to the same struct.

**Release builds** use `ReleaseSafe`, so `assert` stays active in the shipped library.

**Suppression:** `// nasa-lint: allow(Rn) <reason>` on the line or the line above. Each suppression needs a reason.

## Consequences
- The runtime is more verbose than the reference runtime: explicit stacks and many assertions.
- An input that exceeds a limit fails with an error. The reference runtime accepts it.
- Test blocks and test helpers are exempt from R4 and R5.
- Assertions check programmer errors only. ztree reports bad input with an error.

## Alternatives considered
- **Recursion with a depth counter.** Rejected: R1 forbids recursion.
- **A port of the generated C to Zig.** Rejected: the grammar generator writes this C, and ztree does not replace the generator ([ADR-0004](/decisions/adr-0004-a-batch-tree-sitter-runtime-for-abi-14-and-15--01a1e96b8f27.md)).
