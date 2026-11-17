//! ztree: a batch Tree-sitter runtime in Zig under the NASA Power of 10 rules.
//! ADR-0004 defines the scope. ADR-0003 defines the rule adaptation.

const std = @import("std");

pub const abi = @import("abi.zig");
pub const grammars = @import("grammars.zig");

/// Hard limits for one parse. A parse that reaches a limit returns an error.
pub const limits = struct {
    /// The largest source text that one parse accepts.
    pub const max_source_bytes: usize = 16 * 1024 * 1024;
    /// The maximum number of GLR stack versions. The reference runtime uses 6.
    pub const max_stack_versions: usize = 6;
};

test "limits are positive" {
    try std.testing.expect(limits.max_source_bytes > 0);
    try std.testing.expect(limits.max_stack_versions > 0);
}

test {
    std.testing.refAllDecls(@This());
}
