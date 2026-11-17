//! Differential tests of the parser against the reference runtime. Both
//! sides write the tree in pre-order, with hidden repetition nodes flattened,
//! because the reference balances repetitions and ztree does not (ADR-0005).

const std = @import("std");
const ztree = @import("ztree");
const samples = @import("samples");
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

const Totals = struct { compared: usize = 0, with_errors: usize = 0 };

/// Parse `text` with both runtimes and compare the dumps.
fn check(lang_name: []const u8, name: []const u8, text: []const u8, totals: *Totals) !void {
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
    if (ref_has_error) totals.with_errors += 1;
    var ours: std.ArrayList(NodeRecord) = .empty;
    defer ours.deinit(gpa);
    try dump(root, &ours, gpa);
    try compareDumps(lang, lang_name, name, ref[0..n], ours.items);
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

/// One example of a corpus file: the name and the input text.
const Example = struct { name: []const u8, input: []const u8 };

fn isRule(line: []const u8, c: u8) bool {
    if (line.len < 3) return false;
    for (line) |x| if (x != c) return false;
    return true;
}

/// Split a corpus file into examples. A header is a rule of `=`, the name,
/// optional `:attribute` lines and a closing rule. A rule of `-` ends the input.
fn splitCorpus(text: []const u8, out: *std.ArrayList(Example), gpa: std.mem.Allocator) !void {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| try lines.append(gpa, std.mem.trimEnd(u8, line, "\r"));
    var i: usize = 0;
    while (i < lines.items.len) : (i += 1) {
        if (!isRule(lines.items[i], '=') or i + 2 >= lines.items.len) continue;
        const name = lines.items[i + 1];
        var j = i + 2;
        while (j < lines.items.len and !isRule(lines.items[j], '=')) j += 1;
        if (j >= lines.items.len) break;
        var k = j + 1;
        while (k < lines.items.len and !isRule(lines.items[k], '-')) k += 1;
        if (k >= lines.items.len) break;
        const start = @intFromPtr(lines.items[j + 1].ptr) - @intFromPtr(text.ptr);
        const end = @intFromPtr(lines.items[k].ptr) - @intFromPtr(text.ptr);
        try out.append(gpa, .{ .name = name, .input = std.mem.trim(u8, text[start..end], "\n") });
        i = k;
    }
}

/// Inputs that put keywords where identifiers go, for the switch from a
/// keyword to the word token, plus inputs with syntax errors.
const extra_inputs = [_]struct { []const u8, []const u8 }{
    .{ "python", "print = 1\nexec = 2\nx.print\nx.exec(print)\nmatch = 3\ntype = 4\nawait = 5\nmatch.x = type.y\nprint(exec, match, type)\n" },
    .{ "python", "def match(type, print): return exec\nclass type: pass\nasync = 1\nnonlocal = 2\n" },
    .{ "python", "def f(:\n  return )\nx = [1, 2\nprint 'a'\n" },
    .{ "go", "package p\nvar new, make, len = 1, 2, 3\nfunc f() { x.type = 1; type T int; go := 1 }\n" },
    .{ "go", "package p\nfunc f( { return }\nvar x = \n" },
    .{ "c", "int bool, true, nullptr, auto_x; struct s { int default; } x; y = sizeof(int) + alignof;\n" },
    .{ "c", "int f( { return; }\nstruct { int x }\n" },
    .{ "rust", "fn f() { let union = 1; let default = 2; let auto = 3; union.x = default.y; macro_rules = 4; r#type = 5; }\n" },
    .{ "rust", "fn f( { let x = ; }\nstruct S { a: }\n" },
    .{ "zig", "const type = 1; const anytype = 2; fn f(error: u8) void { _ = error; }\n" },
    .{ "zig", "fn f( { return; }\nconst x = ;\n" },
};

test "parser matches the reference runtime on keyword and error inputs" {
    var totals = Totals{};
    for (extra_inputs) |input| try check(input[0], input[1], input[1], &totals);
    try std.testing.expectEqual(extra_inputs.len, totals.compared);
}

test "parser matches the reference runtime on corpus inputs and source files" {
    const gpa = std.testing.allocator;
    var totals = Totals{};
    inline for (samples.paths, 0..) |path, s| {
        const text = @embedFile(path);
        if (std.mem.eql(u8, samples.kinds[s], "corpus")) {
            var examples: std.ArrayList(Example) = .empty;
            defer examples.deinit(gpa);
            try splitCorpus(text, &examples, gpa);
            try std.testing.expect(examples.items.len > 0);
            for (examples.items) |ex| try check(samples.langs[s], ex.name, ex.input, &totals);
        } else {
            try check(samples.langs[s], path, text, &totals);
        }
    }
    std.debug.print("parser differential: {d} trees match, {d} of them with errors\n", .{ totals.compared, totals.with_errors });
    // 436 inputs on 2026-11-17: a drop means the corpus split lost examples.
    try std.testing.expect(totals.compared >= 436);
    try std.testing.expect(totals.with_errors > 0);
}
