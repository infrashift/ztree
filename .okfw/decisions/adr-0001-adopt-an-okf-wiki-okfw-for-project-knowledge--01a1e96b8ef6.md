---
x-okfw-id: "01a1e96b-8ef6-73ff-85de-686c6da565e5"
title: "ADR-0001: Adopt an OKF wiki (okfw) for project knowledge"
type: "ADR"
tags:
  - "adr"
  - "process"
x-okfw-created: "2026-11-17T06:11:42-06:00"
x-okfw-timestamp: "2026-11-17T06:11:42-06:00"
description: "ztree records decisions, scope and open work in an OKF wiki that okfw manages and validates."
---

# ADR-0001: Adopt an OKF wiki (okfw) for project knowledge

**Status:** Accepted
**Date:** 2026-11-17
**Source:** User request. The zmake project uses the same setup.

## Context
ztree makes design decisions that the code does not record: scope limits, deviations from the Power of 10 rules and pinned grammar versions. An agent and a person both need a searchable record of these decisions.

## Decision
- ztree keeps an OKF wiki in `.okfw/` and manages it with `okfw`.
- `.mcp.json` registers `okfw mcp` as the MCP server for Claude Code.
- `okfw install --platform claude` writes the skill and the okfw block in `CLAUDE.md`.
- The wiki follows the Wiki conventions guide. The gate `zmake wiki` validates the wiki.

## Consequences
- Each phase of `PLAN.md` has a mirror issue.
- Each decision gets an ADR when the work makes it.
- The `okfw` CLI and the MCP server give the same operations. Work continues when the MCP server is not connected.

## Alternatives considered
- **Plain Markdown in `docs/`.** Rejected: no frontmatter schema, no link repair and no search.
