const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Prog = @import("Prog.zig");
const Inst = Prog.Inst;

const condense = @import("optimize/Condense.zig").pass;

pub const passes: []const Pass = &.{ zeroLoops, condense, mulLoops, condense };

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
    const extras = prog.insts.items(.extra);
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
                        .extra = undefined,
                    });
                    i += offsets[i];
                } else {
                    try pending_loop_starts.append(allocator, @intCast(insts.len));
                    try insts.append(allocator, .{
                        .tag = .loop_start,
                        .value = undefined,
                        .offset = undefined,
                        .extra = undefined,
                    });
                }
            },
            .loop_end => {
                const pos: u32 = @intCast(insts.len);
                const start = pending_loop_starts.pop();
                insts.items(.extra)[start] = pos - start;
                try insts.append(allocator, .{
                    .tag = .loop_end,
                    .value = undefined,
                    .offset = undefined,
                    .extra = start -% pos,
                });
            },
            else => try insts.append(allocator, .{
                .tag = tags[i],
                .value = values[i],
                .offset = offsets[i],
                .extra = extras[i],
            }),
        }
    }

    return .{ .insts = insts.toOwnedSlice() };
}

/// Optimizes multiplication loops.
///
/// For example, `[->>+++<++]` can be optimized to
///
/// ```
/// add-mul 3 * -2 @ 2
/// add-mul 2 * -1 @ 1
/// set 0
/// ```
pub fn mulLoops(allocator: Allocator, prog: Prog) Allocator.Error!Prog {
    var insts: Inst.List = .{};
    defer insts.deinit(allocator);
    var pending_loop_starts: std.ArrayListUnmanaged(u32) = .{};
    defer pending_loop_starts.deinit(allocator);

    const tags = prog.insts.items(.tag);
    const values = prog.insts.items(.value);
    const offsets = prog.insts.items(.offset);
    const extras = prog.insts.items(.extra);
    var i: u32 = 0;
    translation: while (i < prog.insts.len) : (i += 1) {
        switch (tags[i]) {
            .loop_start => {
                var increments: std.AutoArrayHashMapUnmanaged(u32, u8) = .{};
                defer increments.deinit(allocator);
                var j = i + 1;
                while (j < i + offsets[i]) : (j += 1) {
                    if (tags[j] != .add) {
                        // For simplicity, this optimization assumes an
                        // offsetized input, so only loops with purely add
                        // instructions qualify.
                        try pending_loop_starts.append(allocator, @intCast(insts.len));
                        try insts.append(allocator, .{
                            .tag = .loop_start,
                            .value = undefined,
                            .offset = undefined,
                            .extra = undefined,
                        });
                        continue :translation;
                    }
                    const gop = try increments.getOrPut(allocator, offsets[j]);
                    if (!gop.found_existing) gop.value_ptr.* = 0;
                    gop.value_ptr.* +%= values[j];
                }
                if (increments.get(0) orelse 0 != 255) {
                    // The increment on the current cell per loop must be -1.
                    try pending_loop_starts.append(allocator, @intCast(insts.len));
                    try insts.append(allocator, .{
                        .tag = .loop_start,
                        .value = undefined,
                        .offset = undefined,
                        .extra = undefined,
                    });
                    continue :translation;
                }
                // At this point, the optimization applies.
                try insts.ensureUnusedCapacity(allocator, increments.count());
                var inc_entries = increments.iterator();
                while (inc_entries.next()) |entry| {
                    if (entry.key_ptr.* == 0) continue;
                    insts.appendAssumeCapacity(.{
                        .tag = .add_mul,
                        .value = entry.value_ptr.*,
                        .offset = entry.key_ptr.*,
                        .extra = -%entry.key_ptr.*,
                    });
                }
                insts.appendAssumeCapacity(.{
                    .tag = .set,
                    .value = 0,
                    .offset = 0,
                    .extra = undefined,
                });
                i += offsets[i];
            },
            .loop_end => {
                const pos: u32 = @intCast(insts.len);
                const start = pending_loop_starts.pop();
                insts.items(.extra)[start] = pos - start;
                try insts.append(allocator, .{
                    .tag = .loop_end,
                    .value = undefined,
                    .offset = undefined,
                    .extra = start -% pos,
                });
            },
            else => try insts.append(allocator, .{
                .tag = tags[i],
                .value = values[i],
                .offset = offsets[i],
                .extra = extras[i],
            }),
        }
    }

    return .{ .insts = insts.toOwnedSlice() };
}
