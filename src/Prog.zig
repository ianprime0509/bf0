const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

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
        /// `mp += offset`
        move,
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
    var insts: std.MultiArrayList(Inst) = .{};
    defer insts.deinit(allocator);
    var pending_loop_starts: std.ArrayListUnmanaged(u32) = .{};
    defer pending_loop_starts.deinit(allocator);
    var current_op: union(enum) {
        none,
        add: u8,
        move: u32,
    } = .none;
    for (source) |c| {
        switch (c) {
            '+', '-' => {
                const inc: u8 = if (c == '+') 1 else @bitCast(@as(i8, -1));
                switch (current_op) {
                    .none => current_op = .{ .add = inc },
                    .add => |*value| value.* +%= inc,
                    .move => |offset| {
                        try insts.append(allocator, .{
                            .tag = .move,
                            .value = undefined,
                            .offset = offset,
                            .extra = undefined,
                        });
                        current_op = .{ .add = inc };
                    },
                }
            },
            '>', '<' => {
                const inc: u32 = if (c == '>') 1 else @bitCast(@as(i32, -1));
                switch (current_op) {
                    .none => current_op = .{ .move = inc },
                    .add => |value| {
                        try insts.append(allocator, .{
                            .tag = .add,
                            .value = value,
                            .offset = 0,
                            .extra = undefined,
                        });
                        current_op = .{ .move = inc };
                    },
                    .move => |*offset| offset.* +%= inc,
                }
            },
            ',', '.', '[', ']' => {
                switch (current_op) {
                    .none => {},
                    .add => |value| {
                        try insts.append(allocator, .{
                            .tag = .add,
                            .value = value,
                            .offset = 0,
                            .extra = undefined,
                        });
                        current_op = .none;
                    },
                    .move => |offset| {
                        try insts.append(allocator, .{
                            .tag = .move,
                            .value = undefined,
                            .offset = offset,
                            .extra = undefined,
                        });
                    },
                }
                current_op = .none;
                switch (c) {
                    ',' => try insts.append(allocator, .{
                        .tag = .in,
                        .value = undefined,
                        .offset = 0,
                        .extra = undefined,
                    }),
                    '.' => try insts.append(allocator, .{
                        .tag = .out,
                        .value = undefined,
                        .offset = 0,
                        .extra = undefined,
                    }),
                    '[' => {
                        const index: u32 = @intCast(insts.len);
                        try insts.append(allocator, .{
                            .tag = .loop_start,
                            .value = undefined,
                            .offset = undefined,
                            .extra = undefined,
                        });
                        try pending_loop_starts.append(allocator, index);
                    },
                    ']' => {
                        const loop_start = pending_loop_starts.popOrNull() orelse return error.ParseError;
                        const index: u32 = @intCast(insts.len);
                        insts.items(.extra)[loop_start] = index - loop_start;
                        try insts.append(allocator, .{
                            .tag = .loop_end,
                            .value = undefined,
                            .offset = undefined,
                            .extra = loop_start -% index,
                        });
                    },
                    else => unreachable,
                }
            },
            else => {},
        }
    }

    switch (current_op) {
        .none => {},
        .add => |value| {
            try insts.append(allocator, .{
                .tag = .add,
                .value = value,
                .offset = 0,
                .extra = undefined,
            });
            current_op = .none;
        },
        .move => |offset| {
            try insts.append(allocator, .{
                .tag = .move,
                .value = undefined,
                .offset = offset,
                .extra = undefined,
            });
        },
    }
    try insts.append(allocator, .{
        .tag = .halt,
        .value = undefined,
        .offset = undefined,
        .extra = undefined,
    });

    return .{
        .insts = insts.toOwnedSlice(),
    };
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
            .add_mul => try writer.print("add-mul {} * {} @ {}\n", .{ @as(i8, @bitCast(value)), @as(i32, @bitCast(extra)), @as(i32, @bitCast(offset)) }),
            .move => try writer.print("move {}\n", .{@as(i32, @bitCast(offset))}),
            .in => try writer.print("in @ {}\n", .{@as(i32, @bitCast(offset))}),
            .out => try writer.print("out @ {}\n", .{@as(i32, @bitCast(offset))}),
            .loop_start => try writer.print("loop-start -> {}\n", .{extra}),
            .loop_end => try writer.print("loop-end -> -{} \n", .{-%extra}),
        }
    }
}
