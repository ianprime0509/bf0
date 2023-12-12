const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Prog = @import("Prog.zig");
const Inst = Prog.Inst;

pub const passes: []const Pass = &.{offsetize};

pub const Pass = *const fn (Allocator, Prog) Allocator.Error!Prog;

pub fn offsetize(allocator: Allocator, prog: Prog) Allocator.Error!Prog {
    var insts: Inst.List = .{};
    defer insts.deinit(allocator);
    var pending_loop_starts: std.ArrayListUnmanaged(u32) = .{};
    defer pending_loop_starts.deinit(allocator);

    var current_offset: u32 = 0;
    for (
        prog.insts.items(.tag),
        prog.insts.items(.value),
        prog.insts.items(.offset),
    ) |tag, value, offset| {
        switch (tag) {
            .add, .in, .out => try insts.append(allocator, .{
                .tag = tag,
                .value = value,
                .offset = offset +% current_offset,
            }),
            .move => current_offset +%= offset,
            .halt, .loop_start, .loop_end => {
                if (current_offset != 0) {
                    try insts.append(allocator, .{
                        .tag = .move,
                        .value = undefined,
                        .offset = current_offset,
                    });
                    current_offset = 0;
                }
                switch (tag) {
                    .halt => try insts.append(allocator, .{
                        .tag = .halt,
                        .value = undefined,
                        .offset = undefined,
                    }),
                    .loop_start => {
                        try pending_loop_starts.append(allocator, @intCast(insts.len));
                        try insts.append(allocator, .{
                            .tag = .loop_start,
                            .value = undefined,
                            .offset = undefined,
                        });
                    },
                    .loop_end => {
                        const pos: u32 = @intCast(insts.len);
                        const start = pending_loop_starts.pop();
                        insts.items(.offset)[start] = pos - start;
                        try insts.append(allocator, .{
                            .tag = .loop_end,
                            .value = undefined,
                            .offset = start -% pos,
                        });
                    },
                    else => unreachable,
                }
            },
        }
    }

    return .{ .insts = insts.toOwnedSlice() };
}
