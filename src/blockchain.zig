const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const panic = std.debug.panic;
const info = std.log.info;
const crypto = std.crypto;
const sha256 = crypto.hash.sha2.Sha256;
const fmt = std.fmt;
const assert = std.debug.assert;

pub const Lmdb = @import("lmdb.zig").Lmdb;
pub const BLOCK_DB = "blocks";

const Transaction = @import("Transaction.zig");

//TARGET_ZERO_BITS must be a multiple of 4 and it determines the number of zeros in the target hash which determines difficult
//The higer TARGET_ZERO_BITS the harder or time consuming it is to find a hash
//NOTE: when we define a target adjusting algorithm this won't be a global constant anymore
//it specifies the target hash which is used to check hashes which are valid
//a block is only accepted by the network if its hash meets the network's difficulty target
//the number of leading zeros in the target serves as a good approximation of the current difficult
const TARGET_ZERO_BITS = 8;

pub const Block = struct {
    //when the block is created
    timestamp: i64,
    //difficulty bits is the block header storing the difficulty at which the block was mined
    difficulty_bits: u7 = TARGET_ZERO_BITS, //u7 limit value from 0 to 127
    //Thus miners must discover by brute force the "nonce" that, when included in the block, results in an acceptable hash.
    nonce: usize = 0,
    //the actual valuable information contained in the block .eg Transactions
    transactions: std.ArrayListUnmanaged(Transaction),
    //stores the hash of the previous block
    previous_hash: [32]u8,
    //hash of the current block
    hash: [32]u8 = undefined,

    pub fn genesisBlock(arena: std.mem.Allocator, coinbase: Transaction) Block {
        var genesis_block = Block{
            .timestamp = std.time.timestamp(),
            .transactions = std.ArrayListUnmanaged(Transaction){},
            .previous_hash = undefined,
        };
        genesis_block.transactions.append(arena, coinbase) catch unreachable;
        const pow_result = genesis_block.POW();
        genesis_block.hash = pow_result.hash;
        genesis_block.nonce = pow_result.nonce;
        return genesis_block;
    }

    pub fn deinit(self: *Block, arena: std.mem.Allocator) void {
        self.transactions.deinit(arena);
    }

    ///Validate POW
    pub fn validate(block: Block) bool {
        const target_hash = getTargetHash(block.difficulty_bits);

        const hash_int = block.hashBlock(block.nonce);

        const is_block_valid = if (hash_int < target_hash) true else false;
        return is_block_valid;
    }

    fn hashBlock(self: Block, nonce: usize) u256 {
        //TODO : optimize the sizes of these buffers base on the base and use exactly the amount that is needed
        var time_buf: [16]u8 = undefined;
        var bits_buf: [3]u8 = undefined;
        var nonce_buf: [16]u8 = undefined;

        const timestamp = fmt.bufPrintIntToSlice(&time_buf, self.timestamp, 16, .lower, .{});
        const difficulty_bits = fmt.bufPrintIntToSlice(&bits_buf, self.difficulty_bits, 16, .lower, .{});

        const nonce_val = fmt.bufPrintIntToSlice(&nonce_buf, nonce, 16, .lower, .{});

        var buf: [4096]u8 = undefined;

        //timestamp ,previous_hash and hash form the BlockHeader
        const block_headers = fmt.bufPrint(&buf, "{[previous_hash]s}{[transactions]s}{[timestamp]s}{[difficulty_bits]s}{[nonce]s}", .{
            .previous_hash = self.previous_hash,
            .transactions = self.hashTxs(),
            .timestamp = timestamp,
            .difficulty_bits = difficulty_bits,
            .nonce = nonce_val,
        }) catch unreachable;

        var hash: [32]u8 = undefined;
        sha256.hash(block_headers, &hash, .{});

        const hash_int = mem.bytesToValue(u256, hash[0..]);

        return hash_int;
    }

    fn getTargetHash(target_dificulty: u7) u256 {
        //hast to be compaired with for valid hashes to prove work done
        const @"256bit": u9 = 256; //256 bit is 32 byte which is the size of a sha256 hash
        const @"1": u256 = 1; //a 32 byte integer with the value of 1
        const target_hash = @"1" << @intCast(u8, @"256bit" - target_dificulty);
        return target_hash;
    }

    ///Proof of Work mining algorithm
    ///The usize returned is the nonce with which a valid block was mined
    pub fn POW(block: Block) struct { hash: [32]u8, nonce: usize } {
        const target_hash = getTargetHash(block.difficulty_bits);

        var nonce: usize = 0;

        while (nonce < std.math.maxInt(usize)) {
            const hash_int = block.hashBlock(nonce);

            if (hash_int < target_hash) {
                return .{ .hash = @bitCast([32]u8, hash_int), .nonce = nonce };
            } else {
                nonce += 1;
            }
        }
        unreachable;
    }

    fn hashTxs(self: Block) [32]u8 {
        var txhashes: []u8 = &.{};

        var buf: [2048]u8 = undefined;
        var allocator = std.heap.FixedBufferAllocator.init(&buf).allocator();

        for (self.transactions.items) |txn| {
            txhashes = std.mem.concat(allocator, u8, &[_][]const u8{ txhashes, txn.id[0..] }) catch unreachable;
        }

        var hash: [32]u8 = undefined;
        sha256.hash(txhashes, &hash, .{});
        return hash;
    }

    ///mine a new block
    pub fn newBlock(self: *Block, arena: std.mem.Allocator, transaction: Transaction) Block {
        var new_block = Block{
            .timestamp = std.time.timestamp(),
            .transactions = self.transactions,
            .previous_hash = self.hash,
        };
        new_block.transactions.append(arena, transaction) catch unreachable;
        const pow_result = new_block.POW();
        new_block.hash = pow_result.hash;
        new_block.nonce = pow_result.nonce;
        return new_block;
    }
};

fn fmtHash(hash: [32]u8) [32]u8 {
    const hash_int = @bitCast(u256, hash);
    const big_end_hash_int = @byteSwap(u256, hash_int);
    return @bitCast([32]u8, big_end_hash_int);
}

test "Block Test" {
    var allocator = std.testing.allocator;
    var coinbase = Transaction.initCoinBaseTx(allocator, "genesis");
    defer coinbase.deinit(allocator);

    var genesis_block = Block.genesisBlock(allocator, coinbase);
    defer genesis_block.deinit(allocator);

    const new_block = genesis_block.newBlock(allocator, coinbase);
    try testing.expectEqualSlices(u8, genesis_block.hash[0..], new_block.previous_hash[0..]);
    const result = new_block.POW();
    try testing.expectEqual(result.nonce, new_block.nonce);
    try testing.expectEqualStrings(result.hash[0..], new_block.hash[0..]);
}

//READ: https://en.bitcoin.it/wiki/Block_hashing_algorithm https://en.bitcoin.it/wiki/Proof_of_work https://en.bitcoin.it/wiki/Hashcash

const LAST = "last";
pub const BlockChain = struct {
    last_hash: [32]u8,
    db: Lmdb,
    arena: std.mem.Allocator,

    ///create a new BlockChain
    pub fn newChain(db: Lmdb, arena: std.mem.Allocator, address: []const u8) BlockChain {
        const txn = db.startTxn(.rw, BLOCK_DB);
        defer txn.commitTxns();
        if (txn.get([32]u8, LAST)) |last_block_hash| {
            return .{ .last_hash = last_block_hash, .db = db, .arena = arena };
        } else |err| switch (err) {
            error.KeyNotFound => {
                const coinbase_tx = Transaction.initCoinBaseTx(arena, address);
                const genesis_block = Block.genesisBlock(arena, coinbase_tx);
                info("new blockchain created with with hash '{s}'", .{fmt.fmtSliceHexUpper(fmtHash(genesis_block.hash)[0..])});

                var buf: [2046]u8 = undefined;
                var fba = std.heap.FixedBufferAllocator.init(&buf).allocator();

                txn.putAlloc(fba, genesis_block.hash[0..], genesis_block) catch unreachable;
                txn.put(LAST, genesis_block.hash) catch unreachable;

                return .{ .last_hash = genesis_block.hash, .db = db, .arena = arena };
            },
            else => unreachable,
        }
    }

    ///add a new Block to the BlockChain
    pub fn addBlock(bc: *BlockChain, transaction: Transaction) void {
        info("Mining the block containing - '{s}'", .{fmt.fmtSliceHexUpper(transaction.id[0..])});
        const txn = bc.db.startTxn(.rw, BLOCK_DB);
        defer txn.commitTxns();

        var buf: [2046]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf).allocator();

        var previous_block = txn.getAlloc(Block, fba, bc.last_hash[0..]) catch unreachable;
        const new_block = Block.newBlock(previous_block, bc.arena, transaction);

        info("'{s}' - has a valid hash of '{}'", .{ fmt.fmtSliceHexUpper(transaction.id[0..]), fmt.fmtSliceHexUpper(new_block.hash[0..]) });
        info("nonce is {}", .{new_block.nonce});
        assert(new_block.validate() == true);
        info("POW: {}\n\n", .{new_block.validate()});

        txn.put(new_block.hash[0..], new_block) catch unreachable;
        txn.update(LAST, new_block.hash) catch unreachable;
        bc.last_hash = new_block.hash;
    }
};

pub const ChainIterator = struct {
    db: *const Lmdb,
    //Notice that an iterator initially points at the tip of a blockchain, thus blocks will be obtained from top to bottom, from newest to oldest.
    current_hash: [32]u8,

    pub fn iterator(bc: BlockChain) ChainIterator {
        return .{ .db = &bc.db, .current_hash = bc.last_hash };
    }

    ///the returned usize is the address of the Block in memory
    ///the ptr can be obtained with @intToPtr
    pub fn next(self: *ChainIterator) ?Block {
        const txn = self.db.startTxn(.ro, BLOCK_DB);
        defer txn.doneReading();

        if (txn.get(Block, self.current_hash[0..])) |current_block| {
            self.current_hash = current_block.previous_hash;

            return current_block;
            // return @ptrToInt(current_block);
        } else |_| {
            return null;
        }
    }

    pub fn print(chain_iter: *ChainIterator) void {
        //TODO:work on converting hashes to Big endian which is usually the expected form for display
        //improve the hex formating
        info("starting blockchain iteration\n", .{});
        while (chain_iter.next()) |current_block| {
            // const current_block = @intToPtr(*Block, block);
            info("previous hash is '{X}'", .{fmt.fmtSliceHexUpper(current_block.previous_hash[0..])});
            info("data is '{s}'", .{current_block.data});
            info("current hash of {s} is '{X}'", .{ current_block.data, fmt.fmtSliceHexUpper(current_block.hash[0..]) });
            info("nonce is {}", .{current_block.nonce});
            info("POW: {}\n\n", .{current_block.validate()});
            //remove when type of data is changed
            if (std.mem.eql(u8, current_block.data[0..], GENESIS_DATA)) break;
        }
        info("done", .{});
    }
};
