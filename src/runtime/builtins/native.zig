//! Helpers for writing builtins: native function values, argument conversions, and the
//! relative indices many methods take.

const std = @import("std");
const value = @import("../value.zig");
pub const Interpreter = @import("../Interpreter.zig");
pub const Value = value.Value;
pub const Table = value.Table;
pub const Error = Interpreter.Error;

/// A builtin's implementation: the interpreter, `this`, and the arguments.
pub const Fn = fn (*Interpreter, Value, []const Value) Error!Value;

fn wrap(comptime f: Fn) value.NativeFunction.Call {
    return struct {
        fn call(context: *anyopaque, this: Value, args: []const Value) anyerror!Value {
            return f(Interpreter.fromContext(context), this, args);
        }
    }.call;
}

/// A builtin function, which `length` says how many arguments it expects.
pub fn function(comptime name: []const u8, comptime length: u32, comptime f: Fn) Value {
    return .{ .native_function = &struct {
        const native: value.NativeFunction = .{
            .name = name,
            .source = "function " ++ name ++ "() { [native code] }",
            .call = wrap(f),
            .length = length,
        };
    }.native };
}

/// A builtin constructor, with what calling it does, what `new` does, and its own properties.
/// `unsupported` says that JavaScript can do the ones that are null, which we can't yet.
pub fn constructor(comptime name: []const u8, comptime length: u32, comptime call: ?Fn, comptime construct: ?Fn, comptime statics: *const Table, comptime unsupported: bool) Value {
    return .{ .native_function = &struct {
        const native: value.NativeFunction = .{
            .name = name,
            .source = "function " ++ name ++ "() { [native code] }",
            .call = if (call) |f| wrap(f) else null,
            .construct = if (construct) |f| wrap(f) else null,
            .statics = statics,
            .length = length,
            .unsupported = unsupported,
        };
    }.native };
}

/// The argument at `i`, or `undefined` if there aren't that many.
pub fn arg(args: []const Value, i: usize) Value {
    return if (i < args.len) args[i] else .undefined;
}

/// ToIntegerOrInfinity (§7.1.5).
pub fn integer(v: Value) f64 {
    const n = v.toNumber();
    if (std.math.isNan(n)) {
        return 0;
    }
    if (std.math.isInf(n)) {
        return n;
    }
    const t = @trunc(n);
    return if (t == 0) 0 else t;
}

/// A relative index as `slice` and friends take it: negative counts back from `len`, and the
/// result is clamped to 0..len. `undefined` is `default`.
pub fn relative(v: Value, len: usize, default: usize) usize {
    if (v == .undefined) {
        return default;
    }
    const n = integer(v);
    const l: f64 = @floatFromInt(len);
    if (n < 0) {
        return @intFromFloat(@max(l + n, 0));
    }
    return @intFromFloat(@min(n, l));
}

/// A callback argument, which has to be a function.
pub fn callable(it: *Interpreter, v: Value) Error!Value {
    return switch (v) {
        .function, .native_function => v,
        else => it.throw(.TypeError, "{s} is not a function", .{try typed(it, v)}),
    };
}

/// A value the way V8's messages about builtins' arguments show it: `number 5`, `object null`.
pub fn typed(it: *Interpreter, v: Value) Error![]const u8 {
    return switch (v) {
        .undefined => "undefined",
        .null => "object null",
        .boolean, .number => std.fmt.allocPrint(it.arena, "{s} {s}", .{ v.typeOf(), try v.toString(it.arena) }),
        .string => |s| std.fmt.allocPrint(it.arena, "string \"{s}\"", .{s}),
        else => it.describe(v),
    };
}

/// What iterating over a builtin's argument goes through, with V8's message if it can't be.
pub fn iterate(it: *Interpreter, v: Value) Error!Interpreter.Iteration {
    const iterable = switch (v) {
        .array, .string => true,
        .object => |o| o.internal != .none and o.internal != .@"error",
        else => false,
    };
    if (!iterable) {
        return it.throw(.TypeError, "{s} is not iterable (cannot read property Symbol(Symbol.iterator))", .{try typed(it, v)});
    }
    return it.iterate(v);
}

pub fn number(n: anytype) Value {
    return .{ .number = switch (@typeInfo(@TypeOf(n))) {
        .int, .comptime_int => @floatFromInt(n),
        else => n,
    } };
}

/// A new plain object with these properties, in order.
pub fn object(it: *Interpreter, properties: []const struct { []const u8, Value }) Error!Value {
    const o = try it.arena.create(value.Object);
    o.* = .{};
    for (properties) |p| {
        try o.properties.put(it.arena, p[0], p[1]);
    }
    return .{ .object = o };
}
