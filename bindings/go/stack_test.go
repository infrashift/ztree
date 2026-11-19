package ztree

import (
	"debug/elf"
	"os"
	"testing"
)

// TestStackNotExecutable checks that the test program, which links
// libztree.a, has a stack that is not executable. GNU ld makes the stack
// executable when one object has no .note.GNU-stack section (ISSUE-019).
func TestStackNotExecutable(t *testing.T) {
	path, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	f, err := elf.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	for _, p := range f.Progs {
		if p.Type == elf.PT_GNU_STACK {
			if p.Flags&elf.PF_X != 0 {
				t.Fatalf("the stack is executable (%v): an object of libztree.a has no .note.GNU-stack section", p.Flags)
			}
			return
		}
	}
	t.Fatal("the program has no PT_GNU_STACK header")
}
