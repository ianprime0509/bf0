const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "bf0",
        .target = target,
        .optimize = optimize,
        .root_source_file = .{ .path = "src/main.zig" },
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| {
        run.addArgs(args);
    }
    b.step("run", "Run the executable").dependOn(&run.step);

    const tests = b.addTest(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = .{ .path = "src/main.zig" },
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);

    const exe_test_exe = b.addExecutable(.{
        .name = "exe-test-runner",
        .target = target,
        .optimize = optimize,
        .root_source_file = .{ .path = "src/exe_test_runner.zig" },
    });
    const programs: []const []const u8 = &.{
        "cat",
        "cat-provided-input",
        "hello",
        "third-party/numwarp",
        "third-party/rot13",
    };
    const arg_sets: []const []const []const u8 = &.{
        &.{},
        &.{"-O0"},
    };
    for (programs) |program| {
        for (arg_sets) |args| {
            test_step.dependOn(&addExeTest(b, exe, exe_test_exe, program, args).step);
        }
    }
}

fn addExeTest(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    exe_test_exe: *std.Build.Step.Compile,
    program: []const u8,
    args: []const []const u8,
) *std.Build.Step.Run {
    const run = b.addRunArtifact(exe_test_exe);
    run.addFileArg(.{ .path = b.pathFromRoot(b.fmt("programs/test-data/{s}.b.in", .{program})) });
    run.addFileArg(.{ .path = b.pathFromRoot(b.fmt("programs/test-data/{s}.b.out", .{program})) });
    run.addFileArg(exe.getEmittedBin());
    run.addFileArg(.{ .path = b.pathFromRoot(b.fmt("programs/{s}.b", .{program})) });
    run.addArgs(args);
    return run;
}
