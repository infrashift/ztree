---
id: "01a1f090-2c3e-7f21-b2ae-405a93d5a320"
title: "ADR-0010: A Pike VM for an RE2 subset"
type: "ADR"
tags:
  - "adr"
  - "regex"
  - "semscope"
created: "2026-11-18T15:29:02-06:00"
timestamp: "2026-11-18T15:29:02-06:00"
description: "src/regex.zig reads an ASCII subset of RE2 and matches with a Pike VM in linear time, with the result of regexp.Match of Go."
---

# ADR-0010: A Pike VM for an RE2 subset

**Status:** Accepted
**Date:** 2026-11-18
**Source:** [ISSUE-012](/issues/issue-012-a-bounded-regex-engine-for-match-predicates--01a1ef92fe88.md), [ADR-0007](/decisions/adr-0007-ztree-is-the-tree-sitter-service-of-lexis-and-semscope--01a1ef926073.md)

## Context
The query predicates `#match?` and `#not-match?` test the text of a node against a regex. go-tree-sitter compiles the regex with the Go `regexp` package (RE2 syntax) and calls `regexp.Match`. That is a search: the regex can match at each position of the text. semscope users write the regexes in CUE rule sets. [ADR-0007](/decisions/adr-0007-ztree-is-the-tree-sitter-service-of-lexis-and-semscope--01a1ef926073.md) puts the regex engine in Zig, under the Power of 10 rules.

## Decision
`src/regex.zig` compiles a pattern into a program with no pointers and runs it with a Pike VM. The VM runs in time O(text × program) with no recursion and no backtracking. A match result equals the result of `regexp.Match` of Go.

**Syntax that ztree reads:**
- Literal characters, and the escapes `\a \f \t \n \r \v`, `\xHH`, `\x{H…}`, octal escapes and an escaped ASCII punctuation character.
- `.` (no newline), with the flag `s` (any character).
- Classes: `[…]`, `[^…]`, ranges, the Perl classes `\d \D \s \S \w \W` and the POSIX classes `[:name:]` and `[:^name:]`. The classes are ASCII, as in RE2.
- `^ $`, with the flag `m` for lines. `\A \z \b \B`. `\b` uses ASCII word characters.
- Groups `(…)` and `(?:…)`, and alternation `|`.
- Repetition: `* + ?`, `{n}`, `{n,}` and `{n,m}` with counts to 1000, and the lazy forms. A lazy form gives the same match result.
- Flags: `(?flags)` and `(?flags:…)` with `i`, `m`, `s` and `U`, and `-` to clear a flag.

**Syntax that gives `ZTREE_ERROR_REGEX_UNSUPPORTED`:** Unicode classes `\p` and `\P`, `\Q…\E`, `\C`, and named groups `(?P<n>…)` and `(?<n>…)`. The flag `i` with a non-ASCII character also gives this error: ztree has no Unicode fold table. For ASCII, the flag `i` adds the two Unicode simple folds K (U+212A) and ſ (U+017F), as Go does.

**Other errors:** Syntax that Go rejects gives `ZTREE_ERROR_REGEX_SYNTAX` with the byte offset of the error. A program of more than 4096 instructions or 4096 ranges, or more than 256 nested groups, gives `ZTREE_ERROR_LIMIT_REACHED`.

**Text:** Invalid UTF-8 in the text reads as U+FFFD, one byte at a time, as in Go.

The C ABI exports `ztree_regex_match` so that the Go tests can compare ztree with the `regexp` package. The ABI version is 4.

## Consequences
- The regexes of semscope compile and match as in Go.
- A Go test compares ztree with `regexp` on a table, on 20,000 random patterns, and in a fuzz target. A 2-minute fuzz run did 11 million cases with no difference.
- A program has no pointers, so the query compiler can copy it into a query blob ([ADR-0008](/decisions/adr-0008-a-flat-tree-and-a-compiled-query-blob-in-caller-memory--01a1ef929e5c.md)).
- A match needs scratch memory of 6 words for each instruction. The caller gives it.
- A rule set with an unsupported regex fails at compile time, not at match time.

## Alternatives considered
- **A backtracking engine.** Rejected: the time is exponential for some patterns, and the stack has no fixed bound.
- **A DFA.** Rejected: the state count can grow exponentially, and a lazy DFA needs a cache that removes old states.
- **Unicode classes and case folding.** Rejected for now: they need large tables. No semscope regex uses them. A later ADR can add them.
