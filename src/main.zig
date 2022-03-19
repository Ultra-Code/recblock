const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

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

    fn init(allocator: std.mem.Allocator, data: []const u8, previous_hash: []const u8) Block {
        return .{
            .allocator = allocator,
            .timestamp = std.time.timestamp(),
            .data = data,
            .previous_hash = previous_hash,
            .hash = undefined,
        };
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

    fn reportOOM() noreturn {
        std.debug.panic("allocator is Out Of Memory", .{});
    }

    fn setHash(block: *Block) void {
        block.hash = calculateHash(block.*);
    }

    pub fn newBlock(allocator: Allocator, data: []const u8, previous_hash: []const u8) Block {
        var new_block = init(allocator, data, previous_hash);
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

    const new_block = Block.newBlock(block.allocator, "test", "0");
    defer new_block.deinit();
    try testing.expectEqualSlices(u8, block.hash, new_block.hash);
}
pub fn main() !void {}
