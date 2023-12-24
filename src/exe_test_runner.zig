const std = @import("std");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    if (args.len < 5) return error.InvalidArgs; // Usage: test_runner input output bf0-exe program [args...]

    const input = try std.fs.cwd().readFileAlloc(allocator, args[1], std.math.maxInt(usize));
    const expected_output = try std.fs.cwd().readFileAlloc(allocator, args[2], std.math.maxInt(usize));

    var run_process = std.process.Child.init(args[3..], allocator);
    run_process.stdin_behavior = .Pipe;
    run_process.stdout_behavior = .Pipe;
    run_process.stderr_behavior = .Ignore;
    try run_process.spawn();

    try run_process.stdin.?.writeAll(input);
    run_process.stdin.?.close();
    run_process.stdin = null;

    const actual_output = try run_process.stdout.?.readToEndAlloc(allocator, std.math.maxInt(usize));
    const exit = try run_process.wait();
    if (exit != .Exited or exit.Exited != 0) {
        std.debug.print("Process exited unsuccessfully: {}\n", .{exit});
        std.process.exit(1);
    }

    if (!std.mem.eql(u8, actual_output, expected_output)) {
        std.debug.print("Outputs differ.\n\nExpected:\n{s}\nActual:\n{s}\n", .{ expected_output, actual_output });
        std.process.exit(1);
    }
}
