//! The query differential step (ISSUE-014): `zig build query-diff`. It runs
//! each query of the corpus over each source of the same language, with
//! ztree and with `ts_query_cursor_next_match` of the reference runtime,
//! and compares the matches: the pattern, the order and each capture. The
//! sources are the inputs of the grammar corpus examples and the files of
//! `-Dquery-dirs`. The comparison skips the text predicates, which the
//! reference cursor does not run.

const std = @import("std");
const ztree = @import("ztree");
const grammars = ztree.grammars;
const corpus_file = @import("corpus_file.zig");
const grammar_corpus = @import("corpus");
const query_corpus = @import("query_corpus");
const options = @import("query_diff_options");
const cases = @import("query_cases.zig").cases;

const Match = ztree.query_exec.Match;
const Capture = ztree.query_exec.Capture;
extern fn ztree_ref_query_matches(lang: *const ztree.abi.Language14, query: [*]const u8, query_len: u32, src: [*]const u8, len: u32, matches: [*]Match, match_cap: u32, match_count: *u32, caps: [*]Capture, cap_cap: u32, cap_count: *u32) bool;

const Source = struct { name: []const u8, text: []const u8 };
const Query = struct { name: []const u8, text: []const u8 };

const Totals = struct { runs: usize = 0, matches: usize = 0, captures: usize = 0, unsupported: usize = 0 };

fn langOf(path: []const u8) ?grammars.Lang {
    const ext = std.fs.path.extension(path);
    const map = [_]struct { []const u8, grammars.Lang }{ .{ ".go", .go }, .{ ".zig", .zig }, .{ ".py", .python }, .{ ".c", .c }, .{ ".h", .c }, .{ ".rs", .rust }, .{ ".cc", .cpp }, .{ ".cpp", .cpp }, .{ ".hpp", .cpp } };
    for (map) |m| if (std.mem.eql(u8, ext, m[0])) return m[1];
    return null;
}

/// Add each source file of `root` to the source list of its language.
fn addDir(arena: std.mem.Allocator, io: std.Io, root: []const u8, sources: *[6]std.ArrayList(Source)) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walkSelectively(arena);
    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory) {
            if (!std.mem.eql(u8, entry.basename, ".git") and !std.mem.eql(u8, entry.basename, ".zig-cache")) try walker.enter(io, entry);
            continue;
        }
        if (entry.kind != .file) continue;
        const lang = langOf(entry.basename) orelse continue;
        const text = entry.dir.readFileAlloc(io, entry.basename, arena, .limited(256 * 1024)) catch continue;
        try sources[@backingInt(lang)].append(arena, .{ .name = try std.fs.path.join(arena, &.{ root, entry.path }), .text = text });
    }
}

/// Compile `q` into a blob with ztree, or null when ztree rejects it.
fn compile(arena: std.mem.Allocator, lang: grammars.Lang, q: []const u8) !?[]align(4) u8 {
    var failure = ztree.query.Failure{};
    var ub = false;
    const compiled = ztree.query.compile(arena, grammars.language(lang), q, &failure, &ub) catch |err| switch (err) {
        error.QueryError => return null,
        else => return err,
    };
    if (ub) return null;
    const preds = ztree.query_predicates.compile(compiled, &failure) catch |err| switch (err) {
        error.QueryError => return null,
        else => return err,
    };
    const size = try ztree.query_blob.write(arena, @backingInt(lang), compiled, &preds, &.{});
    const blob = try arena.alignedAlloc(u8, .fromByteUnits(4), size);
    _ = try ztree.query_blob.write(arena, @backingInt(lang), compiled, &preds, blob);
    return blob;
}

/// Run one query over one source with both runtimes. Return false on a difference.
fn compareRun(gpa: std.mem.Allocator, lang: grammars.Lang, q: Query, view: *const ztree.query_blob.View, src: Source, totals: *Totals) !bool {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const language = grammars.language(lang);
    const root = try ztree.parser.parse(arena, language, src.text);
    const counts = try ztree.flat.flatten(arena, language, root, &.{}, &.{});
    const nodes = try arena.alloc(ztree.flat.Node, counts.nodes);
    const overrides = try arena.alloc(ztree.flat.FieldOverride, counts.overrides);
    _ = try ztree.flat.flatten(arena, language, root, nodes, overrides);
    const in = ztree.query_exec.Input{ .view = view, .nodes = nodes, .overrides = overrides, .text = src.text, .start = 0 };
    const n = try ztree.query_exec.exec(arena, in, true, &.{}, &.{});
    const ours_m = try arena.alloc(Match, n.matches);
    const ours_c = try arena.alloc(Capture, n.captures);
    _ = try ztree.query_exec.exec(arena, in, true, ours_m, ours_c);
    const ref_m = try arena.alloc(Match, n.matches + 64);
    const ref_c = try arena.alloc(Capture, n.captures + 256);
    var rm: u32 = 0;
    var rc: u32 = 0;
    const fits = ztree_ref_query_matches(language, q.text.ptr, @intCast(q.text.len), src.text.ptr, @intCast(src.text.len), ref_m.ptr, @intCast(ref_m.len), &rm, ref_c.ptr, @intCast(ref_c.len), &rc);
    totals.runs += 1;
    totals.matches += n.matches;
    totals.captures += n.captures;
    if (fits and rm == n.matches and rc == n.captures and std.mem.eql(u8, std.mem.sliceAsBytes(ref_m[0..rm]), std.mem.sliceAsBytes(ours_m)) and std.mem.eql(u8, std.mem.sliceAsBytes(ref_c[0..rc]), std.mem.sliceAsBytes(ours_c))) return true;
    std.debug.print("query-diff: {s} over {s}: ref {d} matches {d} captures, ztree {d} matches {d} captures\n", .{ q.name, src.name, rm, rc, n.matches, n.captures });
    const limit = @min(@min(rm, n.matches), 400);
    var ci: usize = 0;
    for (0..limit) |i| {
        const same = std.meta.eql(ref_m[i], ours_m[i]) and std.mem.eql(u8, std.mem.sliceAsBytes(ref_c[ci..][0..ref_m[i].capture_count]), std.mem.sliceAsBytes(ours_c[ci..][0..@min(ours_m[i].capture_count, ours_c.len - ci)]));
        if (!same) {
            std.debug.print("  first difference at match {d}: ref {any} {any}\n  ztree {any} {any}\n", .{ i, ref_m[i], ref_c[ci..][0..ref_m[i].capture_count], ours_m[i], ours_c[ci..][0..@min(ours_m[i].capture_count, ours_c.len - ci)] });
            break;
        }
        ci += ref_m[i].capture_count;
    }
    return false;
}

test "query matches equal the matches of the reference query cursor" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sources: [6]std.ArrayList(Source) = @splat(.empty);
    inline for (grammar_corpus.paths, grammar_corpus.langs) |path, lang_name| {
        var examples: std.ArrayList(corpus_file.Example) = .empty;
        try corpus_file.parseCorpus(arena, @embedFile(path), &examples);
        const lang = std.meta.stringToEnum(grammars.Lang, lang_name).?;
        for (examples.items) |ex| try sources[@backingInt(lang)].append(arena, .{ .name = ex.name, .text = ex.input });
    }
    for (options.dirs) |d| try addDir(arena, std.testing.io, d, &sources);
    var queries: [6]std.ArrayList(Query) = @splat(.empty);
    inline for (query_corpus.paths, query_corpus.langs) |path, lang_name| {
        try queries[@backingInt(std.meta.stringToEnum(grammars.Lang, lang_name).?)].append(arena, .{ .name = path, .text = @embedFile(path) });
    }
    for (cases) |c| try queries[@backingInt(std.meta.stringToEnum(grammars.Lang, c[0]).?)].append(arena, .{ .name = c[1], .text = c[1] });
    var totals = Totals{};
    var failures: usize = 0;
    for (queries, sources, 0..) |qs, srcs, li| {
        const lang: grammars.Lang = @fromBackingInt(@intCast(li));
        for (qs.items) |q| {
            const blob = try compile(arena, lang, q.text) orelse {
                totals.unsupported += 1;
                continue;
            };
            const view = try ztree.query_blob.View.init(blob);
            for (srcs.items) |src| {
                if (!try compareRun(gpa, lang, q, &view, src, &totals)) failures += 1;
                if (failures > 3) return error.TestUnexpectedResult;
            }
        }
    }
    std.debug.print("query-diff: {d} runs, {d} matches and {d} captures equal the reference; {d} queries do not compile\n", .{ totals.runs, totals.matches, totals.captures, totals.unsupported });
    try std.testing.expectEqual(@as(usize, 0), failures);
    try std.testing.expect(totals.matches > 1000);
}
