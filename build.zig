const std = @import("std");
const Pkg = std.build.Pkg;
const pkgs = struct {
    const s2s = Pkg{
        .name = "s2s",
        .path = .{ .path = "./deps/s2s/s2s.zig" },
        .dependencies = &[_]Pkg{},
    };
};

pub fn build(b: *std.build.Builder) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("recblock", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.addPackage(pkgs.s2s);
    exe.install();

    //Add lmdb library for embeded key/value store
    const builtin = @import("builtin");

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTestExe("recblock-test", "src/main.zig");
    exe_tests.setTarget(target);
    exe_tests.setBuildMode(mode);
    exe_tests.addPackage(pkgs.s2s);
    exe_tests.install();

    const run_test = exe_tests.run();

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_test.step);

    switch (builtin.target.os.tag) {
        .linux => {
            exe.linkSystemLibrary("lmdb");
            exe.linkLibC();

            //link libraries for test
            exe_tests.linkSystemLibrary("lmdb");
            exe_tests.linkLibC();
        },
        else => {
            @compileError("Support and Contribution for Other Oses is wellcomed");
        },
    }
}
