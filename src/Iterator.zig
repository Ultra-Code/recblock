const std = @import("std");
const Block = @import("./Block.zig");
const Lmdb = @import("./Lmdb.zig");
const Iterator = @This();

const info = std.log.info;
const fh = std.fmt.fmtSliceHexUpper;
const utils = @import("./utils.zig");
const fmtHash = utils.fmtHash;
const BLOCK_DB = utils.BLOCK_DB;

arena: std.mem.Allocator,
db: *const Lmdb,
//Notice that an iterator initially points at the tip of a blockchain, thus blocks will be obtained from top to bottom, from newest to oldest.
current_hash: [32]u8,

pub fn iterator(fba: std.mem.Allocator, db: Lmdb, last_hash: [32]u8) Iterator {
    return .{ .arena = fba, .db = &db, .current_hash = last_hash };
}

///the returned usize is the address of the Block in memory
///the ptr can be obtained with @intToPtr
pub fn next(self: *Iterator) ?Block {
    const txn = self.db.startTxn(.ro, BLOCK_DB);
    defer txn.doneReading();

    if (txn.getAlloc(Block, self.arena, self.current_hash[0..])) |current_block| {
        self.current_hash = current_block.previous_hash;

        return current_block;
        // return @ptrToInt(current_block);
    } else |_| {
        return null;
    }
}

pub fn print(chain_iter: *Iterator) void {
    //TODO:work on converting hashes to Big endian which is usually the expected form for display
    //improve the hex formating
    info("starting blockchain iteration\n", .{});
    while (chain_iter.next()) |current_block| {
        // const current_block = @intToPtr(*Block, block);
        info("previous hash is '{X}'", .{fh(fmtHash(current_block.previous_hash)[0..])});
        info("hash of current block is '{X}'", .{fh(fmtHash(current_block.hash)[0..])});
        info("nonce is {}", .{current_block.nonce});
        info("POW: {}\n\n", .{current_block.validate()});
    }
    info("done", .{});
}
