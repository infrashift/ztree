package ztree

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"testing"
)

// TestLibraryHash checks that libhash.go holds the SHA-256 of the library
// that cgo links. The Go build cache does not hash libztree.a, so a stale
// libhash.go lets Go link an old library (ISSUE-018).
func TestLibraryHash(t *testing.T) {
	lib, err := os.ReadFile("../../zig-out/lib/libztree.a")
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(lib)
	if got := hex.EncodeToString(sum[:]); got != LibraryHash() {
		t.Fatalf("libhash.go holds %s, but zig-out/lib/libztree.a has %s: run zig build lib", LibraryHash(), got)
	}
}
