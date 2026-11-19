// Test-only shim over the reference runtime (ADR-0002). It exposes the UTF-8
// decoder and drives the reference lexer for tests/lexer_test.zig.
#include <stdbool.h>
#include <stdint.h>
#include "lexer.h"
#include "unicode.h"

uint32_t ztree_ref_decode_utf8(const uint8_t *s, uint32_t len, int32_t *cp) {
  return ts_decode_utf8(s, len, cp);
}

typedef struct {
  const char *string;
  uint32_t length;
} StringInput;

// The same read callback as ts_parser_parse_string.
static const char *read_string(void *payload, uint32_t byte, TSPoint point, uint32_t *bytes_read) {
  (void)point;
  StringInput *input = payload;
  if (byte >= input->length) {
    *bytes_read = 0;
    return "";
  }
  *bytes_read = input->length - byte;
  return input->string + byte;
}

typedef struct {
  bool ok;
  bool did_get_column;
  bool at_range_start;
  uint16_t symbol;
  uint32_t column;
  int32_t lookahead;
  uint32_t lookahead_end_byte;
  Length token_start;
  Length token_end;
} ZtreeLexResult;

// mode 0: lex_fn(state). mode 1: keyword_lex_fn(state). mode 2: a fresh
// external scanner with the valid symbols `valid`. mode 3: advance `state`
// times, then call get_column and is_at_included_range_start.
void ztree_ref_lex(const TSLanguage *lang, const char *src, uint32_t len, Length position,
                   uint32_t mode, uint16_t state, const bool *valid, ZtreeLexResult *out) {
  Lexer lexer;
  ts_lexer_init(&lexer);
  StringInput input = {src, len};
  ts_lexer_set_input(&lexer, (TSInput){&input, read_string, TSInputEncodingUTF8, NULL});
  ts_lexer_reset(&lexer, position);
  ts_lexer_start(&lexer);
  bool ok = false;
  uint32_t column = 0;
  bool at_range_start = false;
  if (mode == 3) {
    for (uint16_t i = 0; i < state; i++) lexer.data.advance(&lexer.data, false);
    column = lexer.data.get_column(&lexer.data);
    at_range_start = lexer.data.is_at_included_range_start(&lexer.data);
  } else if (mode == 0) {
    ok = lang->lex_fn(&lexer.data, state);
  } else if (mode == 1) {
    ok = lang->keyword_lex_fn(&lexer.data, state);
  } else {
    void *payload = lang->external_scanner.create();
    ok = lang->external_scanner.scan(payload, &lexer.data, valid);
    lang->external_scanner.destroy(payload);
  }
  uint32_t lookahead_end = 0;
  ts_lexer_finish(&lexer, &lookahead_end);
  out->ok = ok;
  out->did_get_column = lexer.did_get_column;
  out->at_range_start = at_range_start;
  out->column = column;
  out->symbol = lexer.data.result_symbol;
  out->lookahead = lexer.data.lookahead;
  out->lookahead_end_byte = lookahead_end;
  out->token_start = lexer.token_start_position;
  out->token_end = lexer.token_end_position;
  ts_lexer_delete(&lexer);
}

// ----- Parse dumps for tests/parser_test.zig -----
#include "tree.h"
#include "subtree.h"
#include "tree_sitter/api.h"

typedef struct {
  uint16_t symbol;
  uint16_t parse_state;
  uint16_t production_id;
  uint16_t flags;
  Length padding;
  Length size;
  uint32_t lookahead_bytes;
  uint32_t child_count;
  uint32_t error_cost;
  int32_t dynamic_precedence;
  uint32_t visible_child_count;
  uint32_t named_child_count;
  uint32_t visible_descendant_count;
} ZtreeNodeRecord;

static bool is_repetition(Subtree t) {
  return ts_subtree_child_count(t) > 0 && !ts_subtree_visible(t) && !ts_subtree_named(t);
}

// The number of children of `t` after the flattening of repetition nodes.
static uint32_t flat_child_count(Subtree t) {
  uint32_t n = 0;
  for (uint32_t i = 0; i < ts_subtree_child_count(t); i++) {
    Subtree c = ts_subtree_children(t)[i];
    n += is_repetition(c) ? flat_child_count(c) : 1;
  }
  return n;
}

static void dump(Subtree t, ZtreeNodeRecord *out, uint32_t cap, uint32_t *n);

static void dump_children(Subtree t, ZtreeNodeRecord *out, uint32_t cap, uint32_t *n) {
  for (uint32_t i = 0; i < ts_subtree_child_count(t); i++) {
    Subtree c = ts_subtree_children(t)[i];
    if (is_repetition(c)) dump_children(c, out, cap, n);
    else dump(c, out, cap, n);
  }
}

static void dump(Subtree t, ZtreeNodeRecord *out, uint32_t cap, uint32_t *n) {
  if (*n < cap) {
    uint16_t flags =
      ts_subtree_visible(t) | ts_subtree_named(t) << 1 | ts_subtree_extra(t) << 2 |
      ts_subtree_missing(t) << 3 | ts_subtree_is_keyword(t) << 4 |
      ts_subtree_fragile_left(t) << 5 | ts_subtree_fragile_right(t) << 6 |
      ts_subtree_depends_on_column(t) << 7 | ts_subtree_has_external_tokens(t) << 8;
    bool parent = ts_subtree_child_count(t) > 0;
    out[*n] = (ZtreeNodeRecord){
      .symbol = ts_subtree_symbol(t),
      .parse_state = ts_subtree_parse_state(t),
      .production_id = ts_subtree_production_id(t),
      .flags = flags,
      .padding = ts_subtree_padding(t),
      .size = ts_subtree_size(t),
      .lookahead_bytes = ts_subtree_lookahead_bytes(t),
      .child_count = flat_child_count(t),
      .error_cost = ts_subtree_error_cost(t),
      .dynamic_precedence = ts_subtree_dynamic_precedence(t),
      .visible_child_count = ts_subtree_visible_child_count(t),
      .named_child_count = parent ? t.ptr->named_child_count : 0,
      .visible_descendant_count = ts_subtree_visible_descendant_count(t),
    };
  }
  (*n)++;
  dump_children(t, out, cap, n);
}

// Parse `src` with the reference runtime and write the flattened pre-order
// records of the tree. Return the number of records. `has_error` reports an
// error cost above 0.
uint32_t ztree_ref_parse_dump(const TSLanguage *lang, const char *src, uint32_t len,
                              ZtreeNodeRecord *out, uint32_t cap, bool *has_error) {
  TSParser *parser = ts_parser_new();
  ts_parser_set_language(parser, lang);
  TSTree *tree = ts_parser_parse_string(parser, NULL, src, len);
  uint32_t n = 0;
  *has_error = ts_subtree_error_cost(tree->root) > 0;
  dump(tree->root, out, cap, &n);
  ts_tree_delete(tree);
  ts_parser_delete(parser);
  return n;
}

// ----- S-expressions and comment spans for tests/parser_test.zig -----
#include <stdlib.h>
#include <string.h>

// Write ts_node_string of the root to `out`. Return the full length.
uint32_t ztree_ref_sexp(const TSLanguage *lang, const char *src, uint32_t len, char *out, uint32_t cap) {
  TSParser *parser = ts_parser_new();
  ts_parser_set_language(parser, lang);
  TSTree *tree = ts_parser_parse_string(parser, NULL, src, len);
  char *s = ts_node_string(ts_tree_root_node(tree));
  uint32_t n = (uint32_t)strlen(s);
  memcpy(out, s, n < cap ? n : cap);
  free(s);
  ts_tree_delete(tree);
  ts_parser_delete(parser);
  return n;
}

typedef struct {
  uint32_t start_byte, end_byte, start_row, start_column, end_row, end_column;
} ZtreeSpan;

static bool is_kind(const char *type, const char *const *kinds, uint32_t kind_count) {
  for (uint32_t i = 0; i < kind_count; i++) if (strcmp(type, kinds[i]) == 0) return true;
  return false;
}

// Walk the tree with a TSTreeCursor and write the span of each named node
// whose type is in `kinds`, without entering it. Return the count.
uint32_t ztree_ref_comments(const TSLanguage *lang, const char *src, uint32_t len,
                            const char *const *kinds, uint32_t kind_count, ZtreeSpan *out, uint32_t cap) {
  TSParser *parser = ts_parser_new();
  ts_parser_set_language(parser, lang);
  TSTree *tree = ts_parser_parse_string(parser, NULL, src, len);
  TSTreeCursor cursor = ts_tree_cursor_new(ts_tree_root_node(tree));
  uint32_t n = 0;
  for (;;) {
    TSNode node = ts_tree_cursor_current_node(&cursor);
    bool hit = ts_node_is_named(node) && is_kind(ts_node_type(node), kinds, kind_count);
    if (hit) {
      if (n < cap) {
        TSPoint s = ts_node_start_point(node), e = ts_node_end_point(node);
        out[n] = (ZtreeSpan){ts_node_start_byte(node), ts_node_end_byte(node), s.row, s.column, e.row, e.column};
      }
      n++;
    }
    if (!hit && ts_tree_cursor_goto_first_child(&cursor)) continue;
    while (!ts_tree_cursor_goto_next_sibling(&cursor)) {
      if (!ts_tree_cursor_goto_parent(&cursor)) goto done;
    }
  }
done:
  ts_tree_cursor_delete(&cursor);
  ts_tree_delete(tree);
  ts_parser_delete(parser);
  return n;
}

typedef struct {
  const char *type;
  uint32_t start_byte, end_byte;
  bool named;
} ZtreeVisit;

// Write each node that a TSTreeCursor visits in pre-order. Return the count.
uint32_t ztree_ref_nodes(const TSLanguage *lang, const char *src, uint32_t len, ZtreeVisit *out, uint32_t cap) {
  TSParser *parser = ts_parser_new();
  ts_parser_set_language(parser, lang);
  TSTree *tree = ts_parser_parse_string(parser, NULL, src, len);
  TSTreeCursor cursor = ts_tree_cursor_new(ts_tree_root_node(tree));
  uint32_t n = 0;
  for (;;) {
    TSNode node = ts_tree_cursor_current_node(&cursor);
    if (n < cap) out[n] = (ZtreeVisit){ts_node_type(node), ts_node_start_byte(node), ts_node_end_byte(node), ts_node_is_named(node)};
    n++;
    if (ts_tree_cursor_goto_first_child(&cursor)) continue;
    while (!ts_tree_cursor_goto_next_sibling(&cursor)) {
      if (!ts_tree_cursor_goto_parent(&cursor)) goto done;
    }
  }
done:
  ts_tree_cursor_delete(&cursor);
  ts_tree_delete(tree);
  ts_parser_delete(parser);
  return n;
}

// ----- The flat tree and the TSNode API for tests/differential.zig -----
#include "tree_cursor.h"

#define ZTREE_REF_NONE 0xffffffffu
#define ZTREE_REF_UNKNOWN 0xfffffffeu

// The layout of ztree_node (include/ztree.h).
typedef struct {
  uint32_t start_byte, end_byte, start_row, start_column, end_row, end_column;
  uint32_t parent, next_sibling, child_count, named_child_count;
  uint16_t symbol, field_id, flags, status_field_id;
} ZtreeFlatNode;

// The siblings and the parent of a node from the TSNode API, as indices.
// `children_ok` is 0 when ts_node_child or ts_node_named_child disagrees
// with the cursor order of the children.
typedef struct {
  uint32_t parent, next_sibling, prev_sibling, next_named_sibling, prev_named_sibling;
  uint32_t children_ok;
  // ts_tree_cursor_current_status: bit 0 has_later_siblings, bit 1 has_later_named_siblings.
  uint32_t later;
} ZtreeRefLinks;

typedef struct {
  uint32_t node, field_id, child;
} ZtreeRefFieldChild;

typedef struct {
  const void **keys;
  uint32_t *values;
  uint32_t mask;
} IdTable;

static uint32_t id_hash(const void *id, uint32_t mask) {
  uintptr_t x = (uintptr_t)id;
  x ^= x >> 17;
  x *= 0x9e3779b97f4a7c15ull;
  return (uint32_t)(x >> 32) & mask;
}

static void id_put(IdTable *t, const void *id, uint32_t value) {
  uint32_t h = id_hash(id, t->mask);
  while (t->keys[h] != NULL) h = (h + 1) & t->mask;
  t->keys[h] = id;
  t->values[h] = value;
}

static uint32_t id_index(const IdTable *t, TSNode node) {
  if (ts_node_is_null(node)) return ZTREE_REF_NONE;
  uint32_t h = id_hash(node.id, t->mask);
  while (t->keys[h] != NULL) {
    if (t->keys[h] == node.id) return t->values[h];
    h = (h + 1) & t->mask;
  }
  return ZTREE_REF_UNKNOWN;
}

static uint16_t ref_flags(TSNode node) {
  return (uint16_t)(ts_node_is_named(node) | ts_node_is_extra(node) << 1 | ts_node_is_missing(node) << 2 |
                    ts_node_is_error(node) << 3 | ts_node_has_error(node) << 4);
}

// Check ts_node_child and ts_node_named_child against the cursor order.
static uint32_t children_agree(const TSNode *nodes, const ZtreeFlatNode *recs, uint32_t i) {
  TSNode node = nodes[i];
  uint32_t c = recs[i].child_count > 0 ? i + 1 : ZTREE_REF_NONE;
  uint32_t named = 0;
  for (uint32_t j = 0; j < recs[i].child_count; j++) {
    if (c == ZTREE_REF_NONE || !ts_node_eq(ts_node_child(node, j), nodes[c])) return 0;
    if (recs[c].flags & 1) {
      if (!ts_node_eq(ts_node_named_child(node, named), nodes[c])) return 0;
      named++;
    }
    c = recs[c].next_sibling;
  }
  return c == ZTREE_REF_NONE && named == recs[i].named_child_count;
}

// Walk the reference tree with a TSTreeCursor and write one record for
// each node, from the TSNode API. Write the links of each node and the
// result of ts_node_child_by_field_id for each field. Return the number of
// nodes, or 0 when a buffer is too small.
uint32_t ztree_ref_flat(const TSLanguage *lang, const char *src, uint32_t len, ZtreeFlatNode *recs,
                        ZtreeRefLinks *links, uint32_t cap, ZtreeRefFieldChild *fields,
                        uint32_t field_cap, uint32_t *field_count) {
  TSParser *parser = ts_parser_new();
  ts_parser_set_language(parser, lang);
  TSTree *tree = ts_parser_parse_string(parser, NULL, src, len);
  TSTreeCursor cursor = ts_tree_cursor_new(ts_tree_root_node(tree));
  TSNode *nodes = malloc(sizeof(TSNode) * cap);
  uint32_t *owners = malloc(sizeof(uint32_t) * cap);
  uint32_t *last_child = malloc(sizeof(uint32_t) * cap);
  uint32_t *later_bits = malloc(sizeof(uint32_t) * cap);
  uint32_t depth = 0, n = 0;
  bool ok = true;
  for (;;) {
    if (n >= cap) { ok = false; break; }
    TSNode node = ts_tree_cursor_current_node(&cursor);
    TSPoint s = ts_node_start_point(node), e = ts_node_end_point(node);
    uint32_t parent = depth > 0 ? owners[depth - 1] : ZTREE_REF_NONE;
    TSFieldId status_field = 0;
    bool later_siblings, later_named, later_field;
    TSSymbol supertypes[8];
    unsigned supertype_count = 8;
    ts_tree_cursor_current_status(&cursor, &status_field, &later_siblings, &later_named, &later_field, supertypes,
                                  &supertype_count);
    nodes[n] = node;
    later_bits[n] = (uint32_t)later_siblings | (uint32_t)later_named << 1;
    recs[n] = (ZtreeFlatNode){ts_node_start_byte(node), ts_node_end_byte(node), s.row, s.column, e.row, e.column,
                              parent, ZTREE_REF_NONE, ts_node_child_count(node), ts_node_named_child_count(node),
                              ts_node_symbol(node), ts_tree_cursor_current_field_id(&cursor),
                              (uint16_t)(ref_flags(node) | later_field << 5), status_field};
    if (depth > 0) {
      if (last_child[depth - 1] != ZTREE_REF_NONE) recs[last_child[depth - 1]].next_sibling = n;
      last_child[depth - 1] = n;
    }
    n++;
    if (ts_tree_cursor_goto_first_child(&cursor)) {
      owners[depth] = n - 1;
      last_child[depth] = ZTREE_REF_NONE;
      depth++;
      continue;
    }
    while (!ts_tree_cursor_goto_next_sibling(&cursor)) {
      if (!ts_tree_cursor_goto_parent(&cursor)) goto walked;
      depth--;
    }
  }
walked:;
  uint32_t size = 1;
  while (size < 2 * n + 2) size <<= 1;
  IdTable table = {calloc(size, sizeof(void *)), malloc(sizeof(uint32_t) * size), size - 1};
  for (uint32_t i = 0; ok && i < n; i++) id_put(&table, nodes[i].id, i);
  uint32_t fc = 0;
  uint32_t field_ids = ts_language_field_count(lang);
  for (uint32_t i = 0; ok && i < n; i++) {
    TSNode node = nodes[i];
    links[i] = (ZtreeRefLinks){id_index(&table, ts_node_parent(node)), id_index(&table, ts_node_next_sibling(node)),
                               id_index(&table, ts_node_prev_sibling(node)),
                               id_index(&table, ts_node_next_named_sibling(node)),
                               id_index(&table, ts_node_prev_named_sibling(node)), children_agree(nodes, recs, i),
                               later_bits[i]};
    if (recs[i].child_count == 0) continue;
    for (uint32_t f = 1; f <= field_ids; f++) {
      TSNode child = ts_node_child_by_field_id(node, (TSFieldId)f);
      if (ts_node_is_null(child)) continue;
      if (fc >= field_cap) { ok = false; break; }
      fields[fc++] = (ZtreeRefFieldChild){i, f, id_index(&table, child)};
    }
  }
  *field_count = fc;
  free(table.keys);
  free(table.values);
  free(last_child);
  free(later_bits);
  free(owners);
  free(nodes);
  ts_tree_cursor_delete(&cursor);
  ts_tree_delete(tree);
  ts_parser_delete(parser);
  return ok ? n : 0;
}

// ----- Query matches for tests/query_diff.zig -----

typedef struct {
  uint32_t pattern_index, capture_count;
} ZtreeRefMatch;

typedef struct {
  uint32_t node, index;
} ZtreeRefCapture;

// Run `query` over the tree of `src` with ts_query_cursor_next_match. Write
// each match and its captures, with each node as its cursor pre-order index.
// Return false when the query does not compile or a buffer is too small.
bool ztree_ref_query_matches(const TSLanguage *lang, const char *query, uint32_t query_len, const char *src,
                             uint32_t len, ZtreeRefMatch *matches, uint32_t match_cap, uint32_t *match_count,
                             ZtreeRefCapture *caps, uint32_t cap_cap, uint32_t *cap_count) {
  uint32_t error_offset;
  TSQueryError error_type;
  TSQuery *q = ts_query_new(lang, query, query_len, &error_offset, &error_type);
  if (!q) return false;
  TSParser *parser = ts_parser_new();
  ts_parser_set_language(parser, lang);
  TSTree *tree = ts_parser_parse_string(parser, NULL, src, len);
  // Number the nodes in cursor pre-order.
  uint32_t n = 0, size = 1;
  TSTreeCursor cursor = ts_tree_cursor_new(ts_tree_root_node(tree));
  for (;;) {
    n++;
    if (ts_tree_cursor_goto_first_child(&cursor)) continue;
    while (!ts_tree_cursor_goto_next_sibling(&cursor)) {
      if (!ts_tree_cursor_goto_parent(&cursor)) goto counted;
    }
  }
counted:
  while (size < 2 * n + 2) size <<= 1;
  IdTable table = {calloc(size, sizeof(void *)), malloc(sizeof(uint32_t) * size), size - 1};
  ts_tree_cursor_reset(&cursor, ts_tree_root_node(tree));
  for (uint32_t i = 0;; i++) {
    id_put(&table, ts_tree_cursor_current_node(&cursor).id, i);
    if (ts_tree_cursor_goto_first_child(&cursor)) continue;
    while (!ts_tree_cursor_goto_next_sibling(&cursor)) {
      if (!ts_tree_cursor_goto_parent(&cursor)) goto numbered;
    }
  }
numbered:;
  TSQueryCursor *qc = ts_query_cursor_new();
  ts_query_cursor_exec(qc, q, ts_tree_root_node(tree));
  TSQueryMatch m;
  bool ok = true;
  *match_count = 0;
  *cap_count = 0;
  while (ts_query_cursor_next_match(qc, &m)) {
    if (*match_count >= match_cap || *cap_count + m.capture_count > cap_cap) { ok = false; break; }
    matches[(*match_count)++] = (ZtreeRefMatch){m.pattern_index, m.capture_count};
    for (uint16_t i = 0; i < m.capture_count; i++) {
      caps[(*cap_count)++] = (ZtreeRefCapture){id_index(&table, m.captures[i].node), m.captures[i].index};
    }
  }
  ts_query_cursor_delete(qc);
  ts_tree_cursor_delete(&cursor);
  free(table.keys);
  free(table.values);
  ts_tree_delete(tree);
  ts_parser_delete(parser);
  ts_query_delete(q);
  return ok;
}
