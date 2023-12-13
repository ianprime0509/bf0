const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Prog = @import("Prog.zig");
const Inst = Prog.Inst;

pub const passes: []const Pass = &.{ zeroLoops, offsetize };

pub const Pass = *const fn (Allocator, Prog) Allocator.Error!Prog;

/// Optimizes the common `[-]` pattern or equivalent to a `set 0`.
pub fn zeroLoops(allocator: Allocator, prog: Prog) Allocator.Error!Prog {
    var insts: Inst.List = .{};
    defer insts.deinit(allocator);
    var pending_loop_starts: std.ArrayListUnmanaged(u32) = .{};
    defer pending_loop_starts.deinit(allocator);

    const tags = prog.insts.items(.tag);
    const values = prog.insts.items(.value);
    const offsets = prog.insts.items(.offset);
    var i: u32 = 0;
    while (i < prog.insts.len) : (i += 1) {
        switch (tags[i]) {
            .loop_start => {
                if (offsets[i] == 2 and
                    tags[i + 1] == .add and
                    offsets[i + 1] == 0 and
                    values[i + 1] % 2 != 0)
                {
                    // The optimization is only guaranteed to be valid when the
                    // added value is odd, which will be coprime with the cell
                    // size (a power of 2) and hence will always eventually loop
                    // back to 0.
                    try insts.append(allocator, .{
                        .tag = .set,
                        .value = 0,
                        .offset = 0,
                    });
                    i += offsets[i];
                } else {
                    try pending_loop_starts.append(allocator, @intCast(insts.len));
                    try insts.append(allocator, .{
                        .tag = .loop_start,
                        .value = undefined,
                        .offset = undefined,
                    });
                }
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
            else => try insts.append(allocator, .{
                .tag = tags[i],
                .value = values[i],
                .offset = offsets[i],
            }),
        }
    }

    return .{ .insts = insts.toOwnedSlice() };
}

/// Converts sequences of moves and offsetable instructions to offset
/// instructions and at most one move.
///
/// For example, `++>++<<<++` can be optimized to
///
/// ```
/// add 2
/// add 2 @ 1
/// add 2 @ -2
/// move -2
/// ```
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
            .set, .add, .in, .out => try insts.append(allocator, .{
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
