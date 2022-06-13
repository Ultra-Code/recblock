const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;
const sha256 = std.crypto.hash.sha2.Sha256;
const testing = std.testing;

const Block = @This();
const Transaction = @import("Transaction.zig");

//TARGET_ZERO_BITS must be a multiple of 4 and it determines the number of zeros in the target hash which determines difficult
//The higer TARGET_ZERO_BITS the harder or time consuming it is to find a hash
//NOTE: when we define a target adjusting algorithm this won't be a global constant anymore
//it specifies the target hash which is used to check hashes which are valid
//a block is only accepted by the network if its hash meets the network's difficulty target
//the number of leading zeros in the target serves as a good approximation of the current difficult
const TARGET_ZERO_BITS = 8;

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

///mine a new block
pub fn newBlock(arena: std.mem.Allocator, previous_hash: [32]u8, transactions: []const Transaction) Block {
    var new_block = Block{
        .timestamp = std.time.timestamp(),
        .transactions = std.ArrayListUnmanaged(Transaction){},
        .previous_hash = previous_hash,
    };
    new_block.transactions.appendSlice(arena, transactions) catch unreachable;
    const pow_result = new_block.POW();
    new_block.hash = pow_result.hash;
    new_block.nonce = pow_result.nonce;
    return new_block;
}

pub fn genesisBlock(arena: std.mem.Allocator, coinbase: Transaction) Block {
    return newBlock(arena, .{'\x00'} ** 32, &.{coinbase});
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

test "newBlock" {
    const ta = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const allocator = arena.allocator();

    var coinbase = Transaction.initCoinBaseTx(allocator, "genesis");

    var genesis_block = Block.genesisBlock(allocator, coinbase);

    var new_block = newBlock(allocator, genesis_block.hash, &.{coinbase});

    try testing.expectEqualSlices(u8, genesis_block.hash[0..], new_block.previous_hash[0..]);
    const result = new_block.POW();
    try testing.expectEqual(result.nonce, new_block.nonce);
    try testing.expectEqualStrings(result.hash[0..], new_block.hash[0..]);
}
