//! `Map` and `Set`. Keys are compared with SameValueZero, and both keep their entries in the
//! order they were added.

const std = @import("std");
const native = @import("native.zig");
const value = @import("../value.zig");
const iterators = @import("iterators.zig");
const Interpreter = native.Interpreter;
const Value = native.Value;
const Error = native.Error;
const Collection = value.Collection;
const arg = native.arg;

pub const map_methods: native.Table = .initComptime(.{
    .{ "clear", native.function("clear", 0, clear) },
    .{ "delete", native.function("delete", 1, delete) },
    .{ "forEach", native.function("forEach", 1, forEach) },
    .{ "get", native.function("get", 1, get) },
    .{ "has", native.function("has", 1, has) },
    .{ "set", native.function("set", 2, set) },
    .{ "entries", native.function("entries", 0, entries) },
    .{ "keys", native.function("keys", 0, keys) },
    .{ "values", native.function("values", 0, values) },
    .{ "[Symbol.iterator]", native.function("entries", 0, entries) },
});

pub const set_methods: native.Table = .initComptime(.{
    .{ "add", native.function("add", 1, add) },
    .{ "clear", native.function("clear", 0, clear) },
    .{ "delete", native.function("delete", 1, delete) },
    .{ "forEach", native.function("forEach", 1, forEach) },
    .{ "has", native.function("has", 1, has) },
    .{ "entries", native.function("entries", 0, entries) },
    // A set's keys are its values.
    .{ "keys", native.function("values", 0, values) },
    .{ "values", native.function("values", 0, values) },
    .{ "[Symbol.iterator]", native.function("values", 0, values) },
});

const no_statics: native.Table = .initComptime(.{});

pub const map_constructor = native.constructor("Map", 0, null, newMap, &no_statics, false);
pub const set_constructor = native.constructor("Set", 0, null, newSet, &no_statics, false);

fn create(it: *Interpreter, comptime kind: enum { map, set }) Error!struct { *value.Object, *Collection } {
    const c = try it.arena.create(Collection);
    c.* = .{};
    const o = try it.arena.create(value.Object);
    o.* = switch (kind) {
        .map => .{ .internal = .{ .map = c }, .methods = &map_methods },
        .set => .{ .internal = .{ .set = c }, .methods = &set_methods },
    };
    return .{ o, c };
}

/// `new Map(entries)`.
fn newMap(it: *Interpreter, _: Value, args: []const Value) Error!Value {
    const o, const c = try create(it, .map);
    const source = arg(args, 0);
    if (source != .undefined and source != .null) {
        var iteration = try native.iterate(it, source);
        while (try iteration.next(it)) |entry| {
            switch (entry) {
                .object, .array => {},
                else => return it.throw(.TypeError, "Iterator value {s} is not an entry object", .{try entry.toString(it.arena)}),
            }
            try c.set(it.arena, try it.getProperty(entry, native.number(0)), try it.getProperty(entry, native.number(1)));
        }
    }
    return .{ .object = o };
}

/// `new Set(values)`.
fn newSet(it: *Interpreter, _: Value, args: []const Value) Error!Value {
    const o, const c = try create(it, .set);
    const source = arg(args, 0);
    if (source != .undefined and source != .null) {
        var iteration = try native.iterate(it, source);
        while (try iteration.next(it)) |item| {
            try c.add(it.arena, item);
        }
    }
    return .{ .object = o };
}

/// What a method's `this` holds, which has to be a map (or a set, for a set's methods).
fn collection(it: *Interpreter, this: Value) Error!*Collection {
    if (this == .object) {
        switch (this.object.internal) {
            .map, .set => |c| return c,
            else => {},
        }
    }
    return it.throw(.TypeError, "Method called on incompatible receiver {s}", .{try it.describe(this)});
}

fn get(it: *Interpreter, this: Value, args: []const Value) Error!Value {
    return (try collection(it, this)).get(arg(args, 0)) orelse .undefined;
}

fn has(it: *Interpreter, this: Value, args: []const Value) Error!Value {
    return .{ .boolean = (try collection(it, this)).has(arg(args, 0)) };
}

fn set(it: *Interpreter, this: Value, args: []const Value) Error!Value {
    try (try collection(it, this)).set(it.arena, arg(args, 0), arg(args, 1));
    return this;
}

fn add(it: *Interpreter, this: Value, args: []const Value) Error!Value {
    try (try collection(it, this)).add(it.arena, arg(args, 0));
    return this;
}

fn delete(it: *Interpreter, this: Value, args: []const Value) Error!Value {
    return .{ .boolean = (try collection(it, this)).delete(arg(args, 0)) };
}

fn clear(it: *Interpreter, this: Value, _: []const Value) Error!Value {
    (try collection(it, this)).clear();
    return .undefined;
}

/// Calls the callback with each value, key and the collection, including entries added along
/// the way, but not ones deleted before they're reached.
fn forEach(it: *Interpreter, this: Value, args: []const Value) Error!Value {
    const c = try collection(it, this);
    const callback = try native.callable(it, arg(args, 0));
    var i: usize = 0;
    while (i < c.entries.items.len) : (i += 1) {
        const e = c.entries.items[i];
        if (e.removed) {
            continue;
        }
        _ = try it.invoke(callback, arg(args, 1), &.{ e.value, e.key, this });
    }
    return .undefined;
}

fn iterate(it: *Interpreter, this: Value, kind: value.Iterator.Kind) Error!Value {
    const c = try collection(it, this);
    const source: value.Iterator.Source = if (this.object.internal == .map) .{ .map = c } else .{ .set = c };
    return iterators.toValue(it, try iterators.create(it, source, kind));
}

fn entries(it: *Interpreter, this: Value, _: []const Value) Error!Value {
    return iterate(it, this, .entries);
}

fn keys(it: *Interpreter, this: Value, _: []const Value) Error!Value {
    return iterate(it, this, .keys);
}

fn values(it: *Interpreter, this: Value, _: []const Value) Error!Value {
    return iterate(it, this, .values);
}
