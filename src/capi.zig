//! The C ABI of ztree (`include/ztree.h`, ISSUE-007). It is the root of the
//! static library `libztree.a`. The functions take no callbacks, keep no
//! global state and write to buffers that the caller owns. Each call uses
//! its own arena on the C heap and frees it before it returns.

const std = @import("std");
const assert = std.debug.assert;
const ztree = @import("root.zig");
const comments = ztree.comments;
const grammars = ztree.grammars;
const limits = ztree.limits;

/// The panic handler of the library. A library prints no stack trace and
/// starts no thread, so a panic writes its message to stderr and aborts the
/// process, as `include/ztree.h` states.
pub const panic = std.debug.FullPanic(abortWithMessage);

fn abortWithMessage(msg: []const u8, first_trace_addr: ?usize) noreturn {
    @branchHint(.cold);
    if (first_trace_addr) |addr| assert(addr != 0);
    const parts = [_][]const u8{ "ztree: panic: ", msg, "\n" };
    for (parts) |part| {
        if (std.c.write(2, part.ptr, part.len) < 0) break;
    }
    std.c.abort();
}

/// `ZTREE_ABI_VERSION` of `include/ztree.h`. Change it with each change of the header.
pub const abi_version: u32 = 1;

/// The status codes of `include/ztree.h`.
pub const Status = enum(i32) {
    ok = 0,
    buffer_too_small = 1,
    invalid_argument = 2,
    source_too_large = 3,
    out_of_memory = 4,
    limit_reached = 5,
    unsupported_grammar = 6,
};

/// The `ZTREE_LANG_*` values of `include/ztree.h`. The values do not depend
/// on the order of `grammars.Lang`.
pub fn langFromC(value: u32) ?grammars.Lang {
    const lang: ?grammars.Lang = switch (value) {
        0 => .go,
        1 => .zig,
        2 => .python,
        3 => .c,
        4 => .rust,
        else => null,
    };
    assert(lang == null or value <= 4);
    assert(lang != null or value > 4);
    return lang;
}

/// The status of each error of `comments.collectComments`. The switch has no
/// `else`, so a new error fails the build until it has a status.
fn statusFromError(err: (ztree.parser.Error || ztree.tree.Error)) Status {
    const status: Status = switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.SourceTooLarge => .source_too_large,
        error.UnsupportedAbiVersion => .unsupported_grammar,
        error.TooManySubtrees, error.TooManyStackNodes, error.TooManyVersions, error.StackTooDeep, error.TreeTooDeep, error.TooManyOperations => .limit_reached,
    };
    assert(status != .ok);
    assert(status != .buffer_too_small);
    return status;
}

/// `ztree_abi_version`: the ABI version of the library. A caller compares it
/// with `ZTREE_ABI_VERSION` of its header.
export fn ztree_abi_version() callconv(.c) u32 {
    assert(abi_version > 0);
    assert(abi_version < 1000);
    return abi_version;
}

/// `ztree_extract_comments`: see `include/ztree.h`.
export fn ztree_extract_comments(lang: u32, src: ?[*]const u8, len: usize, spans_out: ?[*]comments.Span, max_spans: usize, count_out: ?*usize) callconv(.c) i32 {
    const status = extract(lang, src, len, spans_out, max_spans, count_out);
    assert(status != .ok or count_out.?.* <= max_spans);
    assert(status != .buffer_too_small or count_out.?.* > max_spans);
    return @backingInt(status);
}

fn extract(lang_value: u32, src: ?[*]const u8, len: usize, spans_out: ?[*]comments.Span, max_spans: usize, count_out: ?*usize) Status {
    const out_count = count_out orelse return .invalid_argument;
    out_count.* = 0;
    const lang = langFromC(lang_value) orelse return .invalid_argument;
    if (src == null and len > 0) return .invalid_argument;
    if (spans_out == null and max_spans > 0) return .invalid_argument;
    if (len > limits.max_source_bytes) return .source_too_large;
    const source: []const u8 = if (src) |p| p[0..len] else "";
    // A tree holds at most `max_subtrees` nodes, so a larger buffer gains nothing.
    const cap = @min(max_spans, limits.max_subtrees);
    const out: []comments.Span = if (spans_out) |p| p[0..cap] else &.{};
    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    const count = comments.collectComments(arena_state.allocator(), lang, source, out) catch |err| return statusFromError(err);
    out_count.* = count;
    assert(out.len <= max_spans);
    return if (count > out.len) .buffer_too_small else .ok;
}

test "ztree_extract_comments writes the spans and the count" {
    const src = "package p\n// a\nvar x = 1 /* b */\n";
    var spans: [4]comments.Span = undefined;
    var count: usize = 99;
    try std.testing.expectEqual(@as(i32, 0), ztree_extract_comments(0, src.ptr, src.len, &spans, spans.len, &count));
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqualStrings("/* b */", src[spans[1].start_byte..spans[1].end_byte]);
    try std.testing.expectEqual(@as(i32, 1), ztree_extract_comments(0, src.ptr, src.len, &spans, 1, &count));
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(@as(i32, 1), ztree_extract_comments(0, src.ptr, src.len, null, 0, &count));
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "ztree_extract_comments rejects bad arguments" {
    var spans: [1]comments.Span = undefined;
    var count: usize = 99;
    try std.testing.expectEqual(@as(i32, 2), ztree_extract_comments(5, "x", 1, &spans, 1, &count));
    try std.testing.expectEqual(@as(usize, 0), count);
    try std.testing.expectEqual(@as(i32, 2), ztree_extract_comments(0, null, 1, &spans, 1, &count));
    try std.testing.expectEqual(@as(i32, 2), ztree_extract_comments(0, "x", 1, null, 1, &count));
    try std.testing.expectEqual(@as(i32, 2), ztree_extract_comments(0, "x", 1, &spans, 1, null));
    try std.testing.expectEqual(@as(i32, 0), ztree_extract_comments(0, null, 0, null, 0, &count));
    try std.testing.expectEqual(@as(usize, 0), count);
    try std.testing.expectEqual(@as(i32, 3), ztree_extract_comments(0, "x", limits.max_source_bytes + 1, &spans, 1, &count));
}

test "each C language value maps to a grammar" {
    for (0..5) |v| try std.testing.expect(langFromC(@intCast(v)) != null);
    try std.testing.expectEqual(grammars.Lang.rust, langFromC(4).?);
    try std.testing.expectEqual(@as(?grammars.Lang, null), langFromC(std.math.maxInt(u32)));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(comments.Span));
    // `ZTREE_MAX_SOURCE_BYTES` of `include/ztree.h`.
    try std.testing.expectEqual(@as(usize, 16 * 1024 * 1024), limits.max_source_bytes);
}
