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

pub fn reportOOM() noreturn {
    panic("allocator is Out Of Memory", .{});
}

//TARGET_ZERO_BITS must be a multiple of 4 and it determines the number of zeros in the target hash which determines difficult
//The higer TARGET_ZERO_BITS the harder or time consuming it is to find a hash
//NOTE: when we define a target adjusting algorithm this won't be a global constant anymore
//it specifies the target hash which is used to check hashes which are valid
//a block is only accepted by the network if its hash meets the network's difficulty target
//the number of leading zeros in the target serves as a good approximation of the current difficult
const TARGET_ZERO_BITS = 8;

const GENESIS_DATA = "Genesis Block is the First Block";

//CHANGE_AFTER_BETTER_SERIALIZATION: storing []const u8 as [N]u8 for easy serialization till pointer swizilling and unswizilling is learnt
pub const Block = struct {
    //when the block is created
    timestamp: i64,
    //difficulty bits is the block header storing the difficulty at which the block was mined
    difficulty_bits: u7 = TARGET_ZERO_BITS, //u7 limit value from 0 to 127
    //Thus miners must discover by brute force the "nonce" that, when included in the block, results in an acceptable hash.
    nonce: usize = 0,
    //the actual valuable information contained in the block .eg Transactions which is usually a differenct data
    //structure
    data: [32]u8,
    //stores the hash of the previous block
    previous_hash: [32]u8,
    //hash of the current block
    hash: [32]u8 = undefined,

    pub fn genesisBlock() Block {
        var genesis_block = Block{
            .timestamp = std.time.timestamp(),
            .data = GENESIS_DATA.*,
            .previous_hash = undefined,
        };
        var hash: [32]u8 = undefined;
        const nonce = genesis_block.POW(&hash);
        genesis_block.hash = hash;
        genesis_block.nonce = nonce;
        return genesis_block;
    }

    ///Validate POW
    //refactor and deduplicate
    pub fn validate(block: Block) bool {
        const target_hash = getTargetHash(block.difficulty_bits);

        var time_buf: [16]u8 = undefined;
        var bits_buf: [3]u8 = undefined;
        var nonce_buf: [16]u8 = undefined;

        const timestamp = fmt.bufPrintIntToSlice(&time_buf, block.timestamp, 16, .lower, .{});
        const difficulty_bits = fmt.bufPrintIntToSlice(&bits_buf, block.difficulty_bits, 16, .lower, .{});
        const nonce = fmt.bufPrintIntToSlice(&nonce_buf, block.nonce, 16, .lower, .{});

        //timestamp ,previous_hash and hash form the BlockHeader
        var block_headers_buf: [128]u8 = undefined;
        const block_headers = fmt.bufPrint(&block_headers_buf, "{[previous_hash]s}{[data]s}{[timestamp]s}{[difficulty_bits]s}{[nonce]s}", .{
            .previous_hash = block.previous_hash[0..],
            .data = block.data[0..],
            .timestamp = timestamp,
            .difficulty_bits = difficulty_bits,
            .nonce = nonce,
        }) catch unreachable;

        var hash: [32]u8 = undefined;
        sha256.hash(block_headers, &hash, .{});

        const hash_int = @bitCast(u256, hash);

        const is_block_valid = if (hash_int < target_hash) true else false;
        return is_block_valid;
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
    pub fn POW(block: Block, hash: *[32]u8) usize {
        const target_hash = getTargetHash(block.difficulty_bits);

        var nonce: usize = 0;

        //TODO : optimize the sizes of these buffers base on the base and use exactly the amount that is needed
        var time_buf: [16]u8 = undefined;
        var bits_buf: [3]u8 = undefined;
        var nonce_buf: [16]u8 = undefined;

        const timestamp = fmt.bufPrintIntToSlice(&time_buf, block.timestamp, 16, .lower, .{});
        const difficulty_bits = fmt.bufPrintIntToSlice(&bits_buf, block.difficulty_bits, 16, .lower, .{});

        // const size = comptime (block.previous_hash.len + block.data.len + time_buf.len + bits_buf.len + nonce_buf.len);
        var block_headers_buf: [128]u8 = undefined;
        while (nonce < std.math.maxInt(usize)) {
            const nonce_val = fmt.bufPrintIntToSlice(&nonce_buf, nonce, 16, .lower, .{});

            //timestamp ,previous_hash and hash form the BlockHeader
            const block_headers = fmt.bufPrint(&block_headers_buf, "{[previous_hash]s}{[data]s}{[timestamp]s}{[difficulty_bits]s}{[nonce]s}", .{
                .previous_hash = block.previous_hash,
                .data = block.data,
                .timestamp = timestamp,
                .difficulty_bits = difficulty_bits,
                .nonce = nonce_val,
            }) catch unreachable;

            sha256.hash(block_headers, hash, .{});

            const hash_int = mem.bytesToValue(u256, hash[0..]);

            if (hash_int < target_hash) {
                return nonce;
            } else {
                nonce += 1;
            }
        }
        unreachable;
    }

    pub fn newBlock(data: [32]u8, previous_hash: [32]u8) Block {
        var new_block = Block{
            .timestamp = std.time.timestamp(),
            .data = data,
            .previous_hash = previous_hash,
        };
        var hash: [32]u8 = undefined;
        const nonce = new_block.POW(&hash);
        new_block.hash = hash;
        new_block.nonce = nonce;
        return new_block;
    }
};

test "Block Test" {
    var genesis_block = Block.genesisBlock();
    const new_block = Block.newBlock("testing Block".* ++ [_]u8{'0'} ** 19, genesis_block.hash);
    try testing.expectEqualSlices(u8, genesis_block.hash[0..], new_block.previous_hash[0..]);
    var hash: [32]u8 = undefined;
    const nonce = new_block.POW(&hash);
    try testing.expectEqual(nonce, new_block.nonce);
    try testing.expectEqualStrings(hash[0..], new_block.hash[0..]);
}

//READ: https://en.bitcoin.it/wiki/Block_hashing_algorithm https://en.bitcoin.it/wiki/Proof_of_work https://en.bitcoin.it/wiki/Hashcash

const LAST = "last";
pub const BlockChain = struct {
    last_hash: [32]u8,
    db: Lmdb,

    ///create a new BlockChain
    pub fn newChain(db: Lmdb, genesis_block: Block) BlockChain {
        const txn = db.startTxn(.rw, BLOCK_DB);
        defer txn.commitTxns();
        if (txn.getAs([32]u8, LAST)) |last_block_hash| {
            return .{ .last_hash = last_block_hash, .db = db };
        } else |err| switch (err) {
            error.KeyNotFound => {
                txn.put(genesis_block.hash[0..], genesis_block) catch unreachable;
                txn.put(LAST, genesis_block.hash) catch unreachable;
                return .{ .last_hash = genesis_block.hash, .db = db };
            },
            else => unreachable,
        }
    }

    ///add a new Block to the BlockChain
    pub fn addBlock(bc: *BlockChain, block_data: [32]u8) void {
        info("Mining the block containing - '{s}'", .{block_data[0..]});
        const new_block = Block.newBlock(block_data, bc.last_hash);
        info("'{s}' - has a valid hash of '{}'", .{ block_data[0..], fmt.fmtSliceHexUpper(new_block.hash[0..]) });
        info("nonce is {}", .{new_block.nonce});
        info("POW: {}\n\n", .{new_block.validate()});
        assert(new_block.validate() == true);

        const txn = bc.db.startTxn(.rw, BLOCK_DB);
        defer txn.commitTxns();

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

        if (txn.getAs(Block, self.current_hash[0..])) |current_block| {
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
