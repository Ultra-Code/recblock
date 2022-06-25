const std = @import("std");
const BlockChain = @import("Blockchain.zig");
const ChainIterator = BlockChain.ChainIterator;
const Lmdb = @import("Lmdb.zig");

const Cli = @This();

const Cmd = enum {
    createchain,
    send,
    getbalance,
    help,
};

arena: std.mem.Allocator,

pub fn init(arena: std.mem.Allocator) Cli {
    return .{ .arena = arena };
}

pub fn run(self: Cli) void {
    var buf: [1024]u8 = undefined;
    const fba = std.heap.FixedBufferAllocator.init(&buf).allocator();

    var itr = try std.process.argsWithAllocator(fba);
    defer itr.deinit();

    _ = itr.skip(); //skip name of program

    while (itr.next()) |argv| {
        var db_env = Lmdb.initdb("./db", .rw);
        defer db_env.deinitdb();

        if (std.mem.eql(u8, argv, "createchain")) {
            const chain_name = itr.next();

            if (chain_name) |name| {
                _ = BlockChain.newChain(db_env, self.arena, name);
            } else {
                printUsage(.createchain);
            }
        } else if (std.mem.eql(u8, argv, "send")) {
            if (itr.next()) |amount_option| {
                if (std.mem.eql(u8, amount_option, "--amount")) {
                    const amount_value = itr.next().?;

                    if (itr.next()) |from_option| {
                        if (std.mem.eql(u8, from_option, "--from")) {
                            const from_address = itr.next().?;

                            if (itr.next()) |to_option| {
                                if (std.mem.eql(u8, to_option, "--to")) {
                                    const to_address = itr.next().?;
                                    const amount = std.fmt.parseUnsigned(usize, amount_value, 10) catch unreachable;

                                    var bc = BlockChain.getChain(db_env, self.arena);

                                    bc.sendValue(amount, from_address, to_address);

                                    std.debug.print("done sending RBC {d} from '{s}' to '{s}'\n", .{ amount, from_address, to_address });
                                    std.debug.print("{[from_address]s} now has a balance of {[from_balance]d} and {[to_address]s} a balance of {[to_balance]d}\n", .{
                                        .from_address = from_address,
                                        .from_balance = bc.getBalance(from_address),
                                        .to_address = to_address,
                                        .to_balance = bc.getBalance(to_address),
                                    });
                                }
                            }
                        }
                    } else {
                        printUsage(.send);
                    }
                } else {
                    printUsage(.send);
                }
            } else {
                printUsage(.send);
            }
        } else if (std.mem.eql(u8, argv, "getbalance")) {
            if (itr.next()) |address| {
                const bc = BlockChain.getChain(db_env, self.arena);

                const balance = bc.getBalance(address);
                std.debug.print("'{[address]s}' has a balance of {[balance]d}\n", .{ .address = address, .balance = balance });
            } else {
                printUsage(.getbalance);
            }
        } else if (std.mem.eql(u8, argv, "printchain")) {
            const bc = BlockChain.getChain(db_env, self.arena);

            var chain_iter = ChainIterator.iterator(bc.arena, bc.db, bc.last_hash);
            chain_iter.print();
        } else {
            printUsage(.help);
        }
    }
}

fn printUsage(cmd: Cmd) void {
    switch (cmd) {
        .createchain => {
            std.debug.print(
                \\Usage:
                \\eg.zig build run -- createchain "blockchain name"
                \\
            , .{});
        },
        .help => {
            std.debug.print(
                \\Usage:
                \\eg.zig build run -- createchain "blockchain name"
                \\OR
                \\zig build run -- printchain
                \\OR
                \\zig build run -- getbalance "address"
                \\OR
                \\zig build run -- send --amount value --from address --to address
                \\
            , .{});
        },
        .getbalance => {
            std.debug.print(
                \\Usage:
                \\zig build run -- getbalance "address"
                \\
            , .{});
        },
        .send => {
            std.debug.print(
                \\Usage:
                \\zig build run -- send --amount value --from address --to address
                \\
            , .{});
        },
    }
    std.process.abort();
}