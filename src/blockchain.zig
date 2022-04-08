const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const print = std.debug.print;
const panic = std.debug.panic;
const debug = std.log.debug;
const crypto = std.crypto;
const sha256 = crypto.hash.sha2.Sha256;
const fmt = std.fmt;

pub const Lmdb = @import("lmdb.zig").Lmdb;
pub const BLOCK_DB = "blocks";

const Algods = @import("algods");
const List = Algods.linked_list.SinglyCircularList;

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
            .data = "Genesis Block is the First Block".*,
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
    pub fn deinit(_: Block) void {}
};

test "Block Test" {
    var genesis_block = Block.genesisBlock(testing.allocator);
    defer genesis_block.deinit();
    const new_block = genesis_block.newBlock("test", genesis_block.hash);
    defer new_block.deinit();
    try testing.expectEqualSlices(u8, genesis_block.hash, new_block.previous_hash);
}

//READ: https://en.bitcoin.it/wiki/Block_hashing_algorithm https://en.bitcoin.it/wiki/Proof_of_work https://en.bitcoin.it/wiki/Hashcash
pub const BlockChain = struct {
    blocks: List(Block),
    db: Lmdb,

    pub fn newChain(arena: mem.Allocator, db: Lmdb, genesis_block: Block) BlockChain {
        const txn = db.startTxn(.rw, BLOCK_DB);
        defer txn.commitTxns();
        if (txn.getAs(Block, "last")) |last_block| {
            var continue_chain_from_last_block = List(Block).init(arena);
            continue_chain_from_last_block.append(last_block) catch reportOOM();
            return .{ .blocks = continue_chain_from_last_block, .db = db };
        } else |err| switch (err) {
            error.KeyNotInDb => {
                var blocks = List(Block).init(arena);
                blocks.append(genesis_block) catch reportOOM();
                txn.put("last", genesis_block) catch unreachable;
                return .{ .blocks = blocks, .db = db };
            },
            error.InvalidParam => unreachable,
        }
    }

    pub fn addBlock(bc: *BlockChain, block_data: [32]u8) void {
        const previous_block = bc.blocks.last();
        print("\nMining the block containing - '{s}'\n", .{block_data[0..]});
        const new_block = Block.newBlock(block_data, previous_block.hash);
        print("previous hash is '{}'\n", .{fmt.fmtSliceHexUpper(previous_block.hash[0..])});
        print("'{s}' - has a valid hash of '{}'\n", .{ block_data[0..], fmt.fmtSliceHexUpper(new_block.hash[0..]) });
        print("nonce is {}\n", .{new_block.nonce});
        print("POW: {}\n\n", .{new_block.validate()});
        bc.blocks.append(new_block) catch reportOOM();
    }

    //TODO:Make iterator continue from where it left of previously
    //maybe add size to List to track end
    pub fn saveBlocks(bc: BlockChain) void {
        // const chain = @bitCast([@sizeOf(@TypeOf(bc))]u8, bc);
        // bc.db.put(bc.db.db_handle, block.hash, block) catch unreachable;
        var txn = bc.db.startTxn(.rw, BLOCK_DB);
        defer txn.commitTxns();

        var iter = bc.blocks.iterator();
        while (iter.next()) |block| {
            //TODO: improve and prevent key collision so that put could be catch unreachable
            txn.put(block.hash[0..], block) catch |err| switch (err) {
                error.KeyExist => {},
                else => unreachable,
            };
        }
        txn.update("last", bc.blocks.last()) catch unreachable;
    }

    pub fn deinit(bc: BlockChain) void {
        bc.saveBlocks();
        bc.blocks.deinit();
    }
};

test "Blockchain Test" {
    var allocator = testing.allocator;
    var genesis_block = Block.genesisBlock(allocator);
    var bc = BlockChain.newChain(allocator, genesis_block);
    defer bc.deinit();

    bc.addBlock("transfer 1BTC to Esteban");
    bc.addBlock("transfer 9BTC to Assan");

    var iter = bc.blocks.iterator();
    //TODO:work on converting hashes to Big endian which is usually the expected form for display
    while (iter.next()) |block| {
        print("\nprevious hash is '{}'\n", .{fmt.fmtSliceHexUpper(block.previous_hash)});
        print("data is '{s}'\n", .{block.data});
        print("current hash of {s} is '{}'\n", .{ block.data, fmt.fmtSliceHexUpper(block.hash) });
        print("nonce is {}\n", .{block.nonce});
        print("POW: {}\n", .{block.validate()});
    }
    return error.SkipZigTest;
}
