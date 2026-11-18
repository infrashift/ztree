//! The differential step on real source files (ISSUE-006). It walks the
//! directories of `-Ddiff-dirs` and runs each check of `differential.zig` on
//! each Go, Zig, Python, C, C++ and Rust file: the node dump, the S-expression, the
//! visible-node walk and the comment spans.

const std = @import("std");
const ztree = @import("ztree");
const options = @import("diff_options");
const diff = @import("differential.zig");

/// The most bytes of one file. Larger files count as skipped.
const max_file_bytes = 512 * 1024;
const skip_dirs = [_][]const u8{ ".git", ".zig-cache", "zig-out", "node_modules", "target", "__pycache__" };

fn langOf(path: []const u8) ?[]const u8 {
    const ext = std.fs.path.extension(path);
    const map = [_]struct { []const u8, []const u8 }{ .{ ".go", "go" }, .{ ".zig", "zig" }, .{ ".py", "python" }, .{ ".c", "c" }, .{ ".h", "c" }, .{ ".rs", "rust" }, .{ ".cc", "cpp" }, .{ ".cpp", "cpp" }, .{ ".cxx", "cpp" }, .{ ".hh", "cpp" }, .{ ".hpp", "cpp" }, .{ ".hxx", "cpp" } };
    for (map) |m| if (std.mem.eql(u8, ext, m[0])) return m[1];
    return null;
}

const Stats = struct {
    files: usize = 0,
    skipped: usize = 0,
    failures: usize = 0,
    /// Per language: files, files whose tree has errors.
    per_lang: [6][2]usize = @splat(.{ 0, 0 }),
};

fn langIndex(name: []const u8) usize {
    const names = [_][]const u8{ "go", "zig", "python", "c", "rust", "cpp" };
    for (names, 0..) |n, i| if (std.mem.eql(u8, n, name)) return i;
    unreachable;
}

fn checkDir(gpa: std.mem.Allocator, io: std.Io, root: []const u8, stats: *Stats, totals: *diff.Totals) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walkSelectively(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory) {
            var skip = false;
            for (skip_dirs) |d| skip = skip or std.mem.eql(u8, entry.basename, d);
            if (!skip) try walker.enter(io, entry);
            continue;
        }
        if (entry.kind != .file) continue;
        const lang = langOf(entry.basename) orelse continue;
        const text = entry.dir.readFileAlloc(io, entry.basename, gpa, .limited(max_file_bytes)) catch |err| switch (err) {
            error.StreamTooLong => {
                stats.skipped += 1;
                continue;
            },
            else => return err,
        };
        defer gpa.free(text);
        const name = try std.fs.path.join(gpa, &.{ root, entry.path });
        defer gpa.free(name);
        stats.files += 1;
        const li = langIndex(lang);
        stats.per_lang[li][0] += 1;
        diff.check(lang, name, text, totals) catch |err| {
            stats.failures += 1;
            std.debug.print("differential failure: {s}: {s}\n", .{ name, @errorName(err) });
            continue;
        };
        if (totals.last_had_error) stats.per_lang[li][1] += 1;
        if (totals.last_had_error and options.list_errors) std.debug.print("tree with errors: {s}\n", .{name});
    }
}

test "real source files parse the same with ztree and the reference runtime" {
    const gpa = std.testing.allocator;
    var stats = Stats{};
    var totals = diff.Totals{};
    for (options.dirs) |d| try checkDir(gpa, std.testing.io, d, &stats, &totals);
    const names = [_][]const u8{ "go", "zig", "python", "c", "rust", "cpp" };
    std.debug.print("differential: {d} files, {d} skipped (over {d} bytes), {d} failures, {d} comments, {d} flat nodes, {d} field children, {d} overrides\n", .{ stats.files, stats.skipped, max_file_bytes, stats.failures, totals.comments, totals.nodes, totals.field_children, totals.overrides });
    for (names, stats.per_lang) |n, c| if (c[0] > 0) std.debug.print("  {s}: {d} files, {d} with syntax errors\n", .{ n, c[0], c[1] });
    try std.testing.expectEqual(@as(usize, 0), stats.failures);
    try std.testing.expect(stats.files > 0);
}
