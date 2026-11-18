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

int main(void) {
  CHECK(ztree_abi_version() == ZTREE_ABI_VERSION);
  test_each_grammar();
  test_points();
  test_buffer_too_small();
  test_bad_arguments();
  test_syntax_errors();
  if (failures > 0) {
    fprintf(stderr, "capi_test: %d failure(s)\n", failures);
    return 1;
  }
  printf("capi_test: all checks pass\n");
  return 0;
}
