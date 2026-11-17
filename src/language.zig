//! Parse table lookups. They port `language.h` and `language.c` of the
//! reference runtime for the grammar ABI in `abi.zig`.

const std = @import("std");
const assert = std.debug.assert;
const abi = @import("abi.zig");

const Language = abi.Language14;
const Symbol = abi.Symbol;
const StateId = abi.StateId;

/// `ts_builtin_sym_error_repeat`: the hidden repetition of ERROR nodes.
pub const builtin_sym_error_repeat: Symbol = abi.builtin_sym_error - 1;
/// `ERROR_STATE`: the parse state of error recovery.
pub const error_state: StateId = 0;
/// A lex state that means "do not lex": the state only holds non-terminal extras.
pub const no_lex_state: u16 = std.math.maxInt(u16);

/// The actions for one state and one terminal symbol.
pub const TableEntry = struct {
    actions: []const abi.ParseAction,
    is_reusable: bool,
};

/// The table value for `state` and `symbol` (`ts_language_lookup`): an action
/// index for a terminal and a successor state for a non-terminal.
pub fn lookup(lang: *const Language, state: StateId, symbol: Symbol) u16 {
    assert(state < lang.state_count);
    assert(symbol < lang.symbol_count);
    if (state < lang.large_state_count) {
        return lang.parse_table.?[@as(usize, state) * lang.symbol_count + symbol];
    }
    const index = lang.small_parse_table_map.?[state - lang.large_state_count];
    const data = lang.small_parse_table.? + index;
    const group_count = data[0];
    var at: usize = 1;
    var group: u16 = 0;
    while (group < group_count) : (group += 1) {
        const value = data[at];
        const count = data[at + 1];
        at += 2;
        for (data[at..][0..count]) |s| {
            if (s == symbol) return value;
        }
        at += count;
    }
    return 0;
}

/// The actions for `state` and the terminal `symbol` (`ts_language_table_entry`).
pub fn tableEntry(lang: *const Language, state: StateId, symbol: Symbol) TableEntry {
    assert(lang.parse_actions != null);
    if (symbol == abi.builtin_sym_error or symbol == builtin_sym_error_repeat) {
        return .{ .actions = &.{}, .is_reusable = false };
    }
    assert(symbol < lang.token_count);
    const entry = lang.parse_actions.? + lookup(lang, state, symbol);
    const actions: [*]const abi.ParseAction = @ptrCast(entry + 1);
    return .{ .actions = actions[0..entry[0].entry.count], .is_reusable = entry[0].entry.reusable };
}

/// True when `state` has a parse action for `symbol` (`ts_language_has_actions`).
pub fn hasActions(lang: *const Language, state: StateId, symbol: Symbol) bool {
    assert(state < lang.state_count);
    assert(symbol < lang.token_count);
    return lookup(lang, state, symbol) != 0;
}

/// The state after `symbol` in `state` (`ts_language_next_state`).
pub fn nextState(lang: *const Language, state: StateId, symbol: Symbol) StateId {
    assert(lang.token_count <= lang.symbol_count);
    if (symbol == abi.builtin_sym_error or symbol == builtin_sym_error_repeat) return 0;
    if (symbol >= lang.symbol_count or state >= lang.state_count) return 0;
    if (symbol >= lang.token_count) return lookup(lang, state, symbol);
    const entry = tableEntry(lang, state, symbol);
    if (entry.actions.len == 0) return 0;
    const action = entry.actions[entry.actions.len - 1];
    assert(action.type <= @backingInt(abi.ParseActionType.recover));
    if (action.type != @backingInt(abi.ParseActionType.shift)) return 0;
    return if (action.shift.extra) state else action.shift.state;
}

/// The metadata of `symbol` (`ts_language_symbol_metadata`).
pub fn symbolMetadata(lang: *const Language, symbol: Symbol) abi.SymbolMetadata {
    assert(lang.symbol_metadata != null);
    if (symbol == abi.builtin_sym_error) return .{ .visible = true, .named = true, .supertype = false };
    if (symbol == builtin_sym_error_repeat) return .{ .visible = false, .named = false, .supertype = false };
    assert(symbol < lang.symbol_count + lang.alias_count);
    return lang.symbol_metadata.?[symbol];
}

/// True when `symbol` is a reserved word in `state` (`ts_language_is_reserved_word`).
pub fn isReservedWord(lang: *const Language, state: StateId, symbol: Symbol) bool {
    assert(state < lang.state_count);
    const mode = abi.lexMode(lang, state);
    if (mode.reserved_word_set_id == 0) return false;
    const ext = abi.extended(lang).?;
    assert(ext.reserved_words != null);
    const size = ext.max_reserved_word_set_size;
    const start = @as(usize, mode.reserved_word_set_id) * size;
    for (ext.reserved_words.?[start..][0..size]) |word| {
        if (word == symbol) return true;
        if (word == 0) break;
    }
    return false;
}

/// The alias of child `index` in production `production_id`, or 0.
pub fn aliasAt(lang: *const Language, production_id: u16, index: u32) Symbol {
    if (production_id == 0) return 0;
    assert(production_id < lang.production_id_count);
    assert(index < lang.max_alias_sequence_length);
    return lang.alias_sequences.?[@as(usize, production_id) * lang.max_alias_sequence_length + index];
}

/// The valid external tokens of an external lex state, or null for state 0.
pub fn enabledExternalTokens(lang: *const Language, external_lex_state: u16) ?[*]const bool {
    if (external_lex_state == 0) return null;
    assert(lang.external_token_count > 0);
    assert(lang.external_scanner.states != null);
    return lang.external_scanner.states.? + @as(usize, lang.external_token_count) * external_lex_state;
}

/// Iterate over the valid symbols of one state (`ts_language_lookaheads`).
/// The order matches the reference: symbol order for a large state, group
/// order for a small state.
pub const LookaheadIterator = struct {
    lang: *const Language,
    data: [*]const u16,
    index: usize = 0,
    group_end: usize = 0,
    table_value: u16 = 0,
    group_count: u16 = 0,
    is_small_state: bool,
    phase: enum { fresh, positioned, done } = .fresh,
    actions: []const abi.ParseAction = &.{},
    symbol: Symbol = std.math.maxInt(u16),
    next_state: StateId = 0,

    pub fn init(lang: *const Language, state: StateId) LookaheadIterator {
        assert(state < lang.state_count);
        if (state >= lang.large_state_count) {
            const offset = lang.small_parse_table_map.?[state - lang.large_state_count];
            const data = lang.small_parse_table.? + offset;
            return .{ .lang = lang, .data = data, .group_end = 1, .group_count = data[0], .is_small_state = true };
        }
        const row = lang.parse_table.? + @as(usize, state) * lang.symbol_count;
        assert(lang.symbol_count > 0);
        return .{ .lang = lang, .data = row, .is_small_state = false };
    }

    /// Move to the next valid symbol. Return false at the end.
    pub fn next(self: *LookaheadIterator) bool {
        assert(self.lang.symbol_count > 0);
        if (self.phase == .done) return false;
        assert(self.lang.token_count <= self.lang.symbol_count);
        if (self.is_small_state) {
            self.index += 1;
            if (self.index != self.group_end) {
                self.symbol = self.data[self.index];
                self.phase = .positioned;
                return true;
            }
            if (self.group_count == 0) {
                self.phase = .done;
                return false;
            }
            self.group_count -= 1;
            self.table_value = self.data[self.index];
            const symbol_count = self.data[self.index + 1];
            self.index += 2;
            self.group_end = self.index + symbol_count;
            self.symbol = self.data[self.index];
        } else {
            var symbol: u32 = if (self.phase == .fresh) 0 else @as(u32, self.symbol) + 1;
            while (symbol < self.lang.symbol_count and self.data[symbol] == 0) symbol += 1;
            if (symbol >= self.lang.symbol_count) {
                self.phase = .done;
                return false;
            }
            self.symbol = @intCast(symbol);
            self.table_value = self.data[symbol];
        }
        self.setActions();
        return true;
    }

    fn setActions(self: *LookaheadIterator) void {
        assert(self.symbol < self.lang.symbol_count);
        if (self.symbol < self.lang.token_count) {
            const entry = self.lang.parse_actions.? + self.table_value;
            const actions: [*]const abi.ParseAction = @ptrCast(entry + 1);
            self.actions = actions[0..entry[0].entry.count];
            self.next_state = 0;
        } else {
            self.actions = &.{};
            self.next_state = self.table_value;
        }
        self.phase = .positioned;
        assert(self.phase == .positioned);
    }
};
