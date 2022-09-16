pub const BLOCK_DB = "blocks";

pub const LAST = "last";

pub fn fmtHash(hash: [32]u8) [32]u8 {
    const hash_int = @bitCast(u256, hash);
    const big_end_hash_int = @byteSwap(hash_int);
    return @bitCast([32]u8, big_end_hash_int);
}
