const std = @import("std");
const builtin = @import("builtin");
const Build = std.Build;

comptime {
    //Big endian systems not currently supported
    std.debug.assert(builtin.target.cpu.arch.endian() == .Little);
}

pub fn build(b: *Build) void {
    const s2s_module = b.dependency("s2s", .{}).module("s2s");

    const LMDB_PATH = "./deps/lmdb/libraries/liblmdb/";
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const optimize = b.standardOptimizeOption(.{});

    //Add lmdb library for embeded key/value store
    const cflags = [_][]const u8{ "-pthread", "-std=c2x" };
    const lmdb_sources = [_][]const u8{ LMDB_PATH ++ "mdb.c", LMDB_PATH ++ "midl.c" };
    const lmdb = b.addStaticLibrary(.{
        .name = "lmdb",
        .target = target,
        .optimize = optimize,
    });
    lmdb.addCSourceFiles(&lmdb_sources, &cflags);
    lmdb.linkLibC();
    b.installArtifact(lmdb);

    const target_name = target.allocDescription(b.allocator) catch unreachable;
    const exe_name = std.fmt.allocPrint(b.allocator, "{[program]s}-{[target]s}", .{
        .program = "recblock",
        .target = target_name,
    }) catch unreachable;

    const exe = b.addExecutable(.{
        .name = exe_name,
        .root_source_file = .{
            .path = "src/main.zig",
        },
        .target = target,
        .optimize = optimize,
    });
    exe.addModule("s2s", s2s_module);
    exe.linkLibrary(lmdb);
    exe.addIncludePath(.{ .path = LMDB_PATH });
    b.installArtifact(exe);
    exe.stack_size = 1024 * 1024 * 64;

    switch (optimize) {
        .ReleaseFast => {
            lmdb.link_function_sections = true;
            lmdb.red_zone = true;
            lmdb.want_lto = true;

            exe.link_function_sections = true;
            exe.red_zone = true;
            exe.want_lto = true;
            //FIXME: cross compiling for windows with strip run into issues
            //Wait for self-hosting and if problem still persist,open an issue to track this
            if (!target.isWindows()) {
                lmdb.strip = true;
                exe.strip = true;
            }
        },
        else => {},
    }
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&lmdb.step);
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
    });
    const test_run = b.addRunArtifact(exe_tests);

    exe_tests.addModule("s2s", s2s_module);
    exe_tests.linkLibrary(lmdb);
    exe_tests.addIncludePath(.{ .path = LMDB_PATH });

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&lmdb.step);
    test_step.dependOn(&test_run.step);
}
