const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const BrainfuckParser = @import("Prog/BrainfuckParser.zig");
const BytecodeTextParser = @import("Prog/BytecodeTextParser.zig");

insts: Inst.List.Slice,

const Prog = @This();

pub const Inst = struct {
    tag: Tag,
    value: u8,
    offset: u32,
    extra: u32,

    pub const List = std.MultiArrayList(Inst);

    pub const Tag = enum {
        /// Halts the program.
        halt,
        /// Debugger breakpoint.
        breakpoint,
        /// `mem[mp + offset] = value`
        set,
        /// `mem[mp + offset] += value`
        add,
        /// `mem[mp + offset] = value * mem[mp + offset + extra]`
        add_mul,
        /// `mp += extra`
        move,
        /// Set `mp` to the first occurrence of `value` found by starting at
        /// `offset` and moving in increments of `extra`.
        seek,
        /// `mem[mp + offset] = in()`
        in,
        /// `out(mem[mp + offset])`
        out,
        /// `out(value)`
        out_value,
        /// `if (mem[mp] == 0) pc += extra`
        ///
        /// Guaranteed to be balanced with `loop_end`.
        loop_start,
        /// `pc -= extra + 1`
        /// (set `pc` so that the next instruction executed is at `pc - extra`)
        ///
        /// Guaranteed to be balanced with `loop_start`.
        loop_end,
    };

    pub const Meta = struct {
        name: []const u8,
        value: ArgUsage,
        offset: ArgUsage,
        extra: ArgUsage,

        pub const ArgUsage = enum {
            unused,
            used,
            internal_only,
        };
    };

    pub const meta = meta: {
        var m = std.EnumArray(Tag, Meta).initUndefined();
        m.set(.halt, .{ .name = "halt", .value = .unused, .offset = .unused, .extra = .unused });
        m.set(.breakpoint, .{ .name = "breakpoint", .value = .unused, .offset = .unused, .extra = .unused });
        m.set(.set, .{ .name = "set", .value = .used, .offset = .used, .extra = .unused });
        m.set(.add, .{ .name = "add", .value = .used, .offset = .used, .extra = .unused });
        m.set(.add_mul, .{ .name = "add-mul", .value = .used, .offset = .used, .extra = .used });
        m.set(.move, .{ .name = "move", .value = .unused, .offset = .unused, .extra = .used });
        m.set(.seek, .{ .name = "seek", .value = .used, .offset = .used, .extra = .used });
        m.set(.in, .{ .name = "in", .value = .unused, .offset = .used, .extra = .unused });
        m.set(.out, .{ .name = "out", .value = .unused, .offset = .used, .extra = .unused });
        m.set(.out_value, .{ .name = "out-value", .value = .used, .offset = .unused, .extra = .unused });
        m.set(.loop_start, .{ .name = "loop-start", .value = .unused, .offset = .unused, .extra = .internal_only });
        m.set(.loop_end, .{ .name = "loop-end", .value = .unused, .offset = .unused, .extra = .internal_only });
        break :meta m;
    };
};

pub fn deinit(prog: *Prog, allocator: Allocator) void {
    prog.insts.deinit(allocator);
    prog.* = undefined;
}

pub fn parseBrainfuck(allocator: Allocator, source: []const u8) error{ ParseError, OutOfMemory }!Prog {
    var p: BrainfuckParser = .{ .source = source, .allocator = allocator };
    defer p.deinit();
    try p.parse();
    return .{ .insts = p.insts.toOwnedSlice() };
}

pub fn parseBytecodeText(allocator: Allocator, source: []const u8) error{ ParseError, OutOfMemory }!Prog {
    var p: BytecodeTextParser = .{ .source = source, .allocator = allocator };
    defer p.deinit();
    try p.parse();
    return .{ .insts = p.insts.toOwnedSlice() };
}

const Hash = std.crypto.hash.Md5;

pub fn hash(prog: Prog) [Hash.digest_length]u8 {
    var h = Hash.init(.{});
    for (
        prog.insts.items(.tag),
        prog.insts.items(.value),
        prog.insts.items(.offset),
        prog.insts.items(.extra),
    ) |tag, value, offset, extra| {
        h.update(mem.asBytes(&tag));
        h.update(mem.asBytes(&value));
        h.update(mem.asBytes(&offset));
        h.update(mem.asBytes(&extra));
    }
    var out: [Hash.digest_length]u8 = undefined;
    h.final(&out);
    return out;
}

pub const BytecodeTextStyle = struct {
    /// The number of spaces to use to indent loop bodies.
    indent: usize = 2,
    /// Whether to write out internal_only arguments as comments.
    show_internal: bool = false,
};

pub fn writeBytecodeText(prog: Prog, writer: anytype, style: BytecodeTextStyle) @TypeOf(writer).Error!void {
    var indent: usize = 0;
    for (
        prog.insts.items(.tag),
        prog.insts.items(.value),
        prog.insts.items(.offset),
        prog.insts.items(.extra),
    ) |tag, value, offset, extra| {
        if (tag == .loop_end) indent -= style.indent;
        const meta = Inst.meta.get(tag);
        try writer.writeByteNTimes(' ', indent);
        try writer.writeAll(meta.name);
        if (meta.value == .used) {
            try writer.print(" {}", .{@as(i8, @bitCast(value))});
        }
        if (meta.extra == .used) {
            if (meta.value == .used) try writer.writeByte(',');
            try writer.print(" {}", .{@as(i32, @bitCast(extra))});
        }
        if (meta.offset == .used and offset != 0) {
            try writer.print(" @ {}", .{@as(i32, @bitCast(offset))});
        }
        if (style.show_internal and meta.extra == .internal_only) {
            try writer.print(" # {}", .{@as(i32, @bitCast(extra))});
        }
        try writer.writeByte('\n');
        if (tag == .loop_start) indent += style.indent;
    }
}
