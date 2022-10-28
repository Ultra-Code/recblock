pub fn fmtHash(hash: [32]u8) [32]u8 {
    const hash_int = @bitCast(u256, hash);
    const big_end_hash_int = @byteSwap(hash_int);
    return @bitCast([32]u8, big_end_hash_int);
}

pub const ExitCodes = enum {
    blockchain_not_found,
    blockchain_already_exist,
    invalid_wallet_address,
    insufficient_wallet_balance,
    invalid_cli_argument,
};
