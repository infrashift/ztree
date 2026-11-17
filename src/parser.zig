//! The LR loop. This ports `parser.c` of the reference runtime for one batch
//! parse (ADR-0004, ADR-0005): no incremental reuse, no included ranges, no
//! balance step and no cancellation. `recover.zig` holds the error recovery.

const std = @import("std");
const assert = std.debug.assert;
const abi = @import("abi.zig");
const language = @import("language.zig");
const length = @import("length.zig");
const lexer_mod = @import("lexer.zig");
const st = @import("subtree.zig");
const stack_mod = @import("stack.zig");
const recover_mod = @import("recover.zig");
const limits = @import("root.zig").limits;

const Language = abi.Language14;
const Symbol = abi.Symbol;
const StateId = abi.StateId;
const Length = length.Length;
const Subtree = st.Subtree;
const Stack = stack_mod.Stack;
const Version = stack_mod.Version;
const SubtreeList = stack_mod.SubtreeList;

pub const max_version_count: u32 = 6;
const max_version_count_overflow: u32 = 4;
const max_cost_difference: u32 = 18 * st.error_cost_per_skipped_tree;

pub const Error = st.Error || stack_mod.Error || lexer_mod.Error || abi.AbiError || error{TooManyOperations};

const TokenCache = struct {
    token: ?*const Subtree = null,
    last_external_token: ?*const Subtree = null,
    byte_index: u32 = 0,
};

pub const ErrorStatus = struct {
    cost: u32,
    node_count: u32,
    dynamic_precedence: i32,
    is_in_error: bool,
};

pub const ErrorComparison = enum { take_left, prefer_left, none, prefer_right, take_right };

/// The state of one call of `lex` (the locals of `ts_parser__lex`).
const LexScan = struct {
    error_mode: bool,
    found_external_token: bool = false,
    skipped_error: bool = false,
    called_get_column: bool = false,
    first_error_character: i32 = 0,
    error_start: Length = length.zero,
    error_end: Length = length.zero,
    lookahead_end_byte: u32 = 0,
    external_state_len: u32 = 0,
    external_state_changed: bool = false,
};

/// Parse `source` with `lang`. The arena owns every subtree of the result.
pub fn parse(arena: std.mem.Allocator, lang: *const Language, source: []const u8) Error!*const Subtree {
    try abi.checkVersion(lang);
    assert(lang.lex_fn != null);
    const p = try arena.create(Parser);
    p.* = .{
        .arena = arena,
        .lang = lang,
        .lexer = try lexer_mod.Lexer.init(source),
        .stack = try Stack.init(arena),
        .pool = .{ .arena = arena, .lang = lang },
    };
    if (lang.external_scanner.states != null) {
        if (lang.external_scanner.create) |create| p.scanner_payload = create();
    }
    defer if (p.scanner_payload) |payload| lang.external_scanner.destroy.?(payload);
    const root = try p.run();
    assert(root.children.len > 0 or root.symbol == abi.builtin_sym_error);
    return root;
}

pub const Parser = struct {
    arena: std.mem.Allocator,
    lang: *const Language,
    lexer: lexer_mod.Lexer,
    stack: Stack,
    pool: st.Pool,
    finished_tree: ?*const Subtree = null,
    trailing_extras: SubtreeList = .empty,
    trailing_extras2: SubtreeList = .empty,
    compare_scratch: std.ArrayList(*const Subtree) = .empty,
    token_cache: TokenCache = .{},
    scanner_payload: ?*anyopaque = null,
    scanner_buffer: [abi.serialization_buffer_size]u8 = undefined,
    accept_count: u32 = 0,
    reduce_actions: std.ArrayList(recover_mod.ReduceAction) = .empty,

    /// The outer loop of `ts_parser_parse`.
    fn run(self: *Parser) Error!*const Subtree {
        assert(self.stack.versionCount() == 1);
        var last_position: u32 = 0;
        var rounds: usize = 0;
        while (rounds <= limits.max_stack_nodes) : (rounds += 1) {
            var version: Version = 0;
            var version_count = self.stack.versionCount();
            while (version < version_count) : (version += 1) {
                try self.advanceVersion(version, &last_position);
                version_count = self.stack.versionCount();
            }
            const min_error_cost = try self.condenseStack();
            if (self.finished_tree) |finished| {
                if (finished.errorCost() < min_error_cost) {
                    try self.stack.clear();
                    break;
                }
            }
            if (version_count == 0) break;
        } else return error.TooManyOperations;
        assert(self.finished_tree != null);
        return self.finished_tree.?;
    }

    /// Advance `version` until it moves past the furthest position so far.
    fn advanceVersion(self: *Parser, version: Version, last_position: *u32) Error!void {
        assert(version < self.stack.versionCount());
        var steps: usize = 0;
        while (self.stack.isActive(version)) : (steps += 1) {
            if (steps > limits.max_stack_nodes) return error.TooManyOperations;
            try self.advance(version);
            const position = self.stack.position(version).bytes;
            if (position > last_position.* or (version > 0 and position == last_position.*)) {
                last_position.* = position;
                break;
            }
        }
        assert(last_position.* <= self.lexer.source.len);
    }

    // ----- Lexing -----

    fn deserializeScanner(self: *Parser, external_token: ?*const Subtree) void {
        const state = Subtree.externalState(external_token);
        assert(state.len <= abi.serialization_buffer_size);
        assert(self.scanner_payload != null or self.lang.external_scanner.create == null);
        const data: ?[*]const u8 = if (external_token != null) state.ptr else null;
        self.lang.external_scanner.deserialize.?(self.scanner_payload, data, @intCast(state.len));
    }

    /// Run the external scanner (the first part of the `ts_parser__lex` loop).
    fn tryExternal(self: *Parser, version: Version, parse_state: StateId, mode: abi.LexModeView, external_token: ?*const Subtree, scan: *LexScan) bool {
        assert(mode.external_lex_state != 0);
        const lx = &self.lexer;
        const current = lx.current_position;
        const column_valid = lx.column_valid;
        const column_value = lx.column_value;
        lx.start();
        self.deserializeScanner(external_token);
        const valid = language.enabledExternalTokens(self.lang, mode.external_lex_state).?;
        var found = self.lang.external_scanner.scan.?(self.scanner_payload, &lx.data, valid);
        scan.called_get_column = scan.called_get_column or lx.did_get_column;
        lx.finish(&scan.lookahead_end_byte);
        if (found) {
            const len = self.lang.external_scanner.serialize.?(self.scanner_payload, &self.scanner_buffer);
            assert(len <= abi.serialization_buffer_size);
            scan.external_state_len = len;
            scan.external_state_changed = !std.mem.eql(u8, Subtree.externalState(external_token), self.scanner_buffer[0..len]);
            if (lx.token_end_position.bytes <= current.bytes and !scan.external_state_changed) {
                const symbol = self.lang.external_scanner.symbol_map.?[lx.data.result_symbol];
                const is_extra = language.nextState(self.lang, parse_state, symbol) == parse_state;
                if (scan.error_mode or !self.stack.hasAdvancedSinceError(version) or is_extra) found = false;
            }
        }
        if (found) {
            scan.found_external_token = true;
            return true;
        }
        lx.reset(current);
        lx.column_valid = column_valid;
        lx.column_value = column_value;
        return false;
    }

    /// The loop of `ts_parser__lex`: external scanner, main lexer, then error mode.
    fn lexLoop(self: *Parser, version: Version, parse_state: StateId, start: Length, scan: *LexScan) void {
        assert(start.bytes <= self.lexer.source.len);
        const lx = &self.lexer;
        const external_token = self.stack.lastExternalToken(version);
        var mode = abi.lexMode(self.lang, parse_state);
        var steps: usize = 0;
        while (steps <= lx.source.len + 4) : (steps += 1) {
            if (mode.external_lex_state != 0 and self.tryExternal(version, parse_state, mode, external_token, scan)) return;
            lx.start();
            const found = self.lang.lex_fn.?(&lx.data, mode.lex_state);
            lx.finish(&scan.lookahead_end_byte);
            if (found) return;
            if (!scan.error_mode) {
                scan.error_mode = true;
                mode = abi.lexMode(self.lang, language.error_state);
                lx.reset(start);
                continue;
            }
            if (!scan.skipped_error) {
                scan.skipped_error = true;
                scan.error_start = lx.token_start_position;
                scan.error_end = lx.token_start_position;
                scan.first_error_character = lx.data.lookahead;
            }
            if (lx.current_position.bytes == scan.error_end.bytes) {
                if (lx.data.eof(&lx.data)) {
                    lx.data.result_symbol = abi.builtin_sym_error;
                    return;
                }
                lx.data.advance(&lx.data, false);
            }
            scan.error_end = lx.current_position;
        }
        assert(false);
    }

    /// Lex one token in `parse_state` (`ts_parser__lex`). Null means the state
    /// only holds non-terminal extras.
    fn lex(self: *Parser, version: Version, parse_state: StateId) Error!?*const Subtree {
        assert(version < self.stack.versionCount());
        const mode = abi.lexMode(self.lang, parse_state);
        if (mode.lex_state == language.no_lex_state) return null;
        const start = self.stack.position(version);
        var scan = LexScan{ .error_mode = parse_state == language.error_state };
        self.lexer.reset(start);
        self.lexLoop(version, parse_state, start, &scan);
        if (scan.skipped_error) {
            const padding = st.subLength(scan.error_start, start);
            const size = st.subLength(scan.error_end, scan.error_start);
            const lookahead_bytes = scan.lookahead_end_byte - scan.error_end.bytes;
            return try self.pool.newError(scan.first_error_character, padding, size, lookahead_bytes, parse_state);
        }
        const token = try self.makeToken(parse_state, start, &scan);
        assert(token.symbol < self.lang.symbol_count);
        return token;
    }

    /// Build the leaf of a token that the lexer found (end of `ts_parser__lex`).
    fn makeToken(self: *Parser, parse_state: StateId, start: Length, scan: *const LexScan) Error!*Subtree {
        assert(start.bytes <= self.lexer.token_start_position.bytes);
        const lx = &self.lexer;
        var symbol = lx.data.result_symbol;
        const padding = st.subLength(lx.token_start_position, start);
        const size = st.subLength(lx.token_end_position, lx.token_start_position);
        const lookahead_bytes = scan.lookahead_end_byte - lx.token_end_position.bytes;
        var is_keyword = false;
        if (scan.found_external_token) {
            symbol = self.lang.external_scanner.symbol_map.?[symbol];
        } else if (symbol == self.lang.keyword_capture_token and symbol != 0) {
            const end_byte = lx.token_end_position.bytes;
            lx.reset(lx.token_start_position);
            lx.start();
            is_keyword = self.lang.keyword_lex_fn.?(&lx.data, 0);
            const keyword = lx.data.result_symbol;
            if (is_keyword and lx.token_end_position.bytes == end_byte and
                (language.hasActions(self.lang, parse_state, keyword) or language.isReservedWord(self.lang, parse_state, keyword)))
            {
                symbol = keyword;
            }
        }
        const leaf = try self.pool.newLeaf(symbol, padding, size, lookahead_bytes, parse_state, scan.found_external_token, scan.called_get_column, is_keyword);
        if (scan.found_external_token) {
            leaf.external_scanner_state = try self.arena.dupe(u8, self.scanner_buffer[0..scan.external_state_len]);
            leaf.has_external_scanner_state_change = scan.external_state_changed;
        }
        assert(leaf.symbol == symbol);
        return leaf;
    }

    // ----- Token cache -----

    fn canReuseFirstLeaf(self: *const Parser, state: StateId, tree: *const Subtree, entry: language.TableEntry) bool {
        assert(state < self.lang.state_count);
        const leaf_symbol = tree.leafSymbol();
        const current_mode = abi.lexMode(self.lang, state);
        const leaf_mode = abi.lexMode(self.lang, tree.leafParseState());
        if (current_mode.lex_state == language.no_lex_state) return false;
        if (entry.actions.len > 0 and std.meta.eql(leaf_mode, current_mode) and
            (leaf_symbol != self.lang.keyword_capture_token or (!tree.is_keyword and tree.parse_state == state)))
        {
            return true;
        }
        if (tree.size.bytes == 0 and leaf_symbol != abi.builtin_sym_end) return false;
        assert(current_mode.lex_state != language.no_lex_state);
        return current_mode.external_lex_state == 0 and entry.is_reusable;
    }

    fn getCachedToken(self: *const Parser, state: StateId, position: u32, last_external_token: ?*const Subtree, entry: *language.TableEntry) ?*const Subtree {
        assert(state < self.lang.state_count);
        const cache = &self.token_cache;
        const token = cache.token orelse return null;
        if (cache.byte_index != position) return null;
        if (!st.externalStateEq(cache.last_external_token, last_external_token)) return null;
        entry.* = language.tableEntry(self.lang, state, token.symbol);
        if (!self.canReuseFirstLeaf(state, token, entry.*)) return null;
        assert(token.children.len == 0);
        return token;
    }

    // ----- Actions -----

    fn shift(self: *Parser, version: Version, state: StateId, lookahead: *const Subtree, extra: bool) Error!void {
        const is_leaf = lookahead.children.len == 0;
        assert(is_leaf);
        var to_push = lookahead;
        if (extra != lookahead.extra and is_leaf) {
            const copy = try self.pool.makeMut(lookahead);
            copy.extra = extra;
            to_push = copy;
        }
        try self.stack.push(version, to_push, !is_leaf, state);
        if (to_push.has_external_tokens) self.stack.setLastExternalToken(version, st.lastExternalToken(to_push));
        assert(self.stack.state(version) == state);
    }

    /// Move trailing extras from `children` to `dest` (`ts_subtree_array_remove_trailing_extras`).
    pub fn removeTrailingExtras(self: *Parser, children: *SubtreeList, dest: *SubtreeList) Error!void {
        assert(children.items.len <= limits.max_subtrees);
        dest.clearRetainingCapacity();
        while (children.items.len > 0 and children.items[children.items.len - 1].extra) {
            try dest.append(self.arena, children.pop().?);
        }
        std.mem.reverse(*const Subtree, dest.items);
        assert(children.items.len == 0 or !children.items[children.items.len - 1].extra);
    }

    /// True when `right` is the better tree (`ts_parser__select_tree`).
    fn selectTree(self: *Parser, left: ?*const Subtree, right: ?*const Subtree) Error!bool {
        assert(self.compare_scratch.items.len == 0);
        const l = left orelse return true;
        const r = right orelse return false;
        if (r.errorCost() < l.errorCost()) return true;
        if (l.errorCost() < r.errorCost()) return false;
        if (r.dynamicPrecedence() > l.dynamicPrecedence()) return true;
        if (l.dynamicPrecedence() > r.dynamicPrecedence()) return false;
        if (l.errorCost() > 0) return true;
        const order = try st.compare(self.arena, &self.compare_scratch, l, r);
        assert(self.compare_scratch.items.len == 0);
        return order == .gt;
    }

    /// The reduce action (`ts_parser__reduce`). Return the first new version.
    pub fn reduce(self: *Parser, version: Version, symbol: Symbol, count: u32, dynamic_precedence: i32, production_id: u16, is_fragile: bool, end_of_non_terminal_extra: bool) Error!Version {
        assert(version < self.stack.versionCount());
        const initial_version_count = self.stack.versionCount();
        const pop = try self.stack.popCount(version, count);
        var removed: u32 = 0;
        const halted = self.stack.haltedVersionCount();
        var i: usize = 0;
        while (i < pop.len) : (i += 1) {
            const slice = pop[i];
            const slice_version = slice.version - removed;
            if (slice_version > max_version_count + max_version_count_overflow + halted) {
                self.stack.removeVersion(slice_version);
                removed += 1;
                while (i + 1 < pop.len and pop[i + 1].version == slice.version) i += 1;
                continue;
            }
            const parent = try self.reduceSlice(pop, &i, symbol, production_id);
            const reduce_info = ReduceInfo{ .dynamic_precedence = dynamic_precedence, .fragile = is_fragile or pop.len > 1 or initial_version_count > 1, .end_of_extra = end_of_non_terminal_extra };
            try self.pushReduced(slice_version, parent, symbol, reduce_info);
            var j: Version = 0;
            while (j < slice_version) : (j += 1) {
                if (j == version) continue;
                if (try self.stack.merge(j, slice_version)) {
                    removed += 1;
                    break;
                }
            }
        }
        assert(i >= pop.len);
        return if (self.stack.versionCount() > initial_version_count) initial_version_count else stack_mod.version_none;
    }

    /// Build the parent of slice `i.*` and choose among the slices that reach
    /// the same version (the inner loop of `ts_parser__reduce`).
    fn reduceSlice(self: *Parser, pop: []stack_mod.Slice, i: *usize, symbol: Symbol, production_id: u16) Error!*Subtree {
        assert(i.* < pop.len);
        const slice = pop[i.*];
        var children = slice.subtrees;
        try self.removeTrailingExtras(&children, &self.trailing_extras);
        var parent = try self.pool.newNode(symbol, children.items, production_id);
        while (i.* + 1 < pop.len) {
            const next = pop[i.* + 1];
            if (next.version != slice.version) break;
            i.* += 1;
            var next_children = next.subtrees;
            try self.removeTrailingExtras(&next_children, &self.trailing_extras2);
            const scratch = try self.pool.newNode(parent.symbol, next_children.items, 0);
            if (try self.selectTree(parent, scratch)) {
                std.mem.swap(SubtreeList, &self.trailing_extras, &self.trailing_extras2);
                parent = try self.pool.newNode(symbol, next_children.items, production_id);
            }
            self.trailing_extras2.clearRetainingCapacity();
        }
        assert(parent.symbol == symbol);
        return parent;
    }

    const ReduceInfo = struct { dynamic_precedence: i32, fragile: bool, end_of_extra: bool };

    /// Push the new parent and the trailing extras (end of `ts_parser__reduce`).
    fn pushReduced(self: *Parser, slice_version: Version, parent: *Subtree, symbol: Symbol, info: ReduceInfo) Error!void {
        assert(parent.children.len <= limits.max_subtrees);
        const state = self.stack.state(slice_version);
        const next_state = language.nextState(self.lang, state, symbol);
        if (info.end_of_extra and next_state == state) parent.extra = true;
        if (info.fragile) {
            parent.fragile_left = true;
            parent.fragile_right = true;
            parent.parse_state = st.state_none;
        } else {
            parent.parse_state = state;
        }
        parent.dynamic_precedence += info.dynamic_precedence;
        try self.stack.push(slice_version, parent, false, next_state);
        for (self.trailing_extras.items) |extra| try self.stack.push(slice_version, extra, false, next_state);
        assert(self.stack.state(slice_version) == next_state);
    }

    /// The accept action (`ts_parser__accept`).
    pub fn accept(self: *Parser, version: Version, lookahead: *const Subtree) Error!void {
        assert(lookahead.symbol == abi.builtin_sym_end);
        try self.stack.push(version, lookahead, false, 1);
        const pop = try self.stack.popAll(version);
        assert(pop.len > 0);
        for (pop) |slice| {
            const root = try self.acceptRoot(slice.subtrees.items);
            self.accept_count += 1;
            if (self.finished_tree == null or try self.selectTree(self.finished_tree, root)) self.finished_tree = root;
        }
        self.stack.removeVersion(pop[0].version);
        self.stack.halt(version);
    }

    /// Replace the last non-extra tree with its children under a new root.
    fn acceptRoot(self: *Parser, trees: []const *const Subtree) Error!*const Subtree {
        assert(trees.len > 0);
        var j = trees.len;
        while (j > 0) {
            j -= 1;
            const tree = trees[j];
            if (tree.extra) continue;
            var list: SubtreeList = .empty;
            try list.ensureTotalCapacity(self.arena, trees.len + tree.children.len);
            list.appendSliceAssumeCapacity(trees[0..j]);
            list.appendSliceAssumeCapacity(tree.children);
            list.appendSliceAssumeCapacity(trees[j + 1 ..]);
            const root = try self.pool.newNode(tree.symbol, list.items, tree.production_id);
            assert(root.symbol == tree.symbol);
            return root;
        }
        unreachable;
    }

    /// Process the actions of the lookahead in `version` (`ts_parser__advance`).
    fn advance(self: *Parser, version: Version) Error!void {
        assert(version < self.stack.versionCount());
        assert(self.stack.isActive(version));
        var state = self.stack.state(version);
        const position = self.stack.position(version).bytes;
        const last_external_token = self.stack.lastExternalToken(version);
        var entry = language.TableEntry{ .actions = &.{}, .is_reusable = false };
        var lookahead = self.getCachedToken(state, position, last_external_token, &entry);
        var needs_lex = lookahead == null;
        var steps: usize = 0;
        while (steps <= limits.max_stack_nodes) : (steps += 1) {
            if (needs_lex) {
                needs_lex = false;
                lookahead = try self.lex(version, state);
                if (lookahead) |la| {
                    self.token_cache = .{ .token = la, .last_external_token = last_external_token, .byte_index = position };
                    entry = language.tableEntry(self.lang, state, la.symbol);
                } else {
                    entry = language.tableEntry(self.lang, state, abi.builtin_sym_end);
                }
            }
            switch (try self.applyActions(version, state, lookahead, entry)) {
                .done => return,
                .reduced => |reduction_version| {
                    self.stack.renumberVersion(reduction_version, version);
                    state = self.stack.state(version);
                    if (lookahead) |la| {
                        entry = language.tableEntry(self.lang, state, la.leafSymbol());
                    } else needs_lex = true;
                    continue;
                },
                .none => {},
            }
            if (try self.switchToWordToken(state, &lookahead, &entry)) continue;
            if (state == language.error_state) {
                try recover_mod.recover(self, version, lookahead.?);
                return;
            }
            self.stack.pause(version, lookahead);
            return;
        }
        return error.TooManyOperations;
    }

    const Outcome = union(enum) { done, reduced: Version, none };

    /// Run each action of `entry` (the action loop of `ts_parser__advance`).
    fn applyActions(self: *Parser, version: Version, state: StateId, lookahead: ?*const Subtree, entry: language.TableEntry) Error!Outcome {
        var did_reduce = false;
        var last_reduction_version = stack_mod.version_none;
        assert(entry.actions.len <= std.math.maxInt(u8));
        for (entry.actions) |action| {
            switch (@as(abi.ParseActionType, @fromBackingInt(@intCast(action.type)))) {
                .shift => {
                    if (action.shift.repetition) continue;
                    const next_state = if (action.shift.extra) state else action.shift.state;
                    try self.shift(version, next_state, lookahead.?, action.shift.extra);
                    return .done;
                },
                .reduce => {
                    const r = action.reduce;
                    const v = try self.reduce(version, r.symbol, r.child_count, r.dynamic_precedence, r.production_id, entry.actions.len > 1, lookahead == null);
                    did_reduce = true;
                    if (v != stack_mod.version_none) last_reduction_version = v;
                },
                .accept => {
                    try self.accept(version, lookahead.?);
                    return .done;
                },
                .recover => {
                    try recover_mod.recover(self, version, lookahead.?);
                    return .done;
                },
            }
        }
        if (last_reduction_version != stack_mod.version_none) return .{ .reduced = last_reduction_version };
        if (did_reduce) {
            self.stack.halt(version);
            return .done;
        }
        assert(!did_reduce);
        return .none;
    }

    /// Treat an invalid keyword as the word token when the word token is valid.
    fn switchToWordToken(self: *Parser, state: StateId, lookahead: *?*const Subtree, entry: *language.TableEntry) Error!bool {
        assert(state < self.lang.state_count);
        const la = lookahead.* orelse return false;
        const word = self.lang.keyword_capture_token;
        if (!la.is_keyword or la.symbol == word) return false;
        if (language.isReservedWord(self.lang, state, la.symbol)) return false;
        entry.* = language.tableEntry(self.lang, state, word);
        if (entry.actions.len == 0) return false;
        const copy = try self.pool.makeMut(la);
        st.setSymbol(copy, word, self.lang);
        lookahead.* = copy;
        assert(copy.symbol == word);
        return true;
    }

    // ----- Version selection -----

    pub fn versionStatus(self: *Parser, version: Version) ErrorStatus {
        assert(version < self.stack.versionCount());
        var cost = self.stack.errorCost(version);
        const is_paused = self.stack.isPaused(version);
        if (is_paused) cost += st.error_cost_per_skipped_tree;
        assert(cost >= self.stack.errorCost(version));
        return .{
            .cost = cost,
            .node_count = self.stack.nodeCountSinceError(version),
            .dynamic_precedence = self.stack.dynamicPrecedence(version),
            .is_in_error = is_paused or self.stack.state(version) == language.error_state,
        };
    }

    pub fn compareVersions(a: ErrorStatus, b: ErrorStatus) ErrorComparison {
        assert(a.node_count <= limits.max_subtrees and b.node_count <= limits.max_subtrees);
        if (!a.is_in_error and b.is_in_error) return if (a.cost < b.cost) .take_left else .prefer_left;
        if (a.is_in_error and !b.is_in_error) return if (b.cost < a.cost) .take_right else .prefer_right;
        if (a.cost < b.cost) {
            const diff = @as(u64, b.cost - a.cost) * (1 + @as(u64, a.node_count));
            return if (diff > max_cost_difference) .take_left else .prefer_left;
        }
        if (b.cost < a.cost) {
            const diff = @as(u64, a.cost - b.cost) * (1 + @as(u64, b.node_count));
            return if (diff > max_cost_difference) .take_right else .prefer_right;
        }
        assert(a.cost == b.cost);
        if (a.dynamic_precedence > b.dynamic_precedence) return .prefer_left;
        if (b.dynamic_precedence > a.dynamic_precedence) return .prefer_right;
        return .none;
    }

    /// Prune, merge and order the versions (`ts_parser__condense_stack`).
    /// Return the smallest error cost of a version that is not in error.
    fn condenseStack(self: *Parser) Error!u32 {
        assert(self.stack.versionCount() <= stack_mod.max_heads);
        assert(self.accept_count <= limits.max_stack_nodes);
        var min_error_cost: u32 = std.math.maxInt(u32);
        var i: Version = 0;
        while (i < self.stack.versionCount()) : (i +%= 1) {
            if (self.stack.isHalted(i)) {
                self.stack.removeVersion(i);
                i -%= 1;
                continue;
            }
            const status_i = self.versionStatus(i);
            if (!status_i.is_in_error and status_i.cost < min_error_cost) min_error_cost = status_i.cost;
            i = try self.condensePairs(i, status_i);
        }
        while (self.stack.versionCount() > max_version_count) self.stack.removeVersion(max_version_count);
        return self.resumePaused(min_error_cost);
    }

    /// Compare version `i` with each earlier version. Return the new `i`.
    fn condensePairs(self: *Parser, start_i: Version, status_i: ErrorStatus) Error!Version {
        assert(start_i < self.stack.versionCount());
        var i = start_i;
        var j: Version = 0;
        while (j < i) : (j +%= 1) {
            const status_j = self.versionStatus(j);
            switch (compareVersions(status_j, status_i)) {
                .take_left => {
                    self.stack.removeVersion(i);
                    i -%= 1;
                    j = i;
                },
                .prefer_left, .none => if (try self.stack.merge(j, i)) {
                    i -%= 1;
                    j = i;
                },
                .prefer_right => if (try self.stack.merge(j, i)) {
                    i -%= 1;
                    j = i;
                } else self.stack.swapVersions(i, j),
                .take_right => {
                    self.stack.removeVersion(j);
                    i -%= 1;
                    j -%= 1;
                },
            }
        }
        // A removal lowers `i`. At 0 it wraps, and the caller's increment wraps back.
        assert(i <= start_i or i == std.math.maxInt(Version));
        return i;
    }

    /// Resume the best paused version for recovery, or remove paused versions
    /// (end of `ts_parser__condense_stack`). The loop bound is the count at
    /// the start, as in the reference, although recovery adds versions.
    fn resumePaused(self: *Parser, min_error_cost_in: u32) Error!u32 {
        assert(self.stack.versionCount() <= stack_mod.max_heads);
        var min_error_cost = min_error_cost_in;
        var has_unpaused_version = false;
        var n = self.stack.versionCount();
        var i: Version = 0;
        while (i < n) : (i +%= 1) {
            if (!self.stack.isPaused(i)) {
                has_unpaused_version = true;
                continue;
            }
            if (!has_unpaused_version and self.accept_count < max_version_count) {
                min_error_cost = self.stack.errorCost(i);
                const lookahead = self.stack.@"resume"(i);
                try recover_mod.handleError(self, i, lookahead.?);
                has_unpaused_version = true;
            } else {
                self.stack.removeVersion(i);
                i -%= 1;
                n -= 1;
            }
        }
        assert(n <= self.stack.versionCount());
        return min_error_cost;
    }
};
