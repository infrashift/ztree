/*
 * ztree: a batch Tree-sitter runtime in Zig. It gives the comments of a
 * source file and its syntax tree as a flat array of nodes.
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
#define ZTREE_ABI_VERSION 5

/* Grammars. */
#define ZTREE_LANG_GO 0
#define ZTREE_LANG_ZIG 1
#define ZTREE_LANG_PYTHON 2
#define ZTREE_LANG_C 3
#define ZTREE_LANG_RUST 4
#define ZTREE_LANG_CPP 5

/* Status codes. */
#define ZTREE_OK 0
#define ZTREE_ERROR_BUFFER_TOO_SMALL 1 /* *count_out holds the number of items. */
#define ZTREE_ERROR_INVALID_ARGUMENT 2
#define ZTREE_ERROR_SOURCE_TOO_LARGE 3 /* More than ZTREE_MAX_SOURCE_BYTES. */
#define ZTREE_ERROR_OUT_OF_MEMORY 4
#define ZTREE_ERROR_LIMIT_REACHED 5    /* A hard limit of the parser: nodes, stack or depth. */
#define ZTREE_ERROR_UNSUPPORTED_GRAMMAR 6
#define ZTREE_ERROR_REGEX_SYNTAX 7      /* The Go regexp package rejects the pattern too. */
#define ZTREE_ERROR_REGEX_UNSUPPORTED 8 /* Valid RE2 syntax that ztree does not read. */
#define ZTREE_ERROR_QUERY 9             /* *error_out holds the error of the query. */

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

/*
 * The syntax tree (ztree_parse). The nodes are the nodes that a
 * Tree-sitter cursor visits, in pre-order: the root, then each named and
 * anonymous node. Node 0 is the root. The first child of a node with
 * children is at the next index.
 */

/* An index that names no node: the parent of the root, or the next sibling of the last child. */
#define ZTREE_NONE 0xffffffffu

/* The symbol of an ERROR node. */
#define ZTREE_SYMBOL_ERROR 0xffffu

/* The bits of ztree_node.flags. */
#define ZTREE_NODE_NAMED 0x1u     /* ts_node_is_named */
#define ZTREE_NODE_EXTRA 0x2u     /* ts_node_is_extra */
#define ZTREE_NODE_MISSING 0x4u   /* ts_node_is_missing */
#define ZTREE_NODE_ERROR 0x8u     /* ts_node_is_error */
#define ZTREE_NODE_HAS_ERROR 0x10u /* ts_node_has_error */

/*
 * One node. Bytes, rows and columns follow the rules of ztree_span. The
 * size is 48 bytes.
 */
typedef struct ztree_node {
  uint32_t start_byte;
  uint32_t end_byte;
  uint32_t start_row;
  uint32_t start_column;
  uint32_t end_row;
  uint32_t end_column;
  uint32_t parent;            /* ZTREE_NONE for the root. */
  uint32_t next_sibling;      /* ZTREE_NONE for the last child. */
  uint32_t child_count;       /* ts_node_child_count */
  uint32_t named_child_count; /* ts_node_named_child_count */
  uint16_t symbol;            /* ts_node_symbol: the public symbol, with the alias applied. */
  uint16_t field_id;          /* ts_tree_cursor_current_field_id, or 0. */
  uint16_t flags;             /* ZTREE_NODE_* bits. */
  uint16_t reserved;          /* 0. */
} ztree_node;

/*
 * A field lookup that the first-child rule does not give. The first-child
 * rule: ts_node_child_by_field_id(node, field_id) gives the first child of
 * node whose field_id is field_id, or no node. An override gives child in
 * place of that result, or ZTREE_NONE for no node. Overrides are rare: an
 * ERROR node has no fields, and an inherited field can name a grandchild.
 */
typedef struct ztree_field_override {
  uint32_t node;
  uint32_t child; /* ZTREE_NONE for no node. */
  uint16_t field_id;
  uint16_t reserved; /* 0. */
} ztree_field_override;

/*
 * Parse src[0..len) with the grammar lang. Write the first max_nodes nodes
 * of the tree to nodes_out and the number of nodes to *node_count_out. A
 * tree has 1 or more nodes. Write the first max_overrides field overrides
 * to overrides_out, in node order, and their number to *override_count_out.
 *
 * Returns ZTREE_OK when each count is at most the size of its buffer.
 * Returns ZTREE_ERROR_BUFFER_TOO_SMALL when a count is more than the size of
 * its buffer. Both counts are then valid, and each buffer holds its first
 * records. A link (parent or next_sibling) can then name a node that is not
 * in the buffer. Each other status sets both counts to 0.
 *
 * src can be NULL when len is 0. A buffer can be NULL when its size is 0.
 * A NULL count pointer gives ZTREE_ERROR_INVALID_ARGUMENT.
 */
int32_t ztree_parse(uint32_t lang, const uint8_t *src, size_t len,
                    ztree_node *nodes_out, size_t max_nodes,
                    size_t *node_count_out,
                    ztree_field_override *overrides_out, size_t max_overrides,
                    size_t *override_count_out);

/*
 * Grammar metadata. Each function gives 0 or NULL for an unknown lang. A
 * name points into the static data of the library.
 */

/* The bits of ztree_language_symbol_flags. */
#define ZTREE_SYMBOL_VISIBLE 0x1u
#define ZTREE_SYMBOL_NAMED 0x2u
#define ZTREE_SYMBOL_SUPERTYPE 0x4u

/* The Tree-sitter ABI version of the grammar: 14 or 15. */
uint32_t ztree_language_abi_version(uint32_t lang);

/* The number of symbols, aliases included (ts_language_symbol_count). */
uint32_t ztree_language_symbol_count(uint32_t lang);

/* The largest field id. Field ids start at 1. */
uint32_t ztree_language_field_count(uint32_t lang);

/* The name of a symbol, "ERROR" for ZTREE_SYMBOL_ERROR, or NULL out of range. */
const char *ztree_language_symbol_name(uint32_t lang, uint32_t symbol);

/* The ZTREE_SYMBOL_* bits of a symbol, or 0 out of range. */
uint32_t ztree_language_symbol_flags(uint32_t lang, uint32_t symbol);

/* The name of a field, or NULL for 0 and out of range. */
const char *ztree_language_field_name(uint32_t lang, uint32_t field);

/*
 * Queries. A compiled query is a blob with no pointers in caller memory. A
 * caller can copy the blob and share it between threads. The blob is valid
 * only for the ztree library that wrote it.
 */

/* The kinds of ztree_query_error. Kinds 1 to 6 are those of TSQueryError. */
#define ZTREE_QUERY_ERROR_SYNTAX 1
#define ZTREE_QUERY_ERROR_NODE_TYPE 2
#define ZTREE_QUERY_ERROR_FIELD 3
#define ZTREE_QUERY_ERROR_CAPTURE 4
#define ZTREE_QUERY_ERROR_STRUCTURE 5  /* A pattern that the grammar cannot produce. */
#define ZTREE_QUERY_ERROR_LANGUAGE 6
#define ZTREE_QUERY_ERROR_PREDICATE 7  /* An unknown predicate, bad arguments, or a bad regex. */
#define ZTREE_QUERY_ERROR_UNSUPPORTED 8 /* A supertype, a directive, or a regex outside the subset. */

/* The largest query text, in bytes. */
#define ZTREE_MAX_QUERY_BYTES (1024u * 1024u)

/* The position of a query error. offset is a byte offset; row and column start at 0. */
typedef struct ztree_query_error {
  uint32_t kind;
  uint32_t offset;
  uint32_t row;
  uint32_t column;
} ztree_query_error;

/*
 * Compile the query src[0..len) for the grammar lang. Write the blob to
 * blob_out when it fits, and its size to *blob_size_out. blob_out must be
 * aligned to 4 bytes.
 *
 * Returns ZTREE_OK, or ZTREE_ERROR_BUFFER_TOO_SMALL with the size in
 * *blob_size_out. Returns ZTREE_ERROR_QUERY with *error_out for an error in
 * the query, and ZTREE_ERROR_LIMIT_REACHED for a query that needs more than
 * a hard limit. blob_out can be NULL when blob_cap is 0.
 */
int32_t ztree_query_compile(uint32_t lang, const uint8_t *src, size_t len,
                            uint8_t *blob_out, size_t blob_cap,
                            size_t *blob_size_out, ztree_query_error *error_out);

/*
 * Report in *matched_out whether the regex pattern[0..pattern_len) matches
 * somewhere in text[0..text_len), as regexp.Match of Go does. The pattern
 * syntax is a subset of RE2 (the wiki decision ADR-0010). The query
 * predicate #match? uses the same engine.
 *
 * Returns ZTREE_OK, ZTREE_ERROR_REGEX_SYNTAX or ZTREE_ERROR_REGEX_UNSUPPORTED
 * with the byte offset of the error in *error_offset_out, or
 * ZTREE_ERROR_LIMIT_REACHED for a pattern that needs too large a program.
 * pattern and text can be NULL when their length is 0.
 */
int32_t ztree_regex_match(const uint8_t *pattern, size_t pattern_len,
                          const uint8_t *text, size_t text_len,
                          int32_t *matched_out, size_t *error_offset_out);

#ifdef __cplusplus
}
#endif

#endif /* ZTREE_H */
