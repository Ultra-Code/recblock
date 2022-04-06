const db = struct {
    usingnamespace @cImport({
        @cInclude("lmdb.h");
    });
};

const err = struct {
    usingnamespace @cImport({
        @cInclude("errno.h");
    });
};

const std = @import("std");
const panic = std.debug.panic;
const assert = std.debug.assert;
const debug = std.log.debug;
const testing = std.testing;

const serializer = @import("serializer.zig");
const cast = serializer.cast;
const serialize = serializer.serialize;
const deserialize = serializer.deserialize;
const getBytes = serializer.getBytes;
const getBytesAs = serializer.getBytesAs;

const PutError = error{
    DbFull,
    TxnFull,
    ReadOnlyTxn,
    InvalidParam,
    KeyExist,
};

const GetError = error{
    KeyNotInDb,
    InvalidParam,
};

const SUCCESS = db.MDB_SUCCESS;
const Env = db.MDB_env;
const Key = db.MDB_val;
const Val = db.MDB_val;
const Txn = db.MDB_txn;
pub const DbHandle = db.MDB_dbi;

pub const Lmdb = @This();
const TxnType = enum { rw, ro };
db_env: *Env,
txn: *Txn = undefined,
db_handle: DbHandle = undefined,

///`db_path` is the directory in which the database files reside. This directory must already exist and be writable.
///initialize db environment (mmap file) specifing the db mode `.rw/.ro`
///make sure to start a transaction .ie startTxn() fn before calling any db manipulation fn's
///a maximum of two named db's are allowed
pub fn initdb(db_path: []const u8, txn_type: TxnType) Lmdb {
    var db_env: ?*Env = undefined;
    const env_state = db.mdb_env_create(&db_env);
    if (env_state != SUCCESS) {
        panic("Failed to Create an LMDB environment handle.", .{});
    }
    const max_num_of_dbs = 2;

    if (db.mdb_env_set_maxdbs(db_env, max_num_of_dbs) != SUCCESS) {
        panic("an invalid parameter was specified, or the environment is already open", .{});
    }

    const db_flags: c_uint = if (txn_type == .ro) db.MDB_RDONLY else 0;
    const permissions: c_uint = 0o0600; //octal permissions for created files in db_dir
    const open_state = db.mdb_env_open(db_env, db_path.ptr, db_flags, permissions);
    checkOpenState(open_state, db_env);

    debug("done opening db environment", .{});
    return .{
        .db_env = db_env.?,
    };
}

///close all opened db environment
pub fn deinitdb(lmdb: Lmdb) void {
    db.mdb_env_close(lmdb.db_env);
}

///start a transaction in rw/ro mode and get a db handle for db manipulation
///commit changes with commitTxns() fn
pub fn startTxn(lmdb: Lmdb, txn_type: TxnType, db_name: []const u8) Lmdb {
    const txn = beginTxn(lmdb.db_env, txn_type);
    const handle = openDb(lmdb.db_env, txn, txn_type, db_name);
    return .{
        .db_env = lmdb.db_env,
        .txn = txn,
        .db_handle = handle,
    };
}

fn beginTxn(db_env: *Env, txn_type: TxnType) *Txn {
    // This transaction will not perform any write operations if ro.
    const flags: c_uint = if (txn_type == .ro) db.MDB_RDONLY else 0;
    const parent = null; //no parent
    var txn: ?*Txn = undefined; //where the new #MDB_txn handle will be stored
    const txn_state = db.mdb_txn_begin(db_env, parent, flags, &txn);
    checkTxnState(txn_state);

    const write_t = switch (txn_type) {
        .ro => "read-only",
        .rw => "read-write",
    };
    debug("done starting {s} transaction", .{write_t});
    return txn.?;
}

fn openDb(db_env: *Env, txn: *Txn, txn_type: TxnType, db_name: []const u8) DbHandle {
    const db_flags: c_uint = if (txn_type == .rw) db.MDB_CREATE else 0; //Create the named database if it doesn't exist. This option is not allowed in a read-only transaction or a read-only environment.

    var db_handle: db.MDB_dbi = undefined; //dbi Address where the new #MDB_dbi handle will be stored
    const db_state = db.mdb_dbi_open(txn, db_name.ptr, db_flags, &db_handle);
    checkOpenState(db_state, db_env);
    debug("done opening block db", .{});
    return db_handle;
}
const InsertionType = enum {
    put, //overwrite isn't allowed
    update, //overwite data is allowed
};

fn insert(lmdb: Lmdb, insertion_t: InsertionType, key_val: []const u8, data: anytype) !void {
    const insert_flags: c_uint = switch (insertion_t) {
        .put => db.MDB_NOOVERWRITE, // don't overwrite data if key already exist
        .update => 0,
    };

    const DataType = @TypeOf(data);
    const hash_size = 8; //size of std.hash.Fnv1a_64 is 64bit which is 8 byte
    var serialized_data: [@sizeOf(DataType) + hash_size]u8 = undefined;

    var fbr = std.io.fixedBufferStream(&serialized_data);
    const writer = fbr.writer();
    serialize(writer, DataType, data) catch unreachable;

    const put_state = db.mdb_put(
        lmdb.txn,
        lmdb.db_handle,
        &key(key_val),
        &value(serialized_data[0..]),
        insert_flags,
    );
    try checkPutState(put_state);

    const insertion_name = switch (insertion_t) {
        .put => "putting",
        .update => "updating",
    };
    debug("done {s} key/value in db", .{insertion_name});
}

pub fn put(lmdb: Lmdb, key_val: []const u8, data: anytype) PutError!void {
    assert(lmdb.txn != undefined);
    assert(lmdb.db_handle != undefined);

    try insert(lmdb, .put, key_val, data);
}

pub fn update(lmdb: Lmdb, key_val: []const u8, data: anytype) PutError!void {
    assert(lmdb.txn != undefined);
    assert(lmdb.db_handle != undefined);

    try insert(lmdb, .update, key_val, data);
}

const BLOCK_DB = @import("blockchain.zig").BLOCK_DB;

test "test db key:str / value:str" {
    var dbh = initdb("/home/ultracode/repos/zig/recblock/db", .rw);
    defer deinitdb(dbh);

    const txn = dbh.startTxn(.rw, BLOCK_DB);
    defer txn.commitTxns();
    //TODO: read should be a separate transaction

    try txn.put("key", "value");
    try testing.expectEqualSlices(u8, "value", (try txn.get("key")));
}

test "test db update" {
    var dbh = initdb("/home/ultracode/repos/zig/recblock/db", .rw);
    defer deinitdb(db);

    const txn = dbh.startTxn(.rw, BLOCK_DB);
    defer commitTxns(dbh);

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

///commit all transaction on the current db handle
///should usually be called before the end of fn's to save db changes
pub fn commitTxns(lmdb: Lmdb) void {
    assert(lmdb.txn != undefined);

    const commit_state = db.mdb_txn_commit(lmdb.txn);
    checkState(commit_state);
    debug("done commiting transaction into db", .{});
}

///cancel/discard all transaction on the current db handle
pub fn abortTxns(lmdb: Lmdb) void {
    db.mdb_txn_abort(lmdb.txn);
}

///get the data as a slice of bytes
pub fn get(lmdb: Lmdb, key_val: []const u8) GetError![]u8 {
    assert(lmdb.txn != undefined);
    assert(lmdb.db_handle != undefined);

    var data: Val = undefined;
    const get_state = db.mdb_get(
        lmdb.txn,
        lmdb.db_handle,
        &key(key_val),
        &data,
    );

    try checkGetState(get_state);
    return getBytes(data.mv_data, data.mv_size);
}

///get the data as type `T`
pub fn getAs(lmdb: Lmdb, comptime T: type, key_val: []const u8) GetError!T {
    assert(lmdb.txn != undefined);
    assert(lmdb.db_handle != undefined);

    var data: Val = undefined;
    const get_state = db.mdb_get(
        lmdb.txn,
        lmdb.db_handle,
        &key(key_val),
        &data,
    );
    try checkGetState(get_state);
    return getBytesAs(T, data.mv_data, data.mv_size);
}

fn key(data: []const u8) Key {
    return .{ .mv_size = data.len, .mv_data = cast(*anyopaque, data.ptr) };
}

fn value(data: []const u8) Val {
    const trait = std.meta.trait;
    const DataType = @TypeOf(data);
    if (comptime !(trait.isSlice(DataType) or trait.isPtrTo(.Array)(DataType) or trait.is(.Struct)(DataType) or trait.isSingleItemPtr(DataType))) {
        @compileError("expected []const u8 or *const [_:0]u8 or anytype or *anytype but passed " ++ @typeName(DataType));
    }
    if (comptime trait.isSlice(DataType)) {
        // if (comptime trait.isSliceOf(.Int)([]const u8)) {
        return .{ .mv_size = data.len, .mv_data = cast(*anyopaque, data.ptr) };
    }
    if (comptime trait.isPtrTo(.Array)(DataType)) {
        // if (comptime trait.isPtrTo(.Array)(*const [data.len:0]u8)) {
        return .{ .mv_size = data.len, .mv_data = cast(*anyopaque, data) };
    }
    if (comptime trait.isSingleItemPtr(DataType)) {
        return .{ .mv_size = @sizeOf(@TypeOf(data)), .mv_data = cast(*anyopaque, data) };
    }
    return .{ .mv_size = @sizeOf(@TypeOf(data)), .mv_data = cast(*anyopaque, &data) };
}

//TODO :Improve error messages with the fields in this struct
fn checkGetState(get_state: c_int) GetError!void {
    if (get_state == SUCCESS) {} else if (get_state == db.MDB_NOTFOUND) {
        debug("the key was not in the database.", .{});
        return error.KeyNotInDb;
    } else if (get_state == err.EINVAL) {
        debug("an invalid parameter was specified.", .{});
        return error.InvalidParam;
    }
}

fn checkPutState(put_state: c_int) PutError!void {
    if (put_state == SUCCESS) {} else if (put_state == db.MDB_MAP_FULL) {
        debug("the database is full, see #mdb_env_set_mapsize().", .{});
        return error.DbFull;
    } else if (put_state == db.MDB_TXN_FULL) {
        debug("the transaction has too many dirty pages.", .{});
        return error.TxnFull;
    } else if (put_state == err.EACCES) {
        debug("an attempt was made to write in a read-only transaction.", .{});
        return error.ReadOnlyTxn;
    } else if (put_state == err.EINVAL) {
        debug("an invalid parameter was specified.", .{});
        return error.InvalidParam;
    } else if (put_state == db.MDB_KEYEXIST) {
        debug("the key/data pair already exists in the db", .{});
        return error.KeyExist;
    } else {
        checkState(put_state);
    }
}

fn checkState(state: c_int) void {
    if (state != SUCCESS) {
        panic("{s}", .{db.mdb_strerror(state)});
    }
}

fn checkDbState(db_state: c_int) void {
    if (db_state == SUCCESS) {} else if (db_state == db.MDB_NOTFOUND) {
        panic("the specified database doesn't exist in the environment and #MDB_CREATE was not specified.", .{});
    } else if (db_state == db.MDB_DBS_FULL) {
        panic("too many databases have been opened. See #mdb_env_set_maxdbs().", .{});
    } else {
        checkState(db_state);
    }
}

fn checkOpenState(open_state: c_int, db_env: ?*Env) void {
    if (open_state == SUCCESS) {} else if (open_state == db.MDB_VERSION_MISMATCH) {
        db.mdb_env_close(db_env);
        panic("The version of the LMDB library doesn't match the version that created the database environment.", .{});
    } else if (open_state == db.MDB_INVALID) {
        db.mdb_env_close(db_env);
        panic("The environment file headers are corrupted.", .{});
    } else if (open_state == err.ENOENT) {
        db.mdb_env_close(db_env);
        panic("The directory specified by the path parameter doesn't exist.", .{});
    } else if (open_state == err.EACCES) {
        db.mdb_env_close(db_env);
        panic("The user didn't have permission to access the environment files.", .{});
    } else if (open_state == err.EAGAIN) {
        db.mdb_env_close(db_env);
        panic("The environment was locked by another process.", .{});
    } else {
        db.mdb_env_close(db_env);
        checkState(open_state);
    }
}

fn checkTxnState(txn_state: c_int) void {
    if (txn_state == SUCCESS) {} else if (txn_state == db.MDB_PANIC) {
        panic("a fatal error occurred earlier and the environment must be shut down. ", .{});
    } else if (txn_state == db.MDB_MAP_RESIZED) {
        panic("another process wrote data beyond this MDB_env's mapsize and this environment's map must be resized as well.See #mdb_env_set_mapsize().", .{});
    } else if (txn_state == db.MDB_READERS_FULL) {
        panic("a read-only transaction was requested and the reader lock table is full. See #mdb_env_set_maxreaders().", .{});
    } else if (txn_state == err.ENOMEM) {
        panic("out of memory.", .{});
    } else {
        checkState(txn_state);
    }
}
