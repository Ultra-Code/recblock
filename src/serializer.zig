const std = @import("std");
const debug = std.log.debug;

//IDEAS: consider maybe json serialization but prefer binnary serialization
//READ: read into Google Protocol Buffers ,Thrift and Avro in I want to use well established serialization tools

//Serialization takes an in-memory data structure and converts it into a series of bytes that can be stored and transferred.
//Deserialization takes a series of bytes and converts it to an in-memory data structure that can be consumed programmatically.

//TODO: try to implement a way to convert slices into arrays for easy serialization
//IDEAS: 🤔 maybe reify the slice type but with a .field_type of [N]u8 take inspiration from std.meta.Sentinel
//REF: https://stackoverflow.com/questions/15707933/how-to-serialize-a-struct-in-c  , serialization framework https://github.com/getty-zig/getty
//REF: https://stackoverflow.com/questions/9778806/serializing-a-class-with-a-pointer-in-c https://www.boost.org/doc/libs/1_78_0/libs/serialization/doc/tutorial.html#pointers
//REF: https://stackoverflow.com/questions/523872/how-do-you-serialize-an-object-in-c/ https://accu.org/journals/overload/24/136/ignatchenko_2317/

pub fn serialize(type_to_serialize: anytype, serialized_buf: *[@sizeOf(@TypeOf(type_to_serialize))]u8) void {
    @memcpy(serialized_buf, @ptrCast([*]const u8, &type_to_serialize), @sizeOf(@TypeOf(type_to_serialize)));
}

pub fn deserialize(comptime T: type, serialized_t: [@sizeOf(T)]u8) T {
    return @bitCast(T, serialized_t);
}

// fn serialize(type_to_serialize: anytype, serialized_buf: *[@sizeOf(@TypeOf(type_to_serialize))]u8) void {
//     const @"type" = @TypeOf(type_to_serialize);
//     const fields = comptime std.meta.fields(@"type");
//     debug("size of {} is {}", .{ @"type", @sizeOf(@"type") });
//     var size: usize = 0;
//     inline for (fields) |field| {
//         if (std.meta.trait.isSlice(field.field_type)) {
//             debug("The field {s} is a slice, .{field.name});
//             debug("size of {s} slice is {}", .{ field.name, @sizeOf(field.field_type) });
//             size += @sizeOf(field.field_type);
//         }
//         debug("name {s}\n{s}", .{ field.name, field });
//         @memcpy(serialized_buf, @ptrCast([*]const u8, &type_to_serialize), @sizeOf(@TypeOf(type_to_serialize)));
//     }
//     @memcpy(serialized_buf, @ptrCast([*]const u8, &type_to_serialize), @sizeOf(@TypeOf(type_to_serialize)));
// }
// pub fn serialize(type_to_serialize: anytype, serialized_buf: *[@sizeOf(@TypeOf(type_to_serialize))]u8) void {
//     const @"type" = @TypeOf(type_to_serialize);
//     const fields = comptime std.meta.fields(@"type");
//     debug("size of {} is {}", .{ @"type", @sizeOf(@"type") });
//     var size: usize = 0;
//     const manyptr_to_serialize = @ptrCast([*]const u8, &type_to_serialize);
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
//     // @memcpy(serialized_buf, @ptrCast([*]const u8, &type_to_serialize), @sizeOf(@TypeOf(type_to_serialize)));
// }

// pub fn deserialize(comptime T: type, serialized_t: [@sizeOf(T)]u8) T {
//     return @bitCast(T, serialized_t);
// var des_type: T = undefined;
// const fields = std.meta.fields(T);
// var size: usize = 0;
// inline for (fields) |field| {
//     if (std.meta.trait.isSlice(field.field_type)) {
//         const size_of_slice = @sizeOf(field.field_type);
//         @memcpy(cast([*]u8, des_type.character.ptr), serialized_t[size .. size + size_of_slice].ptr, size_of_slice);
//         size += size_of_slice;
//     } else {
//         const type_size = comptime blk: {
//             const size_of_type = @sizeOf(field.field_type);
//             if (size_of_type < 8) {
//                 const new_size = @sizeOf(field.field_type) * 8;
//                 break :blk new_size;
//             } else break :blk size_of_type;
//         };
//         //since size might have been modified
//         const actual_size = @sizeOf(field.field_type);
//         @memcpy(des_type.integer, serialized_t[size .. size + actual_size].ptr, actual_size);
//         size += type_size;
//     }
// }
// return des_type;
// }

pub fn getBytes(data: ?*anyopaque, size: usize) []u8 {
    return @ptrCast([*]u8, data.?)[0..size];
}

pub fn getBytesAs(comptime T: type, data: ?*anyopaque, size: usize) T {
    return std.mem.bytesAsSlice(T, getBytes(data.?, size))[0];
    // var serialized_t: [@sizeOf(T)]u8 = undefined;
    // std.mem.copy(u8, serialized_t[0..], getBytes(data.?, size));
    // return deserialize(T, serialized_t);
}
///This is any unsafe cast which discards const
pub fn cast(comptime T: type, any_ptr: anytype) T {
    return @intToPtr(T, @ptrToInt(any_ptr));
}
// fn typeInfo() void {
//     const Array = struct { len: usize = 10, ptr: [10]u8 = [_]u8{ 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j' } };
//     const Slice = struct { len: usize = 10, ptr: []const u8 = &[_]u8{ 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j' } };
//     const array_info = comptime std.meta.fields(Array);
//     const slice_info = comptime std.meta.fields(Slice);
//
//     debug("Array size is {}", .{@sizeOf(Array)});
//     inline for (array_info) |field| {
//         debug("array info {s}", .{field});
//     }
//     debug("Slice size is {}", .{@sizeOf(Slice)});
//     inline for (slice_info) |field| {
//         debug("slice info {s}", .{field});
//     }
// }

// pub fn testBytification() void {
//     typeInfo();
// const SomeType = struct { integer: usize, character: []const u8 };
// var data = SomeType{ .integer = 7, .character = "seven" };
// const new_data = data.character.ptr;
// const info = comptime @typeInfo(@TypeOf(new_data));
// debug("type info of {}", .{info});
// const Data = struct { data: [7]u8 };
// var data = Data{ .data = [_]u8{ 'i', 'm', 'd', 'a', 't', 'a', 's' } };
// const SomeType = Data;

// var serialized_data: [@sizeOf(SomeType)]u8 = undefined; serialize(data, &serialized_data);
// debug("serialized data is {s}", .{serialized_data[0..]});
// const SerializedSomeType = std.fs.cwd().createFile("serialized-SomeType.data", .{ .read = true }) catch unreachable;
// defer SerializedSomeType.close();
// SerializedSomeType.writeAll(serialized_data[0..]) catch unreachable;
// // data.character = "Eight";
// var deserialize_data: [@sizeOf(SomeType)]u8 = undefined;
// _ = SerializedSomeType.read(&deserialize_data) catch unreachable;
// const deserialize_t = deserialize(SomeType, deserialize_data);
// debug("deserialize_t type is {}", .{deserialize_t});
// debug("deserialize_t type .integer is {} and .character is {s}", .{ deserialize_t.integer, deserialize_t.character });
// debug("deserialize_t type .data is {s}", .{deserialize_t.data});

// const Data = struct {
//     char: []const u8 = "is my data still here",
//     int: u8 = 7,
//     ochar: []const u8 = "is my data still here",
// };
// const data = Data{};
// var serialized_data: [@sizeOf(Data)]u8 = undefined;
// serialize(data, &serialized_data);
// const deserialized_data = deserialize(Data, serialized_data);
// debug("char is {s} and int is {} and ochar is {s}", .{ deserialized_data.char, deserialized_data.int, deserialized_data.ochar });

//Test Serialization
// const txn = db.startTxn(.rw, BLOCK_DB);
// defer txn.commitTxns();

// txn.put("key", "value") catch unreachable;
// debug("key has data {s}", .{txn.get("key") catch unreachable});
// const Data = struct {
//     data: []const u8 = "is my data still here",
//     // int: u8 = 7,
//     // ochar: []const u8 = "is my data still here",
// };
// const data = Data{};
// var serialized_data: [@sizeOf(Data)]u8 = undefined;
// serialize(data, &serialized_data);
// const deserialized_data = deserialize(Data, serialized_data);
// debug("char is {s} and int is {} and ochar is {s}", .{ deserialized_data.char, deserialized_data.int, deserialized_data.ochar });

// const Data = struct { data: u8 };
// var data = Data{ .data = 7 };
// txn.update("data_key", data) catch unreachable;
// const gotten_data = txn.getAs(Data, "data_key") catch unreachable;
// debug("data_key has data {}", .{gotten_data});
// debug("data_key has data.data {s}", .{gotten_data.data});
// const chainstate_db_name = "chainstates";
// }
