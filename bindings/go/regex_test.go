package ztree

import (
	"errors"
	"math/rand/v2"
	"regexp"
	"strings"
	"testing"
)

// The #match? patterns of the semscope rule sets, and the regex of its C
// parser.
var semscopePatterns = []string{
	`^//\s*nolint(:[A-Za-z0-9_,-]+)?\s*$`,
	`NOLINT(\([^)]*\))?\s*(\*/)?$`,
	`#\s*(noqa|type:\s*ignore)\s*$`,
	`(^|[^#])#\s*[A-Za-z_]`,
}

var tablePatterns = []string{
	``, `a`, `abc`, `^abc$`, `a|b|`, `(a|ab)(c|bcd)`, `a*`, `a+b+`, `a?b`, `(ab)*c`,
	`a{2}`, `a{2,}`, `a{1,3}b`, `(a{0,2}b){2}`, `x{0}`, `a{,2}`, `a{`, `a{1`, `a{1,`, `{2`,
	`.`, `(?s).`, `^.*$`, `(?s)^.*$`, `(?m)^b$`, `(?m)$`, `\A\z`, `^$`, `\bword\b`, `\Bor\B`,
	`[abc]`, `[^abc]`, `[a-c-e]`, `[-a]`, `[a-]`, `[]a]`, `[^]a]`, `[\]]`, `[\d_]`, `[^\D]`,
	`[\w\s]`, `[^\W]`, `[[:alpha:]]`, `[[:^digit:]x]`, `[[:punct:]]+`, `[[a]`, `[x[:y]`, `\d\D\s\S\w\W`,
	`(?i)abc`, `(?i)[a-c]`, `(?i)[^k]`, `(?i)\w`, `(?i)\W`, `(?i)s`, `(?i:A)a`, `(?i)(?-i)a`, `(?is)A.`, `(?U)a+`,
	`\x41`, `\x{263a}`, `\101`, `\0`, `\07`, `\a\f\t\n\r\v`, `\.\*\+\?\(\)\[\]\{\}\|\^\$\\`, `\-\_\ \/\#\:`, `é+`, `[é-ü]`,
	`a*?`, `a+?b`, `a??`, `a{2}?`, `(a*)*`, `(a|)+`, `()`, `(|)`, `(?:a|b)c`, `^*a`,
	`(?i)é`, `\pL`, `\p{Greek}`, `(?P<n>a)`, `(?<n>a)`, `\Qa.b\E`, `\C`,
	`a**`, `a*+`, `*a`, `(*)`, `a|*`, `(a`, `a)`, `[a`, `[z-a]`, `a{2,1}`, `a{1001}`, `\1`, `\8`, `\e`, `\Z`, `x\`,
	`(?x)a`, `(?-)a`, `(?i-)a`, `(?`, `(?i`, `[[:foo:]]`, `\x`, `\xG1`, `\x{}`, `\x{110000}`, `[a-\d]`, `[\b]`, "\xff",
}

var tableInputs = []string{
	"", "a", "b", "ab", "abc", "ABC", "aaa", "aab", "abcd", "abbcd", "xaby", "a\nb", "\n", "b\n",
	"word", "a word.", "sword", "1_x", " \t", "-", "]", "é", "ü", "☺", "K", "K", "ſ", "S",
	"\xff", "a\xffb", " ", "// nolint", "//nolint:errcheck ", "x // NOLINT(foo) */", "# type: ignore",
	"#define X", "##x", "x # noqa", "{", "a{", "a{,2}", "x{2}", "A.", "\a\f\t\n\r\v", ".*+?()[]{}|^$\\",
	"-_ /#:", "aa", "abab", "abbb",
}

// compareRegex compares ztree with the regexp package on one pattern. It
// returns false when ztree does not support the pattern.
func compareRegex(t *testing.T, pattern string, inputs []string) bool {
	t.Helper()
	re, goErr := regexp.Compile(pattern)
	_, _, err := regexMatch(pattern, nil)
	switch {
	case errors.Is(err, ErrRegexUnsupported), errors.Is(err, ErrLimitReached):
		return false
	case errors.Is(err, ErrRegexSyntax):
		if goErr == nil {
			t.Errorf("pattern %q: ztree gives a syntax error, Go compiles it", pattern)
		}
		return true
	case err != nil:
		t.Fatalf("pattern %q: %v", pattern, err)
	case goErr != nil:
		t.Errorf("pattern %q: ztree compiles it, Go gives %v", pattern, goErr)
		return true
	}
	for _, in := range inputs {
		got, _, err := regexMatch(pattern, []byte(in))
		if err != nil {
			t.Fatalf("pattern %q input %q: %v", pattern, in, err)
		}
		if want := re.MatchString(in); got != want {
			t.Errorf("pattern %q input %q: ztree %v, Go %v", pattern, in, got, want)
		}
	}
	return true
}

func TestRegexTable(t *testing.T) {
	unsupported := 0
	for _, p := range append(slicesConcat(semscopePatterns, tablePatterns), semscopePatterns...) {
		if !compareRegex(t, p, tableInputs) {
			unsupported++
		}
	}
	for _, p := range semscopePatterns {
		if _, _, err := regexMatch(p, nil); err != nil {
			t.Errorf("semscope pattern %q: %v", p, err)
		}
	}
	if unsupported != 7 {
		t.Errorf("%d unsupported patterns, want 7", unsupported)
	}
}

func slicesConcat(a, b []string) []string { return append(append([]string{}, a...), b...) }

// The parts of the random patterns and inputs.
var (
	patternParts = []string{
		"a", "b", "c", "A", "K", "s", "_", "1", " ", ".", "\\n", "\\.", "\\d", "\\w", "\\s", "\\W", "\\b", "\\B",
		"^", "$", "\\A", "\\z", "[ab]", "[^a]", "[a-c]", "[[:upper:]]", "[\\d\\s]", "(", ")", "(?:", "|",
		"*", "+", "?", "*?", "{2}", "{1,2}", "{0,}", "{", "}", "(?i)", "(?m)", "(?s)", "(?-i)", "(?i:", "é", "\\x{17f}",
	}
	inputParts = []string{"a", "b", "c", "A", "B", "K", "K", "s", "S", "ſ", "_", "1", " ", "\n", "#", "é", "\xff", "ab"}
)

func randomString(r *rand.Rand, parts []string, n int) string {
	var b strings.Builder
	for range r.IntN(n + 1) {
		b.WriteString(parts[r.IntN(len(parts))])
	}
	return b.String()
}

// TestRegexRandom compares ztree with the regexp package on random patterns
// and random inputs. The seed is fixed, so the test is repeatable.
func TestRegexRandom(t *testing.T) {
	r := rand.New(rand.NewPCG(1, 2))
	compared, valid := 0, 0
	for range 20000 {
		pattern := randomString(r, patternParts, 8)
		inputs := make([]string, 12)
		for i := range inputs {
			inputs[i] = randomString(r, inputParts, 8)
		}
		if compareRegex(t, pattern, inputs) {
			compared++
			if _, err := regexp.Compile(pattern); err == nil {
				valid++
			}
		}
		if t.Failed() {
			return
		}
	}
	if compared < 15000 || valid < 8000 {
		t.Fatalf("compared %d patterns, %d valid", compared, valid)
	}
	t.Logf("compared %d random patterns, %d of them valid", compared, valid)
}

// FuzzRegex compares ztree with the regexp package. `go test` runs the
// seeds; `go test -fuzz FuzzRegex` searches for new cases.
func FuzzRegex(f *testing.F) {
	for _, p := range append(slicesConcat(semscopePatterns, tablePatterns), "") {
		f.Add(p, "a word // NOLINT(x)")
	}
	f.Fuzz(func(t *testing.T, pattern, input string) {
		if len(pattern) > 64 {
			return
		}
		compareRegex(t, pattern, []string{input, "", "a\nb"})
	})
}
