//! The corpus file format of the tree-sitter CLI v0.27.2
//! (`crates/cli/src/test.rs`): each example has a name, an input and the
//! expected S-expression. The conformance step and the query differential
//! step read it.

const std = @import("std");

pub const Expectation = enum { pass, err, skip };

pub const Example = struct {
    name: []const u8,
    input: []const u8,
    output: []const u8,
    has_fields: bool,
    expectation: Expectation,
};

/// `parse_delimiter_line`: 3 or more `c`, then an optional suffix.
pub fn delimiter(line: []const u8, c: u8) ?[]const u8 {
    var n: usize = 0;
    while (n < line.len and line[n] == c) n += 1;
    if (n < 3) return null;
    return std.mem.trimEnd(u8, line[n..], "\r\n");
}

pub fn suffixMatches(first: ?[]const u8, suffix: []const u8) bool {
    if (first) |f| return suffix.len > 0 and std.mem.eql(u8, f, suffix);
    return suffix.len == 0;
}

pub const Header = struct { name: []const u8, expectation: Expectation, body_start: usize };

/// `parse_header`: name lines, attribute lines and the closing `===` line.
pub fn parseHeader(lines: []const []const u8, first: ?[]const u8, start: usize) ?Header {
    const suffix = delimiter(lines[start], '=') orelse return null;
    if (!suffixMatches(first, suffix)) return null;
    var name: []const u8 = "";
    var seen_marker = false;
    var skip = false;
    var err = false;
    var i = start + 1;
    while (i < lines.len) : (i += 1) {
        if (delimiter(lines[i], '=')) |s| if (suffixMatches(first, s)) break;
        const trimmed = std.mem.trim(u8, lines[i], " \t\r\n");
        if (trimmed.len == 0 and !seen_marker) return null;
        var it = std.mem.splitScalar(u8, trimmed, '(');
        const head = it.first();
        if (std.mem.eql(u8, head, ":skip")) {
            seen_marker = true;
            skip = true;
        } else if (std.mem.eql(u8, head, ":error")) {
            seen_marker = true;
            err = true;
        } else if (std.mem.eql(u8, head, ":fail-fast") or std.mem.eql(u8, head, ":cst") or
            std.mem.eql(u8, head, ":platform") or std.mem.eql(u8, head, ":language"))
        {
            seen_marker = true;
        } else if (!seen_marker and name.len == 0) {
            name = std.mem.trimEnd(u8, lines[i], " \t\r\n");
        }
    }
    if (i >= lines.len) return null;
    const expectation: Expectation = if (skip) .skip else if (err) .err else .pass;
    return .{ .name = name, .expectation = expectation, .body_start = i + 1 };
}

/// `normalize_sexp_output`: drop `;` comment lines, collapse whitespace and
/// drop a space before `)`.
pub fn normalizeOutput(gpa: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var prev_space = false;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " \t\r"), ";")) continue;
        for (line) |c| {
            if (std.ascii.isWhitespace(c)) {
                if (!prev_space and out.items.len > 0) {
                    try out.append(gpa, ' ');
                    prev_space = true;
                }
            } else {
                if (c == ')' and prev_space) out.items.len -= 1;
                try out.append(gpa, c);
                prev_space = false;
            }
        }
        if (out.items.len > 0 and !prev_space) {
            try out.append(gpa, ' ');
            prev_space = true;
        }
    }
    while (out.items.len > 0 and std.ascii.isWhitespace(out.items[out.items.len - 1])) out.items.len -= 1;
    return out.toOwnedSlice(gpa);
}

/// `strip_sexp_fields`: replace ` word: (` with ` (`.
pub fn parseCorpus(gpa: std.mem.Allocator, content: []const u8, out: *std.ArrayList(Example)) !void {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);
    var start: usize = 0;
    while (start < content.len) {
        const end = if (std.mem.indexOfScalarPos(u8, content, start, '\n')) |e| e + 1 else content.len;
        try lines.append(gpa, content[start..end]);
        start = end;
    }
    var first: ?[]const u8 = null;
    for (lines.items) |line| if (delimiter(line, '=')) |s| if (s.len > 0) {
        first = s;
        break;
    };
    var pending: ?Header = null;
    var i: usize = 0;
    while (i < lines.items.len) {
        const h = parseHeader(lines.items, first, i) orelse {
            i += 1;
            continue;
        };
        if (pending) |p| try buildEntry(gpa, lines.items[p.body_start..i], first, p, out);
        pending = h;
        i = h.body_start;
    }
    if (pending) |p| try buildEntry(gpa, lines.items[p.body_start..], first, p, out);
}

pub fn buildEntry(gpa: std.mem.Allocator, body: []const []const u8, first: ?[]const u8, h: Header, out: *std.ArrayList(Example)) !void {
    var best: ?usize = null;
    var best_len: usize = 0;
    for (body, 0..) |line, j| {
        var n: usize = 0;
        while (n < line.len and line[n] == '-') n += 1;
        const suffix = delimiter(line, '-') orelse continue;
        if (!suffixMatches(first, suffix)) continue;
        if (n + suffix.len >= best_len) {
            best = j;
            best_len = n + suffix.len;
        }
    }
    const divider = best orelse return;
    var input: []const u8 = if (divider == 0) "" else spanOf(body[0], body[divider - 1]);
    if (std.mem.endsWith(u8, input, "\n")) input = input[0 .. input.len - 1];
    if (std.mem.endsWith(u8, input, "\r")) input = input[0 .. input.len - 1];
    const raw_output = if (divider + 1 < body.len) spanOf(body[divider + 1], body[body.len - 1]) else "";
    const output = try normalizeOutput(gpa, raw_output);
    try out.append(gpa, .{ .name = h.name, .input = input, .output = output, .has_fields = std.mem.indexOf(u8, output, ": (") != null, .expectation = h.expectation });
}

/// The bytes from the start of `a` to the end of `b`, two lines of one buffer.
pub fn spanOf(a: []const u8, b: []const u8) []const u8 {
    const start = @intFromPtr(a.ptr);
    const end = @intFromPtr(b.ptr) + b.len;
    return a.ptr[0 .. end - start];
}
