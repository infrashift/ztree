//! Comment extraction: the spans of the comment nodes of a source text, in
//! source order. A comment node with children (a Rust doc comment) gives one
//! span, and the walk does not enter it.

const std = @import("std");
const assert = std.debug.assert;
const abi = @import("abi.zig");
const grammars = @import("grammars.zig");
const parser = @import("parser.zig");
const st = @import("subtree.zig");
const tree = @import("tree.zig");
const limits = @import("root.zig").limits;

pub const Error = parser.Error || tree.Error || error{OutputTooSmall};

/// The byte range and the start and end points of one comment. A column
/// counts bytes from the start of the row, as in the reference runtime.
pub const Span = extern struct {
    start_byte: u32,
    end_byte: u32,
    start_row: u32,
    start_column: u32,
    end_row: u32,
    end_column: u32,
};

/// The node types of the comments of each grammar (`node-types.json`).
pub fn commentKinds(lang: grammars.Lang) []const []const u8 {
    const kinds: []const []const u8 = switch (lang) {
        .go, .zig, .python, .c, .cpp, .csharp => &.{"comment"},
        .rust => &.{ "line_comment", "block_comment" },
    };
    assert(kinds.len > 0);
    assert(kinds.len <= 4);
    return kinds;
}

fn isCommentKind(name: []const u8, kinds: []const []const u8) bool {
    assert(kinds.len > 0);
    assert(name.len > 0);
    for (kinds) |k| {
        if (std.mem.eql(u8, k, name)) return true;
    }
    return false;
}

/// Write the spans of the named nodes of `root` whose type is in `kinds`, up
/// to `out.len` spans. Return the number of such nodes in the tree. The
/// number is more than `out.len` when `out` is too small.
pub fn collectFromTree(arena: std.mem.Allocator, lang: *const abi.Language14, root: *const st.Subtree, kinds: []const []const u8, out: []Span) tree.Error!usize {
    assert(kinds.len > 0);
    var walker = tree.Walker.init(arena, lang, root);
    var count: usize = 0;
    var steps: usize = 0;
    while (try walker.next()) |node| : (steps += 1) {
        assert(steps <= limits.max_subtrees);
        if (!node.isNamed(lang) or !isCommentKind(node.kind(lang), kinds)) continue;
        if (count < out.len) {
            const s = node.start();
            const e = node.end();
            out[count] = .{ .start_byte = s.bytes, .end_byte = e.bytes, .start_row = s.extent.row, .start_column = s.extent.column, .end_row = e.extent.row, .end_column = e.extent.column };
        }
        count += 1;
        walker.skipChildren();
    }
    assert(count <= steps);
    return count;
}

/// Write the spans of the named nodes of `root` whose type is in `kinds`.
/// Return the number of spans, or `error.OutputTooSmall`.
pub fn extractFromTree(arena: std.mem.Allocator, lang: *const abi.Language14, root: *const st.Subtree, kinds: []const []const u8, out: []Span) Error!usize {
    const count = try collectFromTree(arena, lang, root, kinds, out);
    if (count > out.len) return error.OutputTooSmall;
    assert(count <= out.len);
    return count;
}

/// Parse `source` and write the spans of its first `out.len` comments to
/// `out`. The arena holds the tree. Return the number of comments in the
/// source, which can be more than `out.len`.
pub fn collectComments(arena: std.mem.Allocator, lang: grammars.Lang, source: []const u8, out: []Span) (parser.Error || tree.Error)!usize {
    const language = grammars.language(lang);
    assert(out.len <= limits.max_subtrees);
    const root = try parser.parse(arena, language, source);
    assert(source.len <= limits.max_source_bytes);
    return collectFromTree(arena, language, root, commentKinds(lang), out);
}

/// Parse `source` and write the spans of its comments to `out`. The arena
/// holds the tree. Return the number of spans, or `error.OutputTooSmall`.
pub fn extractComments(arena: std.mem.Allocator, lang: grammars.Lang, source: []const u8, out: []Span) Error!usize {
    const count = try collectComments(arena, lang, source, out);
    if (count > out.len) return error.OutputTooSmall;
    assert(count <= out.len);
    return count;
}

fn testExpectComments(lang: grammars.Lang, source: []const u8, expected: []const []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var spans: [16]Span = undefined;
    const n = try extractComments(arena_state.allocator(), lang, source, &spans);
    try std.testing.expectEqual(expected.len, n);
    for (expected, spans[0..n]) |want, span| {
        try std.testing.expectEqualStrings(want, source[span.start_byte..span.end_byte]);
    }
}

test "extractComments finds line, block and doc comments" {
    try testExpectComments(.go, "package p\n// a\nvar x = 1 /* b */\n", &.{ "// a", "/* b */" });
    try testExpectComments(.python, "# a\nx = 1  # b\ns = '# no'\n", &.{ "# a", "# b" });
    try testExpectComments(.c, "/* a */ int x; // b\n", &.{ "/* a */", "// b" });
    try testExpectComments(.zig, "// a\n/// b\nconst x = 1; //! c\n", &.{ "// a", "/// b", "//! c" });
    try testExpectComments(.rust, "// a\n/// b\nfn f() {} /* c */\n", &.{ "// a", "/// b\n", "/* c */" });
    try testExpectComments(.csharp, "// a\n/// <summary>b</summary>\nclass C { string s = @\"// no\"; /* c */ }\n", &.{ "// a", "/// <summary>b</summary>", "/* c */" });
}

test "extractComments reports a buffer that is too small" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var spans: [1]Span = undefined;
    try std.testing.expectError(error.OutputTooSmall, extractComments(arena_state.allocator(), .go, "// a\n// b\npackage p\n", &spans));
    try std.testing.expectEqual(@as(usize, 2), try collectComments(arena_state.allocator(), .go, "// a\n// b\npackage p\n", &spans));
    try std.testing.expectEqual(@as(u32, 4), spans[0].end_byte);
}
