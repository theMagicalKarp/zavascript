//! The builtin iterators: what `entries()`, `keys()` and `values()` return, and what `for...of`
//! uses to go through strings, maps and sets.

const std = @import("std");
const native = @import("native.zig");
const value = @import("../value.zig");
const Interpreter = native.Interpreter;
const Value = native.Value;
const Error = native.Error;

pub const methods: native.Table = .initComptime(.{
    .{ "next", native.function("next", 0, next) },
    .{ "[Symbol.iterator]", native.function("[Symbol.iterator]", 0, self) },
});

pub fn create(it: *Interpreter, source: value.Iterator.Source, kind: value.Iterator.Kind) Error!*value.Iterator {
    const iterator = try it.arena.create(value.Iterator);
    iterator.* = .{ .source = source, .kind = kind };
    return iterator;
}

/// An iterator as a value, an object `console.log` shows the way node does.
pub fn toValue(it: *Interpreter, iterator: *value.Iterator) Error!Value {
    const o = try it.arena.create(value.Object);
    o.* = .{
        .internal = .{ .iterator = iterator },
        .methods = &methods,
        .tag = switch (iterator.source) {
            .array => "Object [Array Iterator]",
            .string => "Object [String Iterator]",
            .map, .set => null,
        },
    };
    return .{ .object = o };
}

/// The next value an iterator gives, or null when it's done.
pub fn step(it: *Interpreter, iterator: *value.Iterator) Error!?Value {
    if (iterator.done) {
        return null;
    }
    switch (iterator.source) {
        .array => |a| {
            // An array iterator sees the array as it is at each step.
            if (iterator.position < a.items().len) {
                const i = iterator.position;
                iterator.position += 1;
                return switch (iterator.kind) {
                    .keys => native.number(i),
                    .values => a.items()[i],
                    .entries => try it.newArray(&.{ native.number(i), a.items()[i] }),
                };
            }
        },
        .string => |s| if (iterator.position < s.len) {
            // A code point at a time; a lone surrogate is one too.
            const i = iterator.position;
            const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
            iterator.position = @min(i + len, s.len);
            return .{ .string = s[i..iterator.position] };
        },
        .map, .set => |c| {
            while (iterator.position < c.entries.items.len) {
                const e = c.entries.items[iterator.position];
                iterator.position += 1;
                if (e.removed) {
                    continue;
                }
                return switch (iterator.kind) {
                    .keys => e.key,
                    .values => e.value,
                    .entries => try it.newArray(&.{ e.key, e.value }),
                };
            }
        },
    }
    iterator.done = true;
    return null;
}

fn thisIterator(it: *Interpreter, this: Value) Error!*value.Iterator {
    if (this == .object and this.object.internal == .iterator) {
        return this.object.internal.iterator;
    }
    return it.throw(.TypeError, "next method called on incompatible receiver {s}", .{try it.describe(this)});
}

/// `iterator.next()`: `{ value, done }`.
fn next(it: *Interpreter, this: Value, _: []const Value) Error!Value {
    const iterator = try thisIterator(it, this);
    if (try step(it, iterator)) |v| {
        return native.object(it, &.{ .{ "value", v }, .{ "done", .{ .boolean = false } } });
    }
    return native.object(it, &.{ .{ "value", .undefined }, .{ "done", .{ .boolean = true } } });
}

fn self(_: *Interpreter, this: Value, _: []const Value) Error!Value {
    return this;
}
