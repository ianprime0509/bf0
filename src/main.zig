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
    \\  -e, --eof VALUE      Set cell value to VALUE on EOF (use 'n' for no change)
    \\
;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    // TODO: improve argument parsing
    var input: ?[]const u8 = null;
    var options: interp.Options = .{};
    var arg_i: usize = 1;
    while (arg_i < args.len) : (arg_i += 1) {
        if (mem.eql(u8, args[arg_i], "-h") or mem.eql(u8, args[arg_i], "--help")) {
            try std.io.getStdOut().writeAll(usage);
            std.process.exit(0);
        } else if (mem.eql(u8, args[arg_i], "-e") or mem.eql(u8, args[arg_i], "--eof")) {
            arg_i += 1;
            if (arg_i == args.len) {
                log.err("missing argument to --eof", .{});
                std.process.exit(1);
            }
            const eof = args[arg_i];
            if (mem.eql(u8, eof, "n")) {
                options.eof = .no_change;
            } else if (std.fmt.parseInt(u8, eof, 10)) |value| {
                options.eof = .{ .value = value };
            } else |_| if (std.fmt.parseInt(i8, eof, 10)) |value| {
                options.eof = .{ .value = @bitCast(value) };
            } else |_| {
                log.err("invalid argument to --eof: {s}", .{eof});
                std.process.exit(1);
            }
        } else if (mem.startsWith(u8, args[arg_i], "-")) {
            log.err("unrecognized option: {s}", .{args[arg_i]});
            log.info("use --help for help", .{});
            std.process.exit(1);
        } else {
            if (input != null) {
                log.err("too many input files", .{});
                std.process.exit(1);
            }
            input = args[arg_i];
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
    var stdout_buf = std.io.bufferedWriter(std.io.getStdOut().writer());
    var int = interp.interp(allocator, prog, stdin_buf.reader(), stdout_buf.writer(), options);
    defer int.deinit();

    try int.run();
    try stdout_buf.flush();
}
