const std = @import("std");
const mem = std.mem;
const panic = std.debug.panic;
const info = std.log.info;
const Blake3 = std.crypto.hash.Blake3;
const fmt = std.fmt;
const fh = fmt.fmtSliceHexUpper;
const assert = std.debug.assert;

const BlockChain = @This();

const Transaction = @import("Transaction.zig");
const Block = @import("Block.zig");
const Lmdb = @import("Lmdb.zig");
const Iterator = @import("Iterator.zig");
const Wallets = @import("Wallets.zig");
const utils = @import("utils.zig");

const Wallet = Wallets.Wallet;
const Address = Wallets.Address;
const BlockIterator = Iterator.BlockIterator;
const fmtHash = utils.fmtHash;
const ExitCodes = utils.ExitCodes;

const OutputIndex = usize;
pub const TxMap = std.AutoHashMap(Transaction.TxID, OutputIndex);
pub const Hash = [Blake3.digest_length]u8;

pub const BLOCK_DB = "blocks";
pub const LAST = "last";
pub const WALLET_STORAGE = "db/wallet.dat";

//READ: https://en.bitcoin.it/wiki/Block_hashing_algorithm https://en.bitcoin.it/wiki/Proof_of_work https://en.bitcoin.it/wiki/Hashcash

last_hash: Hash,
db: Lmdb,
arena: std.mem.Allocator,
wallet_path: []const u8,

//TODO:organise and document exit codes
pub fn getChain(db: Lmdb, arena: std.mem.Allocator) BlockChain {
    const txn = db.startTxn(.rw, BLOCK_DB);
    defer txn.commitTxns();

    if (txn.get(Hash, LAST)) |last_block_hash| {
        return .{ .last_hash = last_block_hash, .db = db, .arena = arena };
    } else |_| {
        std.log.err("create a blockchain with creatchain command before using any other command", .{});
        std.process.exit(@enumToInt(ExitCodes.blockchain_not_found));
    }
}

///create a new BlockChain
pub fn newChain(db: Lmdb, arena: std.mem.Allocator, address: Wallets.Address) BlockChain {
    if (!Wallet.validateAddress(address)) {
        std.log.err("blockchain address {s} is invalid", .{address});
        std.process.exit(@enumToInt(ExitCodes.invalid_wallet_address));
    }
    var buf: [1024 * 6]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const allocator = fba.allocator();

    const coinbase_tx = Transaction.initCoinBaseTx(allocator, address, WALLET_STORAGE);
    const genesis_block = Block.genesisBlock(allocator, coinbase_tx);

    const txn = db.startTxn(.rw, BLOCK_DB);
    defer txn.commitTxns();

    txn.put(LAST, genesis_block.hash) catch |newchain_err| switch (newchain_err) {
        error.KeyAlreadyExist => {
            std.log.err("Attempting to create a new blockchain at address '{s}' while a blockchain already exist", .{
                address,
            });
            std.process.exit(@enumToInt(ExitCodes.blockchain_already_exist));
        },
        else => unreachable,
    };
    txn.putAlloc(allocator, WALLET, wallet_path) catch unreachable;
    txn.putAlloc(allocator, genesis_block.hash[0..], genesis_block) catch unreachable;

    info("new blockchain is create with address '{s}'\nhash of the created blockchain is '{X}'", .{
        address,
        fh(fmtHash(genesis_block.hash)[0..]),
    });
    info("You get a reward of RBC {d} for mining the coinbase transaction", .{Transaction.SUBSIDY});

    return .{ .last_hash = genesis_block.hash, .db = db, .arena = arena };
}

///add a new Block to the BlockChain
pub fn mineBlock(bc: *BlockChain, transactions: []const Transaction) Block {
    for (transactions) |tx| {
        assert(bc.verifyTx(tx) == true);
    }

    var buf: [8096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const allocator = fba.allocator();

    const new_block = Block.newBlock(bc.arena, bc.last_hash, transactions);
    std.log.info("new transaction is '{X}'", .{fh(fmtHash(new_block.hash)[0..])});

    assert(new_block.validate() == true);

    const txn = bc.db.startTxn(.rw, BLOCK_DB);
    defer txn.commitTxns();

    txn.putAlloc(allocator, new_block.hash[0..], new_block) catch unreachable;
    txn.update(LAST, new_block.hash) catch unreachable;
    bc.last_hash = new_block.hash;

    return new_block;
}

///find unspent transactions
//TODO: add test for *UTX* and Tx Output fn's
fn findUTxs(bc: BlockChain, pub_key_hash: Wallets.PublicKeyHash) []const Transaction {
    //TODO: find a way to cap the max stack usage
    //INITIA_IDEA: copy relevant data and free blocks
    var buf: [1024 * 950]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(buf[0..]);
    const allocator = fba.allocator();

    var unspent_txos = std.ArrayList(Transaction).init(bc.arena);
    var spent_txos = TxMap.init(allocator);

    var bc_itr = Iterator.iterator(allocator, bc.db, bc.last_hash);

    while (bc_itr.next()) |block| {
        for (block.transactions.items) |tx| {
            output: for (tx.tx_out.items) |txoutput, txindex| {
                //was the output spent? We skip those that were referenced in inputs (their values were moved to
                //other outputs, thus we cannot count them)
                if (spent_txos.get(tx.id)) |spent_output_index| {
                    if (spent_output_index == txindex) {
                        continue :output;
                    }
                }

                //If an output was locked by the same pub_key_hash we’re searching unspent transaction outputs for,
                //then this is the output we want
                if (txoutput.isLockedWithKey(pub_key_hash)) {
                    unspent_txos.append(tx) catch unreachable;
                }
            }

            //we gather all inputs that could unlock outputs locked with the provided pub_key_hash (this doesn’t apply
            //to coinbase transactions, since they don’t unlock outputs)
            if (!tx.isCoinBaseTx()) {
                for (tx.tx_in.items) |txinput| {
                    if (txinput.usesKey(pub_key_hash)) {
                        spent_txos.putNoClobber(txinput.out_id, txinput.out_index) catch unreachable;
                    }
                }
            }
        }

        if (block.previous_hash[0] == '\x00') {
            break;
        }
    }
    return unspent_txos.toOwnedSlice();
}

///find unspent transaction outputs
fn findUTxOs(self: BlockChain, pub_key_hash: Wallets.PublicKeyHash) []const Transaction.TxOutput {
    var tx_output_list = std.ArrayList(Transaction.TxOutput).init(self.arena);

    const unspent_txs = self.findUTxs(pub_key_hash);

    for (unspent_txs) |tx| {
        for (tx.tx_out.items) |output| {
            if (output.isLockedWithKey(pub_key_hash)) {
                tx_output_list.append(output) catch unreachable;
            }
        }
    }
    return tx_output_list.toOwnedSlice();
}

///create a new Transaction by moving value from one address to another
fn newUTx(self: BlockChain, amount: usize, from: Wallets.Address, to: Wallets.Address) Transaction {
    var input = std.ArrayListUnmanaged(Transaction.TxInput){};
    var output = std.ArrayListUnmanaged(Transaction.TxOutput){};

    //Before creating new outputs, we first have to find all unspent outputs and ensure that they store enough value.
    const spendable_txns = self.findSpendableOutputs(Wallet.getPubKeyHash(from), amount);
    const accumulated_amount = spendable_txns.accumulated_amount;
    var unspent_output = spendable_txns.unspent_output;

    if (accumulated_amount < amount) {
        std.log.err("not enough funds to transfer RBC {d} from '{s}' to '{s}'", .{ amount, from, to });
        std.process.exit(@enumToInt(ExitCodes.insufficient_wallet_balance));
    }

    //Build a list of inputs
    //for each found output an input referencing it is created.
    var itr = unspent_output.iterator();
    const wallets = Wallets.getWallets(self.arena, WALLET_STORAGE);
    const froms_wallet = wallets.getWallet(from);

    while (itr.next()) |kv| {
        const txid = kv.key_ptr.*;
        const out_index = kv.value_ptr.*;

        input.append(
            self.arena,
            Transaction.TxInput{
                .out_id = txid,
                .out_index = out_index,
                .sig = std.mem.zeroes(Wallets.Signature),
                .pub_key = froms_wallet.wallet_keys.public_key,
            },
        ) catch unreachable;
    }

    //Build a list of outputs
    //The output that’s locked with the receiver address. This is the actual transferring of coins to other address.
    output.append(self.arena, Transaction.TxOutput{ .value = amount, .pub_key_hash = Wallet.getPubKeyHash(to) }) catch unreachable;

    //The output that’s locked with the sender address. This is a change. It’s only created when unspent outputs hold
    //more value than required for the new transaction. Remember: outputs are indivisible.
    if (accumulated_amount > amount) {
        output.append(self.arena, Transaction.TxOutput{ .value = (accumulated_amount - amount), .pub_key_hash = Wallet.getPubKeyHash(from) }) catch unreachable;
    }

    var newtx = Transaction.newTx(input, output);
    //we sign the transaction with the keys of the owner/sender of the value
    self.signTx(&newtx, froms_wallet.wallet_keys);
    return newtx;
}

fn findSpendableOutputs(self: BlockChain, pub_key_hash: Wallets.PublicKeyHash, amount: usize) struct {
    accumulated_amount: usize,
    unspent_output: TxMap,
} {
    var unspent_output = TxMap.init(self.arena);

    const unspentTxs = self.findUTxs(pub_key_hash);

    var accumulated_amount: usize = 0;

    // //The method iterates over all unspent transactions and accumulates their values.
    spendables: for (unspentTxs) |tx| {
        //When the accumulated value is more or equals to the amount we want to transfer, it stops and returns the
        //accumulated value and output indices grouped by transaction IDs. We don’t want to take more than we’re going to spend.
        for (tx.tx_out.items) |output, out_index| {
            if (output.isLockedWithKey(pub_key_hash) and accumulated_amount < amount) {
                accumulated_amount += output.value;
                unspent_output.putNoClobber(tx.id, out_index) catch unreachable;

                if (accumulated_amount >= amount) {
                    break :spendables;
                }
            }
        }
    }

    return .{ .accumulated_amount = accumulated_amount, .unspent_output = unspent_output };
}

///finds a transaction by its ID.This is used to build the `PrevTxMap`
fn findTx(self: BlockChain, tx_id: Transaction.TxID) Transaction {
    var itr = Iterator.iterator(self.arena, self.db, self.last_hash);

    while (itr.next()) |block| {
        for (block.transactions.items) |tx| {
            if (std.mem.eql(u8, tx.id[0..], tx_id[0..])) return tx;
        }
        if (block.previous_hash[0] == '\x00') break;
    }
    unreachable;
}

///take a transaction `tx` finds all previous transactions it references and sign it with KeyPair `wallet_keys`
fn signTx(self: BlockChain, tx: *Transaction, wallet_keys: Wallet.KeyPair) void {
    //Coinbase transactions are not signed because they don't contain real inputs
    if (tx.isCoinBaseTx()) return;

    var buf: [1024 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);

    var prev_txs = Transaction.PrevTxMap.init(fba.allocator());

    for (tx.tx_in.items) |value_in| {
        const found_tx = self.findTx(value_in.out_id);
        prev_txs.putNoClobber(value_in.out_id, found_tx) catch unreachable;
    }
    tx.sign(wallet_keys, prev_txs, fba.allocator());
}

///take a transaction `tx` finds transactions it references and verify it
fn verifyTx(self: BlockChain, tx: Transaction) bool {
    if (tx.isCoinBaseTx()) {
        return true;
    }
    var buf: [1024 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);

    var prev_txs = Transaction.PrevTxMap.init(fba.allocator());

    for (tx.tx_in.items) |value_in| {
        const found_tx = self.findTx(value_in.out_id);
        prev_txs.putNoClobber(value_in.out_id, found_tx) catch unreachable;
    }
    return tx.verify(prev_txs, fba.allocator());
}

pub fn getBalance(self: BlockChain, address: Wallets.Address) usize {
    if (!Wallet.validateAddress(address)) {
        std.log.err("address {s} is invalid", .{address});
        std.process.exit(4);
    }
    var balance: usize = 0;
    const utxos = self.findUTxOs(Wallet.getPubKeyHash(address));

    for (utxos) |utxo| {
        balance += utxo.value;
    }
    return balance;
}

pub fn sendValue(self: *BlockChain, amount: usize, from: Wallets.Address, to: Wallets.Address) void {
    assert(amount > 0);
    assert(!std.mem.eql(u8, &from, &to));

    if (!Wallet.validateAddress(from)) {
        std.log.err("sender address {s} is invalid", .{from});
        std.process.exit(@enumToInt(ExitCodes.invalid_wallet_address));
    }
    if (!Wallet.validateAddress(to)) {
        std.log.err("recipient address {s} is invalid", .{to});
        std.process.exit(@enumToInt(ExitCodes.invalid_wallet_address));
    }
    var new_transaction = self.newUTx(amount, from, to);

    self.mineBlock(&.{new_transaction});
}

test "getBalance , sendValue" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath(tmp.sub_path[0..]);

    const ta = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const allocator = arena.allocator();

    const db_path = try std.cstr.addNullByte(allocator, try tmp.dir.realpathAlloc(allocator, "."));

    var db = Lmdb.initdb(db_path, .rw);
    defer db.deinitdb();

    const wallet_path = try std.fmt.allocPrint(allocator, "zig-cache/tmp/{s}/wallet.dat", .{tmp.sub_path[0..]});
    var wallets = Wallets.initWallets(allocator, wallet_path);

    const genesis_wallet = wallets.createWallet();
    var bc = newChain(db, allocator, genesis_wallet, wallets.wallet_path);

    //a reward of 10 RBC is given for mining the coinbase
    try std.testing.expectEqual(@as(usize, 10), bc.getBalance(genesis_wallet));

    const my_wallet = wallets.createWallet();
    bc.sendValue(7, genesis_wallet, my_wallet);

    try std.testing.expectEqual(@as(usize, 3), bc.getBalance(genesis_wallet));
    try std.testing.expectEqual(@as(usize, 7), bc.getBalance(my_wallet));

    bc.sendValue(2, my_wallet, genesis_wallet);

    try std.testing.expectEqual(@as(usize, 5), bc.getBalance(my_wallet));
    try std.testing.expectEqual(@as(usize, 5), bc.getBalance(genesis_wallet));
}
