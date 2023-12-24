const std = @import("std");
const Allocator = std.mem.Allocator;
const Prog = @import("../Prog.zig");
const Inst = Prog.Inst;

source: []const u8,
insts: Inst.List = .{},
pending_loop_starts: std.ArrayListUnmanaged(u32) = .{},
current_op: union(enum) {
    none,
    add: u8,
    move: u32,
} = .none,
allocator: Allocator,

const Parser = @This();

pub fn deinit(p: *Parser) void {
    p.insts.deinit(p.allocator);
    p.pending_loop_starts.deinit(p.allocator);
    p.* = undefined;
}

pub fn parse(p: *Parser) error{ ParseError, OutOfMemory }!void {
    for (p.source) |c| {
        switch (c) {
            '+' => try p.add(1),
            '-' => try p.add(@bitCast(@as(i8, -1))),
            '>' => try p.move(1),
            '<' => try p.move(@bitCast(@as(i32, -1))),
            ',' => {
                try p.flushOp();
                try p.insts.append(p.allocator, .{
                    .tag = .in,
                    .value = undefined,
                    .offset = 0,
                    .extra = undefined,
                });
            },
            '.' => {
                try p.flushOp();
                try p.insts.append(p.allocator, .{
                    .tag = .out,
                    .value = undefined,
                    .offset = 0,
                    .extra = undefined,
                });
            },
            '[' => try p.startLoop(),
            ']' => try p.endLoop(),
            '#' => {
                try p.flushOp();
                try p.insts.append(p.allocator, .{
                    .tag = .breakpoint,
                    .value = undefined,
                    .offset = undefined,
                    .extra = undefined,
                });
            },
            else => {},
        }
    }

    try p.flushOp();

    try p.insts.append(p.allocator, .{
        .tag = .halt,
        .value = undefined,
        .offset = undefined,
        .extra = undefined,
    });
}

fn add(p: *Parser, inc: u8) !void {
    switch (p.current_op) {
        .none => p.current_op = .{ .add = inc },
        .add => |*value| value.* +%= inc,
        .move => {
            try p.flushOp();
            p.current_op = .{ .add = inc };
        },
    }
}

fn move(p: *Parser, inc: u32) !void {
    switch (p.current_op) {
        .none => p.current_op = .{ .move = inc },
        .add => {
            try p.flushOp();
            p.current_op = .{ .move = inc };
        },
        .move => |*amount| amount.* +%= inc,
    }
}

fn startLoop(p: *Parser) !void {
    try p.flushOp();
    const index: u32 = @intCast(p.insts.len);
    try p.insts.append(p.allocator, .{
        .tag = .loop_start,
        .value = undefined,
        .offset = undefined,
        .extra = undefined,
    });
    try p.pending_loop_starts.append(p.allocator, index);
}

fn endLoop(p: *Parser) !void {
    try p.flushOp();
    const loop_start = p.pending_loop_starts.popOrNull() orelse return error.ParseError;
    const index: u32 = @intCast(p.insts.len);
    p.insts.items(.extra)[loop_start] = index - loop_start;
    try p.insts.append(p.allocator, .{
        .tag = .loop_end,
        .value = undefined,
        .offset = undefined,
        .extra = loop_start -% index,
    });
}

fn flushOp(p: *Parser) !void {
    switch (p.current_op) {
        .none => {},
        .add => |value| try p.insts.append(p.allocator, .{
            .tag = .add,
            .value = value,
            .offset = 0,
            .extra = undefined,
        }),
        .move => |amount| try p.insts.append(p.allocator, .{
            .tag = .move,
            .value = undefined,
            .offset = undefined,
            .extra = amount,
        }),
    }
    p.current_op = .none;
}
