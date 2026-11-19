//! The text predicates of a query (ADR-0011). The checks and the meaning
//! follow `NewQuery` of go-tree-sitter v0.25: `#eq?`, `#not-eq?`,
//! `#any-eq?`, `#any-not-eq?`, the four forms of `#match?`, `#any-of?` and
//! `#not-any-of?`. ztree rejects other predicates. A directive (each name
//! that ends in `!`, for example `#set!` and `#strip!`) and the property
//! predicates `#is?` and `#is-not?` are outside its scope (ADR-0007), so
//! they give `unsupported` (ADR-0011). Another unknown predicate gives
//! `predicate`. `#match?` compiles its regex here (ADR-0010).

const std = @import("std");
const assert = std.debug.assert;
const query = @import("query.zig");
const regex = @import("regex.zig");

pub const Op = enum(u8) { eq, match, any_of };

/// One text predicate (`TextPredicateCapture` of go-tree-sitter).
pub const TextPredicate = extern struct {
    op: Op,
    /// False for the `not-` forms.
    positive: u8,
    /// True when each node of the capture must pass; false for the `any-` forms.
    match_all: u8,
    /// `eq`: true when `value` is a capture id, false for a string id.
    value_is_capture: u8,
    capture_id: u32,
    /// `eq`: a capture or string id. `match`: a regex index. `any_of`: the
    /// index of the first string id in `any_of_values`.
    value: u32,
    /// `any_of`: the number of string ids.
    count: u32 = 0,
};

/// One compiled regex: its instructions and ranges in the shared arrays.
pub const Regex = extern struct { insts: query.Slice, ranges: query.Slice, start: u32 };

/// The text predicates of each pattern, and the data they name.
pub const Predicates = struct {
    items: std.ArrayList(TextPredicate) = .empty,
    /// The predicates of each pattern, as a slice of `items`.
    per_pattern: std.ArrayList(query.Slice) = .empty,
    any_of_values: std.ArrayList(u32) = .empty,
    regexes: std.ArrayList(Regex) = .empty,
    insts: std.ArrayList(regex.Inst) = .empty,
    ranges: std.ArrayList(regex.Range) = .empty,
};

const PredicateStep = query.PredicateStep;

/// A compile context: the query, the result and the error.
const Checker = struct {
    q: *const query.Query,
    p: *Predicates,
    failure: *query.Failure,
    /// The index of the predicate under check, for its byte offset.
    index: usize = 0,

    fn fail(self: *Checker, kind: query.ErrorKind) query.Error {
        assert(kind != .none);
        assert(self.index < self.q.predicate_offsets.items.len);
        self.failure.* = .{ .kind = kind, .offset = self.q.predicate_offsets.items[self.index] };
        return error.QueryError;
    }

    fn value(self: *const Checker, step: PredicateStep) []const u8 {
        assert(step.kind == .string);
        assert(step.value_id < self.q.values.slices.items.len);
        return self.q.values.name(@intCast(step.value_id));
    }

    /// Check one predicate: its steps without the `done` step.
    fn check(self: *Checker, steps: []const PredicateStep) query.Error!void {
        assert(self.index < self.q.predicate_offsets.items.len);
        assert(steps.len > 0);
        if (steps[0].kind != .string) return self.fail(.predicate);
        const name = self.value(steps[0]);
        const eq_forms = [_][]const u8{ "eq?", "not-eq?", "any-eq?", "any-not-eq?" };
        const match_forms = [_][]const u8{ "match?", "not-match?", "any-match?", "any-not-match?" };
        for (eq_forms, 0..) |form, i| {
            if (std.mem.eql(u8, name, form)) return self.eqOrMatch(steps, .eq, i);
        }
        for (match_forms, 0..) |form, i| {
            if (std.mem.eql(u8, name, form)) return self.eqOrMatch(steps, .match, i);
        }
        if (std.mem.eql(u8, name, "any-of?") or std.mem.eql(u8, name, "not-any-of?")) return self.anyOf(steps, name[0] == 'a');
        if (std.mem.endsWith(u8, name, "!")) return self.fail(.unsupported);
        const property_predicates = [_][]const u8{ "is?", "is-not?" };
        for (property_predicates) |d| if (std.mem.eql(u8, name, d)) return self.fail(.unsupported);
        return self.fail(.predicate);
    }

    /// `#eq?` or `#match?` in form `form`: 0 plain, 1 `not-`, 2 `any-`, 3 `any-not-`.
    fn eqOrMatch(self: *Checker, steps: []const PredicateStep, op: Op, form: usize) query.Error!void {
        assert(form < 4);
        if (steps.len != 3 or steps[1].kind != .capture) return self.fail(.predicate);
        var pred = TextPredicate{ .op = op, .positive = @intFromBool(form == 0 or form == 2), .match_all = @intFromBool(form < 2), .value_is_capture = 0, .capture_id = steps[1].value_id, .value = steps[2].value_id };
        if (op == .eq) {
            pred.value_is_capture = @intFromBool(steps[2].kind == .capture);
        } else {
            if (steps[2].kind != .string) return self.fail(.predicate);
            pred.value = try self.compileRegex(self.value(steps[2]));
        }
        try self.p.items.append(self.q.arena, pred);
        assert(self.p.items.items.len > 0);
    }

    fn anyOf(self: *Checker, steps: []const PredicateStep, positive: bool) query.Error!void {
        assert(steps.len > 0);
        if (steps.len < 2 or steps[1].kind != .capture) return self.fail(.predicate);
        const first: u32 = @intCast(self.p.any_of_values.items.len);
        for (steps[2..]) |s| {
            if (s.kind != .string) return self.fail(.predicate);
            try self.p.any_of_values.append(self.q.arena, s.value_id);
        }
        try self.p.items.append(self.q.arena, .{ .op = .any_of, .positive = @intFromBool(positive), .match_all = 1, .value_is_capture = 0, .capture_id = steps[1].value_id, .value = first, .count = @intCast(steps.len - 2) });
        assert(self.p.any_of_values.items.len >= first);
    }

    /// Compile a regex into the shared arrays. Return its index.
    fn compileRegex(self: *Checker, pattern: []const u8) query.Error!u32 {
        assert(pattern.len <= std.math.maxInt(u32));
        const arena = self.q.arena;
        const insts = try arena.alloc(regex.Inst, regex.max_insts);
        const ranges = try arena.alloc(regex.Range, regex.max_ranges);
        var diag = regex.Diagnostic{};
        const prog = regex.compile(pattern, insts, ranges, &diag) catch |err| return self.fail(switch (err) {
            error.Syntax => .predicate,
            error.Unsupported, error.TooLarge => .unsupported,
        });
        const p = self.p;
        try p.regexes.append(arena, .{
            .insts = .{ .offset = @intCast(p.insts.items.len), .length = @intCast(prog.insts.len) },
            .ranges = .{ .offset = @intCast(p.ranges.items.len), .length = @intCast(prog.ranges.len) },
            .start = prog.start,
        });
        try p.insts.appendSlice(arena, prog.insts);
        try p.ranges.appendSlice(arena, prog.ranges);
        assert(p.regexes.items.len > 0);
        return @intCast(p.regexes.items.len - 1);
    }
};

/// Check the predicates of each pattern and compile them.
pub fn compile(q: *const query.Query, failure: *query.Failure) query.Error!Predicates {
    assert(q.predicate_offsets.items.len <= q.predicate_steps.items.len);
    var p = Predicates{};
    var c = Checker{ .q = q, .p = &p, .failure = failure };
    for (q.patterns.items) |pattern| {
        const first: u32 = @intCast(p.items.items.len);
        const steps = q.predicate_steps.items[pattern.predicate_steps.offset..][0..pattern.predicate_steps.length];
        var start: usize = 0;
        for (steps, 0..) |s, i| {
            if (s.kind != .done) continue;
            if (i > start) try c.check(steps[start..i]);
            c.index += 1;
            start = i + 1;
        }
        try p.per_pattern.append(q.arena, .{ .offset = first, .length = @as(u32, @intCast(p.items.items.len)) - first });
    }
    assert(p.per_pattern.items.len == q.patterns.items.len);
    return p;
}
