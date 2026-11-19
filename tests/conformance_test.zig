//! Corpus conformance: each example of each grammar corpus, checked as the
//! tree-sitter CLI v0.27.2 checks it (`crates/cli/src/test.rs`). The test
//! also runs the reference runtime, so a failure that the reference shares
//! counts as an upstream failure, not as a ztree failure.

const std = @import("std");
const ztree = @import("ztree");
const corpus = @import("corpus");
const grammars = ztree.grammars;
const corpus_file = @import("corpus_file.zig");
const Example = corpus_file.Example;
const parseCorpus = corpus_file.parseCorpus;
const normalizeOutput = corpus_file.normalizeOutput;

extern fn ztree_ref_sexp(lang: *const ztree.abi.Language14, src: [*]const u8, len: u32, out: [*]u8, cap: u32) u32;

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
