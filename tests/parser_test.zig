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
    std.debug.print("parser differential: {d} trees match, {d} of them with errors, {d} comments\n", .{ totals.compared, totals.with_errors, totals.comments });
    // 436 inputs on 2026-11-17: a drop means the corpus split lost examples.
    try std.testing.expect(totals.compared >= 436);
    try std.testing.expect(totals.with_errors > 0);
}
