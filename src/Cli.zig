arena: std.mem.Allocator,

const std = @import("std");

const Cli = @This();
const BlockChain = @import("Blockchain.zig");
const Wallets = @import("Wallets.zig");
const Iterator = @import("Iterator.zig");
const Lmdb = @import("Lmdb.zig");
const WALLET_STORAGE = "db/wallet.dat";

const Cmd = enum {
    createchain,
    send,
    getbalance,
    help,
};

pub fn init(arena: std.mem.Allocator) Cli {
    return .{ .arena = arena };
}

pub fn run(self: Cli) void {
    var buf: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);

    var itr = std.process.argsWithAllocator(fba.allocator()) catch unreachable;
    defer itr.deinit();

    _ = itr.skip(); //skip name of program

    while (itr.next()) |argv| {
        if (std.mem.eql(u8, argv, "clean")) {
            std.fs.cwd().deleteTree("db") catch unreachable;
            return;
        }

        var db_env = Lmdb.initdb("db", .rw);
        defer db_env.deinitdb();

        if (std.mem.eql(u8, argv, "createchain")) {
            const chain_name = itr.next();

            if (chain_name) |name| {
                const bc_address = std.mem.bytesAsSlice(Wallets.Address, name)[0];
                _ = BlockChain.newChain(db_env, self.arena, bc_address, WALLET_STORAGE);
            } else {
                printUsage(.createchain);
            }
        } else if (std.mem.eql(u8, argv, "send")) {
            if (itr.next()) |amount_option| {
                if (std.mem.eql(u8, amount_option, "--amount")) {
                    const amount_value = itr.next().?;

                    if (itr.next()) |from_option| {
                        if (std.mem.eql(u8, from_option, "--from")) {
                            const from_address = std.mem.bytesAsSlice(Wallets.Address, itr.next().?)[0];

                            if (itr.next()) |to_option| {
                                if (std.mem.eql(u8, to_option, "--to")) {
                                    const to_address = std.mem.bytesAsSlice(Wallets.Address, itr.next().?)[0];
                                    const amount = std.fmt.parseUnsigned(usize, amount_value, 10) catch unreachable;

                                    var bc = BlockChain.getChain(db_env, self.arena);

                                    bc.sendValue(amount, from_address, to_address);

                                    std.debug.print("done sending RBC {d} from '{s}' to '{s}'\n", .{ amount, from_address, to_address });
                                    std.debug.print("'{[from_address]s}' now has a balance of RBC {[from_balance]d} and '{[to_address]s}' a balance of RBC {[to_balance]d}\n", .{
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
                const users_address = std.mem.bytesAsSlice(Wallets.Address, address)[0];
                const balance = bc.getBalance(users_address);
                std.debug.print("'{[address]s}' has a balance of RBC {[balance]d}\n", .{ .address = users_address, .balance = balance });
            } else {
                printUsage(.getbalance);
            }
        } else if (std.mem.eql(u8, argv, "printchain")) {
            const bc = BlockChain.getChain(db_env, self.arena);

            var chain_iter = Iterator.iterator(bc.arena, bc.db, bc.last_hash);
            chain_iter.print();
        } else if (std.mem.eql(u8, argv, "createwallet")) {
            const wallets = Wallets.initWallets(self.arena, WALLET_STORAGE);
            const wallet_address = wallets.createWallet();
            std.debug.print("Your new address is '{[address]s}'\n", .{ .address = wallet_address });
        } else if (std.mem.eql(u8, argv, "listaddress")) {
            const wallets = Wallets.getWallets(self.arena, WALLET_STORAGE);
            const address_list = wallets.getAddresses();

            for (address_list, 0..) |address, index| {
                std.log.info("address {}\n{s}\n", .{ index, address });
            }
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
                \\zig build run -- createwallet
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
    std.process.exit(7);
}
