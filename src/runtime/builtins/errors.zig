//! `Error` and its subclasses. The runtime raises the same errors (see `Interpreter.throw`).

const std = @import("std");
const native = @import("native.zig");
const value = @import("../value.zig");
const Interpreter = native.Interpreter;
const Value = native.Value;
const Error = native.Error;
const ErrorKind = value.ErrorKind;
const arg = native.arg;

/// `Error.prototype`'s methods, which the other errors' prototypes inherit.
pub const methods: native.Table = .initComptime(.{
    .{ "toString", native.function("toString", 0, toString) },
});

const no_statics: native.Table = .initComptime(.{});

fn constructorFor(comptime kind: ErrorKind) Value {
    const name = @tagName(kind);
    return native.constructor(name, 1, construct(kind), construct(kind), &no_statics, false);
}

/// Each error's constructor, by its kind.
pub const constructors = blk: {
    var list: [std.enums.values(ErrorKind).len]Value = undefined;
    for (std.enums.values(ErrorKind), &list) |kind, *c| {
        c.* = constructorFor(kind);
    }
    break :blk list;
};

/// Which error `f` constructs, if it's one of their constructors.
pub fn kindOf(f: *const value.NativeFunction) ?ErrorKind {
    for (constructors, std.enums.values(ErrorKind)) |c, kind| {
        if (c.native_function == f) {
            return kind;
        }
    }
    return null;
}

/// `new Error(message, options)`, which `Error(message, options)` also does (§20.5.1.1).
fn construct(comptime kind: ErrorKind) native.Fn {
    return struct {
        fn f(it: *Interpreter, _: Value, args: []const Value) Error!Value {
            const message = arg(args, 0);
            var cause: ?Value = null;
            const options = arg(args, 1);
            if (options == .object) {
                if (options.object.properties.get("cause")) |c| {
                    cause = c;
                }
            }
            return it.newError(kind, if (message == .undefined) null else .{ .string = try message.toString(it.arena) }, cause);
        }
    }.f;
}

/// Error.prototype.toString (§20.5.3.4), which works on any object.
fn toString(it: *Interpreter, this: Value, _: []const Value) Error!Value {
    switch (this) {
        .object, .array, .function, .native_function => {},
        else => return it.throw(.TypeError, "Error.prototype.toString requires that 'this' be an Object", .{}),
    }
    const name_value = try it.getNamed(this, "name");
    const message_value = try it.getNamed(this, "message");
    const name = if (name_value == .undefined) "Error" else try name_value.toString(it.arena);
    const message = if (message_value == .undefined) "" else try message_value.toString(it.arena);
    if (name.len == 0) {
        return .{ .string = message };
    }
    if (message.len == 0) {
        return .{ .string = name };
    }
    return .{ .string = try std.fmt.allocPrint(it.arena, "{s}: {s}", .{ name, message }) };
}
