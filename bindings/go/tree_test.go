package ztree

import (
	"errors"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"slices"
	"strings"
	"sync"
	"testing"
)

// parseString parses src with the grammar lang, or fails the test.
func parseString(t *testing.T, lang Lang, src string) *Tree {
	t.Helper()
	p := NewParser()
	if err := p.SetLanguage(NewLanguage(lang)); err != nil {
		t.Fatal(err)
	}
	tree, err := p.Parse([]byte(src))
	if err != nil {
		t.Fatal(err)
	}
	return tree
}

// kinds returns the kinds of the children of n.
func kinds(n *Node) []string {
	var out []string
	for i := range n.ChildCount() {
		out = append(out, n.Child(i).Kind())
	}
	return out
}

func TestNodeAPI(t *testing.T) {
	src := "package p\n\nfunc f(a int, b string) {}\n"
	tree := parseString(t, LangGo, src)
	root := tree.RootNode()
	if root.Kind() != "source_file" || root.Parent() != nil || root.HasError() {
		t.Fatalf("root = %s, parent %v, has error %v", root.Kind(), root.Parent(), root.HasError())
	}
	if got := kinds(root); !slices.Equal(got, []string{"package_clause", "function_declaration"}) {
		t.Fatalf("children of the root = %q", got)
	}
	fn := root.NamedChild(1)
	if fn.Kind() != "function_declaration" || !fn.IsNamed() || fn.IsExtra() || fn.IsMissing() || fn.IsError() {
		t.Fatalf("named child 1 = %s", fn.Kind())
	}
	if got := fn.Utf8Text([]byte(src)); got != "func f(a int, b string) {}" {
		t.Fatalf("text = %q", got)
	}
	if s, e := fn.StartPosition(), fn.EndPosition(); s != (Point{2, 0}) || e != (Point{2, 26}) {
		t.Fatalf("positions = %v %v", s, e)
	}
	if s, e := fn.ByteRange(); s != 11 || e != 37 {
		t.Fatalf("bytes = %d %d", s, e)
	}
	name := fn.ChildByFieldName("name")
	if name == nil || name.Utf8Text([]byte(src)) != "f" || !name.Parent().Equals(*fn) {
		t.Fatalf("name = %v", name)
	}
	if fn.ChildByFieldName("result") != nil || fn.ChildByFieldName("no_such_field") != nil {
		t.Fatal("a missing field gives a node")
	}
	params := fn.ChildByFieldName("parameters")
	if params.NamedChildCount() != 2 || params.ChildCount() != 5 {
		t.Fatalf("parameters: %d named of %d", params.NamedChildCount(), params.ChildCount())
	}
	second := params.NamedChild(1)
	if second.PrevNamedSibling() == nil || !second.PrevNamedSibling().Equals(*params.NamedChild(0)) {
		t.Fatal("PrevNamedSibling of the second parameter")
	}
	if second.PrevSibling().Kind() != "," || second.NextSibling().Kind() != ")" || second.NextNamedSibling() != nil {
		t.Fatal("siblings of the second parameter")
	}
	if params.NamedChild(0).PrevNamedSibling() != nil || params.Child(5) != nil || params.NamedChild(2) != nil {
		t.Fatal("an index out of range gives a node")
	}
	if !fn.Equals(*root.Child(1)) || fn.Equals(*root.Child(0)) {
		t.Fatal("Equals")
	}
	other := parseString(t, LangGo, src)
	if root.Equals(*other.RootNode()) {
		t.Fatal("nodes of two trees are equal")
	}
}

func TestToSexp(t *testing.T) {
	cases := []struct {
		lang Lang
		src  string
		want string
	}{
		{LangGo, "package p\n", "(source_file (package_clause (package_identifier)))"},
		{LangPython, "x = 1\n", "(module (expression_statement (assignment left: (identifier) right: (integer))))"},
		{LangC, "int x;\n", "(translation_unit (declaration type: (primitive_type) declarator: (identifier)))"},
		{LangRust, "fn f() {}\n", "(source_file (function_item name: (identifier) parameters: (parameters) body: (block)))"},
		{LangC, "int x = (1 + ;\n", "(translation_unit (ERROR type: (primitive_type) (identifier) (number_literal)) (expression_statement))"},
		{LangC, "#ifdef X\n", "(translation_unit (preproc_ifdef name: (identifier) (MISSING \"#endif\")))"},
	}
	for _, c := range cases {
		tree := parseString(t, c.lang, c.src)
		if got := tree.RootNode().ToSexp(); got != c.want {
			t.Errorf("%s %q:\n got  %s\n want %s", c.lang, c.src, got, c.want)
		}
	}
	tree := parseString(t, LangGo, "package p\nvar x = 1\n")
	if got := tree.RootNode().NamedChild(1).ToSexp(); !strings.HasPrefix(got, "(var_declaration (var_spec name: (identifier)") {
		t.Errorf("ToSexp of a subtree = %s", got)
	}
}

// TestCursor compares a cursor walk with a walk over Child.
func TestCursor(t *testing.T) {
	src, err := os.ReadFile("tree.go")
	if err != nil {
		t.Fatal(err)
	}
	tree := parseString(t, LangGo, string(src))
	var want []uint32
	stack := []*Node{tree.RootNode()}
	for len(stack) > 0 {
		n := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		want = append(want, n.index)
		for i := n.ChildCount(); i > 0; i-- {
			stack = append(stack, n.Child(i-1))
		}
	}
	if len(want) != len(tree.nodes) {
		t.Fatalf("the walk over Child visits %d of %d nodes", len(want), len(tree.nodes))
	}
	var got []uint32
	c := tree.Walk()
	maxDepth := uint32(0)
	for {
		got = append(got, c.Node().index)
		maxDepth = max(maxDepth, c.Depth())
		if c.GotoFirstChild() {
			continue
		}
		for !c.GotoNextSibling() {
			if !c.GotoParent() {
				goto done
			}
		}
	}
done:
	if !slices.Equal(got, want) || c.Depth() != 0 || maxDepth < 5 {
		t.Fatalf("the cursor visits %d nodes, want %d; depth %d", len(got), len(want), maxDepth)
	}
	// A cursor does not leave its start node.
	fn := tree.RootNode().NamedChild(0)
	for i := uint(1); fn.Kind() != "function_declaration"; i++ {
		fn = tree.RootNode().NamedChild(i)
	}
	c = fn.Walk()
	if c.GotoNextSibling() || c.GotoParent() || c.FieldName() != "" {
		t.Fatal("the cursor left its start node")
	}
	if !c.GotoFirstChild() {
		t.Fatal("GotoFirstChild")
	}
	for c.FieldName() != "name" {
		if !c.GotoNextSibling() {
			t.Fatal("no child in the field name")
		}
	}
	c.Reset(*tree.RootNode())
	if !c.Node().Equals(*tree.RootNode()) || c.Depth() != 0 {
		t.Fatal("Reset")
	}
}

// TestReferenceRules checks the rules of the reference runtime that the
// first-child rule and the cursor order do not give (ADR-0009).
func TestReferenceRules(t *testing.T) {
	// An inherited field of an old-style definition names a grandchild.
	src := "int add(a) int a; { return a; }\n"
	fn := parseString(t, LangC, src).RootNode().NamedChild(0)
	params := fn.ChildByFieldName("parameters")
	if fn.Kind() != "function_definition" || params == nil || params.Kind() != "parameter_list" || params.Parent().Kind() != "function_declarator" {
		t.Fatalf("parameters of %s = %v", fn.Kind(), params)
	}
	// An ERROR node has no fields. Its first child is in the field type of
	// a hidden node, so the cursor gives the field name.
	errNode := parseString(t, LangC, "int x = (1 + ;\n").RootNode().NamedChild(0)
	if !errNode.IsError() || !errNode.HasError() || errNode.ChildByFieldName("type") != nil {
		t.Fatalf("ERROR node %s gives a field child", errNode.Kind())
	}
	if c := errNode.Walk(); !c.GotoFirstChild() || c.FieldName() != "type" {
		t.Fatal("the cursor gives no field in the ERROR node")
	}
	// NextSibling skips an empty sibling at the end of the node.
	ifdef := parseString(t, LangC, "#ifdef X\n").RootNode().NamedChild(0)
	name := ifdef.ChildByFieldName("name")
	last := ifdef.Child(ifdef.ChildCount() - 1)
	if !last.IsMissing() || name.NextSibling() != nil || !last.PrevSibling().Equals(*name) {
		t.Fatalf("children of %s: %q", ifdef.Kind(), kinds(ifdef))
	}
	c := name.Walk()
	c.Reset(*ifdef)
	c.GotoFirstChild()
	c.GotoNextSibling()
	if !c.GotoNextSibling() || !c.Node().IsMissing() {
		t.Fatal("the cursor does not visit the MISSING node")
	}
}

func TestLanguage(t *testing.T) {
	for lang := LangGo; lang <= LangCPP; lang++ {
		l := NewLanguage(lang)
		if l == nil || l != NewLanguage(lang) || l.Lang() != lang {
			t.Fatalf("NewLanguage(%s)", lang)
		}
		if v := l.AbiVersion(); v != 14 && v != 15 {
			t.Fatalf("%s: ABI version %d", lang, v)
		}
		if l.NodeKindForId(0) != "end" || l.NodeKindForId(0xffff) != "ERROR" || l.NodeKindForId(uint16(l.NodeKindCount())) != "" {
			t.Fatalf("%s: NodeKindForId", lang)
		}
		if !l.NodeKindIsNamed(0xffff) || !l.NodeKindIsVisible(0xffff) || l.NodeKindIsVisible(0) {
			t.Fatalf("%s: symbol flags", lang)
		}
		id := l.FieldIdForName("name")
		if id == 0 || l.FieldNameForId(id) != "name" || l.FieldNameForId(0) != "" || l.FieldIdForName("no_such_field") != 0 {
			t.Fatalf("%s: fields", lang)
		}
		if l.FieldNameForId(uint16(l.FieldCount())) == "" || l.FieldNameForId(uint16(l.FieldCount()+1)) != "" {
			t.Fatalf("%s: FieldCount", lang)
		}
	}
	if NewLanguage(Lang(99)) != nil {
		t.Fatal("NewLanguage(99) is not nil")
	}
}

func TestParserErrors(t *testing.T) {
	p := NewParser()
	if _, err := p.Parse([]byte("x")); !errors.Is(err, ErrNoLanguage) {
		t.Fatalf("Parse with no language: %v", err)
	}
	if err := p.SetLanguage(nil); !errors.Is(err, ErrInvalidArgument) {
		t.Fatalf("SetLanguage(nil): %v", err)
	}
	if err := p.SetLanguage(NewLanguage(LangGo)); err != nil || p.Language() != NewLanguage(LangGo) {
		t.Fatal("SetLanguage")
	}
	if _, err := p.Parse(make([]byte, MaxSourceBytes+1)); !errors.Is(err, ErrSourceTooLarge) {
		t.Fatalf("large source: %v", err)
	}
	tree, err := p.Parse(nil)
	if err != nil || tree.RootNode().ChildCount() != 0 || tree.Language() != p.Language() {
		t.Fatalf("empty source: %v", err)
	}
}

// TestNodeBufferGrows parses a source with more nodes than the first guess.
func TestNodeBufferGrows(t *testing.T) {
	src := "x = [" + strings.Repeat("1,", 5000) + "]\n"
	p := NewParser()
	if err := p.SetLanguage(NewLanguage(LangPython)); err != nil {
		t.Fatal(err)
	}
	for range 2 {
		tree, err := p.Parse([]byte(src))
		if err != nil {
			t.Fatal(err)
		}
		list := tree.RootNode().NamedChild(0).NamedChild(0).ChildByFieldName("right")
		if list.Kind() != "list" || list.NamedChildCount() != 5000 || list.ChildCount() != 10002 {
			t.Fatalf("list: %s with %d named children", list.Kind(), list.NamedChildCount())
		}
	}
	if p.hint < 10000 {
		t.Fatalf("the size hint is %d", p.hint)
	}
}

// TestGoFilesMatchGoAST compares the functions and methods of real Go files
// with go/ast: the count, the names and the positions.
func TestGoFilesMatchGoAST(t *testing.T) {
	p := NewParser()
	if err := p.SetLanguage(NewLanguage(LangGo)); err != nil {
		t.Fatal(err)
	}
	total, skipped := 0, 0
	for _, path := range goFiles(t) {
		src, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		fset := token.NewFileSet()
		file, err := parser.ParseFile(fset, path, src, parser.SkipObjectResolution)
		if err != nil {
			continue // go/parser gives no oracle.
		}
		tree, err := p.Parse(src)
		if err != nil {
			t.Fatal(err)
		}
		if tree.RootNode().HasError() {
			skipped++ // The pinned Go grammar does not read each new form of Go.
			continue
		}
		var want []string
		for _, d := range file.Decls {
			if fd, ok := d.(*ast.FuncDecl); ok {
				pos := fset.Position(fd.Pos())
				want = append(want, fd.Name.Name+"@"+itoa(pos.Line-1))
			}
		}
		var got []string
		root := tree.RootNode()
		for i := range root.NamedChildCount() {
			n := root.NamedChild(i)
			if n.Kind() == "function_declaration" || n.Kind() == "method_declaration" {
				got = append(got, n.ChildByFieldName("name").Utf8Text(src)+"@"+itoa(int(n.StartPosition().Row)))
			}
		}
		if !slices.Equal(got, want) {
			t.Fatalf("%s: ztree finds %d functions, go/ast finds %d", path, len(got), len(want))
		}
		total += len(want)
	}
	if total < 5000 || skipped > 20 {
		t.Fatalf("compared %d functions, want at least 5000; skipped %d files with syntax errors", total, skipped)
	}
	t.Logf("%d functions match go/ast; %d files with syntax errors skipped", total, skipped)
}

func itoa(v int) string { return strconvItoa(v) }

// TestConcurrentTrees parses from several goroutines, each with its own
// parser, and reads one tree from all of them.
func TestConcurrentTrees(t *testing.T) {
	files := goFiles(t)[:20]
	srcs := make([][]byte, len(files))
	want := make([]string, len(files))
	for i, path := range files {
		src, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		srcs[i] = src
		want[i] = parseString(t, LangGo, string(src)).RootNode().ToSexp()
	}
	shared := parseString(t, LangGo, string(srcs[0]))
	var wg sync.WaitGroup
	errs := make(chan error, 8)
	for range 8 {
		wg.Go(func() {
			p := NewParser()
			if err := p.SetLanguage(NewLanguage(LangGo)); err != nil {
				errs <- err
				return
			}
			for i, src := range srcs {
				tree, err := p.Parse(src)
				if err != nil || tree.RootNode().ToSexp() != want[i] || shared.RootNode().ToSexp() != want[0] {
					errs <- errors.New(files[i] + ": result differs between goroutines")
					return
				}
			}
		})
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		t.Fatal(err)
	}
}
