const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Prog = @import("../Prog.zig");

pub fn testOptimize(
    pass: *const fn (Allocator, Prog) Allocator.Error!Prog,
    input: []const u8,
    output: []const u8,
) !void {
    var input_prog = try Prog.parseBytecodeText(std.testing.allocator, input);
    defer input_prog.deinit(std.testing.allocator);
    var output_prog = try pass(std.testing.allocator, input_prog);
    defer output_prog.deinit(std.testing.allocator);
    var output_text = std.ArrayList(u8).init(std.testing.allocator);
    defer output_text.deinit();
    try output_prog.writeBytecodeText(output_text.writer(), .{});
    try std.testing.expectEqualStrings(
        mem.trim(u8, output, &std.ascii.whitespace),
        mem.trim(u8, output_text.items, &std.ascii.whitespace),
    );
}
