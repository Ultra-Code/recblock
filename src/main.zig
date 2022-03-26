const std = @import("std");
const fmt = std.fmt;
const print = std.debug.print;

const blockchain = @import("blockchain.zig");
const Block = blockchain.Block;
const BlockChain = blockchain.BlockChain;
const Lmdb = blockchain.Lmdb;

//TODO:maybe add an arena allocator to simplify memory management
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = gpa.allocator();

    const HOME = std.os.getenv("HOME").?;
    var dir_buf: [64]u8 = undefined;
    const db_dir = fmt.bufPrintZ(&dir_buf, "{[HOME]s}/{[db_dir]s}", .{
        .HOME = HOME,
        .db_dir = "repos/zig/recblock/db/",
    }) catch unreachable;

    var db = Lmdb.initdb(db_dir, .rw);
    defer db.deinitdb();

    var genesis_block = Block.genesisBlock();
    var bc = BlockChain.newChain(allocator, db, genesis_block);
    defer bc.deinit();

    bc.addBlock("transfer 1BTC to Esteban 2638219".*);
    bc.addBlock("transfer 9BTC to Assan 238981183".*);

    var iter = bc.blocks.iterator();
    while (iter.next()) |block| {
        print("\nprevious hash is '{}'\n", .{fmt.fmtSliceHexUpper(block.previous_hash[0..])});
        print("data is '{s}'\n", .{block.data});
        print("current hash of {s} is '{}'\n", .{ block.data, fmt.fmtSliceHexUpper(block.hash[0..]) });
        print("nonce is {}\n", .{block.nonce});
        print("POW: {}\n", .{block.validate()});
    }
}
