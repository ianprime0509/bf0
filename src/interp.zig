const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Prog = @import("Prog.zig");
const Inst = Prog.Inst;

pub const Options = struct {
    eof: Eof = .{ .value = 0 },

    pub const Eof = union(enum) {
        no_change,
        value: u8,
    };
};

pub fn interp(
    allocator: Allocator,
    prog: Prog,
    reader: anytype,
    writer: anytype,
    options: Options,
) Interp(@TypeOf(reader), @TypeOf(writer)) {
    return Interp(@TypeOf(reader), @TypeOf(writer)).init(
        allocator,
        prog,
        reader,
        writer,
        options,
    );
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
        options: Options,

        const Self = @This();

        pub fn init(
            allocator: Allocator,
            prog: Prog,
            input: InputReader,
            output: OutputWriter,
            options: Options,
        ) Self {
            return .{
                .tags = prog.insts.items(.tag),
                .values = prog.insts.items(.value),
                .offsets = prog.insts.items(.offset),
                .memory = .{ .allocator = allocator },
                .input = input,
                .output = output,
                .options = options,
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
                    if (int.input.readByte()) |b| {
                        try int.memory.set(b, int.offsets[int.pc]);
                    } else |err| switch (err) {
                        error.EndOfStream => switch (int.options.eof) {
                            .no_change => {},
                            .value => |value| try int.memory.set(value, int.offsets[int.pc]),
                        },
                        else => |other_err| return other_err,
                    }
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
    pages: [n_pages]?*Page = .{null} ** n_pages,
    allocator: Allocator,

    const page_size = 1024 * 1024;
    const n_pages = (1 << 32) / page_size;

    const Page = [page_size]u8;

    pub fn deinit(m: *Memory) void {
        for (m.pages) |page| {
            if (page) |p| m.allocator.destroy(p);
        }
        m.* = undefined;
    }

    pub fn move(m: *Memory, offset: u32) void {
        m.pos +%= offset;
    }

    pub fn add(m: *Memory, value: u8, offset: u32) Allocator.Error!void {
        const pos = m.pos +% offset;
        const page = m.pages[pos / page_size] orelse page: {
            const page = try m.allocator.create(Page);
            @memset(page, 0);
            m.pages[pos / page_size] = page;
            break :page page;
        };
        page[pos % page_size] +%= value;
    }

    pub fn get(m: Memory, offset: u32) u8 {
        const pos = m.pos +% offset;
        const page = m.pages[pos / page_size] orelse return 0;
        return page[pos % page_size];
    }

    pub fn set(m: *Memory, value: u8, offset: u32) Allocator.Error!void {
        const pos = m.pos +% offset;
        const page = m.pages[pos / page_size] orelse page: {
            const page = try m.allocator.create(Page);
            @memset(page, 0);
            m.pages[pos / page_size] = page;
            break :page page;
        };
        page[pos % page_size] = value;
    }
};
