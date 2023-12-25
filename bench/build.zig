const std = @import("std");

pub fn build(b: *std.Build) void {
    const bff = b.dependency("bff", .{});
    const bff_exe = b.addExecutable(.{
        .name = "bff",
        .optimize = .ReleaseFast,
    });
    bff_exe.linkLibC();
    bff_exe.addCSourceFile(.{
        .file = bff.path("bff.c"),
        // https://github.com/apankrat/bff/blob/f9e03ef793f46695b6ad81ed8cfc745a28c66b44/Makefile#L1
        .flags = &.{ "-O3", "-ansi", "-DNDEBUG", "-Wall" },
    });
    b.installArtifact(bff_exe);

    const bff4 = b.dependency("bff4", .{});
    const bff4_exe = b.addExecutable(.{
        .name = "bff4",
        .optimize = .ReleaseFast,
    });
    bff4_exe.linkLibC();
    bff4_exe.addCSourceFile(.{
        .file = bff4.path("bff4/bff4.c"),
        .flags = &.{"-O3"},
    });
    b.installArtifact(bff4_exe);

    const brainforked = b.dependency("brainforked", .{});
    const brainforked_exe = b.addExecutable(.{
        .name = "brainforked",
        .optimize = .ReleaseFast,
    });
    brainforked_exe.linkLibCpp();
    brainforked_exe.addCSourceFiles(.{
        .dependency = brainforked,
        .files = &.{
            "bf_main.cpp",
            "bf_instruction.cpp",
            "bf_io.cpp",
            "bf_optimizations.cpp",
        },
        // https://github.com/JohnCGriffin/BrainForked/blob/ab96b84a7c3371b6b168dcaac79166488f3712ae/Makefile#L6-L7
        .flags = &.{ "-O3", "-Wall", "-std=c++17" },
    });
    b.installArtifact(brainforked_exe);
}
