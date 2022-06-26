const std = @import("std");
const builtin = @import("builtin");
const Pkg = std.build.Pkg;
const pkgs = struct {
    const s2s = Pkg{
        .name = "s2s",
        .source = .{ .path = "./deps/s2s/s2s.zig" },
        .dependencies = &[_]Pkg{},
    };
};
const LMDB_PATH = "./deps/lmdb/libraries/liblmdb/";

pub fn build(b: *std.build.Builder) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    //Add lmdb library for embeded key/value store
    const lmdb = b.addStaticLibrary("lmdb", null);
    lmdb.setTarget(target);
    lmdb.setBuildMode(mode);
    lmdb.addCSourceFiles(&.{ LMDB_PATH ++ "mdb.c", LMDB_PATH ++ "midl.c" }, &.{ "-pthread", "-std=c2x" });
    lmdb.linkLibC();
    lmdb.install();

    const target_name = target.allocDescription(b.allocator) catch unreachable;
    const exe_name = std.fmt.allocPrint(b.allocator, "{[program]s}-{[target]s}", .{ .program = "recblock", .target = target_name }) catch unreachable;

    const exe = b.addExecutable(exe_name, "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.addPackage(pkgs.s2s);
    exe.linkLibrary(lmdb);
    exe.addIncludePath(LMDB_PATH);
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&lmdb.step);
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest("src/main.zig");
    exe_tests.setTarget(target);
    exe_tests.setBuildMode(mode);
    exe_tests.addPackage(pkgs.s2s);
    exe_tests.linkLibrary(lmdb);
    exe_tests.addIncludePath(LMDB_PATH);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&lmdb.step);
    test_step.dependOn(&exe_tests.step);
}
