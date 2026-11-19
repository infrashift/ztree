package ztree

import (
	"errors"
	"os"
	"slices"
	"sync"
	"testing"
)

// matchTexts runs query over src and returns the text of each capture
// named name, in match order.
func matchTexts(t *testing.T, lang Lang, query, src, name string) []string {
	t.Helper()
	q, qerr := NewQuery(NewLanguage(lang), query)
	if qerr != nil {
		t.Fatalf("NewQuery(%q): %v", query, qerr)
	}
	idx, ok := q.CaptureIndexForName(name)
	if !ok {
		t.Fatalf("no capture @%s", name)
	}
	tree := parseString(t, lang, src)
	matches := NewQueryCursor().Matches(q, tree.RootNode(), []byte(src))
	if err := matches.Err(); err != nil {
		t.Fatal(err)
	}
	var out []string
	for m := matches.Next(); m != nil; m = matches.Next() {
		for _, c := range m.Captures {
			if uint(c.Index) == idx {
				out = append(out, c.Node.Utf8Text([]byte(src)))
			}
		}
	}
	return out
}

// TestSemscopeRules runs the ast_query rules of the semscope rule set
// NASA-P10-10 on sample code.
func TestSemscopeRules(t *testing.T) {
	cases := []struct {
		lang  Lang
		query string
		src   string
		want  []string
	}{
		{LangGo, `(import_spec path: (interpreted_string_literal) @violation (#eq? @violation "\"unsafe\""))
((comment) @violation (#match? @violation "^//\\s*nolint(:[A-Za-z0-9_,-]+)?\\s*$"))`,
			"package p\n\nimport (\n\t\"fmt\"\n\t\"unsafe\"\n)\n\n//nolint\nvar x = 1 // nolint:errcheck,gosec\n// nolint: not a directive\n",
			[]string{`"unsafe"`, "//nolint", "// nolint:errcheck,gosec"}},
		{LangC, `(call_expression function: (identifier) @violation (#any-of? @violation "gets" "strcpy" "strcat" "sprintf" "vsprintf"))
((comment) @violation (#match? @violation "NOLINT(\\([^)]*\\))?\\s*(\\*/)?$"))`,
			"void f(char *a, char *b) {\n  strcpy(a, b); // NOLINT(cert-err)\n  strncpy(a, b, 1);\n  gets(a); /* NOLINT */\n}\n",
			[]string{"strcpy", "// NOLINT(cert-err)", "gets", "/* NOLINT */"}},
		{LangCPP, `(call_expression function: (identifier) @violation (#any-of? @violation "gets" "strcpy" "strcat" "sprintf" "vsprintf"))`,
			"int main() { char a[4]; sprintf(a, \"%d\", 1); std::printf(\"x\"); return 0; }\n",
			[]string{"sprintf"}},
		{LangZig, `((builtin_identifier) @violation (#any-of? @violation "@ptrFromInt" "@intFromPtr" "@ptrCast" "@alignCast"))`,
			"fn f(p: *u8) usize {\n    const q: *u16 = @ptrCast(@alignCast(p));\n    return @intFromPtr(q) + @sizeOf(u8);\n}\n",
			[]string{"@ptrCast", "@alignCast", "@intFromPtr"}},
		{LangPython, `(import_statement name: (dotted_name) @violation (#eq? @violation "ctypes"))
((comment) @violation (#match? @violation "#\\s*(noqa|type:\\s*ignore)\\s*$"))`,
			"import ctypes\nimport os\nx = 1  # noqa\ny = 2  # type: ignore\nz = 3  # noqa: E501\n",
			[]string{"ctypes", "# noqa", "# type: ignore"}},
		{LangRust, `(unsafe_block) @violation`,
			"fn f() { let x = 1; unsafe { g(); } }\n",
			[]string{"unsafe { g(); }"}},
	}
	for _, c := range cases {
		if got := matchTexts(t, c.lang, c.query, c.src, "violation"); !slices.Equal(got, c.want) {
			t.Errorf("%s: violations = %q, want %q", c.lang, got, c.want)
		}
	}
}

func TestTextPredicates(t *testing.T) {
	src := "package p\nfunc f() { a := a; b := c; d := d; e(x, y, x) }\n"
	cases := []struct {
		query string
		want  []string
	}{
		{`((identifier) @id (#eq? @id "a"))`, []string{"a", "a"}},
		{`((identifier) @id (#not-eq? @id "a") (#not-eq? @id "x"))`, []string{"f", "b", "c", "d", "d", "e", "y"}},
		{`(short_var_declaration left: (expression_list (identifier) @l) right: (expression_list (identifier) @r) (#eq? @l @r))`, []string{"a", "d"}},
		{`(short_var_declaration left: (expression_list (identifier) @l) right: (expression_list (identifier) @r) (#not-eq? @l @r))`, []string{"b"}},
		{`((identifier) @id (#any-of? @id "b" "c" "zz"))`, []string{"b", "c"}},
		{`((identifier) @id (#not-any-of? @id "a" "b" "c" "d" "x" "y"))`, []string{"f", "e"}},
		{`((identifier) @id (#match? @id "^[a-c]$"))`, []string{"a", "a", "b", "c"}},
		{`((identifier) @id (#not-match? @id "[a-e]"))`, []string{"f", "x", "y", "x"}},
		// The query cursor gives three matches here: [x], [y] and [x]. The
		// any- forms of go-tree-sitter pass when no node of the capture is a
		// hit, so each match passes them.
		{`(argument_list (identifier)+ @arg (#any-eq? @arg "y"))`, []string{"x", "y", "x"}},
		{`(argument_list (identifier)+ @arg (#eq? @arg "x"))`, []string{"x", "x"}},
		{`(argument_list (identifier)+ @arg (#any-match? @arg "^y"))`, []string{"x", "y", "x"}},
		{`(argument_list (identifier)+ @arg (#any-not-eq? @arg "x"))`, []string{"x", "y", "x"}},
	}
	for _, c := range cases {
		name := "id"
		if c.query[1] == 's' {
			name = "l"
		} else if c.query[1] == 'a' {
			name = "arg"
		}
		if got := matchTexts(t, LangGo, c.query, src, name); !slices.Equal(got, c.want) {
			t.Errorf("%s: captures = %q, want %q", c.query, got, c.want)
		}
	}
}

func TestQueryErrors(t *testing.T) {
	cases := []struct {
		query  string
		kind   QueryErrorKind
		row    uint
		column uint
	}{
		{"(identifier", QueryErrorSyntax, 0, 11},
		{"(identifier) @a\n  (no_such_node)", QueryErrorNodeType, 1, 3},
		{"(function_declaration bad_field: (identifier))", QueryErrorField, 0, 22},
		{"((identifier) @a (#eq? @b \"x\"))", QueryErrorCapture, 0, 24},
		{"(identifier (identifier))", QueryErrorStructure, 0, 12},
		{"((identifier) @a (#nope? @a))", QueryErrorPredicate, 0, 17},
		{"((identifier) @a (#eq? @a))", QueryErrorPredicate, 0, 17},
		{"((identifier) @a (#match? @a \"(\"))", QueryErrorPredicate, 0, 17},
		{"((identifier) @a (#set! key value))", QueryErrorUnsupported, 0, 17},
		{"((identifier) @a (#strip! @a \"x\"))", QueryErrorUnsupported, 0, 17},
		{"((identifier) @a (#set-adjacent! @a @a))", QueryErrorUnsupported, 0, 17},
		{"((identifier) @a (#match? @a \"\\\\pL\"))", QueryErrorUnsupported, 0, 17},
	}
	for _, c := range cases {
		_, qerr := NewQuery(NewLanguage(LangGo), c.query)
		if qerr == nil || qerr.Kind != c.kind || qerr.Row != c.row || qerr.Column != c.column {
			t.Errorf("NewQuery(%q) = %+v, want kind %s at %d:%d", c.query, qerr, c.kind, c.row, c.column)
			continue
		}
		if qerr.Error() == "" || qerr.Message == "" {
			t.Errorf("NewQuery(%q): empty message", c.query)
		}
	}
	if _, qerr := NewQuery(NewLanguage(LangPython), "(expression) @e"); qerr == nil || qerr.Kind != QueryErrorUnsupported {
		t.Errorf("a supertype gives %v, want an unsupported error", qerr)
	}
	if _, qerr := NewQuery(nil, "(x)"); qerr == nil || qerr.Kind != QueryErrorLanguage {
		t.Errorf("NewQuery(nil) = %v", qerr)
	}
}

func TestQueryAPI(t *testing.T) {
	q, qerr := NewQuery(NewLanguage(LangGo), "(function_declaration name: (identifier) @name) @fn\n(call_expression) @call")
	if qerr != nil {
		t.Fatal(qerr)
	}
	if q.PatternCount() != 2 || !slices.Equal(q.CaptureNames(), []string{"name", "fn", "call"}) || q.Language() != NewLanguage(LangGo) {
		t.Fatalf("pattern count %d, captures %q", q.PatternCount(), q.CaptureNames())
	}
	if _, ok := q.CaptureIndexForName("nope"); ok {
		t.Fatal("CaptureIndexForName(nope)")
	}
	src := "package p\nfunc f() { g() }\nfunc h() {}\n"
	tree := parseString(t, LangGo, src)
	ms := NewQueryCursor().Matches(q, tree.RootNode(), []byte(src))
	var patterns []uint
	for m := ms.Next(); m != nil; m = ms.Next() {
		patterns = append(patterns, m.PatternIndex)
	}
	if !slices.Equal(patterns, []uint{0, 1, 0}) {
		t.Fatalf("pattern order = %v", patterns)
	}
	// A run from a node sees only its subtree.
	second := tree.RootNode().NamedChild(2)
	ms = NewQueryCursor().Matches(q, second, []byte(src))
	// The captures follow the steps: @fn, then @name.
	if m := ms.Next(); m == nil || m.PatternIndex != 0 || m.Captures[1].Node.Utf8Text([]byte(src)) != "h" || ms.Next() != nil {
		t.Fatal("a run from the second function")
	}
	other := parseString(t, LangC, "int x;")
	if ms := NewQueryCursor().Matches(q, other.RootNode(), nil); !errors.Is(ms.Err(), ErrLanguageMismatch) || ms.Next() != nil {
		t.Fatal("a tree of another grammar")
	}
}

// TestQueryConcurrency shares one Query and one Tree between goroutines,
// each with its own QueryCursor.
func TestQueryConcurrency(t *testing.T) {
	q, qerr := NewQuery(NewLanguage(LangGo), "((identifier) @id (#match? @id \"^[a-m]\"))")
	if qerr != nil {
		t.Fatal(qerr)
	}
	files := goFiles(t)[:10]
	var wg sync.WaitGroup
	errs := make(chan error, 8)
	for range 8 {
		wg.Go(func() {
			p := NewParser()
			if err := p.SetLanguage(NewLanguage(LangGo)); err != nil {
				errs <- err
				return
			}
			c := NewQueryCursor()
			for _, path := range files {
				src := readFile(t, path)
				tree, err := p.Parse(src)
				if err != nil {
					errs <- err
					return
				}
				ms := c.Matches(q, tree.RootNode(), src)
				n := 0
				for m := ms.Next(); m != nil; m = ms.Next() {
					n++
				}
				if ms.Err() != nil || n == 0 {
					errs <- errors.New(path + ": no matches")
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

func readFile(t testing.TB, path string) []byte {
	src, err := os.ReadFile(path)
	if err != nil {
		t.Error(err)
	}
	return src
}
