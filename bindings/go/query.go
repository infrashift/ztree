package ztree

/*
#include <ztree.h>
*/
import "C"

import (
	"errors"
	"fmt"
	"unsafe"
)

// The query API has the names of go-tree-sitter (ADR-0007). One cgo call
// compiles a query into a blob in Go memory, and one cgo call runs it over
// a tree (ADR-0008, ADR-0012). The text predicates run inside ztree.

// QueryErrorKind is the kind of a query error.
type QueryErrorKind uint32

// The kinds of a query error. Kinds 1 to 6 are those of TSQueryError.
const (
	QueryErrorSyntax      QueryErrorKind = C.ZTREE_QUERY_ERROR_SYNTAX
	QueryErrorNodeType    QueryErrorKind = C.ZTREE_QUERY_ERROR_NODE_TYPE
	QueryErrorField       QueryErrorKind = C.ZTREE_QUERY_ERROR_FIELD
	QueryErrorCapture     QueryErrorKind = C.ZTREE_QUERY_ERROR_CAPTURE
	QueryErrorStructure   QueryErrorKind = C.ZTREE_QUERY_ERROR_STRUCTURE
	QueryErrorLanguage    QueryErrorKind = C.ZTREE_QUERY_ERROR_LANGUAGE
	QueryErrorPredicate   QueryErrorKind = C.ZTREE_QUERY_ERROR_PREDICATE
	QueryErrorUnsupported QueryErrorKind = C.ZTREE_QUERY_ERROR_UNSUPPORTED
)

func (k QueryErrorKind) String() string {
	names := map[QueryErrorKind]string{
		QueryErrorSyntax: "syntax", QueryErrorNodeType: "node type", QueryErrorField: "field",
		QueryErrorCapture: "capture", QueryErrorStructure: "structure", QueryErrorLanguage: "language",
		QueryErrorPredicate: "predicate", QueryErrorUnsupported: "unsupported",
	}
	if name, ok := names[k]; ok {
		return name
	}
	return fmt.Sprintf("QueryErrorKind(%d)", uint32(k))
}

// QueryError is an error in a query. Offset is a byte offset. Row and
// Column start at 0; Column counts bytes.
type QueryError struct {
	Row     uint
	Column  uint
	Offset  uint
	Kind    QueryErrorKind
	Message string
}

func (e *QueryError) Error() string {
	return fmt.Sprintf("ztree: query %s error at row %d, column %d: %s", e.Kind, e.Row, e.Column, e.Message)
}

// Query is a compiled query. Two goroutines can use one Query at the same time.
type Query struct {
	language     *Language
	blob         []uint32 // 4-byte aligned for the C ABI
	blobLen      int
	captureNames []string
	patternCount uint
}

// NewQuery compiles source for the grammar of language.
func NewQuery(language *Language, source string) (*Query, *QueryError) {
	if language == nil {
		return nil, &QueryError{Kind: QueryErrorLanguage, Message: "no language"}
	}
	blob := make([]uint32, 256+len(source))
	for range 2 {
		size, qerr, status := compileQuery(language.lang, source, blob)
		switch status {
		case C.ZTREE_OK:
			return newQuery(language, blob, size), nil
		case C.ZTREE_ERROR_BUFFER_TOO_SMALL:
			blob = make([]uint32, (size+3)/4)
		case C.ZTREE_ERROR_QUERY:
			return nil, qerr
		default:
			return nil, &QueryError{Kind: QueryErrorUnsupported, Message: statusError(status).Error()}
		}
	}
	return nil, &QueryError{Kind: QueryErrorSyntax, Message: "the blob size changed between two compiles"}
}

func compileQuery(lang Lang, source string, blob []uint32) (int, *QueryError, C.int32_t) {
	var srcPtr *C.uint8_t
	if len(source) > 0 {
		srcPtr = (*C.uint8_t)(unsafe.Pointer(unsafe.StringData(source)))
	}
	var size C.size_t
	var cerr C.ztree_query_error
	status := C.ztree_query_compile(C.uint32_t(lang), srcPtr, C.size_t(len(source)),
		(*C.uint8_t)(unsafe.Pointer(&blob[0])), C.size_t(len(blob)*4), &size, &cerr)
	if status != C.ZTREE_ERROR_QUERY {
		return int(size), nil, status
	}
	qerr := &QueryError{Row: uint(cerr.row), Column: uint(cerr.column), Offset: uint(cerr.offset), Kind: QueryErrorKind(cerr.kind)}
	qerr.Message = errorContext(source, int(cerr.offset))
	return 0, qerr, status
}

// errorContext returns the text of a query at an error offset, up to the end of its line.
func errorContext(source string, offset int) string {
	if offset >= len(source) {
		return "unexpected end of the query"
	}
	rest := source[offset:]
	for i, c := range rest {
		if c == '\n' {
			return rest[:i]
		}
	}
	return rest
}

func newQuery(language *Language, blob []uint32, size int) *Query {
	q := &Query{language: language, blob: blob, blobLen: size}
	ptr := (*C.uint8_t)(unsafe.Pointer(&blob[0]))
	count := int(C.ztree_query_capture_count(ptr, C.size_t(size)))
	q.captureNames = make([]string, count)
	for i := range count {
		var length C.size_t
		name := C.ztree_query_capture_name(ptr, C.size_t(size), C.uint32_t(i), &length)
		q.captureNames[i] = C.GoStringN((*C.char)(unsafe.Pointer(name)), C.int(length))
	}
	q.patternCount = uint(C.ztree_query_pattern_count(ptr, C.size_t(size)))
	return q
}

// Language returns the grammar of the query.
func (q *Query) Language() *Language { return q.language }

// CaptureNames returns the name of each capture, by capture index.
func (q *Query) CaptureNames() []string { return q.captureNames }

// CaptureIndexForName returns the index of a capture.
func (q *Query) CaptureIndexForName(name string) (uint, bool) {
	for i, n := range q.captureNames {
		if n == name {
			return uint(i), true
		}
	}
	return 0, false
}

// PatternCount returns the number of patterns.
func (q *Query) PatternCount() uint { return q.patternCount }

// QueryCapture is one captured node.
type QueryCapture struct {
	Node  Node
	Index uint32
}

// QueryMatch is one match of a pattern.
type QueryMatch struct {
	PatternIndex uint
	Captures     []QueryCapture
}

// QueryCursor runs queries. It keeps size hints for its buffers, so one
// goroutine at a time can use a QueryCursor.
type QueryCursor struct {
	matchHint   int
	captureHint int
}

// NewQueryCursor returns a QueryCursor.
func NewQueryCursor() *QueryCursor { return &QueryCursor{} }

// QueryMatches iterates over the matches of one run.
type QueryMatches struct {
	matches []QueryMatch
	next    int
	err     error
}

// Next returns the next match, or nil at the end.
func (qm *QueryMatches) Next() *QueryMatch {
	if qm.next >= len(qm.matches) {
		return nil
	}
	m := &qm.matches[qm.next]
	qm.next++
	return m
}

// Err returns the error of the run, or nil. A run with an error gives no matches.
func (qm *QueryMatches) Err() error { return qm.err }

// Errors of QueryCursor.Matches.
var ErrLanguageMismatch = errors.New("ztree: the query and the tree have different grammars")

type matchRecord struct {
	patternIndex uint32
	captureCount uint32
}

type captureRecord struct {
	node  uint32
	index uint32
}

// Matches runs q over the subtree of node and returns its matches in the
// order of the Tree-sitter query cursor. text is the source of the tree.
// A match that fails a text predicate is not in the result.
func (qc *QueryCursor) Matches(q *Query, node *Node, text []byte) QueryMatches {
	t := node.tree
	if q.language != t.language {
		return QueryMatches{err: ErrLanguageMismatch}
	}
	matches := make([]matchRecord, max(qc.matchHint, 16))
	captures := make([]captureRecord, max(qc.captureHint, 32))
	for range 2 {
		mc, cc, status := execQuery(q, t, node.index, text, matches, captures)
		switch status {
		case C.ZTREE_OK:
			qc.matchHint, qc.captureHint = max(qc.matchHint, mc), max(qc.captureHint, cc)
			return QueryMatches{matches: buildMatches(t, matches[:mc], captures[:cc])}
		case C.ZTREE_ERROR_BUFFER_TOO_SMALL:
			matches = make([]matchRecord, max(mc, len(matches)))
			captures = make([]captureRecord, max(cc, len(captures)))
		default:
			return QueryMatches{err: statusError(status)}
		}
	}
	return QueryMatches{err: errors.New("ztree: the match count changed between two runs")}
}

func execQuery(q *Query, t *Tree, start uint32, text []byte, matches []matchRecord, captures []captureRecord) (int, int, C.int32_t) {
	var textPtr *C.uint8_t
	if len(text) > 0 {
		textPtr = (*C.uint8_t)(unsafe.Pointer(&text[0]))
	}
	var overridesPtr *C.ztree_field_override
	if len(t.rawOverrides) > 0 {
		overridesPtr = (*C.ztree_field_override)(unsafe.Pointer(&t.rawOverrides[0]))
	}
	var mc, cc C.size_t
	status := C.ztree_query_exec((*C.uint8_t)(unsafe.Pointer(&q.blob[0])), C.size_t(q.blobLen),
		(*C.ztree_node)(unsafe.Pointer(&t.nodes[0])), C.size_t(len(t.nodes)),
		overridesPtr, C.size_t(len(t.rawOverrides)), textPtr, C.size_t(len(text)), C.uint32_t(start),
		(*C.ztree_match)(unsafe.Pointer(&matches[0])), C.size_t(len(matches)), &mc,
		(*C.ztree_capture)(unsafe.Pointer(&captures[0])), C.size_t(len(captures)), &cc)
	return int(mc), int(cc), status
}

func buildMatches(t *Tree, matches []matchRecord, captures []captureRecord) []QueryMatch {
	out := make([]QueryMatch, len(matches))
	all := make([]QueryCapture, len(captures))
	for i, c := range captures {
		all[i] = QueryCapture{Node: Node{tree: t, index: c.node}, Index: c.index}
	}
	next := 0
	for i, m := range matches {
		out[i] = QueryMatch{PatternIndex: uint(m.patternIndex), Captures: all[next : next+int(m.captureCount) : next+int(m.captureCount)]}
		next += int(m.captureCount)
	}
	return out
}
