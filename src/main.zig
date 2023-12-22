const std = @import("std");
const mem = std.mem;
const log = std.log;
const Prog = @import("Prog.zig");
const interp = @import("interp.zig");
const optimize = @import("optimize.zig");

const usage =
    \\Usage: bf0 [options] [input]
    \\
    \\Options:
    \\  -e, --eof VALUE      Set cell value to VALUE on EOF (use 'no-change' for no change)
    \\
;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var input: ?[]const u8 = null;
    defer if (input) |v| allocator.free(v);
    var options: interp.Options = .{};

    var args: ArgIterator = .{ .args = try std.process.argsWithAllocator(allocator) };
    defer args.deinit();
    _ = args.next();
    while (args.next()) |arg| {
        switch (arg) {
            .option => |option| if (option.is('h', "help")) {
                try std.io.getStdOut().writeAll(usage);
                std.process.exit(0);
            } else if (option.is('e', "eof")) {
                const eof = args.optionValue() orelse fatal("expected value for -e, --eof", .{});
                if (mem.eql(u8, eof, "no-change")) {
                    options.eof = .no_change;
                } else if (std.fmt.parseInt(u8, eof, 10)) |value| {
                    options.eof = .{ .value = value };
                } else |_| if (std.fmt.parseInt(i8, eof, 10)) |value| {
                    options.eof = .{ .value = @bitCast(value) };
                } else |_| {
                    fatal("invalid argument to --eof: {s}", .{eof});
                }
            } else {
                fatal("unrecognized option: {}", .{option});
            },
            .param => |param| if (input != null) {
                fatal("too many input files", .{});
            } else {
                input = try allocator.dupe(u8, param);
            },
            .unexpected_value => |unexpected_value| fatal("unexpected value to --{s}: {s}", .{
                unexpected_value.option,
                unexpected_value.value,
            }),
        }
    }

    const source = if (input) |input_path|
        try std.fs.cwd().readFileAlloc(allocator, input_path, std.math.maxInt(u32))
    else
        try std.io.getStdIn().readToEndAlloc(allocator, std.math.maxInt(u32));
    defer allocator.free(source);

    var prog = try Prog.parse(allocator, source);
    defer prog.deinit(allocator);
    for (optimize.passes) |pass| {
        const optimized_prog = try pass(allocator, prog);
        prog.deinit(allocator);
        prog = optimized_prog;
    }

    var stdin_buf = std.io.bufferedReader(std.io.getStdIn().reader());
    var int = try interp.interp(allocator, prog, stdin_buf.reader(), std.io.getStdOut().writer(), options);
    defer int.deinit();

    try int.run();
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    log.err(format, args);
    std.process.exit(1);
}

// Inspired by https://github.com/judofyr/parg
const ArgIterator = struct {
    args: std.process.ArgIterator,
    state: union(enum) {
        normal,
        short: []const u8,
        long: struct {
            option: []const u8,
            value: []const u8,
        },
        params_only,
    } = .normal,

    const Arg = union(enum) {
        option: union(enum) {
            short: u8,
            long: []const u8,

            fn is(option: @This(), short: ?u8, long: ?[]const u8) bool {
                return switch (option) {
                    .short => |c| short == c,
                    .long => |s| mem.eql(u8, long orelse return false, s),
                };
            }

            pub fn format(option: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
                switch (option) {
                    .short => |c| try writer.print("-{c}", .{c}),
                    .long => |s| try writer.print("--{s}", .{s}),
                }
            }
        },
        param: []const u8,
        unexpected_value: struct {
            option: []const u8,
            value: []const u8,
        },
    };

    fn deinit(iter: *ArgIterator) void {
        iter.args.deinit();
        iter.* = undefined;
    }

    fn next(iter: *ArgIterator) ?Arg {
        switch (iter.state) {
            .normal => {
                const arg = iter.args.next() orelse return null;
                if (mem.eql(u8, arg, "--")) {
                    iter.state = .params_only;
                    return .{ .param = iter.args.next() orelse return null };
                } else if (mem.startsWith(u8, arg, "--")) {
                    if (mem.indexOfScalar(u8, arg, '=')) |equals_index| {
                        const option = arg["--".len..equals_index];
                        iter.state = .{ .long = .{
                            .option = option,
                            .value = arg[equals_index + 1 ..],
                        } };
                        return .{ .option = .{ .long = option } };
                    } else {
                        return .{ .option = .{ .long = arg["--".len..] } };
                    }
                } else if (mem.startsWith(u8, arg, "-") and arg.len > 1) {
                    if (arg.len > 2) {
                        iter.state = .{ .short = arg["-".len + 1 ..] };
                    }
                    return .{ .option = .{ .short = arg["-".len] } };
                } else {
                    return .{ .param = arg };
                }
            },
            .short => |rest| {
                if (rest.len > 1) {
                    iter.state = .{ .short = rest[1..] };
                }
                return .{ .option = .{ .short = rest[0] } };
            },
            .long => |long| return .{ .unexpected_value = .{
                .option = long.option,
                .value = long.value,
            } },
            .params_only => return .{ .param = iter.args.next() orelse return null },
        }
    }

    fn optionValue(iter: *ArgIterator) ?[]const u8 {
        switch (iter.state) {
            .normal => return iter.args.next(),
            .short => |rest| {
                iter.state = .normal;
                return rest;
            },
            .long => |long| {
                iter.state = .normal;
                return long.value;
            },
            .params_only => unreachable,
        }
    }
};
