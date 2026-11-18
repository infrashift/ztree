/*
 * ztree: comment extraction with a Tree-sitter runtime in Zig.
 *
 * The C ABI of libztree.a. The wiki spec "ztree C ABI" defines each rule.
 * The functions take no callbacks and keep no global state. Two threads can
 * call them at the same time. Each call allocates on the C heap and frees
 * the memory before it returns. An internal assertion failure aborts the
 * process.
 */
#ifndef ZTREE_H
#define ZTREE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The version of this header. ztree_abi_version() returns the version of the library. */
#define ZTREE_ABI_VERSION 2

/* Grammars. */
#define ZTREE_LANG_GO 0
#define ZTREE_LANG_ZIG 1
#define ZTREE_LANG_PYTHON 2
#define ZTREE_LANG_C 3
#define ZTREE_LANG_RUST 4
#define ZTREE_LANG_CPP 5

/* Status codes. */
#define ZTREE_OK 0
#define ZTREE_ERROR_BUFFER_TOO_SMALL 1 /* *count_out holds the number of comments. */
#define ZTREE_ERROR_INVALID_ARGUMENT 2
#define ZTREE_ERROR_SOURCE_TOO_LARGE 3 /* More than ZTREE_MAX_SOURCE_BYTES. */
#define ZTREE_ERROR_OUT_OF_MEMORY 4
#define ZTREE_ERROR_LIMIT_REACHED 5    /* A hard limit of the parser: nodes, stack or depth. */
#define ZTREE_ERROR_UNSUPPORTED_GRAMMAR 6

/* The largest source, in bytes. */
#define ZTREE_MAX_SOURCE_BYTES (16u * 1024u * 1024u)

/*
 * One comment. Bytes are offsets into the source. Rows start at 0. A column
 * counts bytes from the start of its row. The end is exclusive.
 */
typedef struct ztree_span {
  uint32_t start_byte;
  uint32_t end_byte;
  uint32_t start_row;
  uint32_t start_column;
  uint32_t end_row;
  uint32_t end_column;
} ztree_span;

/* The ABI version of the library. */
uint32_t ztree_abi_version(void);

/*
 * Parse src[0..len) with the grammar lang. Write the spans of the first
 * max_spans comments to spans_out, in source order. Write the number of
 * comments in the source to *count_out.
 *
 * Returns ZTREE_OK when *count_out <= max_spans. Returns
 * ZTREE_ERROR_BUFFER_TOO_SMALL when *count_out > max_spans; spans_out then
 * holds the first max_spans comments. Each other status sets *count_out to 0.
 *
 * src can be NULL when len is 0. spans_out can be NULL when max_spans is 0.
 * A NULL count_out gives ZTREE_ERROR_INVALID_ARGUMENT.
 */
int32_t ztree_extract_comments(uint32_t lang, const uint8_t *src, size_t len,
                               ztree_span *spans_out, size_t max_spans,
                               size_t *count_out);

#ifdef __cplusplus
}
#endif

#endif /* ZTREE_H */
