const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Prog = @import("Prog.zig");
const Inst = Prog.Inst;

const condense = @import("optimize/Condense.zig").pass;
const recognizeLoops = @import("optimize/RecognizeLoops.zig").pass;

pub const Level = enum(u8) {
    none = 0,
    normal = 1,
};

pub const Options = struct {
    level: Level = .normal,
    max_iterations: u32 = 10,
};

pub const Pass = *const fn (Allocator, Prog) Allocator.Error!Prog;

const default_passes = passes: {
    var p = std.EnumArray(Level, []const Pass).initUndefined();
    p.set(.none, &.{});
    p.set(.normal, &.{ condense, recognizeLoops });
    break :passes p;
};

pub fn optimize(allocator: Allocator, prog: Prog, options: Options) Allocator.Error!Prog {
    const passes = default_passes.get(options.level);
    if (passes.len == 0) return prog;

    var p = prog;
    var i: u32 = 0;
    while (i < options.max_iterations) : (i += 1) {
        const init_len = p.insts.len;
        for (passes) |pass| {
            const p_opt = try pass(allocator, p);
            p.deinit(allocator);
            p = p_opt;
        }
        // TODO: better stopping condition
        if (p.insts.len == init_len) break;
    }
    return p;
}
