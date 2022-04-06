const std = @import("std");
const debug = std.log.debug;
const testing = std.testing;

//IDEAS: consider maybe json serialization but prefer binnary serialization
//READ: read into Google Protocol Buffers ,Thrift and Avro in I want to use well established serialization tools

//Serialization takes an in-memory data structure and converts it into a series of bytes that can be stored and transferred.
//Deserialization takes a series of bytes and converts it to an in-memory data structure that can be consumed programmatically.

//TODO: try to implement a way to convert slices into arrays for easy serialization
//IDEAS: 🤔 maybe reify the slice type but with a .field_type of [N]u8 take inspiration from std.meta.Sentinel
//REF: https://stackoverflow.com/questions/15707933/how-to-serialize-a-struct-in-c  , serialization framework https://github.com/getty-zig/getty
//REF: https://stackoverflow.com/questions/9778806/serializing-a-class-with-a-pointer-in-c https://www.boost.org/doc/libs/1_78_0/libs/serialization/doc/tutorial.html#pointers
//REF: https://stackoverflow.com/questions/523872/how-do-you-serialize-an-object-in-c/ https://accu.org/journals/overload/24/136/ignatchenko_2317/
//REF: https://github.com/srwalter/dbus-serialize

/// serialized a type in memory
fn inMemSerialize(type_to_serialize: anytype, serialized_buf: *[@sizeOf(@TypeOf(type_to_serialize))]u8) void {
    @memcpy(serialized_buf, @ptrCast([*]const u8, &type_to_serialize), @sizeOf(@TypeOf(type_to_serialize)));
}

/// deserialize data from memory
fn inMemDeserialize(comptime T: type, serialized_t: [@sizeOf(T)]u8) T {
    return @bitCast(T, serialized_t);
}

pub fn getBytes(data: ?*anyopaque, size: usize) []u8 {
    return @ptrCast([*]u8, data.?)[0..size];
}

//TODO: handle the case where the type to deserialize needs to be allocated with a fixedBufferAllocator
pub fn getBytesAs(comptime T: type, data: ?*anyopaque, size: usize) T {
    // return std.mem.bytesAsSlice(T, getBytes(data.?, size))[0];
    const serialized_data = getBytes(data.?, size);

    var fbr = std.io.fixedBufferStream(serialized_data);
    fbr.seekTo(0) catch unreachable;

    const reader = fbr.reader();
    return deserialize(reader, T) catch unreachable;
}

///This is any unsafe cast which discards const
pub fn cast(comptime T: type, any_ptr: anytype) T {
    return @intToPtr(T, @ptrToInt(any_ptr));
}

test "simple serialization/deserialization with other data interleved " {
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
    try serialize(writer, Data, data);
    try file.seekTo(0);

    const reader = file.reader();
    const deserialized_data = try deserialize(reader, Data);

    try testing.expectEqualSlices(u8, data.char[0..], deserialized_data.char[0..]);
    try testing.expectEqualSlices(u8, data.ochar[0..], deserialized_data.ochar[0..]);
    try testing.expect(data.int == deserialized_data.int);
}

// Credit to MasterQ32 for https://github.com/ziglibs/s2s
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Public API:

/// Serializes the given `value: T` into the `writer` stream.
/// - `writer` is a instance of `std.io.Writer`
/// - `T` is the type to serialize
/// - `value` is the instance to serialize.
pub fn serialize(writer: anytype, comptime T: type, value: T) @TypeOf(writer).Error!void {
    comptime validateTopLevelType(T);
    const type_hash = comptime computeTypeHash(T);

    try writer.writeAll(&type_hash);
    try serializeRecursive(writer, T, @as(T, value)); // use @as() to coerce to non-tuple type
}

/// Deserializes a value of type `T` from the `reader` stream.
/// - `reader` is a instance of `std.io.Reader`
/// - `T` is the type to deserialize
pub fn deserialize(
    reader: anytype,
    comptime T: type,
) (@TypeOf(reader).Error || error{ DataMismatch, UnexpectedData, EndOfStream })!T {
    comptime validateTopLevelType(T);
    if (comptime requiresAllocationForDeserialize(T))
        @compileError(@typeName(T) ++ " requires allocation to be deserialized. Use deserializeAlloc instead of deserialize!");
    return deserializeInternal(reader, T, null) catch |err| switch (err) {
        error.OutOfMemory => unreachable,
        else => |e| return e,
    };
}

/// Deserializes a value of type `T` from the `reader` stream.
/// - `reader` is a instance of `std.io.Reader`
/// - `T` is the type to deserialize
/// - `allocator` is an allocator require to allocate slices and pointers.
/// Result must be freed by using `free()`.
pub fn deserializeAlloc(
    reader: anytype,
    comptime T: type,
    allocator: std.mem.Allocator,
) (@TypeOf(reader).Error || error{ DataMismatch, UnexpectedData, OutOfMemory, EndOfStream })!T {
    comptime validateTopLevelType(T);
    return try deserializeInternal(reader, T, allocator);
}

/// Releases all memory allocated by `deserializeAlloc`.
/// - `allocator` is the allocator passed to `deserializeAlloc`.
/// - `T` is the type that was passed to `deserializeAlloc`.
/// - `value` is the value that was returned by `deserializeAlloc`.
pub fn free(allocator: std.mem.Allocator, comptime T: type, value: *T) void {
    recursiveFree(allocator, T, value);
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Implementation:

fn serializeRecursive(writer: anytype, comptime T: type, value: T) @TypeOf(writer).Error!void {
    switch (@typeInfo(T)) {
        // Primitive types:
        .Void => {}, // no data
        .Bool => try writer.writeByte(@boolToInt(value)),
        .Float => switch (T) {
            f16 => try writer.writeIntLittle(u16, @bitCast(u16, value)),
            f32 => try writer.writeIntLittle(u32, @bitCast(u32, value)),
            f64 => try writer.writeIntLittle(u64, @bitCast(u64, value)),
            f80 => try writer.writeIntLittle(u80, @bitCast(u80, value)),
            f128 => try writer.writeIntLittle(u128, @bitCast(u128, value)),
            else => unreachable,
        },

        .Int => {
            if (T == usize) {
                try writer.writeIntLittle(u64, value);
            } else {
                try writer.writeIntLittle(T, value);
            }
        },
        .Pointer => |ptr| {
            if (ptr.sentinel != null) @compileError("Sentinels are not supported yet!");
            switch (ptr.size) {
                .One => try serializeRecursive(writer, ptr.child, value.*),
                .Slice => {
                    try writer.writeIntLittle(u64, value.len);
                    for (value) |item| {
                        try serializeRecursive(writer, ptr.child, item);
                    }
                },
                .C => unreachable,
                .Many => unreachable,
            }
        },
        .Array => |arr| {
            if (arr.sentinel != null) @compileError("Sentinels are not supported yet!");
            for (value) |item| {
                try serializeRecursive(writer, arr.child, item);
            }
        },
        .Struct => |str| {
            // we can safely ignore the struct layout here as we will serialize the data by field order,
            // instead of memory representation

            inline for (str.fields) |fld| {
                try serializeRecursive(writer, fld.field_type, @field(value, fld.name));
            }
        },
        .Optional => |opt| {
            if (value) |item| {
                try writer.writeIntLittle(u8, 1);
                try serializeRecursive(writer, opt.child, item);
            } else {
                try writer.writeIntLittle(u8, 0);
            }
        },
        .ErrorUnion => |eu| {
            if (value) |item| {
                try writer.writeIntLittle(u8, 1);
                try serializeRecursive(writer, eu.payload, item);
            } else |item| {
                try writer.writeIntLittle(u8, 0);
                try serializeRecursive(writer, eu.error_set, item);
            }
        },
        .ErrorSet => {
            // Error unions are serialized by "index of sorted name", so we
            // hash all names in the right order
            const names = getSortedErrorNames(T);

            const index = for (names) |name, i| {
                if (std.mem.eql(u8, name, @errorName(value)))
                    break @intCast(u16, i);
            } else unreachable;

            try writer.writeIntLittle(u16, index);
        },
        .Enum => |list| {
            const Tag = if (list.tag_type == usize) u64 else list.tag_type;
            try writer.writeIntLittle(Tag, @enumToInt(value));
        },
        .Union => |un| {
            const Tag = un.tag_type orelse @compileError("Untagged unions are not supported!");

            const active_tag = std.meta.activeTag(value);

            try serializeRecursive(writer, Tag, active_tag);

            inline for (std.meta.fields(T)) |fld| {
                if (@field(Tag, fld.name) == active_tag) {
                    try serializeRecursive(writer, fld.field_type, @field(value, fld.name));
                }
            }
        },
        .Vector => |vec| {
            var array: [vec.len]vec.child = value;
            try serializeRecursive(writer, @TypeOf(array), array);
        },

        // Unsupported types:
        .NoReturn,
        .Type,
        .ComptimeFloat,
        .ComptimeInt,
        .Undefined,
        .Null,
        .Fn,
        .BoundFn,
        .Opaque,
        .Frame,
        .AnyFrame,
        .EnumLiteral,
        => unreachable,
    }
}

fn deserializeInternal(
    reader: anytype,
    comptime T: type,
    allocator: ?std.mem.Allocator,
) (@TypeOf(reader).Error || error{ DataMismatch, UnexpectedData, OutOfMemory, EndOfStream })!T {
    const type_hash = comptime computeTypeHash(T);

    var ref_hash: [type_hash.len]u8 = undefined;
    try reader.readNoEof(&ref_hash);

    if (!std.mem.eql(u8, &type_hash, &ref_hash))
        return error.DataMismatch;

    var result: T = undefined;
    try recursiveDeserialize(reader, T, allocator, &result);
    return result;
}

fn readIntLittleAny(reader: anytype, comptime T: type) !T {
    const BiggerInt = std.meta.Int(@typeInfo(T).Int.signedness, 8 * @as(usize, ((@bitSizeOf(T) + 7)) / 8));
    return @truncate(T, try reader.readIntLittle(BiggerInt));
}

fn recursiveDeserialize(
    reader: anytype,
    comptime T: type,
    allocator: ?std.mem.Allocator,
    target: *T,
) (@TypeOf(reader).Error || error{ UnexpectedData, OutOfMemory, EndOfStream })!void {
    switch (@typeInfo(T)) {
        // Primitive types:
        .Void => target.* = {},
        .Bool => target.* = (try reader.readByte()) != 0,
        .Float => target.* = @bitCast(T, switch (T) {
            f16 => try reader.readIntLittle(u16),
            f32 => try reader.readIntLittle(u32),
            f64 => try reader.readIntLittle(u64),
            f80 => try reader.readIntLittle(u80),
            f128 => try reader.readIntLittle(u128),
            else => unreachable,
        }),

        .Int => target.* = if (T == usize)
            std.math.cast(usize, try reader.readIntLittle(u64)) catch return error.UnexpectedData
        else
            try readIntLittleAny(reader, T),

        .Pointer => |ptr| {
            if (ptr.sentinel != null) @compileError("Sentinels are not supported yet!");
            switch (ptr.size) {
                .One => {
                    const pointer = try allocator.?.create(ptr.child);
                    errdefer allocator.?.destroy(pointer);

                    try recursiveDeserialize(reader, ptr.child, allocator, pointer);

                    target.* = pointer;
                },
                .Slice => {
                    const length = std.math.cast(usize, try reader.readIntLittle(u64)) catch return error.UnexpectedData;

                    const slice = try allocator.?.alloc(ptr.child, length);
                    errdefer allocator.?.free(slice);

                    for (slice) |*item| {
                        try recursiveDeserialize(reader, ptr.child, allocator, item);
                    }

                    target.* = slice;
                },
                .C => unreachable,
                .Many => unreachable,
            }
        },
        .Array => |arr| {
            for (target.*) |*item| {
                try recursiveDeserialize(reader, arr.child, allocator, item);
            }
        },
        .Struct => |str| {
            // we can safely ignore the struct layout here as we will serialize the data by field order,
            // instead of memory representation

            inline for (str.fields) |fld| {
                try recursiveDeserialize(reader, fld.field_type, allocator, &@field(target.*, fld.name));
            }
        },
        .Optional => |opt| {
            const is_set = try reader.readIntLittle(u8);

            if (is_set != 0) {
                target.* = @as(opt.child, undefined);
                try recursiveDeserialize(reader, opt.child, allocator, &target.*.?);
            } else {
                target.* = null;
            }
        },
        .ErrorUnion => |eu| {
            const is_value = try reader.readIntLittle(u8);
            if (is_value != 0) {
                var value: eu.payload = undefined;
                try recursiveDeserialize(reader, eu.payload, allocator, &value);
                target.* = value;
            } else {
                var err: eu.error_set = undefined;
                try recursiveDeserialize(reader, eu.error_set, allocator, &err);
                target.* = err;
            }
        },
        .ErrorSet => {
            // Error unions are serialized by "index of sorted name", so we
            // hash all names in the right order
            const names = comptime getSortedErrorNames(T);
            const index = try reader.readIntLittle(u16);

            inline for (names) |name, i| {
                if (i == index) {
                    target.* = @field(T, name);
                    return;
                }
            }
            return error.UnexpectedData;
        },
        .Enum => |list| {
            const Tag = if (list.tag_type == usize) u64 else list.tag_type;
            const tag_value = try readIntLittleAny(reader, Tag);
            if (list.is_exhaustive) {
                target.* = std.meta.intToEnum(T, tag_value) catch return error.UnexpectedData;
            } else {
                target.* = @intToEnum(T, tag_value);
            }
        },
        .Union => |un| {
            const Tag = un.tag_type orelse @compileError("Untagged unions are not supported!");

            var active_tag: Tag = undefined;
            try recursiveDeserialize(reader, Tag, allocator, &active_tag);

            inline for (std.meta.fields(T)) |fld| {
                if (@field(Tag, fld.name) == active_tag) {
                    var union_value: fld.field_type = undefined;
                    try recursiveDeserialize(reader, fld.field_type, allocator, &union_value);
                    target.* = @unionInit(T, fld.name, union_value);
                    return;
                }
            }

            return error.UnexpectedData;
        },
        .Vector => |vec| {
            var array: [vec.len]vec.child = undefined;
            try recursiveDeserialize(reader, @TypeOf(array), allocator, &array);
            target.* = array;
        },

        // Unsupported types:
        .NoReturn,
        .Type,
        .ComptimeFloat,
        .ComptimeInt,
        .Undefined,
        .Null,
        .Fn,
        .BoundFn,
        .Opaque,
        .Frame,
        .AnyFrame,
        .EnumLiteral,
        => unreachable,
    }
}

fn makeMutableSlice(comptime T: type, slice: []const T) []T {
    return @intToPtr([*]T, @ptrToInt(slice.ptr))[0..slice.len];
}

fn makeMutablePtr(comptime T: type, ptr: *const T) *T {
    return @intToPtr(*T, @ptrToInt(ptr));
}

fn recursiveFree(allocator: std.mem.Allocator, comptime T: type, value: *T) void {
    switch (@typeInfo(T)) {
        // Non-allocating primitives:
        .Void, .Bool, .Float, .Int, .ErrorSet, .Enum => {},

        // Composite types:
        .Pointer => |ptr| {
            switch (ptr.size) {
                .One => {
                    const mut_ptr = makeMutablePtr(ptr.child, value.*);
                    recursiveFree(allocator, ptr.child, mut_ptr);
                    allocator.destroy(mut_ptr);
                },
                .Slice => {
                    const mut_slice = makeMutableSlice(ptr.child, value.*);
                    for (mut_slice) |*item| {
                        recursiveFree(allocator, ptr.child, item);
                    }
                    allocator.free(mut_slice);
                },
                .C => unreachable,
                .Many => unreachable,
            }
        },
        .Array => |arr| {
            for (value.*) |*item| {
                recursiveFree(allocator, arr.child, item);
            }
        },
        .Struct => |str| {
            // we can safely ignore the struct layout here as we will serialize the data by field order,
            // instead of memory representation

            inline for (str.fields) |fld| {
                recursiveFree(allocator, fld.field_type, &@field(value.*, fld.name));
            }
        },
        .Optional => |opt| {
            if (value.*) |*item| {
                recursiveFree(allocator, opt.child, item);
            }
        },
        .ErrorUnion => |eu| {
            if (value.*) |*item| {
                recursiveFree(allocator, eu.payload, item);
            } else |_| {
                // errors aren't meant to be freed
            }
        },
        .Union => |un| {
            const Tag = un.tag_type orelse @compileError("Untagged unions are not supported!");

            var active_tag: Tag = value.*;

            inline for (std.meta.fields(T)) |fld| {
                if (@field(Tag, fld.name) == active_tag) {
                    recursiveFree(allocator, fld.field_type, &@field(value.*, fld.name));
                    return;
                }
            }
        },
        .Vector => |vec| {
            var array: [vec.len]vec.child = value.*;
            for (array) |*item| {
                recursiveFree(allocator, vec.child, item);
            }
        },

        // Unsupported types:
        .NoReturn,
        .Type,
        .ComptimeFloat,
        .ComptimeInt,
        .Undefined,
        .Null,
        .Fn,
        .BoundFn,
        .Opaque,
        .Frame,
        .AnyFrame,
        .EnumLiteral,
        => unreachable,
    }
}

/// Returns `true` if `T` requires allocation to be deserialized.
fn requiresAllocationForDeserialize(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .Pointer => true,
        .Struct, .Union => {
            inline for (comptime std.meta.fields(T)) |fld| {
                if (requiresAllocationForDeserialize(fld.field_type))
                    return true;
            }
            return false;
        },
        .ErrorUnion => |eu| return requiresAllocationForDeserialize(eu.payload),
        else => return false,
    }
}

const TypeHashFn = std.hash.Fnv1a_64;

fn intToLittleEndianBytes(val: anytype) [@sizeOf(@TypeOf(val))]u8 {
    var res: [@sizeOf(@TypeOf(val))]u8 = undefined;
    std.mem.writeIntLittle(@TypeOf(val), &res, val);
    return res;
}

/// Computes a unique type hash from `T` to identify deserializing invalid data.
/// Incorporates field order and field type, but not field names, so only checks for structural equivalence.
/// Compile errors on unsupported or comptime types.
fn computeTypeHash(comptime T: type) [8]u8 {
    var hasher = TypeHashFn.init();

    computeTypeHashInternal(&hasher, T);

    return intToLittleEndianBytes(hasher.final());
}

fn getSortedErrorNames(comptime T: type) []const []const u8 {
    comptime {
        const error_set = @typeInfo(T).ErrorSet orelse @compileError("Cannot serialize anyerror");

        var sorted_names: [error_set.len][]const u8 = undefined;
        for (error_set) |err, i| {
            sorted_names[i] = err.name;
        }

        std.sort.sort([]const u8, &sorted_names, {}, struct {
            fn order(ctx: void, lhs: []const u8, rhs: []const u8) bool {
                _ = ctx;
                return (std.mem.order(u8, lhs, rhs) == .lt);
            }
        }.order);
        return &sorted_names;
    }
}

fn getSortedEnumNames(comptime T: type) []const []const u8 {
    comptime {
        const type_info = @typeInfo(T).Enum;
        if (type_info.layout != .Auto) @compileError("Only automatically tagged enums require sorting!");

        var sorted_names: [type_info.fields.len][]const u8 = undefined;
        for (type_info.fields) |err, i| {
            sorted_names[i] = err.name;
        }

        std.sort.sort([]const u8, &sorted_names, {}, struct {
            fn order(ctx: void, lhs: []const u8, rhs: []const u8) bool {
                _ = ctx;
                return (std.mem.order(u8, lhs, rhs) == .lt);
            }
        }.order);
        return &sorted_names;
    }
}

fn computeTypeHashInternal(hasher: *TypeHashFn, comptime T: type) void {
    switch (@typeInfo(T)) {
        // Primitive types:
        .Void,
        .Bool,
        .Float,
        => hasher.update(@typeName(T)),

        .Int => {
            if (T == usize) {
                // special case: usize can differ between platforms, this
                // format uses u64 internally.
                hasher.update(@typeName(u64));
            } else {
                hasher.update(@typeName(T));
            }
        },
        .Pointer => |ptr| {
            if (ptr.is_volatile) @compileError("Serializing volatile pointers is most likely a mistake.");
            if (ptr.sentinel != null) @compileError("Sentinels are not supported yet!");
            switch (ptr.size) {
                .One => {
                    hasher.update("pointer");
                    computeTypeHashInternal(hasher, ptr.child);
                },
                .Slice => {
                    hasher.update("slice");
                    computeTypeHashInternal(hasher, ptr.child);
                },
                .C => @compileError("C-pointers are not supported"),
                .Many => @compileError("Many-pointers are not supported"),
            }
        },
        .Array => |arr| {
            hasher.update(&intToLittleEndianBytes(@as(u64, arr.len)));
            computeTypeHashInternal(hasher, arr.child);
            if (arr.sentinel != null) @compileError("Sentinels are not supported yet!");
        },
        .Struct => |str| {
            // we can safely ignore the struct layout here as we will serialize the data by field order,
            // instead of memory representation

            // add some generic marker to the hash so emtpy structs get
            // added as information
            hasher.update("struct");

            for (str.fields) |fld| {
                if (fld.is_comptime) @compileError("comptime fields are not supported.");
                computeTypeHashInternal(hasher, fld.field_type);
            }
        },
        .Optional => |opt| {
            hasher.update("optional");
            computeTypeHashInternal(hasher, opt.child);
        },
        .ErrorUnion => |eu| {
            hasher.update("error union");
            computeTypeHashInternal(hasher, eu.error_set);
            computeTypeHashInternal(hasher, eu.payload);
        },
        .ErrorSet => {
            // Error unions are serialized by "index of sorted name", so we
            // hash all names in the right order

            hasher.update("error set");
            const names = getSortedErrorNames(T);
            for (names) |name| {
                hasher.update(name);
            }
        },
        .Enum => |list| {
            const Tag = if (list.tag_type == usize)
                u64
            else if (list.tag_type == isize)
                i64
            else
                list.tag_type;
            if (list.is_exhaustive) {
                // Exhaustive enums only allow certain values, so we
                // tag them via the value type
                hasher.update("enum.exhaustive");
                computeTypeHashInternal(hasher, Tag);
                const names = getSortedEnumNames(T);
                inline for (names) |name| {
                    hasher.update(name);
                    hasher.update(&intToLittleEndianBytes(@as(Tag, @enumToInt(@field(T, name)))));
                }
            } else {
                // Non-exhaustive enums are basically integers. Treat them as such.
                hasher.update("enum.non-exhaustive");
                computeTypeHashInternal(hasher, Tag);
            }
        },
        .Union => |un| {
            const tag = un.tag_type orelse @compileError("Untagged unions are not supported!");
            hasher.update("union");
            computeTypeHashInternal(hasher, tag);
            for (un.fields) |fld| {
                computeTypeHashInternal(hasher, fld.field_type);
            }
        },
        .Vector => |vec| {
            hasher.update("vector");
            hasher.update(&intToLittleEndianBytes(@as(u64, vec.len)));
            computeTypeHashInternal(hasher, vec.child);
        },

        // Unsupported types:
        .NoReturn,
        .Type,
        .ComptimeFloat,
        .ComptimeInt,
        .Undefined,
        .Null,
        .Fn,
        .BoundFn,
        .Opaque,
        .Frame,
        .AnyFrame,
        .EnumLiteral,
        => @compileError("Unsupported type " ++ @typeName(T)),
    }
}

fn validateTopLevelType(comptime T: type) void {
    switch (@typeInfo(T)) {

        // Unsupported top level types:
        .ErrorSet,
        .ErrorUnion,
        => @compileError("Unsupported top level type " ++ @typeName(T) ++ ". Wrap into struct to serialize these."),

        else => {},
    }
}

fn testSameHash(comptime T1: type, comptime T2: type) void {
    const hash_1 = comptime computeTypeHash(T1);
    const hash_2 = comptime computeTypeHash(T2);
    if (comptime !std.mem.eql(u8, &hash_1, &hash_2))
        @compileError("The computed hash for " ++ @typeName(T1) ++ " and " ++ @typeName(T2) ++ " does not match.");
}

test "type hasher basics" {
    testSameHash(void, void);
    testSameHash(bool, bool);
    testSameHash(u1, u1);
    testSameHash(u32, u32);
    testSameHash(f32, f32);
    testSameHash(f64, f64);
    testSameHash(std.meta.Vector(4, u32), std.meta.Vector(4, u32));
    testSameHash(usize, u64);
    testSameHash([]const u8, []const u8);
    testSameHash([]const u8, []u8);
    testSameHash([]const u8, []u8);
    testSameHash(?*struct { a: f32, b: u16 }, ?*const struct { hello: f32, lol: u16 });
    testSameHash(enum { a, b, c }, enum { a, b, c });
    testSameHash(enum(u8) { a, b, c }, enum(u8) { a, b, c });
    testSameHash(enum(u8) { a, b, c, _ }, enum(u8) { c, b, a, _ });
    testSameHash(enum(u8) { a = 1, b = 6, c = 9 }, enum(u8) { a = 1, b = 6, c = 9 });
    testSameHash(enum(usize) { a, b, c }, enum(u64) { a, b, c });
    testSameHash(enum(isize) { a, b, c }, enum(i64) { a, b, c });
    testSameHash([5]std.meta.Vector(4, u32), [5]std.meta.Vector(4, u32));

    testSameHash(union(enum) { a: u32, b: f32 }, union(enum) { a: u32, b: f32 });

    testSameHash(error{ Foo, Bar }, error{ Foo, Bar });
    testSameHash(error{ Foo, Bar }, error{ Bar, Foo });
    testSameHash(error{ Foo, Bar }!void, error{ Bar, Foo }!void);
}

fn testSerialize(comptime T: type, value: T) !void {
    var data = std.ArrayList(u8).init(std.testing.allocator);
    defer data.deinit();

    try serialize(data.writer(), T, value);
}

test "serialize basics" {
    try testSerialize(void, {});
    try testSerialize(bool, false);
    try testSerialize(bool, true);
    try testSerialize(u1, 0);
    try testSerialize(u1, 1);
    try testSerialize(u8, 0xFF);
    try testSerialize(u32, 0xDEADBEEF);
    try testSerialize(usize, 0xDEADBEEF);

    try testSerialize(f16, std.math.pi);
    try testSerialize(f32, std.math.pi);
    try testSerialize(f64, std.math.pi);
    try testSerialize(f80, std.math.pi);
    try testSerialize(f128, std.math.pi);

    try testSerialize([3]u8, "hi!".*);
    try testSerialize([]const u8, "Hello, World!");
    try testSerialize(*const [3]u8, "foo");

    try testSerialize(enum { a, b, c }, .a);
    try testSerialize(enum { a, b, c }, .b);
    try testSerialize(enum { a, b, c }, .c);

    try testSerialize(enum(u8) { a, b, c }, .a);
    try testSerialize(enum(u8) { a, b, c }, .b);
    try testSerialize(enum(u8) { a, b, c }, .c);

    try testSerialize(enum(isize) { a, b, c }, .a);
    try testSerialize(enum(isize) { a, b, c }, .b);
    try testSerialize(enum(isize) { a, b, c }, .c);

    try testSerialize(enum(usize) { a, b, c }, .a);
    try testSerialize(enum(usize) { a, b, c }, .b);
    try testSerialize(enum(usize) { a, b, c }, .c);

    const TestEnum = enum(u8) { a, b, c, _ };
    try testSerialize(TestEnum, .a);
    try testSerialize(TestEnum, .b);
    try testSerialize(TestEnum, .c);
    try testSerialize(TestEnum, @intToEnum(TestEnum, 0xB1));

    try testSerialize(struct { val: error{ Foo, Bar } }, .{ .val = error.Foo });
    try testSerialize(struct { val: error{ Bar, Foo } }, .{ .val = error.Bar });

    try testSerialize(struct { val: error{ Bar, Foo }!u32 }, .{ .val = error.Bar });
    try testSerialize(struct { val: error{ Bar, Foo }!u32 }, .{ .val = 0xFF });

    try testSerialize(union(enum) { a: f32, b: u32 }, .{ .a = 1.5 });
    try testSerialize(union(enum) { a: f32, b: u32 }, .{ .b = 2.0 });

    try testSerialize(?u32, null);
    try testSerialize(?u32, 143);
}

fn testSerDesAlloc(comptime T: type, value: T) !void {
    var data = std.ArrayList(u8).init(std.testing.allocator);
    defer data.deinit();

    try serialize(data.writer(), T, value);

    var stream = std.io.fixedBufferStream(data.items);

    var deserialized = try deserializeAlloc(stream.reader(), T, std.testing.allocator);
    defer free(std.testing.allocator, T, &deserialized);

    try std.testing.expectEqual(value, deserialized);
}

fn testSerDesPtrContentEquality(comptime T: type, value: T) !void {
    var data = std.ArrayList(u8).init(std.testing.allocator);
    defer data.deinit();

    try serialize(data.writer(), T, value);

    var stream = std.io.fixedBufferStream(data.items);

    var deserialized = try deserializeAlloc(stream.reader(), T, std.testing.allocator);
    defer free(std.testing.allocator, T, &deserialized);

    try std.testing.expectEqual(value.*, deserialized.*);
}

fn testSerDesSliceContentEquality(comptime T: type, value: T) !void {
    var data = std.ArrayList(u8).init(std.testing.allocator);
    defer data.deinit();

    try serialize(data.writer(), T, value);

    var stream = std.io.fixedBufferStream(data.items);

    var deserialized = try deserializeAlloc(stream.reader(), T, std.testing.allocator);
    defer free(std.testing.allocator, T, &deserialized);

    try std.testing.expectEqualSlices(std.meta.Child(T), value, deserialized);
}

test "ser/des" {
    try testSerDesAlloc(void, {});
    try testSerDesAlloc(bool, false);
    try testSerDesAlloc(bool, true);
    try testSerDesAlloc(u1, 0);
    try testSerDesAlloc(u1, 1);
    try testSerDesAlloc(u8, 0xFF);
    try testSerDesAlloc(u32, 0xDEADBEEF);
    try testSerDesAlloc(usize, 0xDEADBEEF);

    try testSerDesAlloc(f16, std.math.pi);
    try testSerDesAlloc(f32, std.math.pi);
    try testSerDesAlloc(f64, std.math.pi);
    try testSerDesAlloc(f80, std.math.pi);
    try testSerDesAlloc(f128, std.math.pi);

    try testSerDesAlloc([3]u8, "hi!".*);
    try testSerDesSliceContentEquality([]const u8, "Hello, World!");
    try testSerDesPtrContentEquality(*const [3]u8, "foo");

    try testSerDesAlloc(enum { a, b, c }, .a);
    try testSerDesAlloc(enum { a, b, c }, .b);
    try testSerDesAlloc(enum { a, b, c }, .c);

    try testSerDesAlloc(enum(u8) { a, b, c }, .a);
    try testSerDesAlloc(enum(u8) { a, b, c }, .b);
    try testSerDesAlloc(enum(u8) { a, b, c }, .c);

    try testSerDesAlloc(enum(usize) { a, b, c }, .a);
    try testSerDesAlloc(enum(usize) { a, b, c }, .b);
    try testSerDesAlloc(enum(usize) { a, b, c }, .c);

    try testSerDesAlloc(enum(isize) { a, b, c }, .a);
    try testSerDesAlloc(enum(isize) { a, b, c }, .b);
    try testSerDesAlloc(enum(isize) { a, b, c }, .c);

    const TestEnum = enum(u8) { a, b, c, _ };
    try testSerDesAlloc(TestEnum, .a);
    try testSerDesAlloc(TestEnum, .b);
    try testSerDesAlloc(TestEnum, .c);
    try testSerDesAlloc(TestEnum, @intToEnum(TestEnum, 0xB1));

    try testSerDesAlloc(struct { val: error{ Foo, Bar } }, .{ .val = error.Foo });
    try testSerDesAlloc(struct { val: error{ Bar, Foo } }, .{ .val = error.Bar });

    try testSerDesAlloc(struct { val: error{ Bar, Foo }!u32 }, .{ .val = error.Bar });
    try testSerDesAlloc(struct { val: error{ Bar, Foo }!u32 }, .{ .val = 0xFF });

    try testSerDesAlloc(union(enum) { a: f32, b: u32 }, .{ .a = 1.5 });
    try testSerDesAlloc(union(enum) { a: f32, b: u32 }, .{ .b = 2.0 });

    try testSerDesAlloc(?u32, null);
    try testSerDesAlloc(?u32, 143);
}

// test "simple serialization/deserialization with other data interleved " {
//     const Data = packed struct {
//         char: [21]u8 = "is my data still here".*,
//         int: u8 = 254,
//         ochar: [21]u8 = "is my data still here".*,
//     };
//     const data = Data{};
//     // var serialized_data: [@sizeOf(Data)]u8 = undefined;
//     // simpleSerialize(data, &serialized_data);
//
//     const SerializedData = try std.fs.cwd().createFile("serialized-1.data", .{ .read = true });
//     defer SerializedData.close();
//     const writer = SerializedData.writer();
//     try writer.writeStruct(data);
//     // try writer.writeAll(serialized_data[0..]);
//     try SerializedData.seekTo(0);
//
//     // var deserialized_buf: [@sizeOf(Data)]u8 = undefined;
//     const reader = SerializedData.reader();
//     const deserialized_data = try reader.readStruct(Data);
//     // const deserialized_data = simpleDeserialize(Data, serialized_data);
//     // try testing.expectEqualSlices(u8, serialized_data[0..], deserialized_buf[0..]);
//     std.debug.print("\ndata {}\ndserialized data {}\n", .{ data, deserialized_data });
//
//     // try testing.expectEqualSlices(u8, data.char[0..], deserialized_data.char[0..]);
//     // try testing.expectEqualSlices(u8, data.ochar[0..], deserialized_data.ochar[0..]);
//     // try testing.expect(std.mem.eql(u8, data.char[0..], deserialized_data.char[0..]));
//     // try testing.expect(std.mem.eql(u8, @ptrCast([*][]u8, &data)[0], @ptrCast([*][]u8, &deserialized_data)));
//     // std.debug.print("\nchar is {s}\n", .{deserialized_data.char[0..]});
//     try testing.expect(data.int == deserialized_data.int);
// }

// //TODO: test output of serialized [N]T output with []T output
// //when serializing slice don't forget to set the len field also
// pub fn sliceSerialize(type_to_serialize: anytype, serialized_buf: *[@sizeOf(@TypeOf(type_to_serialize))]u8) void {
//     const @"type" = @TypeOf(type_to_serialize);
//     const fields = comptime std.meta.fields(@"type");
//     debug("size of {} is {}", .{ @"type", @sizeOf(@"type") });
//     var size: usize = 0;
//     const manyptr_to_serialize = @ptrCast([*]const u8, &type_to_serialize);
//     //TODO: use std.mem.alignInBytes for aligning fields in struct during deserialization
//     //take pointers to fields and ptrCast to bytes for modification
//     inline for (fields) |field| {
//         if (std.meta.trait.isSlice(field.field_type)) {
//             const size_of_slice = @sizeOf(field.field_type);
//             debug("The field {s} is a slice", .{field.name});
//             debug("size of {s} slice is {}", .{ field.name, size_of_slice });
//             debug("{s} has {s}", .{ field.name, field });
//             const slice = @bitCast([]const u8, manyptr_to_serialize[size .. size + size_of_slice]);
//             debug("slice ptr contains {s}", .{slice});
//             @memcpy(serialized_buf[size..].ptr, slice.ptr, slice.len);
//             size += size_of_slice;
//         } else {
//             const type_size = comptime blk: {
//                 const size_of_type = @sizeOf(field.field_type);
//                 if (size_of_type < 8) {
//                     const new_size = @sizeOf(field.field_type) * 8;
//                     //multiple size by 8 to properly align
//                     // debug("size was initially {} but is now ", .{ size_of_type, new_size });
//                     break :blk new_size;
//                 } else break :blk size_of_type;
//             };
//             //since size might have been modified
//             const actual_size = @sizeOf(field.field_type);
//             debug("The field {s} is not a slice", .{field.name});
//             debug("size of {s} is {}", .{ field.name, actual_size });
//             debug("{s} has {s}", .{ field.name, field });
//             @memcpy(serialized_buf[size..].ptr, manyptr_to_serialize[size .. size + actual_size].ptr, type_size);
//             size += type_size;
//         }
//         debug("{} bytes copied", .{size});
//     }
//     //     // @memcpy(serialized_buf, @ptrCast([*]const u8, &type_to_serialize), @sizeOf(@TypeOf(type_to_serialize)));
// }
//
//  pub fn deserialize(comptime T: type, serialized_t: [@sizeOf(T)]u8) T {
//      return @bitCast(T, serialized_t);
//  var des_type: T = undefined;
//  const fields = std.meta.fields(T);
//  var size: usize = 0;
//  inline for (fields) |field| {
//      if (std.meta.trait.isSlice(field.field_type)) {
//          const size_of_slice = @sizeOf(field.field_type);
//          @memcpy(cast([*]u8, des_type.character.ptr), serialized_t[size .. size + size_of_slice].ptr, size_of_slice);
//          size += size_of_slice;
//      } else {
//          const type_size = comptime blk: {
//              const size_of_type = @sizeOf(field.field_type);
//              if (size_of_type < 8) {
//                  const new_size = @sizeOf(field.field_type) * 8;
//                  break :blk new_size;
//              } else break :blk size_of_type;
//          };
//          //since size might have been modified
//          const actual_size = @sizeOf(field.field_type);
//          @memcpy(des_type.integer, serialized_t[size .. size + actual_size].ptr, actual_size);
//          size += type_size;
//      }
//  }
//  return des_type;
//  }
//
