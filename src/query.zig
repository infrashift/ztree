//! The query compiler (ISSUE-013, ADR-0011). It parses the Tree-sitter
//! query language into the steps of the reference runtime (`ts_query_new`
//! of `query.c`), with an explicit frame stack in place of the recursion of
//! `ts_query__parse_pattern`. `query_analysis.zig` then checks each pattern
//! against the parse table, and `query_blob.zig` writes the result into a
//! blob with no pointers.

const std = @import("std");
const assert = std.debug.assert;
const abi = @import("abi.zig");
const language = @import("language.zig");
const utf8 = @import("utf8.zig");

const Language = abi.Language14;
const Symbol = abi.Symbol;
const FieldId = abi.FieldId;

/// `NONE` and `PATTERN_DONE_MARKER` of the reference.
pub const none: u16 = std.math.maxInt(u16);
pub const wildcard: Symbol = 0;
pub const max_step_captures = 3;
pub const max_negated_fields = 8;
/// The longest query text.
pub const max_query_bytes: usize = 1024 * 1024;
/// The most steps: a step index is a `u16` below `none`.
pub const max_steps: usize = none - 1;
/// The deepest nesting of patterns.
pub const max_nesting: usize = 1024;

pub const StepFlags = packed struct(u16) {
    is_named: bool = false,
    is_immediate: bool = false,
    is_last_child: bool = false,
    is_pass_through: bool = false,
    is_dead_end: bool = false,
    is_inside_alternation: bool = false,
    contains_captures: bool = false,
    root_pattern_guaranteed: bool = false,
    parent_pattern_guaranteed: bool = false,
    is_missing: bool = false,
    alternative_is_skip: bool = false,
    reserved: u5 = 0,
};

/// `QueryStep`.
pub const Step = extern struct {
    symbol: Symbol,
    supertype_symbol: Symbol = 0,
    field: FieldId = 0,
    capture_ids: [max_step_captures]u16 = .{ none, none, none },
    depth: u16,
    alternative_index: u16 = none,
    negated_field_list_id: u16 = 0,
    flags: StepFlags = .{},

    fn init(symbol: Symbol, depth: u16, is_immediate: bool) Step {
        assert(depth <= none);
        assert(symbol <= none);
        return .{ .symbol = symbol, .depth = depth, .flags = .{ .is_immediate = is_immediate } };
    }

    fn addCapture(self: *Step, capture_id: u16) void {
        assert(capture_id != none);
        for (&self.capture_ids) |*id| {
            if (id.* == none) {
                id.* = capture_id;
                break;
            }
        }
        assert(self.capture_ids[0] != none);
    }
};

/// `PatternEntry`.
pub const PatternEntry = extern struct { step_index: u16, pattern_index: u16, is_rooted: u16 };
pub const Slice = extern struct { offset: u32, length: u32 };
/// `QueryPattern`.
pub const Pattern = extern struct {
    steps: Slice,
    predicate_steps: Slice,
    start_byte: u32,
    end_byte: u32,
    is_non_local: u32,
};
/// `TSQueryPredicateStep`.
pub const PredicateStep = extern struct { kind: PredicateStepKind, value_id: u32 };
pub const PredicateStepKind = enum(u32) { done = 0, capture = 1, string = 2 };
pub const StepOffset = struct { byte_offset: u32, step_index: u16 };
/// `TSQuantifier`.
pub const Quantifier = enum(u8) { zero, zero_or_one, zero_or_more, one, one_or_more };

/// The error kinds of `ztree_query_compile`. The first values are those of
/// `TSQueryError`. `predicate` is a predicate that go-tree-sitter rejects.
/// `unsupported` is valid syntax outside the scope of ztree (ADR-0007).
pub const ErrorKind = enum(u32) { none = 0, syntax = 1, node_type = 2, field = 3, capture = 4, structure = 5, language = 6, predicate = 7, unsupported = 8 };

pub const Error = error{ QueryError, OutOfMemory, TooLarge };

/// A two-way map of strings to ids (`SymbolTable`).
pub const SymbolTable = struct {
    chars: std.ArrayList(u8) = .empty,
    slices: std.ArrayList(Slice) = .empty,

    pub fn idFor(self: *const SymbolTable, text: []const u8) ?u16 {
        assert(self.chars.items.len <= std.math.maxInt(u32));
        assert(self.slices.items.len <= none);
        for (self.slices.items, 0..) |s, i| {
            if (std.mem.eql(u8, self.chars.items[s.offset..][0..s.length], text)) return @intCast(i);
        }
        return null;
    }

    pub fn insert(self: *SymbolTable, arena: std.mem.Allocator, text: []const u8) Error!u16 {
        assert(text.len <= max_query_bytes);
        if (self.idFor(text)) |id| return id;
        if (self.slices.items.len >= none) return error.TooLarge;
        const offset: u32 = @intCast(self.chars.items.len);
        try self.chars.appendSlice(arena, text);
        try self.chars.append(arena, 0);
        try self.slices.append(arena, .{ .offset = offset, .length = @intCast(text.len) });
        assert(self.slices.items.len <= none);
        return @intCast(self.slices.items.len - 1);
    }

    pub fn name(self: *const SymbolTable, id: u16) []const u8 {
        assert(id < self.slices.items.len);
        const s = self.slices.items[id];
        assert(s.offset + s.length <= self.chars.items.len);
        return self.chars.items[s.offset..][0..s.length];
    }
};

/// The quantifier tables of the reference (`quantifier_mul`, `quantifier_join`, `quantifier_add`).
const Q = Quantifier;
const mul_table = [5][5]Q{
    .{ .zero, .zero, .zero, .zero, .zero },
    .{ .zero, .zero_or_one, .zero_or_more, .zero_or_one, .zero_or_more },
    .{ .zero, .zero_or_more, .zero_or_more, .zero_or_more, .zero_or_more },
    .{ .zero, .zero_or_one, .zero_or_more, .one, .one_or_more },
    .{ .zero, .zero_or_more, .zero_or_more, .one_or_more, .one_or_more },
};
const join_table = [5][5]Q{
    .{ .zero, .zero_or_one, .zero_or_more, .zero_or_one, .zero_or_more },
    .{ .zero_or_one, .zero_or_one, .zero_or_more, .zero_or_one, .zero_or_more },
    .{ .zero_or_more, .zero_or_more, .zero_or_more, .zero_or_more, .zero_or_more },
    .{ .zero_or_one, .zero_or_one, .zero_or_more, .one, .one_or_more },
    .{ .zero_or_more, .zero_or_more, .zero_or_more, .one_or_more, .one_or_more },
};
const add_table = [5][5]Q{
    .{ .zero, .zero_or_one, .zero_or_more, .one, .one_or_more },
    .{ .zero_or_one, .zero_or_more, .zero_or_more, .one_or_more, .one_or_more },
    .{ .zero_or_more, .zero_or_more, .zero_or_more, .one_or_more, .one_or_more },
    .{ .one, .one_or_more, .one_or_more, .one_or_more, .one_or_more },
    .{ .one_or_more, .one_or_more, .one_or_more, .one_or_more, .one_or_more },
};

fn qOp(table: *const [5][5]Q, a: Q, b: Q) Q {
    assert(@backingInt(a) < 5);
    assert(@backingInt(b) < 5);
    return table[@backingInt(a)][@backingInt(b)];
}

/// The quantifier of each capture id in one pattern (`CaptureQuantifiers`).
pub const CaptureQuantifiers = std.ArrayList(Q);

fn cqGrow(arena: std.mem.Allocator, self: *CaptureQuantifiers, len: usize) Error!void {
    assert(len <= none);
    while (self.items.len < len) try self.append(arena, .zero);
    assert(self.items.len >= len);
}

fn cqAddFor(arena: std.mem.Allocator, self: *CaptureQuantifiers, id: u16, q: Q) Error!void {
    assert(id != none);
    try cqGrow(arena, self, @as(usize, id) + 1);
    self.items[id] = qOp(&add_table, self.items[id], q);
    assert(self.items.len > id);
}

fn cqAddAll(arena: std.mem.Allocator, self: *CaptureQuantifiers, other: []const Q) Error!void {
    assert(other.len <= none);
    try cqGrow(arena, self, other.len);
    for (other, 0..) |q, i| self.items[i] = qOp(&add_table, self.items[i], q);
    assert(self.items.len >= other.len);
}

fn cqJoinAll(arena: std.mem.Allocator, self: *CaptureQuantifiers, other: []const Q) Error!void {
    assert(other.len <= none);
    try cqGrow(arena, self, other.len);
    for (self.items, 0..) |*q, i| q.* = qOp(&join_table, q.*, if (i < other.len) other[i] else .zero);
    assert(self.items.len >= other.len);
}

fn cqMul(self: *CaptureQuantifiers, q: Q) void {
    assert(@backingInt(q) < 5);
    assert(self.items.len <= none);
    for (self.items) |*own| own.* = qOp(&mul_table, own.*, q);
}

/// `Stream`: the code points of the query text.
const Stream = struct {
    src: []const u8,
    pos: usize = 0,
    next: i32 = 0,
    next_size: u8 = 0,

    fn advance(self: *Stream) bool {
        assert(self.next_size <= 4);
        self.pos += self.next_size;
        assert(self.pos <= self.src.len);
        if (self.pos < self.src.len) {
            const d = utf8.decode(self.src[self.pos..]);
            self.next = d.code_point;
            self.next_size = @intCast(d.len);
            return true;
        }
        self.next_size = 0;
        self.next = 0;
        return false;
    }

    fn reset(self: *Stream, pos: usize) void {
        assert(pos <= self.src.len);
        self.pos = pos;
        self.next_size = 0;
        const more = self.advance();
        assert(more or self.pos == self.src.len);
    }

    fn isSpace(c: i32) bool {
        assert(c <= 0x10ffff);
        assert(c >= -1);
        return c == ' ' or (c >= '\t' and c <= '\r');
    }

    fn isAlnum(c: i32) bool {
        assert(c <= 0x10ffff);
        assert(c >= -1);
        return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
    }

    fn skipWhitespace(self: *Stream) void {
        assert(self.src.len <= max_query_bytes);
        var steps: usize = 0;
        while (steps <= self.src.len) : (steps += 1) {
            if (isSpace(self.next)) {
                _ = self.advance(); // nasa-lint: allow(R7) the end of the text sets next to 0
            } else if (self.next == ';') {
                _ = self.advance(); // nasa-lint: allow(R7) the end of the text sets next to 0
                while (self.next != 0 and self.next != '\n') {
                    if (!self.advance()) break;
                }
            } else break;
        }
        assert(self.pos <= self.src.len);
    }

    fn isIdentStart(self: *const Stream) bool {
        assert(self.next >= -1);
        assert(self.pos <= self.src.len);
        return isAlnum(self.next) or self.next == '_' or self.next == '-';
    }

    fn scanIdentifier(self: *Stream) void {
        assert(self.pos < self.src.len);
        assert(self.isIdentStart());
        _ = self.advance(); // nasa-lint: allow(R7) the end of the text sets next to 0
        while (isAlnum(self.next) or self.next == '_' or self.next == '-' or self.next == '.') {
            _ = self.advance(); // nasa-lint: allow(R7) the end of the text sets next to 0
        }
    }

    fn offset(self: *const Stream) u32 {
        assert(self.pos <= self.src.len);
        assert(self.src.len <= max_query_bytes);
        return @intCast(self.pos);
    }
};

/// The compiled query, before `query_blob.zig` writes it (`TSQuery`).
pub const Query = struct {
    arena: std.mem.Allocator,
    lang: *const Language,
    steps: std.ArrayList(Step) = .empty,
    pattern_map: std.ArrayList(PatternEntry) = .empty,
    patterns: std.ArrayList(Pattern) = .empty,
    predicate_steps: std.ArrayList(PredicateStep) = .empty,
    step_offsets: std.ArrayList(StepOffset) = .empty,
    negated_fields: std.ArrayList(FieldId) = .empty,
    captures: SymbolTable = .{},
    values: SymbolTable = .{},
    capture_quantifiers: std.ArrayList(CaptureQuantifiers) = .empty,
    repeat_symbols_with_rootless_patterns: std.ArrayList(Symbol) = .empty,
    wildcard_root_pattern_count: u16 = 0,
    /// The byte offset of each predicate, in order, for error messages.
    predicate_offsets: std.ArrayList(u32) = .empty,
    /// True for input where the reference runtime has undefined behavior:
    /// a capture or a quantifier after a pattern with no step (an assertion
    /// fails), or a first string literal that is empty (a null pointer goes
    /// to `strncmp`). ztree gives a syntax error or a normal result. The
    /// tests do not run the reference on this input.
    reference_ub: bool = false,
    string_buffer: std.ArrayList(u8) = .empty,

    pub fn pushStep(self: *Query, step: Step) Error!void {
        assert(step.depth == none or step.depth < none - 1);
        if (self.steps.items.len >= max_steps) return error.TooLarge;
        try self.steps.append(self.arena, step);
        assert(self.steps.items.len <= max_steps);
    }

    fn stepCount(self: *const Query) u16 {
        assert(self.steps.items.len <= max_steps);
        assert(max_steps < none);
        return @intCast(self.steps.items.len);
    }

    /// `ts_language_symbol_for_name`.
    fn symbolForName(self: *const Query, name: []const u8, is_named: bool) Symbol {
        assert(name.len <= max_query_bytes);
        if (is_named and std.mem.eql(u8, name, "ERROR")) return abi.builtin_sym_error;
        const count = self.lang.symbol_count + self.lang.alias_count;
        assert(count < none);
        for (0..count) |i| {
            const m = language.symbolMetadata(self.lang, @intCast(i));
            if ((!m.visible and !m.supertype) or m.named != is_named) continue;
            if (std.mem.eql(u8, std.mem.span(self.lang.symbol_names.?[i]), name)) return self.lang.public_symbol_map.?[i];
        }
        return 0;
    }

    /// `ts_language_field_id_for_name`.
    fn fieldForName(self: *const Query, name: []const u8) FieldId {
        assert(name.len <= max_query_bytes);
        assert(self.lang.field_count < none);
        for (1..self.lang.field_count + 1) |i| {
            if (std.mem.eql(u8, std.mem.span(self.lang.field_names.?[i].?), name)) return @intCast(i);
        }
        return 0;
    }
};

/// A failed compile: the kind and the byte offset.
pub const Failure = struct { kind: ErrorKind = .none, offset: u32 = 0 };

/// One open call of `ts_query__parse_pattern`.
const Frame = struct {
    construct: enum { none, alternation, group, node, field } = .none,
    depth: u16,
    is_immediate: bool,
    inside_alternation: bool,
    starting_step: u16 = 0,
    /// The capture quantifiers that the caller passed.
    cq: CaptureQuantifiers = .empty,
    branches: std.ArrayList(u16) = .empty,
    branch_start: u16 = 0,
    child_is_immediate: bool = false,
    last_child_step: u16 = 0,
    child_step: u16 = 0,
    negated: [max_negated_fields]FieldId = undefined,
    negated_count: u16 = 0,
    field_pos: usize = 0,
    field_len: usize = 0,
};

/// The result of a frame: a parsed pattern, or `PARENT_DONE` at `)` or `]`.
const Result = enum { ok, parent_done };

/// The parser state: the stream, the query and the frame stack.
pub const Parser = struct {
    q: *Query,
    stream: Stream,
    frames: std.ArrayList(Frame) = .empty,
    failure: Failure = .{},
    /// The capture quantifiers of the child frame that finished last.
    child_cq: CaptureQuantifiers = .empty,

    fn fail(self: *Parser, kind: ErrorKind) Error {
        assert(kind != .none);
        assert(self.stream.pos <= self.stream.src.len);
        self.failure.kind = kind;
        self.failure.offset = self.stream.offset();
        return error.QueryError;
    }

    fn failAt(self: *Parser, kind: ErrorKind, pos: usize) Error {
        assert(kind != .none);
        assert(pos <= self.stream.src.len);
        self.stream.reset(pos);
        return self.fail(kind);
    }

    fn top(self: *Parser) *Frame {
        assert(self.frames.items.len > 0);
        assert(self.frames.items.len <= max_nesting);
        return &self.frames.items[self.frames.items.len - 1];
    }

    fn pushFrame(self: *Parser, depth: u16, is_immediate: bool, inside_alternation: bool) Error!void {
        assert(self.frames.items.len <= max_nesting);
        if (self.frames.items.len >= max_nesting) return error.TooLarge;
        if (depth >= none - 1) return error.TooLarge;
        try self.frames.append(self.q.arena, .{ .depth = depth, .is_immediate = is_immediate, .inside_alternation = inside_alternation });
        assert(self.frames.items.len <= max_nesting);
    }

    /// Parse one top-level pattern into `cq`.
    pub fn parsePattern(self: *Parser, cq: *CaptureQuantifiers) Error!void {
        assert(self.frames.items.len == 0);
        try self.pushFrame(0, false, false);
        var result: Result = .ok;
        var steps: usize = 0;
        var done = false;
        while (!done) : (steps += 1) {
            assert(steps <= self.stream.src.len * 8 + 64);
            const frame = self.top();
            const r = if (frame.construct == .none) try self.begin(frame) else try self.resume_(frame, result);
            if (r == null) continue; // A child frame is open.
            result = r.?;
            const finished = self.frames.pop().?;
            if (self.frames.items.len == 0) {
                cq.* = finished.cq;
                done = true;
            } else {
                self.child_cq = finished.cq;
            }
        }
        if (result == .parent_done) return self.fail(.syntax);
    }

    fn begin(self: *Parser, frame: *Frame) Error!?Result {
        assert(frame.construct == .none);
        assert(self.frames.items.len > 0);
        const s = &self.stream;
        if (s.next == 0) return self.fail(.syntax);
        if (s.next == ')' or s.next == ']') return .parent_done;
        frame.starting_step = self.q.stepCount();
        const offsets = &self.q.step_offsets;
        if (offsets.items.len == 0 or offsets.items[offsets.items.len - 1].step_index != frame.starting_step) {
            try offsets.append(self.q.arena, .{ .step_index = frame.starting_step, .byte_offset = s.offset() });
        }
        if (s.next == '[') {
            _ = s.advance(); // nasa-lint: allow(R7) the end of the text sets next to 0
            s.skipWhitespace();
            frame.construct = .alternation;
            frame.branch_start = self.q.stepCount();
            try self.pushFrame(frame.depth, frame.is_immediate, true);
            return null;
        }
        if (s.next == '(') return self.beginParen(frame);
        if (s.next == '_') {
            _ = s.advance(); // nasa-lint: allow(R7) the end of the text sets next to 0
            s.skipWhitespace();
            try self.q.pushStep(Step.init(wildcard, frame.depth, frame.is_immediate));
            return try self.suffix(frame);
        }
        if (s.next == '"') {
            const string_start = s.pos;
            try self.stringLiteral();
            const symbol = self.q.symbolForName(self.q.string_buffer.items, false);
            if (symbol == 0) return self.failAt(.node_type, string_start + 1);
            try self.q.pushStep(Step.init(symbol, frame.depth, frame.is_immediate));
            return try self.suffix(frame);
        }
        if (s.isIdentStart()) return self.beginField(frame);
        return self.fail(.syntax);
    }

    fn beginField(self: *Parser, frame: *Frame) Error!?Result {
        const s = &self.stream;
        assert(s.isIdentStart());
        frame.field_pos = s.pos;
        s.scanIdentifier();
        frame.field_len = s.pos - frame.field_pos;
        s.skipWhitespace();
        if (s.next != ':') return self.failAt(.syntax, frame.field_pos);
        _ = s.advance(); // nasa-lint: allow(R7) the end of the text sets next to 0
        s.skipWhitespace();
        frame.construct = .field;
        try self.pushFrame(frame.depth, frame.is_immediate, frame.inside_alternation);
        assert(self.frames.items.len >= 2);
        return null;
    }

    fn beginParen(self: *Parser, frame: *Frame) Error!?Result {
        assert(frame.construct == .none);
        const s = &self.stream;
        assert(s.next == '(');
        _ = s.advance(); // nasa-lint: allow(R7) the end of the text sets next to 0
        s.skipWhitespace();
        if (s.next == '(' or s.next == '"' or s.next == '[') {
            frame.construct = .group;
            frame.child_is_immediate = frame.is_immediate;
            return try self.groupNext(frame);
        }
        if (s.next == '.' or s.next == '#') {
            const at = s.pos - 1;
            _ = s.advance(); // nasa-lint: allow(R7) the end of the text sets next to 0
            try self.q.predicate_offsets.append(self.q.arena, @intCast(at));
            try self.predicate();
            return .ok;
        }
        try self.nodeStep(frame);
        s.skipWhitespace();
        frame.construct = .node;
        return try self.nodeNext(frame);
    }

    /// The next child of a grouped sequence.
    fn groupNext(self: *Parser, frame: *Frame) Error!?Result {
        assert(self.frames.items.len < max_nesting);
        const s = &self.stream;
        assert(frame.construct == .group);
        if (s.next == '.') {
            const anchor_start = s.pos;
            frame.child_is_immediate = true;
            _ = s.advance(); // nasa-lint: allow(R7) the end of the text sets next to 0
            s.skipWhitespace();
            if (s.next == ')') return self.failAt(.syntax, anchor_start);
        }
        try self.pushFrame(frame.depth, frame.child_is_immediate, frame.inside_alternation);
        return null;
    }

    /// The next negated field or child of a named node.
    fn nodeNext(self: *Parser, frame: *Frame) Error!?Result {
        const s = &self.stream;
        assert(frame.construct == .node);
        var steps: usize = 0;
        while (s.next == '!') : (steps += 1) {
            assert(steps <= s.src.len);
            _ = s.advance(); // nasa-lint: allow(R7) the end of the text sets next to 0
            s.skipWhitespace();
            if (!s.isIdentStart()) return self.fail(.syntax);
            const field_pos = s.pos;
            s.scanIdentifier();
            const field_id = self.q.fieldForName(s.src[field_pos..s.pos]);
            s.skipWhitespace();
            if (field_id == 0) {
                s.pos = field_pos;
                return self.fail(.field);
            }
            if (frame.negated_count < max_negated_fields) {
                frame.negated[frame.negated_count] = field_id;
                frame.negated_count += 1;
            }
        }
        if (s.next == '.') {
            frame.child_is_immediate = true;
            _ = s.advance(); // nasa-lint: allow(R7) the end of the text sets next to 0
            s.skipWhitespace();
        }
        frame.child_step = self.q.stepCount();
        try self.pushFrame(frame.depth + 1, frame.child_is_immediate, frame.inside_alternation);
        return null;
    }

    /// Resume a frame after its child finished with `r`.
    fn resume_(self: *Parser, frame: *Frame, r: Result) Error!?Result {
        assert(r == .ok or r == .parent_done);
        assert(frame.construct != .none);
        const child = self.child_cq.items;
        switch (frame.construct) {
            .alternation => return self.alternationChild(frame, r, child),
            .group => {
                if (r == .parent_done) {
                    if (self.stream.next != ')') return self.fail(.syntax);
                    _ = self.stream.advance(); // nasa-lint: allow(R7) the end of the text sets next to 0
                    return try self.suffix(frame);
                }
                try cqAddAll(self.q.arena, &frame.cq, child);
                frame.child_is_immediate = false;
                return try self.groupNext(frame);
            },
            .node => return self.nodeChild(frame, r, child),
            .field => return self.fieldChild(frame, r, child),
            .none => unreachable,
        }
    }

    fn alternationChild(self: *Parser, frame: *Frame, r: Result, child: []const Q) Error!?Result {
        assert(r == .ok or r == .parent_done);
        const q = self.q;
        assert(frame.construct == .alternation);
        if (r == .parent_done) {
            if (self.stream.next != ']' or frame.branches.items.len == 0) return self.fail(.syntax);
            _ = self.stream.advance(); // nasa-lint: allow(R7) the end of the text sets next to 0
            q.steps.items.len -= 1;
            const branches = frame.branches.items;
            for (branches[0 .. branches.len - 1], branches[1..]) |step_index, next_index| {
                q.steps.items[step_index].alternative_index = next_index;
                const end_step = &q.steps.items[next_index - 1];
                end_step.alternative_index = q.stepCount();
                end_step.flags.is_dead_end = true;
            }
            return try self.suffix(frame);
        }
        if (frame.branch_start == frame.starting_step) {
            frame.cq.clearRetainingCapacity();
            try frame.cq.appendSlice(q.arena, child);
        } else {
            try cqJoinAll(q.arena, &frame.cq, child);
        }
        try frame.branches.append(q.arena, frame.branch_start);
        try q.pushStep(Step.init(0, frame.depth, false));
        frame.branch_start = q.stepCount();
        try self.pushFrame(frame.depth, frame.is_immediate, true);
        return null;
    }

    fn nodeChild(self: *Parser, frame: *Frame, r: Result, child: []const Q) Error!?Result {
        const q = self.q;
        assert(frame.construct == .node);
        var step_index = frame.child_step;
        if (step_index == q.stepCount()) step_index -%= 1;
        if (r == .ok) {
            try cqAddAll(q.arena, &frame.cq, child);
            frame.last_child_step = step_index;
            frame.child_is_immediate = false;
            return try self.nodeNext(frame);
        }
        if (self.stream.next != ')') return self.fail(.syntax);
        if (frame.child_is_immediate) {
            if (frame.last_child_step == 0) return self.fail(.syntax);
            var step = &q.steps.items[frame.last_child_step];
            step.flags.is_last_child = true;
            var steps: usize = 0;
            while (step.alternative_index != none and step.alternative_index < q.steps.items.len) : (steps += 1) {
                assert(steps <= max_steps);
                step = &q.steps.items[step.alternative_index];
                step.flags.is_last_child = true;
            }
        }
        if (frame.negated_count > 0) try self.addNegatedFields(frame.starting_step, frame.negated[0..frame.negated_count]);
        _ = self.stream.advance(); // nasa-lint: allow(R7) the end of the text sets next to 0
        return try self.suffix(frame);
    }

    fn fieldChild(self: *Parser, frame: *Frame, r: Result, child: []const Q) Error!?Result {
        assert(frame.field_len > 0);
        const q = self.q;
        assert(frame.construct == .field);
        if (r == .parent_done) return self.fail(.syntax);
        const field_id = q.fieldForName(self.stream.src[frame.field_pos..][0..frame.field_len]);
        if (field_id == 0) {
            self.stream.pos = frame.field_pos;
            return self.fail(.field);
        }
        var index: usize = frame.starting_step;
        var steps: usize = 0;
        while (steps <= max_steps) : (steps += 1) {
            const step = &q.steps.items[index];
            step.field = field_id;
            if (step.alternative_index == none or step.alternative_index <= index or step.alternative_index >= q.steps.items.len) break;
            index = step.alternative_index;
        }
        try cqAddAll(q.arena, &frame.cq, child);
        return try self.suffix(frame);
    }

    /// `ts_query__add_negated_fields`: reuse an equal list, or append one.
    fn addNegatedFields(self: *Parser, step_index: u16, ids: []const FieldId) Error!void {
        assert(step_index < self.q.steps.items.len);
        const fields = &self.q.negated_fields;
        assert(ids.len > 0 and ids.len <= max_negated_fields);
        var failed = false;
        var match_count: usize = 0;
        var start: usize = 0;
        for (fields.items, 0..) |existing, i| {
            if (existing == 0) {
                if (match_count == ids.len) {
                    self.q.steps.items[step_index].negated_field_list_id = @intCast(start);
                    return;
                }
                start = i + 1;
                match_count = 0;
                failed = false;
            } else if (match_count < ids.len and existing == ids[match_count] and !failed) {
                match_count += 1;
            } else {
                match_count = 0;
                failed = true;
            }
        }
        if (fields.items.len >= none) return error.TooLarge;
        self.q.steps.items[step_index].negated_field_list_id = @intCast(fields.items.len);
        try fields.appendSlice(self.q.arena, ids);
        try fields.append(self.q.arena, 0);
    }

    /// The node name after `(`: a step for a named node, `_`, `ERROR` or
    /// `MISSING`. A supertype is outside the scope of ztree (ADR-0007).
    fn nodeStep(self: *Parser, frame: *Frame) Error!void {
        assert(frame.construct == .none);
        const s = &self.stream;
        const q = self.q;
        const node_name = s.pos;
        if (!s.isIdentStart()) return self.fail(.syntax);
        s.scanIdentifier();
        const name = s.src[node_name..s.pos];
        var symbol: Symbol = wildcard;
        var is_missing = false;
        if (std.mem.eql(u8, name, "_")) {
            symbol = wildcard;
        } else if (std.mem.eql(u8, name, "MISSING")) {
            is_missing = true;
            symbol = try self.missingSymbol();
        } else {
            symbol = q.symbolForName(name, true);
            if (symbol == 0) return self.failAt(.node_type, node_name);
        }
        try q.pushStep(Step.init(symbol, frame.depth, frame.is_immediate));
        const step = &q.steps.items[q.steps.items.len - 1];
        if (symbol != abi.builtin_sym_error and language.symbolMetadata(q.lang, symbol).supertype) return self.failAt(.unsupported, node_name);
        step.flags.is_missing = is_missing;
        if (symbol == wildcard) step.flags.is_named = true;
        // `supertype/subtype` needs a supertype, which returned above.
        if (s.next == '/') return self.failAt(.structure, node_name - 1);
        assert(q.steps.items.len > 0);
    }

    /// The symbol after `MISSING`: a name, a string, or none for any node.
    fn missingSymbol(self: *Parser) Error!Symbol {
        assert(self.stream.pos <= self.stream.src.len);
        assert(self.frames.items.len > 0);
        const s = &self.stream;
        s.skipWhitespace();
        if (s.isIdentStart()) {
            const start = s.pos;
            s.scanIdentifier();
            const symbol = self.q.symbolForName(s.src[start..s.pos], true);
            if (symbol == 0) return self.failAt(.node_type, start);
            return symbol;
        }
        if (s.next == '"') {
            const string_start = s.pos;
            try self.stringLiteral();
            const symbol = self.q.symbolForName(self.q.string_buffer.items, false);
            if (symbol == 0) return self.failAt(.node_type, string_start + 1);
            return symbol;
        }
        if (s.next == ')') return wildcard;
        return self.failAt(.syntax, s.pos);
    }

    /// The quantifiers and captures after a pattern.
    fn suffix(self: *Parser, frame: *Frame) Error!Result {
        assert(frame.construct != .none or self.q.steps.items.len > 0);
        const s = &self.stream;
        const q = self.q;
        s.skipWhitespace();
        var quantifier: Q = .one;
        var steps: usize = 0;
        while (steps <= s.src.len) : (steps += 1) {
            if (s.next == '+' or s.next == '*' or s.next == '?') {
                const op: Q = if (s.next == '+') .one_or_more else if (s.next == '*') .zero_or_more else .zero_or_one;
                quantifier = qOp(&join_table, op, quantifier);
                _ = s.advance(); // nasa-lint: allow(R7) the end of the text sets next to 0
                s.skipWhitespace();
            } else if (s.next == '@') {
                try self.capture(frame);
            } else break;
        }
        try self.repeat(frame, quantifier);
        cqMul(&frame.cq, quantifier);
        assert(q.steps.items.len <= max_steps);
        return .ok;
    }

    /// `@name` after a pattern: add the capture to the first step and to its alternatives.
    fn capture(self: *Parser, frame: *Frame) Error!void {
        assert(frame.depth < none);
        const s = &self.stream;
        const q = self.q;
        assert(s.next == '@');
        _ = s.advance(); // nasa-lint: allow(R7) the end of the text sets next to 0
        if (!s.isIdentStart()) return self.fail(.syntax);
        const start = s.pos;
        s.scanIdentifier();
        const id = try q.captures.insert(q.arena, s.src[start..s.pos]);
        s.skipWhitespace();
        try cqAddFor(q.arena, &frame.cq, id, .one);
        if (frame.starting_step >= q.steps.items.len) {
            q.reference_ub = true;
            return self.fail(.syntax);
        }
        var index: usize = frame.starting_step;
        var steps: usize = 0;
        while (steps <= max_steps) : (steps += 1) {
            const step = &q.steps.items[index];
            step.addCapture(id);
            if (step.alternative_index == none or step.alternative_index <= index or step.alternative_index >= q.steps.items.len) break;
            index = step.alternative_index;
        }
    }

    /// The steps of a quantifier.
    fn repeat(self: *Parser, frame: *Frame, quantifier: Q) Error!void {
        const q = self.q;
        assert(q.steps.items.len <= max_steps);
        if (quantifier == .one or quantifier == .zero) return;
        if (frame.starting_step >= q.steps.items.len) {
            q.reference_ub = true;
            return self.fail(.syntax);
        }
        if (quantifier != .zero_or_one) {
            var repeat_step = Step.init(wildcard, frame.depth, false);
            repeat_step.flags.is_inside_alternation = frame.inside_alternation;
            repeat_step.flags.is_pass_through = true;
            repeat_step.alternative_index = frame.starting_step;
            try q.pushStep(repeat_step);
            if (quantifier == .one_or_more) return;
        }
        // The skip of `?` and `*` goes to the end of the alternative chain.
        const limit = if (quantifier == .zero_or_more) q.steps.items.len - 1 else q.steps.items.len;
        var step = &q.steps.items[frame.starting_step];
        var steps: usize = 0;
        while (step.alternative_index != none and step.alternative_index < limit) : (steps += 1) {
            assert(steps <= max_steps);
            step = &q.steps.items[step.alternative_index];
        }
        step.alternative_index = q.stepCount();
        step.flags.alternative_is_skip = true;
    }

    /// `ts_query__parse_string_literal`: the value goes to `string_buffer`.
    fn stringLiteral(self: *Parser) Error!void {
        assert(self.stream.pos < self.stream.src.len);
        assert(self.stream.src.len <= max_query_bytes);
        const s = &self.stream;
        const buf = &self.q.string_buffer;
        const start = s.pos;
        if (s.next != '"') return self.fail(.syntax);
        _ = s.advance(); // nasa-lint: allow(R7) the end of the text sets next to 0
        var prev = s.pos;
        var escaped = false;
        buf.clearRetainingCapacity();
        var steps: usize = 0;
        while (steps <= s.src.len) : (steps += 1) {
            if (escaped) {
                escaped = false;
                switch (s.next) {
                    'n' => try buf.append(self.q.arena, '\n'),
                    'r' => try buf.append(self.q.arena, '\r'),
                    't' => try buf.append(self.q.arena, '\t'),
                    '0' => try buf.append(self.q.arena, 0),
                    else => try buf.appendSlice(self.q.arena, s.src[s.pos..][0..s.next_size]),
                }
                prev = s.pos + s.next_size;
            } else if (s.next == '\\') {
                try buf.appendSlice(self.q.arena, s.src[prev..s.pos]);
                prev = s.pos + 1;
                escaped = true;
            } else if (s.next == '"') {
                if (buf.capacity == 0 and s.pos == prev) self.q.reference_ub = true;
                try buf.appendSlice(self.q.arena, s.src[prev..s.pos]);
                _ = s.advance(); // nasa-lint: allow(R7) the end of the text sets next to 0
                return;
            } else if (s.next == '\n') {
                return self.failAt(.syntax, start);
            }
            if (!s.advance()) return self.failAt(.syntax, start);
        }
        return self.failAt(.syntax, start);
    }

    fn pushPredicateStep(self: *Parser, kind: PredicateStepKind, value_id: u16) Error!void {
        assert(value_id != none or kind == .done);
        if (self.q.predicate_steps.items.len >= std.math.maxInt(u32)) return error.TooLarge;
        try self.q.predicate_steps.append(self.q.arena, .{ .kind = kind, .value_id = value_id });
        assert(self.q.predicate_steps.items.len > 0);
    }

    /// `ts_query__parse_predicate`, after `(#` or `(.`.
    fn predicate(self: *Parser) Error!void {
        assert(self.stream.pos <= self.stream.src.len);
        assert(self.q.predicate_offsets.items.len > 0);
        const s = &self.stream;
        const q = self.q;
        if (!s.isIdentStart()) return self.fail(.syntax);
        const name_start = s.pos;
        s.scanIdentifier();
        if (s.next != '?' and s.next != '!') return self.fail(.syntax);
        _ = s.advance(); // nasa-lint: allow(R7) the end of the text sets next to 0
        try self.pushPredicateStep(.string, try q.values.insert(q.arena, s.src[name_start..s.pos]));
        s.skipWhitespace();
        var steps: usize = 0;
        while (steps <= s.src.len) : (steps += 1) {
            if (s.next == ')') {
                _ = s.advance(); // nasa-lint: allow(R7) the end of the text sets next to 0
                s.skipWhitespace();
                return self.pushPredicateStep(.done, 0);
            } else if (s.next == '@') {
                _ = s.advance(); // nasa-lint: allow(R7) the end of the text sets next to 0
                if (!s.isIdentStart()) return self.fail(.syntax);
                const capture_start = s.pos;
                s.scanIdentifier();
                const id = q.captures.idFor(s.src[capture_start..s.pos]) orelse return self.failAt(.capture, capture_start);
                try self.pushPredicateStep(.capture, id);
            } else if (s.next == '"') {
                try self.stringLiteral();
                try self.pushPredicateStep(.string, try q.values.insert(q.arena, q.string_buffer.items));
            } else if (s.isIdentStart()) {
                const symbol_start = s.pos;
                s.scanIdentifier();
                try self.pushPredicateStep(.string, try q.values.insert(q.arena, s.src[symbol_start..s.pos]));
            } else return self.fail(.syntax);
            s.skipWhitespace();
        }
        return self.fail(.syntax);
    }
};

/// `ts_query__pattern_map_search`: the index of the first entry for
/// `needle`, or where it goes. True when an entry has the symbol.
fn patternMapSearch(q: *const Query, needle: Symbol) struct { u32, bool } {
    assert(q.wildcard_root_pattern_count <= q.pattern_map.items.len);
    var base: u32 = q.wildcard_root_pattern_count;
    var size: u32 = @as(u32, @intCast(q.pattern_map.items.len)) - base;
    if (size == 0) return .{ base, false };
    const map = q.pattern_map.items;
    while (size > 1) {
        const half = size / 2;
        const mid = base + half;
        if (needle > q.steps.items[map[mid].step_index].symbol) base = mid;
        size -= half;
    }
    var symbol = q.steps.items[map[base].step_index].symbol;
    if (needle > symbol) {
        base += 1;
        if (base < map.len) symbol = q.steps.items[map[base].step_index].symbol;
    }
    assert(base <= map.len);
    return .{ base, needle == symbol };
}

/// `ts_query__pattern_map_insert`: keep the map sorted by symbol, then by pattern.
fn patternMapInsert(q: *Query, symbol: Symbol, entry: PatternEntry) Error!void {
    assert(entry.step_index < q.steps.items.len);
    const found = patternMapSearch(q, symbol);
    var index = found[0];
    const map = q.pattern_map.items;
    while (index < map.len) : (index += 1) {
        const e = map[index];
        if (q.steps.items[e.step_index].symbol != symbol or e.pattern_index >= entry.pattern_index) break;
    }
    try q.pattern_map.insert(q.arena, index, entry);
    assert(q.pattern_map.items.len <= max_steps);
}

/// Add the pattern map entries of one pattern, for each root alternative.
fn mapPattern(q: *Query, pattern_index: u16, first_step: u16) Error!void {
    assert(first_step < q.steps.items.len);
    var start = first_step;
    var wildcard_root_alternative: u16 = none;
    var rounds: usize = 0;
    while (rounds <= max_steps) : (rounds += 1) {
        var step = q.steps.items[start];
        // A wildcard root with a non-wildcard child starts at the child.
        if (step.symbol == wildcard and step.depth == 0 and step.field == 0) {
            const second = q.steps.items[start + 1];
            if (second.symbol != wildcard and second.depth == 1 and !second.flags.is_immediate) {
                wildcard_root_alternative = step.alternative_index;
                start += 1;
                step = second;
            }
        }
        const start_depth = step.depth;
        var is_rooted = start_depth == 0;
        for (q.steps.items[start + 1 ..]) |child| {
            if (child.flags.is_dead_end) break;
            if (child.depth == start_depth) {
                is_rooted = false;
                break;
            }
        }
        try patternMapInsert(q, step.symbol, .{ .step_index = start, .pattern_index = pattern_index, .is_rooted = @intFromBool(is_rooted) });
        if (step.symbol == wildcard) q.wildcard_root_pattern_count += 1;
        if (step.alternative_index != none) {
            start = step.alternative_index;
        } else if (wildcard_root_alternative != none) {
            start = wildcard_root_alternative;
            wildcard_root_alternative = none;
        } else break;
    }
    assert(q.pattern_map.items.len > 0);
}

/// Give each quantifier loop-back inside an alternation a clean copy of its
/// target step, with no link to the next branch (`ts_query_new`).
fn fixLoopBacks(q: *Query, pattern: Pattern) Error!void {
    const start = pattern.steps.offset;
    const end = start + pattern.steps.length - 1;
    assert(start <= end);
    for (start..end) |i| {
        const s = q.steps.items[i];
        if (!s.flags.is_pass_through or !s.flags.is_inside_alternation or s.alternative_index == none or s.alternative_index >= i) continue;
        const target_index = s.alternative_index;
        const target = q.steps.items[target_index];
        if (target.alternative_index == none or target.alternative_index <= target_index or target.alternative_index >= end) continue;
        const copy_index = q.stepCount();
        var copy = target;
        copy.alternative_index = none;
        try q.pushStep(copy);
        var redirect = Step.init(0, target.depth, false);
        redirect.flags.is_dead_end = true;
        redirect.alternative_index = target_index + 1;
        try q.pushStep(redirect);
        q.steps.items[i].alternative_index = copy_index;
    }
    assert(q.steps.items.len <= max_steps);
}

/// Parse each pattern of `src` (`ts_query_new`, before the analysis).
pub fn parse(arena: std.mem.Allocator, lang: *const Language, src: []const u8, failure: *Failure, reference_ub: *bool) Error!*Query {
    if (src.len > max_query_bytes) return error.TooLarge;
    const q = try arena.create(Query);
    q.* = .{ .arena = arena, .lang = lang };
    try q.negated_fields.append(arena, 0);
    var p = Parser{ .q = q, .stream = .{ .src = src } };
    const first = p.stream.advance();
    assert(first or src.len == 0);
    p.stream.skipWhitespace();
    var patterns: usize = 0;
    while (p.stream.pos < src.len) : (patterns += 1) {
        assert(patterns <= src.len);
        if (q.patterns.items.len >= none) return error.TooLarge;
        const pattern_index: u16 = @intCast(q.patterns.items.len);
        const start_step = q.stepCount();
        const start_predicate: u32 = @intCast(q.predicate_steps.items.len);
        try q.patterns.append(arena, .{ .steps = .{ .offset = start_step, .length = 0 }, .predicate_steps = .{ .offset = start_predicate, .length = 0 }, .start_byte = p.stream.offset(), .end_byte = 0, .is_non_local = 0 });
        var cq: CaptureQuantifiers = .empty;
        p.parsePattern(&cq) catch |err| {
            failure.* = p.failure;
            reference_ub.* = q.reference_ub;
            return err;
        };
        try q.pushStep(Step.init(0, none, false));
        const pattern = &q.patterns.items[pattern_index];
        pattern.steps.length = q.stepCount() - start_step;
        pattern.predicate_steps.length = @as(u32, @intCast(q.predicate_steps.items.len)) - start_predicate;
        pattern.end_byte = p.stream.offset();
        try q.capture_quantifiers.append(arena, cq);
        try mapPattern(q, pattern_index, start_step);
        try fixLoopBacks(q, pattern.*);
    }
    return q;
}

const analysis = @import("query_analysis.zig");

/// Parse and analyze `src` (`ts_query_new`). On a query error, `failure`
/// holds the kind and the byte offset.
pub fn compile(arena: std.mem.Allocator, lang: *const Language, src: []const u8, failure: *Failure, reference_ub: *bool) Error!*Query {
    assert(src.len <= std.math.maxInt(u32));
    failure.* = .{};
    reference_ub.* = false;
    if (lang.abi_version < abi.min_abi_version or lang.abi_version > abi.max_abi_version) {
        failure.kind = .language;
        return error.QueryError;
    }
    const q = try parse(arena, lang, src, failure, reference_ub);
    reference_ub.* = q.reference_ub;
    if (try analysis.analyze(q)) |offset| {
        failure.* = .{ .kind = .structure, .offset = offset };
        return error.QueryError;
    }
    assert(q.steps.items.len <= max_steps);
    return q;
}
