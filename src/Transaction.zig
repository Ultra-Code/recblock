const std = @import("std");
const serializer = @import("serializer.zig");

//Transactions just lock values with a script, which can be unlocked only by the one who locked them.
const Transaction = @This();
const InList = std.ArrayListUnmanaged(TxInput);
const OutList = std.ArrayListUnmanaged(TxOutput);

//TxOutputs are indivisible,meaning you can't reference part of it's value
//When an output is referenced in a new transaction, it’s spent as a whole.
//And if its value is greater than required, a change is generated and sent back to the sender.
const TxOutput = struct {
    //stores actual value of coins
    value: usize,
    //coins are stored by locking them with a puzzle/key, which is stored in the pub_key
    pub_key: []const u8,
};

const TxInput = struct {
    //id of referenced output transaction
    txid: []const u8,
    //index of an output in the transaction
    index: usize,
    //provides signature data to be used to unlock an output’s pub_key
    sig: []const u8,
};

//hash of transaction
id: [32]u8,
//Inputs of a new transaction reference outputs of a previous transaction
tx_in: InList,
// Outputs are where coins are actually stored.
tx_out: OutList,

//subsidy is the amount of reward for mining
const SUBSIDY = 10;

//A coinbase transaction is a special type of transactions, which doesn’t require previously existing outputs.
//This is the reward miners get for mining new blocks.
pub fn initCoinBaseTx(arena: std.mem.Allocator, to: []const u8) Transaction {
    var buf: [128]u8 = undefined;
    const data = std.fmt.bufPrint(&buf, "Reward to '{s}'", .{to}) catch unreachable;

    //the coinbase's sig contains arbituary data
    var inlist = InList{};
    inlist.append(arena, TxInput{ .txid = "", .index = 0, .sig = data }) catch unreachable;

    var outlist = OutList{};
    outlist.append(arena, TxOutput{ .value = SUBSIDY, .pub_key = to }) catch unreachable;

    var tx = Transaction{ .id = undefined, .tx_in = inlist, .tx_out = outlist };
    tx.setId();
    return tx;
}

///set Id of transaction
fn setId(self: *Transaction) void {
    var buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf).allocator();

    const serialized_data = serializer.serializeAlloc(fba, self);

    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(serialized_data[0..], &hash, .{});
    self.id = hash;
}

///release allocated Transactions
pub fn deinit(self: *Transaction, arena: std.mem.Allocator) void {
    self.tx_in.deinit(arena);
    self.tx_out.deinit(arena);
}
