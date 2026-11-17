//! UTF-8 decode with the validity rules of ICU `U8_NEXT`, which the reference
//! runtime uses. A well-formed sequence gives its code point. Any other
//! sequence gives `decode_error`. The lexer then consumes 1 byte, so the
//! length of an ill-formed sequence does not matter.

const std = @import("std");
const assert = std.debug.assert;

/// `TS_DECODE_ERROR` (ICU `U_SENTINEL`).
pub const decode_error: i32 = -1;

pub const Decoded = struct {
    code_point: i32,
    /// The number of bytes of the code point. 1 for `decode_error`.
    len: u32,
};

const invalid = Decoded{ .code_point = decode_error, .len = 1 };

/// Return the inclusive range of the first trail byte after `lead`.
/// ICU tables `U8_LEAD3_T1_BITS` and `U8_LEAD4_T1_BITS` encode the same ranges.
fn firstTrailRange(lead: u8) struct { u8, u8 } {
    assert(lead >= 0xc2 and lead <= 0xf4);
    const range: struct { u8, u8 } = switch (lead) {
        0xe0 => .{ 0xa0, 0xbf },
        0xed => .{ 0x80, 0x9f },
        0xf0 => .{ 0x90, 0xbf },
        0xf4 => .{ 0x80, 0x8f },
        else => .{ 0x80, 0xbf },
    };
    assert(range[0] <= range[1]);
    return range;
}

/// Decode the first code point of `s`. `s` must not be empty.
pub fn decode(s: []const u8) Decoded {
    assert(s.len > 0);
    const lead = s[0];
    if (lead < 0x80) return .{ .code_point = lead, .len = 1 };
    if (lead < 0xc2 or lead > 0xf4) return invalid;
    const need: u32 = if (lead < 0xe0) 2 else if (lead < 0xf0) 3 else 4;
    assert(need >= 2 and need <= 4);
    if (s.len < 2) return invalid;
    const range = firstTrailRange(lead);
    if (s[1] < range[0] or s[1] > range[1]) return invalid;
    const lead_bits: u32 = switch (need) {
        2 => lead & 0x1f,
        3 => lead & 0x0f,
        else => lead & 0x07,
    };
    var cp: u32 = (lead_bits << 6) | (s[1] & 0x3f);
    var i: u32 = 2;
    while (i < need) : (i += 1) {
        if (i >= s.len) return invalid;
        if (s[i] < 0x80 or s[i] > 0xbf) return invalid;
        cp = (cp << 6) | (s[i] & 0x3f);
    }
    assert(cp <= 0x10ffff);
    return .{ .code_point = @intCast(cp), .len = need };
}

test "decode accepts well-formed sequences" {
    const cases = [_]struct { []const u8, i32, u32 }{
        .{ "a", 'a', 1 },
        .{ "\xc3\xa9", 0xe9, 2 },
        .{ "\xe2\x82\xac", 0x20ac, 3 },
        .{ "\xf0\x9f\x98\x80", 0x1f600, 4 },
        .{ "\xef\xbb\xbf", 0xfeff, 3 },
    };
    for (cases) |c| {
        const d = decode(c[0]);
        try std.testing.expectEqual(c[1], d.code_point);
        try std.testing.expectEqual(c[2], d.len);
    }
}

test "decode rejects ill-formed sequences" {
    const cases = [_][]const u8{ "\x80", "\xc0\x80", "\xe0\x80\x80", "\xed\xa0\x80", "\xf4\x90\x80\x80", "\xf5", "\xe2\x82" };
    for (cases) |c| {
        try std.testing.expectEqual(invalid, decode(c));
    }
}
