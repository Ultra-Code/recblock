const std = @import("std");
const Lmdb = @import("Lmdb.zig");
const serializer = @import("serializer.zig");
const Transaction = @import("Transaction.zig");
const mdb = Lmdb.mdb;
const Cursor = mdb.MDB_cursor;
const ensureValidState = Lmdb.ensureValidState;
const checkState = Lmdb.checkState;
const Key = Lmdb.Key;
const Val = Lmdb.Key;

///This is the set of all operations for retrieving data using a cursor.
const CursorGetOperations = enum(mdb.MDB_cursor_op) {
    MDB_FIRST = mdb.MDB_FIRST, //Position at first key/data item
    MDB_FIRST_DUP, //Position at first data item of current key. Only for MDB_DUPSORT
    MDB_GET_BOTH, //Position at key/data pair. Only for MDB_DUPSORT
    MDB_GET_BOTH_RANGE, //position at key, nearest data. Only for MDB_DUPSORT
    MDB_GET_CURRENT, //Return key/data at current cursor position
    //Return key and up to a page of duplicate data items from current cursor position.
    //Move cursor to prepare for MDB_NEXT_MULTIPLE. Only for MDB_DUPFIXED
    MDB_GET_MULTIPLE,
    MDB_LAST, //Position at last key/data item
    MDB_LAST_DUP, //Position at last data item of current key. Only for MDB_DUPSORT
    MDB_NEXT, //Position at next data item
    MDB_NEXT_DUP, //Position at next data item of current key. Only for MDB_DUPSORT
    //Return key and up to a page of duplicate data items from next cursor position.
    //Move cursor to prepare for MDB_NEXT_MULTIPLE. Only for MDB_DUPFIXED
    MDB_NEXT_MULTIPLE,
    MDB_NEXT_NODUP, //Position at first data item of next key
    MDB_PREV, //Position at previous data item
    MDB_PREV_DUP, //Position at previous data item of current key. Only for MDB_DUPSORT
    MDB_PREV_NODUP, //Position at last data item of previous key
    MDB_SET, //Position at specified key
    MDB_SET_KEY, //Position at specified key, return key + data
    MDB_SET_RANGE, //Position at first key greater than or equal to specified key.
};

//TODO: switch on Alloc or non Alloc fn based on if type requires allocation
pub fn LmdbCursor(comptime ckey: type, comptime cvalue: type) type {
    return struct {
        const Self = @This();
        const KeyValue = struct { key: ckey, value: cvalue };
        lmdb: Lmdb,
        cursor_handle: *Cursor,

        pub fn init(lmdb_txn: Lmdb) Self {
            ensureValidState(lmdb_txn);
            var cursor_handle: ?*Cursor = undefined;
            const cursor_open_state = mdb.mdb_cursor_open(lmdb_txn.db_txn.?, lmdb_txn.db_handle, &cursor_handle);
            checkState(cursor_open_state) catch unreachable;
            return .{ .lmdb = lmdb_txn, .cursor_handle = cursor_handle.? };
        }

        pub fn doneCursoring(cursor: Self) void {
            ensureValidState(cursor.lmdb);

            mdb.mdb_cursor_close(cursor.cursor_handle);
        }

        pub fn updateCursor(cursor: Self) void {
            ensureValidState(cursor.lmdb);
            const cursor_renew_state = mdb.mdb_cursor_renew(cursor.lmdb.db_txn.?, cursor.cursor_handle);
            checkState(cursor_renew_state) catch unreachable;
        }

        ///get mutiple values with  key `key_val` as `T` when it doesn't require allocation
        //TODO: implement cursor Iterator for easy iteration
        pub fn cursorGet(cursor: Self, cursor_get_op: CursorGetOperations) ?KeyValue {
            ensureValidState(cursor.lmdb);

            var key_value: Key = undefined;
            var data_value: Val = undefined;
            const get_state = mdb.mdb_cursor_get(
                cursor.cursor_handle,
                &key_value,
                &data_value,
                @intFromEnum(cursor_get_op),
            );

            checkState(get_state) catch return null;
            return .{
                .key = serializer.deserialize(
                    ckey,
                    key_value.mv_data,
                    key_value.mv_size,
                ),
                .value = serializer.deserialize(
                    cvalue,
                    data_value.mv_data,
                    data_value.mv_size,
                ),
            };
        }
        pub fn cursorGetFirst(cursor: Self) ?KeyValue {
            return cursorGet(cursor, .MDB_FIRST) orelse null;
        }

        pub fn cursorGetFirstAlloc(cursor: Self, fba: std.mem.Allocator) ?KeyValue {
            return cursorGetAlloc(cursor, fba, .MDB_FIRST) orelse null;
        }

        pub fn cursorGetNext(cursor: Self) ?KeyValue {
            return cursorGet(cursor, .MDB_NEXT) orelse null;
        }

        pub fn cursorGetNextAlloc(cursor: Self, fba: std.mem.Allocator) ?KeyValue {
            return cursorGetAlloc(cursor, fba, .MDB_NEXT) orelse null;
        }

        ///get mutiple values with  key `key_val` as `T` when it require allocation
        pub fn cursorGetAlloc(cursor: Self, fba: std.mem.Allocator, cursor_get_op: CursorGetOperations) ?KeyValue {
            ensureValidState(cursor.lmdb);

            var key_value: Key = undefined;
            var data_value: Val = undefined;
            const get_state = mdb.mdb_cursor_get(
                cursor.cursor_handle,
                &key_value,
                &data_value,
                @intFromEnum(cursor_get_op),
            );

            checkState(get_state) catch return null;
            return .{
                .key = std.mem.bytesAsSlice(
                    ckey,
                    serializer.getRawBytes(key_value.mv_data, key_value.mv_size),
                )[0],
                .value = serializer.deserializeAlloc(
                    cvalue,
                    fba,
                    data_value.mv_data,
                    data_value.mv_size,
                ),
            };
        }

        pub fn deinit(cursor: Self) void {
            if (cursor.lmdb.db_txn_type == .ro) {
                cursor.doneCursoring();
            }
        }

        pub fn iterator(cursor: Self, fba: std.heap.FixedBufferAllocator) Iterator {
            return .{ .cursor = cursor, .fba = fba };
        }

        pub const Iterator = struct {
            cursor: Self,
            fba: std.heap.FixedBufferAllocator,
            //start transaction in interator
            pub fn init(cursor: Self, fba: std.heap.FixedBufferAllocator) Iterator {
                return .{ .cursor = cursor, .fba = fba };
            }

            pub fn deinit(self: *Iterator) void {
                self.fba.reset();
            }

            //TODO: Find out if there is the need to store the cursor
            pub fn start(itr: Iterator) ?KeyValue {
                var fba = itr.fba;
                return itr.cursor.cursorGetFirstAlloc(fba.allocator());
            }
            pub fn next(itr: Iterator) ?KeyValue {
                var fba = itr.fba;
                return itr.cursor.cursorGetNextAlloc(fba.allocator());
            }
        };

        pub fn print(cursor: Self, comptime scope_info: []const u8) void {
            var buf: [1024]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&buf);

            var itr = cursor.iterator(fba);
            defer itr.deinit();

            var next = itr.start();
            std.log.info("start printing {s}", .{scope_info});
            while (next) |key_value| : (next = itr.next()) {
                std.log.debug("key is {s}", .{key_value.key});
                for (key_value.value, 0..) |val, idx| {
                    std.log.debug("val {} has amount {} and pub_key_hash {s}", .{ idx, val.value, val.pub_key_hash });
                }
            }
            std.log.info("done printing\n", .{});
        }
    };
}
