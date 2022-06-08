const std = @import("std");
const fmt = std.fmt;
const info = std.log.info;

const blockchain = @import("blockchain.zig");
const Block = blockchain.Block;
const BlockChain = blockchain.BlockChain;
const Lmdb = blockchain.Lmdb;
const Cli = @import("cli.zig");

pub fn main() !void {
    var db_env = Lmdb.initdb("./db", .rw);
    defer db_env.deinitdb();

    const genesis_block = Block.genesisBlock();
    var bc = BlockChain.newChain(db_env, genesis_block);
    var cli = Cli.init(bc);
    cli.run();
}

test {
    std.testing.refAllDecls(@This());
}
