//! The compiled query blob (ADR-0008, ADR-0011). It holds no pointers, so a
//! caller can copy it and share it between threads. A header lists the
//! offset and the count of each section. A CRC-32 of the blob protects the
//! indices inside it: `View.init` rejects a damaged blob before the query
//! cursor trusts any index.

const std = @import("std");
const assert = std.debug.assert;
const query = @import("query.zig");
const predicates = @import("query_predicates.zig");
const regex = @import("regex.zig");

pub const magic: u32 = 0x5154_5a5a; // "ZZTQ"
pub const version: u32 = 1;

pub const Section = enum(u32) {
    steps,
    pattern_map,
    patterns,
    predicate_steps,
    negated_fields,
    capture_slices,
    capture_chars,
    value_slices,
    value_chars,
    capture_quantifiers,
    text_predicates,
    pattern_text_predicates,
    any_of_values,
    regexes,
    regex_insts,
    regex_ranges,
    repeat_symbols,
};
const section_count = @backingInt(Section.repeat_symbols) + 1;

/// The element type of each section.
fn ElementType(comptime s: Section) type {
    comptime assert(@backingInt(s) < section_count);
    comptime assert(section_count == 17);
    return switch (s) {
        .steps => query.Step,
        .pattern_map => query.PatternEntry,
        .patterns => query.Pattern,
        .predicate_steps => query.PredicateStep,
        .negated_fields, .repeat_symbols => u16,
        .capture_slices, .value_slices, .pattern_text_predicates => query.Slice,
        .capture_chars, .value_chars => u8,
        .capture_quantifiers => query.Quantifier,
        .text_predicates => predicates.TextPredicate,
        .any_of_values => u32,
        .regexes => predicates.Regex,
        .regex_insts => regex.Inst,
        .regex_ranges => regex.Range,
    };
}

pub const SectionRef = extern struct { offset: u32, count: u32 };

pub const Header = extern struct {
    magic: u32,
    version: u32,
    /// The `ZTREE_LANG_*` value of the grammar.
    lang: u32,
    /// The size of the blob in bytes.
    size: u32,
    /// The CRC-32 of the blob with this field set to 0.
    checksum: u32,
    capture_count: u32,
    wildcard_root_pattern_count: u32,
    sections: [section_count]SectionRef,
};

/// The alignment of the blob and of each section.
pub const alignment = 4;

fn alignUp(n: usize) usize {
    assert(n <= std.math.maxInt(u32));
    assert(alignment == 4);
    return (n + alignment - 1) & ~@as(usize, alignment - 1);
}

/// The data of each section, in section order.
const Parts = struct {
    slices: [section_count][]const u8 = undefined,
    counts: [section_count]u32 = undefined,

    fn set(self: *Parts, comptime s: Section, items: []const ElementType(s)) void {
        assert(items.len <= std.math.maxInt(u32));
        assert(@backingInt(s) < section_count);
        self.slices[@backingInt(s)] = std.mem.sliceAsBytes(items);
        self.counts[@backingInt(s)] = @intCast(items.len);
    }
};

/// Write the blob of a compiled query to `out` when it fits. Return the
/// size of the blob. The quantifiers form a matrix of pattern × capture.
pub fn write(arena: std.mem.Allocator, lang_value: u32, q: *const query.Query, p: *const predicates.Predicates, out: []u8) error{OutOfMemory}!usize {
    assert(lang_value <= 6);
    const capture_count = q.captures.slices.items.len;
    const matrix = try arena.alloc(query.Quantifier, q.patterns.items.len * capture_count);
    @memset(matrix, .zero);
    for (q.capture_quantifiers.items, 0..) |cq, i| @memcpy(matrix[i * capture_count ..][0..cq.items.len], cq.items);
    var parts = Parts{};
    parts.set(.steps, q.steps.items);
    parts.set(.pattern_map, q.pattern_map.items);
    parts.set(.patterns, q.patterns.items);
    parts.set(.predicate_steps, q.predicate_steps.items);
    parts.set(.negated_fields, q.negated_fields.items);
    parts.set(.capture_slices, q.captures.slices.items);
    parts.set(.capture_chars, q.captures.chars.items);
    parts.set(.value_slices, q.values.slices.items);
    parts.set(.value_chars, q.values.chars.items);
    parts.set(.capture_quantifiers, matrix);
    parts.set(.text_predicates, p.items.items);
    parts.set(.pattern_text_predicates, p.per_pattern.items);
    parts.set(.any_of_values, p.any_of_values.items);
    parts.set(.regexes, p.regexes.items);
    parts.set(.regex_insts, p.insts.items);
    parts.set(.regex_ranges, p.ranges.items);
    parts.set(.repeat_symbols, q.repeat_symbols_with_rootless_patterns.items);
    var header = Header{ .magic = magic, .version = version, .lang = lang_value, .size = 0, .checksum = 0, .capture_count = @intCast(capture_count), .wildcard_root_pattern_count = q.wildcard_root_pattern_count, .sections = undefined };
    var size = alignUp(@sizeOf(Header));
    for (&header.sections, parts.slices, parts.counts) |*ref, bytes, n| {
        ref.* = .{ .offset = @intCast(size), .count = n };
        size = alignUp(size + bytes.len);
    }
    header.size = @intCast(size);
    if (size > out.len) return size;
    @memset(out[0..size], 0);
    for (header.sections, parts.slices) |ref, bytes| @memcpy(out[ref.offset..][0..bytes.len], bytes);
    @memcpy(out[0..@sizeOf(Header)], std.mem.asBytes(&header));
    const sum = std.hash.Crc32.hash(out[0..size]);
    @memcpy(out[@offsetOf(Header, "checksum")..][0..4], std.mem.asBytes(&sum));
    assert(size >= @sizeOf(Header));
    return size;
}

pub const ViewError = error{InvalidBlob};

/// A read view of a blob in caller memory.
pub const View = struct {
    blob: []align(alignment) const u8,
    header: Header,

    /// Check the magic, the version, the size, the checksum and the
    /// bounds of each section.
    pub fn init(blob: []align(alignment) const u8) ViewError!View {
        assert(alignment == 4);
        if (blob.len < @sizeOf(Header)) return error.InvalidBlob;
        var header: Header = undefined;
        @memcpy(std.mem.asBytes(&header), blob[0..@sizeOf(Header)]);
        if (header.magic != magic or header.version != version or header.size != blob.len) return error.InvalidBlob;
        var copy_sum = header;
        copy_sum.checksum = 0;
        var crc = std.hash.Crc32.init();
        crc.update(std.mem.asBytes(&copy_sum));
        crc.update(blob[@sizeOf(Header)..]);
        if (crc.final() != header.checksum) return error.InvalidBlob;
        inline for (0..section_count) |i| {
            const ref = header.sections[i];
            const T = ElementType(@fromBackingInt(@as(u32, i)));
            if (ref.offset % alignment != 0 or ref.offset > blob.len) return error.InvalidBlob;
            if (@as(u64, ref.count) * @sizeOf(T) > blob.len - ref.offset) return error.InvalidBlob;
        }
        assert(header.size == blob.len);
        return .{ .blob = blob, .header = header };
    }

    pub fn get(self: *const View, comptime s: Section) []const ElementType(s) {
        const ref = self.header.sections[@backingInt(s)];
        const T = ElementType(s);
        assert(ref.offset + @as(u64, ref.count) * @sizeOf(T) <= self.blob.len);
        assert(ref.offset % alignment == 0);
        const ptr: [*]const T = @ptrCast(@alignCast(self.blob.ptr + ref.offset));
        return ptr[0..ref.count];
    }

    fn tableName(self: *const View, comptime slices: Section, comptime chars: Section, id: u32) []const u8 {
        const s = self.get(slices)[id];
        const c = self.get(chars);
        assert(s.offset + s.length <= c.len);
        assert(id < self.header.sections[@backingInt(slices)].count);
        return c[s.offset..][0..s.length];
    }

    pub fn captureName(self: *const View, id: u32) []const u8 {
        assert(id < self.header.capture_count);
        assert(self.header.capture_count == self.get(.capture_slices).len);
        return self.tableName(.capture_slices, .capture_chars, id);
    }

    pub fn stringValue(self: *const View, id: u32) []const u8 {
        assert(id < self.get(.value_slices).len);
        assert(self.header.sections[@backingInt(Section.value_slices)].count > 0);
        return self.tableName(.value_slices, .value_chars, id);
    }

    /// The regex program at `index`.
    pub fn program(self: *const View, index: u32) regex.Program {
        const r = self.get(.regexes)[index];
        const insts = self.get(.regex_insts);
        const ranges = self.get(.regex_ranges);
        assert(r.insts.offset + r.insts.length <= insts.len);
        assert(r.ranges.offset + r.ranges.length <= ranges.len);
        return .{ .insts = insts[r.insts.offset..][0..r.insts.length], .ranges = ranges[r.ranges.offset..][0..r.ranges.length], .start = r.start };
    }
};

test "a blob round-trips through write and View.init" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const grammars = @import("grammars.zig");
    var failure = query.Failure{};
    var ub = false;
    const q = try query.compile(arena, grammars.language(.go), "((identifier) @id (#match? @id \"^x\") (#any-of? @id \"a\" \"b\"))", &failure, &ub);
    const p = try predicates.compile(q, &failure);
    const size = try write(arena, 0, q, &p, &.{});
    const blob = try arena.alignedAlloc(u8, .fromByteUnits(alignment), size);
    try std.testing.expectEqual(size, try write(arena, 0, q, &p, blob));
    const view = try View.init(blob);
    try std.testing.expectEqualStrings("id", view.captureName(0));
    try std.testing.expectEqual(q.steps.items.len, view.get(.steps).len);
    try std.testing.expectEqual(@as(usize, 2), view.get(.text_predicates).len);
    try std.testing.expectEqual(@as(usize, 2), view.get(.any_of_values).len);
    try std.testing.expect(view.program(0).insts.len > 0);
    blob[size - 1] ^= 1;
    try std.testing.expectError(error.InvalidBlob, View.init(blob));
}
