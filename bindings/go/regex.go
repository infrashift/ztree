package ztree

/*
#include <ztree.h>
*/
import "C"

import (
	"errors"
	"unsafe"
)

// Errors of a regex pattern of a #match? predicate (ADR-0010).
var (
	ErrRegexSyntax      = errors.New("ztree: regex syntax error")
	ErrRegexUnsupported = errors.New("ztree: regex syntax that ztree does not support")
)

// regexMatch reports whether pattern matches somewhere in text, as
// regexp.Match does. On a pattern error it returns the byte offset of the
// error. The tests compare it with the regexp package.
func regexMatch(pattern string, text []byte) (bool, int, error) {
	var patternPtr, textPtr *C.uint8_t
	if len(pattern) > 0 {
		patternPtr = (*C.uint8_t)(unsafe.Pointer(unsafe.StringData(pattern)))
	}
	if len(text) > 0 {
		textPtr = (*C.uint8_t)(unsafe.Pointer(&text[0]))
	}
	var matched C.int32_t
	var offset C.size_t
	status := C.ztree_regex_match(patternPtr, C.size_t(len(pattern)), textPtr, C.size_t(len(text)), &matched, &offset)
	switch status {
	case C.ZTREE_OK:
		return matched != 0, 0, nil
	case C.ZTREE_ERROR_REGEX_SYNTAX:
		return false, int(offset), ErrRegexSyntax
	case C.ZTREE_ERROR_REGEX_UNSUPPORTED:
		return false, int(offset), ErrRegexUnsupported
	}
	return false, 0, statusError(status)
}
