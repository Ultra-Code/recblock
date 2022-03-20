const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const print = std.debug.print;
const crypto = std.crypto;
const sha256 = crypto.hash.sha2.Sha256;
const fmt = std.fmt;

const Algods = @import("algods");
const List = Algods.linked_list.SinglyCircularList;

pub fn reportOOM() noreturn {
    std.debug.panic("allocator is Out Of Memory", .{});
}

//TARGET_ZERO_BITS must be a multiple of 4 and it determines the number of zeros in the target hash which determines difficult
//The higer TARGET_ZERO_BITS the harder or time consuming it is to find a hash
//NOTE: when we define a target adjusting algorithm this won't be a global constant anymore
//it specifies the target hash which is used to check hashes which are valid
//a block is only accepted by the network if its hash meets the network's difficulty target
//the number of leading zeros in the target serves as a good approximation of the current difficult
const TARGET_ZERO_BITS = 8;

pub const Block = struct {
    //allocator
    allocator: mem.Allocator,
    //when the block is created
    timestamp: i64,
    //the actual valuable information contained in the block .eg Transactions which is usually a differenct data
    //structure
    data: []const u8,
    //stores the hash of the previous block
    previous_hash: []const u8,
    //hash of the current block
    hash: []const u8 = undefined,
    //difficulty bits is the block header storing the difficulty at which the block was mined
    difficulty_bits: u16 = TARGET_ZERO_BITS, //u7 limit value from 0 to 128
    //Thus miners must discover by brute force the "nonce" that, when included in the block, results in an acceptable hash.
    nonce: usize = 0,

    pub fn genesisBlock(allocator: mem.Allocator) Block {
        var genesis_block = Block{
            .allocator = allocator,
            .timestamp = std.time.timestamp(),
            .data = "Genesis Block",
            .previous_hash = "",
        };
        var result = genesis_block.POW();
        genesis_block.hash = result.hash;
        genesis_block.nonce = result.nonce;
        return genesis_block;
    }

    ///Validate POW
    //refactor and deduplicate
    pub fn validate(block: Block) bool {
        // const target_bits = 256 - block.difficulty_bits;
        //hast to be compaired with for valid hashes to prove work done
        const target_hash = 1 << 256 - TARGET_ZERO_BITS;

        var time_buf: [16]u8 = undefined;
        var bits_buf: [3]u8 = undefined;
        var nonce_buf: [16]u8 = undefined;

        const timestamp = std.fmt.bufPrintIntToSlice(&time_buf, block.timestamp, 16, .lower, .{});
        const difficulty_bits = std.fmt.bufPrintIntToSlice(&bits_buf, block.difficulty_bits, 16, .lower, .{});
        const nonce = std.fmt.bufPrintIntToSlice(&nonce_buf, block.nonce, 16, .lower, .{});

        //timestamp ,previous_hash and hash form the BlockHeader
        const block_headers = mem.concat(block.allocator, u8, &[_][]const u8{
            block.previous_hash,
            block.data,
            timestamp,
            difficulty_bits,
            nonce,
        }) catch reportOOM();
        defer block.allocator.free(block_headers);

        var hash: [32]u8 = undefined;
        sha256.hash(block_headers, &hash, .{});

        const hash_int = @bitCast(u256, hash);

        const is_block_valid = if (hash_int < target_hash) true else false;
        return is_block_valid;
    }

    ///Proof of Work consensus algorithm
    pub fn POW(block: Block) struct { nonce: usize, hash: []const u8 } {
        // const target_bits = 256 - block.difficulty_bits;
        //hast to be compaired with for valid hashes to prove work done
        const target_hash = 1 << 256 - TARGET_ZERO_BITS;

        var nonce: usize = 0;

        var time_buf: [16]u8 = undefined;
        var bits_buf: [3]u8 = undefined;
        var nonce_buf: [16]u8 = undefined;

        const timestamp = std.fmt.bufPrintIntToSlice(&time_buf, block.timestamp, 16, .lower, .{});
        const difficulty_bits = std.fmt.bufPrintIntToSlice(&bits_buf, block.difficulty_bits, 16, .lower, .{});

        print("\nMining the block containing {s}\n", .{block.data});

        while (nonce < std.math.maxInt(usize)) {
            const nonce_val = std.fmt.bufPrintIntToSlice(&nonce_buf, nonce, 16, .lower, .{});

            //timestamp ,previous_hash and hash form the BlockHeader
            const block_headers = mem.concat(block.allocator, u8, &[_][]const u8{
                block.previous_hash,
                block.data,
                timestamp,
                difficulty_bits,
                nonce_val,
            }) catch reportOOM();
            defer block.allocator.free(block_headers);

            var hash: [32]u8 = undefined;
            sha256.hash(block_headers, &hash, .{});

            const hash_int = mem.bytesToValue(u256, &hash);

            if (hash_int < target_hash) {
                print("{}\n", .{fmt.fmtSliceHexUpper(&hash)});
                return .{ .nonce = nonce, .hash = block.allocator.dupe(u8, &hash) catch reportOOM() };
            } else {
                nonce += 1;
            }
        }
        unreachable;
    }

    pub fn newBlock(block: Block, data: []const u8, previous_hash: []const u8) Block {
        var new_block = Block{
            .allocator = block.allocator,
            .timestamp = std.time.timestamp(),
            .data = data,
            .previous_hash = previous_hash,
        };
        var result = new_block.POW();
        new_block.hash = result.hash;
        new_block.nonce = result.nonce;
        return new_block;
    }
    pub fn deinit(block: Block) void {
        block.allocator.free(block.hash);
    }
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

    pub fn newChain(allocator: mem.Allocator, genesis_block: Block) BlockChain {
        var blocks = List(Block).init(allocator);
        blocks.append(genesis_block) catch reportOOM();
        return .{ .blocks = blocks };
    }
    pub fn addBlock(bc: *BlockChain, block_data: []const u8) void {
        const previous_block = bc.blocks.last();
        const new_block = previous_block.newBlock(block_data, previous_block.hash);
        bc.blocks.append(new_block) catch reportOOM();
    }

    pub fn deinit(bc: BlockChain) void {
        var iter = bc.blocks.iterator();
        while (iter.next()) |block| {
            block.deinit();
        }
        bc.blocks.deinit();
    }
};

test "Blockchain Test" {
    var allocator = testing.allocator;
    var genesis_block = Block.genesisBlock(allocator);
    var bc = BlockChain.newChain(allocator, genesis_block);
    defer bc.deinit();

    bc.addBlock("transfer $1 to kofi");
    bc.addBlock("transfer $7 to Kojo");

    var iter = bc.blocks.iterator();
    while (iter.next()) |block| {
        print("\nprevious hash is '{}'\n", .{std.fmt.fmtSliceHexUpper(block.previous_hash)});
        print("data is '{s}'\n", .{block.data});
        print("current hash of {s} is '{}'\n", .{ block.data, std.fmt.fmtSliceHexUpper(block.hash) });
        print("nonce is {}\n", .{block.nonce});
        print("POW: {}\n", .{block.validate()});
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = gpa.allocator();

    var genesis_block = Block.genesisBlock(allocator);
    var bc = BlockChain.newChain(allocator, genesis_block);
    defer bc.deinit();

    bc.addBlock("transfer $1 to kofi");
    bc.addBlock("transfer $7 to Kojo");

    var iter = bc.blocks.iterator();
    while (iter.next()) |block| {
        print("previous hash is '{s}'", .{block.previous_hash});
        print("data is '{s}'", .{block.data});
        print("current hash is '{s}'\n", .{block.hash});
    }
}
