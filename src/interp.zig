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
) Allocator.Error!Interp(@TypeOf(reader), @TypeOf(writer), MappedMemory) {
    // TODO: make memory type configurable
    // TODO: refine errors induced by memory type
    return Interp(@TypeOf(reader), @TypeOf(writer), MappedMemory).init(
        allocator,
        prog,
        reader,
        writer,
        options,
    );
}

pub fn Interp(comptime InputReader: type, comptime OutputWriter: type, comptime Memory: type) type {
    return struct {
        tags: []const Inst.Tag,
        values: []const u8,
        offsets: []const u32,
        extras: []const u32,
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
        ) Allocator.Error!Self {
            return .{
                .tags = prog.insts.items(.tag),
                .values = prog.insts.items(.value),
                .offsets = prog.insts.items(.offset),
                .extras = prog.insts.items(.extra),
                .memory = try Memory.init(allocator),
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
                .set => try int.memory.set(int.values[int.pc], int.offsets[int.pc]),
                .add => try int.memory.add(int.values[int.pc], int.offsets[int.pc]),
                .add_mul => {
                    const mul = int.values[int.pc] *% int.memory.get(int.offsets[int.pc] +% int.extras[int.pc]);
                    try int.memory.add(mul, int.offsets[int.pc]);
                },
                .move => int.memory.move(int.extras[int.pc]),
                .seek => int.memory.seek(int.values[int.pc], int.offsets[int.pc], int.extras[int.pc]),
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
                    int.pc += int.extras[int.pc] + 1;
                    return false;
                },
                .loop_end => {
                    // There's no need to return to the loop-start instruction
                    // directly: we can perform its function as part of this
                    // instruction as well.
                    if (int.memory.get(0) == 0) {
                        int.pc += 1;
                    } else {
                        int.pc +%= int.extras[int.pc] + 1;
                    }
                    return false;
                },
            }
            int.pc += 1;
            return false;
        }
    };
}

pub const MappedMemory = struct {
    pos: u32 = 0,
    memory: []align(mem.page_size) u8,

    pub fn init(_: Allocator) Allocator.Error!MappedMemory {
        return .{
            .memory = std.os.mmap(
                null,
                1 << 32,
                std.os.PROT.READ | std.os.PROT.WRITE,
                std.os.MAP.PRIVATE | std.os.MAP.ANONYMOUS | std.os.MAP.NORESERVE,
                -1,
                0,
            ) catch return error.OutOfMemory,
        };
    }

    pub fn deinit(m: *MappedMemory) void {
        std.os.munmap(m.memory);
        m.* = undefined;
    }

    pub fn move(m: *MappedMemory, amount: u32) void {
        m.pos +%= amount;
    }

    pub fn seek(m: *MappedMemory, value: u8, offset: u32, step: u32) void {
        m.pos +%= offset;
        while (m.get(0) != value) {
            m.pos +%= step;
        }
    }

    pub fn add(m: *MappedMemory, value: u8, offset: u32) error{}!void {
        m.memory[m.pos +% offset] +%= value;
    }

    pub fn get(m: *MappedMemory, offset: u32) u8 {
        return m.memory[m.pos +% offset];
    }

    pub fn set(m: *MappedMemory, value: u8, offset: u32) error{}!void {
        m.memory[m.pos +% offset] = value;
    }
};

pub const PagedMemory = struct {
    pos: u32 = 0,
    pages: [n_pages]?*Page = .{null} ** n_pages,
    allocator: Allocator,

    const page_size = 1024 * 1024;
    const n_pages = (1 << 32) / page_size;

    const Page = [page_size]u8;

    pub fn init(allocator: Allocator) error{}!PagedMemory {
        return .{ .allocator = allocator };
    }

    pub fn deinit(m: *PagedMemory) void {
        for (m.pages) |page| {
            if (page) |p| m.allocator.destroy(p);
        }
        m.* = undefined;
    }

    pub fn move(m: *PagedMemory, amount: u32) void {
        m.pos +%= amount;
    }

    pub fn seek(m: *PagedMemory, value: u8, offset: u32, step: u32) void {
        m.pos +%= offset;
        while (m.get(0) != value) {
            m.pos +%= step;
        }
    }

    pub fn add(m: *PagedMemory, value: u8, offset: u32) Allocator.Error!void {
        const pos = m.pos +% offset;
        const page = m.pages[pos / page_size] orelse page: {
            const page = try m.allocator.create(Page);
            @memset(page, 0);
            m.pages[pos / page_size] = page;
            break :page page;
        };
        page[pos % page_size] +%= value;
    }

    pub fn get(m: PagedMemory, offset: u32) u8 {
        const pos = m.pos +% offset;
        const page = m.pages[pos / page_size] orelse return 0;
        return page[pos % page_size];
    }

    pub fn set(m: *PagedMemory, value: u8, offset: u32) Allocator.Error!void {
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
