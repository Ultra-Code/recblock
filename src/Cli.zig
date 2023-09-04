const std = @import("std");
const BlockChain = @import("Blockchain.zig");
const Wallets = @import("Wallets.zig");
const Address = Wallets.Address;
const mem = std.mem;
const Allocator = mem.Allocator;
const Iterator = @import("Iterator.zig");
const Lmdb = @import("Lmdb.zig");
const UTXOcache = @import("UTXOcache.zig");
const ExitCodes = @import("utils.zig").ExitCodes;
const BlockIterator = Iterator.BlockIterator;
const WALLET_STORAGE = BlockChain.WALLET_STORAGE;

const Cli = @This();

const Cmd = enum {
    createchain,
    send,
    getbalance,
    help,
};

arena: Allocator,

pub fn init(arena: Allocator) Cli {
    return .{ .arena = arena };
}

//TODO: the whole system interface should by accessed from cli for consistency
pub fn createchain(db_env: Lmdb, utxo_cache: UTXOcache, arena: Allocator, bc_address: Address) void {
    const bc = BlockChain.newChain(db_env, arena, bc_address);

    utxo_cache.reindex(bc);
}

pub fn sendAmount(db: Lmdb, cache: UTXOcache, arena: Allocator, amount: usize, from_address: Address, to_address: Address) void {
    var bc = BlockChain.getChain(db, arena);

    bc.sendValue(cache, amount, from_address, to_address);
}

pub fn getBalance(cache: UTXOcache, users_address: Address) usize {
    const balance = cache.getBalance(users_address);
    return balance;
}

pub fn printchain(db: Lmdb, arena: Allocator) void {
    const bc = BlockChain.getChain(db, arena);

    var chain_iter = BlockIterator.iterator(bc.arena, bc.db, bc.last_hash);
    chain_iter.print();
}

pub fn createwalletWithPath(arena: Allocator, wallet_path: []const u8) Address {
    const wallets = Wallets.initWallets(arena, wallet_path);
    const wallet_address = wallets.createWallet();
    return wallet_address;
}
pub fn createwallet(arena: Allocator) Address {
    const wallets = Wallets.initWallets(arena, WALLET_STORAGE);
    const wallet_address = wallets.createWallet();
    return wallet_address;
}

pub fn list_wallet_addresses(wallets: Wallets) void {
    const address_list = wallets.getAddresses();

    for (address_list, 0..) |address, index| {
        std.log.info("address {}\n{s}\n", .{ index, address });
    }
}

pub fn listaddress(arena: Allocator) void {
    const wallets = Wallets.getWallets(arena, WALLET_STORAGE);
    const address_list = wallets.getAddresses();

    for (address_list, 0..) |address, index| {
        std.log.info("address {}\n{s}\n", .{ index, address });
    }
}

pub fn run(self: Cli) void {
    var buf: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);

    var itr = std.process.argsWithAllocator(fba.allocator()) catch unreachable;
    defer itr.deinit();

    _ = itr.skip(); //skip name of program

    while (itr.next()) |argv| {
        if (mem.eql(u8, argv, "clean")) {
            std.fs.cwd().deleteTree("db") catch unreachable;
            return;
        }

        const db_env = Lmdb.initdb("db", .rw);
        defer db_env.deinitdb();

        const cache = UTXOcache.init(db_env, self.arena);

        if (mem.eql(u8, argv, "createchain")) {
            const chain_name = itr.next();

            if (chain_name) |name| {
                const bc_address = mem.bytesAsSlice(Address, name)[0];

                createchain(db_env, cache, self.arena, bc_address);
            } else {
                printUsage(.createchain);
            }
        } else if (mem.eql(u8, argv, "send")) {
            if (itr.next()) |amount_option| {
                if (mem.eql(u8, amount_option, "--amount")) {
                    const amount_value = itr.next().?;

                    if (itr.next()) |from_option| {
                        if (mem.eql(u8, from_option, "--from")) {
                            const from_address = mem.bytesAsSlice(Address, itr.next().?)[0];

                            if (itr.next()) |to_option| {
                                if (mem.eql(u8, to_option, "--to")) {
                                    const to_address = mem.bytesAsSlice(Address, itr.next().?)[0];
                                    const amount = std.fmt.parseUnsigned(usize, amount_value, 10) catch unreachable;

                                    sendAmount(db_env, cache, self.arena, amount, from_address, to_address);

                                    std.debug.print("done sending RBC {d} from '{s}' to '{s}'\n", .{ amount, from_address, to_address });
                                    std.debug.print("'{[from_address]s}' now has a balance of RBC {[from_balance]d} and '{[to_address]s}' a balance of RBC {[to_balance]d}\n", .{
                                        .from_address = from_address,
                                        .from_balance = cache.getBalance(from_address),
                                        .to_address = to_address,
                                        .to_balance = cache.getBalance(to_address),
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
        } else if (mem.eql(u8, argv, "getbalance")) {
            if (itr.next()) |address| {
                const users_address = mem.bytesAsSlice(Address, address)[0];

                const balance = getBalance(cache, users_address);

                std.debug.print("'{[address]s}' has a balance of RBC {[balance]d}\n", .{ .address = users_address, .balance = balance });
            } else {
                printUsage(.getbalance);
            }
        } else if (mem.eql(u8, argv, "printchain")) {
            printchain(db_env, self.arena);
        } else if (mem.eql(u8, argv, "createwallet")) {
            const wallet_address = createwallet(self.arena);
            std.debug.print("Your new address is '{[address]s}'\n", .{ .address = wallet_address });
        } else if (mem.eql(u8, argv, "listaddress")) {
            listaddress(self.arena);
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
                \\eg.zig build run -- createchain "wallet address"
                \\
            , .{});
        },
        .help => {
            std.debug.print(
                \\Usage:
                \\eg.zig build run -- createchain "wallet address"
                \\OR
                \\zig build run -- printchain
                \\OR
                \\zig build run -- createwallet
                \\OR
                \\zig build run -- listaddress
                \\OR
                \\zig build run -- getbalance "wallet address"
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
    std.process.exit(@intFromEnum(ExitCodes.invalid_cli_argument));
}
