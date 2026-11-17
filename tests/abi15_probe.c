// C layout probe for the ABI 15 header (tests/abi_test.zig compares it with src/abi.zig).
#include <stddef.h>
#include "../third_party/grammars/go/src/tree_sitter/parser.h"

const size_t ztree_probe15[] = {
  sizeof(TSLanguage),
  offsetof(TSLanguage, max_alias_sequence_length),
  offsetof(TSLanguage, parse_table),
  offsetof(TSLanguage, lex_modes),
  offsetof(TSLanguage, keyword_capture_token),
  offsetof(TSLanguage, external_scanner),
  offsetof(TSLanguage, primary_state_ids),
  offsetof(TSLanguage, name),
  offsetof(TSLanguage, max_reserved_word_set_size),
  offsetof(TSLanguage, supertype_count),
  offsetof(TSLanguage, metadata),
  sizeof(TSLexer),
  offsetof(TSLexer, advance),
  offsetof(TSLexer, log),
  sizeof(TSParseActionEntry),
  sizeof(TSLexerMode),
  sizeof(TSFieldMapEntry),
  sizeof(TSSymbolMetadata),
};
const size_t ztree_probe15_len = sizeof(ztree_probe15) / sizeof(ztree_probe15[0]);
