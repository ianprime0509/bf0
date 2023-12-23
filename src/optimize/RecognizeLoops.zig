//! An optimization that recognizes loops that can be reduced to simpler,
//! non-loop instructions.
//!
//! Specifically, it recognizes the following patterns:
//!
//! - Multiplication: `[->++>+++<<]`
//! - Set to 0: `[-]` (any odd increment)
//! - Seek 0: `[>>>]` (move direction and step may differ)

const std = @import("std");
const Allocator = std.mem.Allocator;
const Prog = @import("../Prog.zig");
const Inst = Prog.Inst;

insts: Inst.List = .{},
pending_loop_starts: std.ArrayListUnmanaged(u32) = .{},
allocator: Allocator,

const RecognizeLoops = @This();

pub fn pass(allocator: Allocator, prog: Prog) Allocator.Error!Prog {
    var o: RecognizeLoops = .{ .allocator = allocator };
    defer o.deinit();
    try o.apply(prog);
    return .{ .insts = o.insts.toOwnedSlice() };
}

fn deinit(o: *RecognizeLoops) void {
    o.insts.deinit(o.allocator);
    o.pending_loop_starts.deinit(o.allocator);
    o.* = undefined;
}

fn apply(o: *RecognizeLoops, prog: Prog) !void {
    const tags = prog.insts.items(.tag);
    const values = prog.insts.items(.value);
    const offsets = prog.insts.items(.offset);
    const extras = prog.insts.items(.extra);

    var i: u32 = 0;
    while (i < prog.insts.len) : (i += 1) {
        switch (tags[i]) {
            .halt,
            .set,
            .add,
            .add_mul,
            .in,
            .out,
            .move,
            .seek,
            => try o.insts.append(o.allocator, .{
                .tag = tags[i],
                .value = values[i],
                .offset = offsets[i],
                .extra = extras[i],
            }),
            .loop_start => {
                const loop_tags = tags[i + 1 .. i + extras[i]];
                const loop_values = values[i + 1 .. i + extras[i]];
                const loop_offsets = offsets[i + 1 .. i + extras[i]];
                const loop_extras = extras[i + 1 .. i + extras[i]];
                if (try o.processMathLoop(loop_tags, loop_values, loop_offsets) or
                    try o.processMoveLoop(loop_tags, loop_extras))
                {
                    i += extras[i];
                } else {
                    try o.startLoop();
                }
            },
            .loop_end => try o.endLoop(),
        }
    }
}

fn startLoop(o: *RecognizeLoops) !void {
    try o.pending_loop_starts.append(o.allocator, @intCast(o.insts.len));
    try o.insts.append(o.allocator, .{
        .tag = .loop_start,
        .value = undefined,
        .offset = undefined,
        .extra = undefined,
    });
}

fn endLoop(o: *RecognizeLoops) !void {
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

fn processMathLoop(
    o: *RecognizeLoops,
    tags: []const Inst.Tag,
    values: []const u8,
    offsets: []const u32,
) !bool {
    var incs: std.AutoArrayHashMapUnmanaged(u32, u8) = .{};
    defer incs.deinit(o.allocator);

    for (tags, values, offsets) |tag, value, offset| {
        switch (tag) {
            .halt,
            .set,
            .add_mul,
            .move,
            .seek,
            .in,
            .out,
            .loop_start,
            => return false,
            .loop_end => unreachable,
            .add => {
                const gop = try incs.getOrPut(o.allocator, offset);
                if (gop.found_existing) {
                    gop.value_ptr.* +%= value;
                } else {
                    gop.value_ptr.* = value;
                }
            },
        }
    }

    const base_add = (incs.fetchSwapRemove(0) orelse return false).value;
    if (base_add == 1 or base_add == 255) {
        // If the base offset change is 1 or -1, then the loop can be optimized
        // to multiplications for other cells. For example, `[->++<]` sets the
        // cell at offset 1 to 2 times the cell at offset 0 (and sets the cell
        // at offset 0 to 0).
        var inc_entries = incs.iterator();
        while (inc_entries.next()) |entry| {
            try o.insts.append(o.allocator, .{
                .tag = .add_mul,
                .value = -%base_add *% entry.value_ptr.*,
                .offset = entry.key_ptr.*,
                .extra = -%entry.key_ptr.*,
            });
        }
        try o.insts.append(o.allocator, .{
            .tag = .set,
            .value = 0,
            .offset = 0,
            .extra = undefined,
        });
        return true;
    } else if (base_add % 2 != 0 and incs.count() == 0) {
        // Loops which do nothing but add an odd number at offset 0 will
        // eventually terminate, resulting in a `set 0`. Adding an even number
        // may not terminate, so the optimization cannot be applied in that
        // case.
        try o.insts.append(o.allocator, .{
            .tag = .set,
            .value = 0,
            .offset = 0,
            .extra = undefined,
        });
        return true;
    } else {
        return false;
    }
}

fn processMoveLoop(
    o: *RecognizeLoops,
    tags: []const Inst.Tag,
    extras: []const u32,
) !bool {
    var step: u32 = 0;

    for (tags, extras) |tag, extra| {
        switch (tag) {
            .halt,
            .set,
            .add,
            .add_mul,
            .seek,
            .in,
            .out,
            .loop_start,
            .loop_end,
            => return false,
            .move => step +%= extra,
        }
    }

    try o.insts.append(o.allocator, .{
        .tag = .seek,
        .value = 0,
        .offset = 0,
        .extra = step,
    });
    return true;
}
