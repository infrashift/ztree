//! The GLR parse stack. This ports `stack.c` of the reference runtime.
//! Stack nodes live in the parse arena and ztree frees none of them before
//! the parse ends, so ztree keeps no reference counts (ADR-0005). The merge
//! of stack nodes uses an explicit frame stack in place of recursion (R1).

const std = @import("std");
const assert = std.debug.assert;
const abi = @import("abi.zig");
const length = @import("length.zig");
const st = @import("subtree.zig");
const limits = @import("root.zig").limits;

const Subtree = st.Subtree;
const StateId = abi.StateId;
const Length = length.Length;
const Allocator = std.mem.Allocator;

const max_link_count = 8;
const max_iterator_count = 64;
/// The most stack versions that the stack holds at one time (ADR-0013).
pub const max_heads = limits.max_stack_heads;

pub const Version = u32;
pub const version_none: Version = std.math.maxInt(Version);

pub const Error = error{ OutOfMemory, TooManyStackNodes, TooManyVersions, StackTooDeep };

pub const Link = struct {
    node: ?*Node = null,
    subtree: ?*const Subtree = null,
    is_pending: bool = false,
};

pub const Node = struct {
    state: StateId,
    position: Length,
    links: [max_link_count]Link = @splat(.{}),
    link_count: u16 = 0,
    error_cost: u32 = 0,
    node_count: u32 = 0,
    dynamic_precedence: i32 = 0,
};

pub const Status = enum { active, paused, halted };

pub const SummaryEntry = struct {
    position: Length,
    depth: u32,
    state: StateId,
};

pub const Summary = std.ArrayList(SummaryEntry);

const Head = struct {
    node: *Node,
    summary: ?*Summary = null,
    node_count_at_last_error: u32 = 0,
    last_external_token: ?*const Subtree = null,
    lookahead_when_paused: ?*const Subtree = null,
    status: Status = .active,
};

pub const SubtreeList = std.ArrayList(*const Subtree);

pub const Slice = struct {
    subtrees: SubtreeList,
    version: Version,
};

const Iterator = struct {
    node: *Node,
    subtrees: SubtreeList,
    subtree_count: u32,
    is_pending: bool,
};

/// The pop operations of `stack__iter`. A switch replaces the C callbacks (R9).
const PopKind = union(enum) {
    count: u32,
    err: *bool,
    all,
    summary: struct { summary: *Summary, max_depth: u32 },
};

const Action = struct { pop: bool = false, stop: bool = false };

/// One level of the merge in `addLink`: merge each link of `source` into `into`.
const MergeFrame = struct {
    parent: *Node,
    into: *Node,
    source: *Node,
    link_subtree: ?*const Subtree,
    next: u16 = 0,
};

fn dynPrec(tree: ?*const Subtree) i32 {
    assert(tree == null or tree.?.children.len <= limits.max_subtrees);
    assert(tree == null or tree.?.padding.bytes <= limits.max_source_bytes);
    const t = tree orelse return 0;
    return t.dynamicPrecedence();
}

/// The number of nodes in `tree` for progress checks (`stack__subtree_node_count`).
fn subtreeNodeCount(tree: *const Subtree) u32 {
    assert(tree.children.len <= limits.max_subtrees);
    var count = tree.visibleDescendantCount();
    if (tree.visible) count += 1;
    if (tree.symbol == @import("language.zig").builtin_sym_error_repeat) count += 1;
    assert(count >= tree.visibleDescendantCount());
    return count;
}

fn isEquivalent(left: ?*const Subtree, right: ?*const Subtree) bool {
    assert(left == null or left.?.size.bytes <= limits.max_source_bytes);
    assert(right == null or right.?.size.bytes <= limits.max_source_bytes);
    if (left == right) return true;
    const l = left orelse return false;
    const r = right orelse return false;
    if (l.symbol != r.symbol) return false;
    if (l.errorCost() > 0 and r.errorCost() > 0) return true;
    return l.padding.bytes == r.padding.bytes and l.size.bytes == r.size.bytes and
        l.children.len == r.children.len and l.extra == r.extra and st.externalStateEq(l, r);
}

pub const Stack = struct {
    arena: Allocator,
    heads: std.ArrayList(Head) = .empty,
    slices: std.ArrayList(Slice) = .empty,
    iterators: std.ArrayList(Iterator) = .empty,
    frames: std.ArrayList(MergeFrame) = .empty,
    base_node: *Node,
    node_total: usize = 0,

    pub fn init(arena: Allocator) Error!Stack {
        assert(limits.max_stack_nodes > 1);
        const base = try arena.create(Node);
        base.* = .{ .state = 1, .position = length.zero };
        var self = Stack{ .arena = arena, .base_node = base, .node_total = 1 };
        try self.clear();
        assert(self.heads.items.len == 1);
        return self;
    }

    /// Reset to one version at the base node (`ts_stack_clear`).
    pub fn clear(self: *Stack) Error!void {
        assert(self.base_node.link_count == 0);
        self.heads.clearRetainingCapacity();
        try self.heads.append(self.arena, .{ .node = self.base_node });
        assert(self.heads.items.len == 1);
    }

    fn head(self: *const Stack, version: Version) *Head {
        assert(version < self.heads.items.len);
        assert(self.heads.items.len <= max_heads);
        return &self.heads.items[version];
    }

    fn newNode(self: *Stack, previous: ?*Node, tree: ?*const Subtree, is_pending: bool, next_state: StateId) Error!*Node {
        assert(self.node_total <= limits.max_stack_nodes);
        if (self.node_total == limits.max_stack_nodes) return error.TooManyStackNodes;
        const node = try self.arena.create(Node);
        self.node_total += 1;
        node.* = .{ .state = next_state, .position = length.zero };
        const prev = previous orelse return node;
        node.link_count = 1;
        node.links[0] = .{ .node = prev, .subtree = tree, .is_pending = is_pending };
        node.position = prev.position;
        node.error_cost = prev.error_cost;
        node.dynamic_precedence = prev.dynamic_precedence;
        node.node_count = prev.node_count;
        if (tree) |t| {
            node.error_cost += t.errorCost();
            node.position = st.addLength(node.position, t.totalSize());
            node.node_count += subtreeNodeCount(t);
            node.dynamic_precedence += t.dynamicPrecedence();
        }
        assert(node.link_count == 1);
        return node;
    }

    pub fn versionCount(self: *const Stack) u32 {
        assert(self.node_total >= 1);
        assert(self.heads.items.len <= max_heads);
        return @intCast(self.heads.items.len);
    }

    pub fn haltedVersionCount(self: *const Stack) u32 {
        assert(self.heads.items.len <= max_heads);
        var count: u32 = 0;
        for (self.heads.items) |h| {
            if (h.status == .halted) count += 1;
        }
        assert(count <= self.heads.items.len);
        return count;
    }

    pub fn state(self: *const Stack, version: Version) StateId {
        assert(version < self.heads.items.len);
        assert(self.heads.items[version].node.link_count <= max_link_count);
        return self.head(version).node.state;
    }

    pub fn position(self: *const Stack, version: Version) Length {
        assert(version < self.heads.items.len);
        assert(self.heads.items[version].node.link_count <= max_link_count);
        return self.head(version).node.position;
    }

    pub fn lastExternalToken(self: *const Stack, version: Version) ?*const Subtree {
        assert(version < self.heads.items.len);
        assert(self.heads.items[version].node.link_count <= max_link_count);
        return self.head(version).last_external_token;
    }

    pub fn setLastExternalToken(self: *Stack, version: Version, token: ?*const Subtree) void {
        assert(version < self.heads.items.len);
        assert(token == null or token.?.has_external_tokens);
        self.head(version).last_external_token = token;
    }

    pub fn errorCost(self: *const Stack, version: Version) u32 {
        assert(version < self.heads.items.len);
        const h = self.head(version);
        var result = h.node.error_cost;
        if (h.status == .paused or (h.node.state == 0 and h.node.links[0].subtree == null)) {
            result += st.error_cost_per_recovery;
        }
        assert(result >= h.node.error_cost);
        return result;
    }

    pub fn nodeCountSinceError(self: *Stack, version: Version) u32 {
        assert(version < self.heads.items.len);
        const h = self.head(version);
        if (h.node.node_count < h.node_count_at_last_error) h.node_count_at_last_error = h.node.node_count;
        assert(h.node.node_count >= h.node_count_at_last_error);
        return h.node.node_count - h.node_count_at_last_error;
    }

    pub fn dynamicPrecedence(self: *const Stack, version: Version) i32 {
        assert(version < self.heads.items.len);
        assert(self.heads.items[version].node.link_count <= max_link_count);
        return self.head(version).node.dynamic_precedence;
    }

    /// Push `tree` onto `version` (`ts_stack_push`).
    pub fn push(self: *Stack, version: Version, tree: ?*const Subtree, pending: bool, next_state: StateId) Error!void {
        assert(tree == null or tree.?.size.bytes <= limits.max_source_bytes);
        const h = self.head(version);
        const node = try self.newNode(h.node, tree, pending, next_state);
        if (tree == null) h.node_count_at_last_error = node.node_count;
        h.node = node;
        assert(self.head(version).node == node);
    }

    pub fn popCount(self: *Stack, version: Version, count: u32) Error![]Slice {
        assert(version < self.heads.items.len);
        assert(count <= std.math.maxInt(i32));
        return self.iter(version, .{ .count = count }, @intCast(count));
    }

    /// Pop the ERROR subtree on top of `version` (`ts_stack_pop_error`).
    pub fn popError(self: *Stack, version: Version) Error!SubtreeList {
        const node = self.head(version).node;
        assert(node.link_count <= max_link_count);
        for (node.links[0..node.link_count]) |link| {
            const t = link.subtree orelse continue;
            if (!t.isError()) continue;
            var found = false;
            const pop = try self.iter(version, .{ .err = &found }, 1);
            if (pop.len > 0) {
                assert(pop.len == 1);
                self.renumberVersion(pop[0].version, version);
                return pop[0].subtrees;
            }
            break;
        }
        return .empty;
    }

    pub fn popAll(self: *Stack, version: Version) Error![]Slice {
        assert(self.heads.items[version].node.link_count <= max_link_count);
        assert(version < self.heads.items.len);
        return self.iter(version, .all, 0);
    }

    pub fn recordSummary(self: *Stack, version: Version, max_depth: u32) Error!void {
        assert(version < self.heads.items.len);
        const summary = try self.arena.create(Summary);
        summary.* = .empty;
        const pop = try self.iter(version, .{ .summary = .{ .summary = summary, .max_depth = max_depth } }, -1);
        assert(pop.len == 0);
        self.head(version).summary = summary;
    }

    pub fn getSummary(self: *const Stack, version: Version) ?*Summary {
        assert(version < self.heads.items.len);
        assert(self.heads.items[version].node.link_count <= max_link_count);
        return self.head(version).summary;
    }

    fn callback(kind: PopKind, it: *const Iterator) Error!Action {
        assert(it.subtree_count <= limits.max_stack_nodes);
        assert(it.node.link_count <= max_link_count);
        switch (kind) {
            .count => |goal| return if (it.subtree_count == goal) .{ .pop = true, .stop = true } else .{},
            .err => |found| {
                if (it.subtrees.items.len == 0) return .{};
                if (!found.* and it.subtrees.items[0].isError()) {
                    found.* = true;
                    return .{ .pop = true, .stop = true };
                }
                return .{ .stop = true };
            },
            .all => return if (it.node.link_count == 0) .{ .pop = true } else .{},
            .summary => |s| return summarize(s.summary, s.max_depth, it),
        }
    }

    /// The decision of `summarize_stack_callback`. `recordEntry` adds the entry.
    fn summarize(summary: *Summary, max_depth: u32, it: *const Iterator) Error!Action {
        assert(summary.items.len < limits.max_stack_nodes);
        assert(max_depth < std.math.maxInt(u32));
        if (it.subtree_count > max_depth) return .{ .stop = true };
        return .{};
    }

    /// Walk the paths back from the head of `version` and collect slices
    /// (`stack__iter`). `goal` is negative when the walk keeps no subtrees.
    fn iter(self: *Stack, version: Version, kind: PopKind, goal: i32) Error![]Slice {
        assert(version < self.heads.items.len);
        self.slices.clearRetainingCapacity();
        self.iterators.clearRetainingCapacity();
        var first = Iterator{ .node = self.head(version).node, .subtrees = .empty, .subtree_count = 0, .is_pending = true };
        if (goal >= 0) try first.subtrees.ensureTotalCapacity(self.arena, @intCast(goal + 1));
        try self.iterators.append(self.arena, first);
        var rounds: usize = 0;
        while (self.iterators.items.len > 0) : (rounds += 1) {
            if (rounds > self.node_total) return error.StackTooDeep;
            try self.iterRound(version, kind, goal >= 0);
        }
        assert(self.iterators.items.len == 0);
        return self.slices.items;
    }

    /// One pass over the iterators of `iter`.
    fn iterRound(self: *Stack, version: Version, kind: PopKind, include_subtrees: bool) Error!void {
        var i: usize = 0;
        var size = self.iterators.items.len;
        assert(size <= max_iterator_count);
        while (i < size) {
            const it = &self.iterators.items[i];
            const node = it.node;
            const action = try callback(kind, it);
            if (kind == .summary and !action.stop) try recordEntry(self.arena, kind.summary.summary, it);
            const stop = action.stop or node.link_count == 0;
            if (action.pop) {
                var subtrees = it.subtrees;
                if (!stop) subtrees = try subtrees.clone(self.arena);
                std.mem.reverse(*const Subtree, subtrees.items);
                try self.addSlice(version, node, subtrees);
            }
            if (stop) {
                const removed = self.iterators.orderedRemove(i);
                assert(removed.node == node);
                size -= 1;
                continue;
            }
            try self.followLinks(i, include_subtrees);
            i += 1;
        }
        assert(i == size);
    }

    /// Add a summary entry when `summarize` found no equal entry.
    fn recordEntry(arena: Allocator, summary: *Summary, it: *const Iterator) Error!void {
        assert(it.node.link_count <= max_link_count);
        const depth = it.subtree_count;
        var i = summary.items.len;
        while (i > 0) {
            i -= 1;
            const entry = summary.items[i];
            if (entry.depth < depth) break;
            if (entry.depth == depth and entry.state == it.node.state) return;
        }
        assert(summary.items.len < limits.max_stack_nodes);
        try summary.append(arena, .{ .position = it.node.position, .depth = depth, .state = it.node.state });
    }

    /// Move iterator `i` along each link of its node. Extra links get copies.
    fn followLinks(self: *Stack, i: usize, include_subtrees: bool) Error!void {
        const node = self.iterators.items[i].node;
        assert(node.link_count > 0 and node.link_count <= max_link_count);
        var j: u16 = 1;
        while (j <= node.link_count) : (j += 1) {
            var index = i;
            var link = node.links[0];
            if (j != node.link_count) {
                if (self.iterators.items.len >= max_iterator_count) continue;
                link = node.links[j];
                var copy = self.iterators.items[i];
                copy.subtrees = try copy.subtrees.clone(self.arena);
                try self.iterators.append(self.arena, copy);
                index = self.iterators.items.len - 1;
            }
            const next = &self.iterators.items[index];
            next.node = link.node.?;
            if (link.subtree) |t| {
                if (include_subtrees) try next.subtrees.append(self.arena, t);
                if (!t.extra) {
                    next.subtree_count += 1;
                    if (!link.is_pending) next.is_pending = false;
                }
            } else {
                next.subtree_count += 1;
                next.is_pending = false;
            }
        }
        assert(j == node.link_count + 1);
    }

    fn addSlice(self: *Stack, original: Version, node: *Node, subtrees: SubtreeList) Error!void {
        assert(node.link_count <= max_link_count);
        var i = self.slices.items.len;
        while (i > 0) {
            i -= 1;
            const v = self.slices.items[i].version;
            if (self.head(v).node == node) {
                try self.slices.insert(self.arena, i + 1, .{ .subtrees = subtrees, .version = v });
                return;
            }
        }
        const v = try self.addVersion(original, node);
        try self.slices.append(self.arena, .{ .subtrees = subtrees, .version = v });
        assert(self.slices.items.len > 0);
    }

    fn addVersion(self: *Stack, original: Version, node: *Node) Error!Version {
        assert(node.position.bytes <= limits.max_source_bytes);
        const o = self.head(original);
        if (self.heads.items.len == max_heads) return error.TooManyVersions;
        try self.heads.append(self.arena, .{
            .node = node,
            .node_count_at_last_error = o.node_count_at_last_error,
            .last_external_token = o.last_external_token,
        });
        assert(self.heads.items.len <= max_heads);
        return @intCast(self.heads.items.len - 1);
    }

    pub fn hasAdvancedSinceError(self: *const Stack, version: Version) bool {
        assert(version < self.heads.items.len);
        const h = self.head(version);
        var node = h.node;
        if (node.error_cost == 0) return true;
        var steps: usize = 0;
        while (steps < self.node_total) : (steps += 1) {
            if (node.link_count == 0) break;
            const t = node.links[0].subtree orelse break;
            if (t.totalSize().bytes > 0) return true;
            if (node.node_count > h.node_count_at_last_error and t.errorCost() == 0) {
                node = node.links[0].node.?;
                continue;
            }
            break;
        }
        assert(steps <= self.node_total);
        return false;
    }

    pub fn removeVersion(self: *Stack, version: Version) void {
        assert(version < self.heads.items.len);
        const removed = self.heads.orderedRemove(version);
        assert(removed.node.position.bytes <= std.math.maxInt(u32));
    }

    pub fn renumberVersion(self: *Stack, v1: Version, v2: Version) void {
        if (v1 == v2) return;
        assert(v2 < v1);
        assert(v1 < self.heads.items.len);
        const source = &self.heads.items[v1];
        const target = &self.heads.items[v2];
        if (target.summary != null and source.summary == null) {
            source.summary = target.summary;
            target.summary = null;
        }
        target.* = source.*;
        const removed = self.heads.orderedRemove(v1);
        assert(removed.node == target.node);
    }

    pub fn swapVersions(self: *Stack, v1: Version, v2: Version) void {
        assert(v1 < self.heads.items.len);
        assert(v2 < self.heads.items.len);
        std.mem.swap(Head, &self.heads.items[v1], &self.heads.items[v2]);
    }

    pub fn copyVersion(self: *Stack, version: Version) Error!Version {
        assert(self.heads.items[version].node.link_count <= max_link_count);
        assert(version < self.heads.items.len);
        if (self.heads.items.len == max_heads) return error.TooManyVersions;
        var copy = self.heads.items[version];
        copy.summary = null;
        try self.heads.append(self.arena, copy);
        return @intCast(self.heads.items.len - 1);
    }

    pub fn canMerge(self: *const Stack, v1: Version, v2: Version) bool {
        assert(v1 != v2);
        assert(v1 < self.heads.items.len and v2 < self.heads.items.len);
        const h1 = self.head(v1);
        const h2 = self.head(v2);
        return h1.status == .active and h2.status == .active and
            h1.node.state == h2.node.state and
            h1.node.position.bytes == h2.node.position.bytes and
            h1.node.error_cost == h2.node.error_cost and
            st.externalStateEq(h1.last_external_token, h2.last_external_token);
    }

    pub fn merge(self: *Stack, v1: Version, v2: Version) Error!bool {
        assert(v1 < self.heads.items.len and v2 < self.heads.items.len);
        if (!self.canMerge(v1, v2)) return false;
        const h1 = self.head(v1);
        const n2 = self.head(v2).node;
        assert(v1 != v2);
        for (n2.links[0..n2.link_count]) |link| try self.addLink(h1.node, link);
        if (h1.node.state == 0) h1.node_count_at_last_error = h1.node.node_count;
        self.removeVersion(v2);
        return true;
    }

    /// Add `link` to `target` (`stack_node_add_link`). A merge of two
    /// equivalent predecessors pushes a frame in place of a recursive call.
    fn addLink(self: *Stack, target: *Node, link: Link) Error!void {
        assert(self.frames.items.len == 0);
        defer self.frames.clearRetainingCapacity();
        if (linkOrMerge(target, link)) |frame| try self.frames.append(self.arena, frame);
        var steps: usize = 0;
        while (self.frames.items.len > 0) : (steps += 1) {
            if (steps > limits.max_stack_nodes) return error.StackTooDeep;
            const f = &self.frames.items[self.frames.items.len - 1];
            if (f.next < f.source.link_count) {
                const l = f.source.links[f.next];
                f.next += 1;
                if (linkOrMerge(f.into, l)) |frame| try self.frames.append(self.arena, frame);
                continue;
            }
            const dp = f.source.dynamic_precedence + dynPrec(f.link_subtree);
            if (dp > f.parent.dynamic_precedence) f.parent.dynamic_precedence = dp;
            self.frames.items.len -= 1;
        }
        assert(self.frames.items.len == 0);
    }

    /// The body of `stack_node_add_link` before its recursive call. Return a
    /// frame when the predecessors merge.
    fn linkOrMerge(target: *Node, link: Link) ?MergeFrame {
        assert(link.node != null);
        const link_node = link.node.?;
        if (link_node == target) return null;
        assert(target.link_count <= max_link_count);
        for (target.links[0..target.link_count]) |*existing| {
            if (!isEquivalent(existing.subtree, link.subtree)) continue;
            const existing_node = existing.node.?;
            if (existing_node == link_node) {
                if (dynPrec(link.subtree) > dynPrec(existing.subtree)) {
                    existing.subtree = link.subtree;
                    target.dynamic_precedence = link_node.dynamic_precedence + dynPrec(link.subtree);
                }
                return null;
            }
            if (existing_node.state == link_node.state and
                existing_node.position.bytes == link_node.position.bytes and
                existing_node.error_cost == link_node.error_cost)
            {
                return .{ .parent = target, .into = existing_node, .source = link_node, .link_subtree = link.subtree };
            }
        }
        if (target.link_count == max_link_count) return null;
        appendLink(target, link);
        return null;
    }

    pub fn halt(self: *Stack, version: Version) void {
        assert(version < self.heads.items.len);
        assert(self.heads.items[version].node.link_count <= max_link_count);
        self.head(version).status = .halted;
    }

    pub fn pause(self: *Stack, version: Version, lookahead: ?*const Subtree) void {
        assert(version < self.heads.items.len);
        assert(self.heads.items[version].node.link_count <= max_link_count);
        const h = self.head(version);
        h.status = .paused;
        h.lookahead_when_paused = lookahead;
        h.node_count_at_last_error = h.node.node_count;
    }

    pub fn isActive(self: *const Stack, version: Version) bool {
        assert(version < self.heads.items.len);
        assert(self.heads.items[version].node.link_count <= max_link_count);
        return self.head(version).status == .active;
    }

    pub fn isPaused(self: *const Stack, version: Version) bool {
        assert(version < self.heads.items.len);
        assert(self.heads.items[version].node.link_count <= max_link_count);
        return self.head(version).status == .paused;
    }

    pub fn isHalted(self: *const Stack, version: Version) bool {
        assert(version < self.heads.items.len);
        assert(self.heads.items[version].node.link_count <= max_link_count);
        return self.head(version).status == .halted;
    }

    pub fn @"resume"(self: *Stack, version: Version) ?*const Subtree {
        const h = self.head(version);
        assert(h.status == .paused);
        const result = h.lookahead_when_paused;
        h.status = .active;
        h.lookahead_when_paused = null;
        return result;
    }
};

/// Append `link` to `target` and update its counts (end of `stack_node_add_link`).
fn appendLink(target: *Node, link: Link) void {
    assert(target.link_count < max_link_count);
    const link_node = link.node.?;
    var node_count = link_node.node_count;
    var dynamic_precedence = link_node.dynamic_precedence;
    target.links[target.link_count] = link;
    target.link_count += 1;
    if (link.subtree) |t| {
        node_count += subtreeNodeCount(t);
        dynamic_precedence += t.dynamicPrecedence();
    }
    if (node_count > target.node_count) target.node_count = node_count;
    if (dynamic_precedence > target.dynamic_precedence) target.dynamic_precedence = dynamic_precedence;
    assert(target.link_count <= max_link_count);
}
