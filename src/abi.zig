//! Zig mirrors of the Tree-sitter grammar ABI (`tree_sitter/parser.h`).
//! ADR-0004 pins ABI versions 14 and 15. ABI 15 appends fields to the
//! ABI 14 layout and widens each lex mode from 4 to 6 bytes.
//! ADR-0003 (R9): this file is the only file that declares function pointers.
//! The grammar ABI requires them.

const std = @import("std");
const assert = std.debug.assert;

pub const StateId = u16;
pub const Symbol = u16;
pub const FieldId = u16;

/// The oldest ABI version that ztree reads.
pub const min_abi_version: u32 = 14;
/// The newest ABI version that ztree reads.
pub const max_abi_version: u32 = 15;
/// The first ABI version with a name, reserved words, supertypes and metadata.
pub const abi_version_with_reserved_words: u32 = 15;

/// The symbol of the end of the input.
pub const builtin_sym_end: Symbol = 0;
/// The symbol of an ERROR node.
pub const builtin_sym_error: Symbol = std.math.maxInt(Symbol);
/// The buffer size that external scanners serialize into.
pub const serialization_buffer_size: usize = 1024;

pub const FieldMapEntry = extern struct {
    field_id: FieldId,
    child_index: u8,
    inherited: bool,
};

/// The field map and the supertype map use this slice type.
pub const MapSlice = extern struct {
    index: u16,
    length: u16,
};

pub const SymbolMetadata = extern struct {
    visible: bool,
    named: bool,
    supertype: bool,
};

/// The lexer interface that the lex function and the external scanners call.
pub const Lexer = extern struct {
    lookahead: i32,
    result_symbol: Symbol,
    advance: *const fn (*Lexer, bool) callconv(.c) void, // nasa-lint: allow(R9) TSLexer ABI
    mark_end: *const fn (*Lexer) callconv(.c) void, // nasa-lint: allow(R9) TSLexer ABI
    get_column: *const fn (*Lexer) callconv(.c) u32, // nasa-lint: allow(R9) TSLexer ABI
    is_at_included_range_start: *const fn (*const Lexer) callconv(.c) bool, // nasa-lint: allow(R9) TSLexer ABI
    eof: *const fn (*const Lexer) callconv(.c) bool, // nasa-lint: allow(R9) TSLexer ABI
    /// A C variadic logger. Phase 2 decides its type. It stays opaque here.
    log: ?*const anyopaque,
};

pub const ParseActionType = enum(u8) {
    shift = 0,
    reduce = 1,
    accept = 2,
    recover = 3,
};

pub const ShiftAction = extern struct {
    type: u8,
    state: StateId,
    extra: bool,
    repetition: bool,
};

pub const ReduceAction = extern struct {
    type: u8,
    child_count: u8,
    symbol: Symbol,
    dynamic_precedence: i16,
    production_id: u16,
};

pub const ParseAction = extern union {
    shift: ShiftAction,
    reduce: ReduceAction,
    type: u8,
};

pub const ParseActionHeader = extern struct {
    count: u8,
    reusable: bool,
};

/// One entry of `parse_actions`: a header, then `count` actions.
pub const ParseActionEntry = extern union {
    action: ParseAction,
    entry: ParseActionHeader,
};

/// An ABI 14 lex mode (4 bytes).
pub const LexMode = extern struct {
    lex_state: u16,
    external_lex_state: u16,
};

/// An ABI 15 lex mode (6 bytes).
pub const LexerMode = extern struct {
    lex_state: u16,
    external_lex_state: u16,
    reserved_word_set_id: u16,
};

/// The lex mode of one parse state, independent of the ABI version.
pub const LexModeView = struct {
    lex_state: u16,
    external_lex_state: u16,
    reserved_word_set_id: u16,
};

pub const LexFn = *const fn (*Lexer, StateId) callconv(.c) bool; // nasa-lint: allow(R9) TSLanguage ABI

pub const ExternalScanner = extern struct {
    states: ?[*]const bool,
    symbol_map: ?[*]const Symbol,
    create: ?*const fn () callconv(.c) ?*anyopaque, // nasa-lint: allow(R9) TSLanguage ABI
    destroy: ?*const fn (?*anyopaque) callconv(.c) void, // nasa-lint: allow(R9) TSLanguage ABI
    scan: ?*const fn (?*anyopaque, *Lexer, [*]const bool) callconv(.c) bool, // nasa-lint: allow(R9) TSLanguage ABI
    serialize: ?*const fn (?*anyopaque, [*]u8) callconv(.c) c_uint, // nasa-lint: allow(R9) TSLanguage ABI
    deserialize: ?*const fn (?*anyopaque, ?[*]const u8, c_uint) callconv(.c) void, // nasa-lint: allow(R9) TSLanguage ABI
};

/// The ABI 14 layout of `TSLanguage`. ABI 15 starts with the same fields.
pub const Language14 = extern struct {
    abi_version: u32,
    symbol_count: u32,
    alias_count: u32,
    token_count: u32,
    external_token_count: u32,
    state_count: u32,
    large_state_count: u32,
    production_id_count: u32,
    field_count: u32,
    max_alias_sequence_length: u16,
    parse_table: ?[*]const u16,
    small_parse_table: ?[*]const u16,
    small_parse_table_map: ?[*]const u32,
    parse_actions: ?[*]const ParseActionEntry,
    symbol_names: ?[*]const [*:0]const u8,
    field_names: ?[*]const ?[*:0]const u8,
    field_map_slices: ?[*]const MapSlice,
    field_map_entries: ?[*]const FieldMapEntry,
    symbol_metadata: ?[*]const SymbolMetadata,
    public_symbol_map: ?[*]const Symbol,
    alias_map: ?[*]const u16,
    alias_sequences: ?[*]const Symbol,
    /// `LexMode` entries in ABI 14 and `LexerMode` entries in ABI 15.
    lex_modes: ?*const anyopaque,
    lex_fn: ?LexFn,
    keyword_lex_fn: ?LexFn,
    keyword_capture_token: Symbol,
    external_scanner: ExternalScanner,
    primary_state_ids: ?[*]const StateId,
};

pub const LanguageMetadata = extern struct {
    major_version: u8,
    minor_version: u8,
    patch_version: u8,
};

/// The ABI 15 layout of `TSLanguage`: the ABI 14 fields, then the new fields.
pub const Language15 = extern struct {
    base: Language14,
    name: ?[*:0]const u8,
    reserved_words: ?[*]const Symbol,
    max_reserved_word_set_size: u16,
    supertype_count: u32,
    supertype_symbols: ?[*]const Symbol,
    supertype_map_slices: ?[*]const MapSlice,
    supertype_map_entries: ?[*]const Symbol,
    metadata: LanguageMetadata,
};

comptime {
    // Language15 embeds Language14. The next field must start at the C offset.
    assert(@offsetOf(Language15, "name") == @sizeOf(Language14));
    assert(@sizeOf(LexMode) == 4 and @sizeOf(LexerMode) == 6);
}

pub const AbiError = error{UnsupportedAbiVersion};

/// Return an error when ztree cannot read the ABI version of `lang`.
pub fn checkVersion(lang: *const Language14) AbiError!void {
    assert(min_abi_version <= max_abi_version);
    assert(lang.state_count > 0);
    if (lang.abi_version < min_abi_version) return error.UnsupportedAbiVersion;
    if (lang.abi_version > max_abi_version) return error.UnsupportedAbiVersion;
}

/// Return the ABI 15 view of `lang`, or null for an ABI 14 grammar.
pub fn extended(lang: *const Language14) ?*const Language15 {
    assert(lang.abi_version >= min_abi_version);
    assert(lang.abi_version <= max_abi_version);
    if (lang.abi_version < abi_version_with_reserved_words) return null;
    return @ptrCast(lang);
}

/// Return the lex mode of `state`. The entry width depends on the ABI version.
pub fn lexMode(lang: *const Language14, state: StateId) LexModeView {
    assert(lang.abi_version >= min_abi_version and lang.abi_version <= max_abi_version);
    assert(state < lang.state_count);
    assert(lang.lex_modes != null);
    if (lang.abi_version >= abi_version_with_reserved_words) {
        const modes: [*]const LexerMode = @ptrCast(@alignCast(lang.lex_modes.?));
        const m = modes[state];
        return .{ .lex_state = m.lex_state, .external_lex_state = m.external_lex_state, .reserved_word_set_id = m.reserved_word_set_id };
    }
    const modes: [*]const LexMode = @ptrCast(@alignCast(lang.lex_modes.?));
    const m = modes[state];
    return .{ .lex_state = m.lex_state, .external_lex_state = m.external_lex_state, .reserved_word_set_id = 0 };
}

/// Return the name of `symbol`. The symbol must be in range.
pub fn symbolName(lang: *const Language14, symbol: Symbol) [*:0]const u8 {
    assert(lang.symbol_names != null);
    assert(symbol < lang.symbol_count + lang.alias_count);
    return lang.symbol_names.?[symbol];
}

test "parse action sizes match the C unions" {
    try std.testing.expectEqual(@as(usize, 6), @sizeOf(ShiftAction));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(ReduceAction));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(ParseActionEntry));
}

test "checkVersion rejects ABI versions outside 14 and 15" {
    var lang = std.mem.zeroes(Language14);
    lang.state_count = 1;
    const cases = [_]struct { u32, bool }{ .{ 13, false }, .{ 14, true }, .{ 15, true }, .{ 16, false } };
    for (cases) |case| {
        lang.abi_version = case[0];
        if (case[1]) {
            try checkVersion(&lang);
        } else {
            try std.testing.expectError(error.UnsupportedAbiVersion, checkVersion(&lang));
        }
    }
}
