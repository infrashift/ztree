// A C caller of libztree.a: it includes include/ztree.h and links the
// static library, as a cgo caller does. `zig build test` runs it.
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ztree.h"

_Static_assert(sizeof(ztree_span) == 24, "ztree_span has six uint32_t fields");
_Static_assert(offsetof(ztree_span, end_byte) == 4, "end_byte follows start_byte");
_Static_assert(offsetof(ztree_span, end_column) == 20, "end_column is the last field");
_Static_assert(sizeof(ztree_node) == 48, "ztree_node has 48 bytes");
_Static_assert(offsetof(ztree_node, parent) == 24, "the links follow the points");
_Static_assert(offsetof(ztree_node, symbol) == 40, "the symbol follows the counts");
_Static_assert(offsetof(ztree_node, flags) == 44, "the flags follow the field id");
_Static_assert(sizeof(ztree_field_override) == 12, "ztree_field_override has 12 bytes");

static int failures = 0;

#define CHECK(cond)                                                    \
  do {                                                                 \
    if (!(cond)) {                                                     \
      fprintf(stderr, "%s:%d: check failed: %s\n", __FILE__, __LINE__, \
              #cond);                                                  \
      failures++;                                                      \
    }                                                                  \
  } while (0)

// Extract the comments of src and compare their text with want.
static void expect_comments(uint32_t lang, const char *src, const char **want,
                            size_t want_len) {
  ztree_span spans[8];
  size_t count = 99;
  int32_t status = ztree_extract_comments(lang, (const uint8_t *)src,
                                          strlen(src), spans, 8, &count);
  CHECK(status == ZTREE_OK);
  CHECK(count == want_len);
  for (size_t i = 0; i < want_len && i < count; i++) {
    const ztree_span s = spans[i];
    size_t n = s.end_byte - s.start_byte;
    CHECK(n == strlen(want[i]));
    CHECK(strncmp(src + s.start_byte, want[i], n) == 0);
  }
}

static void test_each_grammar(void) {
  const char *go[] = {"// a", "/* b */"};
  expect_comments(ZTREE_LANG_GO, "package p\n// a\nvar x = 1 /* b */\n", go, 2);
  const char *zig[] = {"// a", "/// b"};
  expect_comments(ZTREE_LANG_ZIG, "// a\n/// b\nconst x = struct {};\n", zig, 2);
  const char *py[] = {"# a", "# b"};
  expect_comments(ZTREE_LANG_PYTHON, "# a\nx = 1  # b\n", py, 2);
  const char *c[] = {"/* a */", "// b"};
  expect_comments(ZTREE_LANG_C, "/* a */ int x; // b\n", c, 2);
  const char *rust[] = {"// a", "/* c */"};
  expect_comments(ZTREE_LANG_RUST, "// a\nfn f() {} /* c */\n", rust, 2);
  /* The raw string holds "//": the external scanner reads it as string content. */
  const char *cpp[] = {"/* a */", "// b"};
  expect_comments(ZTREE_LANG_CPP, "/* a */ auto s = R\"d(// no)d\"; // b\n", cpp, 2);
  /* The C# raw string also holds "//". */
  const char *cs[] = {"/// a", "/* b */"};
  expect_comments(ZTREE_LANG_CSHARP, "/// a\nclass C { string s = \"\"\"// no\"\"\"; /* b */ }\n", cs, 2);
}

static void test_points(void) {
  const char *src = "package p\n\nvar x = 1 // tail\n";
  ztree_span s;
  size_t count = 0;
  CHECK(ztree_extract_comments(ZTREE_LANG_GO, (const uint8_t *)src, strlen(src),
                               &s, 1, &count) == ZTREE_OK);
  CHECK(count == 1);
  CHECK(s.start_row == 2 && s.start_column == 10);
  CHECK(s.end_row == 2 && s.end_column == 17);
  CHECK(s.start_byte == 21 && s.end_byte == 28);
}

static void test_buffer_too_small(void) {
  const char *src = "// a\n// b\n// c\npackage p\n";
  ztree_span spans[3];
  memset(spans, 0, sizeof spans);
  size_t count = 0;
  CHECK(ztree_extract_comments(ZTREE_LANG_GO, (const uint8_t *)src, strlen(src),
                               spans, 2, &count) == ZTREE_ERROR_BUFFER_TOO_SMALL);
  CHECK(count == 3);
  CHECK(spans[1].start_byte == 5);
  CHECK(spans[2].end_byte == 0); // Not written.
  CHECK(ztree_extract_comments(ZTREE_LANG_GO, (const uint8_t *)src, strlen(src),
                               NULL, 0, &count) == ZTREE_ERROR_BUFFER_TOO_SMALL);
  CHECK(count == 3);
  CHECK(ztree_extract_comments(ZTREE_LANG_GO, (const uint8_t *)src, strlen(src),
                               spans, count, &count) == ZTREE_OK);
}

static void test_bad_arguments(void) {
  ztree_span s;
  size_t count = 99;
  CHECK(ztree_extract_comments(99, (const uint8_t *)"x", 1, &s, 1, &count) ==
        ZTREE_ERROR_INVALID_ARGUMENT);
  CHECK(count == 0);
  CHECK(ztree_extract_comments(ZTREE_LANG_GO, NULL, 1, &s, 1, &count) ==
        ZTREE_ERROR_INVALID_ARGUMENT);
  CHECK(ztree_extract_comments(ZTREE_LANG_GO, (const uint8_t *)"x", 1, NULL, 1,
                               &count) == ZTREE_ERROR_INVALID_ARGUMENT);
  CHECK(ztree_extract_comments(ZTREE_LANG_GO, (const uint8_t *)"x", 1, &s, 1,
                               NULL) == ZTREE_ERROR_INVALID_ARGUMENT);
  CHECK(ztree_extract_comments(ZTREE_LANG_GO, NULL, 0, NULL, 0, &count) ==
        ZTREE_OK);
  CHECK(count == 0);
  size_t big = (size_t)ZTREE_MAX_SOURCE_BYTES + 1;
  uint8_t *src = calloc(big, 1);
  CHECK(src != NULL);
  CHECK(ztree_extract_comments(ZTREE_LANG_GO, src, big, &s, 1, &count) ==
        ZTREE_ERROR_SOURCE_TOO_LARGE);
  free(src);
}

static void test_syntax_errors(void) {
  // A tree with errors still gives its comments.
  const char *want[] = {"// a", "// b"};
  expect_comments(ZTREE_LANG_GO, "package p\n// a\nfunc f( {\n// b\n", want, 2);
}

// The name of the symbol of node i.
static const char *kind(uint32_t lang, const ztree_node *nodes, uint32_t i) {
  return ztree_language_symbol_name(lang, nodes[i].symbol);
}

// Parse with a buffer of 8 overrides.
static int32_t parse_go(const char *src, ztree_node *nodes, size_t max_nodes, size_t *count) {
  ztree_field_override overrides[8];
  size_t override_count = 0;
  return ztree_parse(ZTREE_LANG_GO, (const uint8_t *)src, strlen(src), nodes, max_nodes, count,
                     overrides, 8, &override_count);
}

static void test_parse(void) {
  const char *src = "package p\n\nfunc f(a int) {}\n";
  ztree_node nodes[64];
  size_t count = 0;
  CHECK(parse_go(src, nodes, 64, &count) == ZTREE_OK);
  CHECK(count > 8 && count < 64);
  CHECK(strcmp(kind(ZTREE_LANG_GO, nodes, 0), "source_file") == 0);
  CHECK(nodes[0].parent == ZTREE_NONE && nodes[0].next_sibling == ZTREE_NONE);
  CHECK((nodes[0].flags & ZTREE_NODE_HAS_ERROR) == 0);
  // Find the function in the children of the root.
  uint32_t fn = 1;
  while (fn != ZTREE_NONE && strcmp(kind(ZTREE_LANG_GO, nodes, fn), "function_declaration") != 0) {
    CHECK(nodes[fn].parent == 0);
    fn = nodes[fn].next_sibling;
  }
  CHECK(fn != ZTREE_NONE);
  if (fn == ZTREE_NONE) return;
  CHECK(nodes[fn].start_row == 2 && nodes[fn].start_column == 0);
  CHECK(nodes[fn].end_byte - nodes[fn].start_byte == strlen("func f(a int) {}"));
  CHECK(strcmp(kind(ZTREE_LANG_GO, nodes, fn + 1), "func") == 0);
  CHECK((nodes[fn + 1].flags & ZTREE_NODE_NAMED) == 0);
  CHECK(strcmp(ztree_language_field_name(ZTREE_LANG_GO, nodes[fn + 2].field_id), "name") == 0);
  CHECK(nodes[fn + 2].parent == fn);
  size_t total = count;
  CHECK(parse_go(src, nodes, 2, &count) == ZTREE_ERROR_BUFFER_TOO_SMALL);
  CHECK(count == total);
  size_t override_count = 99;
  CHECK(ztree_parse(99, (const uint8_t *)src, strlen(src), nodes, 64, &count, NULL, 0,
                    &override_count) == ZTREE_ERROR_INVALID_ARGUMENT);
  CHECK(count == 0 && override_count == 0);
  CHECK(ztree_parse(ZTREE_LANG_GO, (const uint8_t *)src, strlen(src), nodes, 64, &count, NULL,
                    0, NULL) == ZTREE_ERROR_INVALID_ARGUMENT);
  // A tree with errors.
  const char *bad = "package p\nfunc f( {\n";
  CHECK(parse_go(bad, nodes, 64, &count) == ZTREE_OK);
  CHECK((nodes[0].flags & ZTREE_NODE_HAS_ERROR) != 0);
}

static void test_language(void) {
  for (uint32_t lang = 0; lang <= ZTREE_LANG_CSHARP; lang++) {
    uint32_t abi = ztree_language_abi_version(lang);
    CHECK(abi == 14 || abi == 15);
    uint32_t symbols = ztree_language_symbol_count(lang);
    CHECK(symbols > 10);
    CHECK(ztree_language_symbol_name(lang, symbols) == NULL);
    CHECK(strcmp(ztree_language_symbol_name(lang, ZTREE_SYMBOL_ERROR), "ERROR") == 0);
    CHECK(ztree_language_symbol_flags(lang, ZTREE_SYMBOL_ERROR) ==
          (ZTREE_SYMBOL_VISIBLE | ZTREE_SYMBOL_NAMED));
    uint32_t fields = ztree_language_field_count(lang);
    CHECK(fields > 0);
    CHECK(ztree_language_field_name(lang, 0) == NULL);
    CHECK(ztree_language_field_name(lang, fields) != NULL);
  }
  CHECK(ztree_language_abi_version(99) == 0);
  CHECK(ztree_language_field_name(99, 1) == NULL);
}

static void test_query_compile(void) {
  _Alignas(4) uint8_t blob[8192];
  size_t size = 0;
  ztree_query_error err;
  const char *q = "(call_expression function: (identifier) @f (#eq? @f \"panic\"))";
  CHECK(ztree_query_compile(ZTREE_LANG_GO, (const uint8_t *)q, strlen(q), blob, sizeof blob, &size, &err) ==
        ZTREE_OK);
  CHECK(size > 0 && size <= sizeof blob);
  size_t needed = size;
  CHECK(ztree_query_compile(ZTREE_LANG_GO, (const uint8_t *)q, strlen(q), NULL, 0, &size, &err) ==
        ZTREE_ERROR_BUFFER_TOO_SMALL);
  CHECK(size == needed);
  const char *bad = "(call_expression\n  function: (no_such_node))";
  CHECK(ztree_query_compile(ZTREE_LANG_GO, (const uint8_t *)bad, strlen(bad), blob, sizeof blob, &size, &err) ==
        ZTREE_ERROR_QUERY);
  CHECK(err.kind == ZTREE_QUERY_ERROR_NODE_TYPE && err.row == 1 && err.column == 13 && err.offset == 30);
}

int main(void) {
  CHECK(ztree_abi_version() == ZTREE_ABI_VERSION);
  test_each_grammar();
  test_points();
  test_buffer_too_small();
  test_bad_arguments();
  test_syntax_errors();
  test_parse();
  test_language();
  test_query_compile();
  if (failures > 0) {
    fprintf(stderr, "capi_test: %d failure(s)\n", failures);
    return 1;
  }
  printf("capi_test: all checks pass\n");
  return 0;
}
