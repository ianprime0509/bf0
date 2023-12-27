const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Prog = @import("Prog.zig");

pub const x86_64 = @import("codegen/x86_64.zig");

/// The native codegen function for the current platform, if any.
pub const generateNative: ?fn (Allocator, Prog) Allocator.Error![]align(mem.page_size) u8 = if (x86_64.supported)
    x86_64.generate
else
    null;
