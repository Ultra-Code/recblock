pub const mdb = struct {
    pub usingnamespace @cImport({
        @cInclude("lmdb.h");
    });
};

const std = @import("std");
const panic = std.debug.panic;
const assert = std.debug.assert;
const info = std.log.info;
const testing = std.testing;
const err = std.os.E;

pub const Lmdb = @This();

const serializer = @import("serializer.zig");
const BLOCK_DB = @import("Blockchain.zig").BLOCK_DB;

const Env = mdb.MDB_env;
pub const Key = mdb.MDB_val;
pub const Val = mdb.MDB_val;
const Txn = mdb.MDB_txn;
const DbHandle = mdb.MDB_dbi;

//TODO: since we can get this from the environment dont store it in this struct
///Special options for this environment
pub const TxnType = enum(c_uint) {
    ///Use a writeable memory map unless MDB_RDONLY is set. This is faster and uses fewer mallocs,
    //but loses protection from application bugs like wild pointer writes and other bad updates into the database.
    rw = mdb.MDB_WRITEMAP,
    ///Open the environment in read-only mode. No write operations will be allowed.
    //LMDB will still modify the lock file - except on read-only filesystems, where LMDB does not use locks.
    ro = mdb.MDB_RDONLY,
};

db_env: *Env,
txn: ?*Txn = null,
txn_type: TxnType,
db_handle: DbHandle = std.math.maxInt(c_uint),

///`db_path` is the directory in which the database files reside. This directory must already exist and be writable.
/// `initdb` fn initializes the db environment (mmap file) specifing the db mode `.rw/.ro`.
///Make sure to start a transaction .ie startTxn() fn before calling any db manipulation fn's
///A maximum of two named db's are allowed
///if the environment is opened in read-only mode No write operations will be allowed.
pub fn initdb(db_path: []const u8, txn_type: TxnType) Lmdb {
    var db_env: ?*Env = undefined;
    const env_state = mdb.mdb_env_create(&db_env);
    checkState(env_state) catch unreachable;
    const max_num_of_dbs = 2;

    const db_limit_state = mdb.mdb_env_set_maxdbs(db_env, max_num_of_dbs);
    checkState(db_limit_state) catch unreachable;

    const db_flags = @intFromEnum(txn_type);
    const permissions: c_uint = 0o0600; //octal permissions for created files in db_dir
    const open_state = mdb.mdb_env_open(db_env, db_path.ptr, db_flags, permissions);
    checkState(open_state) catch |open_err| switch (open_err) {
        error.NoSuchFileOrDirectory => {
            std.fs.cwd().makeDir("db") catch unreachable;
            const new_open_state = mdb.mdb_env_open(db_env, db_path.ptr, db_flags, permissions);
            checkState(new_open_state) catch unreachable;
        },
        else => unreachable,
    };

    return .{
        .db_env = db_env.?,
        .txn_type = txn_type,
    };
}

///close all opened db environment
pub fn deinitdb(lmdb: Lmdb) void {
    mdb.mdb_env_close(lmdb.db_env);
}

pub const DbTxnOption = packed struct {
    ///Create the named database if it doesn't exist.
    ///This option is not allowed in a read-only transaction or a read-only environment.
    rw: bool,
    ///Duplicate keys may be used in the database.
    ///(Or, from another perspective, keys may have multiple data items, stored in sorted order.)
    dup: bool = false,
};

///start a transaction in rw/ro mode and get a db handle for db manipulation
///commit changes with commitTxns() if .rw else doneReading() if .ro
pub fn startTxn(lmdb: Lmdb) *Txn {
    // This transaction will not perform any write operations if ro.
    const flags: c_uint = if (lmdb.txn_type == .ro) mdb.MDB_RDONLY else 0;
    const parent = null; //no parent
    var txn: ?*Txn = undefined; //where the new #MDB_txn handle will be stored
    const txn_state = mdb.mdb_txn_begin(lmdb.db_env, parent, flags, &txn);
    checkState(txn_state) catch unreachable;

    return txn.?;
}

//TODO:maybe support other flags for db like MDB_DUPSORT && MDB_DUPFIXED
//A single transaction can open multiple databases
pub fn setDbOpt(lmdb: Lmdb, db_txn: *Txn, db_txn_option: DbTxnOption, comptime db_name: []const u8) void {
    //Create the named database if it doesn't exist.
    //This option is not allowed in a read-only transaction or a read-only environment
    var db_flags: c_uint = 0;
    if (lmdb.txn_type == .rw and db_txn_option.rw) {
        db_flags |= mdb.MDB_CREATE;
    } else if (lmdb.txn_type == .ro and db_txn_option.rw) {
        @panic("Can't create a new database " ++ db_name ++ " in a read-only environment or transaction");
    }

    if (db_txn_option.dup) db_flags |= mdb.MDB_DUPSORT;

    var db_handle: mdb.MDB_dbi = undefined; //dbi Address where the new #MDB_dbi handle will be stored
    const db_state = mdb.mdb_dbi_open(db_txn, db_name.ptr, db_flags, &db_handle);
    checkState(db_state) catch unreachable;
}

//from https://bugs.openldap.org/show_bug.cgi?id=10005
//The persistent flags you specified when the DB was created
//are stored in the DB record and retrieved when the DB is opened.
//Flags specified to mdb_dbi_open at any other time are ignored.
pub fn openDb(lmdb: Lmdb, db_txn: *Txn, comptime db_name: []const u8) Lmdb {
    var db_handle: mdb.MDB_dbi = undefined; //dbi Address where the new #MDB_dbi handle will be stored
    const DEFAULT_FLAGS = 0;
    const db_state = mdb.mdb_dbi_open(db_txn, db_name.ptr, DEFAULT_FLAGS, &db_handle);
    checkState(db_state) catch unreachable;
    return .{
        .db_env = lmdb.db_env,
        .txn = db_txn,
        .txn_type = lmdb.txn_type,
        .db_handle = db_handle,
    };
}
//TODO: make openDb consistent with setDbOpt and openDb
///open a different db in an already open transaction
pub fn openNewDb(lmdb: Lmdb, db_txn_option: DbTxnOption, db_name: []const u8) Lmdb {
    //make sure a transaction has been created already
    ensureValidState(lmdb);
    const handle = openDb(lmdb, db_txn_option, db_name);
    return .{
        .db_env = lmdb.db_env,
        .txn = lmdb.txn.?,
        .txn_type = lmdb.txn_type,
        .db_handle = handle,
    };
}

pub inline fn ensureValidState(lmdb: Lmdb) void {
    assert(lmdb.txn != null);
    assert(lmdb.db_handle != std.math.maxInt(c_uint));
}

const DeleteAction = enum {
    //when there are no duplicates .ie MDB_DUPSORT isn't enabled
    single,
    //when MDB_DUPSORT is enabled and you want to delete a specific duplicate key/value pair
    exact,
    //when MDB_DUPSORT is enabled, delete all key/value pairs that match the key
    all,
};
///delete entry in db with key `key`
///Use If the database supports sorted duplicate data items (MDB_DUPSORT) else the data parameter is ignored.
///because If the database supports sorted duplicates and the data parameter is NULL, all of the duplicate data items
///for the key will be deleted. While, if the data parameter is non-NULL only the matching data item will be deleted.
pub fn del(lmdb: Lmdb, key: []const u8, comptime del_opt: DeleteAction, data: anytype) !void {
    ensureValidState(lmdb);
    var del_key = dbKey(key);

    switch (del_opt) {
        .exact => {
            const db_flags = try DbFlags.flags(lmdb);
            if (db_flags.isDupSorted()) {
                const serialized_data = serializer.serialize(data);
                var del_data = dbValue(serialized_data);

                const del_state = mdb.mdb_del(lmdb.txn.?, lmdb.db_handle, &del_key, &del_data);
                try checkState(del_state);
            } else unreachable;
        },
        .all, .single => {
            const del_state = mdb.mdb_del(lmdb.txn.?, lmdb.db_handle, &del_key, null);
            try checkState(del_state);
        },
    }
}

///for the special case of deleting an exact item where the data contains slices
pub fn delDupsAlloc(lmdb: Lmdb, allocator: std.mem.Allocator, key: []const u8, data: anytype) !void {
    ensureValidState(lmdb);
    //This function will return MDB_NOTFOUND if the specified key/data pair is not in the database.
    const db_flags = try DbFlags.flags(lmdb);
    if (db_flags.isDupSorted()) {
        var del_key = dbKey(key);
        const serialized_data = serializer.serializeAlloc(allocator, data);
        var del_data = dbValue(serialized_data);

        const del_state = mdb.mdb_del(lmdb.txn.?, lmdb.db_handle, &del_key, &del_data);
        try checkState(del_state);
    } else unreachable;
}

const RemoveAction = enum(u1) {
    empty,
    delete_and_close,
};

inline fn remove(lmdb: Lmdb, action: RemoveAction) void {
    //0 to empty the DB, 1 to delete it from the environment and close the DB handle.
    const empty_db_state = mdb.mdb_drop(lmdb.txn.?, lmdb.db_handle, @intFromEnum(action));
    checkState(empty_db_state) catch unreachable;
}

///Empty the DB `db_name`
pub fn emptyDb(lmdb: Lmdb) void {
    ensureValidState(lmdb);

    remove(lmdb, .empty);
}

/// Delete db `db_name` from the environment and close the DB handle.
pub fn delDb(lmdb: Lmdb) void {
    ensureValidState(lmdb);

    remove(lmdb, .delete_and_close);
}

const DbFlags = struct {
    flags: c_uint,
    const Self = @This();

    pub fn flags(lmdb: Lmdb) !DbFlags {
        ensureValidState(lmdb);

        var set_flags: c_uint = undefined;
        const get_flags_state = mdb.mdb_dbi_flags(lmdb.txn, lmdb.db_handle, &set_flags);
        try checkState(get_flags_state);

        return .{ .flags = set_flags };
    }

    fn isDupSorted(self: Self) bool {
        return if ((self.flags & mdb.MDB_DUPSORT) == mdb.MDB_DUPSORT) true else false;
    }
};

const InsertFlags = enum {
    //allow duplicate key/data pairs
    dup_data,
    //allow duplicate keys but not duplicate key/data pairs
    no_dup_data,
    //disallow duplicate keys even if duplicates are allowed
    no_overwrite,
    //replace previously existing data, use this with case else you might loss overwriten data
    overwrite,
};

fn insert(lmdb: Lmdb, key: []const u8, serialized_data: []const u8, flags: InsertFlags) !void {
    const set_flags = try DbFlags.flags(lmdb);
    const is_dup_sorted = set_flags.isDupSorted();
    const DEFAULT_BEHAVIOUR = 0;
    const ALLOW_DUP_DATA = 0;
    // zig fmt: off
    const insert_flags: c_uint =
    //enter the new key/data pair only if both key and value does not already appear in the database.
    //that is allow duplicate keys but not both duplicate keys and values
    if (is_dup_sorted and flags == .no_dup_data )
    // Only for MDB_DUPSORT
    // For put: don't write if the key and data pair already exist.
    // For mdb_cursor_del: remove all duplicate data items.
        mdb.MDB_NODUPDATA
    //default behavior: allow adding a duplicate key/data item if duplicates are allowed (MDB_DUPSORT)
    else if (is_dup_sorted and flags == .dup_data )
        ALLOW_DUP_DATA
    // if the database supports duplicates (MDB_DUPSORT). The data parameter will be set to point to the existing item.
    else if (is_dup_sorted and flags == .no_overwrite ) mdb.MDB_NOOVERWRITE
    //enter the new key/data pair only if the key does not already appear in the database
    //that is: don't allow overwriting keys
    else if (flags == .no_overwrite ) mdb.MDB_NOOVERWRITE
    //The default behavior is to enter the new key/data pair,
    //replacing any previously existing key if duplicates are disallowed
    //allow overwriting data
    else DEFAULT_BEHAVIOUR;
    // zig fmt: on

    if (is_dup_sorted and flags == .overwrite) {
        del(lmdb, key, .all, {}) catch unreachable;
        return try mdbput(lmdb, insert_flags, key, serialized_data);
    } else if (flags == .overwrite) {
        //use default behavior
        return try mdbput(lmdb, insert_flags, key, serialized_data);
    }

    try mdbput(lmdb, insert_flags, key, serialized_data);
}

fn mdbput(lmdb: Lmdb, insert_flags: c_uint, key: []const u8, serialized_data: []const u8) !void {
    //due to limitations of lmdb,the len of data items in a #MDB_DUPSORT db are limited to a max of 512
    // NOTE: MDB_MAXKEYSIZE macro in deps/lmdb/libraries/liblmdb/mdb.c Line:665

    var insert_key = dbKey(key);
    var value_data = dbValue(serialized_data[0..]);
    const put_state = mdb.mdb_put(
        lmdb.txn.?,
        lmdb.db_handle,
        &insert_key,
        &value_data,
        insert_flags,
    );

    checkState(put_state) catch |put_errors| switch (put_errors) {
        error.UnsupportedKeyOrDataSize => @panic(
            \\Cannot store Keys/#MDB_DUPSORT data items greater than 512.
            \\Maybe try the compress option/rethink your use of dupsort db
            \\http://www.lmdb.tech/doc/group__mdb.html#gaaf0be004f33828bf2fb09d77eb3cef94
        ),
        else => |remaining_put_errors| return remaining_put_errors,
    };
}

///insert new key/data pair without overwriting already inserted pair
///if `data` contains pointers or slices use `putAlloc`
pub fn put(lmdb: Lmdb, key: []const u8, data: anytype) !void {
    ensureValidState(lmdb);

    const serialized_data = serializer.serialize(data);

    try insert(lmdb, key, serialized_data[0..], .no_overwrite);
}

///use `putAlloc` when data contains slices or pointers
///recommend you use fixedBufferAllocator or ArenaAllocator
pub fn putAlloc(lmdb: Lmdb, fba: std.mem.Allocator, key: []const u8, data: anytype) !void {
    ensureValidState(lmdb);
    const serialized_data = serializer.serializeAlloc(fba, data);

    try insert(lmdb, key, serialized_data[0..], .no_overwrite);
}

pub fn putDup(lmdb: Lmdb, key: []const u8, data: anytype, dup_data: bool) !void {
    ensureValidState(lmdb);

    const serialized_data = serializer.serialize(data);
    if (dup_data) {
        try insert(lmdb, key, serialized_data[0..], .dup_data);
    } else {
        try insert(lmdb, key, serialized_data[0..], .no_dup_data);
    }
}

pub fn putDupAlloc(lmdb: Lmdb, allocator: std.mem.Allocator, key: []const u8, data: anytype, dup_data: bool) !void {
    ensureValidState(lmdb);

    const serialized_data = serializer.serializeAlloc(allocator, data);
    if (dup_data) {
        try insert(lmdb, key, serialized_data[0..], .dup_data);
    } else {
        try insert(lmdb, key, serialized_data[0..], .no_dup_data);
    }
}

///insert/update already existing key/data pair
pub fn update(lmdb: Lmdb, key: []const u8, data: anytype) !void {
    ensureValidState(lmdb);

    const serialized_data = serializer.serialize(data);
    try insert(lmdb, key, serialized_data[0..], .overwrite);
}

///insert/update already existing key/data pair
pub fn updateAlloc(lmdb: Lmdb, allocator: std.mem.Allocator, key: []const u8, data: anytype) !void {
    ensureValidState(lmdb);

    const serialized_data = serializer.serializeAlloc(allocator, data);
    try insert(lmdb, key, serialized_data[0..], .overwrite);
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
fn abortTxns(lmdb: Lmdb) void {
    mdb.mdb_txn_abort(lmdb.txn.?);
}

///This is any unsafe cast which discards const
pub fn cast(comptime T: type, any_ptr: anytype) T {
    return @constCast(any_ptr);
}

///get `key` as `T` when it doesn't require allocation
pub fn get(lmdb: Lmdb, comptime T: type, key: []const u8) !T {
    ensureValidState(lmdb);

    var data: Val = undefined;

    var get_key = dbKey(key);
    const get_state = mdb.mdb_get(
        lmdb.txn.?,
        lmdb.db_handle,
        &get_key,
        &data,
    );

    try checkState(get_state);
    return serializer.deserialize(T, data.mv_data, data.mv_size);
}

///get `key` as `T` when it doesn't require allocation
pub fn getAlloc(lmdb: Lmdb, comptime T: type, fba: std.mem.Allocator, key: []const u8) !T {
    ensureValidState(lmdb);

    var data: Val = undefined;
    var get_key = dbKey(key);
    const get_state = mdb.mdb_get(
        lmdb.txn.?,
        lmdb.db_handle,
        &get_key,
        &data,
    );

    try checkState(get_state);
    return serializer.deserializeAlloc(T, fba, data.mv_data, data.mv_size);
}

fn dbKey(data: []const u8) Key {
    return dbValue(data);
}

fn dbValue(data: []const u8) Val {
    return .{ .mv_size = data.len, .mv_data = cast(*anyopaque, data.ptr) };
}

///check state of operation to make sure there where no errors
pub fn checkState(state: c_int) !void {
    switch (state) {
        //lmdb  errors  Return Codes
        //Successful result */
        mdb.MDB_SUCCESS => {},
        //key/data pair already exists */
        mdb.MDB_KEYEXIST => {
            return error.KeyAlreadyExist;
        },
        //key/data pair not found (EOF) */
        mdb.MDB_NOTFOUND => {
            return error.KeyNotFound;
        },
        //Requested page not found - this usually indicates corruption */
        mdb.MDB_PAGE_NOTFOUND => {
            return error.RequestedPageNotFound;
        },
        //Located page was wrong type */
        mdb.MDB_CORRUPTED => {
            return error.WrongPageType;
        },
        //Update of meta page failed or environment had fatal error */
        mdb.MDB_PANIC => {
            return error.EnvFatalError;
        },
        //Environment version mismatch */
        mdb.MDB_VERSION_MISMATCH => {
            return error.EnvVersionMismatch;
        },
        //File is not a valid LMDB file */
        mdb.MDB_INVALID => {
            return error.InvalidDbFile;
        },
        //Environment mapsize reached */
        mdb.MDB_MAP_FULL => {
            return error.EnvMapsizeFull;
        },
        //Environment maxdbs reached */
        mdb.MDB_DBS_FULL => {
            return error.EnvMaxDbsOpened;
        },
        //Environment maxreaders reached */
        mdb.MDB_READERS_FULL => {
            return error.EnvMaxReaders;
        },
        //Too many TLS keys in use - Windows only */
        mdb.MDB_TLS_FULL => {
            return error.ManyTlsKeysUsed;
        },
        //Txn has too many dirty pages */
        mdb.MDB_TXN_FULL => {
            return error.ManyTxnDirtyPages;
        },
        //Cursor stack too deep - internal error */
        mdb.MDB_CURSOR_FULL => {
            return error.DeepCursorStack;
        },
        //Page has not enough space - internal error */
        mdb.MDB_PAGE_FULL => {
            return error.NotEnoughPageSpace;
        },
        //Database contents grew beyond environment mapsize */
        mdb.MDB_MAP_RESIZED => {
            return error.DbSizeGtEnvMapsize;
        },
        //Operation and DB incompatible, or DB type changed. This can mean:
        //The operation expects an #MDB_DUPSORT /#MDB_DUPFIXED database.
        //Opening a named DB when the unnamed DB has #MDB_DUPSORT /#MDB_INTEGERKEY.
        //Accessing a data record as a database, or vice versa.
        //The database was dropped and recreated with different flags.
        mdb.MDB_INCOMPATIBLE => {
            return error.OpAndDbIncompatible;
        },
        //Invalid reuse of reader locktable slot */
        mdb.MDB_BAD_RSLOT => {
            return error.InvalidReaderSlotReuse;
        },
        //Transaction must abort, has a child, or is invalid */
        mdb.MDB_BAD_TXN => {
            return error.InvalidTxn;
        },
        //Unsupported size of key/DB name/data, or wrong DUPFIXED size */
        mdb.MDB_BAD_VALSIZE => {
            return error.UnsupportedKeyOrDataSize;
        },
        //The specified DBI was changed unexpectedly */
        mdb.MDB_BAD_DBI => {
            return error.InvalidDbHandle;
        },
        //out of memory.
        @intFromEnum(err.NOENT) => {
            return error.NoSuchFileOrDirectory;
        },
        //don't have adecuate permissions to perform operation
        @intFromEnum(err.ACCES) => {
            return error.PermissionDenied;
        },
        //the environment was locked by another process.
        @intFromEnum(err.AGAIN) => {
            return error.EnvLockedTryAgain;
        },
        @intFromEnum(err.NOMEM) => {
            return error.OutOfMemory;
        },
        //an invalid parameter was specified.
        @intFromEnum(err.INVAL) => {
            return error.InvalidArgument;
        },
        //a low-level I/O error occurred
        @intFromEnum(err.IO) => {
            return error.IOFailed;
        },
        //no more disk space on device.
        @intFromEnum(err.NOSPC) => {
            return error.DiskSpaceFull;
        },
        else => panic("'{}' -> {s}", .{ state, mdb.mdb_strerror(state) }),
    }
}

test "test db key:str / value:str" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath(tmp.sub_path[0..]);

    const ta = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const allocator = arena.allocator();

    const db_path = try std.cstr.addNullByte(allocator, try tmp.dir.realpathAlloc(allocator, "."));

    var dbh = initdb(db_path, .rw);
    defer deinitdb(dbh);

    const wtxn = dbh.startTxn(.rw, BLOCK_DB);

    const val: [5]u8 = "value".*;
    {
        try wtxn.put("key", val);
        defer wtxn.commitTxns();
    }

    const rtxn = dbh.startTxn(.ro, BLOCK_DB);
    {
        try testing.expectEqualSlices(u8, "value", (try rtxn.get([5]u8, "key"))[0..]);
        defer rtxn.doneReading();
    }

    var slicetxn = dbh.startTxn(.rw, BLOCK_DB);
    const slice_data = [_][]const u8{ "hello", "serializer" };
    {
        try slicetxn.putAlloc(allocator, "slice", &slice_data);
        defer slicetxn.commitTxns();
    }

    slicetxn = dbh.startTxn(.ro, BLOCK_DB);
    {
        const deserialized_slice_data = try slicetxn.getAlloc([2][]const u8, allocator, "slice");
        for (slice_data, 0..) |str, index| {
            try testing.expectEqualStrings(str[0..], deserialized_slice_data[index]);
        }
        defer slicetxn.doneReading();
    }
}

test "test db update" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath(tmp.sub_path[0..]);

    const ta = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const allocator = arena.allocator();

    const db_path = try std.cstr.addNullByte(allocator, try tmp.dir.realpathAlloc(allocator, "."));

    var dbh = initdb(db_path, .rw);
    defer deinitdb(dbh);

    const txn = dbh.startTxn(.rw, BLOCK_DB);
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

    try txn.put("data_key", data);
    const gotten_data = try txn.get(Data, "data_key");

    try testing.expectEqualSlices(u8, data.char[0..], gotten_data.char[0..]);
    try testing.expectEqualSlices(u8, data.ochar[0..], gotten_data.ochar[0..]);
    try testing.expect(data.int == gotten_data.int);
}

//TODO: review the test below for it relevance now
test "serialization/deserialization data" {
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

    const file = try std.fs.cwd().createFile("serialized.data", .{ .read = true });
    //defer statements are runned in the reverse order of execution
    defer std.fs.cwd().deleteFile("serialized.data") catch unreachable;
    defer file.close();

    const writer = file.writer();
    try serializer.serialize(writer, Data, data);
    try file.seekTo(0);

    const reader = file.reader();
    const deserialized_data = try serializer.deserialize(reader, Data);

    try testing.expectEqualSlices(u8, data.char[0..], deserialized_data.char[0..]);
    try testing.expectEqualSlices(u8, data.ochar[0..], deserialized_data.ochar[0..]);
    try testing.expect(data.int == deserialized_data.int);
}

test "serialization/deserialization packed data" {
    const Data = extern struct {
        char: [21]u8,
        int: u8,
        ochar: [21]u8,
    };

    const data = Data{
        .char = "is my data still here".*,
        .int = 254,
        .ochar = "is my data still here".*,
    };

    const file = try std.fs.cwd().createFile("serialized.data", .{ .read = true });
    //defer statements are runned in the reverse order of execution
    defer std.fs.cwd().deleteFile("serialized.data") catch unreachable;
    defer file.close();

    const writer = file.writer();
    try serializer.serialize(writer, Data, data);
    try file.seekTo(0);

    const reader = file.reader();
    const deserialized_data = try serializer.deserialize(reader, Data);

    try testing.expectEqualSlices(u8, data.char[0..], deserialized_data.char[0..]);
    try testing.expectEqualSlices(u8, data.ochar[0..], deserialized_data.ochar[0..]);
    try testing.expect(data.int == deserialized_data.int);
}

test "readStruct/writeStruct with array field" {
    const Data = extern struct { arr: [3]u8 };
    const data = Data{ .arr = [_]u8{'0'} ** 3 };

    var buf: [@sizeOf(Data)]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    try fbs.writer().writeStruct(data);
    try fbs.seekTo(0);

    const read_data = try fbs.reader().readStruct(Data);

    try testing.expectEqualSlices(u8, data.arr[0..], read_data.arr[0..]);
}
