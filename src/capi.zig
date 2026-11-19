//! The C ABI of ztree (`include/ztree.h`, ISSUE-007). It is the root of the
//! static library `libztree.a`. The functions take no callbacks, keep no
//! global state and write to buffers that the caller owns. Each call uses
//! its own arena on the C heap and frees it before it returns.

const std = @import("std");
const assert = std.debug.assert;
const ztree = @import("root.zig");
const abi = ztree.abi;
const comments = ztree.comments;
const flat = ztree.flat;
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
pub const abi_version: u32 = 6;

/// The status codes of `include/ztree.h`.
pub const Status = enum(i32) {
    ok = 0,
    buffer_too_small = 1,
    invalid_argument = 2,
    source_too_large = 3,
    out_of_memory = 4,
    limit_reached = 5,
    unsupported_grammar = 6,
    regex_syntax = 7,
    regex_unsupported = 8,
    query_error = 9,
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
        5 => .cpp,
        else => null,
    };
    assert(lang == null or value <= 5);
    assert(lang != null or value > 5);
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

/// `ztree_parse`: see `include/ztree.h`.
export fn ztree_parse(lang: u32, src: ?[*]const u8, len: usize, nodes_out: ?[*]flat.Node, max_nodes: usize, node_count_out: ?*usize, overrides_out: ?[*]flat.FieldOverride, max_overrides: usize, override_count_out: ?*usize) callconv(.c) i32 {
    const out = ParseOut{ .nodes = nodes_out, .max_nodes = max_nodes, .node_count = node_count_out, .overrides = overrides_out, .max_overrides = max_overrides, .override_count = override_count_out };
    const status = parse(lang, src, len, out);
    assert(status != .ok or node_count_out.?.* <= max_nodes);
    assert(status != .ok or override_count_out.?.* <= max_overrides);
    return @backingInt(status);
}

/// The output arguments of `ztree_parse`.
const ParseOut = struct {
    nodes: ?[*]flat.Node,
    max_nodes: usize,
    node_count: ?*usize,
    overrides: ?[*]flat.FieldOverride,
    max_overrides: usize,
    override_count: ?*usize,
};

fn parse(lang_value: u32, src: ?[*]const u8, len: usize, out: ParseOut) Status {
    const node_count = out.node_count orelse return .invalid_argument;
    node_count.* = 0;
    const override_count = out.override_count orelse return .invalid_argument;
    override_count.* = 0;
    const lang = langFromC(lang_value) orelse return .invalid_argument;
    if (src == null and len > 0) return .invalid_argument;
    if (out.nodes == null and out.max_nodes > 0) return .invalid_argument;
    if (out.overrides == null and out.max_overrides > 0) return .invalid_argument;
    if (len > limits.max_source_bytes) return .source_too_large;
    const source: []const u8 = if (src) |p| p[0..len] else "";
    // A tree holds at most `max_subtrees` nodes, so a larger buffer gains nothing.
    const nodes: []flat.Node = if (out.nodes) |p| p[0..@min(out.max_nodes, limits.max_subtrees)] else &.{};
    const overrides: []flat.FieldOverride = if (out.overrides) |p| p[0..@min(out.max_overrides, limits.max_subtrees)] else &.{};
    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const language = grammars.language(lang);
    const root = ztree.parser.parse(arena, language, source) catch |err| return statusFromError(err);
    const counts = flat.flatten(arena, language, root, nodes, overrides) catch |err| return statusFromError(err);
    node_count.* = counts.nodes;
    override_count.* = counts.overrides;
    assert(counts.nodes > 0);
    assert(counts.nodes <= limits.max_subtrees);
    return if (counts.nodes > nodes.len or counts.overrides > overrides.len) .buffer_too_small else .ok;
}

/// `ztree_regex_match`: see `include/ztree.h`.
export fn ztree_regex_match(pattern: ?[*]const u8, pattern_len: usize, text: ?[*]const u8, text_len: usize, matched_out: ?*i32, error_offset_out: ?*usize) callconv(.c) i32 {
    const status = regexMatch(pattern, pattern_len, text, text_len, matched_out, error_offset_out);
    assert(status != .ok or matched_out.?.* == 0 or matched_out.?.* == 1);
    assert(status != .regex_syntax or error_offset_out.?.* <= pattern_len);
    return @backingInt(status);
}

fn regexMatch(pattern: ?[*]const u8, pattern_len: usize, text: ?[*]const u8, text_len: usize, matched_out: ?*i32, error_offset_out: ?*usize) Status {
    const matched = matched_out orelse return .invalid_argument;
    const error_offset = error_offset_out orelse return .invalid_argument;
    matched.* = 0;
    error_offset.* = 0;
    if ((pattern == null and pattern_len > 0) or (text == null and text_len > 0)) return .invalid_argument;
    if (text_len > limits.max_source_bytes) return .source_too_large;
    const regex = ztree.regex;
    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const insts = arena.alloc(regex.Inst, regex.max_insts) catch return .out_of_memory;
    const ranges = arena.alloc(regex.Range, regex.max_ranges) catch return .out_of_memory;
    var diag = regex.Diagnostic{};
    const prog = regex.compile(if (pattern) |p| p[0..pattern_len] else "", insts, ranges, &diag) catch |err| {
        error_offset.* = diag.offset;
        return switch (err) {
            error.Syntax => .regex_syntax,
            error.Unsupported => .regex_unsupported,
            error.TooLarge => .limit_reached,
        };
    };
    const scratch = arena.alloc(u32, regex.scratchLen(prog)) catch return .out_of_memory;
    matched.* = @intFromBool(regex.isMatch(prog, if (text) |t| t[0..text_len] else "", scratch));
    assert(matched.* == 0 or matched.* == 1);
    assert(prog.insts.len <= regex.max_insts);
    return .ok;
}

test "ztree_regex_match matches and reports errors" {
    var matched: i32 = 9;
    var offset: usize = 9;
    try std.testing.expectEqual(@as(i32, 0), ztree_regex_match("b+", 2, "abbc", 4, &matched, &offset));
    try std.testing.expectEqual(@as(i32, 1), matched);
    try std.testing.expectEqual(@as(i32, 0), ztree_regex_match("^b", 2, "abbc", 4, &matched, &offset));
    try std.testing.expectEqual(@as(i32, 0), matched);
    try std.testing.expectEqual(@as(i32, 7), ztree_regex_match("a(b", 3, "", 0, &matched, &offset));
    try std.testing.expectEqual(@as(usize, 1), offset);
    try std.testing.expectEqual(@as(i32, 8), ztree_regex_match("\\pL", 3, "", 0, &matched, &offset));
    try std.testing.expectEqual(@as(i32, 0), ztree_regex_match(null, 0, null, 0, &matched, &offset));
    try std.testing.expectEqual(@as(i32, 1), matched);
    try std.testing.expectEqual(@as(i32, 2), ztree_regex_match(null, 1, null, 0, &matched, &offset));
    try std.testing.expectEqual(@as(i32, 2), ztree_regex_match("a", 1, "a", 1, null, &offset));
}

/// `ztree_query_error` of `include/ztree.h`.
pub const QueryError = extern struct { kind: u32, offset: u32, row: u32, column: u32 };

/// `ztree_query_compile`: see `include/ztree.h`.
export fn ztree_query_compile(lang: u32, src: ?[*]const u8, len: usize, blob_out: ?[*]u8, blob_cap: usize, blob_size_out: ?*usize, error_out: ?*QueryError) callconv(.c) i32 {
    const status = queryCompile(lang, src, len, blob_out, blob_cap, blob_size_out, error_out);
    assert(status != .ok or blob_size_out.?.* <= blob_cap);
    assert(status != .query_error or error_out.?.kind != 0);
    return @backingInt(status);
}

fn queryCompile(lang_value: u32, src: ?[*]const u8, len: usize, blob_out: ?[*]u8, blob_cap: usize, blob_size_out: ?*usize, error_out: ?*QueryError) Status {
    const size_out = blob_size_out orelse return .invalid_argument;
    const err_out = error_out orelse return .invalid_argument;
    size_out.* = 0;
    err_out.* = .{ .kind = 0, .offset = 0, .row = 0, .column = 0 };
    const lang = langFromC(lang_value) orelse return .invalid_argument;
    if ((src == null and len > 0) or (blob_out == null and blob_cap > 0)) return .invalid_argument;
    if (blob_out) |b| if (@intFromPtr(b) % ztree.query_blob.alignment != 0) return .invalid_argument;
    if (len > ztree.query.max_query_bytes) return .limit_reached;
    const source: []const u8 = if (src) |p| p[0..len] else "";
    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var failure = ztree.query.Failure{};
    var reference_ub = false;
    const q = ztree.query.compile(arena, grammars.language(lang), source, &failure, &reference_ub) catch |err| return queryStatus(err, source, failure, err_out);
    const preds = ztree.query_predicates.compile(q, &failure) catch |err| return queryStatus(err, source, failure, err_out);
    const out: []u8 = if (blob_out) |b| b[0..blob_cap] else &.{};
    const size = ztree.query_blob.write(arena, lang_value, q, &preds, out) catch return .out_of_memory;
    size_out.* = size;
    assert(size >= @sizeOf(ztree.query_blob.Header));
    return if (size > blob_cap) .buffer_too_small else .ok;
}

/// The status of a failed compile. A query error gets its kind, offset, row and column.
fn queryStatus(err: ztree.query.Error, source: []const u8, failure: ztree.query.Failure, out: *QueryError) Status {
    switch (err) {
        error.OutOfMemory => return .out_of_memory,
        error.TooLarge => return .limit_reached,
        error.QueryError => {},
    }
    assert(failure.kind != .none);
    assert(failure.offset <= source.len);
    const before = source[0..failure.offset];
    const line_start = if (std.mem.lastIndexOfScalar(u8, before, '\n')) |i| i + 1 else 0;
    out.* = .{ .kind = @backingInt(failure.kind), .offset = failure.offset, .row = @intCast(std.mem.count(u8, before, "\n")), .column = @intCast(failure.offset - line_start) };
    return .query_error;
}

test "ztree_query_compile writes a blob or an error with its position" {
    var blob: [4096]u8 align(4) = undefined;
    var size: usize = 0;
    var err: QueryError = undefined;
    const q = "(function_declaration name: (identifier) @name)";
    try std.testing.expectEqual(@as(i32, 0), ztree_query_compile(0, q, q.len, &blob, blob.len, &size, &err));
    try std.testing.expect(size > @sizeOf(ztree.query_blob.Header));
    const view = try ztree.query_blob.View.init(blob[0..size]);
    try std.testing.expectEqualStrings("name", view.captureName(0));
    try std.testing.expectEqual(@as(u32, 1), ztree_query_pattern_count(&blob, size));
    try std.testing.expectEqual(@as(u32, 1), ztree_query_capture_count(&blob, size));
    var name_len: usize = 0;
    try std.testing.expectEqualStrings("name", ztree_query_capture_name(&blob, size, 0, &name_len).?[0..name_len]);
    try std.testing.expectEqual(@as(?[*]const u8, null), ztree_query_capture_name(&blob, size, 1, &name_len));
    try std.testing.expectEqual(@as(u32, 0), ztree_query_pattern_count(&blob, size - 4));
    try std.testing.expectEqual(@as(i32, 1), ztree_query_compile(0, q, q.len, &blob, 8, &size, &err));
    const bad = "(identifier) @a\n  (no_such_node)";
    try std.testing.expectEqual(@as(i32, 9), ztree_query_compile(0, bad, bad.len, &blob, blob.len, &size, &err));
    try std.testing.expectEqual(QueryError{ .kind = 2, .offset = 19, .row = 1, .column = 3 }, err);
    const pred = "((identifier) @a (#foo? @a))";
    try std.testing.expectEqual(@as(i32, 9), ztree_query_compile(0, pred, pred.len, &blob, blob.len, &size, &err));
    try std.testing.expectEqual(@as(u32, 7), err.kind);
    try std.testing.expectEqual(@as(u32, 17), err.offset);
    const directives = [_][]const u8{ "((identifier) @a (#set! key value))", "((identifier) @a (#strip! @a \"x\"))", "((identifier) @a (#set-adjacent! @a @a))", "((identifier) @a (#nope! @a))", "((identifier) @a (#is? local))" };
    for (directives) |d| {
        try std.testing.expectEqual(@as(i32, 9), ztree_query_compile(0, d.ptr, d.len, &blob, blob.len, &size, &err));
        try std.testing.expectEqual(QueryError{ .kind = 8, .offset = 17, .row = 0, .column = 17 }, err);
    }
    const re = "((identifier) @a (#match? @a \"\\\\pL\"))";
    try std.testing.expectEqual(@as(i32, 9), ztree_query_compile(0, re, re.len, &blob, blob.len, &size, &err));
    try std.testing.expectEqual(@as(u32, 8), err.kind);
    try std.testing.expectEqual(@as(i32, 2), ztree_query_compile(6, q, q.len, &blob, blob.len, &size, &err));
    try std.testing.expectEqual(@as(i32, 2), ztree_query_compile(0, q, q.len, blob[1..].ptr, 8, &size, &err));
}

/// The output arguments of `ztree_query_exec`.
const ExecOut = struct {
    matches: ?[*]ztree.query_exec.Match,
    max_matches: usize,
    match_count: ?*usize,
    captures: ?[*]ztree.query_exec.Capture,
    max_captures: usize,
    capture_count: ?*usize,
};

/// `ztree_query_exec`: see `include/ztree.h`.
export fn ztree_query_exec(blob: ?[*]const u8, blob_len: usize, nodes: ?[*]const flat.Node, node_count: usize, overrides: ?[*]const flat.FieldOverride, override_count: usize, src: ?[*]const u8, len: usize, start_node: u32, matches_out: ?[*]ztree.query_exec.Match, max_matches: usize, match_count_out: ?*usize, captures_out: ?[*]ztree.query_exec.Capture, max_captures: usize, capture_count_out: ?*usize) callconv(.c) i32 {
    const out = ExecOut{ .matches = matches_out, .max_matches = max_matches, .match_count = match_count_out, .captures = captures_out, .max_captures = max_captures, .capture_count = capture_count_out };
    const status = queryExec(blob, blob_len, nodes, node_count, overrides, override_count, src, len, start_node, out);
    assert(status != .ok or match_count_out.?.* <= max_matches);
    assert(status != .ok or capture_count_out.?.* <= max_captures);
    return @backingInt(status);
}

fn queryExec(blob: ?[*]const u8, blob_len: usize, nodes: ?[*]const flat.Node, node_count: usize, overrides: ?[*]const flat.FieldOverride, override_count: usize, src: ?[*]const u8, len: usize, start_node: u32, out: ExecOut) Status {
    const match_count = out.match_count orelse return .invalid_argument;
    const capture_count = out.capture_count orelse return .invalid_argument;
    match_count.* = 0;
    capture_count.* = 0;
    const b = blob orelse return .invalid_argument;
    const node_ptr = nodes orelse return .invalid_argument;
    if (@intFromPtr(b) % ztree.query_blob.alignment != 0) return .invalid_argument;
    if ((overrides == null and override_count > 0) or (src == null and len > 0)) return .invalid_argument;
    if ((out.matches == null and out.max_matches > 0) or (out.captures == null and out.max_captures > 0)) return .invalid_argument;
    if (node_count == 0 or node_count > limits.max_subtrees or start_node >= node_count or len > limits.max_source_bytes) return .invalid_argument;
    const aligned: [*]align(ztree.query_blob.alignment) const u8 = @alignCast(b);
    const view = ztree.query_blob.View.init(aligned[0..blob_len]) catch return .invalid_argument;
    const tree_nodes = node_ptr[0..node_count];
    assert(tree_nodes.len > 0 and start_node < tree_nodes.len);
    const tree_overrides: []const flat.FieldOverride = if (overrides) |o| o[0..override_count] else &.{};
    const text: []const u8 = if (src) |p| p[0..len] else "";
    if (!ztree.query_exec.validTree(tree_nodes, tree_overrides, len)) return .invalid_argument;
    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    const in = ztree.query_exec.Input{ .view = &view, .nodes = tree_nodes, .overrides = tree_overrides, .text = text, .start = start_node };
    const matches: []ztree.query_exec.Match = if (out.matches) |m| m[0..out.max_matches] else &.{};
    const captures: []ztree.query_exec.Capture = if (out.captures) |c| c[0..out.max_captures] else &.{};
    const counts = ztree.query_exec.exec(arena_state.allocator(), in, false, matches, captures) catch |err| return switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.LimitReached => .limit_reached,
    };
    match_count.* = counts.matches;
    capture_count.* = counts.captures;
    // Each capture belongs to a match.
    assert(counts.matches > 0 or counts.captures == 0);
    return if (counts.matches > matches.len or counts.captures > captures.len) .buffer_too_small else .ok;
}

test "ztree_query_exec runs a query over a flat tree" {
    const src = "package p\nfunc f() { panic(1); g(2) }\n";
    var nodes: [64]flat.Node = undefined;
    var count: usize = 0;
    var ovs: [4]flat.FieldOverride = undefined;
    var ov_count: usize = 0;
    try std.testing.expectEqual(@as(i32, 0), ztree_parse(0, src, src.len, &nodes, nodes.len, &count, &ovs, ovs.len, &ov_count));
    var blob: [8192]u8 align(4) = undefined;
    var size: usize = 0;
    var err: QueryError = undefined;
    const q = "(call_expression function: (identifier) @f (#eq? @f \"panic\"))";
    try std.testing.expectEqual(@as(i32, 0), ztree_query_compile(0, q, q.len, &blob, blob.len, &size, &err));
    var matches: [4]ztree.query_exec.Match = undefined;
    var captures: [4]ztree.query_exec.Capture = undefined;
    var mc: usize = 0;
    var cc: usize = 0;
    try std.testing.expectEqual(@as(i32, 0), ztree_query_exec(&blob, size, &nodes, count, &ovs, ov_count, src, src.len, 0, &matches, matches.len, &mc, &captures, captures.len, &cc));
    try std.testing.expectEqual(@as(usize, 1), mc);
    try std.testing.expectEqual(@as(usize, 1), cc);
    const n = nodes[captures[0].node];
    try std.testing.expectEqualStrings("panic", src[n.start_byte..n.end_byte]);
    try std.testing.expectEqual(@as(i32, 1), ztree_query_exec(&blob, size, &nodes, count, &ovs, ov_count, src, src.len, 0, null, 0, &mc, null, 0, &cc));
    try std.testing.expectEqual(@as(usize, 1), mc);
    blob[size - 1] ^= 1;
    try std.testing.expectEqual(@as(i32, 2), ztree_query_exec(&blob, size, &nodes, count, &ovs, ov_count, src, src.len, 0, &matches, matches.len, &mc, &captures, captures.len, &cc));
    blob[size - 1] ^= 1;
    nodes[3].parent = 7;
    try std.testing.expectEqual(@as(i32, 2), ztree_query_exec(&blob, size, &nodes, count, &ovs, ov_count, src, src.len, 0, &matches, matches.len, &mc, &captures, captures.len, &cc));
}

/// The view of a blob from caller memory, or null when the blob fails its checks.
fn blobView(blob: ?[*]const u8, blob_len: usize) ?ztree.query_blob.View {
    const b = blob orelse return null;
    if (@intFromPtr(b) % ztree.query_blob.alignment != 0) return null;
    const aligned: [*]align(ztree.query_blob.alignment) const u8 = @alignCast(b);
    const view = ztree.query_blob.View.init(aligned[0..blob_len]) catch return null;
    assert(view.header.size == blob_len);
    assert(view.blob.len == blob_len);
    return view;
}

/// `ztree_query_pattern_count`: the number of patterns of a blob, or 0.
export fn ztree_query_pattern_count(blob: ?[*]const u8, blob_len: usize) callconv(.c) u32 {
    const view = blobView(blob, blob_len) orelse return 0;
    const count = view.get(.patterns).len;
    assert(count <= std.math.maxInt(u16));
    assert(count == view.get(.pattern_text_predicates).len);
    return @intCast(count);
}

/// `ztree_query_capture_count`: the number of captures of a blob, or 0.
export fn ztree_query_capture_count(blob: ?[*]const u8, blob_len: usize) callconv(.c) u32 {
    const view = blobView(blob, blob_len) orelse return 0;
    assert(view.header.capture_count == view.get(.capture_slices).len);
    assert(view.header.capture_count <= std.math.maxInt(u16));
    return view.header.capture_count;
}

/// `ztree_query_capture_name`: the name of a capture, or NULL.
export fn ztree_query_capture_name(blob: ?[*]const u8, blob_len: usize, index: u32, length_out: ?*usize) callconv(.c) ?[*]const u8 {
    const len_out = length_out orelse return null;
    len_out.* = 0;
    const view = blobView(blob, blob_len) orelse return null;
    if (index >= view.header.capture_count) return null;
    const name = view.captureName(index);
    len_out.* = name.len;
    assert(name.len <= ztree.query.max_query_bytes);
    assert(len_out.* == name.len);
    return name.ptr;
}

/// The grammar of a `ZTREE_LANG_*` value, or null.
fn languageFromC(value: u32) ?*const abi.Language14 {
    const lang = langFromC(value) orelse return null;
    const language = grammars.language(lang);
    assert(language.symbol_count > 0);
    assert(language.abi_version >= abi.min_abi_version);
    return language;
}

/// `ztree_language_abi_version`: the Tree-sitter ABI version of a grammar, or 0.
export fn ztree_language_abi_version(lang: u32) callconv(.c) u32 {
    const language = languageFromC(lang) orelse return 0;
    assert(language.abi_version >= abi.min_abi_version);
    assert(language.abi_version <= abi.max_abi_version);
    return language.abi_version;
}

/// `ztree_language_symbol_count`: the symbols and the aliases of a grammar
/// (`ts_language_symbol_count`), or 0.
export fn ztree_language_symbol_count(lang: u32) callconv(.c) u32 {
    const language = languageFromC(lang) orelse return 0;
    const count = language.symbol_count + language.alias_count;
    assert(count >= language.symbol_count);
    assert(count < abi.builtin_sym_error);
    return count;
}

/// `ztree_language_field_count`: the largest field id of a grammar, or 0.
export fn ztree_language_field_count(lang: u32) callconv(.c) u32 {
    const language = languageFromC(lang) orelse return 0;
    assert(language.field_count < std.math.maxInt(abi.FieldId));
    assert(language.field_count == 0 or language.field_names != null);
    return language.field_count;
}

/// True when `symbol` names a symbol of `language` or ERROR.
fn symbolInRange(language: *const abi.Language14, symbol: u32) bool {
    assert(language.symbol_count > 0);
    assert(language.symbol_count + language.alias_count < abi.builtin_sym_error);
    return symbol == abi.builtin_sym_error or symbol < language.symbol_count + language.alias_count;
}

/// `ztree_language_symbol_name`: the name of a symbol, or NULL.
export fn ztree_language_symbol_name(lang: u32, symbol: u32) callconv(.c) ?[*:0]const u8 {
    const language = languageFromC(lang) orelse return null;
    if (!symbolInRange(language, symbol)) return null;
    if (symbol == abi.builtin_sym_error) return "ERROR";
    assert(symbol < abi.builtin_sym_error);
    assert(language.symbol_names != null);
    return abi.symbolName(language, @intCast(symbol));
}

/// The bits of `ztree_language_symbol_flags`.
pub const symbol_visible: u32 = 1;
pub const symbol_named: u32 = 2;
pub const symbol_supertype: u32 = 4;

/// `ztree_language_symbol_flags`: the metadata of a symbol, or 0.
export fn ztree_language_symbol_flags(lang: u32, symbol: u32) callconv(.c) u32 {
    const language = languageFromC(lang) orelse return 0;
    if (!symbolInRange(language, symbol)) return 0;
    const m = ztree.language.symbolMetadata(language, @intCast(symbol));
    assert(symbol == abi.builtin_sym_error or symbol < language.symbol_count + language.alias_count);
    var bits: u32 = 0;
    if (m.visible) bits |= symbol_visible;
    if (m.named) bits |= symbol_named;
    if (m.supertype) bits |= symbol_supertype;
    assert(bits < 8);
    return bits;
}

/// `ztree_language_field_name`: the name of a field id, or NULL.
export fn ztree_language_field_name(lang: u32, field: u32) callconv(.c) ?[*:0]const u8 {
    const language = languageFromC(lang) orelse return null;
    if (field == 0 or field > language.field_count) return null;
    assert(field <= std.math.maxInt(abi.FieldId));
    assert(language.field_names != null);
    return language.field_names.?[field];
}

fn testParse(src: ?[*]const u8, len: usize, nodes: ?[*]flat.Node, max_nodes: usize, count: *usize) i32 {
    var overrides: [8]flat.FieldOverride = undefined;
    var override_count: usize = 99;
    const status = ztree_parse(0, src, len, nodes, max_nodes, count, &overrides, overrides.len, &override_count);
    if (status == 0) assert(override_count == 0);
    return status;
}

test "ztree_parse writes the flat tree and the count" {
    const src = "package p\nvar x = 1\n";
    var nodes: [32]flat.Node = undefined;
    var count: usize = 99;
    try std.testing.expectEqual(@as(i32, 0), testParse(src.ptr, src.len, &nodes, nodes.len, &count));
    try std.testing.expect(count > 4 and count < nodes.len);
    try std.testing.expectEqual(flat.none, nodes[0].parent);
    try std.testing.expectEqualStrings("source_file", std.mem.span(ztree_language_symbol_name(0, nodes[0].symbol).?));
    const total = count;
    try std.testing.expectEqual(@as(i32, 1), testParse(src.ptr, src.len, &nodes, 2, &count));
    try std.testing.expectEqual(total, count);
    try std.testing.expectEqual(@as(i32, 1), testParse(src.ptr, src.len, null, 0, &count));
    try std.testing.expectEqual(@as(i32, 0), testParse(null, 0, &nodes, nodes.len, &count));
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(i32, 2), testParse(src.ptr, src.len, null, 1, &count));
    try std.testing.expectEqual(@as(usize, 0), count);
    try std.testing.expectEqual(@as(i32, 3), testParse(src.ptr, limits.max_source_bytes + 1, &nodes, 1, &count));
    var oc: usize = 0;
    try std.testing.expectEqual(@as(i32, 2), ztree_parse(6, src.ptr, src.len, &nodes, nodes.len, &count, null, 0, &oc));
    try std.testing.expectEqual(@as(i32, 2), ztree_parse(0, src.ptr, src.len, &nodes, nodes.len, null, null, 0, &oc));
    try std.testing.expectEqual(@as(i32, 2), ztree_parse(0, src.ptr, src.len, &nodes, nodes.len, &count, null, 0, null));
    try std.testing.expectEqual(@as(i32, 2), ztree_parse(0, src.ptr, src.len, &nodes, nodes.len, &count, null, 1, &oc));
}

test "ztree_parse writes the field overrides of an ERROR node" {
    // The ERROR node holds a hidden node with fields, but it has no field
    // map: `ts_node_child_by_field_id` gives null for each field.
    const src = "package p\nfunc f() { x := }\n";
    var nodes: [64]flat.Node = undefined;
    var count: usize = 0;
    var overrides: [8]flat.FieldOverride = undefined;
    var override_count: usize = 0;
    try std.testing.expectEqual(@as(i32, 0), ztree_parse(0, src, src.len, &nodes, nodes.len, &count, &overrides, overrides.len, &override_count));
    for (overrides[0..override_count]) |o| {
        try std.testing.expect(o.node < count);
        try std.testing.expect(o.field_id > 0);
    }
    if (override_count > 0) {
        try std.testing.expectEqual(@as(i32, 1), ztree_parse(0, src, src.len, &nodes, nodes.len, &count, &overrides, 0, &override_count));
    }
}

test "the language functions give the metadata of each grammar" {
    for (0..6) |v| {
        const lang: u32 = @intCast(v);
        try std.testing.expect(ztree_language_abi_version(lang) >= 14);
        const symbols = ztree_language_symbol_count(lang);
        try std.testing.expect(symbols > 10);
        try std.testing.expectEqualStrings("end", std.mem.span(ztree_language_symbol_name(lang, 0).?));
        try std.testing.expectEqualStrings("ERROR", std.mem.span(ztree_language_symbol_name(lang, 0xffff).?));
        try std.testing.expectEqual(@as(?[*:0]const u8, null), ztree_language_symbol_name(lang, symbols));
        try std.testing.expectEqual(symbol_visible | symbol_named, ztree_language_symbol_flags(lang, 0xffff));
        const fields = ztree_language_field_count(lang);
        try std.testing.expect(fields > 0);
        try std.testing.expectEqual(@as(?[*:0]const u8, null), ztree_language_field_name(lang, 0));
        try std.testing.expect(ztree_language_field_name(lang, fields) != null);
        try std.testing.expectEqual(@as(?[*:0]const u8, null), ztree_language_field_name(lang, fields + 1));
    }
    try std.testing.expectEqual(@as(u32, 0), ztree_language_symbol_count(6));
    try std.testing.expectEqual(@as(?[*:0]const u8, null), ztree_language_symbol_name(6, 0));
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(flat.Node));
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
    try std.testing.expectEqual(@as(i32, 2), ztree_extract_comments(6, "x", 1, &spans, 1, &count));
    try std.testing.expectEqual(@as(usize, 0), count);
    try std.testing.expectEqual(@as(i32, 2), ztree_extract_comments(0, null, 1, &spans, 1, &count));
    try std.testing.expectEqual(@as(i32, 2), ztree_extract_comments(0, "x", 1, null, 1, &count));
    try std.testing.expectEqual(@as(i32, 2), ztree_extract_comments(0, "x", 1, &spans, 1, null));
    try std.testing.expectEqual(@as(i32, 0), ztree_extract_comments(0, null, 0, null, 0, &count));
    try std.testing.expectEqual(@as(usize, 0), count);
    try std.testing.expectEqual(@as(i32, 3), ztree_extract_comments(0, "x", limits.max_source_bytes + 1, &spans, 1, &count));
}

test "each C language value maps to a grammar" {
    for (0..6) |v| try std.testing.expect(langFromC(@intCast(v)) != null);
    try std.testing.expectEqual(grammars.Lang.rust, langFromC(4).?);
    try std.testing.expectEqual(grammars.Lang.cpp, langFromC(5).?);
    try std.testing.expectEqual(@as(?grammars.Lang, null), langFromC(6));
    try std.testing.expectEqual(@as(?grammars.Lang, null), langFromC(std.math.maxInt(u32)));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(comments.Span));
    // `ZTREE_MAX_SOURCE_BYTES` of `include/ztree.h`.
    try std.testing.expectEqual(@as(usize, 16 * 1024 * 1024), limits.max_source_bytes);
}
