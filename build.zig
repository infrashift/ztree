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
        .flags = &.{ "-std=c11", "-D_POSIX_C_SOURCE=200112L", "-D_DEFAULT_SOURCE" },
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
}
