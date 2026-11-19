//! Subtrees: the nodes of the tree while a parse runs. This ports
//! `subtree.c` of the reference runtime with three changes (ADR-0005):
//! every subtree lives in one arena for the whole parse, ztree keeps no
//! reference counts, and `makeMut` always copies. A subtree is never changed
//! in place after another holder can see it, so the result is the same.

const std = @import("std");
const assert = std.debug.assert;
const abi = @import("abi.zig");
const language = @import("language.zig");
const length = @import("length.zig");
const limits = @import("root.zig").limits;

const Language = abi.Language14;
const Symbol = abi.Symbol;
const StateId = abi.StateId;
const Length = length.Length;

/// `TS_TREE_STATE_NONE`: a subtree that no single parse state produced.
pub const state_none: StateId = std.math.maxInt(u16);

pub const error_cost_per_recovery: u32 = 500;
pub const error_cost_per_missing_tree: u32 = 110;
pub const error_cost_per_skipped_tree: u32 = 100;
pub const error_cost_per_skipped_line: u32 = 30;
pub const error_cost_per_skipped_char: u32 = 1;

pub const Error = error{ OutOfMemory, TooManySubtrees };

pub const Subtree = struct {
    padding: Length,
    size: Length,
    lookahead_bytes: u32,
    error_cost: u32 = 0,
    symbol: Symbol,
    parse_state: StateId,
    visible: bool,
    named: bool,
    extra: bool = false,
    fragile_left: bool = false,
    fragile_right: bool = false,
    has_external_tokens: bool = false,
    has_external_scanner_state_change: bool = false,
    depends_on_column: bool = false,
    is_missing: bool = false,
    is_keyword: bool = false,
    children: []*const Subtree = &.{},
    // Fields of a node with children.
    visible_child_count: u32 = 0,
    named_child_count: u32 = 0,
    visible_descendant_count: u32 = 0,
    dynamic_precedence: i32 = 0,
    production_id: u16 = 0,
    first_leaf_symbol: Symbol = 0,
    first_leaf_parse_state: StateId = 0,
    /// The serialized external scanner state of an external token.
    external_scanner_state: []const u8 = &.{},
    /// The first character of an ERROR leaf.
    lookahead_char: i32 = 0,

    pub fn totalSize(self: *const Subtree) Length {
        assert(self.padding.bytes <= limits.max_source_bytes);
        assert(self.size.bytes <= limits.max_source_bytes);
        return addLength(self.padding, self.size);
    }

    pub fn isError(self: *const Subtree) bool {
        assert(self.children.len <= limits.max_subtrees);
        assert(self.named_child_count <= self.visible_child_count);
        return self.symbol == abi.builtin_sym_error;
    }

    pub fn isRepetition(self: *const Subtree) bool {
        assert(self.children.len <= limits.max_subtrees);
        assert(self.named_child_count <= self.visible_child_count);
        return !self.named and !self.visible and self.children.len != 0;
    }

    pub fn errorCost(self: *const Subtree) u32 {
        assert(self.children.len <= limits.max_subtrees);
        assert(self.named_child_count <= self.visible_child_count);
        if (self.is_missing) return error_cost_per_missing_tree + error_cost_per_recovery;
        return self.error_cost;
    }

    pub fn dynamicPrecedence(self: *const Subtree) i32 {
        assert(self.children.len <= limits.max_subtrees);
        assert(self.named_child_count <= self.visible_child_count);
        return if (self.children.len == 0) 0 else self.dynamic_precedence;
    }

    pub fn productionId(self: *const Subtree) u16 {
        assert(self.children.len <= limits.max_subtrees);
        assert(self.named_child_count <= self.visible_child_count);
        return if (self.children.len == 0) 0 else self.production_id;
    }

    pub fn visibleDescendantCount(self: *const Subtree) u32 {
        assert(self.children.len <= limits.max_subtrees);
        assert(self.named_child_count <= self.visible_child_count);
        return if (self.children.len == 0) 0 else self.visible_descendant_count;
    }

    pub fn leafSymbol(self: *const Subtree) Symbol {
        assert(self.children.len <= limits.max_subtrees);
        assert(self.named_child_count <= self.visible_child_count);
        return if (self.children.len == 0) self.symbol else self.first_leaf_symbol;
    }

    pub fn leafParseState(self: *const Subtree) StateId {
        assert(self.children.len <= limits.max_subtrees);
        assert(self.named_child_count <= self.visible_child_count);
        return if (self.children.len == 0) self.parse_state else self.first_leaf_parse_state;
    }

    /// The scanner state of an external token, or the empty state.
    pub fn externalState(self: ?*const Subtree) []const u8 {
        assert(self == null or self.?.external_scanner_state.len <= abi.serialization_buffer_size);
        assert(self == null or self.?.children.len <= limits.max_subtrees);
        const s = self orelse return &.{};
        if (!s.has_external_tokens or s.children.len != 0) return &.{};
        return s.external_scanner_state;
    }
};

/// Add two lengths (`length_add` with `point_add`).
pub fn addLength(a: Length, b: Length) Length {
    assert(a.bytes <= limits.max_source_bytes);
    assert(b.bytes <= limits.max_source_bytes);
    const extent = if (b.extent.row > 0)
        length.Point{ .row = a.extent.row + b.extent.row, .column = b.extent.column }
    else
        length.Point{ .row = a.extent.row, .column = a.extent.column + b.extent.column };
    return .{ .bytes = a.bytes + b.bytes, .extent = extent };
}

/// Subtract two lengths (`length_sub` with `point_sub`).
pub fn subLength(a: Length, b: Length) Length {
    assert(a.bytes <= limits.max_source_bytes);
    assert(b.bytes <= limits.max_source_bytes);
    const bytes = if (a.bytes >= b.bytes) a.bytes - b.bytes else 0;
    const extent = if (a.extent.row > b.extent.row)
        length.Point{ .row = a.extent.row - b.extent.row, .column = a.extent.column }
    else
        length.Point{ .row = 0, .column = if (a.extent.column >= b.extent.column) a.extent.column - b.extent.column else 0 };
    return .{ .bytes = bytes, .extent = extent };
}

/// True when two subtrees hold the same external scanner state.
pub fn externalStateEq(a: ?*const Subtree, b: ?*const Subtree) bool {
    const sa = Subtree.externalState(a);
    const sb = Subtree.externalState(b);
    assert(sa.len <= abi.serialization_buffer_size);
    assert(sb.len <= abi.serialization_buffer_size);
    return std.mem.eql(u8, sa, sb);
}

/// The arena for one parse. It allocates subtrees and their child arrays.
pub const Pool = struct {
    arena: std.mem.Allocator,
    lang: *const Language,
    count: usize = 0,

    fn create(self: *Pool, value: Subtree) Error!*Subtree {
        assert(self.count <= limits.max_subtrees);
        if (self.count == limits.max_subtrees) return error.TooManySubtrees;
        const node = try self.arena.create(Subtree);
        node.* = value;
        self.count += 1;
        assert(node.symbol == value.symbol);
        return node;
    }

    /// Return a new leaf (`ts_subtree_new_leaf`).
    pub fn newLeaf(self: *Pool, symbol: Symbol, padding: Length, size: Length, lookahead_bytes: u32, parse_state: StateId, has_external_tokens: bool, depends_on_column: bool, is_keyword: bool) Error!*Subtree {
        assert(symbol < self.lang.symbol_count + self.lang.alias_count or symbol == abi.builtin_sym_error);
        const metadata = language.symbolMetadata(self.lang, symbol);
        assert(padding.bytes + size.bytes <= limits.max_source_bytes);
        return self.create(.{
            .padding = padding,
            .size = size,
            .lookahead_bytes = lookahead_bytes,
            .symbol = symbol,
            .parse_state = parse_state,
            .visible = metadata.visible,
            .named = metadata.named,
            .extra = symbol == abi.builtin_sym_end,
            .has_external_tokens = has_external_tokens,
            .depends_on_column = depends_on_column,
            .is_keyword = is_keyword,
        });
    }

    /// Return a new ERROR leaf (`ts_subtree_new_error`).
    pub fn newError(self: *Pool, lookahead_char: i32, padding: Length, size: Length, bytes_scanned: u32, parse_state: StateId) Error!*Subtree {
        assert(padding.bytes <= limits.max_source_bytes);
        const leaf = try self.newLeaf(abi.builtin_sym_error, padding, size, bytes_scanned, parse_state, false, false, false);
        leaf.fragile_left = true;
        leaf.fragile_right = true;
        leaf.lookahead_char = lookahead_char;
        assert(leaf.isError());
        return leaf;
    }

    /// Return a new MISSING leaf (`ts_subtree_new_missing_leaf`).
    pub fn newMissingLeaf(self: *Pool, symbol: Symbol, state: StateId, padding: Length, lookahead_bytes: u32) Error!*Subtree {
        assert(symbol < self.lang.token_count);
        const leaf = try self.newLeaf(symbol, padding, length.zero, lookahead_bytes, state, false, false, false);
        leaf.is_missing = true;
        assert(leaf.size.bytes == 0);
        return leaf;
    }

    /// Return a node with a copy of `children` (`ts_subtree_new_node`).
    pub fn newNode(self: *Pool, symbol: Symbol, children: []const *const Subtree, production_id: u16) Error!*Subtree {
        const metadata = language.symbolMetadata(self.lang, symbol);
        const fragile = symbol == abi.builtin_sym_error or symbol == language.builtin_sym_error_repeat;
        assert(children.len <= std.math.maxInt(u32));
        const node = try self.create(.{
            .padding = length.zero,
            .size = length.zero,
            .lookahead_bytes = 0,
            .symbol = symbol,
            .parse_state = 0,
            .visible = metadata.visible,
            .named = metadata.named,
            .fragile_left = fragile,
            .fragile_right = fragile,
            .children = try self.arena.dupe(*const Subtree, children),
            .production_id = production_id,
        });
        summarizeChildren(node, self.lang);
        assert(node.children.len == children.len);
        return node;
    }

    /// Return an ERROR node over `children` (`ts_subtree_new_error_node`).
    pub fn newErrorNode(self: *Pool, children: []const *const Subtree, extra: bool) Error!*Subtree {
        assert(children.len <= limits.max_subtrees);
        const node = try self.newNode(abi.builtin_sym_error, children, 0);
        node.extra = extra;
        assert(node.isError());
        return node;
    }

    /// Return a copy that the caller can change (`ts_subtree_make_mut`).
    pub fn makeMut(self: *Pool, tree: *const Subtree) Error!*Subtree {
        assert(tree.children.len <= std.math.maxInt(u32));
        const copy = try self.create(tree.*);
        assert(copy.children.ptr == tree.children.ptr);
        return copy;
    }
};

/// Set the symbol and its metadata (`ts_subtree_set_symbol`).
pub fn setSymbol(tree: *Subtree, symbol: Symbol, lang: *const Language) void {
    const metadata = language.symbolMetadata(lang, symbol);
    assert(metadata.visible or !metadata.named or symbol != 0);
    tree.symbol = symbol;
    tree.named = metadata.named;
    tree.visible = metadata.visible;
    assert(tree.symbol == symbol);
}

fn errorExtentCost(size: Length) u32 {
    assert(size.bytes <= limits.max_source_bytes);
    const cost = error_cost_per_recovery + error_cost_per_skipped_char * size.bytes + error_cost_per_skipped_line * size.extent.row;
    assert(cost >= error_cost_per_recovery);
    return cost;
}

/// Reset the summary fields before `summarizeChildren` adds the children.
fn resetSummary(node: *Subtree) void {
    assert(node.children.len <= std.math.maxInt(u32));
    node.named_child_count = 0;
    node.visible_child_count = 0;
    node.error_cost = 0;
    node.visible_descendant_count = 0;
    node.has_external_tokens = false;
    node.depends_on_column = false;
    node.has_external_scanner_state_change = false;
    node.dynamic_precedence = 0;
    assert(node.error_cost == 0);
}

/// The symbol of an ERROR node or of a hidden ERROR repetition.
inline fn isErrorSymbol(symbol: Symbol) bool {
    return symbol == abi.builtin_sym_error or symbol == language.builtin_sym_error_repeat;
}

/// The error cost that `child` adds to `node`.
fn childErrorCost(node: *const Subtree, child: *const Subtree) u32 {
    assert(node.children.len > 0);
    if (child.symbol == language.builtin_sym_error_repeat) {
        const extent_cost = errorExtentCost(child.size);
        assert(child.errorCost() >= extent_cost);
        return child.errorCost() - extent_cost;
    }
    var cost = child.errorCost();
    if (isErrorSymbol(node.symbol) and !child.extra and !(child.isError() and child.children.len == 0)) {
        if (child.visible) {
            cost += error_cost_per_skipped_tree;
        } else if (child.children.len > 0) {
            cost += error_cost_per_skipped_tree * child.visible_child_count;
        }
    }
    return cost;
}

/// Add the visible and named counts of one child (`summarize_children`).
fn countVisibleChild(node: *Subtree, child: *const Subtree, alias: Symbol, lang: *const Language) void {
    assert(node.children.len > 0);
    if (!child.extra and child.symbol != 0 and alias != 0) {
        node.visible_descendant_count += 1;
        node.visible_child_count += 1;
        if (language.symbolMetadata(lang, alias).named) node.named_child_count += 1;
    } else if (child.visible) {
        node.visible_descendant_count += 1;
        node.visible_child_count += 1;
        if (child.named) node.named_child_count += 1;
    } else if (child.children.len > 0) {
        node.visible_child_count += child.visible_child_count;
        node.named_child_count += child.named_child_count;
    }
    assert(node.named_child_count <= node.visible_child_count);
}

/// Compute the summary fields of `node` from its children
/// (`ts_subtree_summarize_children`).
pub fn summarizeChildren(node: *Subtree, lang: *const Language) void {
    assert(node.children.len <= std.math.maxInt(u32));
    resetSummary(node);
    var structural_index: u32 = 0;
    var lookahead_end_byte: u32 = 0;
    for (node.children, 0..) |child, i| {
        if ((i == 0 or node.size.extent.row == 0) and child.depends_on_column) node.depends_on_column = true;
        if (child.has_external_scanner_state_change) node.has_external_scanner_state_change = true;
        if (i == 0) {
            node.padding = child.padding;
            node.size = child.size;
        } else {
            node.size = addLength(node.size, child.totalSize());
        }
        const child_end = node.padding.bytes + node.size.bytes + child.lookahead_bytes;
        if (child_end > lookahead_end_byte) lookahead_end_byte = child_end;
        node.error_cost += childErrorCost(node, child);
        node.dynamic_precedence += child.dynamicPrecedence();
        node.visible_descendant_count += child.visibleDescendantCount();
        const alias = if (child.extra) 0 else language.aliasAt(lang, node.production_id, structural_index);
        countVisibleChild(node, child, alias, lang);
        if (child.has_external_tokens) node.has_external_tokens = true;
        if (child.isError()) {
            node.fragile_left = true;
            node.fragile_right = true;
            node.parse_state = state_none;
        }
        if (!child.extra) structural_index += 1;
    }
    node.lookahead_bytes = lookahead_end_byte - node.size.bytes - node.padding.bytes;
    if (isErrorSymbol(node.symbol)) node.error_cost += errorExtentCost(node.size);
    if (node.children.len > 0) summarizeEnds(node);
    assert(node.lookahead_bytes <= lookahead_end_byte);
}

/// Set the first leaf and the fragile flags. ztree keeps no repeat depth:
/// only the balance step of the reference reads it (ADR-0005, ISSUE-017).
fn summarizeEnds(node: *Subtree) void {
    assert(node.children.len > 0);
    const first = node.children[0];
    const last = node.children[node.children.len - 1];
    node.first_leaf_symbol = first.leafSymbol();
    node.first_leaf_parse_state = first.leafParseState();
    if (first.fragile_left) node.fragile_left = true;
    if (last.fragile_right) node.fragile_right = true;
    assert(node.first_leaf_symbol == first.leafSymbol());
}

/// The last external token in `tree` (`ts_subtree_last_external_token`).
pub fn lastExternalToken(tree: *const Subtree) ?*const Subtree {
    if (!tree.has_external_tokens) return null;
    var current = tree;
    var depth: usize = 0;
    while (current.children.len > 0 and depth < limits.max_tree_depth) : (depth += 1) {
        var i = current.children.len;
        while (i > 0) {
            i -= 1;
            if (current.children[i].has_external_tokens) {
                current = current.children[i];
                break;
            }
        }
    }
    assert(current.children.len == 0);
    assert(current.has_external_tokens);
    return current;
}

/// Compare two trees by symbol and child count in pre-order (`ts_subtree_compare`).
/// `scratch` is an empty list that the caller reuses between calls.
pub fn compare(arena: std.mem.Allocator, scratch: *std.ArrayList(*const Subtree), left: *const Subtree, right: *const Subtree) Error!std.math.Order {
    assert(scratch.items.len == 0);
    defer scratch.clearRetainingCapacity();
    try scratch.appendSlice(arena, &.{ left, right });
    var steps: usize = 0;
    while (scratch.items.len > 0 and steps <= limits.max_subtrees) : (steps += 1) {
        const r = scratch.pop().?;
        const l = scratch.pop().?;
        if (l.symbol != r.symbol) return std.math.order(l.symbol, r.symbol);
        if (l.children.len != r.children.len) return std.math.order(l.children.len, r.children.len);
        var i = l.children.len;
        while (i > 0) {
            i -= 1;
            try scratch.appendSlice(arena, &.{ l.children[i], r.children[i] });
        }
    }
    assert(scratch.items.len % 2 == 0);
    return .eq;
}

test "addLength and subLength follow point arithmetic" {
    const a = Length{ .bytes = 10, .extent = .{ .row = 1, .column = 4 } };
    const b = Length{ .bytes = 3, .extent = .{ .row = 0, .column = 3 } };
    try std.testing.expectEqual(Length{ .bytes = 13, .extent = .{ .row = 1, .column = 7 } }, addLength(a, b));
    try std.testing.expectEqual(Length{ .bytes = 7, .extent = .{ .row = 1, .column = 4 } }, subLength(a, b));
}
