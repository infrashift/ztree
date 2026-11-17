//! The finished tree: nodes, a walker over the visible nodes, and the
//! S-expression output of the reference runtime (`ts_node_string`). Each
//! walk uses an explicit stack, because repetition subtrees stay deep on the
//! left side (ADR-0005).

const std = @import("std");
const assert = std.debug.assert;
const abi = @import("abi.zig");
const language = @import("language.zig");
const length = @import("length.zig");
const st = @import("subtree.zig");
const limits = @import("root.zig").limits;

const Language = abi.Language14;
const Symbol = abi.Symbol;
const Length = length.Length;
const Subtree = st.Subtree;

pub const Error = error{ OutOfMemory, TreeTooDeep };

/// The name of `symbol` (`ts_language_symbol_name`).
pub fn symbolName(lang: *const Language, symbol: Symbol) []const u8 {
    assert(lang.symbol_names != null);
    if (symbol == abi.builtin_sym_error) return "ERROR";
    if (symbol == language.builtin_sym_error_repeat) return "_ERROR";
    assert(symbol < lang.symbol_count + lang.alias_count);
    return std.mem.span(abi.symbolName(lang, symbol));
}

/// One node of the finished tree (`TSNode`).
pub const Node = struct {
    subtree: *const Subtree,
    /// The position of the start of the padding of the node.
    offset: Length,
    /// The alias of the node in its parent production, or 0.
    alias: Symbol,

    pub fn symbol(self: Node) Symbol {
        assert(self.offset.bytes <= limits.max_source_bytes);
        assert(self.subtree.children.len <= limits.max_subtrees);
        return if (self.alias != 0) self.alias else self.subtree.symbol;
    }

    pub fn kind(self: Node, lang: *const Language) []const u8 {
        assert(lang.symbol_names != null);
        assert(self.subtree.children.len <= limits.max_subtrees);
        return symbolName(lang, self.symbol());
    }

    pub fn isNamed(self: Node, lang: *const Language) bool {
        assert(lang.symbol_metadata != null);
        assert(self.subtree.named_child_count <= self.subtree.visible_child_count);
        if (self.alias != 0) return language.symbolMetadata(lang, self.alias).named;
        return self.subtree.named;
    }

    /// True for a node that the reference cursor reports (`ts_node__is_relevant`
    /// with anonymous nodes).
    pub fn isVisible(self: Node) bool {
        assert(self.subtree.children.len <= limits.max_subtrees);
        assert(self.offset.bytes <= limits.max_source_bytes);
        return self.subtree.visible or self.alias != 0;
    }

    pub fn start(self: Node) Length {
        assert(self.offset.bytes <= limits.max_source_bytes);
        assert(self.subtree.padding.bytes <= limits.max_source_bytes);
        return st.addLength(self.offset, self.subtree.padding);
    }

    pub fn end(self: Node) Length {
        const s = self.start();
        assert(s.bytes <= limits.max_source_bytes);
        assert(self.subtree.size.bytes <= limits.max_source_bytes);
        return st.addLength(s, self.subtree.size);
    }
};

/// The root node of a tree (`ts_tree_root_node`).
pub fn rootNode(root: *const Subtree) Node {
    assert(root.padding.bytes <= limits.max_source_bytes);
    assert(root.children.len <= limits.max_subtrees);
    return .{ .subtree = root, .offset = length.zero, .alias = 0 };
}

const WalkFrame = struct {
    subtree: *const Subtree,
    next_offset: Length,
    child_index: u32 = 0,
    structural_index: u32 = 0,
};

/// A pre-order walk over the root and each visible node. It descends
/// through hidden nodes without reporting them.
pub const Walker = struct {
    arena: std.mem.Allocator,
    lang: *const Language,
    frames: std.ArrayList(WalkFrame) = .empty,
    /// The root before the first call of `next`.
    root: ?Node,
    /// The last node that `next` returned. The next call descends into it.
    pending: ?Node = null,

    pub fn init(arena: std.mem.Allocator, lang: *const Language, root: *const Subtree) Walker {
        assert(lang.symbol_count > 0);
        assert(root.children.len <= limits.max_subtrees);
        return .{ .arena = arena, .lang = lang, .root = rootNode(root) };
    }

    /// Do not visit the children of the node that `next` returned last.
    pub fn skipChildren(self: *Walker) void {
        assert(self.root == null);
        assert(self.frames.items.len <= limits.max_tree_depth);
        self.pending = null;
    }

    fn push(self: *Walker, subtree: *const Subtree, offset: Length) Error!void {
        assert(subtree.children.len > 0);
        if (self.frames.items.len >= limits.max_tree_depth) return error.TreeTooDeep;
        try self.frames.append(self.arena, .{ .subtree = subtree, .next_offset = offset });
        assert(self.frames.items.len <= limits.max_tree_depth);
    }

    /// Return the next node in pre-order, or null at the end. The first call
    /// returns the root.
    pub fn next(self: *Walker) Error!?Node {
        assert(self.frames.items.len <= limits.max_tree_depth);
        if (self.root) |r| {
            self.root = null;
            self.pending = r;
            return r;
        }
        if (self.pending) |p| {
            self.pending = null;
            if (p.subtree.children.len > 0) try self.push(p.subtree, p.offset);
        }
        var steps: usize = 0;
        while (self.frames.items.len > 0) : (steps += 1) {
            assert(steps <= limits.max_subtrees * 2);
            const top = &self.frames.items[self.frames.items.len - 1];
            if (top.child_index >= top.subtree.children.len) {
                self.frames.items.len -= 1;
                continue;
            }
            const child = top.subtree.children[top.child_index];
            const alias = if (child.extra) 0 else language.aliasAt(self.lang, top.subtree.productionId(), top.structural_index);
            const node = Node{ .subtree = child, .offset = top.next_offset, .alias = alias };
            top.next_offset = st.addLength(top.next_offset, child.totalSize());
            top.child_index += 1;
            if (!child.extra) top.structural_index += 1;
            if (node.isVisible()) {
                self.pending = node;
                return node;
            }
            if (child.children.len > 0) try self.push(child, node.offset);
        }
        return null;
    }
};

const SexpFrame = struct {
    subtree: *const Subtree,
    alias_symbol: Symbol,
    alias_is_named: bool,
    field_name: ?[]const u8,
    is_root: bool,
    pre_written: bool = false,
    is_visible: bool = false,
    child_index: u32 = 0,
    structural_child_index: u32 = 0,
    fields: []const abi.FieldMapEntry = &.{},
};

/// Write `root` as the reference `ts_node_string` writes it
/// (`ts_subtree__write_to_string` without hidden nodes).
pub fn writeSexp(arena: std.mem.Allocator, lang: *const Language, root: *const Subtree, w: *std.Io.Writer) (Error || std.Io.Writer.Error)!void {
    var stack: std.ArrayList(SexpFrame) = .empty;
    try stack.append(arena, .{ .subtree = root, .alias_symbol = 0, .alias_is_named = false, .field_name = null, .is_root = true });
    var steps: usize = 0;
    while (stack.items.len > 0) : (steps += 1) {
        assert(steps <= limits.max_subtrees * 3);
        const frame = &stack.items[stack.items.len - 1];
        if (!frame.pre_written) try writeOpen(lang, frame, w);
        if (frame.child_index < frame.subtree.children.len) {
            const child_frame = childFrame(lang, frame);
            if (stack.items.len >= limits.max_tree_depth) return error.TreeTooDeep;
            try stack.append(arena, child_frame);
            continue;
        }
        if (frame.is_visible) try w.writeByte(')');
        stack.items.len -= 1;
    }
    assert(stack.items.len == 0);
}

/// The field map entries of a production (`ts_language_field_map`).
fn fieldMap(lang: *const Language, production_id: u16) []const abi.FieldMapEntry {
    if (lang.field_count == 0) return &.{};
    assert(production_id < lang.production_id_count);
    const slice = lang.field_map_slices.?[production_id];
    assert(lang.field_map_entries != null);
    return lang.field_map_entries.?[slice.index..][0..slice.length];
}

/// Write the opening of a frame: the name of a visible node.
fn writeOpen(lang: *const Language, frame: *SexpFrame, w: *std.Io.Writer) (Error || std.Io.Writer.Error)!void {
    const node = frame.subtree;
    assert(!frame.pre_written);
    assert(node.children.len <= limits.max_subtrees);
    const is_visible = node.is_missing or
        (if (frame.alias_symbol != 0) frame.alias_is_named else node.visible and node.named);
    const symbol = if (frame.alias_symbol != 0) frame.alias_symbol else node.symbol;
    const name = symbolName(lang, symbol);
    if (is_visible) {
        if (!frame.is_root) {
            try w.writeByte(' ');
            if (frame.field_name) |f| try w.print("{s}: ", .{f});
        }
        if (node.isError() and node.children.len == 0 and node.size.bytes > 0) {
            try w.writeAll("(UNEXPECTED ");
            try writeChar(node.lookahead_char, w);
        } else if (node.is_missing) {
            if (frame.alias_is_named or node.named) try w.print("(MISSING {s}", .{name}) else try w.print("(MISSING \"{s}\"", .{name});
        } else {
            try w.print("({s}", .{name});
        }
    } else if (frame.is_root) {
        if (node.children.len > 0) try w.print("({s}", .{name}) else if (node.named) try w.print("({s})", .{name}) else try w.print("(\"{s}\")", .{name});
    }
    if (node.children.len > 0) frame.fields = fieldMap(lang, node.production_id);
    frame.is_visible = is_visible;
    frame.pre_written = true;
}

/// The frame of the next child of `frame`, with its alias and field name.
fn childFrame(lang: *const Language, frame: *SexpFrame) SexpFrame {
    const child = frame.subtree.children[frame.child_index];
    assert(frame.pre_written);
    frame.child_index += 1;
    var result = SexpFrame{ .subtree = child, .alias_symbol = 0, .alias_is_named = false, .field_name = null, .is_root = false };
    if (child.extra) return result;
    const alias = language.aliasAt(lang, frame.subtree.productionId(), frame.structural_child_index);
    result.alias_symbol = alias;
    result.alias_is_named = alias != 0 and language.symbolMetadata(lang, alias).named;
    result.field_name = if (frame.is_visible) null else frame.field_name;
    for (frame.fields) |entry| {
        if (!entry.inherited and entry.child_index == frame.structural_child_index) {
            result.field_name = std.mem.span(lang.field_names.?[entry.field_id].?);
            break;
        }
    }
    frame.structural_child_index += 1;
    assert(frame.child_index <= frame.subtree.children.len);
    return result;
}

/// Write the first character of an ERROR leaf (`ts_subtree__write_char_to_string`).
fn writeChar(chr: i32, w: *std.Io.Writer) std.Io.Writer.Error!void {
    assert(chr >= -1);
    assert(chr <= 0x10ffff);
    switch (chr) {
        -1 => try w.writeAll("INVALID"),
        0 => try w.writeAll("'\\0'"),
        '\n' => try w.writeAll("'\\n'"),
        '\t' => try w.writeAll("'\\t'"),
        '\r' => try w.writeAll("'\\r'"),
        0x20...0x7e => try w.print("'{c}'", .{@as(u8, @intCast(chr))}),
        else => try w.print("{d}", .{chr}),
    }
}

test "writeChar prints the first character of an ERROR leaf as the reference does" {
    const cases = [_]struct { i32, []const u8 }{
        .{ -1, "INVALID" }, .{ 0, "'\\0'" }, .{ '\n', "'\\n'" }, .{ '\t', "'\\t'" }, .{ '\r', "'\\r'" },
        .{ 'a', "'a'" },    .{ ' ', "' '" }, .{ 0x7f, "127" },   .{ 0x1b, "27" },    .{ 0xe9, "233" },
    };
    for (cases) |c| {
        var buf: [16]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        try writeChar(c[0], &w);
        try std.testing.expectEqualStrings(c[1], w.buffered());
    }
}
