//! `Number`, `Number.prototype`, `Boolean` and the global number functions (`parseInt`,
//! `parseFloat`, `isNaN`, `isFinite`).

const std = @import("std");
const native = @import("native.zig");
const value = @import("../value.zig");
const number = @import("../number.zig");
const Interpreter = native.Interpreter;
const Value = native.Value;
const Error = native.Error;
const arg = native.arg;

pub const methods: native.Table = .initComptime(.{
    .{ "toString", native.function("toString", 1, toString) },
    .{ "toFixed", native.function("toFixed", 1, toFixed) },
    .{ "toExponential", native.function("toExponential", 1, toExponential) },
    .{ "toPrecision", native.function("toPrecision", 1, toPrecision) },
    .{ "valueOf", native.function("valueOf", 0, valueOf) },
});

pub const boolean_methods: native.Table = .initComptime(.{
    .{ "valueOf", native.function("valueOf", 0, booleanValueOf) },
    .{ "toString", native.function("toString", 0, booleanToString) },
});

pub const parse_int = native.function("parseInt", 2, parseInt);
pub const parse_float = native.function("parseFloat", 1, parseFloat);
pub const is_nan = native.function("isNaN", 1, isNaN);
pub const is_finite = native.function("isFinite", 1, isFinite);

pub const statics: native.Table = .initComptime(.{
    .{ "MAX_VALUE", native.number(std.math.floatMax(f64)) },
    .{ "MIN_VALUE", native.number(std.math.floatTrueMin(f64)) },
    .{ "NaN", native.number(std.math.nan(f64)) },
    .{ "NEGATIVE_INFINITY", native.number(-std.math.inf(f64)) },
    .{ "POSITIVE_INFINITY", native.number(std.math.inf(f64)) },
    .{ "EPSILON", native.number(std.math.floatEps(f64)) },
    .{ "MAX_SAFE_INTEGER", native.number(9007199254740991) },
    .{ "MIN_SAFE_INTEGER", native.number(-9007199254740991) },
    .{ "isFinite", native.function("isFinite", 1, numberIsFinite) },
    .{ "isInteger", native.function("isInteger", 1, isInteger) },
    .{ "isNaN", native.function("isNaN", 1, numberIsNaN) },
    .{ "isSafeInteger", native.function("isSafeInteger", 1, isSafeInteger) },
    // The same functions as the globals.
    .{ "parseFloat", parse_float },
    .{ "parseInt", parse_int },
});

pub const constructor = native.constructor("Number", 1, call, null, &statics, true);

const no_statics: native.Table = .initComptime(.{});

pub const boolean_constructor = native.constructor("Boolean", 1, booleanCall, null, &no_statics, true);

/// `Number(value)`.
fn call(_: *Interpreter, _: Value, args: []const Value) Error!Value {
    return native.number(if (args.len == 0) 0 else args[0].toNumber());
}

/// `Boolean(value)`.
fn booleanCall(_: *Interpreter, _: Value, args: []const Value) Error!Value {
    return .{ .boolean = arg(args, 0).toBoolean() };
}

fn thisNumber(it: *Interpreter, this: Value, comptime method: []const u8) Error!f64 {
    return switch (this) {
        .number => |n| n,
        else => it.throw(.TypeError, "Number.prototype." ++ method ++ " requires that 'this' be a Number", .{}),
    };
}

fn toString(it: *Interpreter, this: Value, args: []const Value) Error!Value {
    const x = try thisNumber(it, this, "toString");
    var radix: f64 = 10;
    if (arg(args, 0) != .undefined) {
        radix = native.integer(args[0]);
    }
    if (radix < 2 or radix > 36) {
        return it.throw(.RangeError, "toString() radix argument must be between 2 and 36", .{});
    }
    return .{ .string = try number.toRadix(it.arena, x, @intFromFloat(radix)) };
}

fn toFixed(it: *Interpreter, this: Value, args: []const Value) Error!Value {
    const x = try thisNumber(it, this, "toFixed");
    const f = native.integer(arg(args, 0));
    if (f < 0 or f > 100) {
        return it.throw(.RangeError, "toFixed() digits argument must be between 0 and 100", .{});
    }
    return .{ .string = try number.toFixed(it.arena, x, @intFromFloat(f)) };
}

fn toExponential(it: *Interpreter, this: Value, args: []const Value) Error!Value {
    const x = try thisNumber(it, this, "toExponential");
    const f = native.integer(arg(args, 0));
    if (!std.math.isFinite(x)) {
        return .{ .string = try number.toString(it.arena, x) };
    }
    if (f < 0 or f > 100) {
        return it.throw(.RangeError, "toExponential() argument must be between 0 and 100", .{});
    }
    const digits: ?u32 = if (arg(args, 0) == .undefined) null else @intFromFloat(f);
    return .{ .string = try number.toExponential(it.arena, x, digits) };
}

fn toPrecision(it: *Interpreter, this: Value, args: []const Value) Error!Value {
    const x = try thisNumber(it, this, "toPrecision");
    if (arg(args, 0) == .undefined or !std.math.isFinite(x)) {
        return .{ .string = try number.toString(it.arena, x) };
    }
    const p = native.integer(args[0]);
    if (p < 1 or p > 100) {
        return it.throw(.RangeError, "toPrecision() argument must be between 1 and 100", .{});
    }
    return .{ .string = try number.toPrecision(it.arena, x, @intFromFloat(p)) };
}

fn valueOf(it: *Interpreter, this: Value, _: []const Value) Error!Value {
    return native.number(try thisNumber(it, this, "valueOf"));
}

fn booleanValueOf(it: *Interpreter, this: Value, _: []const Value) Error!Value {
    return switch (this) {
        .boolean => this,
        else => it.throw(.TypeError, "Boolean.prototype.valueOf requires that 'this' be a Boolean", .{}),
    };
}

fn booleanToString(it: *Interpreter, this: Value, _: []const Value) Error!Value {
    return switch (this) {
        .boolean => |b| .{ .string = if (b) "true" else "false" },
        else => it.throw(.TypeError, "Boolean.prototype.toString requires that 'this' be a Boolean", .{}),
    };
}

fn parseInt(it: *Interpreter, _: Value, args: []const Value) Error!Value {
    const s = try arg(args, 0).toString(it.arena);
    return native.number(number.parseInt(s, value.toInt32(arg(args, 1).toNumber())));
}

fn parseFloat(it: *Interpreter, _: Value, args: []const Value) Error!Value {
    return native.number(number.parseFloat(try arg(args, 0).toString(it.arena)));
}

fn isNaN(_: *Interpreter, _: Value, args: []const Value) Error!Value {
    return .{ .boolean = std.math.isNan(arg(args, 0).toNumber()) };
}

fn isFinite(_: *Interpreter, _: Value, args: []const Value) Error!Value {
    return .{ .boolean = std.math.isFinite(arg(args, 0).toNumber()) };
}

fn numberIsNaN(_: *Interpreter, _: Value, args: []const Value) Error!Value {
    const v = arg(args, 0);
    return .{ .boolean = v == .number and std.math.isNan(v.number) };
}

fn numberIsFinite(_: *Interpreter, _: Value, args: []const Value) Error!Value {
    const v = arg(args, 0);
    return .{ .boolean = v == .number and std.math.isFinite(v.number) };
}

fn isIntegral(v: Value) bool {
    return v == .number and std.math.isFinite(v.number) and @trunc(v.number) == v.number;
}

fn isInteger(_: *Interpreter, _: Value, args: []const Value) Error!Value {
    return .{ .boolean = isIntegral(arg(args, 0)) };
}

fn isSafeInteger(_: *Interpreter, _: Value, args: []const Value) Error!Value {
    const v = arg(args, 0);
    return .{ .boolean = isIntegral(v) and @abs(v.number) <= 9007199254740991 };
}
