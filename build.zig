const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .ReleaseSafe,
    });

    const strip = b.option(bool, "strip", "Strip debug information") orelse false;
    const lto = b.option(bool, "lto", "Enable link time optimization") orelse false;

    //Add lmdb library for embeded key/value store
    const lmdb = b.dependency("lmdb", .{
        .target = target,
        .optimize = optimize,
    });

    const target_name = target.query.allocDescription(b.allocator) catch unreachable;
    const exe_name = std.fmt.allocPrint(
        b.allocator,
        "{[program]s}-{[target]s}",
        .{
            .program = "recblock",
            .target = target_name,
        },
    ) catch unreachable;

    const exe = b.addExecutable(.{
        .name = exe_name,
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });
    exe.want_lto = lto;

    const s2s_dep = b.dependency("s2s", .{
        .target = target,
        .optimize = optimize,
    });
    const s2s_module = s2s_dep.module("s2s");
    const liblmdb = lmdb.artifact("lmdb");
    const lmdb_module = lmdb.module("lmdb");

    exe.root_module.addImport("s2s", s2s_module);
    exe.root_module.addImport("mdb", lmdb_module);
    exe.linkLibrary(liblmdb);
    b.installArtifact(exe);

    const check = b.addExecutable(.{
        .name = "check",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    check.root_module.addImport("s2s", s2s_module);
    check.root_module.addImport("mdb", lmdb_module);
    check.linkLibrary(liblmdb);

    const check_step = b.step("check", "Zls: Check if recblock compiles");
    check_step.dependOn(&check.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
    });
    exe_tests.root_module.addImport("s2s", s2s_module);
    exe_tests.root_module.addImport("mdb", lmdb_module);
    exe_tests.linkLibrary(liblmdb);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&exe_tests.step);
}
