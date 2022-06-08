const mdb = struct {
    usingnamespace @cImport({
        @cInclude("lmdb.h");
    });
};

const std = @import("std");
const panic = std.debug.panic;
const assert = std.debug.assert;
const info = std.log.info;
const testing = std.testing;
const err = std.os.E;

const s2s = @import("s2s");
const serialize = s2s.serialize;
const deserialize = s2s.deserialize;
const BLOCK_DB = @import("blockchain.zig").BLOCK_DB;
pub const HASH_SIZE = 8; //size of std.hash.Fnv1a_64 is 64bit which is 8 byte

const Env = mdb.MDB_env;
const Key = mdb.MDB_val;
const Val = mdb.MDB_val;
const Txn = mdb.MDB_txn;
const DbHandle = mdb.MDB_dbi;

//TODO:folow convention of using upper case for structs in file
pub const Lmdb = @This();
const TxnType = enum { rw, ro };
db_env: *Env,
txn: ?*Txn = null,
txn_type: TxnType,
db_handle: DbHandle = undefined,

///`db_path` is the directory in which the database files reside. This directory must already exist and be writable.
///initialize db environment (mmap file) specifing the db mode `.rw/.ro`
///make sure to start a transaction .ie startTxn() fn before calling any db manipulation fn's
///a maximum of two named db's are allowed
pub fn initdb(db_path: []const u8, txn_type: TxnType) Lmdb {
    var db_env: ?*Env = undefined;
    const env_state = mdb.mdb_env_create(&db_env);
    checkState(env_state) catch unreachable;
    const max_num_of_dbs = 2;

    const db_limit_state = mdb.mdb_env_set_maxdbs(db_env, max_num_of_dbs);
    checkState(db_limit_state) catch unreachable;

    //if .ro open the environment in read-only mode. No write operations will be allowed.
    const db_flags: c_uint = if (txn_type == .ro) mdb.MDB_RDONLY else 0;
    const permissions: c_uint = 0o0600; //octal permissions for created files in db_dir
    const open_state = mdb.mdb_env_open(db_env, db_path.ptr, db_flags, permissions);
    checkState(open_state) catch unreachable;

    return .{
        .db_env = db_env.?,
        .txn_type = txn_type,
    };
}

///close all opened db environment
pub fn deinitdb(lmdb: Lmdb) void {
    mdb.mdb_env_close(lmdb.db_env);
}

///start a transaction in rw/ro mode and get a db handle for db manipulation
///commit changes with commitTxns() if .rw / doneReading() if .ro
pub fn startTxn(lmdb: Lmdb, txn_type: TxnType, db_name: []const u8) Lmdb {
    const txn = beginTxn(lmdb, txn_type);
    const handle = openDb(.{ .db_env = lmdb.db_env, .txn = txn, .txn_type = txn_type }, db_name);
    return .{
        .db_env = lmdb.db_env,
        .txn = txn,
        .txn_type = txn_type,
        .db_handle = handle,
    };
}

///open a different db in an already open transaction
pub fn openNewDb(lmdb: Lmdb, db_name: []const u8) Lmdb {
    //make sure a transaction has been created already
    ensureValidState(lmdb);
    const handle = openDb(lmdb, db_name);
    return .{
        .db_handle = lmdb.db_env,
        .txn = lmdb.txn.?,
        .txn_type = lmdb.txn_type,
        .db_handle = handle,
    };
}

fn beginTxn(lmdb: Lmdb, txn_type: TxnType) *Txn {
    // This transaction will not perform any write operations if ro.
    const flags: c_uint = if (txn_type == .ro) mdb.MDB_RDONLY else 0;
    if (flags != mdb.MDB_RDONLY and lmdb.txn_type == .ro) {
        panic("Cannot begin a read-write transaction in a read-only environment", .{});
    }
    const parent = null; //no parent
    var txn: ?*Txn = undefined; //where the new #MDB_txn handle will be stored
    const txn_state = mdb.mdb_txn_begin(lmdb.db_env, parent, flags, &txn);
    checkState(txn_state) catch unreachable;

    return txn.?;
}

//TODO:may be support other flags for db like MDB_DUPSORT && MDB_DUPFIXED
fn openDb(lmdb: Lmdb, db_name: []const u8) DbHandle {
    //Create the named database if it doesn't exist. This option is not allowed in a read-only transaction or a read-only environment.
    const db_flags: c_uint = if (lmdb.txn_type == .rw) mdb.MDB_CREATE else 0;

    var db_handle: mdb.MDB_dbi = undefined; //dbi Address where the new #MDB_dbi handle will be stored
    const db_state = mdb.mdb_dbi_open(lmdb.txn.?, db_name.ptr, db_flags, &db_handle);
    checkState(db_state) catch unreachable;
    return db_handle;
}

inline fn ensureValidState(lmdb: Lmdb) void {
    assert(lmdb.txn != null);
    assert(lmdb.db_handle != undefined);
}

///delete entry in db with key `key_val`
///if db was opened with MDB_DUPSORT use `delDups` instead
pub fn del(lmdb: Lmdb, key_val: []const u8) !void {
    ensureValidState(lmdb);
    const del_state = mdb.mdb_del(lmdb.txn.?, lmdb.db_handle, &key(key_val), null);
    try checkState(del_state);
}

///Use If the database supports sorted duplicate data items (MDB_DUPSORT) else the data parameter is ignored.
///because If the database supports sorted duplicates and the data parameter is NULL, all of the duplicate data items
///for the key will be deleted. While, if the data parameter is non-NULL only the matching data item will be deleted.
pub fn delDups(_: Lmdb, _: []const u8, _: anytype) void {
    //This function will return MDB_NOTFOUND if the specified key/data pair is not in the database.
    panic("TODO");
}
const InsertionType = enum {
    put, //overwrite isn't allowed
    update, //overwite data is allowed
};

//TODO:when MDB_DUPSORT is supported then support MDB_NODUPDATA flag
fn insert(lmdb: Lmdb, insertion_t: InsertionType, key_val: []const u8, data: anytype) !void {
    const insert_flags: c_uint = switch (insertion_t) {
        .put => mdb.MDB_NOOVERWRITE, // don't overwrite data if key already exist
        .update => 0,
    };

    const DataType = @TypeOf(data);
    var serialized_data: [HASH_SIZE + @sizeOf(DataType)]u8 = undefined;

    var fbr = std.io.fixedBufferStream(&serialized_data);
    const writer = fbr.writer();
    serialize(writer, DataType, data) catch unreachable;

    const put_state = mdb.mdb_put(
        lmdb.txn.?,
        lmdb.db_handle,
        &key(key_val),
        &value(serialized_data[0..]),
        insert_flags,
    );
    try checkState(put_state);
}

///insert new key/data pair without overwriting already inserted pair
pub fn put(lmdb: Lmdb, key_val: []const u8, data: anytype) !void {
    ensureValidState(lmdb);

    try insert(lmdb, .put, key_val, data);
}

///insert/update already existing key/data pair
pub fn update(lmdb: Lmdb, key_val: []const u8, data: anytype) !void {
    ensureValidState(lmdb);

    try insert(lmdb, .update, key_val, data);
}

///commit all transaction on the current db handle
///should usually be called before the end of fn's to save db changes
pub fn commitTxns(lmdb: Lmdb) void {
    ensureValidState(lmdb);

    const commit_state = mdb.mdb_txn_commit(lmdb.txn.?);
    checkState(commit_state) catch unreachable;
}

///put db in a consistent state after performing a read-only transaction
pub fn doneReading(lmdb: Lmdb) void {
    ensureValidState(lmdb);
    abortTxns(lmdb);
}

///update the read state of a read-only transaction
///this fn should be called after performing a read-write operation in a different transaction
///it will update the current read-only transaction to see the changes made in the read-write transaction
pub fn updateRead(lmdb: Lmdb) void {
    ensureValidState(lmdb);
    mdb.mdb_txn_reset(lmdb.txn.?);
    const rewew_state = mdb.mdb_txn_renew(lmdb.txn.?);
    checkState(rewew_state) catch unreachable;
}

///cancel/discard all transaction on the current db handle
pub fn abortTxns(lmdb: Lmdb) void {
    mdb.mdb_txn_abort(lmdb.txn.?);
}

fn getRawBytes(data: ?*anyopaque, start: usize, size: usize) []u8 {
    return @ptrCast([*]u8, data.?)[start..size];
}

///get byte slice representing data
pub fn getBytes(comptime len: usize, data: ?*anyopaque, size: usize) []u8 {
    return getBytesAs([len]u8, data, size)[0..];
}

//TODO: handle the case where the type to deserialize needs to be allocated with a fixedBufferAllocator
pub fn getBytesAs(comptime T: type, data: ?*anyopaque, size: usize) T {
    // return std.mem.bytesAsSlice(T, getBytes(data.?, size))[0];
    const serialized_data = getRawBytes(data, 0, size);

    var fbr = std.io.fixedBufferStream(serialized_data);
    fbr.seekTo(0) catch unreachable;

    const reader = fbr.reader();
    return deserialize(reader, T) catch unreachable;
}

///This is any unsafe cast which discards const
pub fn cast(comptime T: type, any_ptr: anytype) T {
    return @intToPtr(T, @ptrToInt(any_ptr));
}

///get the data as a slice of bytes
pub fn get(lmdb: Lmdb, key_val: []const u8, comptime value_len: usize) ![]u8 {
    ensureValidState(lmdb);

    var data: Val = undefined;
    const get_state = mdb.mdb_get(
        lmdb.txn.?,
        lmdb.db_handle,
        &key(key_val),
        &data,
    );

    try checkState(get_state);
    return getBytes(value_len, data.mv_data, data.mv_size);
}

///get the data as type `T`
pub fn getAs(lmdb: Lmdb, comptime T: type, key_val: []const u8) !T {
    ensureValidState(lmdb);

    var data: Val = undefined;
    const get_state = mdb.mdb_get(
        lmdb.txn.?,
        lmdb.db_handle,
        &key(key_val),
        &data,
    );
    try checkState(get_state);
    return getBytesAs(T, data.mv_data, data.mv_size);
}

fn key(data: []const u8) Key {
    return value(data);
}

fn value(data: []const u8) Val {
    return .{ .mv_size = data.len, .mv_data = cast(*anyopaque, data.ptr) };
}

///check state of operation to make sure there where no errors
fn checkState(state: c_int) !void {
    switch (state) {
        //lmdb  errors  Return Codes
        //Successful result */
        mdb.MDB_SUCCESS => {},
        //key/data pair already exists */
        mdb.MDB_KEYEXIST => {
            info("'{}' -> {s}", .{ state, mdb.mdb_strerror(state) });
            return error.KeyAlreadyExist;
        },
        //key/data pair not found (EOF) */
        mdb.MDB_NOTFOUND => {
            info("'{}' -> {s}", .{ state, mdb.mdb_strerror(state) });
            return error.KeyNotFound;
        },
        //Requested page not found - this usually indicates corruption */
        mdb.MDB_PAGE_NOTFOUND => {
            info("'{}' -> {s}", .{ state, mdb.mdb_strerror(state) });
            return error.RequestedPageNotFound;
        },
        //Located page was wrong type */
        mdb.MDB_CORRUPTED => {
            info("'{}' -> {s}", .{ state, mdb.mdb_strerror(state) });
            return error.WrongPageType;
        },
        //Update of meta page failed or environment had fatal error */
        mdb.MDB_PANIC => {
            info("'{}' -> {s}", .{ state, mdb.mdb_strerror(state) });
            return error.EnvFatalError;
        },
        //Environment version mismatch */
        mdb.MDB_VERSION_MISMATCH => {
            info("'{}' -> {s}", .{ state, mdb.mdb_strerror(state) });
            return error.EnvVersionMismatch;
        },
        //File is not a valid LMDB file */
        mdb.MDB_INVALID => {
            info("'{}' -> {s}", .{ state, mdb.mdb_strerror(state) });
            return error.InvalidDbFile;
        },
        //Environment mapsize reached */
        mdb.MDB_MAP_FULL => {
            info("'{}' -> {s}", .{ state, mdb.mdb_strerror(state) });
            return error.EnvMapsizeFull;
        },
        //Environment maxdbs reached */
        mdb.MDB_DBS_FULL => {
            info("'{}' -> {s}", .{ state, mdb.mdb_strerror(state) });
            return error.EnvMaxDbsOpened;
        },
        //Environment maxreaders reached */
        mdb.MDB_READERS_FULL => {
            info("'{}' -> {s}", .{ state, mdb.mdb_strerror(state) });
            return error.EnvMaxReaders;
        },
        //Too many TLS keys in use - Windows only */
        mdb.MDB_TLS_FULL => {
            info("'{}' -> {s}", .{ state, mdb.mdb_strerror(state) });
            return error.ManyTlsKeysUsed;
        },
        //Txn has too many dirty pages */
        mdb.MDB_TXN_FULL => {
            info("'{}' -> {s}", .{ state, mdb.mdb_strerror(state) });
            return error.ManyTxnDirtyPages;
        },
        //Cursor stack too deep - internal error */
        mdb.MDB_CURSOR_FULL => {
            info("'{}' -> {s}", .{ state, mdb.mdb_strerror(state) });
            return error.DeepCursorStack;
        },
        //Page has not enough space - internal error */
        mdb.MDB_PAGE_FULL => {
            info("'{}' -> {s}", .{ state, mdb.mdb_strerror(state) });
            return error.NotEnoughPageSpace;
        },
        //Database contents grew beyond environment mapsize */
        mdb.MDB_MAP_RESIZED => {
            info("'{}' -> {s}", .{ state, mdb.mdb_strerror(state) });
            return error.DbSizeGtEnvMapsize;
        },
        //Operation and DB incompatible, or DB type changed. This can mean:
        //The operation expects an #MDB_DUPSORT /#MDB_DUPFIXED database.
        //Opening a named DB when the unnamed DB has #MDB_DUPSORT /#MDB_INTEGERKEY.
        //Accessing a data record as a database, or vice versa.
        //The database was dropped and recreated with different flags.
        mdb.MDB_INCOMPATIBLE => {
            info("'{}' -> {s}", .{ state, mdb.mdb_strerror(state) });
            return error.OpAndDbIncompatible;
        },
        //Invalid reuse of reader locktable slot */
        mdb.MDB_BAD_RSLOT => {
            info("'{}' -> {s}", .{ state, mdb.mdb_strerror(state) });
            return error.InvalidReaderSlotReuse;
        },
        //Transaction must abort, has a child, or is invalid */
        mdb.MDB_BAD_TXN => {
            info("'{}' -> {s}", .{ state, mdb.mdb_strerror(state) });
            return error.InvalidTxn;
        },
        //Unsupported size of key/DB name/data, or wrong DUPFIXED size */
        mdb.MDB_BAD_VALSIZE => {
            info("'{}' -> {s}", .{ state, mdb.mdb_strerror(state) });
            return error.UnsupportedComponentSize;
        },
        //The specified DBI was changed unexpectedly */
        mdb.MDB_BAD_DBI => {
            info("'{}' -> {s}", .{ state, mdb.mdb_strerror(state) });
            return error.InvalidDbHandle;
        },
        //out of memory.
        @enumToInt(err.NOENT) => {
            info("'{}' -> {s}", .{ state, mdb.mdb_strerror(state) });
            return error.NoSuchFileOrDirectory;
        },
        //don't have adecuate permissions to perform operation
        @enumToInt(err.ACCES) => {
            info("'{}' -> {s}", .{ state, mdb.mdb_strerror(state) });
            return error.PermissionDenied;
        },
        //the environment was locked by another process.
        @enumToInt(err.AGAIN) => {
            info("'{}' -> {s}", .{ state, mdb.mdb_strerror(state) });
            return error.EnvLockedTryAgain;
        },
        @enumToInt(err.NOMEM) => {
            info("'{}' -> {s}", .{ state, mdb.mdb_strerror(state) });
            return error.OutOfMemory;
        },
        //an invalid parameter was specified.
        @enumToInt(err.INVAL) => {
            info("'{}' -> {s}", .{ state, mdb.mdb_strerror(state) });
            return error.InvalidArgument;
        },
        //a low-level I/O error occurred
        @enumToInt(err.IO) => {
            info("'{}' -> {s}", .{ state, mdb.mdb_strerror(state) });
            return error.IOFailed;
        },
        //no more disk space on device.
        @enumToInt(err.NOSPC) => {
            info("'{}' -> {s}", .{ state, mdb.mdb_strerror(state) });
            return error.DiskSpaceFull;
        },
        else => panic("'{}' -> {s}", .{ state, mdb.mdb_strerror(state) }),
    }
}

test "test db key:str / value:str" {
    var dbh = initdb("./testdb", .rw);
    defer deinitdb(dbh);

    const wtxn = dbh.startTxn(.rw, BLOCK_DB);

    const val: [5]u8 = "value".*;
    {
        try wtxn.update("key", val);
        defer wtxn.commitTxns();
    }

    const rtxn = dbh.startTxn(.ro, BLOCK_DB);
    defer rtxn.doneReading();
    try testing.expectEqualSlices(u8, "value", (try rtxn.get("key", val.len)));
}

test "test db update" {
    var dbh = initdb("./testdb", .rw);
    defer deinitdb(dbh);

    const txn = dbh.startTxn(.rw, BLOCK_DB);
    //TODO(ultracode): find out why this causes a segfault
    defer txn.commitTxns();

    const Data = struct {
        char: [21]u8,
        int: u8,
        ochar: [21]u8,
    };
    const data = Data{
        .char = "is my data still here".*,
        .int = 254,
        .ochar = "is my data still here".*,
    };

    try txn.update("data_key", data);
    const gotten_data = try txn.getAs(Data, "data_key");

    try testing.expectEqualSlices(u8, data.char[0..], gotten_data.char[0..]);
    try testing.expectEqualSlices(u8, data.ochar[0..], gotten_data.ochar[0..]);
    try testing.expect(data.int == gotten_data.int);
}
