const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Prog = @import("Prog.zig");
const Inst = Prog.Inst;

pub fn interp(
    allocator: Allocator,
    prog: Prog,
    reader: anytype,
    writer: anytype,
) Interp(@TypeOf(reader), @TypeOf(writer)) {
    return Interp(@TypeOf(reader), @TypeOf(writer)).init(allocator, prog, reader, writer);
}

pub fn Interp(comptime InputReader: type, comptime OutputWriter: type) type {
    return struct {
        tags: []const Inst.Tag,
        values: []const u8,
        offsets: []const u32,
        pc: u32 = 0,
        memory: Memory,
        input: InputReader,
        output: OutputWriter,

        const Self = @This();

        pub fn init(allocator: Allocator, prog: Prog, input: InputReader, output: OutputWriter) Self {
            return .{
                .tags = prog.insts.items(.tag),
                .values = prog.insts.items(.value),
                .offsets = prog.insts.items(.offset),
                .memory = .{ .allocator = allocator },
                .input = input,
                .output = output,
            };
        }

        pub fn deinit(int: *Self) void {
            int.memory.deinit();
            int.* = undefined;
        }

        pub const RunError = InputReader.Error || OutputWriter.Error || Allocator.Error;

        pub fn run(int: *Self) RunError!void {
            while (true) {
                if (try int.step()) break;
            }
        }

        pub fn step(int: *Self) RunError!bool {
            switch (int.tags[int.pc]) {
                .halt => return true,
                .add => try int.memory.add(int.values[int.pc], int.offsets[int.pc]),
                .move => int.memory.move(int.offsets[int.pc]),
                .in => {
                    const b = int.input.readByte() catch |err| switch (err) {
                        error.EndOfStream => @as(u8, 0),
                        else => |other_err| return other_err,
                    };
                    try int.memory.set(b, int.offsets[int.pc]);
                },
                .out => try int.output.writeByte(int.memory.get(int.offsets[int.pc])),
                .loop_start => if (int.memory.get(0) == 0) {
                    int.pc += int.offsets[int.pc] + 1;
                    return false;
                },
                .loop_end => {
                    int.pc +%= int.offsets[int.pc];
                    return false;
                },
            }
            int.pc += 1;
            return false;
        }
    };
}

pub const Memory = struct {
    pos: u32 = 0,
    // TODO: optimizations
    l2: L2Table = .{},
    allocator: Allocator,

    const page_size = 4096;
    const table_size = 1024;

    const L2Table = struct {
        l1s: [table_size]*L1Table = undefined,
        l1s_valid: std.StaticBitSet(table_size) = std.StaticBitSet(table_size).initEmpty(),
    };

    const L1Table = struct {
        pages: [table_size]*Page = undefined,
        pages_valid: std.StaticBitSet(table_size) = std.StaticBitSet(table_size).initEmpty(),
    };

    const Page = [page_size]u8;

    pub fn deinit(m: *Memory) void {
        for (m.l2.l1s, 0..) |l1, i| {
            if (m.l2.l1s_valid.isSet(i)) {
                for (l1.pages, 0..) |page, j| {
                    if (l1.pages_valid.isSet(j)) {
                        m.allocator.destroy(page);
                    }
                }
                m.allocator.destroy(l1);
            }
        }
        m.* = undefined;
    }

    pub fn move(m: *Memory, offset: u32) void {
        m.pos +%= offset;
    }

    pub fn add(m: *Memory, value: u8, offset: u32) Allocator.Error!void {
        const ptr = try m.getPtr(offset);
        ptr.* +%= value;
    }

    pub fn get(m: Memory, offset: u32) u8 {
        const pos = m.pos +% offset;
        const l1_index = pos / (table_size * page_size);
        const page_index = (pos % (table_size * page_size)) / page_size;
        const index = pos % page_size;
        if (!m.l2.l1s_valid.isSet(l1_index)) return 0;
        const l1 = m.l2.l1s[l1_index];
        if (!l1.pages_valid.isSet(page_index)) return 0;
        const page = l1.pages[page_index];
        return page[index];
    }

    pub fn set(m: *Memory, value: u8, offset: u32) Allocator.Error!void {
        const ptr = try m.getPtr(offset);
        ptr.* = value;
    }

    fn getPtr(m: *Memory, offset: u32) !*u8 {
        const pos = m.pos +% offset;
        const l1_index = pos / (table_size * page_size);
        const page_index = (pos % (table_size * page_size)) / page_size;
        const index = pos % page_size;
        if (!m.l2.l1s_valid.isSet(l1_index)) {
            const l1 = try m.allocator.create(L1Table);
            l1.* = .{};
            m.l2.l1s[l1_index] = l1;
            m.l2.l1s_valid.set(l1_index);
        }
        const l1 = m.l2.l1s[l1_index];
        if (!l1.pages_valid.isSet(page_index)) {
            const page = try m.allocator.create(Page);
            @memset(page, 0);
            l1.pages[page_index] = page;
            l1.pages_valid.set(page_index);
        }
        const page = l1.pages[page_index];
        return &page[index];
    }
};
