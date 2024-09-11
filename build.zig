const std = @import("std");
const builtin = @import("builtin");

const LMDB_PATH = "./deps/lmdb/libraries/liblmdb/";

pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const optimize =
        b.standardOptimizeOption(
        .{ .preferred_optimize_mode = .ReleaseSafe },
    );

    //Add lmdb library for embeded key/value store
    const cflags = [_][]const u8{ "-pthread", "-std=c2x" };
    const lmdb_sources = [_][]const u8{
        LMDB_PATH ++ "mdb.c",
        LMDB_PATH ++ "midl.c",
    };
    const lmdb = b.addStaticLibrary(.{
        .name = "lmdb",
        .target = target,
        .optimize = optimize,
    });
    lmdb.addCSourceFiles(.{
        .files = &lmdb_sources,
        .flags = &cflags,
    });
    lmdb.linkLibC();
    const install_lmdb = b.addInstallArtifact(
        lmdb,
        .{},
    );
    b.getInstallStep().dependOn(&install_lmdb.step);

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
    });
    const s2s_dep = b.dependency("s2s", .{
        .target = target,
        .optimize = optimize,
    });
    const s2s_module = s2s_dep.module("s2s");
    exe.root_module.addImport("s2s", s2s_module);
    const translate_lmdb = b.addTranslateC(.{
        .root_source_file = b.path(LMDB_PATH ++ "lmdb.h"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("mdb", translate_lmdb.createModule());
    exe.linkLibrary(lmdb);
    b.installArtifact(exe);

    switch (optimize) {
        .Debug => {},
        else => {
            lmdb.link_function_sections = true;
            lmdb.root_module.red_zone = true;
            lmdb.want_lto = true;

            exe.link_function_sections = true;
            exe.root_module.red_zone = true;
            exe.want_lto = true;
            //FIXME: cross compiling for windows with strip run into issues
            //Wait for self-hosting and if problem still persist,open an issue to track this
            if (builtin.target.os.tag != .windows) {
                lmdb.root_module.strip = true;
                exe.root_module.strip = true;
            }
        },
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
        .root_source_file = b.path("src/main.zig"),
    });
    exe_tests.root_module.addImport("s2s", s2s_module);
    exe_tests.linkLibrary(lmdb);
    exe_tests.addIncludePath(b.path(LMDB_PATH));

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&lmdb.step);
    test_step.dependOn(&exe_tests.step);
}
