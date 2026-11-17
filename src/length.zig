//! Positions in the source text. They mirror `TSPoint` and `Length` of the
//! reference runtime. A column counts bytes from the start of the row.

const std = @import("std");
const assert = std.debug.assert;

pub const Point = extern struct {
    row: u32,
    column: u32,
};

pub const Length = extern struct {
    bytes: u32,
    extent: Point,
};

pub const zero = Length{ .bytes = 0, .extent = .{ .row = 0, .column = 0 } };

/// `LENGTH_UNDEFINED`: a length that no real position can have.
pub const undefined_length = Length{ .bytes = 0, .extent = .{ .row = 0, .column = 1 } };

/// Return true when `len` is `undefined_length`.
pub fn isUndefined(len: Length) bool {
    assert(len.extent.row == 0 or len.bytes > 0);
    const result = len.bytes == 0 and len.extent.column != 0;
    assert(!result or len.extent.row == 0);
    return result;
}

test "only the undefined length is undefined" {
    try std.testing.expect(isUndefined(undefined_length));
    try std.testing.expect(!isUndefined(zero));
    try std.testing.expect(!isUndefined(.{ .bytes = 3, .extent = .{ .row = 0, .column = 3 } }));
}
