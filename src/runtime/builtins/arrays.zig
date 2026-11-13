//! `Array` and `Array.prototype`. Arrays never have holes, so a method that would make one says
//! it's unsupported instead.

const std = @import("std");
const native = @import("native.zig");
const value = @import("../value.zig");
const iterators = @import("iterators.zig");
const Interpreter = native.Interpreter;
const Value = native.Value;
const Error = native.Error;
const Array = value.Array;
const arg = native.arg;

pub const methods: native.Table = .initComptime(.{
    .{ "toString", native.function("toString", 0, toString) },
    .{ "pop", native.function("pop", 0, pop) },
    .{ "push", native.function("push", 1, push) },
    .{ "concat", native.function("concat", 1, concat) },
    .{ "join", native.function("join", 1, join) },
    .{ "reverse", native.function("reverse", 0, reverse) },
    .{ "shift", native.function("shift", 0, shift) },
    .{ "slice", native.function("slice", 2, slice) },
    .{ "sort", native.function("sort", 1, sort) },
    .{ "splice", native.function("splice", 2, splice) },
    .{ "unshift", native.function("unshift", 1, unshift) },
    .{ "indexOf", native.function("indexOf", 1, indexOf) },
    .{ "lastIndexOf", native.function("lastIndexOf", 1, lastIndexOf) },
    .{ "every", native.function("every", 1, every) },
    .{ "some", native.function("some", 1, some) },
    .{ "forEach", native.function("forEach", 1, forEach) },
    .{ "map", native.function("map", 1, map) },
    .{ "filter", native.function("filter", 1, filter) },
    .{ "reduce", native.function("reduce", 1, reduce) },
    .{ "reduceRight", native.function("reduceRight", 1, reduceRight) },
    .{ "find", native.function("find", 1, find) },
    .{ "findIndex", native.function("findIndex", 1, findIndex) },
    .{ "fill", native.function("fill", 1, fill) },
    .{ "includes", native.function("includes", 1, includes) },
    .{ "flat", native.function("flat", 0, flat) },
    .{ "flatMap", native.function("flatMap", 1, flatMap) },
    .{ "at", native.function("at", 1, at) },
    .{ "entries", native.function("entries", 0, entries) },
    .{ "keys", native.function("keys", 0, keys) },
    .{ "values", native.function("values", 0, values) },
    .{ "[Symbol.iterator]", native.function("values", 0, values) },
});

pub const statics: native.Table = .initComptime(.{
    .{ "isArray", native.function("isArray", 1, isArray) },
    .{ "from", native.function("from", 1, from) },
    .{ "of", native.function("of", 0, of) },
});

pub const constructor = native.constructor("Array", 1, null, null, &statics, true);

fn thisArray(it: *Interpreter, this: Value) Error!*Array {
    return switch (this) {
        .array => |a| a,
        else => it.throw(.Unsupported, "Calling an array method on something other than an array is not supported yet.", .{}),
    };
}

/// An array that's about to change, which it can't once it's frozen.
fn mutable(it: *Interpreter, this: Value) Error!*Array {
    const a = try thisArray(it, this);
    if (a.frozen) {
        return it.throw(.TypeError, "Cannot assign to read only property '0' of object '[object Array]'", .{});
    }
    return a;
}

fn toString(it: *Interpreter, this: Value, _: []const Value) Error!Value {
    return .{ .string = try joinArray(it, try thisArray(it, this), ",") };
}

fn join(it: *Interpreter, this: Value, args: []const Value) Error!Value {
    const separator = if (arg(args, 0) == .undefined) "," else try args[0].toString(it.arena);
    return .{ .string = try joinArray(it, try thisArray(it, this), separator) };
}

pub fn joinArray(it: *Interpreter, a: *Array, separator: []const u8) Error![]const u8 {
    return a.joinWith(it.arena, separator);
}

fn push(it: *Interpreter, this: Value, args: []const Value) Error!Value {
    const a = try thisArray(it, this);
    if (a.frozen) {
        return it.throw(.TypeError, "Cannot add property {d}, object is not extensible", .{a.items().len});
    }
    try a.elements.appendSlice(it.arena, args);
    return native.number(a.items().len);
}

fn pop(it: *Interpreter, this: Value, _: []const Value) Error!Value {
    const a = try thisArray(it, this);
    if (a.items().len == 0) {
        return .undefined;
    }
    if (a.frozen) {
        return it.throw(.TypeError, "Cannot delete property '{d}' of [object Array]", .{a.items().len - 1});
    }
    return a.elements.pop().?;
}

fn shift(it: *Interpreter, this: Value, _: []const Value) Error!Value {
    const a = try thisArray(it, this);
    if (a.items().len == 0) {
        return .undefined;
    }
    _ = try mutable(it, this);
    return a.elements.orderedRemove(0);
}

fn unshift(it: *Interpreter, this: Value, args: []const Value) Error!Value {
    const a = try thisArray(it, this);
    if (args.len > 0) {
        _ = try mutable(it, this);
        try a.elements.insertSlice(it.arena, 0, args);
    }
    return native.number(a.items().len);
}

fn concat(it: *Interpreter, this: Value, args: []const Value) Error!Value {
    var out: std.ArrayList(Value) = .empty;
    try out.appendSlice(it.arena, (try thisArray(it, this)).items());
    for (args) |item| {
        switch (item) {
            .array => |a| try out.appendSlice(it.arena, a.items()),
            else => try out.append(it.arena, item),
        }
    }
    return it.newArray(out.items);
}

fn reverse(it: *Interpreter, this: Value, _: []const Value) Error!Value {
    const a = try thisArray(it, this);
    if (a.items().len > 1) {
        std.mem.reverse(Value, (try mutable(it, this)).items());
    }
    return this;
}

fn slice(it: *Interpreter, this: Value, args: []const Value) Error!Value {
    const items = (try thisArray(it, this)).items();
    const start = native.relative(arg(args, 0), items.len, 0);
    const end = native.relative(arg(args, 1), items.len, items.len);
    return it.newArray(if (start < end) items[start..end] else &.{});
}

fn splice(it: *Interpreter, this: Value, args: []const Value) Error!Value {
    const a = try thisArray(it, this);
    const len = a.items().len;
    const start = native.relative(arg(args, 0), len, 0);
    var count: usize = 0;
    if (args.len == 1) {
        count = len - start;
    } else if (args.len > 1) {
        const n = native.integer(args[1]);
        count = @intFromFloat(std.math.clamp(n, 0, @as(f64, @floatFromInt(len - start))));
    }
    const inserted = if (args.len > 2) args[2..] else &.{};
    if (count > 0 or inserted.len > 0) {
        _ = try mutable(it, this);
    }
    const removed = try it.newArray(a.items()[start .. start + count]);
    try a.elements.replaceRange(it.arena, start, count, inserted);
    return removed;
}

/// SortCompare (§23.1.3.30.2): `undefined` goes last, and without a comparator the elements are
/// compared as strings.
const Sorter = struct {
    it: *Interpreter,
    comparator: Value,

    /// Whether `b` sorts before `a`, which is when a stable merge takes `b` first.
    fn before(this: *Sorter, b: Value, a: Value) Error!bool {
        if (this.comparator == .undefined) {
            const x = try b.toString(this.it.arena);
            const y = try a.toString(this.it.arena);
            return value.compareStrings(x, y) == .lt;
        }
        const result = (try this.it.invoke(this.comparator, .undefined, &.{ b, a })).toNumber();
        return result < 0;
    }

    fn sort(this: *Sorter, items: []Value) Error!void {
        if (items.len < 2) {
            return;
        }
        const scratch = try this.it.arena.alloc(Value, items.len);
        var width: usize = 1;
        var source = items;
        var target = scratch;
        while (width < items.len) : (width *= 2) {
            var start: usize = 0;
            while (start < items.len) : (start += 2 * width) {
                const middle = @min(start + width, items.len);
                const end = @min(start + 2 * width, items.len);
                var i = start;
                var j = middle;
                var k = start;
                while (i < middle and j < end) : (k += 1) {
                    if (try this.before(source[j], source[i])) {
                        target[k] = source[j];
                        j += 1;
                    } else {
                        target[k] = source[i];
                        i += 1;
                    }
                }
                while (i < middle) : (i += 1) {
                    target[k] = source[i];
                    k += 1;
                }
                while (j < end) : (j += 1) {
                    target[k] = source[j];
                    k += 1;
                }
            }
            const swap = source;
            source = target;
            target = swap;
        }
        if (source.ptr != items.ptr) {
            @memcpy(items, source);
        }
    }
};

fn sort(it: *Interpreter, this: Value, args: []const Value) Error!Value {
    const comparator = arg(args, 0);
    if (comparator != .undefined and comparator != .function and comparator != .native_function) {
        return it.throw(.TypeError, "The comparison function must be either a function or undefined: {s}", .{try comparator.toString(it.arena)});
    }
    const a = try thisArray(it, this);
    // Sorted as a copy, which a comparator that changes the array doesn't disturb.
    var defined: std.ArrayList(Value) = .empty;
    var undefineds: usize = 0;
    for (a.items()) |item| {
        if (item == .undefined) {
            undefineds += 1;
        } else {
            try defined.append(it.arena, item);
        }
    }
    var sorter: Sorter = .{ .it = it, .comparator = comparator };
    try sorter.sort(defined.items);
    if (a.items().len > 1) {
        _ = try mutable(it, this);
    }
    a.elements.clearRetainingCapacity();
    try a.elements.appendSlice(it.arena, defined.items);
    try a.elements.appendNTimes(it.arena, .undefined, undefineds);
    return this;
}

fn fromIndex(v: Value, len: usize) usize {
    if (v == .undefined) {
        return 0;
    }
    return native.relative(v, len, 0);
}

fn indexOf(it: *Interpreter, this: Value, args: []const Value) Error!Value {
    const items = (try thisArray(it, this)).items();
    const wanted = arg(args, 0);
    for (items[fromIndex(arg(args, 1), items.len)..], fromIndex(arg(args, 1), items.len)..) |item, i| {
        if (item.strictEquals(wanted)) {
            return native.number(i);
        }
    }
    return native.number(-1);
}

fn lastIndexOf(it: *Interpreter, this: Value, args: []const Value) Error!Value {
    const items = (try thisArray(it, this)).items();
    if (items.len == 0) {
        return native.number(-1);
    }
    const wanted = arg(args, 0);
    var start: f64 = @floatFromInt(items.len - 1);
    if (args.len > 1) {
        const n = native.integer(args[1]);
        start = if (n < 0) @as(f64, @floatFromInt(items.len)) + n else @min(n, start);
    }
    if (start < 0) {
        return native.number(-1);
    }
    var i: usize = @intFromFloat(start);
    while (true) : (i -= 1) {
        if (items[i].strictEquals(wanted)) {
            return native.number(i);
        }
        if (i == 0) {
            return native.number(-1);
        }
    }
}

fn includes(it: *Interpreter, this: Value, args: []const Value) Error!Value {
    const items = (try thisArray(it, this)).items();
    const wanted = arg(args, 0);
    for (items[fromIndex(arg(args, 1), items.len)..]) |item| {
        if (value.sameValueZero(item, wanted)) {
            return .{ .boolean = true };
        }
    }
    return .{ .boolean = false };
}

/// Calls `callback` with each element, index and the array, for as many elements as the array
/// had to begin with that it still has, until `done` says to stop.
fn each(it: *Interpreter, this: Value, args: []const Value, context: anytype, comptime done: fn (@TypeOf(context), Value, usize, Value) Error!bool) Error!void {
    const a = try thisArray(it, this);
    const callback = try native.callable(it, arg(args, 0));
    const len = a.items().len;
    for (0..len) |i| {
        if (i >= a.items().len) {
            break;
        }
        const element = a.items()[i];
        const result = try it.invoke(callback, arg(args, 1), &.{ element, native.number(i), this });
        if (try done(context, element, i, result)) {
            return;
        }
    }
}

fn every(it: *Interpreter, this: Value, args: []const Value) Error!Value {
    var all = true;
    try each(it, this, args, &all, struct {
        fn f(result: *bool, _: Value, _: usize, r: Value) Error!bool {
            if (!r.toBoolean()) {
                result.* = false;
                return true;
            }
            return false;
        }
    }.f);
    return .{ .boolean = all };
}

fn some(it: *Interpreter, this: Value, args: []const Value) Error!Value {
    var any = false;
    try each(it, this, args, &any, struct {
        fn f(result: *bool, _: Value, _: usize, r: Value) Error!bool {
            if (r.toBoolean()) {
                result.* = true;
                return true;
            }
            return false;
        }
    }.f);
    return .{ .boolean = any };
}

fn forEach(it: *Interpreter, this: Value, args: []const Value) Error!Value {
    try each(it, this, args, {}, struct {
        fn f(_: void, _: Value, _: usize, _: Value) Error!bool {
            return false;
        }
    }.f);
    return .undefined;
}

const Collected = struct {
    it: *Interpreter,
    items: std.ArrayList(Value) = .empty,
};

fn map(it: *Interpreter, this: Value, args: []const Value) Error!Value {
    const len = (try thisArray(it, this)).items().len;
    var collected: Collected = .{ .it = it };
    try each(it, this, args, &collected, struct {
        fn f(c: *Collected, _: Value, _: usize, r: Value) Error!bool {
            try c.items.append(c.it.arena, r);
            return false;
        }
    }.f);
    if (collected.items.items.len < len) {
        return it.throw(.Unsupported, "An array that 'map' leaves holes in is not supported yet.", .{});
    }
    return it.newArray(collected.items.items);
}

fn filter(it: *Interpreter, this: Value, args: []const Value) Error!Value {
    var collected: Collected = .{ .it = it };
    try each(it, this, args, &collected, struct {
        fn f(c: *Collected, element: Value, _: usize, r: Value) Error!bool {
            if (r.toBoolean()) {
                try c.items.append(c.it.arena, element);
            }
            return false;
        }
    }.f);
    return it.newArray(collected.items.items);
}

const Found = struct {
    element: Value = .undefined,
    index: ?usize = null,
};

fn search(it: *Interpreter, this: Value, args: []const Value) Error!Found {
    var found: Found = .{};
    try each(it, this, args, &found, struct {
        fn f(result: *Found, element: Value, i: usize, r: Value) Error!bool {
            if (r.toBoolean()) {
                result.* = .{ .element = element, .index = i };
                return true;
            }
            return false;
        }
    }.f);
    return found;
}

fn find(it: *Interpreter, this: Value, args: []const Value) Error!Value {
    return (try search(it, this, args)).element;
}

fn findIndex(it: *Interpreter, this: Value, args: []const Value) Error!Value {
    const found = try search(it, this, args);
    return if (found.index) |i| native.number(i) else native.number(-1);
}

fn reduceWith(it: *Interpreter, this: Value, args: []const Value, comptime backwards: bool) Error!Value {
    const a = try thisArray(it, this);
    const callback = try native.callable(it, arg(args, 0));
    const len = a.items().len;
    var k: usize = 0;
    var accumulator: Value = undefined;
    if (args.len >= 2) {
        accumulator = args[1];
    } else {
        if (len == 0) {
            return it.throw(.TypeError, "Reduce of empty array with no initial value", .{});
        }
        accumulator = a.items()[if (backwards) len - 1 else 0];
        k = 1;
    }
    while (k < len) : (k += 1) {
        const i = if (backwards) len - 1 - k else k;
        if (i >= a.items().len) {
            continue;
        }
        accumulator = try it.invoke(callback, .undefined, &.{ accumulator, a.items()[i], native.number(i), this });
    }
    return accumulator;
}

fn reduce(it: *Interpreter, this: Value, args: []const Value) Error!Value {
    return reduceWith(it, this, args, false);
}

fn reduceRight(it: *Interpreter, this: Value, args: []const Value) Error!Value {
    return reduceWith(it, this, args, true);
}

fn fill(it: *Interpreter, this: Value, args: []const Value) Error!Value {
    const items = (try thisArray(it, this)).items();
    const start = native.relative(arg(args, 1), items.len, 0);
    const end = native.relative(arg(args, 2), items.len, items.len);
    if (start < end) {
        @memset((try mutable(it, this)).items()[start..end], arg(args, 0));
    }
    return this;
}

fn flatten(it: *Interpreter, out: *std.ArrayList(Value), items: []const Value, depth: f64) Error!void {
    try it.checkStack();
    for (items) |item| {
        if (depth > 0 and item == .array) {
            try flatten(it, out, item.array.items(), depth - 1);
        } else {
            try out.append(it.arena, item);
        }
    }
}

fn flat(it: *Interpreter, this: Value, args: []const Value) Error!Value {
    const items = (try thisArray(it, this)).items();
    const depth: f64 = if (arg(args, 0) == .undefined) 1 else native.integer(args[0]);
    var out: std.ArrayList(Value) = .empty;
    try flatten(it, &out, items, depth);
    return it.newArray(out.items);
}

fn flatMap(it: *Interpreter, this: Value, args: []const Value) Error!Value {
    const mapped = try map(it, this, args);
    var out: std.ArrayList(Value) = .empty;
    try flatten(it, &out, mapped.array.items(), 1);
    return it.newArray(out.items);
}

fn at(it: *Interpreter, this: Value, args: []const Value) Error!Value {
    const items = (try thisArray(it, this)).items();
    const n = native.integer(arg(args, 0));
    const len: f64 = @floatFromInt(items.len);
    const k = if (n < 0) len + n else n;
    if (k < 0 or k >= len) {
        return .undefined;
    }
    return items[@intFromFloat(k)];
}

fn iterate(it: *Interpreter, this: Value, kind: value.Iterator.Kind) Error!Value {
    return iterators.toValue(it, try iterators.create(it, .{ .array = try thisArray(it, this) }, kind));
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

fn isArray(_: *Interpreter, _: Value, args: []const Value) Error!Value {
    return .{ .boolean = arg(args, 0) == .array };
}

/// Array.from: what iterating over an iterable gives, or the elements of an array-like object
/// like `{ length: 3 }`.
fn from(it: *Interpreter, _: Value, args: []const Value) Error!Value {
    const items = arg(args, 0);
    const mapper = arg(args, 1);
    if (mapper != .undefined) {
        _ = try native.callable(it, mapper);
    }
    var out: std.ArrayList(Value) = .empty;
    const iterable = switch (items) {
        .array, .string => true,
        .object => |o| o.internal != .none and o.internal != .@"error",
        .undefined, .null => return it.throw(.TypeError, "{s} is not iterable (cannot read property Symbol(Symbol.iterator))", .{try native.typed(it, items)}),
        else => false,
    };
    if (iterable) {
        var iteration = try it.iterate(items);
        while (try iteration.next(it)) |item| {
            try out.append(it.arena, item);
        }
    } else {
        const length = native.integer(try it.getNamed(items, "length"));
        var i: f64 = 0;
        while (i < length) : (i += 1) {
            try out.append(it.arena, try it.getProperty(items, native.number(i)));
        }
    }
    if (mapper != .undefined) {
        for (out.items, 0..) |*item, i| {
            item.* = try it.invoke(mapper, arg(args, 2), &.{ item.*, native.number(i) });
        }
    }
    return it.newArray(out.items);
}

fn of(it: *Interpreter, _: Value, args: []const Value) Error!Value {
    return it.newArray(args);
}
