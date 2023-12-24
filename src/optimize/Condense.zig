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
//!
//! The optimization also keeps track of known values, including the known
//! initial 0 values for unset cells, so that an `add 1` at the beginning of a
//! program can be optimized to `set 1` (this also allows other constant-based
//! optimizations such as removing "header comment" loops).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Prog = @import("../Prog.zig");
const Inst = Prog.Inst;
const testOptimize = @import("testing.zig").testOptimize;

insts: Inst.List = .{},
pending_loop_starts: std.ArrayListUnmanaged(u32) = .{},
pending_move: u32 = 0,
/// If non-null, any cells not described in `ops` and not present in this set
/// can be assumed to be 0 (the initial value of every cell).
start_clobbers: ?std.AutoHashMapUnmanaged(u32, void) = .{},
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
    if (o.start_clobbers) |*m| m.deinit(o.allocator);
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
        const eff_offset = o.pending_move +% offset;
        switch (tag) {
            // Pending ops have no side effects, so they can be discarded when
            // the program halts.
            .halt => try o.insts.append(o.allocator, .{
                .tag = .halt,
                .value = value,
                .offset = offset,
                .extra = extra,
            }),
            .breakpoint => {
                try o.flushOps();
                try o.flushPendingMove();
                try o.insts.append(o.allocator, .{
                    .tag = .breakpoint,
                    .value = value,
                    .offset = offset,
                    .extra = extra,
                });
            },
            .set => try o.setValue(eff_offset, value),
            .add => try o.addValue(eff_offset, value),
            .add_mul => {
                const src_offset = eff_offset +% extra;
                if (o.getKnownValue(src_offset)) |src_value| {
                    try o.addValue(eff_offset, value *% src_value);
                } else {
                    try o.flushOpAt(eff_offset);
                    try o.flushOpAt(src_offset);
                    try o.insts.append(o.allocator, .{
                        .tag = .add_mul,
                        .value = value,
                        .offset = eff_offset,
                        .extra = extra,
                    });
                }
            },
            .move => o.pending_move +%= extra,
            .seek => {
                if (o.getKnownValue(eff_offset)) |v| {
                    if (v == value) {
                        // The seek can be skipped if we know we're already
                        // looking at the desired value. The pending move is
                        // still removed.
                        o.pending_move = 0;
                        continue;
                    }
                }
                try o.flushOps();
                try o.insts.append(o.allocator, .{
                    .tag = .seek,
                    .value = value,
                    .offset = eff_offset,
                    .extra = extra,
                });
                // The seek removes any pending move; the pending move prior to
                // the seek is incorporated into the seek's offset.
                o.pending_move = 0;
            },
            .in => {
                // Any operation on the input cell is clobbered by the input
                // instruction, so doesn't need to be flushed.
                try o.clobberOpAt(eff_offset);
                try o.insts.append(o.allocator, .{
                    .tag = .in,
                    .value = value,
                    .offset = eff_offset,
                    .extra = extra,
                });
            },
            .out => {
                if (o.getKnownValue(eff_offset)) |v| {
                    try o.insts.append(o.allocator, .{
                        .tag = .out_value,
                        .value = v,
                        .offset = undefined,
                        .extra = undefined,
                    });
                    continue;
                }
                try o.flushOpAt(eff_offset);
                try o.insts.append(o.allocator, .{
                    .tag = .out,
                    .value = value,
                    .offset = eff_offset,
                    .extra = extra,
                });
            },
            .out_value => try o.insts.append(o.allocator, .{
                .tag = .out_value,
                .value = value,
                .offset = offset,
                .extra = extra,
            }),
            .loop_start => {
                if (o.getKnownValue(o.pending_move)) |v| {
                    if (v == 0) {
                        // This loop is dead code since the condition is known
                        // to be false.
                        i += extra;
                        continue;
                    }
                }
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

/// Returns the known value of `offset`, if any.
fn getKnownValue(o: Condense, offset: u32) ?u8 {
    if (o.ops.get(offset)) |op| {
        return switch (op) {
            .known_value, .set => |v| v,
            .add => null,
        };
    } else if (o.start_clobbers) |start_clobbers| {
        return if (start_clobbers.contains(offset)) null else 0;
    } else {
        return null;
    }
}

/// Adds or modifies an op to set the value of `offset` to `value`.
fn setValue(o: *Condense, offset: u32, value: u8) !void {
    // We do not need to emit a set instruction if the cell value is already
    // known to be `value`.
    if (o.getKnownValue(offset) != value) {
        try o.ops.put(o.allocator, offset, .{ .set = value });
        if (o.start_clobbers) |*start_clobbers| {
            try start_clobbers.put(o.allocator, offset, {});
        }
    }
}

/// Adds or modifies an op to add `value` to `offset`.
fn addValue(o: *Condense, offset: u32, value: u8) !void {
    const gop = try o.ops.getOrPut(o.allocator, offset);
    if (gop.found_existing) {
        gop.value_ptr.* = switch (gop.value_ptr.*) {
            .known_value, .set => |v| .{ .set = v +% value },
            .add => |v| .{ .add = v +% value },
        };
    } else if (o.start_clobbers) |*start_clobbers| {
        if (start_clobbers.contains(offset)) {
            gop.value_ptr.* = .{ .add = value };
        } else {
            gop.value_ptr.* = .{ .set = value };
            try start_clobbers.put(o.allocator, offset, {});
        }
    } else {
        gop.value_ptr.* = .{ .add = value };
    }
}

/// Flushes the effects of `pending_move` and resets it to 0.
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

/// Clobbers (removes) the op at `offset`, without flushing it.
fn clobberOpAt(o: *Condense, offset: u32) !void {
    _ = o.ops.swapRemove(offset);
    if (o.start_clobbers) |*start_clobbers| {
        try start_clobbers.put(o.allocator, offset, {});
    }
}

/// Flushes the effects of `op`.
fn flushOp(o: *Condense, offset: u32, op: Op) !void {
    if (o.start_clobbers) |*start_clobbers| {
        try start_clobbers.put(o.allocator, offset, {});
    }
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

/// Flushes and removes the op at `offset`.
fn flushOpAt(o: *Condense, offset: u32) !void {
    if (o.ops.fetchSwapRemove(offset)) |entry| {
        try o.flushOp(entry.key, entry.value);
    }
}

/// Flushes and removes all ops.
fn flushOps(o: *Condense) !void {
    var ops = o.ops.iterator();
    while (ops.next()) |entry| {
        try o.flushOp(entry.key_ptr.*, entry.value_ptr.*);
    }
    o.ops.clearRetainingCapacity();
    if (o.start_clobbers) |*start_clobbers| {
        start_clobbers.deinit(o.allocator);
        o.start_clobbers = null;
    }
}

// Note: in many of the tests below, the breakpoint instruction is used as an
// optimization barrier (e.g. to ensure cell mutations are not optimized away).

test "coalesce arithmetic" {
    try testOptimize(pass,
        \\breakpoint
        \\add 1
        \\add 2
        \\add 3
        \\set 5 @ 1
        \\add 10 @ 1
        \\add 4
        \\set 0 @ 2
        \\set 5 @ 3
        \\add-mul 6, 1 @ 2
        \\breakpoint
    ,
        \\breakpoint
        \\add 10
        \\set 15 @ 1
        \\set 30 @ 2
        \\set 5 @ 3
        \\breakpoint
    );
}

test "coalesce moves" {
    try testOptimize(pass,
        \\breakpoint
        \\add 1
        \\move 1
        \\add 2
        \\move 4
        \\add 3
        \\move -5
        \\add 4
        \\move 2
        \\out
        \\in
        \\breakpoint
    ,
        \\breakpoint
        \\out @ 2
        \\in @ 2
        \\add 5
        \\add 2 @ 1
        \\add 3 @ 5
        \\move 2
        \\breakpoint
    );
}

test "initial cells known to be 0" {
    try testOptimize(pass,
        \\add 2
        \\add-mul 5, -1 @ 1
        \\add 3 @ 2
        \\add-mul 10, -2 @ 2
        \\in @ 3
        \\add 5 @ 4
        \\add-mul 10, -1 @ 1
        \\out @ 4
        \\add 5 @ 4
        \\breakpoint
    ,
        \\in @ 3
        \\out-value 5
        \\set 2
        \\set 30 @ 1
        \\set 23 @ 2
        \\set 10 @ 4
        \\breakpoint
    );
}

test "useless add/set optimized out" {
    try testOptimize(pass,
        \\breakpoint
        \\add 5
        \\add 6 @ 1
        \\add 7 @ 2
        \\out
        \\set 100
        \\add 6 @ 1
        \\halt
    ,
        \\breakpoint
        \\add 5
        \\out
        \\halt
    );
}
