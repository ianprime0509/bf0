const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Prog = @import("Prog.zig");
const Inst = Prog.Inst;

const log = std.log.scoped(.optimize);

pub const Pass = struct {
    name: []const u8,
    apply: *const fn (Allocator, Prog) Allocator.Error!Prog,
};

const condense: Pass = .{
    .name = "condense",
    .apply = @import("optimize/Condense.zig").pass,
};
const recognizeLoops: Pass = .{
    .name = "recognize-loops",
    .apply = @import("optimize/RecognizeLoops.zig").pass,
};

pub const Level = enum(u8) {
    none = 0,
    normal = 1,
};

pub const Options = struct {
    level: Level = .normal,
    max_iterations: u32 = 10,
};

const default_passes = passes: {
    var p = std.EnumArray(Level, []const Pass).initUndefined();
    p.set(.none, &.{});
    p.set(.normal, &.{ condense, recognizeLoops });
    break :passes p;
};

pub fn optimize(allocator: Allocator, prog: Prog, options: Options) Allocator.Error!Prog {
    const passes = default_passes.get(options.level);
    for (passes) |pass| {
        log.debug("enabled optimization pass: {s}", .{pass.name});
    }

    var p = prog;
    var i: u32 = 0;
    const max_iterations = if (passes.len == 0) 0 else options.max_iterations;
    while (i < max_iterations) : (i += 1) {
        const init_hash = p.hash();
        for (passes) |pass| {
            const p_opt = try pass.apply(allocator, p);
            p.deinit(allocator);
            p = p_opt;
        }
        const final_hash = p.hash();
        if (mem.eql(u8, &init_hash, &final_hash)) break;
    }
    log.debug("completed optimization in {} iterations", .{i});
    return p;
}
