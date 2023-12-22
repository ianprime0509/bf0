const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Prog = @import("Prog.zig");
const Inst = Prog.Inst;

const condense = @import("optimize/Condense.zig").pass;
const recognizeLoops = @import("optimize/RecognizeLoops.zig").pass;

pub const passes: []const Pass = &.{ condense, recognizeLoops, condense };

pub const Pass = *const fn (Allocator, Prog) Allocator.Error!Prog;
