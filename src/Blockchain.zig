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
const UTXOcache = @import("UTXOcache.zig");

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

//READ: https://en.bitcoin.it/wiki/Block_hashing_algorithm
//https://en.bitcoin.it/wiki/Proof_of_work https://en.bitcoin.it/wiki/Hashcash

last_hash: Hash,
db: Lmdb,
arena: std.mem.Allocator,

//TODO:organise and document exit codes
pub fn getChain(lmdb: Lmdb, arena: std.mem.Allocator) BlockChain {
    const txn = lmdb.startTxn(.ro);

    const db = txn.openDb(BLOCK_DB);
    defer db.doneReading();

    if (db.get(Hash, LAST)) |last_block_hash| {
        return .{ .last_hash = last_block_hash, .db = db, .arena = arena };
    } else |_| {
        std.log.err("create a blockchain with creatchain command before using any other command", .{});
        std.process.exit(@intFromEnum(ExitCodes.blockchain_not_found));
    }
}

///create a new BlockChain
pub fn newChain(lmdb: Lmdb, arena: std.mem.Allocator, address: Wallets.Address) BlockChain {
    if (!Wallet.validateAddress(address)) {
        std.log.err("blockchain address {s} is invalid", .{address});
        std.process.exit(@intFromEnum(ExitCodes.invalid_wallet_address));
    }
    var buf: [1024 * 6]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const allocator = fba.allocator();

    const coinbase_tx = Transaction.initCoinBaseTx(allocator, address, WALLET_STORAGE);
    const genesis_block = Block.genesisBlock(allocator, coinbase_tx);

    const txn = lmdb.startTxn(.rw);

    txn.setDbOpt(BLOCK_DB, .{});
    const db = txn.openDb(BLOCK_DB);
    defer db.commitTxns();

    db.put(LAST, genesis_block.hash) catch |newchain_err| switch (newchain_err) {
        error.KeyAlreadyExist => {
            std.log.err("Attempting to create a new blockchain at address '{s}' while a blockchain already exist", .{
                address,
            });
            std.process.exit(@intFromEnum(ExitCodes.blockchain_already_exist));
        },
        else => unreachable,
    };
    db.putAlloc(allocator, genesis_block.hash[0..], genesis_block) catch unreachable;

    info("new blockchain is create with address '{s}'\nhash of the created blockchain is '{X}'", .{
        address,
        fh(fmtHash(genesis_block.hash)[0..]),
    });
    info("You get a reward of RBC {d} for mining the transaction", .{Transaction.SUBSIDY});

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

    const txn = bc.db.startTxn(.rw);
    const db = txn.openDb(BLOCK_DB);
    defer db.commitTxns();

    db.putAlloc(allocator, new_block.hash[0..], new_block) catch unreachable;
    db.update(LAST, new_block.hash) catch unreachable;
    bc.last_hash = new_block.hash;

    return new_block;
}

///find all unspent transactions and map them with their Transaction.TxID
//TODO: add test for *UTX* and Tx Output fn's
pub fn findAndMapAllTxIDsToUTxOs(bc: BlockChain) std.AutoArrayHashMap(Transaction.TxID, []const Transaction.TxOutput) {
    //TODO: find a way to cap the max stack usage
    //INITIA_IDEA: copy relevant data and free blocks
    var buf: [1024 * 950]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(buf[0..]);
    const allocator = fba.allocator();

    var unspent_txos = std.AutoArrayHashMap(Transaction.TxID, []const Transaction.TxOutput).init(bc.arena);
    var spent_txos = TxMap.init(allocator);

    var bc_itr = BlockIterator.iterator(bc.arena, bc.db, bc.last_hash);

    while (bc_itr.next()) |block| {
        for (block.transactions.items) |tx| {
            output: for (tx.tx_out.items, 0..) |txoutput, txindex| {
                //was the output spent? We skip those that were referenced in inputs (their values were moved to
                //other outputs, thus we cannot count them)
                if (spent_txos.get(tx.id)) |spent_output_index| {
                    if (spent_output_index == txindex) {
                        continue :output;
                    }
                }

                //If an output was locked by the same pub_key_hash we’re searching unspent transaction outputs for,
                //then this is the output we want
                // if (txoutput.isLockedWithKey(pub_key_hash)) {

                // unspent_txos.append(tx) catch unreachable;
                // }
                if (unspent_txos.get(tx.id)) |output| {
                    const outputs = std.mem.concat(bc.arena, Transaction.TxOutput, &.{ output, &.{txoutput} }) catch unreachable;
                    unspent_txos.putNoClobber(tx.id, outputs) catch unreachable;
                } else {
                    const txoutput_copy = bc.arena.dupe(Transaction.TxOutput, &.{txoutput}) catch unreachable;
                    unspent_txos.putNoClobber(tx.id, txoutput_copy) catch unreachable;
                }
            }

            //we gather all inputs that could unlock outputs locked with the provided pub_key_hash (this doesn’t apply
            //to coinbase transactions, since they don’t unlock outputs)
            if (!tx.isCoinBaseTx()) {
                for (tx.tx_in.items) |txinput| {
                    //     if (txinput.usesKey(pub_key_hash)) {
                    //         spent_txos.putNoClobber(txinput.out_id, txinput.out_index) catch unreachable;
                    //     }
                    spent_txos.putNoClobber(txinput.out_id, txinput.out_index) catch unreachable;
                }
            }
        }

        if (block.previous_hash[0] == '\x00') {
            break;
        }
    }

    return unspent_txos;
}

///finds a transaction by its ID.This is used to build the `PrevTxMap`
fn findTx(self: BlockChain, tx_id: Transaction.TxID) Transaction {
    var itr = BlockIterator.iterator(self.arena, self.db, self.last_hash);

    while (itr.next()) |block| {
        for (block.transactions.items) |tx| {
            if (std.mem.eql(u8, tx.id[0..], tx_id[0..])) return tx;
        }
        if (block.previous_hash[0] == '\x00') break;
    }
    unreachable;
}

///create a new Transaction by moving value from one address to another
fn newUTx(self: BlockChain, utxo_cache: UTXOcache, amount: usize, from: Wallets.Address, to: Wallets.Address) Transaction {
    var input = std.ArrayListUnmanaged(Transaction.TxInput){};
    var output = std.ArrayListUnmanaged(Transaction.TxOutput){};

    //Before creating new outputs, we first have to find all unspent outputs and ensure that they store enough value.
    const spendable_txns = utxo_cache.findSpendableOutputs(Wallet.getPubKeyHash(from), amount);
    const accumulated_amount = spendable_txns.accumulated_amount;
    var unspent_output = spendable_txns.unspent_output;

    if (accumulated_amount < amount) {
        std.log.err("spendable amount is {d}", .{accumulated_amount});
        std.log.err("not enough funds to transfer RBC {d} from '{s}' to '{s}'", .{ amount, from, to });
        std.process.exit(@intFromEnum(ExitCodes.insufficient_wallet_balance));
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

pub fn sendValue(self: *BlockChain, cache: UTXOcache, amount: usize, from: Wallets.Address, to: Wallets.Address) void {
    assert(amount > 0);
    assert(!std.mem.eql(u8, from[0..], to[0..]));

    if (!Wallet.validateAddress(from)) {
        std.log.err("sender address {s} is invalid", .{from});
        std.process.exit(@intFromEnum(ExitCodes.invalid_wallet_address));
    }
    if (!Wallet.validateAddress(to)) {
        std.log.err("recipient address {s} is invalid", .{to});
        std.process.exit(@intFromEnum(ExitCodes.invalid_wallet_address));
    }

    var new_transaction = self.newUTx(cache, amount, from, to);
    //The reward is just a coinbase transaction. When a mining node starts mining a new block,
    //it takes transactions from the queue and prepends a coinbase transaction to them.
    //The coinbase transaction’s only output contains miner’s public key hash.
    //In this implementation, the one who creates a transaction mines the new block, and thus, receives a reward.
    const rewardtx = Transaction.initCoinBaseTx(self.arena, from, WALLET_STORAGE);
    const block = self.mineBlock(&.{ rewardtx, new_transaction });

    cache.update(block);
}

test "getBalance , sendValue" {
    if (true) return error.SkipZigTest;
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
