//! `Object` and `Object.prototype`.

const std = @import("std");
const native = @import("native.zig");
const value = @import("../value.zig");
const strings = @import("strings.zig");
const Interpreter = native.Interpreter;
const Value = native.Value;
const Error = native.Error;
const arg = native.arg;

pub const prototype: native.Table = .initComptime(.{
    .{ "toString", native.function("toString", 0, toString) },
    .{ "valueOf", native.function("valueOf", 0, valueOf) },
    .{ "hasOwnProperty", native.function("hasOwnProperty", 1, hasOwnProperty) },
});

pub const statics: native.Table = .initComptime(.{
    .{ "keys", native.function("keys", 1, keys) },
    .{ "values", native.function("values", 1, values) },
    .{ "entries", native.function("entries", 1, entries) },
    .{ "assign", native.function("assign", 2, assign) },
    .{ "freeze", native.function("freeze", 1, freeze) },
    .{ "isFrozen", native.function("isFrozen", 1, isFrozen) },
    .{ "fromEntries", native.function("fromEntries", 1, fromEntries) },
    .{ "hasOwn", native.function("hasOwn", 2, hasOwn) },
});

pub const constructor = native.constructor("Object", 1, null, null, &statics, true);

/// ToObject (§7.1.18), which only fails for `null` and `undefined`.
fn checkObject(it: *Interpreter, v: Value) Error!void {
    if (v == .undefined or v == .null) {
        return it.throw(.TypeError, "Cannot convert undefined or null to object", .{});
    }
}

/// The names of a value's own enumerable properties, as `Object.keys` gives them.
fn ownKeys(it: *Interpreter, v: Value) Error![]const []const u8 {
    try checkObject(it, v);
    return switch (v) {
        .object, .array, .string => it.ownKeys(v),
        else => &.{},
    };
}

fn keys(it: *Interpreter, _: Value, args: []const Value) Error!Value {
    const names = try ownKeys(it, arg(args, 0));
    const list = try it.arena.alloc(Value, names.len);
    for (names, list) |name, *item| {
        item.* = .{ .string = name };
    }
    return it.newArray(list);
}

fn values(it: *Interpreter, _: Value, args: []const Value) Error!Value {
    const o = arg(args, 0);
    const names = try ownKeys(it, o);
    const list = try it.arena.alloc(Value, names.len);
    for (names, list) |name, *item| {
        item.* = try it.getNamed(o, name);
    }
    return it.newArray(list);
}

fn entries(it: *Interpreter, _: Value, args: []const Value) Error!Value {
    const o = arg(args, 0);
    const names = try ownKeys(it, o);
    const list = try it.arena.alloc(Value, names.len);
    for (names, list) |name, *item| {
        item.* = try it.newArray(&.{ .{ .string = name }, try it.getNamed(o, name) });
    }
    return it.newArray(list);
}

fn assign(it: *Interpreter, _: Value, args: []const Value) Error!Value {
    const target = arg(args, 0);
    try checkObject(it, target);
    if (target != .object and target != .array) {
        return it.throw(.Unsupported, "Assigning properties to a {s} is not supported yet.", .{target.typeOf()});
    }
    for (args[1..]) |source| {
        if (source == .undefined or source == .null) {
            continue;
        }
        for (try ownKeys(it, source)) |name| {
            try checkWritable(it, target, name);
            try it.setProperty(target, .{ .string = name }, try it.getNamed(source, name));
        }
    }
    return target;
}

/// `Object.assign` throws where a plain assignment to a frozen object would silently do nothing.
fn checkWritable(it: *Interpreter, target: Value, name: []const u8) Error!void {
    const exists, const description = switch (target) {
        .object => |o| if (!o.frozen) return else .{ o.properties.contains(name), "#<Object>" },
        .array => |a| if (!a.frozen) return else .{
            std.mem.eql(u8, name, "length") or if (value.arrayIndex(name)) |i| i < a.items().len else false,
            "[object Array]",
        },
        else => return,
    };
    if (exists) {
        return it.throw(.TypeError, "Cannot assign to read only property '{s}' of object '{s}'", .{ name, description });
    }
    return it.throw(.TypeError, "Cannot add property {s}, object is not extensible", .{name});
}

fn freeze(_: *Interpreter, _: Value, args: []const Value) Error!Value {
    const o = arg(args, 0);
    switch (o) {
        .object => |x| x.frozen = true,
        .array => |x| x.frozen = true,
        else => {},
    }
    return o;
}

fn isFrozen(_: *Interpreter, _: Value, args: []const Value) Error!Value {
    return .{ .boolean = switch (arg(args, 0)) {
        .object => |x| x.frozen,
        .array => |x| x.frozen,
        .function, .native_function => false,
        else => true,
    } };
}

fn fromEntries(it: *Interpreter, _: Value, args: []const Value) Error!Value {
    const o = try it.arena.create(value.Object);
    o.* = .{};
    var iteration = try native.iterate(it, arg(args, 0));
    while (try iteration.next(it)) |entry| {
        switch (entry) {
            .object, .array => {},
            else => return it.throw(.TypeError, "Iterator value {s} is not an entry object", .{try entry.toString(it.arena)}),
        }
        const key = try it.propertyKey(try it.getProperty(entry, native.number(0)));
        try o.properties.put(it.arena, key, try it.getProperty(entry, native.number(1)));
    }
    return .{ .object = o };
}

/// Whether `v` has an own property called `name`.
fn hasOwnName(it: *Interpreter, v: Value, name: []const u8) Error!bool {
    return switch (v) {
        .object => |o| o.properties.contains(name),
        .array => |a| std.mem.eql(u8, name, "length") or if (value.arrayIndex(name)) |i| i < a.items().len else false,
        .string => |s| std.mem.eql(u8, name, "length") or if (value.arrayIndex(name)) |i| i < strings.lengthOf(it, s) else false,
        .function, .native_function => std.mem.eql(u8, name, "name") or std.mem.eql(u8, name, "length"),
        .undefined, .null => it.throw(.TypeError, "Cannot convert undefined or null to object", .{}),
        else => false,
    };
}

fn hasOwn(it: *Interpreter, _: Value, args: []const Value) Error!Value {
    const o = arg(args, 0);
    try checkObject(it, o);
    return .{ .boolean = try hasOwnName(it, o, try it.propertyKey(arg(args, 1))) };
}

fn hasOwnProperty(it: *Interpreter, this: Value, args: []const Value) Error!Value {
    return .{ .boolean = try hasOwnName(it, this, try it.propertyKey(arg(args, 0))) };
}

fn toString(_: *Interpreter, this: Value, _: []const Value) Error!Value {
    return .{ .string = switch (this) {
        .undefined => "[object Undefined]",
        .null => "[object Null]",
        .boolean => "[object Boolean]",
        .number => "[object Number]",
        .string => "[object String]",
        .array => "[object Array]",
        .function, .native_function => "[object Function]",
        .object => |o| value.objectString(o),
        .uninitialized => unreachable,
    } };
}

fn valueOf(it: *Interpreter, this: Value, _: []const Value) Error!Value {
    try checkObject(it, this);
    return this;
}
