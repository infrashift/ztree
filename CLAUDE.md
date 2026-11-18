# CLAUDE.md — ztree

## Purpose (WHY)
ztree is a batch Tree-sitter runtime in Zig. It follows the NASA Power of 10 rules. It loads the generated grammars of Go, Zig, Python, C, C++ and Rust. It is the Tree-sitter service of two linters through a C ABI: lexis reads comment spans, and semscope reads trees and runs queries. [ADR-0004](.okfw/decisions/adr-0004-a-batch-tree-sitter-runtime-for-abi-14-and-15--01a1e96b8f27.md) and [ADR-0007](.okfw/decisions/adr-0007-ztree-is-the-tree-sitter-service-of-lexis-and-semscope--01a1ef926073.md) define the scope.

## Tech Stack (WHAT)
- **Language:** Zig 0.17.1, pinned in `build.zig.zon` as `minimum_zig_version`.
- **Dependencies:** the Zig standard library only. `third_party/` holds pinned C grammars and the reference runtime ([ADR-0002](.okfw/decisions/adr-0002-zig-0-17-1-the-standard-library-and-vendored-c-grammars--01a1e96b8f06.md)). Write an ADR before you add a dependency.
- **Wiki:** okfw (`.okfw/`), [ADR-0001](.okfw/decisions/adr-0001-adopt-an-okf-wiki-okfw-for-project-knowledge--01a1e96b8ef6.md). See the okfw block below.

## Layout
- `src/root.zig` is the root of the Zig module. It holds the hard limits.
- `src/capi.zig` is the root of `libztree.a`. `include/ztree.h` declares its C ABI ([spec](.okfw/specs/ztree-c-abi--01a1ec92dc4f.md)).
- `bindings/go/` holds the Go binding: a separate Go module that links `zig-out/lib/libztree.a`.
- `src/` holds the runtime modules. The [architecture overview](.okfw/architecture/ztree-architecture-overview--01a1e96b8ee5.md) lists them.
- `third_party/` holds vendored C source. Do not edit it.
- `scripts/` holds the lint scripts from zmake: `nasa-lint.py` (Power of 10) and `ste-check.py` (ASD-STE100). Do not change them.

## Verification & Workflow Commands (HOW)
`ZMakefile` (zmake, modern mode) and `Makefile` (GNU Make) have the same targets. Change both files together.

Run these targets with `zmake`:
- `zmake lint` runs `zig fmt --check` and `scripts/nasa-lint.py`.
- `zmake test` runs `zig build test`.
- `zmake conformance` checks each grammar corpus example against its expected tree.
- `zmake differential` parses the source files of this repository with ztree and the reference runtime. For other directories, run `zig build differential --release -Ddiff-dirs=<dir>`.
- `zmake build` runs `zig build`.
- `zmake lib` writes `zig-out/lib/libztree.a` and `zig-out/include/ztree.h` (ReleaseSafe).
- `zmake go` runs `zmake lib`, then checks the Go binding with gofmt, `go vet` and `go test -race`.
- `zmake wiki` runs `okfw validate --all` and `okfw validate --okf`.
- `zmake docs-style` runs `scripts/ste-check.py`.
- `zmake check` runs all of the gates above. It is the default goal.

## Mandatory Execution Rules
1. **One phase at a time.** Read `PLAN.md`. Implement only the first unchecked phase. Follow the [Development workflow](.okfw/development-workflow--01a1e96b8ed2.md).
2. **Repeat until green.** After each task, run `zmake check`. Fix each error and each warning. Do not commit while a gate fails.
3. **Test integrity.** Do not weaken or delete tests to make a gate pass.
4. **Power of 10.** Follow the rules as [ADR-0003](.okfw/decisions/adr-0003-adapt-the-nasa-power-of-10-rules-to-ztree--01a1e96b8f17.md) adapts them. Only `src/abi.zig` declares function pointers.
5. **Minimal abstractions.** Add no unrequested interfaces, vtables or factories.
6. **Wiki stays in sync.** Each `PLAN.md` phase has a mirror issue in `.okfw/issues/`. Record each decision as an ADR when you make it.
7. **Documentation follows ASD-STE100.** Use active voice, simple present tense and short sentences. Read the [Wiki conventions](.okfw/wiki-conventions--01a1e96b8eb9.md). Run `zmake docs-style`.
8. **Git.** Make one commit per phase. Do not push.

<!-- BEGIN okfw -->
## Project knowledge base (okfw)

ztree keeps a local-first OKF wiki in `.okfw/`: markdown concepts with
YAML frontmatter, linked to each other. The files are the whole database —
search and the link graph are computed from them on demand, so there is no
index to build and nothing to sync. Each directory's `index.md` is generated
and gives a cheap overview before you open anything (OKF section 8).

- **Search before you derive.** `okfw search "<query>"` / `okfw_search`. The
  wiki holds what the code does not say — why things are built the way they
  are, what was considered and rejected, dependency and security findings,
  operational context, open work. Check it before explaining a design,
  assessing risk, or running an analysis someone may already have recorded and
  adjudicated.
- **Browse top-down.** Each directory's `index.md` lists its concepts with
  their descriptions (`okfw_read {"ref":"<dir>/"}` over MCP). Open only what fits.
- **Search before you write**, too, so a new concept links to what already
  exists instead of duplicating it.
- **Link actively** — `[Title](/dir/file.md)` from the wiki root, or
  `./file.md`. Links are what makes the wiki more than a folder.
- **One idea per concept**, with a one-sentence `description`.
- **Use `okfw move` / `okfw delete`, never `mv` / `rm`.** `move` repairs every
  link to the concept and its own relative links, and both keep the `index.md`
  listings current; the shell commands break the links and leave the listings
  stale.
- **`status` is the OKF lifecycle field** (`draft`/`stable`/`deprecated`), not
  task state. Mark superseded knowledge rather than deleting it.
- **Custom metadata goes under `x:`** — the schema is closed and rejects any
  other unrecognized key.
- Don't edit `index.md` or `log.md`; okfw generates them.

Results are capped and say so: `truncated`, or `… N more`, means you did not
see everything — raise the limit or page with `--offset`/`"offset"`.

`okfw mcp` serves all of this as MCP stdio tools named `okfw_*`.
<!-- END okfw -->
