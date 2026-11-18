// Package ztree extracts the comments of Go, Zig, Python, C, C++ and Rust source
// with ztree, a Tree-sitter runtime in Zig. It calls the C ABI of
// libztree.a (include/ztree.h of the ztree repository).
//
// Build the library before the package: run `zig build lib --release` in
// the ztree root. The cgo flags read zig-out/include and zig-out/lib there.
package ztree

/*
#cgo CFLAGS: -I${SRCDIR}/../../zig-out/include
#cgo LDFLAGS: -L${SRCDIR}/../../zig-out/lib -lztree
#include <ztree.h>
*/
import "C"

import (
	"errors"
	"fmt"
	"unsafe"
)

// Lang selects a grammar.
type Lang uint32

// The grammars of libztree.a.
const (
	LangGo     Lang = C.ZTREE_LANG_GO
	LangZig    Lang = C.ZTREE_LANG_ZIG
	LangPython Lang = C.ZTREE_LANG_PYTHON
	LangC      Lang = C.ZTREE_LANG_C
	LangRust   Lang = C.ZTREE_LANG_RUST
	LangCPP    Lang = C.ZTREE_LANG_CPP
)

// String returns the name of the grammar.
func (l Lang) String() string {
	switch l {
	case LangGo:
		return "go"
	case LangZig:
		return "zig"
	case LangPython:
		return "python"
	case LangC:
		return "c"
	case LangRust:
		return "rust"
	case LangCPP:
		return "cpp"
	}
	return fmt.Sprintf("Lang(%d)", uint32(l))
}

// MaxSourceBytes is the largest source that ExtractComments accepts.
const MaxSourceBytes = C.ZTREE_MAX_SOURCE_BYTES

// Span is the position of one comment. Bytes are offsets into the source.
// Rows start at 0. A column counts bytes from the start of its row. The end
// is exclusive.
type Span struct {
	StartByte   uint32
	EndByte     uint32
	StartRow    uint32
	StartColumn uint32
	EndRow      uint32
	EndColumn   uint32
}

// Span and C.ztree_span have the same layout, so C writes into a []Span.
// Each array length is negative, and the build fails, when the layouts differ.
var (
	_ [unsafe.Sizeof(Span{}) - unsafe.Sizeof(C.ztree_span{})]struct{}
	_ [unsafe.Sizeof(C.ztree_span{}) - unsafe.Sizeof(Span{})]struct{}
	_ [unsafe.Offsetof(Span{}.EndColumn) - unsafe.Offsetof(C.ztree_span{}.end_column)]struct{}
	_ [unsafe.Offsetof(C.ztree_span{}.end_column) - unsafe.Offsetof(Span{}.EndColumn)]struct{}
)

// Errors of ExtractComments.
var (
	ErrInvalidArgument    = errors.New("ztree: invalid argument")
	ErrSourceTooLarge     = errors.New("ztree: source too large")
	ErrOutOfMemory        = errors.New("ztree: out of memory")
	ErrLimitReached       = errors.New("ztree: parser limit reached")
	ErrUnsupportedGrammar = errors.New("ztree: unsupported grammar")
	ErrABIMismatch        = errors.New("ztree: libztree.a and ztree.h have different ABI versions")
)

func statusError(status C.int32_t) error {
	switch status {
	case C.ZTREE_ERROR_INVALID_ARGUMENT:
		return ErrInvalidArgument
	case C.ZTREE_ERROR_SOURCE_TOO_LARGE:
		return ErrSourceTooLarge
	case C.ZTREE_ERROR_OUT_OF_MEMORY:
		return ErrOutOfMemory
	case C.ZTREE_ERROR_LIMIT_REACHED:
		return ErrLimitReached
	case C.ZTREE_ERROR_UNSUPPORTED_GRAMMAR:
		return ErrUnsupportedGrammar
	}
	return fmt.Errorf("ztree: unknown status %d", int32(status))
}

// ABIVersion returns the ABI version of the linked libztree.a.
func ABIVersion() uint32 {
	return uint32(C.ztree_abi_version())
}

// ExtractComments parses src with the grammar lang and returns the spans of
// its comments in source order. A source with syntax errors still gives its
// comments. Two goroutines can call ExtractComments at the same time.
func ExtractComments(lang Lang, src []byte) ([]Span, error) {
	if ABIVersion() != C.ZTREE_ABI_VERSION {
		return nil, ErrABIMismatch
	}
	// A guess that fits most sources. A larger count costs a second parse.
	spans := make([]Span, len(src)/32+16)
	for range 2 {
		count, status := extract(lang, src, spans)
		switch status {
		case C.ZTREE_OK:
			return spans[:count], nil
		case C.ZTREE_ERROR_BUFFER_TOO_SMALL:
			spans = make([]Span, count)
		default:
			return nil, statusError(status)
		}
	}
	return nil, errors.New("ztree: the comment count changed between two parses")
}

func extract(lang Lang, src []byte, spans []Span) (int, C.int32_t) {
	var srcPtr *C.uint8_t
	if len(src) > 0 {
		srcPtr = (*C.uint8_t)(unsafe.Pointer(&src[0]))
	}
	var spansPtr *C.ztree_span
	if len(spans) > 0 {
		spansPtr = (*C.ztree_span)(unsafe.Pointer(&spans[0]))
	}
	var count C.size_t
	status := C.ztree_extract_comments(C.uint32_t(lang), srcPtr, C.size_t(len(src)), spansPtr, C.size_t(len(spans)), &count)
	return int(count), status
}
