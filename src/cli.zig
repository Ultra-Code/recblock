const std = @import("std");
const blockchain = @import("blockchain.zig");
const BlockChain = blockchain.BlockChain;
const Cli = @This();

bc: BlockChain,

const Cmd = enum {
    addblock,
    help,
};

pub fn init(bc: BlockChain) Cli {
    return .{ .bc = bc };
}

//this is a temporary fix for not using an allocator in deserialize
fn sliceToArray(slice: []const u8, array: *[32]u8) void {
    std.mem.copy(u8, array, slice);
}

pub fn run(self: *Cli) void {
    var buf: [60]u8 = undefined;
    const fba = std.heap.FixedBufferAllocator.init(&buf).allocator();
    var arena = std.heap.ArenaAllocator.init(fba);
    defer arena.deinit();
    var allocator = arena.allocator();

    var itr = try std.process.argsWithAllocator(allocator);
    defer itr.deinit();

    _ = itr.skip(); //skip name of program

    while (itr.next()) |argv| {
        if (std.mem.eql(u8, argv, "addblock")) {
            const block_data = itr.next().?;
            if (!std.mem.eql(u8, block_data, "")) {
                var array: [32]u8 = undefined;
                sliceToArray(block_data, &array);
                self.bc.addBlock(array);
            } else {
                printUsage(.addblock);
            }
        } else if (std.mem.eql(u8, argv, "printchain")) {
            var chain_iter = blockchain.ChainIterator.iterator(self.bc);
            chain_iter.print();
        } else {
            printUsage(.help);
        }
    }
}

fn printUsage(cmd: Cmd) void {
    switch (cmd) {
        .addblock => {
            std.debug.print(
                \\Expected a string quoted data after addblock option
                \\eg.zig build run -- addblock "send 1BTC to Assan"
                \\
            , .{});
        },
        .help => {
            std.debug.print(
                \\Usage:
                \\zig build run -- addblock "send 1BTC to Assan"
                \\OR
                \\zig build run -- printchain
                \\
            , .{});
        },
    }
    std.process.abort();
}
