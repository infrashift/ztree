//! The six vendored grammars (ADR-0004, ADR-0007). `build.zig` compiles their C files
//! from `third_party/grammars/` into the ztree module.

const std = @import("std");
const assert = std.debug.assert;
const abi = @import("abi.zig");

pub const Lang = enum { go, zig, python, c, rust, cpp };

extern fn tree_sitter_go() callconv(.c) *const abi.Language14;
extern fn tree_sitter_zig() callconv(.c) *const abi.Language14;
extern fn tree_sitter_python() callconv(.c) *const abi.Language14;
extern fn tree_sitter_c() callconv(.c) *const abi.Language14;
extern fn tree_sitter_rust() callconv(.c) *const abi.Language14;
extern fn tree_sitter_cpp() callconv(.c) *const abi.Language14;

/// Return the generated language of `lang`. Each vendored grammar has a
/// supported ABI version, so a failed check is a programmer error.
pub fn language(lang: Lang) *const abi.Language14 {
    const result = switch (lang) {
        .go => tree_sitter_go(),
        .zig => tree_sitter_zig(),
        .python => tree_sitter_python(),
        .c => tree_sitter_c(),
        .rust => tree_sitter_rust(),
        .cpp => tree_sitter_cpp(),
    };
    assert(result.abi_version >= abi.min_abi_version);
    assert(result.abi_version <= abi.max_abi_version);
    return result;
}

test "each vendored grammar has a supported ABI version" {
    for (std.enums.values(Lang)) |lang| {
        try abi.checkVersion(language(lang));
    }
}
