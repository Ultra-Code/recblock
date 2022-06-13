const std = @import("std");
const builtin = @import("builtin");

const Cli = @import("Cli.zig");

var default_allocator = std.heap.GeneralPurposeAllocator(.{}){};
const gpa = if (builtin.link_libc and builtin.mode != .Debug)
    std.heap.raw_c_allocator
else
    default_allocator.allocator();

pub fn main() !void {
    defer if (builtin.mode == .Debug) {
        _ = default_allocator.deinit();
    };
    var buf: [1024 * 1024 * 15]u8 = undefined;
    const fba = std.heap.FixedBufferAllocator.init(&buf).allocator();

    var arena = std.heap.ArenaAllocator.init(fba);
    defer arena.deinit();

    const allocator = arena.allocator();

    var cli = Cli.init(allocator);
    cli.run();
}

test {
    std.testing.refAllDecls(@This());
}
