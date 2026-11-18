//! ztree: a batch Tree-sitter runtime in Zig under the NASA Power of 10 rules.
//! ADR-0004 defines the scope. ADR-0003 defines the rule adaptation.

const std = @import("std");

pub const abi = @import("abi.zig");
pub const comments = @import("comments.zig");
pub const flat = @import("flat.zig");
pub const grammars = @import("grammars.zig");
pub const length = @import("length.zig");
pub const language = @import("language.zig");
pub const lexer = @import("lexer.zig");
pub const parser = @import("parser.zig");
pub const recover = @import("recover.zig");
pub const stack = @import("stack.zig");
pub const subtree = @import("subtree.zig");
pub const tree = @import("tree.zig");
pub const utf8 = @import("utf8.zig");

/// Hard limits for one parse. A parse that reaches a limit returns an error.
pub const limits = struct {
    /// The largest source text that one parse accepts.
    pub const max_source_bytes: usize = 16 * 1024 * 1024;
    /// The maximum number of GLR stack versions. The reference runtime uses 6.
    pub const max_stack_versions: usize = 6;
    /// The most subtrees that one parse allocates. ztree frees no subtree
    /// before the parse ends (ADR-0005).
    pub const max_subtrees: usize = 4 * 1024 * 1024;
    /// The most stack nodes that one parse allocates.
    pub const max_stack_nodes: usize = 4 * 1024 * 1024;
    /// The deepest tree that a walk visits.
    pub const max_tree_depth: usize = 1024 * 1024;
};

test "limits are positive" {
    try std.testing.expect(limits.max_source_bytes > 0);
    try std.testing.expect(limits.max_stack_versions > 0);
}

test {
    std.testing.refAllDecls(@This());
}
