//! The flat tree (ADR-0008): the visible nodes of a finished tree in
//! pre-order, as an array of fixed-size records. The C ABI writes the
//! records into caller memory, and the Go binding reads them. One walk with
//! an explicit stack writes the records. A record holds the result of each
//! `TSNode` function that the binding needs.

const std = @import("std");
const assert = std.debug.assert;
const abi = @import("abi.zig");
const language = @import("language.zig");
const length = @import("length.zig");
const st = @import("subtree.zig");
const tree = @import("tree.zig");
const utf8 = @import("utf8.zig");
const limits = @import("root.zig").limits;

const Language = abi.Language14;
const Symbol = abi.Symbol;
const FieldId = abi.FieldId;
const Length = length.Length;
const Subtree = st.Subtree;

pub const Error = tree.Error;

/// The index of a missing node: the parent of the root, or the next sibling
/// of the last child (`ZTREE_NONE`).
pub const none: u32 = std.math.maxInt(u32);

/// The bits of `Node.flags` (`ZTREE_NODE_*`).
pub const flag_named: u16 = 1 << 0;
pub const flag_extra: u16 = 1 << 1;
pub const flag_missing: u16 = 1 << 2;
pub const flag_error: u16 = 1 << 3;
pub const flag_has_error: u16 = 1 << 4;
/// `can_have_later_siblings_with_this_field` of `ts_tree_cursor_current_status`:
/// the production of the parent, or of a hidden node between them, has a
/// later child with the field of the node (ADR-0012).
pub const flag_later_field: u16 = 1 << 5;

/// One visible node (`ztree_node`). The first child of a node with children
/// is at the next index.
pub const Node = extern struct {
    start_byte: u32,
    end_byte: u32,
    start_row: u32,
    start_column: u32,
    end_row: u32,
    end_column: u32,
    /// The index of the parent, or `none` for the root.
    parent: u32,
    /// The index of the next sibling, or `none`.
    next_sibling: u32,
    /// `ts_node_child_count` and `ts_node_named_child_count`.
    child_count: u32,
    named_child_count: u32,
    /// `ts_node_symbol`: the public symbol, with the alias applied.
    symbol: Symbol,
    /// `ts_tree_cursor_current_field_id`: the field of the node in its
    /// parent, inherited through hidden nodes, or 0.
    field_id: FieldId,
    flags: u16,
    /// The field id of `ts_tree_cursor_current_status`, which the query
    /// cursor reads. It differs from `field_id` only for an extra node in a
    /// hidden node with a field (ADR-0012).
    status_field_id: FieldId = 0,

    pub fn isNamed(self: Node) bool {
        assert(self.start_byte <= self.end_byte);
        assert(self.named_child_count <= self.child_count);
        return self.flags & flag_named != 0;
    }
};

comptime {
    assert(@sizeOf(Node) == 48);
    assert(@offsetOf(Node, "symbol") == 40);
}

/// A subtree whose children the walk visits.
const Frame = struct {
    subtree: *const Subtree,
    /// The position of the next child.
    offset: Length,
    child_index: u32 = 0,
    structural_index: u32 = 0,
    fields: []const abi.FieldMapEntry,
    /// The field of a hidden subtree, for its children. 0 for a visible node.
    inherited_field: FieldId,
    /// True when the subtree is the node of the top entry of `owners`.
    owns: bool,
    /// For `ts_tree_cursor_current_status`, which does not stop at an extra
    /// node: the field of the nearest hidden level, and its later-field flag.
    chain_field: FieldId = 0,
    chain_can_later: bool = false,
    /// The fields that a later child can have at this hidden level or above,
    /// as a bit set. Empty for a visible node.
    later_above: []const u64 = &.{},
};

/// A visible node whose children the walk visits.
const Owner = struct {
    index: u32,
    last_child: u32 = none,
    child_count: u32 = 0,
    named_child_count: u32 = 0,
};

/// The public symbol of `symbol` (`ts_language_public_symbol`).
pub fn publicSymbol(lang: *const Language, symbol: Symbol) Symbol {
    assert(lang.public_symbol_map != null);
    if (symbol == abi.builtin_sym_error) return symbol;
    assert(symbol < lang.symbol_count + lang.alias_count);
    return lang.public_symbol_map.?[symbol];
}

/// The field map entries of a production (`ts_language_field_map`).
fn fieldMap(lang: *const Language, subtree: *const Subtree) []const abi.FieldMapEntry {
    assert(subtree.children.len > 0);
    if (lang.field_count == 0) return &.{};
    const production_id = subtree.productionId();
    assert(production_id < lang.production_id_count);
    const slice = lang.field_map_slices.?[production_id];
    assert(lang.field_map_entries != null);
    return lang.field_map_entries.?[slice.index..][0..slice.length];
}

/// The field of the child at `structural_index`, from the entries that are
/// not inherited.
fn ownField(fields: []const abi.FieldMapEntry, structural_index: u32) FieldId {
    assert(fields.len <= std.math.maxInt(u16));
    for (fields) |entry| {
        if (!entry.inherited and entry.child_index == structural_index) {
            assert(entry.field_id > 0);
            return entry.field_id;
        }
    }
    return 0;
}

/// The record of `node`, without its links and counts.
fn record(lang: *const Language, node: tree.Node, parent: u32, field_id: FieldId, status: Status) Node {
    const s = node.start();
    const e = node.end();
    assert(s.bytes <= e.bytes);
    const symbol = publicSymbol(lang, node.symbol());
    var flags: u16 = 0;
    if (node.isNamed(lang)) flags |= flag_named;
    if (node.subtree.extra) flags |= flag_extra;
    if (node.subtree.is_missing) flags |= flag_missing;
    if (symbol == abi.builtin_sym_error) flags |= flag_error;
    // `ts_node_has_error`: an ERROR node, or a node with an error cost. An
    // ERROR leaf can have no error cost.
    if (symbol == abi.builtin_sym_error or node.subtree.errorCost() > 0) flags |= flag_has_error;
    if (status.can_later) flags |= flag_later_field;
    assert(parent == none or parent < limits.max_subtrees);
    return .{
        .start_byte = s.bytes,
        .end_byte = e.bytes,
        .start_row = s.extent.row,
        .start_column = s.extent.column,
        .end_row = e.extent.row,
        .end_column = e.extent.column,
        .parent = parent,
        .next_sibling = none,
        .child_count = 0,
        .named_child_count = 0,
        .symbol = symbol,
        .field_id = field_id,
        .flags = flags,
        .status_field_id = status.field_id,
    };
}

/// The field part of `ts_tree_cursor_current_status` for one node.
const Status = struct { field_id: FieldId = 0, can_later: bool = false };

fn hasBit(set: []const u64, field_id: FieldId) bool {
    assert(field_id > 0);
    const word = field_id / 64;
    assert(set.len <= 1024);
    return word < set.len and set[word] & (@as(u64, 1) << @intCast(field_id % 64)) != 0;
}

/// True when a field map entry for `field_id` follows `structural_index`.
fn laterEntry(fields: []const abi.FieldMapEntry, field_id: FieldId, structural_index: u32) bool {
    assert(field_id > 0);
    assert(fields.len <= std.math.maxInt(u16));
    for (fields) |entry| {
        if (entry.field_id == field_id and entry.child_index > structural_index) return true;
    }
    return false;
}

/// The state of one flatten walk. It keeps each record and each node, so
/// the override pass can read the whole tree.
const Flattener = struct {
    arena: std.mem.Allocator,
    lang: *const Language,
    records: std.ArrayList(Node) = .empty,
    nodes: std.ArrayList(tree.Node) = .empty,
    frames: std.ArrayList(Frame) = .empty,
    owners: std.ArrayList(Owner) = .empty,

    /// Add the record of `node` and link it to its owner.
    fn emit(self: *Flattener, node: tree.Node, field_id: FieldId, status: Status) Error!void {
        const index: u32 = @intCast(self.records.items.len);
        assert(field_id <= self.lang.field_count);
        if (index >= limits.max_subtrees) return error.TreeTooDeep;
        const parent: u32 = if (self.owners.items.len > 0) self.owners.items[self.owners.items.len - 1].index else none;
        try self.records.append(self.arena, record(self.lang, node, parent, field_id, status));
        try self.nodes.append(self.arena, node);
        if (self.owners.items.len > 0) {
            const owner = &self.owners.items[self.owners.items.len - 1];
            if (owner.last_child != none) self.records.items[owner.last_child].next_sibling = index;
            owner.last_child = index;
            owner.child_count += 1;
            if (node.isNamed(self.lang)) owner.named_child_count += 1;
        }
        assert(self.records.items.len == self.nodes.items.len);
        if (node.subtree.children.len == 0) return;
        if (self.owners.items.len >= limits.max_tree_depth) return error.TreeTooDeep;
        try self.owners.append(self.arena, .{ .index = index });
        try self.push(node, 0, true);
    }

    fn push(self: *Flattener, node: tree.Node, inherited_field: FieldId, owns: bool) Error!void {
        assert(node.subtree.children.len > 0);
        if (self.frames.items.len >= limits.max_tree_depth) return error.TreeTooDeep;
        try self.frames.append(self.arena, .{
            .subtree = node.subtree,
            .offset = node.offset,
            .fields = fieldMap(self.lang, node.subtree),
            .inherited_field = inherited_field,
            .owns = owns,
        });
        assert(self.frames.items.len <= limits.max_tree_depth);
    }

    /// Write the counts of the owner of a finished frame.
    fn close(self: *Flattener) void {
        const owner = self.owners.items[self.owners.items.len - 1];
        assert(owner.named_child_count <= owner.child_count);
        self.records.items[owner.index].child_count = owner.child_count;
        self.records.items[owner.index].named_child_count = owner.named_child_count;
        self.owners.items.len -= 1;
        assert(self.owners.items.len < limits.max_tree_depth);
    }

    /// Visit the next child of the top frame.
    fn step(self: *Flattener) Error!void {
        const top = &self.frames.items[self.frames.items.len - 1];
        assert(top.child_index < top.subtree.children.len);
        const child = top.subtree.children[top.child_index];
        const structural = top.structural_index;
        const alias = if (child.extra) 0 else language.aliasAt(self.lang, top.subtree.productionId(), top.structural_index);
        const node = tree.Node{ .subtree = child, .offset = top.offset, .alias = alias };
        // `ts_tree_cursor_current_field_id`: the field of the nearest level,
        // up to the visible parent. An extra node stops the search.
        var field_id: FieldId = 0;
        if (!child.extra) {
            field_id = ownField(top.fields, top.structural_index);
            if (field_id == 0) field_id = top.inherited_field;
        }
        top.offset = st.addLength(top.offset, child.totalSize());
        top.child_index += 1;
        if (!child.extra) top.structural_index += 1;
        assert(top.child_index <= top.subtree.children.len);
        const own: FieldId = if (child.extra) 0 else ownField(top.fields, structural);
        if (node.isVisible()) return self.emit(node, field_id, statusOf(top, own, structural));
        if (child.children.len == 0) return;
        const chain = try self.chainFor(top, own, child.extra, structural);
        try self.push(node, field_id, false);
        const frame = &self.frames.items[self.frames.items.len - 1];
        frame.chain_field = chain.field;
        frame.chain_can_later = chain.can_later;
        frame.later_above = chain.later_above;
    }

    /// The status of a visible child of `top` with field `own` at
    /// `structural`. Without its own field, the node takes the field of the
    /// nearest hidden level.
    fn statusOf(top: *const Frame, own: FieldId, structural: u32) Status {
        assert(structural <= top.subtree.children.len);
        if (own == 0) return .{ .field_id = top.chain_field, .can_later = top.chain_can_later };
        assert(top.chain_field == 0 or !top.owns);
        return .{ .field_id = own, .can_later = laterEntry(top.fields, own, structural) or hasBit(top.later_above, own) };
    }

    /// The chain values of a hidden child of `top`.
    fn chainFor(self: *Flattener, top: *const Frame, own: FieldId, extra: bool, structural: u32) Error!struct { field: FieldId, can_later: bool, later_above: []const u64 } {
        assert(structural <= top.subtree.children.len);
        var later = top.later_above;
        if (!extra) {
            var added = false;
            const words = @as(usize, self.lang.field_count) / 64 + 1;
            var set: []u64 = &.{};
            for (top.fields) |entry| {
                if (entry.child_index <= structural or hasBit(later, entry.field_id)) continue;
                if (!added) {
                    set = try self.arena.alloc(u64, words);
                    @memset(set, 0);
                    @memcpy(set[0..later.len], later);
                    added = true;
                }
                set[entry.field_id / 64] |= @as(u64, 1) << @intCast(entry.field_id % 64);
            }
            if (added) later = set;
        }
        assert(later.len <= @as(usize, self.lang.field_count) / 64 + 1);
        if (own != 0) return .{ .field = own, .can_later = hasBit(later, own), .later_above = later };
        return .{ .field = top.chain_field, .can_later = top.chain_can_later, .later_above = later };
    }

    /// Walk the tree under `root` and add a record for each visible node.
    fn walk(self: *Flattener, root: *const Subtree) Error!void {
        assert(self.records.items.len == 0);
        try self.emit(tree.rootNode(root), 0, .{});
        var steps: usize = 0;
        while (self.frames.items.len > 0) : (steps += 1) {
            assert(steps <= limits.max_subtrees * 2);
            const top = self.frames.items[self.frames.items.len - 1];
            if (top.child_index < top.subtree.children.len) {
                try self.step();
                continue;
            }
            self.frames.items.len -= 1;
            if (top.owns) self.close();
        }
        assert(self.owners.items.len == 0);
    }
};

/// The number of records that `flatten` gives.
pub const Counts = struct { nodes: usize, overrides: usize };

/// Write the visible nodes of `root` in pre-order to `out`, and the field
/// overrides of the tree to `overrides`. Write each array up to its length.
/// Return the full counts, which are more than the lengths when an array is
/// too small. A link in a record can name a record that does not fit.
pub fn flatten(arena: std.mem.Allocator, lang: *const Language, root: *const Subtree, out: []Node, overrides: []FieldOverride) Error!Counts {
    assert(lang.symbol_count > 0);
    assert(out.len <= limits.max_subtrees);
    var f = Flattener{ .arena = arena, .lang = lang };
    try f.walk(root);
    const records = f.records.items;
    const n = @min(out.len, records.len);
    @memcpy(out[0..n], records[0..n]);
    var o = Overrider{ .arena = arena, .lang = lang, .records = records, .nodes = f.nodes.items, .out = overrides };
    try o.run();
    assert(o.count <= records.len * (lang.field_count + 1));
    return .{ .nodes = records.len, .overrides = o.count };
}

/// A field lookup that the first-child rule does not give
/// (`ztree_field_override`): `ts_node_child_by_field_id(node, field_id)`
/// gives `child`, or `none`.
pub const FieldOverride = extern struct {
    node: u32,
    child: u32,
    field_id: FieldId,
    reserved: u16 = 0,
};

comptime {
    assert(@sizeOf(FieldOverride) == 12);
}

/// The children of a node, with their aliases and positions
/// (`ts_node_iterate_children`).
const ChildIterator = struct {
    parent: tree.Node,
    child_index: u32 = 0,
    structural_index: u32 = 0,
    offset: Length,

    fn init(parent: tree.Node) ChildIterator {
        assert(parent.subtree.children.len > 0);
        assert(parent.offset.bytes <= limits.max_source_bytes);
        return .{ .parent = parent, .offset = parent.offset };
    }

    /// The next child and its structural index, or null at the end. An
    /// extra child has no structural index.
    fn next(self: *ChildIterator, lang: *const Language) ?struct { tree.Node, ?u32 } {
        const children = self.parent.subtree.children;
        assert(self.child_index <= children.len);
        if (self.child_index == children.len) return null;
        const child = children[self.child_index];
        self.child_index += 1;
        const offset = self.offset;
        self.offset = st.addLength(self.offset, child.totalSize());
        if (child.extra) return .{ .{ .subtree = child, .offset = offset, .alias = 0 }, null };
        const index = self.structural_index;
        self.structural_index += 1;
        const alias = language.aliasAt(lang, self.parent.subtree.productionId(), index);
        assert(self.structural_index <= children.len);
        return .{ .{ .subtree = child, .offset = offset, .alias = alias }, index };
    }
};

/// The entries of a field map for one field id. The entries are sorted by
/// field id.
fn entriesFor(fields: []const abi.FieldMapEntry, field_id: FieldId) []const abi.FieldMapEntry {
    assert(field_id > 0);
    var lo: usize = 0;
    while (lo < fields.len and fields[lo].field_id < field_id) lo += 1;
    var hi = lo;
    while (hi < fields.len and fields[hi].field_id == field_id) hi += 1;
    assert(lo <= hi);
    return fields[lo..hi];
}

/// One level of `childByField`: a node and its entries for the field.
const LookupFrame = struct {
    it: ChildIterator,
    entries: []const abi.FieldMapEntry,
};

/// The field override pass. For each node, it runs the algorithm of
/// `ts_node_child_by_field_id` for each field of the node and of its
/// children, and writes each result that the first-child rule does not give.
const Overrider = struct {
    arena: std.mem.Allocator,
    lang: *const Language,
    records: []const Node,
    nodes: []const tree.Node,
    out: []FieldOverride,
    count: usize = 0,
    index: std.AutoHashMapUnmanaged(*const Subtree, u32) = .empty,
    stack: std.ArrayList(LookupFrame) = .empty,

    fn run(self: *Overrider) Error!void {
        assert(self.records.len == self.nodes.len);
        try self.index.ensureTotalCapacity(self.arena, @intCast(self.nodes.len));
        for (self.nodes, 0..) |node, i| {
            const entry = self.index.getOrPutAssumeCapacity(node.subtree);
            assert(!entry.found_existing);
            entry.value_ptr.* = @intCast(i);
        }
        const seen = try self.arena.alloc(bool, self.lang.field_count + 1);
        for (self.records, 0..) |rec, i| {
            if (rec.child_count == 0) continue;
            @memset(seen, false);
            for (fieldMap(self.lang, self.nodes[i].subtree)) |entry| {
                if (seen[entry.field_id]) continue;
                seen[entry.field_id] = true;
                try self.check(@intCast(i), entry.field_id);
            }
            var c: u32 = @intCast(i + 1);
            while (c != none) : (c = self.records[c].next_sibling) {
                const f = self.records[c].field_id;
                if (f == 0 or seen[f]) continue;
                seen[f] = true;
                try self.check(@intCast(i), f);
            }
        }
        assert(self.index.count() == self.nodes.len);
    }

    /// Compare the reference lookup with the first-child rule for one node
    /// and one field. Write an override when they differ.
    fn check(self: *Overrider, node: u32, field_id: FieldId) Error!void {
        assert(self.records[node].child_count > 0);
        var first: u32 = none;
        var c: u32 = node + 1;
        while (c != none) : (c = self.records[c].next_sibling) {
            if (self.records[c].field_id == field_id) {
                first = c;
                break;
            }
        }
        const found = try self.childByField(self.nodes[node], field_id);
        const ref: u32 = if (found) |n| self.index.get(n.subtree).? else none;
        if (ref == first) return;
        if (self.count < self.out.len) self.out[self.count] = .{ .node = node, .child = ref, .field_id = field_id };
        self.count += 1;
        assert(self.count <= limits.max_subtrees * 2);
    }

    /// The frame of `node` for `field_id`, or null when the node has no
    /// entries for the field: the reference then returns null.
    fn frameFor(self: *Overrider, node: tree.Node, field_id: FieldId) ?LookupFrame {
        assert(field_id > 0);
        if (node.subtree.children.len == 0) return null;
        const entries = entriesFor(fieldMap(self.lang, node.subtree), field_id);
        if (entries.len == 0) return null;
        assert(entries[0].field_id == field_id);
        return .{ .it = ChildIterator.init(node), .entries = entries };
    }

    fn push(self: *Overrider, frame: LookupFrame) Error!void {
        assert(frame.entries.len > 0);
        if (self.stack.items.len >= limits.max_tree_depth) return error.TreeTooDeep;
        try self.stack.append(self.arena, frame);
        assert(self.stack.items.len <= limits.max_tree_depth);
    }

    /// The top frame gives null. The frame below then tries its next entry,
    /// as the reference does after a recursive call, and gives null when it
    /// has no next entry.
    fn fail(self: *Overrider) void {
        var steps: usize = 0;
        while (self.stack.items.len > 0) : (steps += 1) {
            assert(steps <= limits.max_tree_depth);
            self.stack.items.len -= 1;
            if (self.stack.items.len == 0) return;
            const below = &self.stack.items[self.stack.items.len - 1];
            assert(below.entries.len > 0);
            below.entries = below.entries[1..];
            if (below.entries.len > 0) return;
        }
    }

    /// `ts_node_child_by_field_id`, with an explicit stack in place of its
    /// recursion.
    fn childByField(self: *Overrider, start: tree.Node, field_id: FieldId) Error!?tree.Node {
        assert(field_id > 0 and field_id <= self.lang.field_count);
        self.stack.items.len = 0;
        try self.push(self.frameFor(start, field_id) orelse return null);
        var steps: usize = 0;
        while (self.stack.items.len > 0) : (steps += 1) {
            assert(steps <= limits.max_subtrees * 2);
            const top = &self.stack.items[self.stack.items.len - 1];
            const child, const structural = top.it.next(self.lang) orelse {
                self.fail();
                continue;
            };
            const index = structural orelse continue;
            const entry = top.entries[0];
            if (index < entry.child_index) continue;
            if (entry.inherited) {
                const inner = self.frameFor(child, field_id);
                if (top.entries.len == 1) {
                    // The last entry is a tail call: the child replaces the frame.
                    if (inner) |frame| top.* = frame else self.fail();
                } else if (inner) |frame| {
                    try self.push(frame);
                } else {
                    top.entries = top.entries[1..];
                }
                continue;
            }
            if (child.isVisible()) return child;
            if (child.subtree.children.len > 0 and child.subtree.visible_child_count > 0) return self.firstChild(child);
            top.entries = top.entries[1..];
            if (top.entries.len == 0) self.fail();
        }
        return null;
    }

    /// `ts_node_child(node, 0)`: the first visible descendant through hidden
    /// nodes. The node has a visible child.
    fn firstChild(self: *Overrider, node: tree.Node) tree.Node {
        assert(node.subtree.visible_child_count > 0);
        var it = ChildIterator.init(node);
        var steps: usize = 0;
        while (it.next(self.lang)) |next| : (steps += 1) {
            assert(steps <= limits.max_subtrees);
            const child = next[0];
            if (child.isVisible()) return child;
            if (child.subtree.children.len > 0 and child.subtree.visible_child_count > 0) it = ChildIterator.init(child);
        }
        unreachable;
    }
};

/// A node that `writeSexp` has opened.
const SexpEntry = struct {
    index: u32,
    /// True when the S-expression shows the node.
    shown: bool,
    /// The field name that the children of a node that is not shown inherit.
    field_id: FieldId,
};

/// The name of a field id. The id is in range.
fn fieldName(lang: *const Language, field_id: FieldId) []const u8 {
    assert(field_id > 0);
    assert(field_id <= lang.field_count);
    return std.mem.span(lang.field_names.?[field_id].?);
}

/// Write the opening of record `index`, as `tree.writeVisibleSexp` writes it.
fn writeOpen(lang: *const Language, nodes: []const Node, source: []const u8, entry: SexpEntry, w: *std.Io.Writer) std.Io.Writer.Error!void {
    const n = nodes[entry.index];
    const name = tree.symbolName(lang, n.symbol);
    assert(n.end_byte <= source.len);
    assert(entry.index < nodes.len);
    if (entry.index == 0 and !entry.shown) {
        if (n.child_count > 0) try w.print("({s}", .{name}) else try w.print("(\"{s}\")", .{name});
        return;
    }
    if (!entry.shown) return;
    if (entry.index > 0) {
        try w.writeByte(' ');
        if (entry.field_id != 0) try w.print("{s}: ", .{fieldName(lang, entry.field_id)});
    }
    if (n.flags & flag_error != 0 and n.child_count == 0 and n.end_byte > n.start_byte) {
        try w.writeAll("(UNEXPECTED ");
        try writeChar(source[n.start_byte..n.end_byte], w);
    } else if (n.flags & flag_missing != 0) {
        if (n.isNamed()) try w.print("(MISSING {s}", .{name}) else try w.print("(MISSING \"{s}\"", .{name});
    } else {
        try w.print("({s}", .{name});
    }
}

/// Write the first character of the text of an ERROR leaf.
fn writeChar(text: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    assert(text.len > 0);
    const d = utf8.decode(text);
    assert(d.len <= 4);
    const cp = d.code_point;
    switch (cp) {
        -1 => try w.writeAll("INVALID"),
        0 => try w.writeAll("'\\0'"),
        '\n' => try w.writeAll("'\\n'"),
        '\t' => try w.writeAll("'\\t'"),
        '\r' => try w.writeAll("'\\r'"),
        0x20...0x7e => try w.print("'{c}'", .{@as(u8, @intCast(cp))}),
        else => try w.print("{d}", .{cp}),
    }
}

/// Write the S-expression of a flat tree, as `tree.writeVisibleSexp` writes
/// the tree. The source gives the first character of each ERROR leaf.
pub fn writeSexp(arena: std.mem.Allocator, lang: *const Language, nodes: []const Node, source: []const u8, w: *std.Io.Writer) (Error || std.Io.Writer.Error)!void {
    assert(nodes.len > 0);
    assert(nodes[0].parent == none);
    var stack: std.ArrayList(SexpEntry) = .empty;
    for (nodes, 0..) |n, i| {
        // Close each open node that is not the parent of this node.
        while (stack.items.len > 0 and stack.items[stack.items.len - 1].index != n.parent) {
            if (stack.items[stack.items.len - 1].shown) try w.writeByte(')');
            stack.items.len -= 1;
        }
        var entry = SexpEntry{ .index = @intCast(i), .shown = n.isNamed() or n.flags & flag_missing != 0, .field_id = 0 };
        if (n.flags & flag_extra == 0 and i > 0) {
            const up = stack.items[stack.items.len - 1];
            entry.field_id = if (n.field_id != 0) n.field_id else if (!up.shown) up.field_id else 0;
        }
        try writeOpen(lang, nodes, source, entry, w);
        if (stack.items.len >= limits.max_tree_depth) return error.TreeTooDeep;
        try stack.append(arena, entry);
    }
    var steps: usize = 0;
    while (stack.items.len > 0) : (steps += 1) {
        assert(steps <= nodes.len);
        if (stack.items[stack.items.len - 1].shown) try w.writeByte(')');
        stack.items.len -= 1;
    }
}

fn testFlatten(arena: std.mem.Allocator, lang: *const Language, source: []const u8) ![]Node {
    const parser = @import("parser.zig");
    const root = try parser.parse(arena, lang, source);
    const n = (try flatten(arena, lang, root, &.{}, &.{})).nodes;
    const nodes = try arena.alloc(Node, n);
    try std.testing.expectEqual(n, (try flatten(arena, lang, root, nodes, &.{})).nodes);
    var ours: std.Io.Writer.Allocating = .init(arena);
    try writeSexp(arena, lang, nodes, source, &ours.writer);
    var want: std.Io.Writer.Allocating = .init(arena);
    try tree.writeVisibleSexp(arena, lang, root, source, &want.writer);
    try std.testing.expectEqualStrings(want.written(), ours.written());
    return nodes;
}

test "flatten writes the visible nodes in pre-order with their links" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const grammars = @import("grammars.zig");
    const lang = grammars.language(.go);
    const src = "package p\n\nfunc f(a int) {}\n";
    const nodes = try testFlatten(arena_state.allocator(), lang, src);
    const root = nodes[0];
    try std.testing.expectEqualStrings("source_file", tree.symbolName(lang, root.symbol));
    try std.testing.expectEqual(none, root.parent);
    try std.testing.expectEqual(@as(u32, 0), nodes[1].parent);
    // The second child of the root is the function, after `package p` and its newline.
    var i: u32 = 1;
    var children: u32 = 0;
    while (i != none) : (i = nodes[i].next_sibling) children += 1;
    try std.testing.expectEqual(root.child_count, children);
    var fn_index: u32 = 1;
    while (!std.mem.eql(u8, "function_declaration", tree.symbolName(lang, nodes[fn_index].symbol))) fn_index = nodes[fn_index].next_sibling;
    const fn_node = nodes[fn_index];
    try std.testing.expectEqual(@as(u32, 2), fn_node.start_row);
    try std.testing.expectEqualStrings("func f(a int) {}", src[fn_node.start_byte..fn_node.end_byte]);
    // `func` is anonymous, `f` is the field `name`.
    try std.testing.expect(!nodes[fn_index + 1].isNamed());
    try std.testing.expectEqualStrings("name", fieldName(lang, nodes[fn_index + 2].field_id));
    try std.testing.expectEqual(fn_index, nodes[fn_index + 2].parent);
}

test "flatten reports errors and missing nodes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const grammars = @import("grammars.zig");
    const nodes = try testFlatten(arena_state.allocator(), grammars.language(.c), "int x = 1 int y;\n");
    try std.testing.expect(nodes[0].flags & flag_has_error != 0);
    try std.testing.expect((try testFlatten(arena_state.allocator(), grammars.language(.python), "def f(:\n  $\n")).len > 1);
    try std.testing.expect((try testFlatten(arena_state.allocator(), grammars.language(.rust), "fn f() { let x = ; }\n")).len > 1);
}

test "flatten counts the nodes when the buffer is too small" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const grammars = @import("grammars.zig");
    const parser = @import("parser.zig");
    const lang = grammars.language(.go);
    const root = try parser.parse(arena, lang, "package p\nvar x = 1\n");
    var all: [64]Node = undefined;
    const n = (try flatten(arena, lang, root, &all, &.{})).nodes;
    var few: [3]Node = undefined;
    try std.testing.expectEqual(n, (try flatten(arena, lang, root, &few, &.{})).nodes);
    try std.testing.expect(n > few.len);
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(all[1..3]), std.mem.sliceAsBytes(few[1..3]));
}
