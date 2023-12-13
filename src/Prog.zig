const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

insts: Inst.List.Slice,

const Prog = @This();

pub const Inst = struct {
    tag: Tag,
    value: u8,
    offset: u32,

    pub const List = std.MultiArrayList(Inst);

    pub const Tag = enum {
        /// `value` and `offset` are undefined.
        halt,
        /// `value` is the value to set to.
        /// `offset` is used.
        set,
        /// `value` is the value to add.
        /// `offset` is used.
        add,
        /// `value` is undefined.
        /// `offset` is used.
        move,
        /// `value` is undefined.
        /// `offset` is used (the cell to read to).
        in,
        /// `value` is undefined.
        /// `offset` is used (the cell to write).
        out,
        /// `value` is undefined.
        /// `offset` is used (the matching `loop_end`).
        loop_start,
        /// `value` is undefined.
        /// `offset` is used (the matching `loop_start`).
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
                        });
                        current_op = .none;
                    },
                    .move => |offset| {
                        try insts.append(allocator, .{
                            .tag = .move,
                            .value = undefined,
                            .offset = offset,
                        });
                    },
                }
                current_op = .none;
                switch (c) {
                    ',' => try insts.append(allocator, .{
                        .tag = .in,
                        .value = undefined,
                        .offset = 0,
                    }),
                    '.' => try insts.append(allocator, .{
                        .tag = .out,
                        .value = undefined,
                        .offset = 0,
                    }),
                    '[' => {
                        const index: u32 = @intCast(insts.len);
                        try insts.append(allocator, .{
                            .tag = .loop_start,
                            .value = undefined,
                            .offset = undefined,
                        });
                        try pending_loop_starts.append(allocator, index);
                    },
                    ']' => {
                        const loop_start = pending_loop_starts.popOrNull() orelse return error.ParseError;
                        const index: u32 = @intCast(insts.len);
                        insts.items(.offset)[loop_start] = index - loop_start;
                        try insts.append(allocator, .{
                            .tag = .loop_end,
                            .value = undefined,
                            .offset = loop_start -% index,
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
            });
            current_op = .none;
        },
        .move => |offset| {
            try insts.append(allocator, .{
                .tag = .move,
                .value = undefined,
                .offset = offset,
            });
        },
    }
    try insts.append(allocator, .{
        .tag = .halt,
        .value = undefined,
        .offset = undefined,
    });

    return .{
        .insts = insts.toOwnedSlice(),
    };
}

pub fn dump(prog: Prog, writer: anytype) @TypeOf(writer).Error!void {
    const tags = prog.insts.items(.tag);
    const values = prog.insts.items(.value);
    const offsets = prog.insts.items(.offset);
    for (tags, values, offsets) |tag, value, offset| {
        switch (tag) {
            .halt => try writer.writeAll("halt\n"),
            .set => try writer.print("set {} @ {}\n", .{ @as(i8, @bitCast(value)), @as(i32, @bitCast(offset)) }),
            .add => try writer.print("add {} @ {}\n", .{ @as(i8, @bitCast(value)), @as(i32, @bitCast(offset)) }),
            .move => try writer.print("move {}\n", .{@as(i32, @bitCast(offset))}),
            .in => try writer.print("in @ {}\n", .{@as(i32, @bitCast(offset))}),
            .out => try writer.print("out @ {}\n", .{@as(i32, @bitCast(offset))}),
            .loop_start => try writer.print("loop-start -> {}\n", .{offset}),
            .loop_end => try writer.print("loop-end -> -{} \n", .{-%offset}),
        }
    }
}
