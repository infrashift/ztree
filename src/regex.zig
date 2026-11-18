//! A bounded regex engine for the `#match?` predicates of queries
//! (ISSUE-012, ADR-0010). The compiler reads a subset of the RE2 syntax of
//! the Go `regexp` package and writes a program with no pointers. A Pike VM
//! runs the program in time O(text × program) with no recursion. A match is
//! a search: the program can match at each position of the text, as
//! `regexp.Match` of Go does. Invalid UTF-8 in the text reads as U+FFFD, one
//! byte at a time, as in Go.

const std = @import("std");
const assert = std.debug.assert;
const utf8 = @import("utf8.zig");

/// The most instructions of one program.
pub const max_insts: u32 = 4096;
/// The most character ranges of one program.
pub const max_ranges: u32 = 4096;
/// The most nested groups.
pub const max_nesting: u32 = 256;
/// The largest count of a repetition, as in Go.
pub const max_repeat: u32 = 1000;
/// The longest pattern.
pub const max_pattern_bytes: usize = 64 * 1024;
/// The most ranges of one character class before it is merged.
const max_class_ranges: u32 = 256;

/// An index that names no instruction.
pub const none: u32 = std.math.maxInt(u32);
/// The bit of an unpatched exit in an `out` field: the field then links to
/// the next exit of the same list.
const hole_bit: u32 = 1 << 31;
const max_rune: u32 = 0x10ffff;
const replacement: u32 = 0xfffd;

pub const Op = enum(u8) {
    /// Consume a character in the ranges `first .. first + count`.
    set,
    /// Consume any character.
    any,
    /// Consume any character except a newline.
    any_not_nl,
    /// Continue at `out` and at `out1`.
    split,
    /// Continue at `out`.
    jump,
    /// Continue at `out` when the assertion `arg` holds.
    assertion,
    /// The program matches.
    match,
};

pub const Assertion = enum(u8) { begin_text, end_text, begin_line, end_line, word_boundary, not_word_boundary };

/// One instruction. The struct has no pointers, so a program can live in a
/// query blob.
pub const Inst = extern struct {
    op: Op,
    arg: u8 = 0,
    reserved: u16 = 0,
    first: u32 = 0,
    count: u32 = 0,
    out: u32 = none,
    out1: u32 = none,
};

/// An inclusive range of code points.
pub const Range = extern struct { lo: u32, hi: u32 };

comptime {
    assert(@sizeOf(Inst) == 20);
    assert(@sizeOf(Range) == 8);
}

/// A compiled pattern.
pub const Program = struct {
    insts: []const Inst,
    ranges: []const Range,
    start: u32,
};

/// `Syntax`: Go rejects the pattern too. `Unsupported`: Go accepts the
/// pattern, but ztree does not read that syntax (ADR-0010). `TooLarge`: the
/// pattern needs more than a hard limit.
pub const Error = error{ Syntax, Unsupported, TooLarge };

/// The byte offset in the pattern of a compile error.
pub const Diagnostic = struct { offset: usize = 0 };

const Flags = struct { fold: bool = false, dot_nl: bool = false, multi_line: bool = false };

/// A part of a program under construction: its entry, the list of its
/// unpatched exits, and its instructions `first .. end`.
const Frag = struct { start: u32, holes: u32, first: u32, end: u32 };

/// An open group: the alternatives so far, the concatenation before the
/// last atom, and the last atom, which a repetition can change.
const Group = struct {
    alt: ?Frag = null,
    seq: ?Frag = null,
    last: ?Frag = null,
    /// The flags to restore at the end of the group.
    flags: Flags,
    open: usize,
};

const posix_classes = [_]struct { []const u8, []const Range }{
    .{ "alnum", &.{ .{ .lo = '0', .hi = '9' }, .{ .lo = 'A', .hi = 'Z' }, .{ .lo = 'a', .hi = 'z' } } },
    .{ "alpha", &.{ .{ .lo = 'A', .hi = 'Z' }, .{ .lo = 'a', .hi = 'z' } } },
    .{ "ascii", &.{.{ .lo = 0, .hi = 0x7f }} },
    .{ "blank", &.{ .{ .lo = '\t', .hi = '\t' }, .{ .lo = ' ', .hi = ' ' } } },
    .{ "cntrl", &.{ .{ .lo = 0, .hi = 0x1f }, .{ .lo = 0x7f, .hi = 0x7f } } },
    .{ "digit", &.{.{ .lo = '0', .hi = '9' }} },
    .{ "graph", &.{.{ .lo = '!', .hi = '~' }} },
    .{ "lower", &.{.{ .lo = 'a', .hi = 'z' }} },
    .{ "print", &.{.{ .lo = ' ', .hi = '~' }} },
    .{ "punct", &.{ .{ .lo = '!', .hi = '/' }, .{ .lo = ':', .hi = '@' }, .{ .lo = '[', .hi = '`' }, .{ .lo = '{', .hi = '~' } } },
    .{ "space", &.{ .{ .lo = '\t', .hi = '\r' }, .{ .lo = ' ', .hi = ' ' } } },
    .{ "upper", &.{.{ .lo = 'A', .hi = 'Z' }} },
    .{ "word", &.{ .{ .lo = '0', .hi = '9' }, .{ .lo = 'A', .hi = 'Z' }, .{ .lo = '_', .hi = '_' }, .{ .lo = 'a', .hi = 'z' } } },
    .{ "xdigit", &.{ .{ .lo = '0', .hi = '9' }, .{ .lo = 'A', .hi = 'F' }, .{ .lo = 'a', .hi = 'f' } } },
};

/// The ranges of a Perl class escape (`\d`, `\s`, `\w`), or null.
fn perlClass(c: u32) ?[]const Range {
    assert(c <= max_rune);
    const ranges: ?[]const Range = switch (c) {
        'd', 'D' => &.{.{ .lo = '0', .hi = '9' }},
        's', 'S' => &.{ .{ .lo = '\t', .hi = '\n' }, .{ .lo = 0x0c, .hi = '\r' }, .{ .lo = ' ', .hi = ' ' } },
        'w', 'W' => posix_classes[12][1],
        else => null,
    };
    assert(ranges == null or ranges.?.len <= 4);
    return ranges;
}

fn isAlnum(c: u32) bool {
    assert(max_rune < hole_bit);
    assert(c <= max_rune);
    return (c >= '0' and c <= '9') or (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z');
}

fn hexValue(c: u32) ?u32 {
    assert(max_rune < hole_bit);
    assert(c <= max_rune);
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// The compiler state. The fixed arrays bound the work of one compile.
const Compiler = struct {
    pattern: []const u8,
    pos: usize = 0,
    insts: []Inst,
    n_insts: u32 = 0,
    ranges: []Range,
    n_ranges: u32 = 0,
    groups: [max_nesting]Group = undefined,
    depth: u32 = 0,
    flags: Flags = .{},
    last_repeat: bool = false,
    class: [max_class_ranges]Range = undefined,
    n_class: u32 = 0,
    err_at: usize = 0,

    fn fail(self: *Compiler, err: Error, at: usize) Error {
        assert(at <= self.pattern.len);
        assert(self.pos <= self.pattern.len);
        self.err_at = at;
        return err;
    }

    /// Decode the next code point of the pattern. Invalid UTF-8 is a syntax error.
    fn next(self: *Compiler) Error!u32 {
        assert(self.pos < self.pattern.len);
        const d = utf8.decode(self.pattern[self.pos..]);
        if (d.code_point < 0) return self.fail(error.Syntax, self.pos);
        self.pos += d.len;
        assert(self.pos <= self.pattern.len);
        return @intCast(d.code_point);
    }

    fn peek(self: *const Compiler) ?u8 {
        assert(self.pattern.len <= max_pattern_bytes);
        assert(self.pos <= self.pattern.len);
        return if (self.pos < self.pattern.len) self.pattern[self.pos] else null;
    }

    fn emit(self: *Compiler, inst: Inst) Error!u32 {
        assert(self.n_insts <= self.insts.len);
        if (self.n_insts >= self.insts.len) return self.fail(error.TooLarge, self.pos);
        const index = self.n_insts;
        self.insts[index] = inst;
        self.n_insts += 1;
        assert(self.n_insts <= max_insts);
        return index;
    }

    /// The field that an exit names.
    fn holeField(self: *Compiler, ref: u32) *u32 {
        assert(ref & hole_bit != 0);
        const index = (ref & ~hole_bit) >> 1;
        assert(index < self.n_insts);
        return if (ref & 1 == 0) &self.insts[index].out else &self.insts[index].out1;
    }

    /// Point each exit of `list` to `target`.
    fn patch(self: *Compiler, list: u32, target: u32) void {
        assert(target < self.n_insts);
        var ref = list;
        var steps: u32 = 0;
        while (ref != none) : (steps += 1) {
            assert(steps <= self.n_insts * 2);
            const field = self.holeField(ref);
            ref = field.*;
            field.* = target;
        }
    }

    /// Join two exit lists.
    fn join(self: *Compiler, a: u32, b: u32) u32 {
        assert(b == none or b & hole_bit != 0);
        if (a == none) return b;
        var ref = a;
        var steps: u32 = 0;
        while (self.holeField(ref).* != none) : (steps += 1) {
            assert(steps <= self.n_insts * 2);
            ref = self.holeField(ref).*;
        }
        self.holeField(ref).* = b;
        return a;
    }

    /// A fragment of one instruction with one exit at `out`.
    fn single(self: *Compiler, inst: Inst) Error!Frag {
        const index = try self.emit(inst);
        assert(self.insts[index].out == none);
        assert(index < hole_bit >> 1);
        return .{ .start = index, .holes = hole_bit | index << 1, .first = index, .end = index + 1 };
    }

    /// A fragment that matches the empty string.
    fn empty(self: *Compiler) Error!Frag {
        assert(self.depth < max_nesting);
        assert(self.n_insts <= self.insts.len);
        return self.single(.{ .op = .jump });
    }

    fn concat(self: *Compiler, a: ?Frag, b: Frag) Frag {
        assert(b.start < self.n_insts);
        const first = a orelse return b;
        assert(first.end <= b.first or b.end <= first.first);
        self.patch(first.holes, b.start);
        return .{ .start = first.start, .holes = b.holes, .first = @min(first.first, b.first), .end = @max(first.end, b.end) };
    }

    fn alternate(self: *Compiler, a: Frag, b: Frag) Error!Frag {
        assert(a.end <= b.first);
        const s = try self.emit(.{ .op = .split, .out = a.start, .out1 = b.start });
        assert(s >= b.end);
        return .{ .start = s, .holes = self.join(a.holes, b.holes), .first = a.first, .end = s + 1 };
    }

    /// `f*`, `f+` or `f?`.
    fn loop(self: *Compiler, f: Frag, op: u32) Error!Frag {
        assert(op == '*' or op == '+' or op == '?');
        const s = try self.emit(.{ .op = .split, .out = f.start });
        const exit = hole_bit | s << 1 | 1;
        assert(self.insts[s].out1 == none);
        switch (op) {
            '*' => {
                self.patch(f.holes, s);
                return .{ .start = s, .holes = exit, .first = f.first, .end = s + 1 };
            },
            '+' => {
                self.patch(f.holes, s);
                return .{ .start = f.start, .holes = exit, .first = f.first, .end = s + 1 };
            },
            else => return .{ .start = s, .holes = self.join(f.holes, exit), .first = f.first, .end = s + 1 },
        }
    }

    /// A copy of `f` at the end of the program. `f` must have all its exits.
    fn copy(self: *Compiler, f: Frag) Error!Frag {
        const delta = self.n_insts - f.first;
        assert(f.first < f.end and f.end <= self.n_insts);
        for (f.first..f.end) |i| {
            var inst = self.insts[i];
            inst.out = relocate(inst.out, delta);
            inst.out1 = relocate(inst.out1, delta);
            const index = try self.emit(inst);
            assert(index == i + delta);
        }
        return .{ .start = f.start + delta, .holes = relocate(f.holes, delta), .first = f.first + delta, .end = f.end + delta };
    }

    /// `f{min,max}`, with `max` null for no upper bound. The copies leave
    /// `f` itself as dead code, so each copy has the exits of `f`.
    fn repeat(self: *Compiler, f: Frag, min: u32, max: ?u32) Error!Frag {
        assert(min <= max_repeat);
        assert(max == null or max.? >= min);
        var result: ?Frag = null;
        for (0..min) |_| result = self.concat(result, try self.copy(f));
        if (max) |m| {
            for (min..m) |_| result = self.concat(result, try self.loop(try self.copy(f), '?'));
        } else {
            result = self.concat(result, try self.loop(try self.copy(f), '*'));
        }
        const r = result orelse try self.empty();
        return .{ .start = r.start, .holes = r.holes, .first = f.first, .end = self.n_insts };
    }

    fn group(self: *Compiler) *Group {
        assert(self.depth < max_nesting);
        assert(self.n_insts <= self.insts.len);
        return &self.groups[self.depth];
    }

    /// Add `f` as the last atom of the current group.
    fn atom(self: *Compiler, f: Frag) void {
        assert(f.start < self.n_insts);
        const g = self.group();
        assert(f.end <= self.n_insts);
        if (g.last) |last| g.seq = self.concat(g.seq, last);
        g.last = f;
    }

    /// The fragment of the current group, at `|` or at the end of the group.
    fn finishBranch(self: *Compiler) Error!Frag {
        assert(self.depth < max_nesting);
        const g = self.group();
        if (g.last) |last| g.seq = self.concat(g.seq, last);
        const branch = g.seq orelse try self.empty();
        g.seq = null;
        g.last = null;
        const result = if (g.alt) |alt| try self.alternate(alt, branch) else branch;
        g.alt = null;
        assert(result.end <= self.n_insts);
        return result;
    }

    fn bar(self: *Compiler) Error!void {
        assert(self.pos <= self.pattern.len);
        const f = try self.finishBranch();
        self.group().alt = f;
        assert(self.group().seq == null);
    }

    /// Apply a repetition to the last atom.
    fn applyRepeat(self: *Compiler, at: usize, min: u32, max: ?u32) Error!void {
        assert(min <= max_repeat + 1);
        if (self.last_repeat) return self.fail(error.Syntax, at);
        const g = self.group();
        const last = g.last orelse return self.fail(error.Syntax, at);
        // A lazy repetition gives the same match result.
        if (self.peek() == '?') self.pos += 1;
        assert(self.pos <= self.pattern.len);
        g.last = if (min == 0 and max == null) try self.loop(last, '*') else if (min == 1 and max == null) try self.loop(last, '+') else if (min == 0 and max == 1) try self.loop(last, '?') else try self.repeat(last, min, max);
    }

    /// A decimal count of `{n,m}`, as Go reads it: no leading zero. A count
    /// above `max_repeat` gives `max_repeat + 1`, which is an error.
    fn count(self: *Compiler) ?u32 {
        assert(self.pos <= self.pattern.len);
        const start = self.pos;
        var value: u32 = 0;
        while (self.peek()) |c| {
            if (c < '0' or c > '9') break;
            value = @min(value * 10 + (c - '0'), max_repeat + 1);
            self.pos += 1;
        }
        assert(value <= max_repeat + 1);
        if (self.pos == start) return null;
        if (self.pos - start >= 2 and self.pattern[start] == '0') return null;
        return value;
    }

    /// `{`: a repetition, or a literal `{` when the text is not a repetition.
    /// Return true for a repetition.
    fn brace(self: *Compiler, at: usize) Error!bool {
        assert(self.pos == at + 1);
        assert(self.pattern[at] == '{');
        const min = self.count();
        var max: ?u32 = min;
        var ok = min != null;
        if (ok and self.peek() == ',') {
            self.pos += 1;
            if (self.peek() == '}') {
                max = null;
            } else {
                max = self.count();
                ok = max != null;
            }
        }
        if (!ok or self.peek() != '}') {
            self.pos = at + 1;
            self.atom(try self.set(&.{.{ .lo = '{', .hi = '{' }}, false));
            return false;
        }
        self.pos += 1;
        if (min.? > max_repeat or (max != null and (max.? > max_repeat or max.? < min.?))) return self.fail(error.Syntax, at);
        try self.applyRepeat(at, min.?, max);
        return true;
    }

    fn assertion(self: *Compiler, kind: Assertion) Error!Frag {
        assert(self.n_insts <= self.insts.len);
        assert(@backingInt(kind) <= @backingInt(Assertion.not_word_boundary));
        return self.single(.{ .op = .assertion, .arg = @backingInt(kind) });
    }

    /// Add `r` to the class under construction.
    fn addRange(self: *Compiler, r: Range) Error!void {
        assert(self.n_class <= max_class_ranges);
        assert(r.lo <= r.hi and r.hi <= max_rune);
        if (self.n_class >= max_class_ranges) return self.fail(error.TooLarge, self.pos);
        self.class[self.n_class] = r;
        self.n_class += 1;
    }

    /// Add `r` and, with the flag `i`, the ASCII case folds of `r`. A
    /// non-ASCII range with the flag `i` is not supported: ztree has no
    /// Unicode fold table.
    fn addFolded(self: *Compiler, r: Range) Error!void {
        assert(r.lo <= r.hi);
        try self.addRange(r);
        if (!self.flags.fold) return;
        if (r.hi >= 0x80) return self.fail(error.Unsupported, self.pos);
        assert(r.lo <= r.hi);
        const lo_a = @max(r.lo, 'a');
        const hi_z = @min(r.hi, 'z');
        if (lo_a <= hi_z) try self.addRange(.{ .lo = lo_a - 32, .hi = hi_z - 32 });
        const lo_up = @max(r.lo, 'A');
        const hi_up = @min(r.hi, 'Z');
        if (lo_up <= hi_up) try self.addRange(.{ .lo = lo_up + 32, .hi = hi_up + 32 });
        // The Unicode simple folds of ASCII letters: K (U+212A) and ſ (U+017F).
        if (inRange(r, 'k') or inRange(r, 'K')) try self.addRange(.{ .lo = 0x212a, .hi = 0x212a });
        if (inRange(r, 's') or inRange(r, 'S')) try self.addRange(.{ .lo = 0x17f, .hi = 0x17f });
    }

    /// Add a class item: folded, then negated when `negated`.
    fn addItem(self: *Compiler, items: []const Range, negated: bool) Error!void {
        assert(items.len > 0);
        const base = self.n_class;
        for (items) |r| try self.addFolded(r);
        if (!negated) return;
        const n = normalize(self.class[base..self.n_class]);
        var tmp: [max_class_ranges + 1]Range = undefined;
        const m = complement(self.class[base..][0..n], &tmp);
        self.n_class = base;
        for (tmp[0..m]) |r| try self.addRange(r);
        assert(self.n_class - base == m);
    }

    /// Emit a `set` instruction for the class under construction, after
    /// `items` when it is not empty.
    fn set(self: *Compiler, items: []const Range, negated: bool) Error!Frag {
        assert(self.n_class <= max_class_ranges);
        if (items.len > 0) {
            self.n_class = 0;
            try self.addItem(items, false);
        }
        var n = normalize(self.class[0..self.n_class]);
        var tmp: [max_class_ranges + 1]Range = undefined;
        const ranges: []const Range = if (negated) tmp[0..complement(self.class[0..n], &tmp)] else self.class[0..n];
        n = @intCast(ranges.len);
        if (self.n_ranges + n > self.ranges.len) return self.fail(error.TooLarge, self.pos);
        @memcpy(self.ranges[self.n_ranges..][0..n], ranges);
        const first = self.n_ranges;
        self.n_ranges += n;
        self.n_class = 0;
        assert(self.n_ranges <= max_ranges);
        return self.single(.{ .op = .set, .first = first, .count = n });
    }

    /// A literal character.
    fn literal(self: *Compiler, c: u32) Error!Frag {
        assert(c <= max_rune);
        self.n_class = 0;
        assert(self.n_class == 0);
        return self.set(&.{.{ .lo = c, .hi = c }}, false);
    }

    /// The character of an escape that names one character (`parseEscape`
    /// of Go). `c` follows the backslash.
    fn escapeChar(self: *Compiler, c: u32, at: usize) Error!u32 {
        assert(c <= max_rune);
        assert(self.pattern[at] == '\\');
        switch (c) {
            'a' => return 0x07,
            'f' => return 0x0c,
            'n' => return '\n',
            'r' => return '\r',
            't' => return '\t',
            'v' => return 0x0b,
            'x' => return self.hexEscape(at),
            '0'...'7' => {
                // A single non-zero digit is a back reference: an error.
                const digit = self.peek();
                if (c != '0' and (digit == null or digit.? < '0' or digit.? > '7')) return self.fail(error.Syntax, at);
                var value = c - '0';
                for (0..2) |_| {
                    const d = self.peek() orelse break;
                    if (d < '0' or d > '7') break;
                    value = value * 8 + (d - '0');
                    self.pos += 1;
                }
                return value;
            },
            else => {
                if (c < 0x80 and !isAlnum(c)) return c;
                return self.fail(error.Syntax, at);
            },
        }
    }

    /// `\xHH` or `\x{H...}`.
    fn hexEscape(self: *Compiler, at: usize) Error!u32 {
        assert(self.pattern[at] == '\\');
        if (self.pos >= self.pattern.len) return self.fail(error.Syntax, at);
        const c = try self.next();
        if (c != '{') {
            const x = hexValue(c) orelse return self.fail(error.Syntax, at);
            if (self.pos >= self.pattern.len) return self.fail(error.Syntax, at);
            const y = hexValue(try self.next()) orelse return self.fail(error.Syntax, at);
            return x * 16 + y;
        }
        var value: u32 = 0;
        var digits: usize = 0;
        while (self.pos < self.pattern.len) : (digits += 1) {
            assert(digits <= max_pattern_bytes);
            const d = try self.next();
            if (d == '}') {
                if (digits == 0) return self.fail(error.Syntax, at);
                return value;
            }
            value = value * 16 + (hexValue(d) orelse return self.fail(error.Syntax, at));
            if (value > max_rune) return self.fail(error.Syntax, at);
        }
        return self.fail(error.Syntax, at);
    }

    /// An escape outside a class.
    fn escape(self: *Compiler, at: usize) Error!void {
        assert(self.pattern[at] == '\\');
        if (self.pos >= self.pattern.len) return self.fail(error.Syntax, at);
        const c = try self.next();
        assert(self.pos <= self.pattern.len);
        const f = switch (c) {
            'A' => try self.assertion(.begin_text),
            'z' => try self.assertion(.end_text),
            'b' => try self.assertion(.word_boundary),
            'B' => try self.assertion(.not_word_boundary),
            'C', 'Q', 'p', 'P' => return self.fail(error.Unsupported, at),
            'd', 'D', 's', 'S', 'w', 'W' => blk: {
                self.n_class = 0;
                try self.addItem(perlClass(c).?, c < 'a');
                break :blk try self.set(&.{}, false);
            },
            else => try self.literal(try self.escapeChar(c, at)),
        };
        self.atom(f);
    }

    /// `[:name:]` or `[:^name:]` at `pos`, or false when the text is not a
    /// POSIX class: the `[` is then a literal.
    fn posixClass(self: *Compiler) Error!bool {
        assert(self.pos < self.pattern.len);
        const rest = self.pattern[self.pos..];
        assert(rest.len >= 2 and rest[0] == '[' and rest[1] == ':');
        const end = std.mem.indexOfPos(u8, rest, 2, ":]") orelse return false;
        const negated = rest.len > 2 and rest[2] == '^';
        const name = rest[(if (negated) 3 else 2)..end];
        for (posix_classes) |entry| {
            if (!std.mem.eql(u8, entry[0], name)) continue;
            try self.addItem(entry[1], negated);
            self.pos += end + 2;
            return true;
        }
        return self.fail(error.Syntax, self.pos);
    }

    /// One character of a class: a literal or an escape (`parseClassChar`).
    fn classChar(self: *Compiler, class_at: usize) Error!u32 {
        assert(self.pattern[class_at] == '[');
        if (self.pos >= self.pattern.len) return self.fail(error.Syntax, class_at);
        const at = self.pos;
        const c = try self.next();
        assert(self.pos > at);
        if (c != '\\') return c;
        if (self.pos >= self.pattern.len) return self.fail(error.Syntax, at);
        return self.escapeChar(try self.next(), at);
    }

    /// One item of a class: a POSIX class, a Perl class, a character or a range.
    fn classItem(self: *Compiler, class_at: usize) Error!void {
        assert(self.pattern[class_at] == '[');
        const rest = self.pattern[self.pos..];
        assert(rest.len > 0);
        if (rest.len > 2 and rest[0] == '[' and rest[1] == ':' and try self.posixClass()) return;
        if (rest.len >= 2 and rest[0] == '\\') {
            if (rest[1] == 'p' or rest[1] == 'P') return self.fail(error.Unsupported, self.pos);
            if (perlClass(rest[1])) |ranges| {
                self.pos += 2;
                return self.addItem(ranges, rest[1] < 'a');
            }
        }
        const lo = try self.classChar(class_at);
        var hi = lo;
        const after = self.pattern[self.pos..];
        if (after.len >= 2 and after[0] == '-' and after[1] != ']') {
            self.pos += 1;
            hi = try self.classChar(class_at);
            if (hi < lo) return self.fail(error.Syntax, class_at);
        }
        try self.addFolded(.{ .lo = lo, .hi = hi });
    }

    /// `[...]` after the `[` at `at`.
    fn class_(self: *Compiler, at: usize) Error!void {
        self.n_class = 0;
        const negated = self.peek() == '^';
        if (negated) self.pos += 1;
        var first = true;
        var steps: usize = 0;
        while (first or self.peek() != ']') : (steps += 1) {
            assert(steps <= max_pattern_bytes);
            if (self.pos >= self.pattern.len) return self.fail(error.Syntax, at);
            try self.classItem(at);
            first = false;
        }
        self.pos += 1;
        assert(self.pattern[self.pos - 1] == ']');
        self.atom(try self.set(&.{}, negated));
    }
};

fn inRange(r: Range, c: u32) bool {
    assert(r.lo <= r.hi);
    assert(c <= max_rune);
    return r.lo <= c and c <= r.hi;
}

/// Shift an instruction index or an exit link by `delta` instructions.
fn relocate(value: u32, delta: u32) u32 {
    assert(value == none or value & ~hole_bit < 2 * max_insts);
    assert(delta < hole_bit >> 1);
    if (value == none) return none;
    return if (value & hole_bit != 0) value + 2 * delta else value + delta;
}

fn lessThan(_: void, a: Range, b: Range) bool {
    assert(a.lo <= a.hi);
    assert(b.lo <= b.hi);
    return a.lo < b.lo;
}

/// Sort and merge the ranges in place. Return the new count.
fn normalize(ranges: []Range) u32 {
    assert(ranges.len <= max_class_ranges);
    if (ranges.len == 0) return 0;
    std.mem.sort(Range, ranges, {}, lessThan);
    var n: u32 = 1;
    for (ranges[1..]) |r| {
        const last = &ranges[n - 1];
        if (r.lo <= last.hi +| 1) {
            last.hi = @max(last.hi, r.hi);
        } else {
            ranges[n] = r;
            n += 1;
        }
    }
    assert(n <= ranges.len);
    return n;
}

/// Write the complement of sorted, merged ranges in [0, U+10FFFF] to `out`.
fn complement(ranges: []const Range, out: []Range) u32 {
    assert(out.len > ranges.len);
    var n: u32 = 0;
    var next: u32 = 0;
    for (ranges) |r| {
        if (r.lo > next) {
            out[n] = .{ .lo = next, .hi = r.lo - 1 };
            n += 1;
        }
        next = r.hi + 1;
    }
    if (next <= max_rune) {
        out[n] = .{ .lo = next, .hi = max_rune };
        n += 1;
    }
    assert(n <= ranges.len + 1);
    return n;
}

/// Read the flags after `(?` (`parsePerlFlags` of Go). `(?flags:` opens a
/// group, and `(?flags)` sets the flags of the current group.
fn flagGroup(c: *Compiler, at: usize) Error!void {
    assert(c.pattern[at] == '(');
    var flags = c.flags;
    var negative = false;
    var saw_flag = false;
    var steps: usize = 0;
    while (c.pos < c.pattern.len) : (steps += 1) {
        assert(steps <= max_pattern_bytes);
        const ch = try c.next();
        switch (ch) {
            'i', 'm', 's', 'U' => {
                const on = !negative;
                if (ch == 'i') flags.fold = on;
                if (ch == 'm') flags.multi_line = on;
                if (ch == 's') flags.dot_nl = on;
                saw_flag = true;
            },
            '-' => {
                if (negative) return c.fail(error.Syntax, at);
                negative = true;
                saw_flag = false;
            },
            ':', ')' => {
                if (negative and !saw_flag) return c.fail(error.Syntax, at);
                if (ch == ':') try openGroup(c, at);
                c.flags = flags;
                return;
            },
            else => return c.fail(error.Syntax, at),
        }
    }
    return c.fail(error.Syntax, at);
}

fn openGroup(c: *Compiler, at: usize) Error!void {
    assert(c.pattern[at] == '(');
    if (c.depth + 1 >= max_nesting) return c.fail(error.TooLarge, at);
    c.depth += 1;
    c.groups[c.depth] = .{ .flags = c.flags, .open = at };
    assert(c.depth < max_nesting);
}

fn closeGroup(c: *Compiler, at: usize) Error!void {
    assert(c.pattern[at] == ')');
    if (c.depth == 0) return c.fail(error.Syntax, at);
    const f = try c.finishBranch();
    c.flags = c.groups[c.depth].flags;
    c.depth -= 1;
    c.atom(f);
    assert(c.depth < max_nesting);
}

/// `(`: a group, a flag group, or an unsupported named group.
fn paren(c: *Compiler, at: usize) Error!void {
    assert(c.pos == at + 1);
    assert(c.pattern[at] == '(');
    if (c.peek() != '?') return openGroup(c, at);
    c.pos += 1;
    const kind = c.peek() orelse return c.fail(error.Syntax, at);
    if (kind == 'P' or kind == '<') return c.fail(error.Unsupported, at);
    try flagGroup(c, at);
}

/// Read one token of the pattern.
fn token(c: *Compiler) Error!void {
    assert(c.pos < c.pattern.len);
    const at = c.pos;
    const ch = try c.next();
    var repeat = false;
    switch (ch) {
        '(' => try paren(c, at),
        ')' => try closeGroup(c, at),
        '|' => try c.bar(),
        '*' => try c.applyRepeat(at, 0, null),
        '+' => try c.applyRepeat(at, 1, null),
        '?' => try c.applyRepeat(at, 0, 1),
        '{' => repeat = try c.brace(at),
        '^' => c.atom(try c.assertion(if (c.flags.multi_line) .begin_line else .begin_text)),
        '$' => c.atom(try c.assertion(if (c.flags.multi_line) .end_line else .end_text)),
        '.' => c.atom(try c.single(.{ .op = if (c.flags.dot_nl) .any else .any_not_nl })),
        '[' => try c.class_(at),
        '\\' => try c.escape(at),
        else => c.atom(try c.literal(ch)),
    }
    c.last_repeat = repeat or ch == '*' or ch == '+' or ch == '?';
    assert(c.pos > at);
}

/// Compile `pattern` into `insts` and `ranges`. On an error, `diag` holds
/// the byte offset of the error in the pattern.
pub fn compile(pattern: []const u8, insts: []Inst, ranges: []Range, diag: *Diagnostic) Error!Program {
    assert(insts.len <= max_insts);
    assert(ranges.len <= max_ranges);
    diag.offset = 0;
    if (pattern.len > max_pattern_bytes) return error.TooLarge;
    var c = Compiler{ .pattern = pattern, .insts = insts, .ranges = ranges };
    c.groups[0] = .{ .flags = .{}, .open = 0 };
    const start = run(&c) catch |err| {
        diag.offset = c.err_at;
        return err;
    };
    return .{ .insts = insts[0..c.n_insts], .ranges = ranges[0..c.n_ranges], .start = start };
}

fn run(c: *Compiler) Error!u32 {
    var steps: usize = 0;
    while (c.pos < c.pattern.len) : (steps += 1) {
        assert(steps <= max_pattern_bytes);
        try token(c);
    }
    if (c.depth > 0) return c.fail(error.Syntax, c.groups[c.depth].open);
    const f = try c.finishBranch();
    const m = try c.emit(.{ .op = .match });
    c.patch(f.holes, m);
    assert(c.n_insts <= max_insts);
    return f.start;
}

/// A set of instruction indices with O(1) insert and clear.
const SparseSet = struct {
    sparse: []u32,
    dense: []u32,
    len: u32 = 0,

    fn contains(self: *const SparseSet, x: u32) bool {
        assert(self.len <= self.dense.len);
        assert(x < self.sparse.len);
        const i = self.sparse[x];
        return i < self.len and self.dense[i] == x;
    }

    fn insert(self: *SparseSet, x: u32) void {
        assert(!self.contains(x));
        self.sparse[x] = self.len;
        self.dense[self.len] = x;
        self.len += 1;
        assert(self.len <= self.dense.len);
    }
};

/// The number of `u32` words of scratch memory that `isMatch` needs.
pub fn scratchLen(prog: Program) usize {
    assert(prog.insts.len > 0);
    assert(prog.insts.len <= max_insts);
    return prog.insts.len * 6 + 2;
}

fn isWordChar(c: ?u32) bool {
    assert(c == null or c.? <= max_rune);
    const ch = c orelse return false;
    assert(ch <= max_rune);
    return ch == '_' or isAlnum(ch);
}

/// The characters around one position of the text.
const Context = struct { prev: ?u32, cur: ?u32 };

fn holds(kind: Assertion, ctx: Context) bool {
    assert(ctx.prev == null or ctx.prev.? <= max_rune);
    assert(ctx.cur == null or ctx.cur.? <= max_rune);
    return switch (kind) {
        .begin_text => ctx.prev == null,
        .end_text => ctx.cur == null,
        .begin_line => ctx.prev == null or ctx.prev.? == '\n',
        .end_line => ctx.cur == null or ctx.cur.? == '\n',
        .word_boundary => isWordChar(ctx.prev) != isWordChar(ctx.cur),
        .not_word_boundary => isWordChar(ctx.prev) == isWordChar(ctx.cur),
    };
}

fn inSet(prog: Program, inst: Inst, c: u32) bool {
    const ranges = prog.ranges[inst.first..][0..inst.count];
    assert(c <= max_rune);
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (c < ranges[mid].lo) hi = mid else if (c > ranges[mid].hi) lo = mid + 1 else return true;
    }
    assert(lo == hi);
    return false;
}

/// The Pike VM state of one match.
const Vm = struct {
    prog: Program,
    stack: []u32,

    /// Add the thread at `pc` and its epsilon closure to `list`. Return
    /// true when the closure reaches `match`.
    fn add(self: *Vm, list: *SparseSet, pc: u32, ctx: Context) bool {
        var top: usize = 0;
        self.stack[top] = pc;
        top += 1;
        var steps: usize = 0;
        while (top > 0) : (steps += 1) {
            assert(steps <= self.stack.len);
            top -= 1;
            const p = self.stack[top];
            if (p == none or list.contains(p)) continue;
            list.insert(p);
            const inst = self.prog.insts[p];
            switch (inst.op) {
                .match => return true,
                .jump => self.push(&top, inst.out),
                .split => {
                    self.push(&top, inst.out1);
                    self.push(&top, inst.out);
                },
                .assertion => if (holds(@fromBackingInt(@intCast(inst.arg)), ctx)) self.push(&top, inst.out),
                .set, .any, .any_not_nl => {},
            }
        }
        assert(list.len <= self.prog.insts.len);
        return false;
    }

    fn push(self: *Vm, top: *usize, pc: u32) void {
        assert(top.* < self.stack.len);
        assert(pc == none or pc < self.prog.insts.len);
        self.stack[top.*] = pc;
        top.* += 1;
    }

    /// Step each thread of `clist` over `c` into `nlist`.
    fn step(self: *Vm, clist: *const SparseSet, nlist: *SparseSet, c: u32, ctx: Context) bool {
        assert(c <= max_rune);
        assert(nlist.len == 0);
        for (clist.dense[0..clist.len]) |pc| {
            const inst = self.prog.insts[pc];
            const ok = switch (inst.op) {
                .set => inSet(self.prog, inst, c),
                .any => true,
                .any_not_nl => c != '\n',
                else => false,
            };
            if (ok and self.add(nlist, inst.out, ctx)) return true;
        }
        return false;
    }
};

/// Decode the character at `i`, or null at the end of the text.
fn charAt(text: []const u8, i: usize) struct { ?u32, usize } {
    assert(i <= text.len);
    if (i == text.len) return .{ null, 0 };
    const d = utf8.decode(text[i..]);
    assert(d.len >= 1 and d.len <= 4);
    return .{ if (d.code_point < 0) replacement else @intCast(d.code_point), d.len };
}

/// True when `prog` matches somewhere in `text` (`regexp.Match` of Go).
/// `scratch` holds `scratchLen(prog)` words.
pub fn isMatch(prog: Program, text: []const u8, scratch: []u32) bool {
    assert(prog.start < prog.insts.len);
    const m = prog.insts.len;
    assert(scratch.len >= scratchLen(prog));
    @memset(scratch[0 .. 2 * m], 0);
    var lists = [2]SparseSet{
        .{ .sparse = scratch[0..m], .dense = scratch[2 * m .. 3 * m] },
        .{ .sparse = scratch[m .. 2 * m], .dense = scratch[3 * m .. 4 * m] },
    };
    var vm = Vm{ .prog = prog, .stack = scratch[4 * m ..] };
    var prev: ?u32 = null;
    var i: usize = 0;
    var cur, var width = charAt(text, 0);
    var steps: usize = 0;
    // Each step reads one character, and the last step reads the end.
    while (steps <= text.len) : (steps += 1) {
        const clist = &lists[steps % 2];
        const nlist = &lists[(steps + 1) % 2];
        if (vm.add(clist, prog.start, .{ .prev = prev, .cur = cur })) return true;
        const c = cur orelse return false;
        const after, const after_width = charAt(text, i + width);
        nlist.len = 0;
        if (vm.step(clist, nlist, c, .{ .prev = c, .cur = after })) return true;
        clist.len = 0;
        prev = c;
        i += width;
        cur = after;
        width = after_width;
    }
    unreachable;
}

fn testMatch(pattern: []const u8, text: []const u8) !bool {
    var insts: [max_insts]Inst = undefined;
    var ranges: [max_ranges]Range = undefined;
    var diag = Diagnostic{};
    const prog = try compile(pattern, &insts, &ranges, &diag);
    var scratch: [max_insts * 6 + 2]u32 = undefined;
    return isMatch(prog, text, &scratch);
}

test "isMatch searches the text as regexp.Match does" {
    const cases = [_]struct { []const u8, []const u8, bool }{
        .{ "", "", true },                                                   .{ "a", "xay", true },
        .{ "^a", "xa", false },                                              .{ "a$", "ab", false },
        .{ "a$", "a\n", false },                                             .{ "(?m)a$", "a\nb", true },
        .{ "(?m)^b", "a\nb", true },                                         .{ "^b", "a\nb", false },
        .{ "a.c", "a\nc", false },                                           .{ "(?s)a.c", "a\nc", true },
        .{ "ab*c", "ac", true },                                             .{ "ab+c", "ac", false },
        .{ "ab?c", "abbc", false },                                          .{ "a{2,3}", "a", false },
        .{ "^a{2,3}$", "aaa", true },                                        .{ "^a{2,3}$", "aaaa", false },
        .{ "^a{2,}$", "aaaaa", true },                                       .{ "^(ab|cd){2}$", "abcd", true },
        .{ "[a-c]x", "bx", true },                                           .{ "[^a-c]x", "bx", false },
        .{ "[^a]", "\n", true },                                             .{ "\\d+", "x42", true },
        .{ "^\\w+$", "a_1", true },                                          .{ "^\\S$", " ", false },
        .{ "\\bfoo\\b", "a foo.", true },                                    .{ "\\bfoo\\b", "afoo", false },
        .{ "(?i)HeLLo", "hello", true },                                     .{ "(?i)k", "\u{212a}", true },
        .{ "(?i)[^k]", "K", false },                                         .{ "(?i:a)b", "AB", false },
        .{ "[[:upper:]]+", "abC", true },                                    .{ "[[:^alpha:]]", "ab", false },
        .{ "a{", "a{", true },                                               .{ "a{,2}", "a{,2}", true },
        .{ "\\x41\\x{42}", "AB", true },                                     .{ "\\101", "A", true },
        .{ "a|", "x", true },                                                .{ "\\.", "a", false },
        .{ "^.$", "\xff", true },                                            .{ "^\u{fffd}$", "\xff", true },
        .{ "^.$", "é", true },
        .{ "^[à-ÿ]$", "é", true },
        .{ "NOLINT(\\([^)]*\\))?\\s*(\\*/)?$", "// NOLINT(rule) */", true }, .{ "^//\\s*nolint(:[A-Za-z0-9_,-]+)?\\s*$", "// nolint:errcheck", true },
        .{ "#\\s*(noqa|type:\\s*ignore)\\s*$", "x  # type: ignore", true },
    };
    for (cases) |case| {
        const got = try testMatch(case[0], case[1]);
        if (got != case[2]) std.debug.print("pattern {s} text {s}: got {}\n", .{ case[0], case[1], got });
        try std.testing.expectEqual(case[2], got);
    }
}

test "compile reports syntax errors, unsupported syntax and limits" {
    const cases = [_]struct { []const u8, Error, usize }{
        .{ "a**", error.Syntax, 2 },            .{ "*", error.Syntax, 0 },                 .{ "(a", error.Syntax, 0 },
        .{ "a)", error.Syntax, 1 },             .{ "[a", error.Syntax, 0 },                .{ "[z-a]", error.Syntax, 0 },
        .{ "a{2,1}", error.Syntax, 1 },         .{ "a{1001}", error.Syntax, 1 },           .{ "\\1", error.Syntax, 0 },
        .{ "\\e", error.Syntax, 0 },            .{ "x\\", error.Syntax, 1 },               .{ "(?x)", error.Syntax, 0 },
        .{ "(?-)", error.Syntax, 0 },           .{ "[[:foo:]]", error.Syntax, 1 },         .{ "\xff", error.Syntax, 0 },
        .{ "a{99999999999}", error.Syntax, 1 }, .{ "\\pL", error.Unsupported, 0 },         .{ "(?P<n>a)", error.Unsupported, 0 },
        .{ "(?i)é", error.Unsupported, 4 },
        .{ "\\Qa\\E", error.Unsupported, 0 },   .{ "(a{1000}){1000}", error.TooLarge, 0 },
    };
    for (cases) |case| {
        var insts: [max_insts]Inst = undefined;
        var ranges: [max_ranges]Range = undefined;
        var diag = Diagnostic{};
        try std.testing.expectError(case[1], compile(case[0], &insts, &ranges, &diag));
        if (case[1] == error.Syntax) try std.testing.expectEqual(case[2], diag.offset);
    }
}
