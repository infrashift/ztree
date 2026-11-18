//! The query analysis of the reference runtime (`ts_query__analyze_patterns`
//! of `query.c`, ADR-0011). It walks the parse table of the grammar to find
//! each pattern that cannot match (a structure error) and each step that
//! can fail. The query cursor splits its states at fallible steps, so these
//! flags change the matches. The port keeps the order of each sorted set,
//! because the order decides which states the walk visits.

const std = @import("std");
const assert = std.debug.assert;
const abi = @import("abi.zig");
const language = @import("language.zig");
const query = @import("query.zig");

const Language = abi.Language14;
const Symbol = abi.Symbol;
const StateId = abi.StateId;
const FieldId = abi.FieldId;
const Step = query.Step;
const none = query.none;
const wildcard = query.wildcard;

const max_state_depth = 8;
const max_iterations = 256;
const max_predecessors = 256;

const Entry = struct {
    parse_state: StateId = 0,
    parent_symbol: Symbol = 0,
    child_index: u16 = 0,
    field_id: FieldId = 0,
    done: bool = false,
};

/// `AnalysisState`.
const State = struct {
    stack: [max_state_depth]Entry = @splat(.{}),
    depth: u16,
    step_index: u16,
    root_symbol: Symbol,

    fn top(self: *State) *Entry {
        assert(self.depth <= max_state_depth);
        assert(self.stack.len == max_state_depth);
        return &self.stack[if (self.depth == 0) 0 else self.depth - 1];
    }

    /// `analysis_state__recursion_depth`.
    fn recursionDepth(self: *const State) u32 {
        var result: u32 = 0;
        assert(self.depth <= max_state_depth);
        for (0..self.depth) |i| {
            for (0..i) |j| {
                if (self.stack[j].parent_symbol == self.stack[i].parent_symbol) {
                    result += 1;
                    break;
                }
            }
        }
        assert(result <= max_state_depth);
        return result;
    }

    fn hasSupertype(self: *const State, symbol: Symbol) bool {
        assert(self.depth <= max_state_depth);
        assert(symbol != 0);
        for (self.stack[0..self.depth]) |e| if (e.parent_symbol == symbol) return true;
        return false;
    }
};

/// `analysis_state__compare`, with the element first and the needle second.
fn compareStates(a: *const State, b: *const State) i32 {
    assert(a.step_index != none and b.step_index != none);
    assert(a.depth <= max_state_depth and b.depth <= max_state_depth);
    if (a.depth < b.depth) return 1;
    for (0..a.depth) |i| {
        if (i >= b.depth) return -1;
        const s1 = a.stack[i];
        const s2 = b.stack[i];
        if (s1.child_index != s2.child_index) return if (s1.child_index < s2.child_index) -1 else 1;
        if (s1.parent_symbol != s2.parent_symbol) return if (s1.parent_symbol < s2.parent_symbol) -1 else 1;
        if (s1.parse_state != s2.parse_state) return if (s1.parse_state < s2.parse_state) -1 else 1;
        if (s1.field_id != s2.field_id) return if (s1.field_id < s2.field_id) -1 else 1;
    }
    if (a.step_index != b.step_index) return if (a.step_index < b.step_index) -1 else 1;
    return 0;
}

/// `_array__search_sorted`: the index of `needle`, or where it goes.
fn searchSorted(comptime T: type, items: []const T, needle: anytype, comptime cmp: anytype) struct { usize, bool } {
    var index: usize = 0;
    if (items.len == 0) return .{ 0, false };
    var size = items.len;
    var steps: usize = 0;
    while (size > 1) : (steps += 1) {
        assert(steps <= 64);
        const half = size / 2;
        const mid = index + half;
        if (cmp(&items[mid], needle) <= 0) index = mid;
        size -= half;
    }
    const c = cmp(&items[index], needle);
    if (c == 0) return .{ index, true };
    if (c < 0) index += 1;
    assert(index <= items.len);
    return .{ index, false };
}

fn cmpU16(a: *const u16, b: u16) i32 {
    assert(b <= none);
    assert(a.* <= none);
    return @as(i32, a.*) - @as(i32, b);
}

/// Insert `value` into a sorted list of integers when it is not there.
fn insertSortedU16(arena: std.mem.Allocator, list: *std.ArrayList(u16), value: u16) error{OutOfMemory}!void {
    assert(value <= none);
    const index, const exists = searchSorted(u16, list.items, value, cmpU16);
    if (!exists) try list.insert(arena, index, value);
    assert(list.items.len > 0);
}

/// `AnalysisSubgraphNode`.
const SubgraphNode = struct { state: StateId, production_id: u16, child_index: u8, done: bool };

fn cmpNodes(a: *const SubgraphNode, b: *const SubgraphNode) i32 {
    assert(a.state <= none and b.state <= none);
    assert(a.child_index < 128 and b.child_index < 128);
    if (a.state != b.state) return if (a.state < b.state) -1 else 1;
    if (a.child_index != b.child_index) return if (a.child_index < b.child_index) -1 else 1;
    if (a.done != b.done) return if (!a.done) -1 else 1;
    if (a.production_id != b.production_id) return if (a.production_id < b.production_id) -1 else 1;
    return 0;
}

const Subgraph = struct {
    symbol: Symbol,
    start_states: std.ArrayList(StateId) = .empty,
    nodes: std.ArrayList(SubgraphNode) = .empty,
};

fn cmpSubgraph(a: *const Subgraph, symbol: Symbol) i32 {
    assert(symbol <= none);
    assert(a.symbol <= none);
    return @as(i32, a.symbol) - @as(i32, symbol);
}

/// `ts_language_alias_at`, reading the flat table as the reference does.
fn aliasAt(lang: *const Language, production_id: u16, child_index: u32) Symbol {
    assert(production_id < lang.production_id_count);
    if (production_id == 0) return 0;
    const index = @as(usize, production_id) * lang.max_alias_sequence_length + child_index;
    assert(lang.alias_sequences != null);
    if (index >= @as(usize, lang.production_id_count) * lang.max_alias_sequence_length) return 0;
    return lang.alias_sequences.?[index];
}

fn fieldMap(lang: *const Language, production_id: u16) []const abi.FieldMapEntry {
    if (lang.field_count == 0) return &.{};
    assert(production_id < lang.production_id_count);
    const slice = lang.field_map_slices.?[production_id];
    assert(lang.field_map_entries != null);
    return lang.field_map_entries.?[slice.index..][0..slice.length];
}

/// `ts_language_aliases_for_symbol`: the public symbol and the aliases of `symbol`.
fn aliasesFor(lang: *const Language, symbol: Symbol) []const Symbol {
    assert(lang.alias_map != null);
    assert(symbol < lang.symbol_count);
    const map = lang.alias_map.?;
    var index: usize = 0;
    var steps: usize = 0;
    while (steps <= lang.symbol_count) : (steps += 1) {
        const s = map[index];
        index += 1;
        if (s == 0 or s > symbol) break;
        const count = map[index];
        index += 1;
        if (s == symbol) return map[index..][0..count];
        index += count;
    }
    return lang.public_symbol_map.?[symbol..][0..1];
}

/// `QueryAnalysis`.
const Analysis = struct {
    arena: std.mem.Allocator,
    states: std.ArrayList(State) = .empty,
    next_states: std.ArrayList(State) = .empty,
    deeper_states: std.ArrayList(State) = .empty,
    final_step_indices: std.ArrayList(u16) = .empty,
    finished_parent_symbols: std.ArrayList(Symbol) = .empty,
    did_abort: bool = false,

    fn insertState(self: *Analysis, list: *std.ArrayList(State), state: *const State) error{OutOfMemory}!void {
        assert(state.depth <= max_state_depth);
        const index, const exists = searchSorted(State, list.items, state, compareStates);
        if (!exists) try list.insert(self.arena, index, state.*);
        assert(list.items.len > 0);
    }
};

/// The context of one analysis: the query, the grammar and the subgraphs.
const Analyzer = struct {
    q: *query.Query,
    lang: *const Language,
    subgraphs: []Subgraph,
    a: Analysis,

    fn subgraphFor(self: *const Analyzer, symbol: Symbol) ?*const Subgraph {
        assert(symbol != 0);
        const index, const exists = searchSorted(Subgraph, self.subgraphs, symbol, cmpSubgraph);
        assert(index <= self.subgraphs.len);
        return if (exists) &self.subgraphs[index] else null;
    }

    /// `ts_query__perform_analysis`.
    fn perform(self: *Analyzer) error{OutOfMemory}!void {
        assert(self.a.states.items.len <= std.math.maxInt(u32));
        const a = &self.a;
        var recursion_limit: u32 = 0;
        var prev_final_count: usize = 0;
        a.final_step_indices.clearRetainingCapacity();
        a.finished_parent_symbols.clearRetainingCapacity();
        var iteration: u32 = 0;
        var finished = false;
        while (!finished and iteration < max_iterations) : (iteration += 1) {
            if (a.states.items.len == 0) {
                if (a.deeper_states.items.len > 0 and a.final_step_indices.items.len > prev_final_count) {
                    prev_final_count = a.final_step_indices.items.len;
                    recursion_limit += 1;
                    std.mem.swap(std.ArrayList(State), &a.states, &a.deeper_states);
                    continue;
                }
                finished = true;
                continue;
            }
            a.next_states.clearRetainingCapacity();
            try self.iterate(recursion_limit);
            std.mem.swap(std.ArrayList(State), &a.states, &a.next_states);
        }
        if (!finished) a.did_abort = true;
        assert(iteration <= max_iterations);
    }

    /// One iteration over the current states.
    fn iterate(self: *Analyzer, recursion_limit: u32) error{OutOfMemory}!void {
        const a = &self.a;
        assert(a.next_states.items.len == 0);
        var j: usize = 0;
        while (j < a.states.items.len) : (j += 1) {
            const state = a.states.items[j];
            if (a.next_states.items.len > 0) {
                const c = compareStates(&state, &a.next_states.items[a.next_states.items.len - 1]);
                if (c == 0) {
                    try a.insertState(&a.next_states, &state);
                    continue;
                } else if (c > 0) {
                    try a.next_states.appendSlice(a.arena, a.states.items[j..]);
                    break;
                }
            }
            try self.advanceState(state, recursion_limit);
        }
        assert(j <= a.states.items.len);
    }

    /// Follow each path of the parse table from one state.
    fn advanceState(self: *Analyzer, state_in: State, recursion_limit: u32) error{OutOfMemory}!void {
        assert(state_in.depth > 0 and state_in.depth <= max_state_depth);
        var state = state_in;
        const top = state.top().*;
        const subgraph = self.subgraphFor(top.parent_symbol) orelse return;
        var it = language.LookaheadIterator.init(self.lang, top.parse_state);
        var steps: usize = 0;
        while (it.next()) : (steps += 1) {
            assert(steps <= self.lang.symbol_count);
            var successor = SubgraphNode{ .state = top.parse_state, .child_index = @truncate(top.child_index), .production_id = 0, .done = false };
            if (it.actions.len > 0) {
                const action = it.actions[it.actions.len - 1];
                if (action.type != @backingInt(abi.ParseActionType.shift)) continue;
                if (!action.shift.extra) {
                    successor.state = action.shift.state;
                    successor.child_index +%= 1;
                }
            } else if (it.next_state != 0) {
                successor.state = it.next_state;
                successor.child_index +%= 1;
            } else continue;
            successor.child_index &= 0x7f;
            const found = searchSorted(SubgraphNode, subgraph.nodes.items, &successor, cmpNodes);
            var node_index = found[0];
            while (node_index < subgraph.nodes.items.len) : (node_index += 1) {
                const node = subgraph.nodes.items[node_index];
                if (node.state != successor.state or node.child_index != successor.child_index) break;
                try self.followNode(&state, top, node, successor, it.symbol, recursion_limit);
            }
        }
    }

    /// The field of child `child_index` of a production, from the entries
    /// that are not inherited.
    fn childField(self: *const Analyzer, production_id: u16, child_index: u16) FieldId {
        assert(child_index < 0x8000);
        for (fieldMap(self.lang, production_id)) |entry| {
            if (!entry.inherited and entry.child_index == child_index) return entry.field_id;
        }
        assert(production_id < self.lang.production_id_count);
        return 0;
    }

    /// True when a hypothetical child with `visible_symbol` and `field_id`
    /// matches `step`.
    fn childMatches(self: *const Analyzer, state: *const State, step: Step, visible_symbol: Symbol, field_id: FieldId) bool {
        assert(visible_symbol != 0);
        var does_match = true;
        if (step.symbol == wildcard) {
            if (step.flags.is_named and !self.lang.symbol_metadata.?[visible_symbol].named) does_match = false;
        } else if (step.symbol != visible_symbol) does_match = false;
        if (step.field != 0 and step.field != field_id) does_match = false;
        if (step.supertype_symbol != 0 and !state.hasSupertype(step.supertype_symbol)) does_match = false;
        assert(field_id < 0x8000);
        return does_match;
    }

    /// Advance a state past one hypothetical child node.
    fn followNode(self: *Analyzer, state: *State, top: Entry, node: SubgraphNode, successor: SubgraphNode, sym: Symbol, recursion_limit: u32) error{OutOfMemory}!void {
        assert(state.step_index < self.q.steps.items.len);
        const lang = self.lang;
        const step = self.q.steps.items[state.step_index];
        const alias = aliasAt(lang, node.production_id, top.child_index);
        const visible_symbol: Symbol = if (alias != 0) alias else if (lang.symbol_metadata.?[sym].visible) lang.public_symbol_map.?[sym] else 0;
        var field_id = top.field_id;
        if (field_id == 0) field_id = self.childField(node.production_id, top.child_index);
        var next = state.*;
        var next_top = next.top();
        next_top.child_index = successor.child_index;
        next_top.parse_state = successor.state;
        if (node.done) next_top.done = true;
        var does_match = false;
        if (step.symbol == abi.builtin_sym_error) {
            does_match = true;
        } else if (visible_symbol != 0) {
            does_match = self.childMatches(state, step, visible_symbol, field_id);
        } else if (sym >= lang.token_count) {
            if (!next_top.done) {
                if (next.depth + 1 >= max_state_depth) {
                    self.a.did_abort = true;
                    return;
                }
                next.depth += 1;
                next_top = next.top();
            }
            next_top.* = .{ .parse_state = top.parse_state, .parent_symbol = sym, .child_index = 0, .field_id = field_id, .done = false };
            if (next.recursionDepth() > recursion_limit) return self.a.insertState(&self.a.deeper_states, &next);
        }
        var pops: usize = 0;
        while (next.depth > 0 and next_top.done) : (pops += 1) {
            assert(pops <= max_state_depth);
            next.depth -= 1;
            next_top = next.top();
        }
        try self.afterMatch(state, &next, step, does_match, successor.state == top.parse_state);
    }

    /// Move a state to the next step after a hypothetical child, and record
    /// where matching can finish.
    fn afterMatch(self: *Analyzer, state: *const State, next: *State, step: Step, does_match: bool, same_state: bool) error{OutOfMemory}!void {
        assert(next.step_index < self.q.steps.items.len);
        assert(state.depth <= max_state_depth);
        const steps = self.q.steps.items;
        const a = &self.a;
        var next_step = step;
        if (does_match) {
            var guard: usize = 0;
            while (guard <= steps.len) : (guard += 1) {
                next.step_index += 1;
                next_step = steps[next.step_index];
                if (next_step.depth == none or next_step.depth <= step.depth) break;
            }
        } else if (same_state) return;
        var rounds: usize = 0;
        while (rounds <= steps.len) : (rounds += 1) {
            if (next_step.flags.is_pass_through) {
                next.step_index += 1;
                next_step = steps[next.step_index];
                continue;
            }
            if (!next_step.flags.is_dead_end) {
                const did_finish = steps[next.step_index].depth != step.depth;
                if (did_finish) {
                    try insertSortedU16(a.arena, &a.finished_parent_symbols, state.root_symbol);
                } else if (next.depth == 0) {
                    try insertSortedU16(a.arena, &a.final_step_indices, next.step_index);
                } else {
                    try a.insertState(&a.next_states, next);
                }
            }
            if (does_match and next_step.alternative_index != none and next_step.alternative_index > next.step_index) {
                next.step_index = next_step.alternative_index;
                next_step = steps[next.step_index];
            } else break;
        }
    }
};

/// The byte offset of the first step offset at or after `step_index`
/// (`array_search_sorted_by(&step_offsets, .step_index, ...)`).
fn offsetOfStep(q: *const query.Query, step_index: u16) u32 {
    assert(step_index <= none);
    const offsets = q.step_offsets.items;
    assert(offsets.len > 0);
    var index: usize = 0;
    var size = offsets.len;
    while (size > 1) {
        const half = size / 2;
        if (@as(i32, offsets[index + half].step_index) - @as(i32, step_index) <= 0) index += half;
        size -= half;
    }
    if (@as(i32, offsets[index].step_index) < @as(i32, step_index)) index += 1;
    if (index >= offsets.len) index = offsets.len - 1;
    return offsets[index].byte_offset;
}

/// Mark the steps that contain captures and the child steps of each
/// non-wildcard step, and list the parent steps.
fn markSteps(q: *query.Query, parents: *std.ArrayList(u16)) error{OutOfMemory}!void {
    assert(parents.items.len == 0);
    const steps = q.steps.items;
    assert(steps.len <= query.max_steps);
    for (steps, 0..) |*step, i| {
        if (step.depth == none) {
            step.flags.parent_pattern_guaranteed = true;
            step.flags.root_pattern_guaranteed = true;
            continue;
        }
        var has_children = false;
        const is_wildcard = step.symbol == wildcard;
        step.flags.contains_captures = step.capture_ids[0] != none;
        for (steps[i + 1 ..]) |*next| {
            if (next.depth == none or next.depth <= step.depth) break;
            if (next.capture_ids[0] != none) step.flags.contains_captures = true;
            if (!is_wildcard) {
                next.flags.root_pattern_guaranteed = true;
                next.flags.parent_pattern_guaranteed = true;
            }
            has_children = true;
        }
        if (has_children and !is_wildcard) try parents.append(q.arena, @intCast(i));
    }
}

/// Build the subgraph of each parent symbol and each hidden symbol.
fn buildSubgraphs(q: *query.Query, parents: []const u16) error{OutOfMemory}![]Subgraph {
    assert(parents.len <= q.steps.items.len);
    const lang = q.lang;
    var list: std.ArrayList(Subgraph) = .empty;
    for (parents) |p| try insertSubgraph(q.arena, &list, q.steps.items[p].symbol);
    for (lang.token_count..lang.symbol_count) |sym| {
        if (!language.symbolMetadata(lang, @intCast(sym)).visible) try insertSubgraph(q.arena, &list, @intCast(sym));
    }
    const predecessors = try q.arena.alloc(StateId, @as(usize, lang.state_count) * (max_predecessors + 1));
    @memset(predecessors, 0);
    for (1..lang.state_count) |state| try scanState(q, list.items, predecessors, @intCast(state));
    var kept: std.ArrayList(Subgraph) = .empty;
    for (list.items) |*sg| {
        if (sg.nodes.items.len == 0) continue;
        try walkBack(q.arena, sg, predecessors);
        try kept.append(q.arena, sg.*);
    }
    assert(kept.items.len <= list.items.len);
    return kept.items;
}

fn insertSubgraph(arena: std.mem.Allocator, list: *std.ArrayList(Subgraph), symbol: Symbol) error{OutOfMemory}!void {
    assert(symbol != 0);
    const index, const exists = searchSorted(Subgraph, list.items, symbol, cmpSubgraph);
    if (!exists) try list.insert(arena, index, .{ .symbol = symbol });
    assert(list.items.len > 0);
}

fn addPredecessor(map: []StateId, state: StateId, predecessor: StateId) void {
    assert(@as(usize, state) * (max_predecessors + 1) < map.len);
    const index = @as(usize, state) * (max_predecessors + 1);
    const count = &map[index];
    if (count.* == 0 or (count.* < max_predecessors and map[index + count.*] != predecessor)) {
        count.* += 1;
        map[index + count.*] = predecessor;
    }
    assert(count.* <= max_predecessors);
}

/// Record the end states, the start states and the predecessors of one parse state.
fn scanState(q: *query.Query, subgraphs: []Subgraph, predecessors: []StateId, state: StateId) error{OutOfMemory}!void {
    assert(state > 0 and state < q.lang.state_count);
    const lang = q.lang;
    var it = language.LookaheadIterator.init(lang, state);
    var steps: usize = 0;
    while (it.next()) : (steps += 1) {
        assert(steps <= lang.symbol_count);
        if (it.actions.len > 0) {
            for (it.actions) |action| {
                if (action.type == @backingInt(abi.ParseActionType.reduce)) {
                    for (aliasesFor(lang, action.reduce.symbol)) |symbol| {
                        const index, const exists = searchSorted(Subgraph, subgraphs, symbol, cmpSubgraph);
                        if (!exists) continue;
                        const sg = &subgraphs[index];
                        if (sg.nodes.items.len == 0 or sg.nodes.items[sg.nodes.items.len - 1].state != state) {
                            try sg.nodes.append(q.arena, .{ .state = state, .production_id = action.reduce.production_id, .child_index = action.reduce.child_count, .done = true });
                        }
                    }
                } else if (action.type == @backingInt(abi.ParseActionType.shift) and !action.shift.extra) {
                    addPredecessor(predecessors, action.shift.state, state);
                }
            }
        } else if (it.next_state != 0) {
            if (it.next_state != state) addPredecessor(predecessors, it.next_state, state);
            if (lang.primary_state_ids.?[state] != state) continue;
            for (aliasesFor(lang, it.symbol)) |symbol| {
                const index, const exists = searchSorted(Subgraph, subgraphs, symbol, cmpSubgraph);
                if (!exists) continue;
                const sg = &subgraphs[index];
                if (sg.start_states.items.len == 0 or sg.start_states.items[sg.start_states.items.len - 1] != state) try sg.start_states.append(q.arena, state);
            }
        }
    }
}

/// Add the states before each end state of a subgraph.
fn walkBack(arena: std.mem.Allocator, sg: *Subgraph, predecessors: []const StateId) error{OutOfMemory}!void {
    assert(sg.nodes.items.len > 0);
    var pending: std.ArrayList(SubgraphNode) = .empty;
    try pending.appendSlice(arena, sg.nodes.items);
    var steps: usize = 0;
    while (pending.pop()) |node| : (steps += 1) {
        assert(steps <= predecessors.len);
        if (node.child_index <= 1) continue;
        const base = @as(usize, node.state) * (max_predecessors + 1);
        for (predecessors[base + 1 ..][0..predecessors[base]]) |pred| {
            const p = SubgraphNode{ .state = pred, .child_index = node.child_index - 1, .production_id = node.production_id, .done = false };
            const index, const exists = searchSorted(SubgraphNode, sg.nodes.items, &p, cmpNodes);
            if (exists) continue;
            try sg.nodes.insert(arena, index, p);
            try pending.append(arena, p);
        }
    }
}

/// Analyze the pattern of each parent step. Return the byte offset of the
/// first impossible pattern, or null.
fn analyzeParents(an: *Analyzer, parents: []const u16) error{OutOfMemory}!?u32 {
    assert(parents.len <= an.q.steps.items.len);
    const q = an.q;
    for (parents) |parent_index| {
        const parent = q.steps.items[parent_index];
        if (parent.symbol == abi.builtin_sym_error) continue;
        const sg = an.subgraphFor(parent.symbol) orelse return offsetOfStep(q, parent_index + 1);
        an.a.states.clearRetainingCapacity();
        an.a.deeper_states.clearRetainingCapacity();
        for (sg.start_states.items) |parse_state| {
            var st = State{ .depth = 1, .step_index = parent_index + 1, .root_symbol = parent.symbol };
            st.stack[0] = .{ .parse_state = parse_state, .parent_symbol = parent.symbol };
            try an.a.states.append(q.arena, st);
        }
        an.a.did_abort = false;
        try an.perform();
        if (an.a.did_abort) {
            markFallible(q, parent_index + 1, parent.depth);
            continue;
        }
        if (an.a.finished_parent_symbols.items.len == 0) {
            const finals = an.a.final_step_indices.items;
            return offsetOfStep(q, if (finals.len > 0) finals[finals.len - 1] else parent_index);
        }
        for (an.a.final_step_indices.items) |final_index| {
            const step = &q.steps.items[final_index];
            if (step.depth != none and step.depth > parent.depth and !step.flags.is_dead_end) {
                step.flags.parent_pattern_guaranteed = false;
                step.flags.root_pattern_guaranteed = false;
            }
        }
    }
    assert(q.steps.items.len <= query.max_steps);
    return null;
}

/// After an aborted analysis, each child step of the parent can fail.
fn markFallible(q: *query.Query, first: u16, parent_depth: u16) void {
    assert(first <= q.steps.items.len);
    assert(parent_depth != none);
    for (q.steps.items[first..]) |*step| {
        if (step.depth <= parent_depth or step.depth == none) break;
        if (!step.flags.is_dead_end) {
            step.flags.parent_pattern_guaranteed = false;
            step.flags.root_pattern_guaranteed = false;
        }
    }
}

/// A step whose capture is used in a predicate is not definite.
fn markPredicateCaptures(q: *query.Query) error{OutOfMemory}!void {
    assert(q.patterns.items.len <= none);
    var ids: std.ArrayList(u16) = .empty;
    for (q.patterns.items) |pattern| {
        ids.clearRetainingCapacity();
        for (q.predicate_steps.items[pattern.predicate_steps.offset..][0..pattern.predicate_steps.length]) |ps| {
            if (ps.kind == .capture) try insertSortedU16(q.arena, &ids, @intCast(ps.value_id));
        }
        for (q.steps.items[pattern.steps.offset..][0..pattern.steps.length]) |*step| {
            for (step.capture_ids) |id| {
                if (id == none) break;
                _, const exists = searchSorted(u16, ids.items, id, cmpU16);
                if (exists) {
                    step.flags.root_pattern_guaranteed = false;
                    break;
                }
            }
        }
    }
    assert(ids.items.len <= none);
}

/// If a pattern can fail at a step, it can fail at each step before it.
fn propagateFallibility(q: *query.Query) void {
    assert(q.steps.items.len <= query.max_steps);
    const steps = q.steps.items;
    var done = steps.len == 0;
    var rounds: usize = 0;
    while (!done) : (rounds += 1) {
        assert(rounds <= steps.len + 1);
        done = true;
        var i = steps.len - 1;
        while (i > 0) : (i -= 1) {
            var step = steps[i];
            if (step.depth == none) continue;
            var guaranteed = false;
            var guard: usize = 0;
            while (guard <= steps.len) : (guard += 1) {
                if (step.flags.root_pattern_guaranteed) {
                    guaranteed = true;
                    break;
                }
                if (step.alternative_index == none or step.alternative_index < i) break;
                step = steps[step.alternative_index];
            }
            if (guaranteed) continue;
            const prev = &steps[i - 1];
            if (!prev.flags.is_dead_end and prev.depth != none and prev.flags.root_pattern_guaranteed) {
                prev.flags.root_pattern_guaranteed = false;
                done = false;
            }
        }
    }
}

/// Find the hidden repetition symbols where a rootless pattern can match,
/// and mark those patterns non-local.
fn analyzeRootless(an: *Analyzer, entries: []const u16) error{OutOfMemory}!void {
    assert(an.subgraphs.len <= std.math.maxInt(u32));
    const q = an.q;
    an.a.did_abort = false;
    assert(entries.len <= q.pattern_map.items.len);
    for (entries) |entry_index| {
        const entry = q.pattern_map.items[entry_index];
        an.a.states.clearRetainingCapacity();
        an.a.deeper_states.clearRetainingCapacity();
        for (an.subgraphs) |sg| {
            const m = language.symbolMetadata(q.lang, sg.symbol);
            if (m.visible or m.named) continue;
            for (sg.start_states.items) |parse_state| {
                var st = State{ .depth = 1, .step_index = entry.step_index, .root_symbol = sg.symbol };
                st.stack[0] = .{ .parse_state = parse_state, .parent_symbol = sg.symbol };
                try an.a.states.append(q.arena, st);
            }
        }
        try an.perform();
        if (an.a.finished_parent_symbols.items.len > 0) q.patterns.items[entry.pattern_index].is_non_local = 1;
        for (an.a.finished_parent_symbols.items) |symbol| try insertSortedU16(q.arena, &q.repeat_symbols_with_rootless_patterns, symbol);
    }
}

/// `ts_query__analyze_patterns`. Return the byte offset of an impossible
/// pattern, or null when each pattern can match.
pub fn analyze(q: *query.Query) error{OutOfMemory}!?u32 {
    assert(q.steps.items.len > 0 or q.patterns.items.len == 0);
    var rootless: std.ArrayList(u16) = .empty;
    for (q.pattern_map.items, 0..) |entry, i| {
        if (entry.is_rooted == 0 and q.steps.items[entry.step_index].symbol != wildcard) try rootless.append(q.arena, @intCast(i));
    }
    var parents: std.ArrayList(u16) = .empty;
    try markSteps(q, &parents);
    var an = Analyzer{ .q = q, .lang = q.lang, .subgraphs = try buildSubgraphs(q, parents.items), .a = .{ .arena = q.arena } };
    if (try analyzeParents(&an, parents.items)) |offset| return offset;
    try markPredicateCaptures(q);
    propagateFallibility(q);
    try analyzeRootless(&an, rootless.items);
    assert(q.steps.items.len <= query.max_steps);
    return null;
}
