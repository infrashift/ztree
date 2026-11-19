//! Query execution (ISSUE-014, ADR-0012). The cursor ports
//! `ts_query_cursor__advance` and `ts_query_cursor_next_match` of the
//! vendored `query.c` to the flat tree. The reference cursor also enters
//! hidden nodes, but it changes its states only on visible nodes, so a walk
//! over the flat records gives the same events. The text predicates follow
//! `SatisfiesTextPredicate` of go-tree-sitter.

const std = @import("std");
const assert = std.debug.assert;
const flat = @import("flat.zig");
const query = @import("query.zig");
const blob_mod = @import("query_blob.zig");
const predicates = @import("query_predicates.zig");
const regex = @import("regex.zig");

const Step = query.Step;
const none16 = query.none;
const none32 = flat.none;

/// The most in-progress states, and the most capture lists, of one execution.
pub const max_states: usize = 1 << 16;
pub const max_capture_lists: usize = 1 << 16;
/// The most captures of one match.
pub const max_match_captures: usize = 1 << 16;

pub const Error = error{ OutOfMemory, LimitReached };

/// One capture (`TSQueryCapture`): a node index and a capture id.
pub const Capture = extern struct { node: u32, index: u32 };
/// One match: its pattern and the number of its captures.
pub const Match = extern struct { pattern_index: u32, capture_count: u32 };

/// `QueryState`. The capture lists live in a pool, as in the reference.
const State = struct {
    capture_list: u32 = none32,
    /// A `uint16_t` in the reference, which wraps for a pattern that starts
    /// at its DONE step (an empty match of `[...]*`).
    start_depth: u16,
    step_index: u16,
    pattern_index: u16,
    seeking_immediate_match: bool = true,
    has_in_progress_alternatives: bool = false,
    dead: bool = false,
    needs_parent: bool = false,
    skipped_quantifier: bool = false,
};

/// The status of the current node (`ts_tree_cursor_current_status`).
const Status = struct {
    field_id: u16 = 0,
    has_later_siblings: bool = false,
    has_later_named_siblings: bool = false,
    can_have_later_siblings_with_this_field: bool = false,
};

/// The input of one execution.
pub const Input = struct {
    view: *const blob_mod.View,
    nodes: []const flat.Node,
    overrides: []const flat.FieldOverride,
    text: []const u8,
    start: u32,
};

/// The query cursor over a flat tree.
pub const Cursor = struct {
    arena: std.mem.Allocator,
    in: Input,
    steps: []const Step,
    pattern_map: []const query.PatternEntry,
    negated: []const u16,
    states: std.ArrayList(State) = .empty,
    finished: std.ArrayList(State) = .empty,
    lists: std.ArrayList(std.ArrayList(Capture)) = .empty,
    in_use: std.ArrayList(bool) = .empty,
    free_ids: std.ArrayList(u32) = .empty,
    /// Bit 0: a later sibling. Bit 1: a later named sibling.
    later: []u8,
    depth: u32 = 0,

    pub fn init(arena: std.mem.Allocator, in: Input) Error!Cursor {
        const n = in.nodes.len;
        assert(in.start < n);
        const later = try arena.alloc(u8, n);
        var i = n;
        while (i > 0) {
            i -= 1;
            const next = in.nodes[i].next_sibling;
            later[i] = 0;
            if (next == none32) continue;
            assert(next > i);
            later[i] = 1;
            if (in.nodes[next].isNamed() or later[next] & 2 != 0) later[i] |= 2;
        }
        const v = in.view;
        return .{ .arena = arena, .in = in, .steps = v.get(.steps), .pattern_map = v.get(.pattern_map), .negated = v.get(.negated_fields), .later = later };
    }

    fn status(self: *const Cursor, node: u32) Status {
        assert(self.later.len == self.in.nodes.len);
        assert(node < self.in.nodes.len);
        if (node == self.in.start) return .{};
        const r = self.in.nodes[node];
        return .{
            .field_id = r.status_field_id,
            .has_later_siblings = self.later[node] & 1 != 0,
            .has_later_named_siblings = self.later[node] & 2 != 0,
            .can_have_later_siblings_with_this_field = r.flags & flat.flag_later_field != 0,
        };
    }

    /// The parent of `node` inside the walk (`ts_tree_cursor_parent_node`).
    fn parentOf(self: *const Cursor, node: u32) u32 {
        assert(node < self.in.nodes.len);
        if (node == self.in.start) return none32;
        assert(self.in.nodes[node].parent != none32);
        return self.in.nodes[node].parent;
    }

    /// `ts_node_child_by_field_id`: an override, else the first child in the field.
    fn childByField(self: *const Cursor, node: u32, field_id: u16) u32 {
        const ov = self.in.overrides;
        assert(field_id != 0);
        var lo: usize = 0;
        var hi: usize = ov.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (ov[mid].node < node) lo = mid + 1 else hi = mid;
        }
        while (lo < ov.len and ov[lo].node == node) : (lo += 1) {
            if (ov[lo].field_id == field_id) return ov[lo].child;
        }
        const r = self.in.nodes[node];
        if (r.child_count == 0) return none32;
        var c: u32 = node + 1;
        var steps: usize = 0;
        while (c != none32) : (c = self.in.nodes[c].next_sibling) {
            steps += 1;
            assert(steps <= r.child_count);
            if (self.in.nodes[c].field_id == field_id) return c;
        }
        return none32;
    }

    // ----- Capture lists (`CaptureListPool`) -----

    fn acquire(self: *Cursor) Error!u32 {
        assert(self.lists.items.len == self.in_use.items.len);
        if (self.free_ids.pop()) |id| {
            self.lists.items[id].clearRetainingCapacity();
            self.in_use.items[id] = true;
            return id;
        }
        if (self.lists.items.len >= max_capture_lists) return error.LimitReached;
        try self.lists.append(self.arena, .empty);
        try self.in_use.append(self.arena, true);
        assert(self.lists.items.len == self.in_use.items.len);
        return @intCast(self.lists.items.len - 1);
    }

    fn release(self: *Cursor, id: u32) Error!void {
        assert(self.lists.items.len == self.in_use.items.len);
        if (id >= self.lists.items.len or !self.in_use.items[id]) return;
        self.in_use.items[id] = false;
        try self.free_ids.append(self.arena, id);
        assert(self.free_ids.items.len <= self.lists.items.len);
    }

    fn captures(self: *const Cursor, id: u32) []const Capture {
        assert(id == none32 or id < max_capture_lists);
        if (id >= self.lists.items.len) return &.{};
        assert(self.lists.items.len == self.in_use.items.len);
        return self.lists.items[id].items;
    }

    // ----- States -----

    /// `ts_query_cursor__add_state`: keep the states sorted by start depth and pattern.
    fn addState(self: *Cursor, entry: query.PatternEntry) Error!void {
        const step = self.steps[entry.step_index];
        // The reference compares the `uint32_t` difference and stores it as `uint16_t`.
        const start_depth: u32 = self.depth -% step.depth;
        assert(entry.pattern_index != none16);
        var index = self.states.items.len;
        while (index > 0) : (index -= 1) {
            const prev = self.states.items[index - 1];
            if (prev.start_depth < start_depth) break;
            if (prev.start_depth == start_depth) {
                if (prev.pattern_index == entry.pattern_index and prev.step_index == entry.step_index) return;
                if (prev.pattern_index <= entry.pattern_index) break;
            }
        }
        if (self.states.items.len >= max_states) return error.LimitReached;
        try self.states.insert(self.arena, index, .{ .step_index = entry.step_index, .pattern_index = entry.pattern_index, .start_depth = @truncate(start_depth), .needs_parent = step.depth == 1 });
        assert(self.states.items.len <= max_states);
    }

    /// `ts_query_cursor__copy_state`: a copy after `index`, with its own capture list.
    fn copyState(self: *Cursor, index: usize) Error!void {
        assert(index < self.states.items.len);
        var copy = self.states.items[index];
        copy.capture_list = none32;
        if (self.states.items[index].capture_list != none32) {
            copy.capture_list = try self.acquire();
            const src = self.states.items[index].capture_list;
            try self.lists.items[copy.capture_list].appendSlice(self.arena, self.lists.items[src].items);
        }
        if (self.states.items.len >= max_states) return error.LimitReached;
        try self.states.insert(self.arena, index + 1, copy);
        assert(self.states.items.len <= max_states);
    }

    /// `ts_query_cursor__capture`.
    fn capture(self: *Cursor, index: usize, step: Step, node: u32) Error!void {
        assert(index < self.states.items.len);
        const state = &self.states.items[index];
        if (state.dead) return;
        if (state.capture_list == none32) state.capture_list = try self.acquire();
        const list = &self.lists.items[state.capture_list];
        for (step.capture_ids) |id| {
            if (id == none16) break;
            if (list.items.len >= max_match_captures) return error.LimitReached;
            try list.append(self.arena, .{ .node = node, .index = id });
        }
        assert(node < self.in.nodes.len);
    }

    fn eraseState(self: *Cursor, index: usize) Error!void {
        assert(self.states.items.len <= max_states);
        assert(index < self.states.items.len);
        try self.release(self.states.items[index].capture_list);
        _ = self.states.orderedRemove(index); // nasa-lint: allow(R7) the state is released above
    }

    fn pushFinished(self: *Cursor, state: State) Error!void {
        assert(state.pattern_index < self.in.view.get(.patterns).len);
        assert(self.steps[state.step_index].depth == none16);
        if (self.finished.items.len >= max_states * 16) return error.LimitReached;
        try self.finished.append(self.arena, state);
    }

    /// `ts_query__step_is_fallible`.
    fn isFallible(self: *const Cursor, step_index: u16) bool {
        assert(self.steps[step_index].depth != none16);
        assert(step_index + 1 < self.steps.len);
        const step = self.steps[step_index];
        const next = self.steps[step_index + 1];
        return next.depth != none16 and next.depth > step.depth and !next.flags.parent_pattern_guaranteed;
    }

    // ----- Leaving a node -----

    /// Remove the states that cannot make progress after leaving a node at `depth`.
    fn leave(self: *Cursor) Error!void {
        assert(self.states.items.len <= max_states);
        var kept: usize = 0;
        const depth = self.depth;
        for (self.states.items) |state| {
            const step = self.steps[state.step_index];
            if (step.depth == none16 and (state.start_depth > depth or depth == 0)) {
                try self.pushFinished(state);
            } else if (step.depth != none16 and @as(u32, state.start_depth) + step.depth > depth) {
                try self.release(state.capture_list);
            } else {
                self.states.items[kept] = state;
                kept += 1;
            }
        }
        self.states.items.len = kept;
        assert(kept <= max_states);
    }

    // ----- Entering a node -----

    fn enter(self: *Cursor, node: u32) Error!void {
        assert(node < self.in.nodes.len);
        const r = self.in.nodes[node];
        const st = self.status(node);
        const parent = self.parentOf(node);
        const node_is_error = r.symbol == @import("abi.zig").builtin_sym_error;
        const parent_is_error = parent != none32 and self.in.nodes[parent].symbol == @import("abi.zig").builtin_sym_error;
        try self.startPatterns(r.symbol, st, node_is_error, parent_is_error);
        try self.updateStates(node, st, node_is_error);
        try self.finishStates();
        assert(self.states.items.len <= max_states);
    }

    /// Add new states for the patterns whose root matches this node.
    fn startPatterns(self: *Cursor, symbol: u16, st: Status, node_is_error: bool, parent_is_error: bool) Error!void {
        const wildcard_count = self.in.view.header.wildcard_root_pattern_count;
        assert(wildcard_count <= self.pattern_map.len);
        if (!node_is_error) {
            for (self.pattern_map[0..wildcard_count]) |entry| {
                const step = self.steps[entry.step_index];
                if ((entry.is_rooted != 0 or !parent_is_error) and (step.field == 0 or st.field_id == step.field) and step.supertype_symbol == 0) try self.addState(entry);
            }
        }
        var i = self.searchPatternMap(symbol) orelse return;
        var steps: usize = 0;
        while (i < self.pattern_map.len) : (i += 1) {
            steps += 1;
            assert(steps <= self.pattern_map.len);
            const entry = self.pattern_map[i];
            const step = self.steps[entry.step_index];
            if (step.symbol != symbol) break;
            if ((entry.is_rooted != 0 or !parent_is_error) and (step.field == 0 or st.field_id == step.field)) try self.addState(entry);
        }
    }

    /// `ts_query__pattern_map_search`: the first entry for `needle`, or null.
    fn searchPatternMap(self: *const Cursor, needle: u16) ?usize {
        assert(self.steps.len > 0 or self.pattern_map.len == 0);
        const map = self.pattern_map;
        var base: usize = self.in.view.header.wildcard_root_pattern_count;
        assert(base <= map.len);
        if (base == map.len) return null;
        var size = map.len - base;
        while (size > 1) {
            const half = size / 2;
            if (needle > self.steps[map[base + half].step_index].symbol) base += half;
            size -= half;
        }
        var symbol = self.steps[map[base].step_index].symbol;
        if (needle > symbol) {
            base += 1;
            if (base < map.len) symbol = self.steps[map[base].step_index].symbol;
        }
        return if (needle == symbol and base < map.len) base else null;
    }

    /// True when the node matches the step of the state, and whether a later sibling can match it.
    fn stepMatches(self: *const Cursor, node: u32, state: State, step: Step, st: Status, node_is_error: bool) struct { bool, bool } {
        assert(node < self.in.nodes.len);
        const r = self.in.nodes[node];
        const is_named = r.isNamed();
        const is_missing = r.flags & flat.flag_missing != 0;
        var does_match = if (step.symbol == query.wildcard)
            (if (step.flags.is_missing) is_missing else !node_is_error and (is_named or !step.flags.is_named))
        else
            r.symbol == step.symbol and (!step.flags.is_missing or is_missing);
        var later = st.has_later_siblings;
        if ((step.flags.is_immediate and is_named and !state.skipped_quantifier) or state.seeking_immediate_match) later = false;
        if (step.flags.is_last_child and st.has_later_named_siblings) does_match = false;
        if (step.field != 0) {
            if (step.field == st.field_id) {
                if (!st.can_have_later_siblings_with_this_field) later = false;
            } else does_match = false;
        }
        if (step.negated_field_list_id != 0) {
            for (self.negated[step.negated_field_list_id..]) |field_id| {
                if (field_id == 0) break;
                if (self.childByField(node, field_id) != none32) {
                    does_match = false;
                    break;
                }
            }
        }
        assert(step.depth != none16);
        return .{ does_match, later };
    }

    /// Advance each in-progress state over the current node.
    fn updateStates(self: *Cursor, node: u32, st: Status, node_is_error: bool) Error!void {
        assert(node < self.in.nodes.len);
        var j: usize = 0;
        var rounds: usize = 0;
        while (j < self.states.items.len) {
            rounds += 1;
            assert(rounds <= max_states * 4);
            const added = try self.updateState(j, node, st, node_is_error);
            j = if (added) |copies| j + 1 + copies else j;
        }
    }

    /// Update the state at `j`. Return the number of copies after it, or
    /// null when the state was removed.
    fn updateState(self: *Cursor, j: usize, node: u32, st: Status, node_is_error: bool) Error!?usize {
        assert(j < self.states.items.len);
        var copy_count: usize = 0;
        self.states.items[j].has_in_progress_alternatives = false;
        const state = self.states.items[j];
        const step = self.steps[state.step_index];
        if (@as(u32, state.start_depth) + step.depth != self.depth) return 0;
        const does_match, const later = self.stepMatches(node, state, step, st, node_is_error);
        if (!does_match) {
            if (later) return 0;
            try self.eraseState(j);
            return null;
        }
        if (later and (step.flags.contains_captures or self.isFallible(state.step_index))) {
            try self.copyState(j);
            copy_count += 1;
        }
        if (state.needs_parent) try self.captureParent(j, node, state.step_index);
        if (step.capture_ids[0] != none16) try self.capture(j, step, node);
        if (self.states.items[j].dead) {
            try self.eraseState(j);
            return null;
        }
        const s = &self.states.items[j];
        s.step_index += 1;
        const next_step = self.steps[s.step_index];
        s.seeking_immediate_match = step.symbol == query.wildcard and !step.flags.is_named and next_step.flags.is_immediate;
        s.skipped_quantifier = false;
        copy_count += try self.splitAlternatives(j, st);
        assert(copy_count <= max_states);
        return copy_count;
    }

    /// A pattern that starts with a wildcard starts at its second step: check
    /// that the node has a parent, and capture the parent when the wildcard has captures.
    fn captureParent(self: *Cursor, j: usize, node: u32, step_index: u16) Error!void {
        assert(j < self.states.items.len);
        const parent = self.parentOf(node);
        assert(step_index > 0);
        if (parent == none32) {
            self.states.items[j].dead = true;
            return;
        }
        self.states.items[j].needs_parent = false;
        var k: usize = step_index;
        var guard: usize = 0;
        while (guard <= self.steps.len) : (guard += 1) {
            k -= 1;
            const s = self.steps[k];
            if (!(s.flags.is_dead_end or s.flags.is_pass_through or s.depth > 0)) break;
        }
        if (self.steps[k].capture_ids[0] != none16) try self.capture(j, self.steps[k], parent);
    }

    /// Split the state at `j` for the alternatives of its next step. Return the number of copies.
    fn splitAlternatives(self: *Cursor, j: usize, st: Status) Error!usize {
        assert(j < self.states.items.len);
        var copies: usize = 0;
        var end_index = j + 1;
        var k = j;
        var guard: usize = 0;
        while (k < end_index) : (guard += 1) {
            assert(guard <= max_states * 4);
            const child_step = self.steps[self.states.items[k].step_index];
            if (child_step.alternative_index == none16) {
                k += 1;
                continue;
            }
            if (child_step.flags.is_dead_end) {
                self.states.items[k].step_index = child_step.alternative_index;
                continue;
            }
            const pass_through = child_step.flags.is_pass_through;
            if (pass_through) self.states.items[k].step_index += 1;
            const skip = child_step.flags.alternative_is_skip and child_step.flags.is_last_child and st.has_later_named_siblings;
            if (!skip) {
                try self.copyState(k);
                end_index += 1;
                copies += 1;
                const copy = &self.states.items[k + 1];
                copy.step_index = child_step.alternative_index;
                if (pass_through) copy.seeking_immediate_match = true;
                if (child_step.flags.alternative_is_skip) self.skipAnchor(k, child_step);
            }
            // A pass-through step stays at the same index, so it runs again at its next step.
            if (!pass_through) k += 1;
        }
        return copies;
    }

    /// The anchor rules of a `?` or `*` zero-skip, for the copy at `k + 1`.
    fn skipAnchor(self: *Cursor, k: usize, child_step: Step) void {
        assert(k + 1 < self.states.items.len);
        const copy = &self.states.items[k + 1];
        assert(child_step.flags.alternative_is_skip);
        if (!child_step.flags.is_immediate) {
            copy.skipped_quantifier = self.steps[child_step.alternative_index].depth == child_step.depth;
        } else if (self.steps[self.states.items[k].step_index - 1].depth < child_step.depth) {
            copy.seeking_immediate_match = true;
        }
    }

    // ----- Longest match and finished states -----

    fn startByte(self: *const Cursor, c: Capture) u32 {
        assert(c.index != none16);
        assert(c.node < self.in.nodes.len);
        return self.in.nodes[c.node].start_byte;
    }

    /// `ts_query_cursor__state_precedes`.
    fn precedes(self: *const Cursor, a: State, b: State) bool {
        assert(a.step_index < self.steps.len and b.step_index < self.steps.len);
        if (a.start_depth != b.start_depth) return a.start_depth < b.start_depth;
        if (a.pattern_index != b.pattern_index) return a.pattern_index < b.pattern_index;
        const a_caps = self.captures(a.capture_list);
        const b_caps = self.captures(b.capture_list);
        if ((a_caps.len == 0) != (b_caps.len == 0)) return a_caps.len == 0;
        if (a_caps.len == 0) return false;
        assert(b_caps.len > 0);
        return self.startByte(a_caps[0]) < self.startByte(b_caps[0]);
    }

    /// `ts_query_cursor__sort_states_by_capture`: a stable insertion sort.
    fn sortStates(self: *Cursor) void {
        assert(self.states.items.len <= max_states);
        const items = self.states.items;
        assert(items.len <= max_states);
        if (items.len < 2) return;
        for (1..items.len) |i| {
            if (!self.precedes(items[i], items[i - 1])) continue;
            const key = items[i];
            var j = i;
            while (j > 0 and self.precedes(key, items[j - 1])) : (j -= 1) items[j] = items[j - 1];
            items[j] = key;
        }
    }

    /// `ts_query_cursor__compare_nodes`.
    fn compareNodes(self: *const Cursor, left: u32, right: u32) i32 {
        assert(left < self.in.nodes.len and right < self.in.nodes.len);
        if (left == right) return 0;
        const l = self.in.nodes[left];
        const r = self.in.nodes[right];
        assert(l.start_byte <= l.end_byte and r.start_byte <= r.end_byte);
        if (l.start_byte != r.start_byte) return if (l.start_byte < r.start_byte) -1 else 1;
        if (l.end_byte != r.end_byte) return if (l.end_byte > r.end_byte) -1 else 1;
        return 0;
    }

    /// `ts_query_cursor__compare_captures`: left contains right, right contains left.
    fn compareCaptures(self: *const Cursor, left: State, right: State) struct { bool, bool } {
        assert(left.step_index < self.steps.len and right.step_index < self.steps.len);
        const lc = self.captures(left.capture_list);
        const rc = self.captures(right.capture_list);
        var l_contains_r = true;
        var r_contains_l = true;
        var i: usize = 0;
        var j: usize = 0;
        while (i < lc.len and j < rc.len) {
            if (lc[i].node == rc[j].node and lc[i].index == rc[j].index) {
                i += 1;
                j += 1;
                continue;
            }
            switch (self.compareNodes(lc[i].node, rc[j].node)) {
                -1 => {
                    r_contains_l = false;
                    i += 1;
                },
                1 => {
                    l_contains_r = false;
                    j += 1;
                },
                else => {
                    r_contains_l = false;
                    l_contains_r = false;
                    i += 1;
                    j += 1;
                },
            }
        }
        if (i < lc.len) r_contains_l = false;
        if (i >= lc.len and j < rc.len) l_contains_r = false;
        assert(i <= lc.len and j <= rc.len);
        return .{ l_contains_r, r_contains_l };
    }

    /// Drop the shorter of two states with the same captures (the longest-match
    /// rule), then finish each state at the end of its pattern.
    fn finishStates(self: *Cursor) Error!void {
        assert(self.states.items.len <= max_states);
        self.sortStates();
        var j: usize = 0;
        var guard: usize = 0;
        while (j < self.states.items.len) : (guard += 1) {
            assert(guard <= max_states * 2);
            if (self.states.items[j].dead) {
                _ = self.states.orderedRemove(j); // nasa-lint: allow(R7) a dead state has no capture list
                continue;
            }
            if (try self.dedup(j)) continue;
            const state = self.states.items[j];
            if (self.steps[state.step_index].depth == none16 and !state.has_in_progress_alternatives) {
                try self.pushFinished(state);
                _ = self.states.orderedRemove(j); // nasa-lint: allow(R7) the finished list owns the capture list
                continue;
            }
            j += 1;
        }
    }

    /// Compare the state at `j` with the later states of its group. Return
    /// true when the state at `j` was removed.
    fn dedup(self: *Cursor, j: usize) Error!bool {
        assert(j < self.states.items.len);
        var k = j + 1;
        var guard: usize = 0;
        while (k < self.states.items.len) : (guard += 1) {
            assert(guard <= max_states);
            const state = self.states.items[j];
            const other = self.states.items[k];
            if (other.start_depth != state.start_depth or other.pattern_index != state.pattern_index) break;
            const sc = self.captures(state.capture_list);
            const oc = self.captures(other.capture_list);
            if (sc.len > 0 and oc.len > 0 and self.startByte(oc[0]) >= self.in.nodes[sc[sc.len - 1].node].end_byte) break;
            const l_contains_r, const r_contains_l = self.compareCaptures(state, other);
            if (l_contains_r) {
                if (state.step_index == other.step_index and (other.seeking_immediate_match or !state.seeking_immediate_match)) {
                    try self.eraseState(k);
                    continue;
                }
                self.states.items[k].has_in_progress_alternatives = true;
            }
            if (r_contains_l) {
                if (state.step_index == other.step_index and (state.seeking_immediate_match or !other.seeking_immediate_match)) {
                    try self.eraseState(j);
                    return true;
                }
                self.states.items[j].has_in_progress_alternatives = true;
            }
            k += 1;
        }
        return false;
    }

    // ----- The walk -----

    /// Walk the tree from the start node and collect the finished states in
    /// the order of `ts_query_cursor_next_match`.
    pub fn run(self: *Cursor) Error!void {
        assert(self.in.start < self.in.nodes.len);
        var node = self.in.start;
        var ascending = false;
        var steps: usize = 0;
        while (steps <= self.in.nodes.len * 2) : (steps += 1) {
            if (!ascending) {
                try self.enter(node);
                if (self.in.nodes[node].child_count > 0) {
                    node += 1;
                    self.depth += 1;
                    continue;
                }
                ascending = true;
                continue;
            }
            try self.leave();
            if (node == self.in.start) break;
            const next = self.in.nodes[node].next_sibling;
            if (next != none32) {
                node = next;
                ascending = false;
            } else {
                node = self.in.nodes[node].parent;
                self.depth -= 1;
            }
        }
        // The halt drops each state that did not finish.
        for (self.states.items) |s| try self.release(s.capture_list);
        self.states.clearRetainingCapacity();
        assert(self.depth == 0);
    }

    // ----- Text predicates -----

    fn nodeText(self: *const Cursor, node: u32) []const u8 {
        const r = self.in.nodes[node];
        assert(r.end_byte <= self.in.text.len);
        assert(r.start_byte <= r.end_byte);
        return self.in.text[r.start_byte..r.end_byte];
    }

    /// `SatisfiesTextPredicate` of go-tree-sitter for one match.
    pub fn satisfies(self: *const Cursor, pattern_index: u16, caps: []const Capture, scratch: []u32) bool {
        assert(pattern_index < self.in.view.get(.pattern_text_predicates).len);
        const per_pattern = self.in.view.get(.pattern_text_predicates)[pattern_index];
        const preds = self.in.view.get(.text_predicates)[per_pattern.offset..][0..per_pattern.length];
        assert(per_pattern.offset + per_pattern.length <= self.in.view.get(.text_predicates).len);
        for (preds) |p| {
            if (!self.predicateHolds(p, caps, scratch)) return false;
        }
        return true;
    }

    fn predicateHolds(self: *const Cursor, p: predicates.TextPredicate, caps: []const Capture, scratch: []u32) bool {
        assert(p.capture_id < self.in.view.header.capture_count);
        const positive = p.positive != 0;
        const match_all = p.match_all != 0;
        assert(p.op != .any_of or match_all);
        if (p.op == .eq and p.value_is_capture != 0) return self.eqCaptures(p, caps);
        for (caps) |c| {
            if (c.index != p.capture_id) continue;
            const text = self.nodeText(c.node);
            const hit = switch (p.op) {
                .eq => std.mem.eql(u8, text, self.in.view.stringValue(p.value)),
                .match => regex.isMatch(self.in.view.program(p.value), text, scratch),
                .any_of => self.anyOf(p, text),
            };
            if (hit != positive and match_all) return false;
            if (hit == positive and !match_all) return true;
        }
        return true;
    }

    fn anyOf(self: *const Cursor, p: predicates.TextPredicate, text: []const u8) bool {
        assert(p.value + p.count <= self.in.view.get(.any_of_values).len);
        const values = self.in.view.get(.any_of_values)[p.value..][0..p.count];
        assert(p.op == .any_of);
        for (values) |id| if (std.mem.eql(u8, text, self.in.view.stringValue(id))) return true;
        return false;
    }

    /// `#eq?` with two captures: compare the nodes of the captures in pairs.
    fn eqCaptures(self: *const Cursor, p: predicates.TextPredicate, caps: []const Capture) bool {
        assert(p.value < self.in.view.header.capture_count);
        const positive = p.positive != 0;
        const match_all = p.match_all != 0;
        assert(p.value_is_capture != 0);
        var i: usize = 0;
        var j: usize = 0;
        var guard: usize = 0;
        while (guard <= caps.len * 2) : (guard += 1) {
            while (i < caps.len and caps[i].index != p.capture_id) i += 1;
            while (j < caps.len and caps[j].index != p.value) j += 1;
            if (i >= caps.len or j >= caps.len) break;
            const hit = std.mem.eql(u8, self.nodeText(caps[i].node), self.nodeText(caps[j].node));
            if (hit != positive and match_all) return false;
            if (hit == positive and !match_all) return true;
            i += 1;
            j += 1;
        }
        // Both capture lists must end together.
        while (i < caps.len and caps[i].index != p.capture_id) i += 1;
        while (j < caps.len and caps[j].index != p.value) j += 1;
        return i >= caps.len and j >= caps.len;
    }
};

/// True when a flat tree from caller memory is safe to walk: the links
/// point inside the tree in pre-order, each child chain has the child
/// count of its parent, each byte range is inside the text, and the
/// overrides are sorted by node.
pub fn validTree(nodes: []const flat.Node, overrides: []const flat.FieldOverride, text_len: usize) bool {
    assert(text_len <= std.math.maxInt(u32));
    const n = nodes.len;
    if (n == 0 or n >= none32 or nodes[0].parent != none32) return false;
    for (nodes, 0..) |r, i| {
        if (r.start_byte > r.end_byte or r.end_byte > text_len) return false;
        if (i > 0 and r.parent >= i) return false;
        if (r.next_sibling != none32 and (r.next_sibling <= i or r.next_sibling >= n or nodes[r.next_sibling].parent != r.parent)) return false;
        if (r.child_count == 0) continue;
        var c: usize = i + 1;
        var k: u32 = 0;
        while (c != none32 and k <= r.child_count) : (k += 1) {
            if (c >= n or nodes[c].parent != i) return false;
            c = nodes[c].next_sibling;
        }
        if (k != r.child_count or c != none32) return false;
    }
    var prev: u32 = 0;
    for (overrides) |o| {
        if (o.node >= n or o.node < prev or (o.child != none32 and o.child >= n)) return false;
        prev = o.node;
    }
    assert(n > 0);
    return true;
}

/// The result counts of `exec`.
pub const Counts = struct { matches: usize, captures: usize };

/// Run a query over a flat tree. Write the matches that pass the text
/// predicates, in the order of the reference, up to the size of each
/// array. With `raw`, write each match of the reference cursor and skip
/// the predicates. Return the full counts.
pub fn exec(arena: std.mem.Allocator, in: Input, raw: bool, matches: []Match, caps_out: []Capture) Error!Counts {
    assert(in.start < in.nodes.len);
    var cursor = try Cursor.init(arena, in);
    try cursor.run();
    var scratch_len: usize = 2;
    for (0..in.view.get(.regexes).len) |i| scratch_len = @max(scratch_len, regex.scratchLen(in.view.program(@intCast(i))));
    const scratch = try arena.alloc(u32, scratch_len);
    var counts = Counts{ .matches = 0, .captures = 0 };
    for (cursor.finished.items) |state| {
        const caps = cursor.captures(state.capture_list);
        if (!raw and !cursor.satisfies(state.pattern_index, caps, scratch)) continue;
        if (counts.matches < matches.len) matches[counts.matches] = .{ .pattern_index = state.pattern_index, .capture_count = @intCast(caps.len) };
        for (caps, counts.captures..) |c, i| {
            if (i < caps_out.len) caps_out[i] = c;
        }
        counts.matches += 1;
        counts.captures += caps.len;
    }
    assert(counts.matches <= cursor.finished.items.len);
    return counts;
}
