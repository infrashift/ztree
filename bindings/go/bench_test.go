package ztree

import "testing"

// The benchmarks measure the three steps of a semscope scan on the Go files
// of goFiles: a parse, a walk of each node with a TreeCursor, and a query
// with text predicates. Each benchmark reports the source bytes per second.
// Run them with: go test -run '^$' -bench . -benchmem

// benchQuery has the shape of the ast_query rules of semscope.
const benchQuery = `(call_expression function: (identifier) @violation (#any-of? @violation "panic" "recover" "print"))
((comment) @violation (#match? @violation "^//\\s*nolint"))
(import_spec path: (interpreted_string_literal) @violation (#eq? @violation "\"unsafe\""))`

type benchInput struct {
	sources [][]byte
	trees   []*Tree
	bytes   int64
}

func loadBench(b *testing.B) benchInput {
	b.Helper()
	files := goFiles(b)
	in := benchInput{sources: make([][]byte, 0, len(files))}
	p := NewParser()
	if err := p.SetLanguage(NewLanguage(LangGo)); err != nil {
		b.Fatal(err)
	}
	for _, path := range files {
		src := readFile(b, path)
		tree, err := p.Parse(src)
		if err != nil {
			b.Fatalf("%s: %v", path, err)
		}
		in.sources = append(in.sources, src)
		in.trees = append(in.trees, tree)
		in.bytes += int64(len(src))
	}
	return in
}

func BenchmarkParse(b *testing.B) {
	in := loadBench(b)
	p := NewParser()
	if err := p.SetLanguage(NewLanguage(LangGo)); err != nil {
		b.Fatal(err)
	}
	b.SetBytes(in.bytes)
	b.ResetTimer()
	for b.Loop() {
		for _, src := range in.sources {
			if _, err := p.Parse(src); err != nil {
				b.Fatal(err)
			}
		}
	}
}

// walkCount visits each node in pre-order, as the walker of semscope does.
func walkCount(t *Tree) int {
	c := t.Walk()
	n := 0
	for {
		n++
		if c.Node().Kind() == "" {
			return -1
		}
		if c.GotoFirstChild() {
			continue
		}
		for !c.GotoNextSibling() {
			if !c.GotoParent() {
				return n
			}
		}
	}
}

func BenchmarkWalk(b *testing.B) {
	in := loadBench(b)
	b.SetBytes(in.bytes)
	b.ResetTimer()
	nodes := 0
	for b.Loop() {
		nodes = 0
		for _, t := range in.trees {
			n := walkCount(t)
			if n <= 0 {
				b.Fatal("a walk with no nodes")
			}
			nodes += n
		}
	}
	b.ReportMetric(float64(nodes), "nodes/op")
}

func BenchmarkQuery(b *testing.B) {
	in := loadBench(b)
	q, qerr := NewQuery(NewLanguage(LangGo), benchQuery)
	if qerr != nil {
		b.Fatal(qerr)
	}
	c := NewQueryCursor()
	b.SetBytes(in.bytes)
	b.ResetTimer()
	total := 0
	for b.Loop() {
		total = 0
		for i, t := range in.trees {
			ms := c.Matches(q, t.RootNode(), in.sources[i])
			for m := ms.Next(); m != nil; m = ms.Next() {
				total += len(m.Captures)
			}
			if ms.Err() != nil {
				b.Fatal(ms.Err())
			}
		}
	}
	if total == 0 {
		b.Fatal("the query gives no captures")
	}
	b.ReportMetric(float64(total), "captures/op")
}
