package ztree

/*
#include <ztree.h>
*/
import "C"

import (
	"errors"
	"strings"
	"sync"
	"unicode/utf8"
	"unsafe"
)

// The node API has the method names of go-tree-sitter (ADR-0007). One cgo
// call parses a file into a flat array of nodes (ADR-0008). Each node
// method then reads Go memory only. Go owns all memory, so no type has a
// Close method.

// none is ZTREE_NONE: the parent of the root, or the next sibling of the last child.
const none = 0xffffffff

// nodeRecord has the layout of C.ztree_node, so C writes into a []nodeRecord.
type nodeRecord struct {
	startByte       uint32
	endByte         uint32
	startRow        uint32
	startColumn     uint32
	endRow          uint32
	endColumn       uint32
	parent          uint32
	nextSibling     uint32
	childCount      uint32
	namedChildCount uint32
	symbol          uint16
	fieldID         uint16
	flags           uint16
	statusFieldID   uint16
}

// Each array length is negative, and the build fails, when the layouts differ.
var (
	_ [unsafe.Sizeof(nodeRecord{}) - unsafe.Sizeof(C.ztree_node{})]struct{}
	_ [unsafe.Sizeof(C.ztree_node{}) - unsafe.Sizeof(nodeRecord{})]struct{}
	_ [unsafe.Offsetof(nodeRecord{}.symbol) - unsafe.Offsetof(C.ztree_node{}.symbol)]struct{}
	_ [unsafe.Offsetof(C.ztree_node{}.symbol) - unsafe.Offsetof(nodeRecord{}.symbol)]struct{}
	_ [unsafe.Offsetof(nodeRecord{}.statusFieldID) - unsafe.Offsetof(C.ztree_node{}.status_field_id)]struct{}
	_ [unsafe.Offsetof(C.ztree_node{}.status_field_id) - unsafe.Offsetof(nodeRecord{}.statusFieldID)]struct{}
)

// overrideRecord has the layout of C.ztree_field_override.
type overrideRecord struct {
	node     uint32
	child    uint32
	fieldID  uint16
	reserved uint16
}

var (
	_ [unsafe.Sizeof(overrideRecord{}) - unsafe.Sizeof(C.ztree_field_override{})]struct{}
	_ [unsafe.Sizeof(C.ztree_field_override{}) - unsafe.Sizeof(overrideRecord{})]struct{}
	_ [unsafe.Offsetof(overrideRecord{}.fieldID) - unsafe.Offsetof(C.ztree_field_override{}.field_id)]struct{}
	_ [unsafe.Offsetof(C.ztree_field_override{}.field_id) - unsafe.Offsetof(overrideRecord{}.fieldID)]struct{}
)

func (r *nodeRecord) has(flag uint16) bool { return r.flags&flag != 0 }

const (
	flagNamed    = C.ZTREE_NODE_NAMED
	flagExtra    = C.ZTREE_NODE_EXTRA
	flagMissing  = C.ZTREE_NODE_MISSING
	flagError    = C.ZTREE_NODE_ERROR
	flagHasError = C.ZTREE_NODE_HAS_ERROR
)

// symbolError is the symbol of an ERROR node.
const symbolError = C.ZTREE_SYMBOL_ERROR

// Language holds the metadata of one grammar: the names and the flags of
// its symbols and the names of its fields. Two goroutines can use one
// Language at the same time.
type Language struct {
	lang        Lang
	abiVersion  uint32
	symbolNames []string
	symbolFlags []uint32
	fieldNames  []string
	fieldIDs    map[string]uint16
}

var (
	languageOnce [LangCPP + 1]sync.Once
	languages    [LangCPP + 1]*Language
)

// NewLanguage returns the Language of a grammar, or nil for an unknown
// grammar. Each call for a grammar returns the same *Language.
func NewLanguage(lang Lang) *Language {
	if lang > LangCPP {
		return nil
	}
	languageOnce[lang].Do(func() { languages[lang] = loadLanguage(lang) })
	return languages[lang]
}

func loadLanguage(lang Lang) *Language {
	c := C.uint32_t(lang)
	l := &Language{lang: lang, abiVersion: uint32(C.ztree_language_abi_version(c))}
	symbols := uint32(C.ztree_language_symbol_count(c))
	l.symbolNames = make([]string, symbols)
	l.symbolFlags = make([]uint32, symbols)
	for s := range symbols {
		l.symbolNames[s] = C.GoString(C.ztree_language_symbol_name(c, C.uint32_t(s)))
		l.symbolFlags[s] = uint32(C.ztree_language_symbol_flags(c, C.uint32_t(s)))
	}
	fields := uint32(C.ztree_language_field_count(c))
	l.fieldNames = make([]string, fields+1)
	l.fieldIDs = make(map[string]uint16, fields)
	for f := uint32(1); f <= fields; f++ {
		name := C.GoString(C.ztree_language_field_name(c, C.uint32_t(f)))
		l.fieldNames[f] = name
		l.fieldIDs[name] = uint16(f)
	}
	return l
}

// Lang returns the grammar of the Language.
func (l *Language) Lang() Lang { return l.lang }

// AbiVersion returns the Tree-sitter ABI version of the grammar: 14 or 15.
func (l *Language) AbiVersion() uint32 { return l.abiVersion }

// NodeKindCount returns the number of symbols, aliases included.
func (l *Language) NodeKindCount() uint32 { return uint32(len(l.symbolNames)) }

// FieldCount returns the largest field id. Field ids start at 1.
func (l *Language) FieldCount() uint32 { return uint32(len(l.fieldNames) - 1) }

// NodeKindForId returns the name of a symbol, or "" out of range.
func (l *Language) NodeKindForId(id uint16) string {
	if id == symbolError {
		return "ERROR"
	}
	if int(id) >= len(l.symbolNames) {
		return ""
	}
	return l.symbolNames[id]
}

func (l *Language) symbolFlag(id uint16, flag uint32) bool {
	if id == symbolError {
		return flag != C.ZTREE_SYMBOL_SUPERTYPE
	}
	return int(id) < len(l.symbolFlags) && l.symbolFlags[id]&flag != 0
}

// NodeKindIsNamed reports whether a symbol is named.
func (l *Language) NodeKindIsNamed(id uint16) bool { return l.symbolFlag(id, C.ZTREE_SYMBOL_NAMED) }

// NodeKindIsVisible reports whether a symbol is visible.
func (l *Language) NodeKindIsVisible(id uint16) bool {
	return l.symbolFlag(id, C.ZTREE_SYMBOL_VISIBLE)
}

// FieldNameForId returns the name of a field, or "" for 0 and out of range.
func (l *Language) FieldNameForId(id uint16) string {
	if int(id) >= len(l.fieldNames) {
		return ""
	}
	return l.fieldNames[id]
}

// FieldIdForName returns the id of a field, or 0 for an unknown name.
func (l *Language) FieldIdForName(name string) uint16 { return l.fieldIDs[name] }

// Point is a position in the source. Rows start at 0. A column counts bytes
// from the start of its row.
type Point struct {
	Row    uint
	Column uint
}

// Errors of Parser.Parse.
var ErrNoLanguage = errors.New("ztree: the parser has no language")

// Parser parses source files with one grammar. It keeps size hints for
// the buffers, so one goroutine at a time can use a Parser.
type Parser struct {
	language      *Language
	hint          int
	overridesHint int
}

// NewParser returns a Parser with no language.
func NewParser() *Parser { return &Parser{} }

// SetLanguage sets the grammar of the next parse.
func (p *Parser) SetLanguage(l *Language) error {
	if l == nil {
		return ErrInvalidArgument
	}
	p.language = l
	return nil
}

// Language returns the grammar of the parser, or nil.
func (p *Parser) Language() *Language { return p.language }

// Parse parses src and returns its tree. A source with syntax errors gives
// a tree with ERROR and MISSING nodes, not an error. The tree keeps no
// reference to src.
func (p *Parser) Parse(src []byte) (*Tree, error) {
	if p.language == nil {
		return nil, ErrNoLanguage
	}
	if ABIVersion() != C.ZTREE_ABI_VERSION {
		return nil, ErrABIMismatch
	}
	// Most sources have fewer nodes than bytes / 3, and few overrides. A
	// larger count costs a second parse.
	nodes := make([]nodeRecord, max(p.hint, len(src)/3+16))
	overrides := make([]overrideRecord, max(p.overridesHint, 64))
	for range 2 {
		count, overrideCount, status := parse(p.language.lang, src, nodes, overrides)
		switch status {
		case C.ZTREE_OK:
			p.hint = max(p.hint, count)
			p.overridesHint = max(p.overridesHint, overrideCount)
			return newTree(p.language, src, nodes[:count], overrides[:overrideCount]), nil
		case C.ZTREE_ERROR_BUFFER_TOO_SMALL:
			nodes = make([]nodeRecord, max(count, len(nodes)))
			overrides = make([]overrideRecord, max(overrideCount, len(overrides)))
		default:
			return nil, statusError(status)
		}
	}
	return nil, errors.New("ztree: the node count changed between two parses")
}

func parse(lang Lang, src []byte, nodes []nodeRecord, overrides []overrideRecord) (int, int, C.int32_t) {
	var srcPtr *C.uint8_t
	if len(src) > 0 {
		srcPtr = (*C.uint8_t)(unsafe.Pointer(&src[0]))
	}
	var nodesPtr *C.ztree_node
	if len(nodes) > 0 {
		nodesPtr = (*C.ztree_node)(unsafe.Pointer(&nodes[0]))
	}
	var overridesPtr *C.ztree_field_override
	if len(overrides) > 0 {
		overridesPtr = (*C.ztree_field_override)(unsafe.Pointer(&overrides[0]))
	}
	var count, overrideCount C.size_t
	status := C.ztree_parse(C.uint32_t(lang), srcPtr, C.size_t(len(src)), nodesPtr, C.size_t(len(nodes)), &count,
		overridesPtr, C.size_t(len(overrides)), &overrideCount)
	return int(count), int(overrideCount), status
}

// nodeLinks holds the positions of a node in the child lists of its parent,
// and the start of its own child lists.
type nodeLinks struct {
	children    uint32 // The index of the first child in Tree.children.
	named       uint32 // The index of the first named child in Tree.named.
	position    uint32 // The index of the node in the children of its parent.
	namedBefore uint32 // The number of named siblings before the node.
}

// Tree is a syntax tree. Two goroutines can read one Tree at the same time.
type Tree struct {
	language *Language
	nodes    []nodeRecord
	links    []nodeLinks
	children []uint32
	named    []uint32
	// The field lookups that the first-child rule does not give, by
	// overrideKey. The value is a node index, or none.
	overrides map[uint64]uint32
	// The same overrides as records, for ztree_query_exec.
	rawOverrides []overrideRecord
	// The first code point of each ERROR leaf, for ToSexp.
	unexpected map[uint32]rune
}

func overrideKey(node uint32, field uint16) uint64 { return uint64(node)<<16 | uint64(field) }

func newTree(l *Language, src []byte, nodes []nodeRecord, overrides []overrideRecord) *Tree {
	t := &Tree{language: l, nodes: nodes, links: make([]nodeLinks, len(nodes)), rawOverrides: overrides}
	if len(overrides) > 0 {
		t.overrides = make(map[uint64]uint32, len(overrides))
		for _, o := range overrides {
			t.overrides[overrideKey(o.node, o.fieldID)] = o.child
		}
	}
	var children, named uint32
	for i := range nodes {
		t.links[i].children, t.links[i].named = children, named
		children += nodes[i].childCount
		named += nodes[i].namedChildCount
	}
	t.children = make([]uint32, children)
	t.named = make([]uint32, named)
	for i := range nodes {
		n := &nodes[i]
		if n.has(flagError) && n.childCount == 0 && n.endByte > n.startByte {
			if t.unexpected == nil {
				t.unexpected = map[uint32]rune{}
			}
			t.unexpected[uint32(i)] = firstRune(src[n.startByte:n.endByte])
		}
		if n.childCount == 0 {
			continue
		}
		var position, namedBefore uint32
		for c := uint32(i + 1); c != none; c = nodes[c].nextSibling {
			t.links[c].position, t.links[c].namedBefore = position, namedBefore
			t.children[t.links[i].children+position] = c
			position++
			if nodes[c].has(flagNamed) {
				t.named[t.links[i].named+namedBefore] = c
				namedBefore++
			}
		}
	}
	return t
}

// firstRune decodes the first code point as the reference runtime does: -1
// for an ill-formed sequence.
func firstRune(text []byte) rune {
	r, size := utf8.DecodeRune(text)
	if r == utf8.RuneError && size <= 1 {
		return -1
	}
	return r
}

// Language returns the grammar of the tree.
func (t *Tree) Language() *Language { return t.language }

// RootNode returns the root of the tree.
func (t *Tree) RootNode() *Node { return &Node{tree: t, index: 0} }

// Walk returns a cursor at the root of the tree.
func (t *Tree) Walk() *TreeCursor { return t.RootNode().Walk() }

// Node is one node of a tree: the root, a named node or an anonymous node.
// The zero Node is not valid. Methods that find another node return nil
// when there is no such node.
type Node struct {
	tree  *Tree
	index uint32
}

func (n *Node) rec() *nodeRecord { return &n.tree.nodes[n.index] }

func (n *Node) node(index uint32) *Node {
	if index == none {
		return nil
	}
	return &Node{tree: n.tree, index: index}
}

// Kind returns the type of the node.
func (n *Node) Kind() string { return n.tree.language.NodeKindForId(n.rec().symbol) }

// KindId returns the symbol of the node, with the alias applied.
func (n *Node) KindId() uint16 { return n.rec().symbol }

// IsNamed reports whether the node is named.
func (n *Node) IsNamed() bool { return n.rec().has(flagNamed) }

// IsExtra reports whether the node is an extra, such as a comment.
func (n *Node) IsExtra() bool { return n.rec().has(flagExtra) }

// IsMissing reports whether the parser inserted the node to recover from an error.
func (n *Node) IsMissing() bool { return n.rec().has(flagMissing) }

// IsError reports whether the node is an ERROR node.
func (n *Node) IsError() bool { return n.rec().has(flagError) }

// HasError reports whether the node is or holds an ERROR or MISSING node.
func (n *Node) HasError() bool { return n.rec().has(flagHasError) }

// StartByte returns the offset of the first byte of the node.
func (n *Node) StartByte() uint { return uint(n.rec().startByte) }

// EndByte returns the offset after the last byte of the node.
func (n *Node) EndByte() uint { return uint(n.rec().endByte) }

// ByteRange returns the start and the end byte of the node.
func (n *Node) ByteRange() (uint, uint) { return n.StartByte(), n.EndByte() }

// StartPosition returns the row and the column of the start of the node.
func (n *Node) StartPosition() Point {
	r := n.rec()
	return Point{Row: uint(r.startRow), Column: uint(r.startColumn)}
}

// EndPosition returns the row and the column of the end of the node.
func (n *Node) EndPosition() Point {
	r := n.rec()
	return Point{Row: uint(r.endRow), Column: uint(r.endColumn)}
}

// Utf8Text returns the text of the node in src, the source of the tree.
func (n *Node) Utf8Text(src []byte) string {
	r := n.rec()
	return string(src[r.startByte:r.endByte])
}

// Equals reports whether two nodes are the same node of the same tree.
func (n *Node) Equals(other Node) bool { return n.tree == other.tree && n.index == other.index }

// Parent returns the parent of the node, or nil for the root.
func (n *Node) Parent() *Node { return n.node(n.rec().parent) }

// ChildCount returns the number of children, named and anonymous.
func (n *Node) ChildCount() uint { return uint(n.rec().childCount) }

// NamedChildCount returns the number of named children.
func (n *Node) NamedChildCount() uint { return uint(n.rec().namedChildCount) }

// Child returns child i, or nil.
func (n *Node) Child(i uint) *Node {
	if i >= n.ChildCount() {
		return nil
	}
	return n.node(n.tree.children[uint(n.tree.links[n.index].children)+i])
}

// NamedChild returns named child i, or nil.
func (n *Node) NamedChild(i uint) *Node {
	if i >= n.NamedChildCount() {
		return nil
	}
	return n.node(n.tree.named[uint(n.tree.links[n.index].named)+i])
}

// ChildByFieldName returns the first child in the field name, or nil.
func (n *Node) ChildByFieldName(name string) *Node {
	return n.ChildByFieldId(n.tree.language.FieldIdForName(name))
}

// ChildByFieldId returns the child in the field id, or nil. It gives the
// result of ts_node_child_by_field_id: mostly the first child whose field
// is id. The tree holds the rare other results, such as a grandchild for an
// inherited field, and nil for each field of an ERROR node.
func (n *Node) ChildByFieldId(id uint16) *Node {
	r := n.rec()
	if id == 0 || r.childCount == 0 {
		return nil
	}
	if child, ok := n.tree.overrides[overrideKey(n.index, id)]; ok {
		return n.node(child)
	}
	first := n.tree.links[n.index].children
	for _, c := range n.tree.children[first : first+r.childCount] {
		if n.tree.nodes[c].fieldID == id {
			return n.node(c)
		}
	}
	return nil
}

// siblings returns the children of the parent of the node, or nil for the root.
func (n *Node) siblings() []uint32 {
	p := n.rec().parent
	if p == none {
		return nil
	}
	first := n.tree.links[p].children
	return n.tree.children[first : first+n.tree.nodes[p].childCount]
}

// NextSibling returns the next sibling, or nil. As in the reference
// runtime, it skips each sibling that ends where the node ends, such as an
// empty MISSING node.
func (n *Node) NextSibling() *Node {
	end := n.rec().endByte
	for _, c := range n.siblings()[n.tree.links[n.index].position+1:] {
		if n.tree.nodes[c].endByte > end {
			return n.node(c)
		}
	}
	return nil
}

// NextNamedSibling returns the next named sibling, or nil, with the rule of NextSibling.
func (n *Node) NextNamedSibling() *Node {
	end := n.rec().endByte
	for _, c := range n.siblings()[n.tree.links[n.index].position+1:] {
		if n.tree.nodes[c].endByte > end && n.tree.nodes[c].has(flagNamed) {
			return n.node(c)
		}
	}
	return nil
}

// PrevSibling returns the previous sibling, or nil.
func (n *Node) PrevSibling() *Node {
	position := n.tree.links[n.index].position
	if n.rec().parent == none || position == 0 {
		return nil
	}
	return n.node(n.siblings()[position-1])
}

// PrevNamedSibling returns the previous named sibling, or nil.
func (n *Node) PrevNamedSibling() *Node {
	p := n.rec().parent
	before := n.tree.links[n.index].namedBefore
	if p == none || before == 0 {
		return nil
	}
	return n.node(n.tree.named[n.tree.links[p].named+before-1])
}

// Walk returns a cursor at the node. The cursor does not leave the node.
func (n *Node) Walk() *TreeCursor { return &TreeCursor{tree: n.tree, root: n.index, current: n.index} }

// ToSexp returns the S-expression of the node and its named descendants,
// with field names, as ts_node_string writes it. It does not show the
// MISSING nodes of hidden tokens, which a cursor does not visit (ADR-0009).
func (n *Node) ToSexp() string {
	var b strings.Builder
	type entry struct {
		index uint32
		shown bool
		field uint16
	}
	nodes := n.tree.nodes
	end := n.index + 1
	for end < uint32(len(nodes)) && n.tree.isDescendant(end, n.index) {
		end++
	}
	stack := make([]entry, 0, 64)
	for i := n.index; i < end; i++ {
		r := &nodes[i]
		for len(stack) > 0 && stack[len(stack)-1].index != r.parent {
			if stack[len(stack)-1].shown {
				b.WriteByte(')')
			}
			stack = stack[:len(stack)-1]
		}
		e := entry{index: i, shown: r.has(flagNamed) || r.has(flagMissing)}
		if i != n.index && !r.has(flagExtra) {
			up := stack[len(stack)-1]
			switch {
			case r.fieldID != 0:
				e.field = r.fieldID
			case !up.shown:
				e.field = up.field
			}
		}
		n.tree.writeOpen(&b, e.index, e.shown, e.field, i == n.index)
		stack = append(stack, e)
	}
	for ; len(stack) > 0; stack = stack[:len(stack)-1] {
		if stack[len(stack)-1].shown {
			b.WriteByte(')')
		}
	}
	return b.String()
}

// isDescendant reports whether node i is in the subtree of node a. Node i
// comes after node a in pre-order.
func (t *Tree) isDescendant(i, a uint32) bool {
	for p := t.nodes[i].parent; p != none && p >= a; p = t.nodes[p].parent {
		if p == a {
			return true
		}
	}
	return false
}

func (t *Tree) writeOpen(b *strings.Builder, i uint32, shown bool, field uint16, top bool) {
	r := &t.nodes[i]
	name := t.language.NodeKindForId(r.symbol)
	if !shown {
		if top && r.childCount > 0 {
			b.WriteString("(" + name)
		} else if top {
			b.WriteString("(\"" + name + "\")")
		}
		return
	}
	if !top {
		b.WriteByte(' ')
		if field != 0 {
			b.WriteString(t.language.FieldNameForId(field) + ": ")
		}
	}
	switch {
	case r.has(flagError) && r.childCount == 0 && r.endByte > r.startByte:
		b.WriteString("(UNEXPECTED " + unexpectedChar(t.unexpected[i]))
	case r.has(flagMissing) && r.has(flagNamed):
		b.WriteString("(MISSING " + name)
	case r.has(flagMissing):
		b.WriteString("(MISSING \"" + name + "\"")
	default:
		b.WriteString("(" + name)
	}
}

// unexpectedChar writes a code point as ts_subtree__write_char_to_string does.
func unexpectedChar(r rune) string {
	switch {
	case r == -1:
		return "INVALID"
	case r == 0:
		return `'\0'`
	case r == '\n':
		return `'\n'`
	case r == '\t':
		return `'\t'`
	case r == '\r':
		return `'\r'`
	case r >= 0x20 && r <= 0x7e:
		return "'" + string(r) + "'"
	}
	return strconvItoa(int(r))
}

func strconvItoa(v int) string {
	var buf [12]byte
	i := len(buf)
	for {
		i--
		buf[i] = byte('0' + v%10)
		v /= 10
		if v == 0 {
			return string(buf[i:])
		}
	}
}

// TreeCursor walks a tree from a start node. It does not leave the start node.
type TreeCursor struct {
	tree    *Tree
	root    uint32
	current uint32
	depth   uint32
}

// Node returns the current node.
func (c *TreeCursor) Node() *Node { return &Node{tree: c.tree, index: c.current} }

// Depth returns the number of levels below the start node.
func (c *TreeCursor) Depth() uint32 { return c.depth }

// Reset moves the cursor to node and makes it the start node.
func (c *TreeCursor) Reset(node Node) {
	c.tree, c.root, c.current, c.depth = node.tree, node.index, node.index, 0
}

// GotoFirstChild moves to the first child. It returns false for a node
// with no children.
func (c *TreeCursor) GotoFirstChild() bool {
	if c.tree.nodes[c.current].childCount == 0 {
		return false
	}
	c.current++
	c.depth++
	return true
}

// GotoNextSibling moves to the next sibling. It returns false at the last
// child and at the start node.
func (c *TreeCursor) GotoNextSibling() bool {
	next := c.tree.nodes[c.current].nextSibling
	if c.current == c.root || next == none {
		return false
	}
	c.current = next
	return true
}

// GotoParent moves to the parent. It returns false at the start node.
func (c *TreeCursor) GotoParent() bool {
	if c.current == c.root {
		return false
	}
	c.current = c.tree.nodes[c.current].parent
	c.depth--
	return true
}

// FieldId returns the field of the current node in its parent, or 0. It
// returns 0 at the start node.
func (c *TreeCursor) FieldId() uint16 {
	if c.current == c.root {
		return 0
	}
	return c.tree.nodes[c.current].fieldID
}

// FieldName returns the name of the field of the current node, or "".
func (c *TreeCursor) FieldName() string { return c.tree.language.FieldNameForId(c.FieldId()) }
