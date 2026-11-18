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
pub const abi_version: u32 = 4;

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
