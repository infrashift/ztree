// C layout probe for the ABI 14 header of tree-sitter-zig v1.1.2, kept in
// tests/abi14/parser.h (tests/abi_test.zig compares it with src/abi.zig).
#include <stddef.h>
#include "abi14/parser.h"

const size_t ztree_probe14[] = {
  sizeof(TSLanguage),
  offsetof(TSLanguage, lex_modes),
  offsetof(TSLanguage, external_scanner),
  offsetof(TSLanguage, primary_state_ids),
  sizeof(TSLexMode),
};
const size_t ztree_probe14_len = sizeof(ztree_probe14) / sizeof(ztree_probe14[0]);
