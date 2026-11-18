//! The query compiler against `ts_query_new` of the reference runtime
//! (ISSUE-013). Each case compares a text dump of the steps, the pattern
//! map, the patterns, the predicates and the symbol tables, or the error
//! kind and offset. The corpus is the `queries/*.scm` files of the upstream
//! grammars (MIT), hand-written cases, and mutations of both.

const std = @import("std");
const ztree = @import("ztree");
const grammars = ztree.grammars;
const query = ztree.query;
const corpus = @import("query_corpus");

extern fn ztree_ref_query_dump(lang: *const ztree.abi.Language14, src: [*]const u8, len: u32, buf: [*]u8, cap: u32) u32;

fn print(w: *std.Io.Writer, comptime fmt: []const u8, args: anytype) void {
    w.print(fmt, args) catch @panic("dump buffer");
}

/// The dump of ztree, in the format of `tests/query_shim.c`.
fn dump(gpa: std.mem.Allocator, lang: *const ztree.abi.Language14, src: []const u8) !struct { []u8, bool } {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var out: std.Io.Writer.Allocating = .init(gpa);
    const w = &out.writer;
    var failure = query.Failure{};
    var ub = false;
    const q = query.compile(arena_state.allocator(), lang, src, &failure, &ub) catch |err| switch (err) {
        error.QueryError => {
            print(w, "error {d} {d}\n", .{ @backingInt(failure.kind), failure.offset });
            return .{ try out.toOwnedSlice(), ub };
        },
        else => return err,
    };
    for (q.steps.items, 0..) |s, i| {
        print(w, "step {d}: sym={d} super={d} field={d} caps={d},{d},{d} depth={d} alt={d} neg={d} flags={x}\n", .{ i, s.symbol, s.supertype_symbol, s.field, s.capture_ids[0], s.capture_ids[1], s.capture_ids[2], s.depth, s.alternative_index, s.negated_field_list_id, @as(u16, @bitCast(s.flags)) });
    }
    for (q.pattern_map.items, 0..) |e, i| print(w, "map {d}: step={d} pattern={d} rooted={d}\n", .{ i, e.step_index, e.pattern_index, e.is_rooted });
    for (q.patterns.items, 0..) |p, i| {
        print(w, "pattern {d}: steps={d}+{d} preds={d}+{d} bytes={d}-{d} nonlocal={d}\n", .{ i, p.steps.offset, p.steps.length, p.predicate_steps.offset, p.predicate_steps.length, p.start_byte, p.end_byte, p.is_non_local });
        print(w, "quantifiers {d}:", .{i});
        for (q.capture_quantifiers.items[i].items) |cq| print(w, " {d}", .{@backingInt(cq)});
        print(w, "\n", .{});
    }
    for (q.predicate_steps.items, 0..) |ps, i| print(w, "pred {d}: {d} {d}\n", .{ i, @backingInt(ps.kind), ps.value_id });
    print(w, "negated:", .{});
    for (q.negated_fields.items) |f| print(w, " {d}", .{f});
    print(w, "\nrepeat:", .{});
    for (q.repeat_symbols_with_rootless_patterns.items) |s| print(w, " {d}", .{s});
    print(w, "\nwildcard roots: {d}\n", .{q.wildcard_root_pattern_count});
    for (0..q.captures.slices.items.len) |i| print(w, "capture {d}: {s}\n", .{ i, q.captures.name(@intCast(i)) });
    for (0..q.values.slices.items.len) |i| print(w, "value {d}: {s}\n", .{ i, q.values.name(@intCast(i)) });
    return .{ try out.toOwnedSlice(), q.reference_ub };
}

const Totals = struct { cases: usize = 0, errors: usize = 0, skipped: usize = 0, unsupported: usize = 0 };

/// Compare one query with the reference. Return false on a difference.
fn compare(gpa: std.mem.Allocator, lang_name: []const u8, src: []const u8, totals: *Totals) !bool {
    const lang = grammars.language(std.meta.stringToEnum(grammars.Lang, lang_name).?);
    const ours, const reference_ub = try dump(gpa, lang, src);
    defer gpa.free(ours);
    if (reference_ub) {
        totals.skipped += 1;
        return true;
    }
    // Supertypes and directives are outside the scope of ztree (ADR-0007).
    if (std.mem.startsWith(u8, ours, "error 8 ")) {
        totals.unsupported += 1;
        return true;
    }
    const buf = try gpa.alloc(u8, 1 << 22);
    defer gpa.free(buf);
    const n = ztree_ref_query_dump(lang, src.ptr, @intCast(src.len), buf.ptr, @intCast(buf.len));
    try std.testing.expect(n <= buf.len);
    totals.cases += 1;
    if (std.mem.startsWith(u8, ours, "error")) totals.errors += 1;
    if (std.mem.eql(u8, buf[0..n], ours)) return true;
    const at = std.mem.indexOfDiff(u8, buf[0..n], ours) orelse 0;
    const line_start = if (std.mem.lastIndexOfScalar(u8, buf[0..@min(at, n)], '\n')) |i| i + 1 else 0;
    std.debug.print("{s} query differs:\n{s}\n--- ref:   {s}\n--- ztree: {s}\n", .{ lang_name, src[0..@min(src.len, 300)], buf[line_start..@min(n, line_start + 200)], ours[@min(ours.len, line_start)..@min(ours.len, line_start + 200)] });
    return false;
}

/// Hand-written queries for each feature and each error kind.
const cases = [_]struct { []const u8, []const u8 }{
    .{ "go", "(function_declaration name: (identifier) @name)" },
    .{ "go", "(call_expression function: (identifier) @f (#eq? @f \"panic\"))" },
    .{ "go", "(import_spec path: (interpreted_string_literal) @violation (#eq? @violation \"\\\"unsafe\\\"\"))" },
    .{ "go", "((comment) @violation (#match? @violation \"^//\\\\s*nolint(:[A-Za-z0-9_,-]+)?\\\\s*$\"))" },
    .{ "go", "(_ (identifier) @id)" },
    .{ "go", "(_) @any" },
    .{ "go", "[(identifier) (field_identifier)] @name" },
    .{ "go", "(block . (_) @first (_)? @second .)" },
    .{ "go", "(parameter_list (parameter_declaration)* @params)" },
    .{ "go", "(parameter_list (parameter_declaration)+ @params)" },
    .{ "go", "((comment)+ @doc . (function_declaration) @fn)" },
    .{ "go", "(function_declaration !result) @no_result" },
    .{ "go", "(function_declaration !result !type_parameters name: (_) @n)" },
    .{ "go", "(ERROR) @error" },
    .{ "go", "(MISSING) @missing (MISSING identifier) @mid (MISSING \";\") @semi" },
    .{ "go", "\"func\" @kw \"return\" @kw" },
    .{ "go", "(binary_expression operator: [\"+\" \"-\"] @op)" },
    .{ "go", "(binary_expression left: (_) @l right: (_) @r) @expr" },
    .{ "go", "[(call_expression function: (identifier) @f) (selector_expression field: (field_identifier) @f)]* @calls" },
    .{ "go", "(source_file [(function_declaration) (method_declaration)]+ @decl)" },
    .{ "go", "((identifier) @a (#any-of? @a \"x\" \"y\" z))" },
    .{ "go", "((identifier) @a (#not-eq? @a @a) (#set! key value))" },
    .{ "go", "(if_statement condition: (_) @c consequence: (block) @b alternative: (_)? @e)" },
    .{ "go", "; a comment\n(identifier) @a ; another\n(field_identifier) @b" },
    .{ "go", "((_)? @a) ((_)* @b) ([(identifier) (_)] @c)" },
    .{ "go", "(function_declaration (block ((expression_statement) @s)*))" },
    .{ "go", "(no_such_node) @x" },
    .{ "go", "(function_declaration no_such_field: (identifier))" },
    .{ "go", "(function_declaration !no_such_field)" },
    .{ "go", "((identifier) @a (#eq? @b \"x\"))" },
    .{ "go", "(identifier" },
    .{ "go", "(identifier))" },
    .{ "go", "[(identifier)" },
    .{ "go", "[]" },
    .{ "go", "(identifier) @" },
    .{ "go", "\"unterminated" },
    .{ "go", "\"no_such_token\"" },
    .{ "go", "(identifier (identifier))" },
    .{ "go", "(function_declaration (int_literal))" },
    .{ "go", "(block .)" },
    .{ "go", "((identifier) .)" },
    .{ "go", "(identifier/x)" },
    .{ "go", "field:" },
    .{ "go", "name: (identifier) @n" },
    .{ "go", "(#eq? @a b)" },
    .{ "go", "(_ name: (identifier) . (parameter_list) @p .)" },
    .{ "c", "(call_expression function: (identifier) @violation (#any-of? @violation \"gets\" \"strcpy\" \"strcat\" \"sprintf\" \"vsprintf\"))" },
    .{ "c", "((comment) @violation (#match? @violation \"NOLINT(\\\\([^)]*\\\\))?\\\\s*(\\\\*/)?$\"))" },
    .{ "c", "(function_definition declarator: (function_declarator declarator: (identifier) @name))" },
    .{ "c", "(preproc_ifdef name: (identifier) @n)" },
    .{ "cpp", "(call_expression function: (identifier) @violation)" },
    .{ "cpp", "(template_declaration (function_definition) @f)" },
    .{ "zig", "((builtin_identifier) @violation (#any-of? @violation \"@ptrFromInt\" \"@intFromPtr\" \"@ptrCast\" \"@alignCast\"))" },
    .{ "zig", "(function_declaration name: (identifier) @name)" },
    .{ "python", "(import_statement name: (dotted_name) @violation (#eq? @violation \"ctypes\"))" },
    .{ "python", "((comment) @violation (#match? @violation \"#\\\\s*(noqa|type:\\\\s*ignore)\\\\s*$\"))" },
    .{ "python", "(function_definition name: (identifier) @n body: (block . (expression_statement (string)) @doc))" },
    .{ "rust", "(unsafe_block) @violation" },
    .{ "rust", "(function_item name: (identifier) @n parameters: (parameters (parameter)* @p))" },
};

const mutation_chars = "()[]\"@.!_:*+?#; \n\\abz-";

/// A mutation of `src`: a deletion, an insertion, a truncation or a duplicate span.
fn mutate(gpa: std.mem.Allocator, r: std.Random, src: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    const at = if (src.len == 0) 0 else r.uintLessThan(usize, src.len + 1);
    switch (r.uintLessThan(u8, 4)) {
        0 => {
            const end = @min(src.len, at + 1 + r.uintLessThan(usize, 6));
            try out.appendSlice(gpa, src[0..at]);
            try out.appendSlice(gpa, src[end..]);
        },
        1 => {
            try out.appendSlice(gpa, src[0..at]);
            try out.append(gpa, mutation_chars[r.uintLessThan(usize, mutation_chars.len)]);
            try out.appendSlice(gpa, src[at..]);
        },
        2 => try out.appendSlice(gpa, src[0..at]),
        else => {
            const end = @min(src.len, at + 1 + r.uintLessThan(usize, 12));
            try out.appendSlice(gpa, src[0..end]);
            try out.appendSlice(gpa, src[at..]);
        },
    }
    return out.toOwnedSlice(gpa);
}

test "the query compiler gives the steps and the errors of ts_query_new" {
    const gpa = std.testing.allocator;
    var totals = Totals{};
    var failures: usize = 0;
    inline for (corpus.paths, corpus.langs) |path, lang| {
        if (!try compare(gpa, lang, @embedFile(path), &totals)) failures += 1;
    }
    for (cases) |c| {
        if (!try compare(gpa, c[0], c[1], &totals)) failures += 1;
    }
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const r = prng.random();
    inline for (corpus.paths, corpus.langs) |path, lang| {
        const src: []const u8 = @embedFile(path);
        for (0..60) |_| {
            const m = try mutate(gpa, r, src);
            defer gpa.free(m);
            if (!try compare(gpa, lang, m, &totals)) failures += 1;
        }
    }
    for (cases) |c| {
        for (0..40) |_| {
            const m = try mutate(gpa, r, c[1]);
            defer gpa.free(m);
            if (!try compare(gpa, c[0], m, &totals)) failures += 1;
            if (failures > 5) return error.TestUnexpectedResult;
        }
    }
    std.debug.print("query compiler: {d} queries match the reference, {d} of them errors; {d} unsupported, {d} skipped\n", .{ totals.cases, totals.errors, totals.unsupported, totals.skipped });
    try std.testing.expectEqual(@as(usize, 0), failures);
    try std.testing.expect(totals.cases > 2000);
}
