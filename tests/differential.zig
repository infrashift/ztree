//! Shared differential checks against the reference runtime: a node-by-node
//! dump, the S-expression, the visible-node walk and the comment spans. The
//! reference balances repetitions and ztree does not (ADR-0005), so both
//! dumps flatten hidden repetition nodes.

const std = @import("std");
const ztree = @import("ztree");
const abi = ztree.abi;
const grammars = ztree.grammars;
const Subtree = ztree.subtree.Subtree;
const Length = ztree.length.Length;

const NodeRecord = extern struct {
    symbol: u16,
    parse_state: u16,
    production_id: u16,
    flags: u16,
    padding: Length,
    size: Length,
    lookahead_bytes: u32,
    child_count: u32,
    error_cost: u32,
    dynamic_precedence: i32,
    visible_child_count: u32,
    named_child_count: u32,
    visible_descendant_count: u32,
};

extern fn ztree_ref_sexp(lang: *const abi.Language14, src: [*]const u8, len: u32, out: [*]u8, cap: u32) u32;
extern fn ztree_ref_comments(lang: *const abi.Language14, src: [*]const u8, len: u32, kinds: [*]const [*:0]const u8, kind_count: u32, out: [*]ztree.comments.Span, cap: u32) u32;

const Visit = extern struct { type: [*:0]const u8, start_byte: u32, end_byte: u32, named: bool };
extern fn ztree_ref_nodes(lang: *const abi.Language14, src: [*]const u8, len: u32, out: [*]Visit, cap: u32) u32;

/// Compare the walker with a TSTreeCursor walk: type, byte range and named flag.
fn compareWalk(arena: std.mem.Allocator, lang: *const abi.Language14, name: []const u8, text: []const u8, root: *const Subtree) !void {
    const ref = try arena.alloc(Visit, 1 << 20);
    const n = ztree_ref_nodes(lang, text.ptr, @intCast(text.len), ref.ptr, @intCast(ref.len));
    try std.testing.expect(n <= ref.len);
    var walker = ztree.tree.Walker.init(arena, lang, root);
    var i: usize = 0;
    while (try walker.next()) |node| : (i += 1) {
        if (i >= n) break;
        const r = ref[i];
        const same = std.mem.eql(u8, std.mem.span(r.type), node.kind(lang)) and r.start_byte == node.start().bytes and
            r.end_byte == node.end().bytes and r.named == node.isNamed(lang);
        if (!same) {
            std.debug.print("{s}: node {d} differs: ref {s} {d}..{d} named={}, ztree {s} {d}..{d} named={}\n", .{ name, i, r.type, r.start_byte, r.end_byte, r.named, node.kind(lang), node.start().bytes, node.end().bytes, node.isNamed(lang) });
            return error.TestUnexpectedResult;
        }
    }
    if (i != n) {
        std.debug.print("{s}: ref visits {d} nodes, ztree visits {d} or more\n", .{ name, n, i });
        return error.TestUnexpectedResult;
    }
}

extern fn ztree_ref_parse_dump(lang: *const abi.Language14, src: [*]const u8, len: u32, out: [*]NodeRecord, cap: u32, has_error: *bool) u32;

fn flatChildCount(t: *const Subtree) u32 {
    var n: u32 = 0;
    for (t.children) |c| n += if (c.isRepetition()) flatChildCount(c) else 1;
    return n;
}

fn record(t: *const Subtree) NodeRecord {
    const parent = t.children.len > 0;
    var flags: u16 = 0;
    const bits = [_]bool{ t.visible, t.named, t.extra, t.is_missing, t.is_keyword, t.fragile_left, t.fragile_right, t.depends_on_column, t.has_external_tokens };
    for (bits, 0..) |b, i| flags |= @as(u16, @intFromBool(b)) << @intCast(i);
    return .{
        .symbol = t.symbol,
        .parse_state = t.parse_state,
        .production_id = t.productionId(),
        .flags = flags,
        .padding = t.padding,
        .size = t.size,
        .lookahead_bytes = t.lookahead_bytes,
        .child_count = flatChildCount(t),
        .error_cost = t.errorCost(),
        .dynamic_precedence = t.dynamicPrecedence(),
        .visible_child_count = if (parent) t.visible_child_count else 0,
        .named_child_count = if (parent) t.named_child_count else 0,
        .visible_descendant_count = t.visibleDescendantCount(),
    };
}

fn dump(t: *const Subtree, out: *std.ArrayList(NodeRecord), gpa: std.mem.Allocator) error{OutOfMemory}!void {
    try out.append(gpa, record(t));
    try dumpChildren(t, out, gpa);
}

fn dumpChildren(t: *const Subtree, out: *std.ArrayList(NodeRecord), gpa: std.mem.Allocator) error{OutOfMemory}!void {
    for (t.children) |c| {
        if (c.isRepetition()) try dumpChildren(c, out, gpa) else try dump(c, out, gpa);
    }
}

pub const Totals = struct { compared: usize = 0, with_errors: usize = 0, comments: usize = 0, nodes: usize = 0, field_children: usize = 0, overrides: usize = 0, last_had_error: bool = false };

const FlatNode = ztree.flat.Node;
const none = ztree.flat.none;
const RefLinks = extern struct { parent: u32, next_sibling: u32, prev_sibling: u32, next_named_sibling: u32, prev_named_sibling: u32, children_ok: u32 };
const RefFieldChild = extern struct { node: u32, field_id: u32, child: u32 };
extern fn ztree_ref_flat(lang: *const abi.Language14, src: [*]const u8, len: u32, recs: [*]FlatNode, links: [*]RefLinks, cap: u32, fields: [*]RefFieldChild, field_cap: u32, field_count: *u32) u32;

/// The links of node `i` of a flat tree, as the Go binding finds them. The
/// reference finds the next sibling by byte position, so it skips each
/// sibling that ends where node `i` ends: an empty node such as a MISSING
/// node.
fn flatLinks(nodes: []const FlatNode, i: u32) RefLinks {
    var links = RefLinks{ .parent = nodes[i].parent, .next_sibling = none, .prev_sibling = none, .next_named_sibling = none, .prev_named_sibling = none, .children_ok = 1 };
    var next = nodes[i].next_sibling;
    while (next != none and nodes[next].end_byte <= nodes[i].end_byte) next = nodes[next].next_sibling;
    links.next_sibling = next;
    while (next != none and !nodes[next].isNamed()) next = nodes[next].next_sibling;
    links.next_named_sibling = next;
    if (nodes[i].parent == none) return links;
    var c = nodes[i].parent + 1;
    while (c != i) : (c = nodes[c].next_sibling) {
        links.prev_sibling = c;
        if (nodes[c].isNamed()) links.prev_named_sibling = c;
    }
    return links;
}

/// Compare the flat tree with the TSNode API of the reference: each record,
/// the parent and the siblings of each node, the children, and the result
/// of `ts_node_child_by_field_id` for each node and each field (ISSUE-011).
fn compareFlat(gpa: std.mem.Allocator, arena: std.mem.Allocator, lang: *const abi.Language14, name: []const u8, text: []const u8, root: *const Subtree, totals: *Totals) !void {
    const counts = try ztree.flat.flatten(arena, lang, root, &.{}, &.{});
    const count = counts.nodes;
    const ours = try arena.alloc(FlatNode, count);
    const overrides = try arena.alloc(ztree.flat.FieldOverride, counts.overrides);
    try std.testing.expectEqual(counts, try ztree.flat.flatten(arena, lang, root, ours, overrides));
    var sexp: std.Io.Writer.Allocating = .init(gpa);
    defer sexp.deinit();
    try ztree.flat.writeSexp(arena, lang, ours, text, &sexp.writer);
    var want: std.Io.Writer.Allocating = .init(gpa);
    defer want.deinit();
    try ztree.tree.writeVisibleSexp(arena, lang, root, text, &want.writer);
    if (!std.mem.eql(u8, want.written(), sexp.written())) {
        const a = want.written();
        const b = sexp.written();
        const at = std.mem.indexOfDiff(u8, a, b).?;
        const from = at -| 200;
        std.debug.print("{s}: the S-expression of the flat tree differs at {d}\n tree {s}\n flat {s}\n", .{ name, at, a[from..@min(a.len, at + 80)], b[from..@min(b.len, at + 80)] });
        return error.TestUnexpectedResult;
    }
    const cap: u32 = @intCast(count + 1);
    const ref = try arena.alloc(FlatNode, cap);
    const links = try arena.alloc(RefLinks, cap);
    const fields = try arena.alloc(RefFieldChild, cap * 4);
    var field_count: u32 = 0;
    const n = ztree_ref_flat(lang, text.ptr, @intCast(text.len), ref.ptr, links.ptr, cap, fields.ptr, @intCast(fields.len), &field_count);
    if (n != count) {
        std.debug.print("{s}: the reference has {d} nodes, the flat tree has {d}\n", .{ name, n, count });
        return error.TestUnexpectedResult;
    }
    for (ref[0..n], ours, links[0..n], 0..) |r, o, l, i| {
        const fl = flatLinks(ours, @intCast(i));
        if (std.meta.eql(r, o) and std.meta.eql(l, fl)) continue;
        std.debug.print("{s}: flat node {d} ({s}) differs\n ref   {any}\n       {any}\n ztree {any}\n       {any}\n", .{ name, i, ztree.tree.symbolName(lang, r.symbol), r, l, o, fl });
        if (o.next_sibling != none) std.debug.print(" next: {s} {any}\n", .{ ztree.tree.symbolName(lang, ours[o.next_sibling].symbol), ours[o.next_sibling] });
        return error.TestUnexpectedResult;
    }
    try compareFieldChildren(arena, lang, name, ours, overrides, fields[0..field_count]);
    totals.overrides += overrides.len;
    totals.nodes += n;
    totals.field_children += field_count;
}

/// Compare `ts_node_child_by_field_id` with the lookup of the Go binding:
/// the override of the node and the field, else the first child in the field.
fn compareFieldChildren(arena: std.mem.Allocator, lang: *const abi.Language14, name: []const u8, nodes: []const FlatNode, overrides: []const ztree.flat.FieldOverride, ref: []const RefFieldChild) !void {
    const first = try arena.alloc(u32, lang.field_count + 1);
    var r: usize = 0;
    var o: usize = 0;
    for (nodes, 0..) |node, i| {
        if (node.child_count == 0) continue;
        @memset(first, none);
        var c: u32 = @intCast(i + 1);
        while (c != none) : (c = nodes[c].next_sibling) {
            if (first[nodes[c].field_id] == none) first[nodes[c].field_id] = c;
        }
        // The overrides of a node are adjacent, in node order.
        while (o < overrides.len and overrides[o].node == i) : (o += 1) first[overrides[o].field_id] = overrides[o].child;
        for (first[1..], 1..) |child, f| {
            const want: u32 = if (r < ref.len and ref[r].node == i and ref[r].field_id == f) ref[r].child else none;
            if (want != none) r += 1;
            if (want == child) continue;
            std.debug.print("{s}: node {d} ({s}) field {s}: ref child {d}, ztree child {d}\n", .{ name, i, ztree.tree.symbolName(lang, node.symbol), std.mem.span(lang.field_names.?[f].?), want, child });
            var d: u32 = @intCast(i + 1);
            while (d != none) : (d = nodes[d].next_sibling) std.debug.print("  child {d} {s} field {d} {d}..{d}\n", .{ d, ztree.tree.symbolName(lang, nodes[d].symbol), nodes[d].field_id, nodes[d].start_byte, nodes[d].end_byte });
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expectEqual(ref.len, r);
    try std.testing.expectEqual(overrides.len, o);
}

/// Compare the S-expression of `root` with `ts_node_string` of the reference.
fn compareSexp(gpa: std.mem.Allocator, arena: std.mem.Allocator, lang: *const abi.Language14, name: []const u8, text: []const u8, root: *const Subtree) !void {
    var ours: std.Io.Writer.Allocating = .init(gpa);
    defer ours.deinit();
    try ztree.tree.writeSexp(arena, lang, root, &ours.writer);
    const buf = try gpa.alloc(u8, 1 << 22);
    defer gpa.free(buf);
    const n = ztree_ref_sexp(lang, text.ptr, @intCast(text.len), buf.ptr, @intCast(buf.len));
    try std.testing.expect(n <= buf.len);
    if (!std.mem.eql(u8, buf[0..n], ours.written())) {
        std.debug.print("{s}: S-expression differs\n ref   {s}\n ztree {s}\n", .{ name, buf[0..@min(n, 400)], ours.written()[0..@min(ours.written().len, 400)] });
        return error.TestUnexpectedResult;
    }
}

/// Compare the comment spans with a cursor walk of the reference tree.
fn compareComments(arena: std.mem.Allocator, lang_enum: grammars.Lang, name: []const u8, text: []const u8, root: *const Subtree) !usize {
    const lang = grammars.language(lang_enum);
    const kinds = ztree.comments.commentKinds(lang_enum);
    var kind_ptrs: [4][*:0]const u8 = undefined;
    for (kinds, 0..) |k, i| kind_ptrs[i] = (try arena.dupeSentinel(u8, k, 0)).ptr;
    const ref = try arena.alloc(ztree.comments.Span, 1 << 16);
    const ours = try arena.alloc(ztree.comments.Span, 1 << 16);
    const n_ref = ztree_ref_comments(lang, text.ptr, @intCast(text.len), &kind_ptrs, @intCast(kinds.len), ref.ptr, @intCast(ref.len));
    const n_ours = try ztree.comments.extractFromTree(arena, lang, root, kinds, ours);
    if (n_ref != n_ours or !std.mem.eql(u8, std.mem.sliceAsBytes(ref[0..n_ref]), std.mem.sliceAsBytes(ours[0..n_ours]))) {
        std.debug.print("{s}: comments differ: ref {d}, ztree {d}\n", .{ name, n_ref, n_ours });
        return error.TestUnexpectedResult;
    }
    return n_ours;
}

/// Parse `text` with both runtimes and compare the dumps.
pub fn check(lang_name: []const u8, name: []const u8, text: []const u8, totals: *Totals) !void {
    const gpa = std.testing.allocator;
    const lang = grammars.language(std.meta.stringToEnum(grammars.Lang, lang_name).?);
    const cap: u32 = 1 << 20;
    const ref = try gpa.alloc(NodeRecord, cap);
    defer gpa.free(ref);
    var ref_has_error = false;
    const n = ztree_ref_parse_dump(lang, text.ptr, @intCast(text.len), ref.ptr, cap, &ref_has_error);
    try std.testing.expect(n <= cap);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const root = ztree.parser.parse(arena_state.allocator(), lang, text) catch |err| {
        std.debug.print("{s}: {s}: ztree failed with {s}\n", .{ lang_name, name, @errorName(err) });
        return err;
    };
    totals.last_had_error = ref_has_error;
    if (ref_has_error) totals.with_errors += 1;
    var ours: std.ArrayList(NodeRecord) = .empty;
    defer ours.deinit(gpa);
    try dump(root, &ours, gpa);
    try compareDumps(lang, lang_name, name, ref[0..n], ours.items);
    try compareSexp(gpa, arena_state.allocator(), lang, name, text, root);
    try compareWalk(arena_state.allocator(), lang, name, text, root);
    try compareFlat(gpa, arena_state.allocator(), lang, name, text, root, totals);
    totals.comments += try compareComments(arena_state.allocator(), std.meta.stringToEnum(grammars.Lang, lang_name).?, name, text, root);
    totals.compared += 1;
}

fn compareDumps(lang: *const abi.Language14, lang_name: []const u8, name: []const u8, ref: []const NodeRecord, ours: []const NodeRecord) !void {
    const count = @min(ref.len, ours.len);
    for (ref[0..count], ours[0..count], 0..) |r, o, i| {
        if (std.meta.eql(r, o)) continue;
        std.debug.print("{s}: {s}: record {d} ({s}) differs\n ref   {any}\n ztree {any}\n", .{ lang_name, name, i, abi.symbolName(lang, @min(r.symbol, lang.symbol_count - 1)), r, o });
        return error.TestUnexpectedResult;
    }
    if (ref.len != ours.len) {
        std.debug.print("{s}: {s}: ref has {d} records, ztree has {d}\n", .{ lang_name, name, ref.len, ours.len });
        return error.TestUnexpectedResult;
    }
}
