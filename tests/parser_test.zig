//! Differential tests of the parser against the reference runtime on the
//! corpus inputs, source files of this repository and targeted inputs.

const std = @import("std");
const ztree = @import("ztree");
const samples = @import("samples");

const diff = @import("differential.zig");
const Totals = diff.Totals;
const check = diff.check;

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
    .{ "go", "package p\nvar _ = x./* c */foo\nvar _ = T{ /* c */ a: 1 }\n" },
    .{ "c", "int bool, true, nullptr, auto_x; struct s { int default; } x; y = sizeof(int) + alignof;\n" },
    .{ "c", "int f( { return; }\nstruct { int x }\n" },
    .{ "rust", "fn f() { let union = 1; let default = 2; let auto = 3; union.x = default.y; macro_rules = 4; r#type = 5; }\n" },
    .{ "rust", "fn f( { let x = ; }\nstruct S { a: }\n" },
    .{ "csharp", "class C { int var = 1; int async = 2; void f() { var record = nameof(async); var x = await; dynamic d = var + record; } }\n" },
    .{ "csharp", "class C { void f( { int x = ; }\nstruct S { int }\n" },
    .{ "zig", "const type = 1; const anytype = 2; fn f(error: u8) void { _ = error; }\n" },
    .{ "zig", "fn f( { return; }\nconst x = ;\n" },
};

test "parser matches the reference runtime on keyword and error inputs" {
    var totals = Totals{};
    for (extra_inputs) |input| try check(input[0], input[1], input[1], &totals);
    try std.testing.expectEqual(extra_inputs.len, totals.compared);
}

/// Zig code that the release grammar v1.1.2 cannot read (ADR-0006): Zig 0.17
/// identifiers, Zig 0.15 asm clobbers and empty containers.
const zig_017_inputs = [_][]const u8{
    "fn f(io: Io) void { const r = await(io, future, result, 8); async = r; }\n",
    "const usingnamespace = 1;\npub fn g() u8 { return usingnamespace + async + await; }\n",
    "fn h() void { asm volatile (\"syscall\" ::: .{ .rcx = true, .r11 = true, .memory = true }); }\n",
    "const A = struct {};\nconst B = enum {};\nconst C = union {};\nconst D = *opaque {};\nconst E = extern struct {};\n",
};

test "the patched Zig grammar reads Zig 0.17 code and empty containers without errors" {
    var totals = Totals{};
    for (zig_017_inputs) |input| {
        try check("zig", input, input, &totals);
        errdefer std.debug.print("input with errors: {s}\n", .{input});
        try std.testing.expect(!totals.last_had_error);
    }
    try std.testing.expectEqual(zig_017_inputs.len, totals.compared);
}

/// Three rare Zig forms from the Zig 0.17.1 standard library (ISSUE-009,
/// ADR-0015): an error set as the type or the name of a container field, a
/// slice of an `if` type and an identifier as the asm clobbers. Without
/// ADR-0015, each input gives a MISSING `..` or an ERROR node.
const zig_rare_inputs = [_][]const u8{
    "const P = struct { w: error{A}, v: error{ B, C } = undefined };\n",
    "const T = struct { error{foo} };\nconst U = struct { error{foo}, u8 };\n",
    "fn f(c: bool) void { const v: []if (c) A else B = &.{}; _ = v; }\n",
    "const S = struct { vec: []const if (c) A else B, w: [:0]align(4) if (c) u8 else u16 };\n",
    "fn g() void { asm volatile (\"svc #0\" : [r] \"={x0}\" (-> usize) : [n] \"{x8}\" (n) : clobbers); }\n",
};

test "the patched Zig grammar reads the three rare forms of ISSUE-009 without errors" {
    var totals = Totals{};
    for (zig_rare_inputs) |input| {
        try check("zig", input, input, &totals);
        errdefer std.debug.print("input with errors: {s}\n", .{input});
        try std.testing.expect(!totals.last_had_error);
    }
    try std.testing.expectEqual(zig_rare_inputs.len, totals.compared);
}

/// C++ code read as C that needs more than 64 GLR stack heads (ISSUE-016,
/// ADR-0013). A delta reduction of two real headers gave these inputs. The
/// first needs 87 heads (from V8 `template-utils.h`), the second needs 71
/// (from libstdc++ `stl_algobase.h`). With 64 heads, ztree failed with
/// `TooManyVersions` on both.
const many_heads_inputs = [_][]const u8{
    "pack(Index>pack(<Key,Key,static_assert(Key,Rest...>);:+",
    "(a,b&c(d,e&,f(g,h&,i(const,const j&);/* note */\n&",
};

test "parser matches the reference runtime on inputs that need more than 64 stack heads" {
    var totals = Totals{};
    for (many_heads_inputs) |input| try check("c", input, input, &totals);
    try std.testing.expectEqual(many_heads_inputs.len, totals.compared);
}

/// The items of each large table. A hidden repetition of n items is a
/// left-deep chain of depth n, more than the 65,535 of a `u16` (ISSUE-017).
const large_table_items = 70_000;

/// A table of `large_table_items` literals for each grammar: the text before
/// the items and the text after them.
const large_tables = [_]struct { []const u8, []const u8, []const u8 }{
    .{ "go", "package p\n\nvar table = []int{", "}\n" },
    .{ "c", "static const int table[] = {", "};\n" },
    .{ "cpp", "static const int table[] = {", "};\n" },
    .{ "csharp", "static class T { static readonly int[] table = {", "}; }\n" },
    .{ "python", "table = [", "]\n" },
    .{ "rust", "static TABLE: &[u8] = &[", "];\n" },
    .{ "zig", "const table = [_]u8{", "};\n" },
};

test "parser matches the reference runtime on tables of more than 65,535 items" {
    const gpa = std.testing.allocator;
    var totals = Totals{};
    for (large_tables) |table| {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(gpa);
        try text.appendSlice(gpa, table[1]);
        for (0..large_table_items) |_| try text.appendSlice(gpa, "7,");
        try text.appendSlice(gpa, table[2]);
        try diff.checkWide(table[0], table[0], text.items, &totals);
        try std.testing.expect(!totals.last_had_error);
    }
    try std.testing.expectEqual(large_tables.len, totals.compared);
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
    std.debug.print("parser differential: {d} trees match, {d} of them with errors, {d} comments\n", .{ totals.compared, totals.with_errors, totals.comments });
    // 436 inputs on 2026-11-17: a drop means the corpus split lost examples.
    try std.testing.expect(totals.compared >= 436);
    try std.testing.expect(totals.with_errors > 0);
}
