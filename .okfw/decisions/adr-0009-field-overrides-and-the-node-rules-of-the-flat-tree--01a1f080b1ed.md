---
id: "01a1f080-b1ed-7b27-b22e-ac78e35e064e"
title: "ADR-0009: Field overrides and the node rules of the flat tree"
type: "ADR"
tags:
  - "adr"
  - "capi"
  - "semscope"
created: "2026-11-18T15:12:08-06:00"
timestamp: "2026-11-18T15:12:08-06:00"
description: "ztree_parse writes field overrides for the rare field lookups that the first-child rule does not give, and the binding follows the sibling and error rules of the reference TSNode API."
---

# ADR-0009: Field overrides and the node rules of the flat tree

**Status:** Accepted
**Date:** 2026-11-18
**Source:** [ISSUE-011](/issues/issue-011-the-flat-tree-and-the-node-api--01a1ef92fe81.md). The differential step on 903 real files.

## Context
[ADR-0008](/decisions/adr-0008-a-flat-tree-and-a-compiled-query-blob-in-caller-memory--01a1ef929e5c.md) gives each visible node one record with a field id. The field id is the result of `ts_tree_cursor_current_field_id`. The Go binding finds a field child as the first child with that field id. The differential step compares each node with the `TSNode` API of the reference runtime. It found four rules that the records do not give:

1. `ts_node_child_by_field_id` reads the field map of the production of the node. An ERROR node has no field map, so it gives no field child. But the cursor can give a field id to a child of an ERROR node. A hidden node between them has the field.
2. An inherited field entry can point to a hidden child with an alias. The alias makes the child visible. `ts_node_child_by_field_id` then gives a grandchild. Example: the C `parameters` field of an old-style function definition.
3. `ts_node_next_sibling` compares byte positions. It skips a sibling that ends where the node ends, such as an empty MISSING node. The cursor visits that sibling.
4. `ts_node_string` writes the MISSING node of a hidden token. For an ERROR leaf, it writes the lookahead character of the lexer. A cursor does not visit a hidden MISSING node. The lookahead character is not a property of a visible node.

## Decision
1. **Field overrides.** `ztree_parse` writes a second array of `ztree_field_override` records (node, field id, child). ztree runs the algorithm of `ts_node_child_by_field_id` with an explicit stack. It runs it for each node and each field of the node and its children. It writes an override when the result is not the first child with that field id. The child of an override can be `ZTREE_NONE`. Rules 1 and 2 give overrides.
2. **Sibling rules in the binding.** `NextSibling` and `NextNamedSibling` skip each sibling that ends at or before the end of the node. `PrevSibling` and `PrevNamedSibling` use the cursor order.
3. **`ts_node_has_error`.** The flag `ZTREE_NODE_HAS_ERROR` is true for an ERROR node and for a node with an error cost. An ERROR leaf can have no error cost.
4. **S-expressions.** The flat tree holds the nodes that a cursor visits, and no more. `ToSexp` omits the MISSING nodes of hidden tokens. It writes the first character of the text of an ERROR leaf in `(UNEXPECTED ...)`. `tree.writeVisibleSexp` writes the same text from the tree, and the tests compare the flat tree with it.

## Consequences
- `ChildByFieldName` gives the result of the reference for each node and each field of the differential corpus. Overrides are rare: 10 in this repository and 1,529 in 133 libstdc++ headers, all in trees with syntax errors.
- `ztree_parse` takes nine arguments. A second buffer can be too small, so a parse can run three times in the worst case. The Go binding keeps a size hint for each buffer.
- The flat tree needs no production ids and no hidden nodes, so the binding stays simple.
- `ToSexp` can differ from `ts_node_string` in two places. The first is a hidden MISSING node. The second is the character of an ERROR leaf when the lexer stopped after the first character. Only debug output uses the S-expression.

## Alternatives considered
- **A field map in the binding.** The binding then needs the production id and the hidden nodes of each node. Rejected: the flat tree then holds the whole subtree arena.
- **The lookahead character in each record.** A code point needs 21 bits, and only `ToSexp` reads it. Rejected: it adds 4 bytes to each of millions of records.
- **Hidden MISSING nodes as records.** Rejected: the records then differ from the cursor, and each node method of the reference then needs a special case.
