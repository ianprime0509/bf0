const std = @import("std");
const Prog = @import("Prog.zig");
const interp = @import("interp.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len != 2) return error.InvalidArgs; // Usage: bf0 input

    const source = try std.fs.cwd().readFileAlloc(allocator, args[1], std.math.maxInt(u32));
    defer allocator.free(source);

    var prog = try Prog.parse(allocator, source);
    defer prog.deinit(allocator);

    var stdin_buf = std.io.bufferedReader(std.io.getStdIn().reader());
    var stdout_buf = std.io.bufferedWriter(std.io.getStdOut().writer());
    var int = interp.interp(allocator, prog, stdin_buf.reader(), stdout_buf.writer());
    defer int.deinit();

    try int.run();
    try stdout_buf.flush();
}
