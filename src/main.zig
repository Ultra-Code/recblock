const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const Algods = @import("algods");
const List = Algods.linked_list.SinglyCircularList;

pub fn reportOOM() noreturn {
    std.debug.panic("allocator is Out Of Memory", .{});
}

pub const Block = struct {
    //allocator
    allocator: std.mem.Allocator,
    //when the block is created
    timestamp: i64,
    //the actual valuable information contained in the block .eg Transactions which is usually a differenct data
    //structure
    data: []const u8,
    //stores the hash of the previous block
    previous_hash: []const u8,
    //hash of the current block
    hash: []const u8,

    pub fn genesisBlock(allocator: Allocator) Block {
        var genesis_block = Block{
            .allocator = allocator,
            .timestamp = std.time.timestamp(),
            .data = "Genesis Block",
            .previous_hash = "",
            .hash = undefined,
        };
        setHash(&genesis_block);
        return genesis_block;
    }

    fn calculateHash(block: Block) []u8 {
        var buf: [64]u8 = undefined;
        const end_pos = std.fmt.formatIntBuf(&buf, block.timestamp, 10, .lower, .{});
        const timestamp = buf[0..end_pos];

        //timestamp ,previous_hash and hash form the BlockHeader
        const block_header = std.mem.join(block.allocator, "", &[_][]const u8{ timestamp, block.data, block.previous_hash }) catch reportOOM();
        defer block.allocator.free(block_header);

        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(block_header, &hash, .{});

        return block.allocator.dupe(u8, &hash) catch reportOOM();
    }

    fn setHash(block: *Block) void {
        block.hash = calculateHash(block.*);
    }

    pub fn newBlock(block: Block, data: []const u8, previous_hash: []const u8) Block {
        var new_block = Block{
            .allocator = block.allocator,
            .timestamp = std.time.timestamp(),
            .data = data,
            .previous_hash = previous_hash,
            .hash = undefined,
        };
        setHash(&new_block);
        return new_block;
    }
    pub fn deinit(block: Block) void {
        block.allocator.free(block.hash);
    }
};

test "Block Test" {
    var block = Block{
        .allocator = testing.allocator,
        .timestamp = std.time.timestamp(),
        .data = "test",
        .previous_hash = "0",
        .hash = undefined,
    };
    Block.setHash(&block);
    defer block.deinit();

    var genesis_block = Block.genesisBlock(testing.allocator);
    defer genesis_block.deinit();
    const new_block = genesis_block.newBlock("test", "0");
    defer new_block.deinit();
    try testing.expectEqualSlices(u8, block.hash, new_block.hash);
}

pub const BlockChain = struct {
    blocks: List(Block),

    pub fn newChain(allocator: Allocator, genesis_block: Block) BlockChain {
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
    bc.addBlock("transfer $1 to kofi");
    defer bc.deinit();
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
        std.log.info("previous hash is '{s}'", .{block.previous_hash});
        std.log.info("data is '{s}'", .{block.data});
        std.log.info("current hash is '{s}'\n", .{block.hash});
    }
}
