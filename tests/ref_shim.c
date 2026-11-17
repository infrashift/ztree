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
