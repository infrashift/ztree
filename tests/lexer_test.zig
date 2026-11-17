//! Differential tests of the lexer bridge against the reference runtime.
//! The UTF-8 test is exhaustive up to 3 bytes. The lexer test runs each lex
//! state, the keyword lexer and each external scanner row at sampled positions.

const std = @import("std");
const ztree = @import("ztree");
const abi = ztree.abi;
const grammars = ztree.grammars;
const Lexer = ztree.lexer.Lexer;
const Length = ztree.length.Length;
const expectEqual = std.testing.expectEqual;

extern fn ztree_ref_decode_utf8(s: [*]const u8, len: u32, cp: *i32) u32;

const LexResult = extern struct {
    ok: bool,
    did_get_column: bool,
    at_range_start: bool,
    symbol: u16,
    column: u32,
    lookahead: i32,
    lookahead_end_byte: u32,
    token_start: Length,
    token_end: Length,
};

extern fn ztree_ref_lex(
    lang: *const abi.Language14,
    src: [*]const u8,
    len: u32,
    position: Length,
    mode: u32,
    state: u16,
    valid: ?[*]const bool,
    out: *LexResult,
) void;

fn expectSameDecode(bytes: []const u8) !void {
    var ref_cp: i32 = 0;
    const ref_len = ztree_ref_decode_utf8(bytes.ptr, @intCast(bytes.len), &ref_cp);
    const d = ztree.utf8.decode(bytes);
    errdefer std.debug.print("bytes {x}: ref {d}/{d}, ztree {d}/{d}\n", .{ bytes, ref_cp, ref_len, d.code_point, d.len });
    try expectEqual(ref_cp, d.code_point);
    if (ref_cp != ztree.utf8.decode_error) try expectEqual(ref_len, d.len);
}

test "utf8 decode matches ICU for all sequences up to 3 bytes" {
    var buf: [3]u8 = undefined;
    for (0..256) |a| {
        buf[0] = @intCast(a);
        try expectSameDecode(buf[0..1]);
        if (a < 0xc0) continue;
        for (0..256) |b| {
            buf[1] = @intCast(b);
            try expectSameDecode(buf[0..2]);
            for (0..256) |c| {
                buf[2] = @intCast(c);
                try expectSameDecode(buf[0..3]);
            }
        }
    }
}

test "utf8 decode matches ICU for 4-byte leads" {
    const tails = [_]u8{ 0x00, 0x7f, 0x80, 0x9f, 0xbf, 0xc0, 0xff };
    var buf: [4]u8 = undefined;
    for (0xf0..0xf8) |a| {
        buf[0] = @intCast(a);
        for (0..256) |b| {
            buf[1] = @intCast(b);
            for (0..256) |c| {
                buf[2] = @intCast(c);
                for (tails) |d| {
                    buf[3] = d;
                    try expectSameDecode(&buf);
                }
            }
        }
    }
}

/// Inputs that every grammar sees: the edge cases of the lexer bridge.
const edge_inputs = [_][]const u8{
    "",
    "\xef\xbb\xbfx = 1\n",
    "a\xffb\xc0\x80c\xed\xa0\x80d \xf4\x90\x80\x80 e",
    "\xf0\x9f\x98\x80 \xc3\xa9\t\r\n// \xc3\xbcn\xc3\xafcode\n",
    "/* x */\r\n\x00tail",
    "  \n\t  indented\n    more\n  back\n",
    "s = \"str\\n\" 'c' `raw` r#\"rust\"# 0x1F 1e9 // end",
    "abc\xe2\x82",
};

const Sample = struct { lang: grammars.Lang, text: []const u8 };

const samples = [_]Sample{
    .{ .lang = .go, .text = @embedFile("go_declarations") },
    .{ .lang = .go, .text = @embedFile("go_expressions") },
    .{ .lang = .python, .text = @embedFile("python_statements") },
    .{ .lang = .python, .text = @embedFile("python_expressions") },
    .{ .lang = .c, .text = @embedFile("c_declarations") },
    .{ .lang = .c, .text = @embedFile("c_preprocessor") },
    .{ .lang = .rust, .text = @embedFile("rust_declarations") },
    .{ .lang = .rust, .text = @embedFile("rust_literals") },
    .{ .lang = .zig, .text = @embedFile("zig_lexer") },
};

/// The most positions that one input checks. Long inputs use a stride.
const max_positions = 300;

/// Return the position of each code point boundary, as the lexer reaches it.
fn boundaries(text: []const u8, out: []Length) usize {
    var n: usize = 0;
    var pos = Length{ .bytes = 0, .extent = .{ .row = 0, .column = 0 } };
    const stride = @max(1, text.len / max_positions);
    var since: usize = stride;
    while (pos.bytes < text.len and n < out.len - 1) {
        if (since >= stride) {
            out[n] = pos;
            n += 1;
            since = 0;
        }
        const d = ztree.utf8.decode(text[pos.bytes..]);
        if (text[pos.bytes] == '\n') {
            pos.extent.row += 1;
            pos.extent.column = 0;
        } else {
            pos.extent.column += d.len;
        }
        pos.bytes += d.len;
        since += d.len;
    }
    out[n] = pos;
    return n + 1;
}

fn lexZtree(lang: *const abi.Language14, text: []const u8, position: Length, mode: u32, state: u16, valid: ?[*]const bool) !LexResult {
    var lx = try Lexer.init(text);
    lx.reset(position);
    lx.start();
    var column: u32 = 0;
    var at_range_start = false;
    const ok = switch (mode) {
        3 => blk: {
            for (0..state) |_| lx.data.advance(&lx.data, false);
            column = lx.data.get_column(&lx.data);
            at_range_start = lx.data.is_at_included_range_start(&lx.data);
            break :blk false;
        },
        0 => lang.lex_fn.?(&lx.data, state),
        1 => lang.keyword_lex_fn.?(&lx.data, state),
        else => blk: {
            const scanner = lang.external_scanner;
            const payload = scanner.create.?();
            defer scanner.destroy.?(payload);
            break :blk scanner.scan.?(payload, &lx.data, valid.?);
        },
    };
    var end: u32 = 0;
    lx.finish(&end);
    return .{
        .ok = ok,
        .did_get_column = lx.did_get_column,
        .at_range_start = at_range_start,
        .column = column,
        .symbol = lx.data.result_symbol,
        .lookahead = lx.data.lookahead,
        .lookahead_end_byte = end,
        .token_start = lx.token_start_position,
        .token_end = lx.token_end_position,
    };
}

fn expectSameLex(lang: *const abi.Language14, text: []const u8, position: Length, mode: u32, state: u16, valid: ?[*]const bool) !void {
    var ref: LexResult = undefined;
    ztree_ref_lex(lang, text.ptr, @intCast(text.len), position, mode, state, valid, &ref);
    const ours = try lexZtree(lang, text, position, mode, state, valid);
    errdefer std.debug.print("byte {d} mode {d} state {d}\n ref   {any}\n ztree {any}\n", .{ position.bytes, mode, state, ref, ours });
    try expectEqual(ref, ours);
}

/// Distinct lex states of `lang`, and the largest external lex state.
fn lexStates(lang: *const abi.Language14, out: []u16) struct { usize, u16 } {
    var seen: [65536]bool = @splat(false);
    var n: usize = 0;
    var max_external: u16 = 0;
    var state: u32 = 0;
    while (state < lang.state_count) : (state += 1) {
        const m = abi.lexMode(lang, @intCast(state));
        max_external = @max(max_external, m.external_lex_state);
        if (m.lex_state == 0xffff or seen[m.lex_state]) continue;
        seen[m.lex_state] = true;
        out[n] = m.lex_state;
        n += 1;
    }
    return .{ n, max_external };
}

fn checkInput(lang: *const abi.Language14, text: []const u8) !void {
    var positions: [max_positions + 2]Length = undefined;
    const n_pos = boundaries(text, &positions);
    var states: [4096]u16 = undefined;
    const n_states, const max_external = lexStates(lang, &states);
    const all_valid: [64]bool = @splat(true);
    for (positions[0..n_pos]) |pos| {
        for (0..4) |k| try expectSameLex(lang, text, pos, 3, @intCast(k), null);
        for (states[0..n_states]) |s| try expectSameLex(lang, text, pos, 0, s, null);
        try expectSameLex(lang, text, pos, 1, 0, null);
        const count = lang.external_token_count;
        if (count == 0) continue;
        try expectSameLex(lang, text, pos, 2, 0, &all_valid);
        var row: u32 = 1;
        while (row <= max_external) : (row += 1) {
            const valid = lang.external_scanner.states.? + row * count;
            try expectSameLex(lang, text, pos, 2, 0, valid);
        }
    }
}

test "lexer bridge matches the reference lexer on edge inputs" {
    for (std.enums.values(grammars.Lang)) |lang| {
        errdefer std.debug.print("grammar {s}\n", .{@tagName(lang)});
        for (edge_inputs) |text| try checkInput(grammars.language(lang), text);
    }
}

test "lexer bridge matches the reference lexer on grammar samples" {
    for (samples) |sample| {
        errdefer std.debug.print("grammar {s}\n", .{@tagName(sample.lang)});
        try checkInput(grammars.language(sample.lang), sample.text);
    }
}
