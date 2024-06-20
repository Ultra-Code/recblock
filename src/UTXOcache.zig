const std = @import("std");
const Lmdb = @import("Lmdb.zig");
const BlockChain = @import("Blockchain.zig");
const Wallets = @import("Wallets.zig");
const Wallet = Wallets.Wallet;
const Transaction = @import("Transaction.zig");
const LmdbCursor = @import("LmdbCursor.zig");
const ExitCodes = @import("utils.zig").ExitCodes;
//since key type is already know find a way to specify LmdbCursor type without it
const Cursor = LmdbCursor.LmdbCursor(Transaction.TxID, []const Transaction.TxOutput);
const Block = @import("Block.zig");

const TxMap = BlockChain.TxMap;
const UTXOcache = @This();

pub const UTXO_DB = "chainstate";

db: Lmdb,
arena: std.mem.Allocator,

/// initializes the cache and opens it as `.ro` by default
pub fn init(db: Lmdb, arena: std.mem.Allocator) UTXOcache {
    return .{ .db = db, .arena = arena };
}

pub fn reindex(utxo_cache: UTXOcache, bc: BlockChain) void {
    const txn = utxo_cache.db.startTxn(.rw);
    txn.setDbOpt(UTXO_DB, .{});
    const db = txn.openDb(UTXO_DB);
    defer db.commitTxns();

    db.emptyDb();

    var buffer: [1024 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const allocator = fba.allocator();

    const unspent_txos = bc.findAndMapAllTxIDsToUTxOs();
    var itr = unspent_txos.iterator();

    while (itr.next()) |entry| {
        const tx_id: Transaction.TxID = entry.key_ptr.*;
        const utx_outs: []const Transaction.TxOutput = entry.value_ptr.*;

        db.putAlloc(allocator, tx_id[0..], utx_outs) catch unreachable;
    }
}

pub fn findSpendableOutputs(
    utxo_cache: UTXOcache,
    pub_key_hash: Wallets.PublicKeyHash,
    amount: usize,
) struct {
    accumulated_amount: usize,
    unspent_output: TxMap,
} {
    const db = utxo_cache.db.startTxn(.ro).openDb(UTXO_DB);
    defer db.doneReading();

    const cursor = Cursor.init(db);
    defer cursor.deinit();

    var buffer: [1024 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    var iterator = cursor.iterator(fba);
    defer iterator.deinit();

    var accumulated_amount: usize = 0;
    var unspent_output = TxMap.init(utxo_cache.arena);

    // const unspentTxs = self.findUTxs(pub_key_hash);
    var next = iterator.start();
    // //The method iterates over all unspent transactions and accumulates their values.
    while (next) |entry| : (next = iterator.next()) {
        //accumulated value and output indices grouped by transaction IDs. We don’t want to take more than we’re going to spend.
        const unspent_txos = entry.value;
        for (unspent_txos, 0..) |output, out_index| {
            if (output.isLockedWithKey(pub_key_hash) and accumulated_amount < amount) {
                const unspent_output_txid = entry.key;
                accumulated_amount += output.value;
                unspent_output.putNoClobber(unspent_output_txid, out_index) catch unreachable;
            }
        }
    }

    return .{ .accumulated_amount = accumulated_amount, .unspent_output = unspent_output };
}

///find unspent transaction outputs
pub fn findUnlockableOutputs(utxo_cache: UTXOcache, pub_key_hash: Wallets.PublicKeyHash) []const Transaction.TxOutput {
    const db = utxo_cache.db.startTxn(.ro).openDb(UTXO_DB);
    defer db.doneReading();

    const cursor = Cursor.init(db);
    defer cursor.deinit();

    var buffer: [1024 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(buffer[0..]);

    var utx_output_list = std.ArrayList(Transaction.TxOutput).init(utxo_cache.arena);
    var iterator = cursor.iterator(fba);
    defer iterator.deinit();

    var iter = iterator.start();
    while (iter) |entry| : (iter = iterator.next()) {
        for (entry.value) |output| {
            if (output.isLockedWithKey(pub_key_hash)) {
                utx_output_list.append(output) catch unreachable;
            }
        }
    }
    return utx_output_list.toOwnedSlice() catch unreachable;
}

pub fn update(utxo_cache: UTXOcache, block: Block) void {
    const db = utxo_cache.db.startTxn(.rw).openDb(UTXO_DB);
    defer db.commitTxns();

    var buffer: [1024 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const allocator = fba.allocator();

    for (block.transactions.items) |tx| {
        if (tx.isCoinBaseTx() == false) {
            var updated_output = std.ArrayList(Transaction.TxOutput).init(allocator);
            defer updated_output.deinit();

            for (tx.tx_in.items) |txin| {
                const utxos = db.getAlloc([]const Transaction.TxOutput, allocator, txin.out_id[0..]) catch unreachable;

                //Updating means removing spent outputs and adding unspent outputs from newly mined transactions.
                for (utxos, 0..) |output, out_idx| {
                    //if the out_idx isn't equal to the txin.out_idx it means that,that output hasn't been spent
                    if (out_idx != txin.out_index) {
                        updated_output.append(output) catch unreachable;
                    }
                }

                //if all the outputs of the txin are spent then we need to remove the outputs of that TxID from the
                //cache
                if (updated_output.items.len == 0) {
                    //TODO: check that this doesn't affect the preoviously inserted outputs
                    //I suspect this fuction is the cause of the current bug so I have to test and fuzz my understanding
                    //hear thoroughly
                    db.del(txin.out_id[0..], .single, {}) catch unreachable;
                } else {
                    //update the cache with the new output_list of the txin.out_id
                    db.updateAlloc(allocator, txin.out_id[0..], updated_output.items) catch unreachable;
                }
            }
        }

        var uoutput = std.ArrayList(Transaction.TxOutput).initCapacity(allocator, tx.tx_out.items.len) catch unreachable;
        defer uoutput.deinit();

        //TODO: maybe this should be a single transaction so that an ArrayList woun't be needed
        for (tx.tx_out.items) |txout| {
            uoutput.append(txout) catch unreachable;
        }

        //TODO: maybe we should put value rather
        //check reference guide to make sure I'm on the right path
        db.putAlloc(allocator, tx.id[0..], uoutput.items) catch |key_data_already_exist| switch (key_data_already_exist) {
            //when the exact same key and data pair already exist in the db
            error.KeyAlreadyExist => {
                const previous_outputs = db.getAlloc([]const Transaction.TxOutput, allocator, tx.id[0..]) catch unreachable;
                var previous_value_sum: usize = 0;

                for (previous_outputs) |poutputs| {
                    previous_value_sum += poutputs.value;
                }
                var current_value_sum = previous_value_sum;
                for (uoutput.items) |poutputs| {
                    current_value_sum += poutputs.value;
                }

                const new_output_with_all_value = Transaction.TxOutput{
                    .value = current_value_sum,
                    .pub_key_hash = previous_outputs[0].pub_key_hash,
                };
                db.updateAlloc(allocator, tx.id[0..], @as([]const Transaction.TxOutput, &.{new_output_with_all_value})) catch unreachable;
            },
            else => unreachable,
        };
    }
}

pub fn getBalance(cache: UTXOcache, address: Wallets.Address) usize {
    if (!Wallet.validateAddress(address)) {
        std.log.err("address {s} is invalid", .{address});
        std.process.exit(@intFromEnum(ExitCodes.invalid_wallet_address));
    }
    var balance: usize = 0;
    const utxos = cache.findUnlockableOutputs(Wallet.getPubKeyHash(address));

    for (utxos) |utxo| {
        balance += utxo.value;
    }
    return balance;
}
