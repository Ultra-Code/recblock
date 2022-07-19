const std = @import("std");
const Blake3 = std.crypto.hash.Blake3;
const Wallets = @import("./Wallets.zig");
const Wallet = Wallets.Wallet;
pub const TxID = [Blake3.digest_length]u8;

const serializer = @import("./serializer.zig");

//Transactions just lock values with a script, which can be unlocked only by the one who locked them.
const Transaction = @This();
const InList = std.ArrayListUnmanaged(TxInput);
const OutList = std.ArrayListUnmanaged(TxOutput);

//TxOutputs are indivisible,meaning you can't reference part of it's value
//When an output is referenced in a new transaction, it’s spent as a whole.
//And if its value is greater than required, a change is generated and sent back to the sender.
pub const TxOutput = struct {
    ///stores actual value of coins
    value: usize,
    ///coins are stored by locking them with a puzzle/key, which is stored in the pub_key
    pub_key_hash: Wallets.PublicKeyHash,
    ///simply locks an output to an `address` since When we send coins to someone, we know only their address
    pub fn lock(self: *TxOutput, address: Wallets.Address) void {
        const pub_key_hash = Wallet.getPubKeyHash(address);
        self.pub_key_hash = pub_key_hash;
    }

    ///checks if provided public key hash was used to lock the output .ie if the output can be used by the owner of the pubkey
    pub fn isLockedWithKey(self: TxOutput, pub_key_hash: Wallets.PublicKeyHash) bool {
        return std.mem.eql(u8, self.pub_key_hash[0..], pub_key_hash[0..]);
    }
};

pub const TxInput = struct {
    ///id of referenced output transaction
    out_id: TxID,
    ///index of an output in the transaction
    out_index: usize,
    ///provides signature data to be used to unlock an output’s pub_key
    sig: []const u8,

    pub_key: Wallets.PublicKey,

    ///checks that an input uses a specific key to unlock an output
    pub fn usesKey(self: TxInput, pub_key_hash: Wallets.PublicKeyHash) bool {
        const locking_hash = Wallet.hashPubKey(self.pub_key);
        return std.mem.eql(u8, locking_hash[0..], pub_key_hash[0..]);
    }
};

//hash of transaction
id: TxID,
//Inputs of a new transaction reference outputs of a previous transaction
tx_in: InList,
// Outputs are where coins are actually stored.
tx_out: OutList,

//subsidy is the amount of reward for mining
const SUBSIDY = 10;

//A coinbase transaction is a special type of transactions, which doesn’t require previously existing outputs.
//This is the reward miners get for mining new blocks.
pub fn initCoinBaseTx(arena: std.mem.Allocator, to: Wallets.Address) Transaction {
    var buf: [128]u8 = undefined;
    const data = std.fmt.bufPrint(&buf, "Reward to '{s}'", .{to}) catch unreachable;

    //the coinbase's sig contains arbituary data
    var inlist = InList{};
    const wallets = Wallets.getWallets(arena);
    const tos_wallet = wallets.getWallet(to);
    inlist.append(arena, TxInput{ .out_id = .{'0'} ** Blake3.digest_length, .out_index = std.math.maxInt(usize), .sig = data, .pub_key = tos_wallet.public_key }) catch unreachable;

    var outlist = OutList{};
    outlist.append(arena, TxOutput{ .value = SUBSIDY, .pub_key_hash = Wallet.getPubKeyHash(to) }) catch unreachable;

    var tx = Transaction{ .id = undefined, .tx_in = inlist, .tx_out = outlist };
    tx.setId();
    return tx;
}

pub fn newTx(input: InList, output: OutList) Transaction {
    var tx = Transaction{ .id = undefined, .tx_in = input, .tx_out = output };
    tx.setId();
    return tx;
}

pub fn isCoinBaseTx(self: Transaction) bool {
    return self.tx_in.items.len == 1 and self.tx_in.items[0].out_id.len == 0 and self.tx_in.items[0].out_index == std.math.maxInt(usize);
}

test "isCoinBaseTx" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    var coinbase = initCoinBaseTx(allocator, "testing");
    try std.testing.expect(isCoinBaseTx(coinbase));
}

///set Id of transaction
fn setId(self: *Transaction) void {
    var buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf).allocator();

    const serialized_data = serializer.serializeAlloc(fba, self);

    var hash: [Blake3.digest_length]u8 = undefined;
    Blake3.hash(serialized_data[0..], &hash, .{});
    self.id = hash;
}
