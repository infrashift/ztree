// C layout probe for the ABI 14 header (tests/abi_test.zig compares it with src/abi.zig).
#include <stddef.h>
#include "../third_party/grammars/zig/src/tree_sitter/parser.h"

const size_t ztree_probe14[] = {
  sizeof(TSLanguage),
  offsetof(TSLanguage, lex_modes),
  offsetof(TSLanguage, external_scanner),
  offsetof(TSLanguage, primary_state_ids),
  sizeof(TSLexMode),
};
const size_t ztree_probe14_len = sizeof(ztree_probe14) / sizeof(ztree_probe14[0]);
