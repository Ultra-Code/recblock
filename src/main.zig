const std = @import("std");
const fmt = std.fmt;
const info = std.log.info;

const blockchain = @import("blockchain.zig");
const Block = blockchain.Block;
const BlockChain = blockchain.BlockChain;
const Lmdb = blockchain.Lmdb;

pub fn main() !void {
    var db_env = Lmdb.initdb("./db", .rw);
    defer db_env.deinitdb();

    const genesis_block = Block.genesisBlock();
    var bc = BlockChain.newChain(db_env, genesis_block);

    bc.addBlock("transfer 1BTC to Esteban 2638219".*);
    bc.addBlock("transfer 9BTC to Assan 238981183".*);

    var chain_iter = blockchain.ChainIterator.iterator(bc);
    //TODO:work on converting hashes to Big endian which is usually the expected form for display
    info("start iteration", .{});
    while (chain_iter.next()) |current_block| {
        // const current_block = @intToPtr(*Block, block);
        info("previous hash is '{X}'", .{fmt.fmtSliceHexUpper(current_block.previous_hash[0..])});
        info("data is '{s}'", .{current_block.data});
        info("current hash of {s} is '{X}'", .{ current_block.data, fmt.fmtSliceHexUpper(current_block.hash[0..]) });
        info("nonce is {}", .{current_block.nonce});
        info("POW: {}", .{current_block.validate()});
    }
    info("done", .{});
}

test {
    std.testing.refAllDecls(@This());
}
