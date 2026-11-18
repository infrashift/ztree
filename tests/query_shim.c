// Test-only dump of a compiled reference query (ADR-0002, ADR-0011). The
// struct definitions below copy the private definitions of the vendored
// lib/src/query.c (tree-sitter v0.27.2). A change of the pin needs a new
// copy. The dump is text, so a test failure shows the first difference.
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "array.h"
#include "tree_sitter/api.h"

#define MAX_STEP_CAPTURE_COUNT 3

typedef struct {
  TSSymbol symbol;
  TSSymbol supertype_symbol;
  TSFieldId field;
  uint16_t capture_ids[MAX_STEP_CAPTURE_COUNT];
  uint16_t depth;
  uint16_t alternative_index;
  uint16_t negated_field_list_id;
  bool is_named: 1;
  bool is_immediate: 1;
  bool is_last_child: 1;
  bool is_pass_through: 1;
  bool is_dead_end: 1;
  bool is_inside_alternation: 1;
  bool contains_captures: 1;
  bool root_pattern_guaranteed: 1;
  bool parent_pattern_guaranteed: 1;
  bool is_missing: 1;
  bool alternative_is_skip: 1;
} QueryStep;

typedef struct {
  uint32_t offset;
  uint32_t length;
} Slice;

typedef struct {
  Array(char) characters;
  Array(Slice) slices;
} SymbolTable;

typedef Array(uint8_t) CaptureQuantifiers;

typedef struct {
  uint16_t step_index;
  uint16_t pattern_index;
  bool is_rooted;
} PatternEntry;

typedef struct {
  Slice steps;
  Slice predicate_steps;
  uint32_t start_byte;
  uint32_t end_byte;
  bool is_non_local;
} QueryPattern;

typedef struct {
  uint32_t byte_offset;
  uint16_t step_index;
} StepOffset;

struct TSQuery {
  SymbolTable captures;
  SymbolTable predicate_values;
  Array(CaptureQuantifiers) capture_quantifiers;
  Array(QueryStep) steps;
  Array(PatternEntry) pattern_map;
  Array(TSQueryPredicateStep) predicate_steps;
  Array(QueryPattern) patterns;
  Array(StepOffset) step_offsets;
  Array(TSFieldId) negated_fields;
  Array(char) string_buffer;
  Array(TSSymbol) repeat_symbols_with_rootless_patterns;
  const TSLanguage *language;
  uint16_t wildcard_root_pattern_count;
};

typedef struct {
  char *buf;
  uint32_t cap;
  uint32_t len;
} Out;

static void out(Out *o, const char *fmt, ...) {
  va_list args;
  va_start(args, fmt);
  int n = vsnprintf(o->buf + (o->len < o->cap ? o->len : o->cap), o->len < o->cap ? o->cap - o->len : 0, fmt, args);
  va_end(args);
  if (n > 0) o->len += (uint32_t)n;
}

static void dump_table(Out *o, const char *label, const SymbolTable *t) {
  for (uint32_t i = 0; i < t->slices.size; i++) {
    Slice s = t->slices.contents[i];
    out(o, "%s %u: %.*s\n", label, i, (int)s.length, t->characters.contents + s.offset);
  }
}

// Write the canonical dump of `src` compiled with `lang`. Return its length.
uint32_t ztree_ref_query_dump(const TSLanguage *lang, const char *src, uint32_t len, char *buf, uint32_t cap) {
  Out o = {buf, cap, 0};
  uint32_t error_offset = 0;
  TSQueryError error_type = TSQueryErrorNone;
  TSQuery *q = ts_query_new(lang, src, len, &error_offset, &error_type);
  if (!q) {
    out(&o, "error %d %u\n", (int)error_type, error_offset);
    return o.len;
  }
  for (uint32_t i = 0; i < q->steps.size; i++) {
    const QueryStep *s = &q->steps.contents[i];
    unsigned flags = s->is_named | s->is_immediate << 1 | s->is_last_child << 2 | s->is_pass_through << 3 |
                     s->is_dead_end << 4 | s->is_inside_alternation << 5 | s->contains_captures << 6 |
                     s->root_pattern_guaranteed << 7 | s->parent_pattern_guaranteed << 8 | s->is_missing << 9 |
                     s->alternative_is_skip << 10;
    out(&o, "step %u: sym=%u super=%u field=%u caps=%u,%u,%u depth=%u alt=%u neg=%u flags=%x\n", i, s->symbol,
        s->supertype_symbol, s->field, s->capture_ids[0], s->capture_ids[1], s->capture_ids[2], s->depth,
        s->alternative_index, s->negated_field_list_id, flags);
  }
  for (uint32_t i = 0; i < q->pattern_map.size; i++) {
    const PatternEntry *e = &q->pattern_map.contents[i];
    out(&o, "map %u: step=%u pattern=%u rooted=%u\n", i, e->step_index, e->pattern_index, e->is_rooted);
  }
  for (uint32_t i = 0; i < q->patterns.size; i++) {
    const QueryPattern *p = &q->patterns.contents[i];
    out(&o, "pattern %u: steps=%u+%u preds=%u+%u bytes=%u-%u nonlocal=%u\n", i, p->steps.offset, p->steps.length,
        p->predicate_steps.offset, p->predicate_steps.length, p->start_byte, p->end_byte, p->is_non_local);
    const CaptureQuantifiers *cq = &q->capture_quantifiers.contents[i];
    out(&o, "quantifiers %u:", i);
    for (uint32_t j = 0; j < cq->size; j++) out(&o, " %u", cq->contents[j]);
    out(&o, "\n");
  }
  for (uint32_t i = 0; i < q->predicate_steps.size; i++) {
    out(&o, "pred %u: %u %u\n", i, q->predicate_steps.contents[i].type, q->predicate_steps.contents[i].value_id);
  }
  out(&o, "negated:");
  for (uint32_t i = 0; i < q->negated_fields.size; i++) out(&o, " %u", q->negated_fields.contents[i]);
  out(&o, "\nrepeat:");
  for (uint32_t i = 0; i < q->repeat_symbols_with_rootless_patterns.size; i++) {
    out(&o, " %u", q->repeat_symbols_with_rootless_patterns.contents[i]);
  }
  out(&o, "\nwildcard roots: %u\n", q->wildcard_root_pattern_count);
  dump_table(&o, "capture", &q->captures);
  dump_table(&o, "value", &q->predicate_values);
  ts_query_delete(q);
  return o.len;
}
