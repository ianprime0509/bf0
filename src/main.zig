const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const log = std.log;
const Prog = @import("Prog.zig");
const interp = @import("interp.zig");
const optimize = @import("optimize.zig");

const usage =
    \\Usage: bf0 [options] [input]
    \\
    \\Interprets the Brainfuck program provided as input. If no input file is
    \\provided, the program is read from standard input.
    \\
    \\Options:
    \\  -e, --eof=VALUE        Set VALUE on EOF (integer or 'no-change') (default: 0)
    \\  -O, --optimize=LEVEL   Set optimization level (supported: 0-1) (default: 1)
    \\  --dump-bytecode        Dump bytecode rather than executing the program
    \\  --input-format=FORMAT  Read input using FORMAT ('brainfuck' or 'bytecode-text') (default: brainfuck)
    \\
;

var log_tty_config: std.io.tty.Config = undefined; // Will be initialized immediately in main

pub const std_options = struct {
    pub const log_level = if (builtin.mode == .Debug) log.Level.debug else log.Level.info;
    pub const logFn = logImpl;
};

pub fn logImpl(
    comptime level: log.Level,
    comptime scope: @Type(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const prefix = if (scope == .default)
        comptime level.asText() ++ ": "
    else
        comptime level.asText() ++ "(" ++ @tagName(scope) ++ "): ";
    const mutex = std.debug.getStderrMutex();
    mutex.lock();
    defer mutex.unlock();
    const stderr = std.io.getStdErr().writer();
    log_tty_config.setColor(stderr, switch (level) {
        .err => .bright_red,
        .warn => .bright_yellow,
        .info => .bright_blue,
        .debug => .bright_magenta,
    }) catch return;
    stderr.writeAll(prefix) catch return;
    log_tty_config.setColor(stderr, .reset) catch return;
    stderr.print(format ++ "\n", args) catch return;
}

pub fn main() !void {
    log_tty_config = std.io.tty.detectConfig(std.io.getStdErr());

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var input: ?[]const u8 = null;
    defer if (input) |v| allocator.free(v);
    var options: interp.Options = .{};
    var opt_options: optimize.Options = .{};
    var dump_bytecode = false;
    var input_format: enum { brainfuck, bytecode_text } = .brainfuck;

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
                    fatal("invalid value for --eof: {s}", .{eof});
                }
            } else if (option.is('O', "optimize")) {
                const level_txt = args.optionValue() orelse fatal("expected value for -O, --optimize", .{});
                const level = std.fmt.parseInt(u8, level_txt, 10) catch fatal("invalid value for -O, --optimize: {s}", .{level_txt});
                opt_options.level = std.meta.intToEnum(optimize.Level, level) catch fatal("invalid value for -O, --optimize: {s}", .{level_txt});
            } else if (option.is(null, "dump-bytecode")) {
                dump_bytecode = true;
            } else if (option.is(null, "input-format")) {
                const format = args.optionValue() orelse fatal("expected value for --input-format", .{});
                input_format = if (mem.eql(u8, format, "brainfuck"))
                    .brainfuck
                else if (mem.eql(u8, format, "bytecode-text"))
                    .bytecode_text
                else
                    fatal("invalid value for --input-format: {s}", .{format});
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

    var prog = switch (input_format) {
        .brainfuck => try Prog.parseBrainfuck(allocator, source),
        .bytecode_text => try Prog.parseBytecodeText(allocator, source),
    };
    defer prog.deinit(allocator);
    prog = try optimize.optimize(allocator, prog, opt_options);

    if (dump_bytecode) {
        var stdout_buf = std.io.bufferedWriter(std.io.getStdOut().writer());
        try prog.writeBytecodeText(stdout_buf.writer(), .{ .show_internal = true });
        try stdout_buf.flush();
    } else {
        var stdin_buf = std.io.bufferedReader(std.io.getStdIn().reader());
        var int = try interp.interp(allocator, prog, stdin_buf.reader(), std.io.getStdOut().writer(), options);
        defer int.deinit();
        while (int.step()) |status| switch (status) {
            .halted => break,
            .breakpoint => int.pc += 1, // TODO: debugger
            .running => {},
        } else |err| return err;
    }
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

test {
    std.testing.refAllDecls(@This());
}
