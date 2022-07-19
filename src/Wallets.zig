const std = @import("std");
const crypto = std.crypto;
const Ed25519 = crypto.sign.Ed25519;
const Blake3 = crypto.hash.Blake3;
const Blake2b160 = crypto.hash.blake2.Blake2b160;
const base64 = std.base64;

const serializer = @import("s2s");

pub const ADDR_CKSUM_LEN = 4; //meaning 4 u8 values making up 32bit
pub const PUB_KEY_HASH_LEN = Blake2b160.digest_length;
//version of the address generation algorithm
pub const VERSION_LEN = 1;
const VERSION = '\x01';
pub const PUB_KEY_LEN = Ed25519.public_length;
const WALLET_DATA = "wallet.dat";
pub const ADDRESS_SIZE = encodedAddressLenght();

const PrivateKey = [Ed25519.secret_length]u8;
pub const PublicKey = [Ed25519.public_length]u8;
pub const Address = [ADDRESS_SIZE]u8;
pub const PublicKeyHash = [PUB_KEY_HASH_LEN]u8;
pub const Checksum = [ADDR_CKSUM_LEN]u8;
const VersionedHash = [VERSION_LEN + PUB_KEY_HASH_LEN]u8;
const RawAddress = [VERSION_LEN + PUB_KEY_HASH_LEN + ADDR_CKSUM_LEN]u8;

pub const Wallets = @This();
const WalleltMap = std.AutoArrayHashMap(Address, Wallet);
///to keep a collection of wallets, save them to a file, and load them from it when needed
wallets: WalleltMap,
arena: std.mem.Allocator,

///use to initialize `Wallets`
pub fn initWallets(arena: std.mem.Allocator) Wallets {
    return .{ .wallets = WalleltMap.init(arena), .arena = arena };
}

pub fn createWallet(self: *Wallets) Address {
    const wallet = Wallet.initWallet();
    const wallet_address = wallet.address();
    self.wallets.putNoClobber(wallet_address, wallet) catch unreachable;
    return wallet_address;
}

pub fn createAndSaveWallet(self: Wallets) Address {
    var wallets = getWallets(self.arena);
    const wallet_address = wallets.createWallet();
    wallets.saveWallets();
    return wallet_address;
}

///return previous wallets from `wallet.dat` else return a new empty wallet
//TODO: optimize so that not all wallets are loaded into memory this is a potentially expensive operation
pub fn getWallets(arena: std.mem.Allocator) Wallets {
    var wallets = initWallets(arena);
    wallets.loadWallets();
    return wallets;
}
///get the wallet associated with this address
pub fn getWallet(self: Wallets, address: Address) Wallet {
    return self.wallets.get(address).?;
}

///load saved wallet data
fn loadWallets(self: *Wallets) void {
    const file = std.fs.cwd().openFile(WALLET_DATA, .{}) catch |err| switch (err) {
        //TODO: maybe do nothing since this is called during the creation of wallets in cli
        error.FileNotFound => return,
        else => {
            std.log.err("{s}", .{@errorName(err)});
            std.process.exit(3);
        },
    };
    defer file.close();

    const reader = std.io.bufferedReader(file.reader()).reader();
    while (true) {
        const wallet_key = serializer.deserialize(reader, Address) catch |err| switch (err) {
            error.EndOfStream => return,
            else => unreachable,
        };
        const wallet_value = serializer.deserialize(reader, Wallet) catch unreachable;

        self.wallets.putNoClobber(wallet_key, wallet_value) catch unreachable;
    }
}
//save wallets to `WALLET_DATA`
//TODO: oraganize exit codes
//TODO: a way to efficiently save wallets .ie something like write only part which aren't already in the file
fn saveWallets(self: Wallets) void {
    const file = std.fs.cwd().openFile(WALLET_DATA, .{ .mode = .write_only }) catch |err| switch (err) {
        error.FileNotFound => std.fs.cwd().createFile(WALLET_DATA, .{}) catch |create_err| {
            std.log.err("{s}", .{@errorName(create_err)});
            std.process.exit(3);
        },
        else => {
            std.log.err("{s}", .{@errorName(err)});
            std.process.exit(3);
        },
    };
    defer file.close();

    var bwriter = std.io.bufferedWriter(file.writer());
    defer bwriter.flush() catch unreachable;
    const writer = bwriter.writer();

    var itr = self.wallets.iterator();

    while (itr.next()) |key_value| {
        serializer.serialize(writer, Address, key_value.key_ptr.*) catch unreachable;
        serializer.serialize(writer, Wallet, key_value.value_ptr.*) catch unreachable;
    }
}

///A wallet is nothing but a key/value pair.
pub const Wallet = struct {
    //https://security.stackexchange.com/questions/50878/ecdsa-vs-ecdh-vs-ed25519-vs-curve25519
    //deviete from bitcoin which uses ecdsa
    private_key: PrivateKey,
    public_key: PublicKey,

    ///use to initialize `Wallet` ie. the public and private keys
    pub fn initWallet() Wallet {
        const kp = Ed25519.KeyPair.create(null) catch unreachable;
        return .{ .private_key = kp.secret_key, .public_key = kp.public_key };
    }

    //TODO: return a array of known size
    pub fn address(self: Wallet) Address {
        const pub_key_hash = hashPubKey(self.public_key);

        const versioned_payload = version(pub_key_hash);

        const checksum_payload = checksum(versioned_payload);

        return encodeBase64(versioned_payload, checksum_payload);
    }

    //use base64 instead of bitcoins base58 for encoding address payload
    fn encodeBase64(versioned_payload: VersionedHash, checksum_payload: Checksum) Address {
        var buf: RawAddress = undefined;
        const fba = std.heap.FixedBufferAllocator.init(&buf).allocator();

        const address_to_encode = std.mem.concat(fba, u8, &.{ &versioned_payload, &checksum_payload }) catch unreachable;

        const encoder = comptime base64.Base64Encoder.init(base64.url_safe_alphabet_chars, null);
        var dest_buf: Address = undefined;
        _ = encoder.encode(&dest_buf, address_to_encode[0..]);

        return dest_buf;
    }

    pub fn decodeBase64(wallet_address: Address) RawAddress {
        var buf: [100]u8 = undefined;
        const decoder = base64.Base64Decoder.init(base64.url_safe_alphabet_chars, null);
        var decoded_buf = buf[0 .. decoder.calcSizeForSlice(wallet_address[0..]) catch unreachable];
        decoder.decode(decoded_buf, wallet_address[0..]) catch unreachable;
        return std.mem.bytesAsSlice(RawAddress, decoded_buf)[0];
    }

    pub fn getPubKeyHash(wallet_address: Address) PublicKeyHash {
        const decoded_address = decodeBase64(wallet_address);

        return (decoded_address[1 .. PUB_KEY_HASH_LEN + 1]).*;
    }

    fn version(pub_key_hash: PublicKeyHash) VersionedHash {
        var versioned_payload_buf: VersionedHash = undefined;
        const fba = std.heap.FixedBufferAllocator.init(&versioned_payload_buf).allocator();

        _ = std.mem.concat(fba, u8, &.{ &.{VERSION}, pub_key_hash[0..] }) catch unreachable;
        return versioned_payload_buf;
    }

    pub fn hashPubKey(pub_key: PublicKey) PublicKeyHash {
        //https://linuxadictos.com/en/blake3-a-fast-and-parallelizable-secure-cryptographic-hash-function.html
        //replaces sha256 with Blake3 which is also 256 and faster in software
        var pk_hash: [Blake3.digest_length]u8 = undefined;
        Blake3.hash(pub_key[0..], &pk_hash, .{});

        //use Blake2b160 as a replacement for bitcoins ripemd-160 https://en.bitcoin.it/wiki/RIPEMD-160
        //smaller bit lenght for easy readability for user
        var final_hash: PublicKeyHash = undefined;
        Blake2b160.hash(pk_hash[0..], &final_hash, .{});

        return final_hash;
    }

    //checksum is the first four bytes of the resulted hash
    fn checksum(versioned_payload: VersionedHash) Checksum {
        var first_hash: [Blake3.digest_length]u8 = undefined;
        Blake3.hash(versioned_payload[0..], &first_hash, .{});

        var final_hash: [Blake3.digest_length]u8 = undefined;
        Blake3.hash(first_hash[0..], &final_hash, .{});

        return (final_hash[0..ADDR_CKSUM_LEN]).*;
    }
};

fn encodedAddressLenght() usize {
    const encoder = base64.Base64Encoder.init(base64.url_safe_alphabet_chars, null);
    return encoder.calcSize(VERSION_LEN + PUB_KEY_HASH_LEN + ADDR_CKSUM_LEN);
}

//TODO: verify if the an encoded address of lenght decodes to a differenct lenght
//TODO: find out how to access arguments in return channels
fn decodedAddressLenght(wallet_address: Address) usize {
    const decoder = base64.Base64Decoder.init(base64.url_safe_alphabet_chars, null);
    return decoder.calcSizeForSlice(wallet_address[0..]) catch unreachable;
}
