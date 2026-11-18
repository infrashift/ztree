//! ABI tests: the Zig mirrors against C `offsetof`, and each grammar against
//! its generated `#define` counts and against the reference runtime.

const std = @import("std");
const ztree = @import("ztree");
const abi = ztree.abi;
const grammars = ztree.grammars;
const expectEqual = std.testing.expectEqual;

extern const ztree_probe15: [18]usize;
extern const ztree_probe15_len: usize;
extern const ztree_probe14: [5]usize;
extern const ztree_probe14_len: usize;

test "ABI 15 layout matches the C header" {
    try expectEqual(ztree_probe15.len, ztree_probe15_len);
    const L = abi.Language15;
    const want = [_]usize{
        @sizeOf(L),
        @offsetOf(abi.Language14, "max_alias_sequence_length"),
        @offsetOf(abi.Language14, "parse_table"),
        @offsetOf(abi.Language14, "lex_modes"),
        @offsetOf(abi.Language14, "keyword_capture_token"),
        @offsetOf(abi.Language14, "external_scanner"),
        @offsetOf(abi.Language14, "primary_state_ids"),
        @offsetOf(L, "name"),
        @offsetOf(L, "max_reserved_word_set_size"),
        @offsetOf(L, "supertype_count"),
        @offsetOf(L, "metadata"),
        @sizeOf(abi.Lexer),
        @offsetOf(abi.Lexer, "advance"),
        @offsetOf(abi.Lexer, "log"),
        @sizeOf(abi.ParseActionEntry),
        @sizeOf(abi.LexerMode),
        @sizeOf(abi.FieldMapEntry),
        @sizeOf(abi.SymbolMetadata),
    };
    for (want, ztree_probe15, 0..) |w, c, i| {
        errdefer std.debug.print("probe15[{d}]: zig {d}, c {d}\n", .{ i, w, c });
        try expectEqual(c, w);
    }
}

test "ABI 14 layout matches the C header" {
    try expectEqual(ztree_probe14.len, ztree_probe14_len);
    const want = [_]usize{
        @sizeOf(abi.Language14),
        @offsetOf(abi.Language14, "lex_modes"),
        @offsetOf(abi.Language14, "external_scanner"),
        @offsetOf(abi.Language14, "primary_state_ids"),
        @sizeOf(abi.LexMode),
    };
    for (want, ztree_probe14, 0..) |w, c, i| {
        errdefer std.debug.print("probe14[{d}]: zig {d}, c {d}\n", .{ i, w, c });
        try expectEqual(c, w);
    }
}

/// The `#define` values at the top of each generated `parser.c`.
const Counts = struct {
    lang: grammars.Lang,
    abi_version: u32,
    state_count: u32,
    large_state_count: u32,
    symbol_count: u32,
    alias_count: u32,
    token_count: u32,
    external_token_count: u32,
    field_count: u32,
    production_id_count: u32,
    max_alias_sequence_length: u16,
};

const expected = [_]Counts{
    .{ .lang = .go, .abi_version = 15, .state_count = 1442, .large_state_count = 29, .symbol_count = 214, .alias_count = 5, .token_count = 95, .external_token_count = 0, .field_count = 35, .production_id_count = 111, .max_alias_sequence_length = 9 },
    .{ .lang = .python, .abi_version = 15, .state_count = 2786, .large_state_count = 185, .symbol_count = 272, .alias_count = 2, .token_count = 108, .external_token_count = 12, .field_count = 32, .production_id_count = 150, .max_alias_sequence_length = 10 },
    .{ .lang = .c, .abi_version = 15, .state_count = 2015, .large_state_count = 455, .symbol_count = 360, .alias_count = 3, .token_count = 161, .external_token_count = 0, .field_count = 39, .production_id_count = 131, .max_alias_sequence_length = 9 },
    .{ .lang = .zig, .abi_version = 14, .state_count = 1840, .large_state_count = 932, .symbol_count = 267, .alias_count = 1, .token_count = 151, .external_token_count = 0, .field_count = 16, .production_id_count = 57, .max_alias_sequence_length = 11 },
    .{ .lang = .rust, .abi_version = 15, .state_count = 3825, .large_state_count = 1064, .symbol_count = 351, .alias_count = 4, .token_count = 157, .external_token_count = 11, .field_count = 31, .production_id_count = 295, .max_alias_sequence_length = 10 },
};

test "each grammar matches its generated counts" {
    for (expected) |e| {
        const l = grammars.language(e.lang);
        errdefer std.debug.print("grammar {s}\n", .{@tagName(e.lang)});
        try expectEqual(e.abi_version, l.abi_version);
        try expectEqual(e.state_count, l.state_count);
        try expectEqual(e.large_state_count, l.large_state_count);
        try expectEqual(e.symbol_count, l.symbol_count);
        try expectEqual(e.alias_count, l.alias_count);
        try expectEqual(e.token_count, l.token_count);
        try expectEqual(e.external_token_count, l.external_token_count);
        try expectEqual(e.field_count, l.field_count);
        try expectEqual(e.production_id_count, l.production_id_count);
        try expectEqual(e.max_alias_sequence_length, l.max_alias_sequence_length);
        try expectEqual(e.external_token_count > 0, l.external_scanner.scan != null);
        try expectEqual(e.abi_version >= 15, abi.extended(l) != null);
    }
}

test "the ABI 15 grammars carry their names" {
    const names = [_]struct { grammars.Lang, []const u8 }{
        .{ .go, "go" }, .{ .python, "python" }, .{ .c, "c" }, .{ .rust, "rust" },
    };
    for (names) |n| {
        const ext = abi.extended(grammars.language(n[0])).?;
        try std.testing.expectEqualStrings(n[1], std.mem.span(ext.name.?));
    }
}

test "lex modes read with the right stride" {
    // Entries from `ts_lex_modes` in each `parser.c`. A wrong stride reads other values.
    // `0xffff` marks a state that only holds non-terminal extras.
    const Row = struct { grammars.Lang, abi.StateId, abi.LexModeView };
    const rows = [_]Row{
        .{ .go, 1, .{ .lex_state = 58, .external_lex_state = 0, .reserved_word_set_id = 1 } },
        .{ .go, 1441, .{ .lex_state = 0, .external_lex_state = 0, .reserved_word_set_id = 0 } },
        .{ .zig, 1, .{ .lex_state = 29, .external_lex_state = 0, .reserved_word_set_id = 0 } },
        .{ .zig, 1718, .{ .lex_state = 2, .external_lex_state = 0, .reserved_word_set_id = 0 } },
        .{ .zig, 1839, .{ .lex_state = 0, .external_lex_state = 0, .reserved_word_set_id = 0 } },
        .{ .python, 1, .{ .lex_state = 53, .external_lex_state = 2, .reserved_word_set_id = 1 } },
        .{ .python, 2785, .{ .lex_state = 53, .external_lex_state = 15, .reserved_word_set_id = 1 } },
        .{ .c, 2013, .{ .lex_state = 120, .external_lex_state = 0, .reserved_word_set_id = 0 } },
        .{ .rust, 1, .{ .lex_state = 71, .external_lex_state = 2, .reserved_word_set_id = 0 } },
        .{ .rust, 3824, .{ .lex_state = 0xffff, .external_lex_state = 0, .reserved_word_set_id = 0 } },
    };
    for (rows) |r| {
        errdefer std.debug.print("grammar {s} state {d}\n", .{ @tagName(r[0]), r[1] });
        try expectEqual(r[2], abi.lexMode(grammars.language(r[0]), r[1]));
    }
}

// The reference runtime: a test oracle only (ADR-0002).
extern fn ts_language_abi_version(lang: *const anyopaque) u32;
extern fn ts_language_symbol_count(lang: *const anyopaque) u32;
extern fn ts_language_state_count(lang: *const anyopaque) u32;
extern fn ts_language_field_count(lang: *const anyopaque) u32;
extern fn ts_language_symbol_name(lang: *const anyopaque, symbol: u16) ?[*:0]const u8;

test "each grammar matches the reference runtime" {
    for (std.enums.values(grammars.Lang)) |lang| {
        const l = grammars.language(lang);
        try expectEqual(ts_language_abi_version(l), l.abi_version);
        try expectEqual(ts_language_symbol_count(l), l.symbol_count + l.alias_count);
        try expectEqual(ts_language_state_count(l), l.state_count);
        try expectEqual(ts_language_field_count(l), l.field_count);
        var sym: u16 = 1;
        while (sym < l.symbol_count) : (sym += 1) {
            const ours = std.mem.span(abi.symbolName(l, sym));
            const theirs = std.mem.span(ts_language_symbol_name(l, sym).?);
            try std.testing.expectEqualStrings(theirs, ours);
        }
    }
}
