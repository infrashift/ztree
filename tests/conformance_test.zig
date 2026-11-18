//! Corpus conformance: each example of each grammar corpus, checked as the
//! tree-sitter CLI v0.27.2 checks it (`crates/cli/src/test.rs`). The test
//! also runs the reference runtime, so a failure that the reference shares
//! counts as an upstream failure, not as a ztree failure.

const std = @import("std");
const ztree = @import("ztree");
const corpus = @import("corpus");
const grammars = ztree.grammars;

extern fn ztree_ref_sexp(lang: *const ztree.abi.Language14, src: [*]const u8, len: u32, out: [*]u8, cap: u32) u32;

const Expectation = enum { pass, err, skip };

const Example = struct {
    name: []const u8,
    input: []const u8,
    output: []const u8,
    has_fields: bool,
    expectation: Expectation,
};

/// `parse_delimiter_line`: 3 or more `c`, then an optional suffix.
fn delimiter(line: []const u8, c: u8) ?[]const u8 {
    var n: usize = 0;
    while (n < line.len and line[n] == c) n += 1;
    if (n < 3) return null;
    return std.mem.trimEnd(u8, line[n..], "\r\n");
}

fn suffixMatches(first: ?[]const u8, suffix: []const u8) bool {
    if (first) |f| return suffix.len > 0 and std.mem.eql(u8, f, suffix);
    return suffix.len == 0;
}

const Header = struct { name: []const u8, expectation: Expectation, body_start: usize };

/// `parse_header`: name lines, attribute lines and the closing `===` line.
fn parseHeader(lines: []const []const u8, first: ?[]const u8, start: usize) ?Header {
    const suffix = delimiter(lines[start], '=') orelse return null;
    if (!suffixMatches(first, suffix)) return null;
    var name: []const u8 = "";
    var seen_marker = false;
    var skip = false;
    var err = false;
    var i = start + 1;
    while (i < lines.len) : (i += 1) {
        if (delimiter(lines[i], '=')) |s| if (suffixMatches(first, s)) break;
        const trimmed = std.mem.trim(u8, lines[i], " \t\r\n");
        if (trimmed.len == 0 and !seen_marker) return null;
        var it = std.mem.splitScalar(u8, trimmed, '(');
        const head = it.first();
        if (std.mem.eql(u8, head, ":skip")) {
            seen_marker = true;
            skip = true;
        } else if (std.mem.eql(u8, head, ":error")) {
            seen_marker = true;
            err = true;
        } else if (std.mem.eql(u8, head, ":fail-fast") or std.mem.eql(u8, head, ":cst") or
            std.mem.eql(u8, head, ":platform") or std.mem.eql(u8, head, ":language"))
        {
            seen_marker = true;
        } else if (!seen_marker and name.len == 0) {
            name = std.mem.trimEnd(u8, lines[i], " \t\r\n");
        }
    }
    if (i >= lines.len) return null;
    const expectation: Expectation = if (skip) .skip else if (err) .err else .pass;
    return .{ .name = name, .expectation = expectation, .body_start = i + 1 };
}

/// `normalize_sexp_output`: drop `;` comment lines, collapse whitespace and
/// drop a space before `)`.
fn normalizeOutput(gpa: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var prev_space = false;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " \t\r"), ";")) continue;
        for (line) |c| {
            if (std.ascii.isWhitespace(c)) {
                if (!prev_space and out.items.len > 0) {
                    try out.append(gpa, ' ');
                    prev_space = true;
                }
            } else {
                if (c == ')' and prev_space) out.items.len -= 1;
                try out.append(gpa, c);
                prev_space = false;
            }
        }
        if (out.items.len > 0 and !prev_space) {
            try out.append(gpa, ' ');
            prev_space = true;
        }
    }
    while (out.items.len > 0 and std.ascii.isWhitespace(out.items[out.items.len - 1])) out.items.len -= 1;
    return out.toOwnedSlice(gpa);
}

/// `strip_sexp_fields`: replace ` word: (` with ` (`.
fn stripFields(gpa: std.mem.Allocator, sexp: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var rest = sexp;
    while (std.mem.indexOf(u8, rest, ": (")) |pos| {
        if (std.mem.lastIndexOfScalar(u8, rest[0..pos], ' ')) |space| {
            const word = rest[space + 1 .. pos];
            var ok = word.len > 0;
            for (word) |b| ok = ok and (std.ascii.isAlphanumeric(b) or b == '_');
            if (ok) {
                try out.appendSlice(gpa, rest[0 .. space + 1]);
                try out.append(gpa, '(');
                rest = rest[pos + 3 ..];
                continue;
            }
        }
        try out.appendSlice(gpa, rest[0 .. pos + 3]);
        rest = rest[pos + 3 ..];
    }
    try out.appendSlice(gpa, rest);
    return out.toOwnedSlice(gpa);
}

/// `parse_test_content` and `build_test_entry`: the examples of one file.
fn parseCorpus(gpa: std.mem.Allocator, content: []const u8, out: *std.ArrayList(Example)) !void {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);
    var start: usize = 0;
    while (start < content.len) {
        const end = if (std.mem.indexOfScalarPos(u8, content, start, '\n')) |e| e + 1 else content.len;
        try lines.append(gpa, content[start..end]);
        start = end;
    }
    var first: ?[]const u8 = null;
    for (lines.items) |line| if (delimiter(line, '=')) |s| if (s.len > 0) {
        first = s;
        break;
    };
    var pending: ?Header = null;
    var i: usize = 0;
    while (i < lines.items.len) {
        const h = parseHeader(lines.items, first, i) orelse {
            i += 1;
            continue;
        };
        if (pending) |p| try buildEntry(gpa, lines.items[p.body_start..i], first, p, out);
        pending = h;
        i = h.body_start;
    }
    if (pending) |p| try buildEntry(gpa, lines.items[p.body_start..], first, p, out);
}

fn buildEntry(gpa: std.mem.Allocator, body: []const []const u8, first: ?[]const u8, h: Header, out: *std.ArrayList(Example)) !void {
    var best: ?usize = null;
    var best_len: usize = 0;
    for (body, 0..) |line, j| {
        var n: usize = 0;
        while (n < line.len and line[n] == '-') n += 1;
        const suffix = delimiter(line, '-') orelse continue;
        if (!suffixMatches(first, suffix)) continue;
        if (n + suffix.len >= best_len) {
            best = j;
            best_len = n + suffix.len;
        }
    }
    const divider = best orelse return;
    var input: []const u8 = if (divider == 0) "" else spanOf(body[0], body[divider - 1]);
    if (std.mem.endsWith(u8, input, "\n")) input = input[0 .. input.len - 1];
    if (std.mem.endsWith(u8, input, "\r")) input = input[0 .. input.len - 1];
    const raw_output = if (divider + 1 < body.len) spanOf(body[divider + 1], body[body.len - 1]) else "";
    const output = try normalizeOutput(gpa, raw_output);
    try out.append(gpa, .{ .name = h.name, .input = input, .output = output, .has_fields = std.mem.indexOf(u8, output, ": (") != null, .expectation = h.expectation });
}

/// The bytes from the start of `a` to the end of `b`, two lines of one buffer.
fn spanOf(a: []const u8, b: []const u8) []const u8 {
    const start = @intFromPtr(a.ptr);
    const end = @intFromPtr(b.ptr) + b.len;
    return a.ptr[0 .. end - start];
}

const Outcome = enum { pass, fail, skip };

/// Run one example on ztree. Return the outcome and the actual output.
fn runZtree(gpa: std.mem.Allocator, lang: grammars.Lang, ex: Example) !struct { Outcome, []u8 } {
    if (ex.expectation == .skip) return .{ .skip, try gpa.dupe(u8, "") };
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const root = try ztree.parser.parse(arena_state.allocator(), grammars.language(lang), ex.input);
    var w: std.Io.Writer.Allocating = .init(gpa);
    defer w.deinit();
    try ztree.tree.writeSexp(arena_state.allocator(), grammars.language(lang), root, &w.writer);
    try checkFlat(arena_state.allocator(), lang, ex, root);
    const actual = if (ex.has_fields) try gpa.dupe(u8, w.written()) else try stripFields(gpa, w.written());
    const pass = if (ex.expectation == .err) root.errorCost() > 0 else std.mem.eql(u8, actual, ex.output);
    return .{ if (pass) .pass else .fail, actual };
}

/// Flatten the tree of one example. Its S-expression must equal the
/// S-expression of the visible nodes of the tree (ISSUE-011).
fn checkFlat(arena: std.mem.Allocator, lang: grammars.Lang, ex: Example, root: *const ztree.subtree.Subtree) !void {
    const language = grammars.language(lang);
    var tree_w: std.Io.Writer.Allocating = .init(arena);
    try ztree.tree.writeVisibleSexp(arena, language, root, ex.input, &tree_w.writer);
    const want = tree_w.written();
    const n = (try ztree.flat.flatten(arena, language, root, &.{}, &.{})).nodes;
    const nodes = try arena.alloc(ztree.flat.Node, n);
    try std.testing.expectEqual(n, (try ztree.flat.flatten(arena, language, root, nodes, &.{})).nodes);
    var w: std.Io.Writer.Allocating = .init(arena);
    try ztree.flat.writeSexp(arena, language, nodes, ex.input, &w.writer);
    if (!std.mem.eql(u8, want, w.written())) {
        std.debug.print("flat tree differs: {s}: {s}\n tree {s}\n flat {s}\n", .{ @tagName(lang), ex.name, want, w.written() });
        return error.TestUnexpectedResult;
    }
}

/// Run one example on the reference runtime: the outcome only.
fn runReference(gpa: std.mem.Allocator, lang: grammars.Lang, ex: Example) !Outcome {
    if (ex.expectation == .skip) return .skip;
    const buf = try gpa.alloc(u8, 1 << 22);
    defer gpa.free(buf);
    const n = ztree_ref_sexp(grammars.language(lang), ex.input.ptr, @intCast(ex.input.len), buf.ptr, @intCast(buf.len));
    const actual = if (ex.has_fields) try gpa.dupe(u8, buf[0..n]) else try stripFields(gpa, buf[0..n]);
    defer gpa.free(actual);
    if (ex.expectation == .err) return if (std.mem.indexOf(u8, actual, "ERROR") != null or std.mem.indexOf(u8, actual, "MISSING") != null) .pass else .fail;
    return if (std.mem.eql(u8, actual, ex.output)) .pass else .fail;
}

test "each corpus example gives the expected tree, or fails as the reference fails" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var counts: [4]usize = @splat(0); // pass, skip, upstream failure, ztree failure
    inline for (corpus.paths, 0..) |path, f| {
        const lang = std.meta.stringToEnum(grammars.Lang, corpus.langs[f]).?;
        var examples: std.ArrayList(Example) = .empty;
        try parseCorpus(arena, @embedFile(path), &examples);
        try std.testing.expect(examples.items.len > 0);
        for (examples.items) |ex| {
            const ours, const actual = try runZtree(gpa, lang, ex);
            defer gpa.free(actual);
            const ref = try runReference(gpa, lang, ex);
            switch (ours) {
                .pass => counts[0] += 1,
                .skip => counts[1] += 1,
                .fail => if (ref == .fail) {
                    counts[2] += 1;
                    std.debug.print("upstream failure (reference fails too): {s}: {s}\n", .{ path, ex.name });
                } else {
                    counts[3] += 1;
                    std.debug.print("ztree failure: {s}: {s}\n expected {s}\n actual   {s}\n", .{ path, ex.name, ex.output, actual });
                },
            }
        }
    }
    std.debug.print("conformance: {d} pass, {d} skipped, {d} upstream failures, {d} ztree failures\n", .{ counts[0], counts[1], counts[2], counts[3] });
    try std.testing.expectEqual(@as(usize, 0), counts[3]);
    try std.testing.expect(counts[0] > 400);
}

test "normalizeOutput and stripFields follow the CLI" {
    const gpa = std.testing.allocator;
    const n = try normalizeOutput(gpa, "\n(a\n  ; note\n  (b c)   )\n\n");
    defer gpa.free(n);
    try std.testing.expectEqualStrings("(a (b c))", n);
    const s = try stripFields(gpa, "(a name: (b) x: (c))");
    defer gpa.free(s);
    try std.testing.expectEqualStrings("(a (b) (c))", s);
}
