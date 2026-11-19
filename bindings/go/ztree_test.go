package ztree

import (
	"errors"
	"go/build"
	"go/parser"
	"go/token"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
)

func TestABIVersion(t *testing.T) {
	if got := ABIVersion(); got != 6 {
		t.Fatalf("ABIVersion() = %d, want 6", got)
	}
}

func TestEachGrammar(t *testing.T) {
	cases := []struct {
		lang Lang
		src  string
		want []string
	}{
		{LangGo, "package p\n// a\nvar x = 1 /* b */\n", []string{"// a", "/* b */"}},
		{LangZig, "// a\n/// b\nconst S = struct {};\n", []string{"// a", "/// b"}},
		{LangPython, "# a\nx = 1  # b\ns = '# no'\n", []string{"# a", "# b"}},
		{LangC, "/* a */ int x; // b\n", []string{"/* a */", "// b"}},
		{LangRust, "// a\n/// b\nfn f() {} /* c */\n", []string{"// a", "/// b\n", "/* c */"}},
		{LangCPP, "/* a */ auto s = R\"d(// no)d\"; // b\n", []string{"/* a */", "// b"}},
	}
	for _, c := range cases {
		t.Run(c.lang.String(), func(t *testing.T) {
			spans, err := ExtractComments(c.lang, []byte(c.src))
			if err != nil {
				t.Fatal(err)
			}
			if got := texts(c.src, spans); !slices.Equal(got, c.want) {
				t.Fatalf("comments = %q, want %q", got, c.want)
			}
		})
	}
}

func TestPoints(t *testing.T) {
	spans, err := ExtractComments(LangGo, []byte("package p\n\nvar x = 1 // tail\n"))
	if err != nil {
		t.Fatal(err)
	}
	want := Span{StartByte: 21, EndByte: 28, StartRow: 2, StartColumn: 10, EndRow: 2, EndColumn: 17}
	if len(spans) != 1 || spans[0] != want {
		t.Fatalf("spans = %+v, want [%+v]", spans, want)
	}
}

func TestBufferGrows(t *testing.T) {
	// 200 comments in 600 bytes: more than the first guess of the buffer.
	src := "package p\n" + strings.Repeat("//\n", 200)
	spans, err := ExtractComments(LangGo, []byte(src))
	if err != nil {
		t.Fatal(err)
	}
	if len(spans) != 200 {
		t.Fatalf("len(spans) = %d, want 200", len(spans))
	}
	if last := spans[199]; last.StartRow != 200 || last.EndByte != uint32(len(src)-1) {
		t.Fatalf("last span = %+v", last)
	}
}

func TestEmptySource(t *testing.T) {
	spans, err := ExtractComments(LangPython, nil)
	if err != nil || len(spans) != 0 {
		t.Fatalf("ExtractComments(nil) = %v, %v; want no spans and no error", spans, err)
	}
}

func TestSyntaxErrors(t *testing.T) {
	src := "package p\n// a\nfunc f( {\n// b\n"
	spans, err := ExtractComments(LangGo, []byte(src))
	if err != nil {
		t.Fatal(err)
	}
	if got := texts(src, spans); !slices.Equal(got, []string{"// a", "// b"}) {
		t.Fatalf("comments = %q", got)
	}
}

func TestErrors(t *testing.T) {
	if _, err := ExtractComments(Lang(99), []byte("x")); !errors.Is(err, ErrInvalidArgument) {
		t.Fatalf("unknown grammar: err = %v, want ErrInvalidArgument", err)
	}
	big := make([]byte, MaxSourceBytes+1)
	if _, err := ExtractComments(LangGo, big); !errors.Is(err, ErrSourceTooLarge) {
		t.Fatalf("large source: err = %v, want ErrSourceTooLarge", err)
	}
}

// goFiles returns the Go files of some GOROOT packages, without testdata.
func goFiles(t *testing.T) []string {
	t.Helper()
	var files []string
	for _, dir := range []string{"go", "fmt", "strings", "encoding/json", "net/http"} {
		root := filepath.Join(build.Default.GOROOT, "src", dir)
		err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if d.IsDir() && d.Name() == "testdata" {
				return filepath.SkipDir
			}
			if !d.IsDir() && strings.HasSuffix(path, ".go") {
				files = append(files, path)
			}
			return nil
		})
		if err != nil {
			t.Fatal(err)
		}
	}
	if len(files) < 100 {
		t.Fatalf("found %d Go files in GOROOT, want at least 100", len(files))
	}
	return files
}

// TestGoFilesMatchGoParser compares the comments of real Go files with the
// comments of go/parser, an implementation that does not share code with ztree.
func TestGoFilesMatchGoParser(t *testing.T) {
	total := 0
	for _, path := range goFiles(t) {
		src, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		fset := token.NewFileSet()
		file, err := parser.ParseFile(fset, path, src, parser.ParseComments)
		if err != nil {
			continue // ztree handles the file, but go/parser gives no oracle.
		}
		var want []string
		for _, group := range file.Comments {
			for _, c := range group.List {
				start := fset.Position(c.Pos()).Offset
				want = append(want, string(src[start:fset.Position(c.End()).Offset]))
			}
		}
		spans, err := ExtractComments(LangGo, src)
		if err != nil {
			t.Fatalf("%s: %v", path, err)
		}
		if got := texts(string(src), spans); !slices.Equal(got, want) {
			t.Fatalf("%s: ztree finds %d comments, go/parser finds %d", path, len(got), len(want))
		}
		total += len(want)
	}
	if total < 10000 {
		t.Fatalf("compared %d comments, want at least 10000", total)
	}
	t.Logf("%d comments match go/parser", total)
}

// TestConcurrentCalls runs ExtractComments from several goroutines and
// compares each result with the result of one goroutine.
func TestConcurrentCalls(t *testing.T) {
	files := goFiles(t)[:40]
	want := make([][]Span, len(files))
	srcs := make([][]byte, len(files))
	for i, path := range files {
		src, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		srcs[i] = src
		if want[i], err = ExtractComments(LangGo, src); err != nil {
			t.Fatal(err)
		}
	}
	var wg sync.WaitGroup
	errs := make(chan error, 8)
	for range 8 {
		wg.Go(func() {
			for i, src := range srcs {
				got, err := ExtractComments(LangGo, src)
				if err != nil || !slices.Equal(got, want[i]) {
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

func texts(src string, spans []Span) []string {
	out := make([]string, len(spans))
	for i, s := range spans {
		out[i] = src[s.StartByte:s.EndByte]
	}
	return out
}
