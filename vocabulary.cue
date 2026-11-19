// The vocabulary of the ztree repository: technical terms of this project
// that the extended rules STE-100-06 and STE-100-07 of lexiscope do not report.
// The docs-lexiscope task loads this file over the built-in ste-100 ruleset:
//
//	lexiscope scan --ruleset ste-100 --ruleset vocabulary.cue ...
//
// Add a term only when it names a concept of the project, a tool or a
// standard. Reword other text.
vocabulary: {
	// Project process: ADRs, issues and the Power of 10 rules.
	acceptance:     true // acceptance criteria of an issue
	decision:       true // architecture decision record
	development:    true // the development workflow
	resolution:     true // the Resolution section of an issue
	allocation:     true // Power of 10 rule R3
	initialization: true // Power of 10 rule R3
	suppression:    true // a nasa-lint allow comment
	mutation:       true // mutation checks of the tests
	marketing:      true // the marketing words rule

	// Tree-sitter, the parser and the gates.
	conformance: true // the conformance step: the corpus tests of each grammar
	extraction:  true // comment extraction for lexiscope
	execution:   true // query execution, Phase 12 and ISSUE-014
	production:  true // a grammar production and its production id
	precedence:  true // the dynamic precedence of a parse
	repetition:  true // a hidden repetition subtree

	// The regex engine and RE2 syntax.
	alternation:  true // the regex operator |
	backtracking: true // a backtracking regex engine
	folding:      true // case folding
	punctuation:  true // the ASCII punctuation class of RE2
}
