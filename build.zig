const std = @import("std");

/// The vendored grammars (ADR-0004). A grammar with an external scanner has a `scanner.c`.
const grammar_sources = [_][]const u8{
    "third_party/grammars/go/src/parser.c",
    "third_party/grammars/zig/src/parser.c",
    "third_party/grammars/python/src/parser.c",
    "third_party/grammars/python/src/scanner.c",
    "third_party/grammars/c/src/parser.c",
    "third_party/grammars/rust/src/parser.c",
    "third_party/grammars/rust/src/scanner.c",
};

const c_flags = [_][]const u8{"-std=c11"};
/// The reference runtime and the shim over it need POSIX and BSD declarations.
const oracle_flags = [_][]const u8{ "-std=c11", "-D_POSIX_C_SOURCE=200112L", "-D_DEFAULT_SOURCE" };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // `--release` builds ReleaseSafe: assertions stay active (ADR-0003).
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    const mod = b.addModule("ztree", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    for (grammar_sources) |src| {
        mod.addCSourceFile(.{ .file = b.path(src), .flags = &c_flags });
    }

    // The reference runtime: a test oracle only. The library never links it (ADR-0002).
    const oracle = b.addLibrary(.{
        .linkage = .static,
        .name = "ts_oracle",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    oracle.root_module.addCSourceFile(.{
        .file = b.path("third_party/tree-sitter/lib/src/lib.c"),
        .flags = &oracle_flags,
    });
    oracle.root_module.addIncludePath(b.path("third_party/tree-sitter/lib/include"));
    oracle.root_module.addIncludePath(b.path("third_party/tree-sitter/lib/src"));

    const test_step = b.step("test", "Run the unit tests and the ABI tests");
    const mod_tests = b.addTest(.{ .root_module = mod });
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);

    const abi_mod = b.createModule(.{
        .root_source_file = b.path("tests/abi_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "ztree", .module = mod }},
    });
    abi_mod.addCSourceFile(.{ .file = b.path("tests/abi15_probe.c"), .flags = &c_flags });
    abi_mod.addCSourceFile(.{ .file = b.path("tests/abi14_probe.c"), .flags = &c_flags });
    abi_mod.linkLibrary(oracle);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = abi_mod })).step);

    const lexer_mod = b.createModule(.{
        .root_source_file = b.path("tests/lexer_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "ztree", .module = mod }},
    });
    lexer_mod.addCSourceFile(.{ .file = b.path("tests/ref_shim.c"), .flags = &oracle_flags });
    lexer_mod.addIncludePath(b.path("third_party/tree-sitter/lib/include"));
    lexer_mod.addIncludePath(b.path("third_party/tree-sitter/lib/src"));
    lexer_mod.linkLibrary(oracle);
    for (lexer_samples) |sample| {
        lexer_mod.addAnonymousImport(sample[0], .{ .root_source_file = b.path(sample[1]) });
    }
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = lexer_mod })).step);

    const parser_mod = b.createModule(.{
        .root_source_file = b.path("tests/parser_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "ztree", .module = mod }},
    });
    parser_mod.addCSourceFile(.{ .file = b.path("tests/ref_shim.c"), .flags = &oracle_flags });
    parser_mod.addIncludePath(b.path("third_party/tree-sitter/lib/include"));
    parser_mod.addIncludePath(b.path("third_party/tree-sitter/lib/src"));
    parser_mod.linkLibrary(oracle);
    const sample_options = b.addOptions();
    var langs: [parser_samples.len][]const u8 = undefined;
    var kinds: [parser_samples.len][]const u8 = undefined;
    var paths: [parser_samples.len][]const u8 = undefined;
    for (parser_samples, 0..) |sample, i| {
        langs[i] = sample[0];
        kinds[i] = sample[1];
        paths[i] = sample[2];
        parser_mod.addAnonymousImport(sample[2], .{ .root_source_file = b.path(sample[2]) });
    }
    sample_options.addOption([]const []const u8, "langs", &langs);
    sample_options.addOption([]const []const u8, "kinds", &kinds);
    sample_options.addOption([]const []const u8, "paths", &paths);
    parser_mod.addOptions("samples", sample_options);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = parser_mod })).step);
}

/// Sample inputs of the lexer differential test (tests/lexer_test.zig).
const lexer_samples = [_]struct { []const u8, []const u8 }{
    .{ "go_declarations", "third_party/grammars/go/test/corpus/declarations.txt" },
    .{ "go_expressions", "third_party/grammars/go/test/corpus/expressions.txt" },
    .{ "python_statements", "third_party/grammars/python/test/corpus/statements.txt" },
    .{ "python_expressions", "third_party/grammars/python/test/corpus/expressions.txt" },
    .{ "c_declarations", "third_party/grammars/c/test/corpus/declarations.txt" },
    .{ "c_preprocessor", "third_party/grammars/c/test/corpus/preprocessor.txt" },
    .{ "rust_declarations", "third_party/grammars/rust/test/corpus/declarations.txt" },
    .{ "rust_literals", "third_party/grammars/rust/test/corpus/literals.txt" },
    .{ "zig_lexer", "src/lexer.zig" },
};

/// Inputs of the parser differential test (tests/parser_test.zig): grammar, kind, path.
const parser_samples = [_]struct { []const u8, []const u8, []const u8 }{
    .{ "go", "corpus", "third_party/grammars/go/test/corpus/declarations.txt" },
    .{ "go", "corpus", "third_party/grammars/go/test/corpus/errors.txt" },
    .{ "go", "corpus", "third_party/grammars/go/test/corpus/expressions.txt" },
    .{ "go", "corpus", "third_party/grammars/go/test/corpus/literals.txt" },
    .{ "go", "corpus", "third_party/grammars/go/test/corpus/source_files.txt" },
    .{ "go", "corpus", "third_party/grammars/go/test/corpus/statements.txt" },
    .{ "go", "corpus", "third_party/grammars/go/test/corpus/types.txt" },
    .{ "python", "corpus", "third_party/grammars/python/test/corpus/errors.txt" },
    .{ "python", "corpus", "third_party/grammars/python/test/corpus/expressions.txt" },
    .{ "python", "corpus", "third_party/grammars/python/test/corpus/literals.txt" },
    .{ "python", "corpus", "third_party/grammars/python/test/corpus/pattern_matching.txt" },
    .{ "python", "corpus", "third_party/grammars/python/test/corpus/statements.txt" },
    .{ "c", "corpus", "third_party/grammars/c/test/corpus/ambiguities.txt" },
    .{ "c", "corpus", "third_party/grammars/c/test/corpus/crlf.txt" },
    .{ "c", "corpus", "third_party/grammars/c/test/corpus/declarations.txt" },
    .{ "c", "corpus", "third_party/grammars/c/test/corpus/expressions.txt" },
    .{ "c", "corpus", "third_party/grammars/c/test/corpus/microsoft.txt" },
    .{ "c", "corpus", "third_party/grammars/c/test/corpus/preprocessor.txt" },
    .{ "c", "corpus", "third_party/grammars/c/test/corpus/statements.txt" },
    .{ "c", "corpus", "third_party/grammars/c/test/corpus/types.txt" },
    .{ "rust", "corpus", "third_party/grammars/rust/test/corpus/async.txt" },
    .{ "rust", "corpus", "third_party/grammars/rust/test/corpus/declarations.txt" },
    .{ "rust", "corpus", "third_party/grammars/rust/test/corpus/error.txt" },
    .{ "rust", "corpus", "third_party/grammars/rust/test/corpus/expressions.txt" },
    .{ "rust", "corpus", "third_party/grammars/rust/test/corpus/literals.txt" },
    .{ "rust", "corpus", "third_party/grammars/rust/test/corpus/macros.txt" },
    .{ "rust", "corpus", "third_party/grammars/rust/test/corpus/patterns.txt" },
    .{ "rust", "corpus", "third_party/grammars/rust/test/corpus/source_files.txt" },
    .{ "rust", "corpus", "third_party/grammars/rust/test/corpus/types.txt" },
    .{ "zig", "file", "src/abi.zig" },
    .{ "zig", "file", "src/grammars.zig" },
    .{ "zig", "file", "src/language.zig" },
    .{ "zig", "file", "src/length.zig" },
    .{ "zig", "file", "src/lexer.zig" },
    .{ "zig", "file", "src/parser.zig" },
    .{ "zig", "file", "src/root.zig" },
    .{ "zig", "file", "src/stack.zig" },
    .{ "zig", "file", "src/subtree.zig" },
    .{ "zig", "file", "src/utf8.zig" },
    .{ "c", "file", "third_party/grammars/python/src/scanner.c" },
    .{ "c", "file", "third_party/grammars/rust/src/scanner.c" },
    .{ "c", "file", "third_party/tree-sitter/lib/src/stack.c" },
    .{ "c", "file", "tests/ref_shim.c" },
    .{ "python", "file", "scripts/nasa-lint.py" },
    .{ "python", "file", "scripts/ste-check.py" },
};
