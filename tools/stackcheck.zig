//! Check that each ELF object of `libztree.a` has a `.note.GNU-stack`
//! section without the flag SHF_EXECINSTR (ISSUE-019, ADR-0017). GNU ld gives
//! a program an executable stack when one object has no such section.
//!
//! Usage: stackcheck <libztree.a>

const std = @import("std");
const elf = std.elf;

/// The largest library that the tool reads.
const max_lib_bytes: usize = 256 * 1024 * 1024;
/// The most members that the tool reads in one archive.
const max_members: usize = 4096;

const ar_magic = "!<arch>\n";
const ar_header_len: usize = 60;
const stack_note = ".note.GNU-stack";

const Ehdr = elf.Elf64.Ehdr;
const Shdr = elf.Elf64.Shdr;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2) {
        std.debug.print("usage: stackcheck <libztree.a>\n", .{});
        return error.Usage;
    }
    const lib = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], arena, .limited(max_lib_bytes));
    const objects = try checkArchive(lib);
    std.debug.assert(objects > 0);
}

/// Returns the number of ELF objects in the archive `lib`. Each object must
/// have a stack note that is not executable.
fn checkArchive(lib: []const u8) !usize {
    if (!std.mem.startsWith(u8, lib, ar_magic)) return error.NotAnArchive;
    var off: usize = ar_magic.len;
    var objects: usize = 0;
    for (0..max_members) |_| {
        std.debug.assert(off <= lib.len);
        if (off == lib.len) return objects;
        if (lib.len - off < ar_header_len) return error.BadArchive;
        const header = lib[off..][0..ar_header_len];
        if (!std.mem.eql(u8, header[58..60], "`\n")) return error.BadArchive;
        const size_text = std.mem.trimEnd(u8, header[48..58], " ");
        const size = std.fmt.parseInt(usize, size_text, 10) catch return error.BadArchive;
        const start = off + ar_header_len;
        if (size > lib.len - start) return error.BadArchive;
        const data = lib[start..][0..size];
        if (std.mem.startsWith(u8, data, elf.MAGIC)) {
            if (!try hasStackNote(data)) {
                const name = std.mem.trimEnd(u8, header[0..16], " /"); // GNU ar ends a name with '/'.
                std.debug.print("stackcheck: {s} has no {s} section, or the section is executable\n", .{ name, stack_note });
                return error.ExecutableStack;
            }
            objects += 1;
        }
        off = @min(lib.len, start + size + (size & 1));
    }
    return error.TooManyMembers;
}

/// Reports whether the ELF object `obj` has a stack note without SHF_EXECINSTR.
fn hasStackNote(obj: []const u8) !bool {
    std.debug.assert(std.mem.startsWith(u8, obj, elf.MAGIC));
    if (obj.len < @sizeOf(Ehdr)) return error.BadElf;
    if (obj[elf.EI_CLASS] != elf.ELFCLASS64 or obj[elf.EI_DATA] != elf.ELFDATA2LSB) return error.UnsupportedElf;
    const shoff = field(u64, obj, @offsetOf(Ehdr, "shoff"));
    const shentsize = field(u16, obj, @offsetOf(Ehdr, "shentsize"));
    const shnum = field(u16, obj, @offsetOf(Ehdr, "shnum"));
    const shstrndx = field(u16, obj, @offsetOf(Ehdr, "shstrndx"));
    if (shentsize != @sizeOf(Shdr) or shstrndx >= shnum) return error.BadElf;
    if (shoff > obj.len or @as(u64, shnum) * shentsize > obj.len - shoff) return error.BadElf;
    const strtab = try sectionData(obj, sectionHeader(obj, shoff, shstrndx));
    for (0..shnum) |i| {
        const sh = sectionHeader(obj, shoff, i);
        const name_off = field(u32, sh, @offsetOf(Shdr, "name"));
        if (name_off >= strtab.len) return error.BadElf;
        const name = std.mem.sliceTo(strtab[name_off..], 0);
        if (std.mem.eql(u8, name, stack_note)) {
            const flags = field(u64, sh, @offsetOf(Shdr, "flags"));
            return flags & elf.SHF_EXECINSTR == 0;
        }
    }
    return false;
}

/// Returns the header of section `index`. The caller checks the bounds.
fn sectionHeader(obj: []const u8, shoff: u64, index: usize) []const u8 {
    const start: usize = @intCast(shoff + index * @sizeOf(Shdr));
    std.debug.assert(start + @sizeOf(Shdr) <= obj.len);
    return obj[start..][0..@sizeOf(Shdr)];
}

/// Returns the bytes of the section that `sh` describes.
fn sectionData(obj: []const u8, sh: []const u8) ![]const u8 {
    std.debug.assert(sh.len == @sizeOf(Shdr));
    const offset = field(u64, sh, @offsetOf(Shdr, "offset"));
    const size = field(u64, sh, @offsetOf(Shdr, "size"));
    if (offset > obj.len or size > obj.len - offset) return error.BadElf;
    return obj[@intCast(offset)..][0..@intCast(size)];
}

/// Reads a little-endian integer of type T at `at` in `bytes`.
fn field(comptime T: type, bytes: []const u8, at: usize) T {
    std.debug.assert(at + @sizeOf(T) <= bytes.len);
    return std.mem.readInt(T, bytes[at..][0..@sizeOf(T)], .little);
}
