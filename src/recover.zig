//! Error recovery. This ports `ts_parser__handle_error`, `ts_parser__recover`,
//! `ts_parser__recover_to_state`, `ts_parser__do_all_potential_reductions` and
//! `ts_parser__better_version_exists` of the reference runtime. The reference
//! also runs this code for valid input: after an accept, the other stack
//! versions fail at the end of the input and recover.

const std = @import("std");
const assert = std.debug.assert;
const abi = @import("abi.zig");
const language = @import("language.zig");
const st = @import("subtree.zig");
const stack_mod = @import("stack.zig");
const parser_mod = @import("parser.zig");
const limits = @import("root.zig").limits;

const Parser = parser_mod.Parser;
const Error = parser_mod.Error;
const Subtree = st.Subtree;
const Version = stack_mod.Version;
const StateId = abi.StateId;
const Symbol = abi.Symbol;

const max_summary_depth: u32 = 16;

pub const ReduceAction = struct {
    count: u32,
    symbol: Symbol,
    dynamic_precedence: i32,
    production_id: u16,
};

/// Add the reduce actions of `actions` to the set. Return true for a shift
/// (`ts_parser__process_candidate_recovery_actions`).
fn processCandidateActions(p: *Parser, actions: []const abi.ParseAction) Error!bool {
    var has_shift_action = false;
    assert(actions.len <= std.math.maxInt(u8));
    for (actions) |action| {
        switch (@as(abi.ParseActionType, @fromBackingInt(@intCast(action.type)))) {
            .shift, .recover => if (!action.shift.extra and !action.shift.repetition) {
                has_shift_action = true;
            },
            .reduce => if (action.reduce.child_count > 0) try addReduceAction(p, .{
                .symbol = action.reduce.symbol,
                .count = action.reduce.child_count,
                .dynamic_precedence = action.reduce.dynamic_precedence,
                .production_id = action.reduce.production_id,
            }),
            .accept => {},
        }
    }
    assert(p.reduce_actions.items.len <= limits.max_stack_nodes);
    return has_shift_action;
}

/// `ts_reduce_action_set_add`: keep the first action for each symbol and count.
fn addReduceAction(p: *Parser, action: ReduceAction) Error!void {
    assert(action.count > 0);
    for (p.reduce_actions.items) |a| {
        if (a.symbol == action.symbol and a.count == action.count) return;
    }
    try p.reduce_actions.append(p.arena, action);
    assert(p.reduce_actions.items.len > 0);
}

/// Collect the reduce actions of each valid terminal in `state`, then sort
/// them by symbol, largest first (stable).
fn collectAllReductions(p: *Parser, state: StateId) Error!bool {
    assert(state < p.lang.state_count);
    var has_shift_action = false;
    var it = language.LookaheadIterator.init(p.lang, state);
    var steps: usize = 0;
    while (it.next()) : (steps += 1) {
        assert(steps <= p.lang.symbol_count);
        if (it.symbol == abi.builtin_sym_end or it.symbol >= p.lang.token_count) continue;
        if (try processCandidateActions(p, it.actions)) has_shift_action = true;
    }
    const items = p.reduce_actions.items;
    var j: usize = 1;
    while (j < items.len) : (j += 1) {
        const key = items[j];
        var k = j;
        while (k > 0 and items[k - 1].symbol < key.symbol) : (k -= 1) items[k] = items[k - 1];
        items[k] = key;
    }
    return has_shift_action;
}

/// Run every reduction that `lookahead_symbol` allows, or every possible
/// reduction for symbol 0 (`ts_parser__do_all_potential_reductions`).
pub fn doAllPotentialReductions(p: *Parser, starting_version: Version, lookahead_symbol: Symbol) Error!bool {
    assert(starting_version < p.stack.versionCount());
    assert(lookahead_symbol < p.lang.token_count or lookahead_symbol == abi.builtin_sym_error);
    const initial_version_count = p.stack.versionCount();
    var can_shift_lookahead_symbol = false;
    var version = starting_version;
    var i: u32 = 0;
    while (i <= limits.max_stack_nodes) : (i += 1) {
        const version_count = p.stack.versionCount();
        if (version >= version_count) break;
        if (try mergeWithNewVersions(p, initial_version_count, version)) continue;
        const state = p.stack.state(version);
        p.reduce_actions.clearRetainingCapacity();
        var has_shift_action = false;
        if (lookahead_symbol != 0) {
            const entry = language.tableEntry(p.lang, state, lookahead_symbol);
            has_shift_action = try processCandidateActions(p, entry.actions);
        } else {
            has_shift_action = try collectAllReductions(p, state);
        }
        var reduction_version = stack_mod.version_none;
        for (p.reduce_actions.items) |a| {
            reduction_version = try p.reduce(version, a.symbol, a.count, a.dynamic_precedence, a.production_id, true, false);
        }
        if (has_shift_action) {
            can_shift_lookahead_symbol = true;
        } else if (reduction_version != stack_mod.version_none and i < parser_mod.max_version_count) {
            p.stack.renumberVersion(reduction_version, version);
            continue;
        } else if (lookahead_symbol != 0) {
            p.stack.removeVersion(version);
            continue;
        }
        version = if (version == starting_version) version_count else version + 1;
    } else return error.TooManyOperations;
    return can_shift_lookahead_symbol;
}

fn mergeWithNewVersions(p: *Parser, initial_version_count: u32, version: Version) Error!bool {
    assert(initial_version_count <= stack_mod.max_heads);
    var j: Version = initial_version_count;
    assert(version < p.stack.versionCount());
    while (j < version) : (j += 1) {
        if (try p.stack.merge(j, version)) return true;
    }
    return false;
}

/// True when another version is clearly better than a version at `cost`
/// (`ts_parser__better_version_exists`).
pub fn betterVersionExists(p: *Parser, version: Version, is_in_error: bool, cost: u32) bool {
    assert(!is_in_error);
    if (p.finished_tree) |finished| {
        if (finished.errorCost() <= cost) return true;
    }
    const position = p.stack.position(version);
    const status = parser_mod.ErrorStatus{
        .cost = cost,
        .is_in_error = is_in_error,
        .dynamic_precedence = p.stack.dynamicPrecedence(version),
        .node_count = p.stack.nodeCountSinceError(version),
    };
    var i: Version = 0;
    const n = p.stack.versionCount();
    assert(version < n);
    while (i < n) : (i += 1) {
        if (i == version or !p.stack.isActive(i) or p.stack.position(i).bytes < position.bytes) continue;
        switch (Parser.compareVersions(status, p.versionStatus(i))) {
            .take_right => return true,
            .prefer_right => if (p.stack.canMerge(i, version)) return true,
            else => {},
        }
    }
    return false;
}

/// Pop `depth` subtrees of `version` into an ERROR node and continue in
/// `goal_state` (`ts_parser__recover_to_state`).
fn recoverToState(p: *Parser, version: Version, depth: u32, goal_state: StateId) Error!bool {
    // pop_error below reuses the slice buffer of the stack, so copy the pop.
    const pop = try p.arena.dupe(stack_mod.Slice, try p.stack.popCount(version, depth));
    var previous_version = stack_mod.version_none;
    for (pop) |slice_value| {
        var slice = slice_value;
        if (slice.version == previous_version) continue;
        if (p.stack.state(slice.version) != goal_state) {
            p.stack.halt(slice.version);
            continue;
        }
        var error_trees = try p.stack.popError(slice.version);
        if (error_trees.items.len > 0) {
            assert(error_trees.items.len == 1);
            const error_tree = error_trees.items[0];
            if (error_tree.children.len > 0) {
                const nested = try p.pool.newNode(language.builtin_sym_error_repeat, error_tree.children, 0);
                try slice.subtrees.insert(p.arena, 0, nested);
            }
            error_trees.clearRetainingCapacity();
        }
        try p.removeTrailingExtras(&slice.subtrees, &p.trailing_extras);
        if (slice.subtrees.items.len > 0) {
            const err = try p.pool.newErrorNode(slice.subtrees.items, true);
            try p.stack.push(slice.version, err, false, goal_state);
        }
        for (p.trailing_extras.items) |tree| try p.stack.push(slice.version, tree, false, goal_state);
        previous_version = slice.version;
    }
    assert(pop.len <= stack_mod.max_heads * 8);
    return previous_version != stack_mod.version_none;
}

/// Strategy 1 of `ts_parser__recover`: return to an earlier state in the
/// summary where the lookahead is valid.
fn recoverToPreviousState(p: *Parser, version: Version, lookahead: *const Subtree, previous_version_count: u32) Error!bool {
    assert(version < previous_version_count);
    const summary = p.stack.getSummary(version) orelse return false;
    if (lookahead.isError()) return false;
    const position = p.stack.position(version);
    const node_count_since_error = p.stack.nodeCountSinceError(version);
    const current_error_cost = p.stack.errorCost(version);
    for (summary.items) |entry| {
        if (entry.state == language.error_state) continue;
        if (entry.position.bytes == position.bytes) continue;
        var depth = entry.depth;
        if (node_count_since_error > 0) depth += 1;
        if (wouldMerge(p, entry.state, position.bytes, previous_version_count)) continue;
        const new_cost = current_error_cost + entry.depth * st.error_cost_per_skipped_tree +
            (position.bytes - entry.position.bytes) * st.error_cost_per_skipped_char +
            (position.extent.row - entry.position.extent.row) * st.error_cost_per_skipped_line;
        if (betterVersionExists(p, version, false, new_cost)) break;
        if (language.hasActions(p.lang, entry.state, lookahead.symbol)) {
            if (try recoverToState(p, version, depth, entry.state)) return true;
        }
    }
    assert(summary.items.len <= limits.max_stack_nodes);
    return false;
}

fn wouldMerge(p: *const Parser, state: StateId, position_bytes: u32, previous_version_count: u32) bool {
    assert(state < p.lang.state_count);
    var j: Version = 0;
    assert(previous_version_count <= p.stack.versionCount());
    while (j < previous_version_count) : (j += 1) {
        if (p.stack.state(j) == state and p.stack.position(j).bytes == position_bytes) return true;
    }
    return false;
}

/// Recover from an error in `version` (`ts_parser__recover`).
pub fn recover(p: *Parser, version: Version, lookahead: *const Subtree) Error!void {
    assert(version < p.stack.versionCount());
    const previous_version_count = p.stack.versionCount();
    const node_count_since_error = p.stack.nodeCountSinceError(version);
    const current_error_cost = p.stack.errorCost(version);
    const did_recover = try recoverToPreviousState(p, version, lookahead, previous_version_count);
    var i: Version = previous_version_count;
    while (i < p.stack.versionCount()) : (i +%= 1) {
        if (!p.stack.isActive(i)) {
            p.stack.removeVersion(i);
            i -%= 1;
        }
    }
    if (lookahead.symbol == abi.builtin_sym_end) {
        const parent = try p.pool.newErrorNode(&.{}, false);
        try p.stack.push(version, parent, false, 1);
        try p.accept(version, lookahead);
        return;
    }
    if (did_recover and (p.stack.versionCount() > parser_mod.max_version_count or lookahead.has_external_scanner_state_change)) {
        p.stack.halt(version);
        return;
    }
    const total = lookahead.totalSize();
    const new_cost = current_error_cost + st.error_cost_per_skipped_tree +
        total.bytes * st.error_cost_per_skipped_char + total.extent.row * st.error_cost_per_skipped_line;
    if (betterVersionExists(p, version, false, new_cost)) {
        p.stack.halt(version);
        return;
    }
    try skipLookahead(p, version, lookahead, node_count_since_error);
    assert(p.stack.state(version) == language.error_state);
}

/// Strategy 2 of `ts_parser__recover`: wrap the lookahead in an ERROR and
/// stay in the error state.
fn skipLookahead(p: *Parser, version: Version, lookahead_in: *const Subtree, node_count_since_error: u32) Error!void {
    var lookahead = lookahead_in;
    const entry = language.tableEntry(p.lang, 1, lookahead.symbol);
    if (entry.actions.len > 0) {
        const last = entry.actions[entry.actions.len - 1];
        if (last.type == @backingInt(abi.ParseActionType.shift) and last.shift.extra) {
            const copy = try p.pool.makeMut(lookahead);
            copy.extra = true;
            lookahead = copy;
        }
    }
    var error_repeat = try p.pool.newNode(language.builtin_sym_error_repeat, &.{lookahead}, 0);
    if (node_count_since_error > 0) {
        const pop = try p.stack.popCount(version, 1);
        assert(pop.len > 0);
        if (pop.len > 1) {
            while (p.stack.versionCount() > pop[0].version + 1) p.stack.removeVersion(pop[0].version + 1);
        }
        p.stack.renumberVersion(pop[0].version, version);
        var subtrees = pop[0].subtrees;
        try subtrees.append(p.arena, error_repeat);
        error_repeat = try p.pool.newNode(language.builtin_sym_error_repeat, subtrees.items, 0);
    }
    try p.stack.push(version, error_repeat, false, language.error_state);
    if (lookahead.has_external_tokens) p.stack.setLastExternalToken(version, st.lastExternalToken(lookahead));
    assert(error_repeat.symbol == language.builtin_sym_error_repeat);
}

/// Start recovery for a paused version (`ts_parser__handle_error`).
pub fn handleError(p: *Parser, version: Version, lookahead: *const Subtree) Error!void {
    const previous_version_count = p.stack.versionCount();
    assert(version < previous_version_count);
    const can_shift = try doAllPotentialReductions(p, version, 0);
    const version_count = p.stack.versionCount();
    assert(!can_shift or version_count >= previous_version_count);
    const position = p.stack.position(version);
    var did_insert_missing_token = false;
    var v = version;
    while (v < version_count) {
        if (!did_insert_missing_token) did_insert_missing_token = try insertMissingToken(p, v, lookahead, position);
        try p.stack.push(v, null, false, language.error_state);
        v = if (v == version) previous_version_count else v + 1;
    }
    var i = previous_version_count;
    while (i < version_count) : (i += 1) {
        const did_merge = try p.stack.merge(version, previous_version_count);
        assert(did_merge);
    }
    try p.stack.recordSummary(version, max_summary_depth);
    try recover(p, version, lookahead);
}

/// Try each token that a missing token could be (the inner loop of `ts_parser__handle_error`).
fn insertMissingToken(p: *Parser, v: Version, lookahead: *const Subtree, position: @import("length.zig").Length) Error!bool {
    const state = p.stack.state(v);
    var missing_symbol: Symbol = 1;
    assert(p.lang.token_count <= std.math.maxInt(u16));
    while (missing_symbol < p.lang.token_count) : (missing_symbol += 1) {
        const state_after = language.nextState(p.lang, state, missing_symbol);
        if (state_after == 0 or state_after == state) continue;
        const after_entry = language.tableEntry(p.lang, state_after, lookahead.leafSymbol());
        if (after_entry.actions.len == 0 or after_entry.actions[0].type != @backingInt(abi.ParseActionType.reduce)) continue;
        p.lexer.reset(position);
        p.lexer.markEnd();
        const padding = st.subLength(p.lexer.token_end_position, position);
        const lookahead_bytes = lookahead.totalSize().bytes + lookahead.lookahead_bytes;
        const with_missing = try p.stack.copyVersion(v);
        const missing = try p.pool.newMissingLeaf(missing_symbol, state, padding, lookahead_bytes);
        try p.stack.push(with_missing, missing, false, state_after);
        if (try doAllPotentialReductions(p, with_missing, lookahead.leafSymbol())) return true;
    }
    assert(missing_symbol <= p.lang.token_count);
    return false;
}
