const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Prog = @import("../Prog.zig");
const Inst = Prog.Inst;

source: []const u8,
insts: Inst.List = .{},
pending_loop_starts: std.ArrayListUnmanaged(u32) = .{},
allocator: Allocator,

const Parser = @This();

const inst_tags = tags: {
    var tags: [Inst.meta.values.len]struct { []const u8, Inst.Tag } = undefined;
    for (&tags, Inst.meta.values, 0..) |*inst, meta, i| {
        inst.* = .{ meta.name, @enumFromInt(i) };
    }
    break :tags std.ComptimeStringMap(Inst.Tag, tags);
};

pub fn deinit(p: *Parser) void {
    p.insts.deinit(p.allocator);
    p.pending_loop_starts.deinit(p.allocator);
    p.* = undefined;
}

pub fn parse(p: *Parser) error{ ParseError, OutOfMemory }!void {
    var lines = mem.splitScalar(u8, p.source, '\n');
    while (lines.next()) |line| {
        try p.parseLine(line);
    }
    if (p.pending_loop_starts.items.len > 0) return error.ParseError;
}

fn parseLine(p: *Parser, line: []const u8) !void {
    var l = line;
    if (mem.indexOfScalar(u8, l, '#')) |comment_start| {
        l = l[0..comment_start];
    }
    l = mem.trim(u8, l, &std.ascii.whitespace);
    if (l.len == 0) return;

    var name: ?[]const u8 = null;
    var args: std.ArrayListUnmanaged([]const u8) = .{};
    defer args.deinit(p.allocator);
    var offset: ?[]const u8 = null;
    var state: union(enum) {
        name: usize,
        after_name,
        before_arg,
        arg: usize,
        after_arg,
        before_offset,
        offset: usize,
    } = .{ .name = 0 };
    for (l, 0..) |c, i| {
        switch (state) {
            .name => |start| switch (c) {
                'a'...'z', 'A'...'Z', '-' => {},
                ' ', '\t' => {
                    name = l[start..i];
                    state = .after_name;
                },
                else => return error.ParseError,
            },
            .after_name => switch (c) {
                ' ', '\t' => {},
                '-', '0'...'9' => state = .{ .arg = i },
                '@' => state = .before_offset,
                else => return error.ParseError,
            },
            .before_arg => switch (c) {
                ' ', '\t' => {},
                '-', '0'...'9' => state = .{ .arg = i },
                else => return error.ParseError,
            },
            .arg => |start| switch (c) {
                '0'...'9' => {},
                ' ', '\t' => {
                    try args.append(p.allocator, l[start..i]);
                    state = .after_arg;
                },
                ',' => {
                    try args.append(p.allocator, l[start..i]);
                    state = .before_arg;
                },
                else => return error.ParseError,
            },
            .after_arg => switch (c) {
                ' ', '\t' => {},
                ',' => state = .before_arg,
                '@' => state = .before_offset,
                else => return error.ParseError,
            },
            .before_offset => switch (c) {
                ' ', '\t' => {},
                '-', '0'...'9' => state = .{ .offset = i },
                else => return error.ParseError,
            },
            .offset => switch (c) {
                '0'...'9' => {},
                else => return error.ParseError,
            },
        }
    }
    switch (state) {
        .name => |start| name = l[start..],
        .arg => |start| try args.append(p.allocator, l[start..]),
        .offset => |start| offset = l[start..],
        .after_name, .after_arg => {},
        .before_arg, .before_offset => return error.ParseError,
    }

    const inst_tag = inst_tags.get(name orelse return error.ParseError) orelse return error.ParseError;
    const meta = Inst.meta.get(inst_tag);

    var expected_args: usize = 0;
    if (meta.value == .used) expected_args += 1;
    if (meta.extra == .used) expected_args += 1;
    if (args.items.len != expected_args) return error.ParseError;
    if (meta.offset != .used and offset != null) return error.ParseError;

    var arg_idx: usize = 0;
    const inst_value = if (meta.value == .used) value: {
        const parsed = parseInt(u8, args.items[arg_idx]) orelse return error.ParseError;
        arg_idx += 1;
        break :value parsed;
    } else undefined;
    var inst_extra = if (meta.extra == .used)
        parseInt(u32, args.items[arg_idx]) orelse return error.ParseError
    else
        undefined;
    const inst_offset = if (offset) |o|
        parseInt(u32, o) orelse return error.ParseError
    else
        0;

    if (inst_tag == .loop_start) {
        try p.pending_loop_starts.append(p.allocator, @intCast(p.insts.len));
    }
    if (inst_tag == .loop_end) {
        const index: u32 = @intCast(p.insts.len);
        const loop_start = p.pending_loop_starts.popOrNull() orelse return error.ParseError;
        p.insts.items(.extra)[loop_start] = index - loop_start;
        inst_extra = loop_start -% index;
    }
    try p.insts.append(p.allocator, .{
        .tag = inst_tag,
        .value = inst_value,
        .offset = inst_offset,
        .extra = inst_extra,
    });
}

fn parseInt(comptime T: type, s: []const u8) ?T {
    const Signed = @Type(.{ .Int = .{ .signedness = .signed, .bits = @typeInfo(T).Int.bits } });
    return std.fmt.parseUnsigned(T, s, 10) catch
        @as(T, @bitCast(std.fmt.parseInt(Signed, s, 10) catch return null));
}
