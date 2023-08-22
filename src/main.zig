const std = @import("std");
const builtin = @import("builtin");

const Cli = @import("Cli.zig");

//TODO: improve memory usage and recycling at appropiate places.
// set buffers in local scope based on the sizeof the struct or types stored or allocated
//TODO: rethink allocations and memory management pattern used,maybe pass the allocator type so you can free memory
//if the data generated at the step won't be used again or isn't useful again
//TODO: update Hex formatting to use X/x
pub fn main() !void {
    var default_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = if (builtin.link_libc and builtin.mode != .Debug)
        std.heap.raw_c_allocator
    else
        default_allocator.allocator();

    defer if (builtin.mode == .Debug) {
        _ = default_allocator.deinit();
    };
    // var buf: [1024 * 1024 * 7]u8 = undefined;
    // var fba = std.heap.FixedBufferAllocator.init(&buf);

    var arena = std.heap.ArenaAllocator.init(gpa);

    defer arena.deinit();

    const allocator = arena.allocator();

    var cli = Cli.init(allocator);
    cli.run();
}

test {
    std.testing.refAllDecls(@This());
}
