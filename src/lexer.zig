//! The lexer bridge: the `TSLexer` that the generated lex functions and the
//! external scanners call. It ports `lib/src/lexer.c` of the reference runtime
//! for one UTF-8 source buffer. ADR-0004 excludes included ranges, so one
//! range covers the whole input. The source buffer acts as the one chunk that
//! the reference string input returns for each read.

const std = @import("std");
const assert = std.debug.assert;
const abi = @import("abi.zig");
const utf8 = @import("utf8.zig");
const length = @import("length.zig");
const limits = @import("root.zig").limits;

const Length = length.Length;
const byte_order_mark: i32 = 0xfeff;

pub const Error = error{SourceTooLarge};

pub const Lexer = struct {
    data: abi.Lexer,
    source: []const u8,
    current_position: Length,
    token_start_position: Length,
    token_end_position: Length,
    chunk_start: u32,
    /// Zero when the lexer holds no chunk (`chunk == NULL` in the reference).
    chunk_size: u32,
    lookahead_size: u32,
    /// The reference stores EOF as `current_included_range_index == count`.
    at_eof: bool,
    did_get_column: bool,
    column_valid: bool,
    column_value: u32,

    /// Return a lexer at byte 0 of `source`, in the state of `ts_lexer_init`
    /// followed by `ts_lexer_set_input`.
    pub fn init(source: []const u8) Error!Lexer {
        if (source.len > limits.max_source_bytes) return error.SourceTooLarge;
        assert(limits.max_source_bytes < std.math.maxInt(u32));
        const self = Lexer{
            .data = .{
                .lookahead = 0,
                .result_symbol = 0,
                .advance = &advance,
                .mark_end = &markEndCallback,
                .get_column = &getColumn,
                .is_at_included_range_start = &isAtIncludedRangeStart,
                .eof = &eof,
                .log = &log,
            },
            .source = source,
            .current_position = length.zero,
            .token_start_position = length.zero,
            .token_end_position = length.zero,
            .chunk_start = 0,
            .chunk_size = 0,
            .lookahead_size = 0,
            .at_eof = false,
            .did_get_column = false,
            .column_valid = false,
            .column_value = 0,
        };
        assert(self.source.len == source.len);
        return self;
    }

    /// Move to `position` (`ts_lexer_reset`). No work when the byte is the same.
    pub fn reset(self: *Lexer, position: Length) void {
        assert(position.bytes <= self.source.len);
        assert(!length.isUndefined(position));
        if (position.bytes != self.current_position.bytes) self.goto(position);
    }

    /// Prepare to lex one token (`ts_lexer_start`).
    pub fn start(self: *Lexer) void {
        assert(self.current_position.bytes <= self.source.len);
        self.token_start_position = self.current_position;
        self.token_end_position = length.undefined_length;
        self.data.result_symbol = 0;
        self.did_get_column = false;
        if (self.at_eof) return;
        if (self.chunk_size == 0) self.getChunk();
        if (self.lookahead_size == 0) self.getLookahead();
        if (self.current_position.bytes == 0) {
            if (self.data.lookahead == byte_order_mark) advance(&self.data, true);
            self.setColumn(0);
        }
        assert(self.lookahead_size > 0);
    }

    /// Close the token (`ts_lexer_finish`). Raise `lookahead_end_byte` to the
    /// last byte that the lexer read.
    pub fn finish(self: *Lexer, lookahead_end_byte: *u32) void {
        assert(self.current_position.bytes <= self.source.len);
        if (length.isUndefined(self.token_end_position)) self.markEnd();
        if (self.token_end_position.bytes < self.token_start_position.bytes) {
            self.token_start_position = self.token_end_position;
        }
        var end: u32 = self.current_position.bytes + 1;
        // The decoder can read up to 4 bytes to reject an ill-formed sequence.
        if (self.data.lookahead == utf8.decode_error) end += 4;
        if (end > lookahead_end_byte.*) lookahead_end_byte.* = end;
        assert(lookahead_end_byte.* >= end);
    }

    /// Mark the end of the current token at the current position.
    pub fn markEnd(self: *Lexer) void {
        assert(self.current_position.bytes <= self.source.len);
        assert(self.current_position.bytes >= self.chunk_start or self.chunk_size == 0);
        // One included range starts at byte 0, so the token always ends here.
        self.token_end_position = self.current_position;
    }

    fn setColumn(self: *Lexer, value: u32) void {
        assert(value <= self.current_position.bytes);
        self.column_valid = true;
        self.column_value = value;
        assert(self.column_valid);
    }

    fn clearChunk(self: *Lexer) void {
        assert(self.chunk_start <= self.source.len);
        self.chunk_start = 0;
        self.chunk_size = 0;
        assert(self.chunk_size == 0);
    }

    /// Read the chunk at the current position (`ts_lexer__get_chunk`).
    fn getChunk(self: *Lexer) void {
        const pos = self.current_position.bytes;
        assert(pos <= self.source.len);
        self.chunk_start = pos;
        self.chunk_size = @intCast(self.source.len - pos);
        if (self.chunk_size == 0) self.at_eof = true;
        assert(self.chunk_start + self.chunk_size == self.source.len);
    }

    /// Decode the lookahead at the current position (`ts_lexer__get_lookahead`).
    fn getLookahead(self: *Lexer) void {
        const pos = self.current_position.bytes;
        assert(pos >= self.chunk_start);
        assert(pos <= self.chunk_start + self.chunk_size);
        const size = self.chunk_size - (pos - self.chunk_start);
        if (size == 0) {
            self.lookahead_size = 1;
            self.data.lookahead = 0;
            return;
        }
        const chunk = self.source[pos..][0..size];
        if (chunk[0] < 0x80) {
            self.data.lookahead = chunk[0];
            self.lookahead_size = 1;
            return;
        }
        // The reference reads a fresh chunk after a decode error near the end
        // of a chunk. One buffer gives the same bytes, so ztree skips that step.
        const d = utf8.decode(chunk);
        self.data.lookahead = d.code_point;
        self.lookahead_size = d.len;
    }

    /// Move to `position` (`ts_lexer_goto`) with one included range.
    fn goto(self: *Lexer, position: Length) void {
        assert(position.bytes <= self.source.len);
        assert(position.bytes < std.math.maxInt(u32));
        if (position.bytes != self.current_position.bytes) {
            self.column_valid = false;
            self.column_value = 0;
        }
        self.current_position = position;
        // The one range ends at UINT32_MAX, so the position is always inside it.
        self.at_eof = false;
        if (self.chunk_size != 0 and (position.bytes < self.chunk_start or
            position.bytes >= self.chunk_start + self.chunk_size))
        {
            self.clearChunk();
        }
        self.lookahead_size = 0;
        self.data.lookahead = 0;
    }

    /// Consume the lookahead (`ts_lexer__do_advance`).
    fn doAdvance(self: *Lexer, skip: bool) void {
        assert(!self.at_eof);
        assert(self.lookahead_size <= 4);
        if (self.lookahead_size != 0) {
            if (self.data.lookahead == '\n') {
                self.current_position.extent.row += 1;
                self.current_position.extent.column = 0;
                self.setColumn(0);
            } else {
                const is_bom = self.current_position.bytes == 0 and self.data.lookahead == byte_order_mark;
                if (!is_bom and self.column_valid) self.column_value += 1;
                self.current_position.extent.column += self.lookahead_size;
            }
            self.current_position.bytes += self.lookahead_size;
        }
        if (skip) self.token_start_position = self.current_position;
        const pos = self.current_position.bytes;
        if (pos < self.chunk_start or pos >= self.chunk_start + self.chunk_size) self.getChunk();
        self.getLookahead();
    }

    fn fromData(data: *abi.Lexer) *Lexer {
        const self: *Lexer = @fieldParentPtr("data", data);
        assert(self.current_position.bytes <= self.source.len);
        assert(self.lookahead_size <= 4);
        return self;
    }

    fn fromConstData(data: *const abi.Lexer) *const Lexer {
        const self: *const Lexer = @fieldParentPtr("data", data);
        assert(self.current_position.bytes <= self.source.len);
        assert(self.lookahead_size <= 4);
        return self;
    }

    /// `TSLexer.advance` (`ts_lexer__advance`).
    fn advance(data: *abi.Lexer, skip: bool) callconv(.c) void {
        const self = fromData(data);
        if (self.chunk_size == 0) return;
        assert(self.current_position.bytes >= self.chunk_start);
        const next = self.current_position.bytes + 1;
        assert(next <= self.source.len + 1);
        if (self.lookahead_size == 1 and self.data.lookahead != '\n' and
            next < self.chunk_start + self.chunk_size)
        {
            const next_byte = self.source[next];
            if (next_byte < 0x80) {
                if (self.column_valid) self.column_value += 1;
                self.current_position.bytes += 1;
                self.current_position.extent.column += 1;
                if (skip) self.token_start_position = self.current_position;
                self.data.lookahead = next_byte;
                return;
            }
        }
        self.doAdvance(skip);
    }

    /// `TSLexer.mark_end` (`ts_lexer__mark_end`).
    fn markEndCallback(data: *abi.Lexer) callconv(.c) void {
        const self = fromData(data);
        assert(self.token_start_position.bytes <= self.current_position.bytes);
        assert(!length.isUndefined(self.current_position));
        self.markEnd();
    }

    /// `TSLexer.get_column` (`ts_lexer__get_column`): code points since the
    /// start of the row. The first call on a row decodes the row again.
    fn getColumn(data: *abi.Lexer) callconv(.c) u32 {
        const self = fromData(data);
        self.did_get_column = true;
        if (self.column_valid) return self.column_value;
        const goal = self.current_position.bytes;
        assert(goal >= self.current_position.extent.column);
        self.goto(.{
            .bytes = goal - self.current_position.extent.column,
            .extent = .{ .row = self.current_position.extent.row, .column = 0 },
        });
        self.setColumn(0);
        self.getChunk();
        if (!self.at_eof) {
            self.getLookahead();
            // Each step consumes 1 or more bytes, so the row length bounds the loop.
            const bound = goal - self.current_position.bytes;
            var steps: u32 = 0;
            while (steps < bound and self.current_position.bytes < goal and
                !self.at_eof and self.chunk_size != 0) : (steps += 1)
            {
                self.doAdvance(false);
            }
            assert(self.current_position.bytes >= goal or self.at_eof or steps == bound);
        }
        return self.column_value;
    }

    /// `TSLexer.is_at_included_range_start`. The one range starts at byte 0.
    fn isAtIncludedRangeStart(data: *const abi.Lexer) callconv(.c) bool {
        const self = fromConstData(data);
        assert(self.chunk_size <= self.source.len);
        assert(self.current_position.bytes >= self.chunk_start or self.chunk_size == 0);
        return !self.at_eof and self.current_position.bytes == 0;
    }

    /// `TSLexer.eof`.
    fn eof(data: *const abi.Lexer) callconv(.c) bool {
        const self = fromConstData(data);
        assert(!self.at_eof or self.chunk_size == 0);
        assert(self.chunk_start <= self.source.len);
        return self.at_eof;
    }

    /// `TSLexer.log`. ztree has no logger, and no vendored scanner calls it.
    fn log(data: *const abi.Lexer, fmt: [*:0]const u8, ...) callconv(.c) void {
        const self = fromConstData(data);
        assert(fmt[0] != 0 or self.lookahead_size <= 4);
        assert(self.chunk_size <= self.source.len);
    }
};

test "start skips a byte order mark and keeps the column at 0" {
    var lx = try Lexer.init("\xef\xbb\xbfab");
    lx.start();
    try std.testing.expectEqual(@as(i32, 'a'), lx.data.lookahead);
    try std.testing.expectEqual(@as(u32, 3), lx.current_position.bytes);
    try std.testing.expectEqual(@as(u32, 3), lx.token_start_position.bytes);
    try std.testing.expectEqual(@as(u32, 0), Lexer.getColumn(&lx.data));
}

test "advance tracks rows, byte columns and code point columns" {
    var lx = try Lexer.init("é\nxy");
    lx.start();
    Lexer.advance(&lx.data, false);
    try std.testing.expectEqual(@as(u32, 2), lx.current_position.extent.column);
    try std.testing.expectEqual(@as(u32, 1), Lexer.getColumn(&lx.data));
    Lexer.advance(&lx.data, false);
    Lexer.advance(&lx.data, false);
    try std.testing.expectEqual(@as(u32, 1), lx.current_position.extent.row);
    try std.testing.expectEqual(@as(u32, 1), lx.current_position.extent.column);
    Lexer.advance(&lx.data, false);
    try std.testing.expect(Lexer.eof(&lx.data));
    try std.testing.expectEqual(@as(i32, 0), lx.data.lookahead);
}

test "an ill-formed byte becomes a decode error of 1 byte" {
    var lx = try Lexer.init("\xffa");
    lx.start();
    try std.testing.expectEqual(utf8.decode_error, lx.data.lookahead);
    var end: u32 = 0;
    lx.finish(&end);
    try std.testing.expectEqual(@as(u32, 5), end);
}
