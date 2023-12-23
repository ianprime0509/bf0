const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Parser = @import("Prog/Parser.zig");

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
};

pub fn deinit(prog: *Prog, allocator: Allocator) void {
    prog.insts.deinit(allocator);
    prog.* = undefined;
}

pub fn parse(allocator: Allocator, source: []const u8) error{ ParseError, OutOfMemory }!Prog {
    var p: Parser = .{ .source = source, .allocator = allocator };
    defer p.deinit();
    try p.parse();
    return .{ .insts = p.insts.toOwnedSlice() };
}

pub fn dump(prog: Prog, writer: anytype) @TypeOf(writer).Error!void {
    for (
        prog.insts.items(.tag),
        prog.insts.items(.value),
        prog.insts.items(.offset),
        prog.insts.items(.extra),
    ) |tag, value, offset, extra| {
        switch (tag) {
            .halt => try writer.writeAll("halt\n"),
            .set => try writer.print("set {} @ {}\n", .{ @as(i8, @bitCast(value)), @as(i32, @bitCast(offset)) }),
            .add => try writer.print("add {} @ {}\n", .{ @as(i8, @bitCast(value)), @as(i32, @bitCast(offset)) }),
            .add_mul => try writer.print("add-mul {}, {} @ {}\n", .{ @as(i8, @bitCast(value)), @as(i32, @bitCast(extra)), @as(i32, @bitCast(offset)) }),
            .move => try writer.print("move {}\n", .{@as(i32, @bitCast(extra))}),
            .seek => try writer.print("seek {}, {} @ {}\n", .{ @as(i8, @bitCast(value)), @as(i32, @bitCast(extra)), @as(i32, @bitCast(offset)) }),
            .in => try writer.print("in @ {}\n", .{@as(i32, @bitCast(offset))}),
            .out => try writer.print("out @ {}\n", .{@as(i32, @bitCast(offset))}),
            .loop_start => try writer.print("loop-start # -> {}\n", .{extra}),
            .loop_end => try writer.print("loop-end # -> -{}\n", .{-%extra}),
        }
    }
}
