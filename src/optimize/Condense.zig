//! An optimization that condenses a program's instructions by keeping track of
//! repeated operations, known values, and their consequences on subsequent
//! code.
//!
//! The effects of set and add instructions are maintained as "ops", in a map
//! keyed by offsets from the current position on the tape. Known values are
//! also tracked as ops, but do not result in any additional instructions being
//! emitted. For example, a `set 0` followed by an `add 2` can be optimized to a
//! `set 2` using this approach.
//!
//! The current effect of move instructions is also maintained as `pending_move`,
//! and only one move instruction is emitted when necessary. Other instructions
//! emitted until the pending move is flushed are offset by the pending move
//! amount. For example, the program `+>>-<+` can be optimized to
//!
//! ```
//! add 1
//! add -1 @ 2
//! add 1 @ 1
//! move 1
//! ```
//!
//! which is one instruction shorter than the naive translation.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Prog = @import("../Prog.zig");
const Inst = Prog.Inst;

insts: Inst.List = .{},
pending_loop_starts: std.ArrayListUnmanaged(u32) = .{},
pending_move: u32 = 0,
ops: std.AutoArrayHashMapUnmanaged(u32, Op) = .{},
allocator: Allocator,

const Condense = @This();

const Op = union(enum) {
    known_value: u8,
    set: u8,
    add: u8,
};

pub fn pass(allocator: Allocator, prog: Prog) Allocator.Error!Prog {
    var o: Condense = .{ .allocator = allocator };
    defer o.deinit();
    try o.apply(prog);
    return .{ .insts = o.insts.toOwnedSlice() };
}

fn deinit(o: *Condense) void {
    o.insts.deinit(o.allocator);
    o.pending_loop_starts.deinit(o.allocator);
    o.ops.deinit(o.allocator);
    o.* = undefined;
}

fn apply(o: *Condense, prog: Prog) !void {
    const tags = prog.insts.items(.tag);
    const values = prog.insts.items(.value);
    const offsets = prog.insts.items(.offset);
    const extras = prog.insts.items(.extra);

    var i: u32 = 0;
    while (i < prog.insts.len) : (i += 1) {
        const tag = tags[i];
        const value = values[i];
        const offset = offsets[i];
        const extra = extras[i];
        switch (tag) {
            // Pending ops have no side effects, so they can be discarded when
            // the program halts.
            .halt => try o.insts.append(o.allocator, .{
                .tag = .halt,
                .value = value,
                .offset = offset,
                .extra = extra,
            }),
            .set => try o.setValue(o.pending_move +% offset, value),
            .add => try o.addValue(o.pending_move +% offset, value),
            .add_mul => {
                const dest_offset = o.pending_move +% offset;
                const src_offset = dest_offset +% extra;
                if (o.ops.get(src_offset)) |src| {
                    switch (src) {
                        .known_value, .set => |v| try o.addValue(dest_offset, value *% v),
                        .add => {
                            // This dependency is too complex to express
                            // effectively. We need to flush both the source op
                            // and any op at the destination, but other ops can
                            // remain active.
                            try o.flushOpAt(dest_offset);
                            try o.flushOpAt(src_offset);
                            try o.insts.append(o.allocator, .{
                                .tag = .add_mul,
                                .value = value,
                                .offset = o.pending_move +% offset,
                                .extra = extra,
                            });
                        },
                    }
                } else {
                    // There is no op at the source cell to flush, but we may
                    // need to flush the destination cell op, since we have no
                    // op for the add-mul operation.
                    try o.flushOpAt(dest_offset);
                    try o.insts.append(o.allocator, .{
                        .tag = .add_mul,
                        .value = value,
                        .offset = o.pending_move +% offset,
                        .extra = extra,
                    });
                }
            },
            .move => o.pending_move +%= extra,
            .seek => {
                if (o.ops.get(o.pending_move +% offset)) |op| switch (op) {
                    .known_value, .set => |v| if (v == value) {
                        // The seek can be skipped if we know we're already
                        // looking at the desired value. The pending move is
                        // still removed.
                        o.pending_move = 0;
                        continue;
                    },
                    .add => {},
                };
                try o.flushOps();
                try o.insts.append(o.allocator, .{
                    .tag = .seek,
                    .value = value,
                    .offset = o.pending_move +% offset,
                    .extra = extra,
                });
                // The seek removes any pending move; the pending move prior to
                // the seek is incorporated into the seek's offset.
                o.pending_move = 0;
            },
            .in => {
                // Any operation on the input cell is clobbered by the input
                // instruction, so doesn't need to be flushed.
                _ = o.ops.swapRemove(o.pending_move +% offset);
                try o.insts.append(o.allocator, .{
                    .tag = .in,
                    .value = value,
                    .offset = o.pending_move +% offset,
                    .extra = extra,
                });
            },
            .out => {
                if (o.ops.fetchSwapRemove(o.pending_move +% offset)) |entry| {
                    try o.flushOp(entry.key, entry.value);
                    switch (entry.value) {
                        .known_value, .set => |v| try o.ops.put(o.allocator, entry.key, .{
                            .known_value = v,
                        }),
                        .add => {},
                    }
                }
                try o.insts.append(o.allocator, .{
                    .tag = .out,
                    .value = value,
                    .offset = o.pending_move +% offset,
                    .extra = extra,
                });
            },
            .loop_start => {
                if (o.ops.get(o.pending_move)) |op| switch (op) {
                    .known_value, .set => |v| if (v == 0) {
                        // Eliminate the loop entirely as dead code.
                        i += extra;
                        continue;
                    },
                    .add => {},
                };
                try o.flushOps();
                try o.flushPendingMove();
                try o.startLoop();
            },
            .loop_end => {
                try o.flushOps();
                try o.flushPendingMove();
                try o.endLoop();
                // The value of the current cell is guaranteed to be 0 after a
                // loop end by definition.
                try o.ops.put(o.allocator, 0, .{ .known_value = 0 });
            },
        }
    }
}

fn startLoop(o: *Condense) !void {
    try o.pending_loop_starts.append(o.allocator, @intCast(o.insts.len));
    try o.insts.append(o.allocator, .{
        .tag = .loop_start,
        .value = undefined,
        .offset = undefined,
        .extra = undefined,
    });
}

fn endLoop(o: *Condense) !void {
    const pos: u32 = @intCast(o.insts.len);
    const start = o.pending_loop_starts.pop();
    o.insts.items(.extra)[start] = pos - start;
    try o.insts.append(o.allocator, .{
        .tag = .loop_end,
        .value = undefined,
        .offset = undefined,
        .extra = start -% pos,
    });
}

fn setValue(o: *Condense, offset: u32, value: u8) !void {
    const gop = try o.ops.getOrPut(o.allocator, offset);
    // We do not need to emit a set instruction if the cell value is already
    // known to be `value`.
    if (!gop.found_existing or
        gop.value_ptr.* != .known_value or
        gop.value_ptr.known_value != value)
    {
        gop.value_ptr.* = .{ .set = value };
    }
}

fn addValue(o: *Condense, offset: u32, value: u8) !void {
    const gop = try o.ops.getOrPut(o.allocator, offset);
    if (gop.found_existing) {
        gop.value_ptr.* = switch (gop.value_ptr.*) {
            .known_value, .set => |v| .{ .set = v +% value },
            .add => |v| .{ .add = v +% value },
        };
    } else {
        gop.value_ptr.* = .{ .add = value };
    }
}

fn flushPendingMove(o: *Condense) !void {
    if (o.pending_move != 0) {
        try o.insts.append(o.allocator, .{
            .tag = .move,
            .value = undefined,
            .offset = undefined,
            .extra = o.pending_move,
        });
        o.pending_move = 0;
    }
}

fn flushOp(o: *Condense, offset: u32, op: Op) !void {
    switch (op) {
        .known_value => {},
        .set => |value| try o.insts.append(o.allocator, .{
            .tag = .set,
            .value = value,
            .offset = offset,
            .extra = undefined,
        }),
        .add => |value| if (value != 0) try o.insts.append(o.allocator, .{
            .tag = .add,
            .value = value,
            .offset = offset,
            .extra = undefined,
        }),
    }
}

fn flushOpAt(o: *Condense, offset: u32) !void {
    if (o.ops.fetchSwapRemove(offset)) |entry| {
        try o.flushOp(entry.key, entry.value);
    }
}

fn flushOps(o: *Condense) !void {
    var ops = o.ops.iterator();
    while (ops.next()) |entry| {
        try o.flushOp(entry.key_ptr.*, entry.value_ptr.*);
    }
    o.ops.clearRetainingCapacity();
}
