//! `Math`.

const std = @import("std");
const native = @import("native.zig");
const value = @import("../value.zig");
const fdlibm = @import("../fdlibm.zig");
const Interpreter = native.Interpreter;
const Value = native.Value;
const Error = native.Error;
const arg = native.arg;

pub const members: native.Table = .initComptime(.{
    .{ "E", native.number(std.math.e) },
    .{ "LN10", native.number(std.math.ln10) },
    .{ "LN2", native.number(std.math.ln2) },
    .{ "LOG2E", native.number(std.math.log2e) },
    .{ "LOG10E", native.number(std.math.log10e) },
    .{ "PI", native.number(std.math.pi) },
    .{ "SQRT1_2", native.number(std.math.sqrt1_2) },
    .{ "SQRT2", native.number(std.math.sqrt2) },
    .{ "abs", unary("abs", abs) },
    .{ "acos", unary("acos", acos) },
    .{ "acosh", unary("acosh", acosh) },
    .{ "asin", unary("asin", asin) },
    .{ "asinh", unary("asinh", asinh) },
    .{ "atan", unary("atan", atan) },
    .{ "atanh", unary("atanh", atanh) },
    .{ "atan2", native.function("atan2", 2, atan2) },
    .{ "cbrt", unary("cbrt", cbrt) },
    .{ "ceil", unary("ceil", ceil) },
    .{ "clz32", unary("clz32", clz32) },
    .{ "cos", unary("cos", cos) },
    .{ "cosh", unary("cosh", cosh) },
    .{ "exp", unary("exp", exp) },
    .{ "expm1", unary("expm1", expm1) },
    .{ "floor", unary("floor", floor) },
    .{ "fround", unary("fround", fround) },
    .{ "hypot", native.function("hypot", 2, hypot) },
    .{ "imul", native.function("imul", 2, imul) },
    .{ "log", unary("log", log) },
    .{ "log10", unary("log10", log10) },
    .{ "log1p", unary("log1p", log1p) },
    .{ "log2", unary("log2", log2) },
    .{ "max", native.function("max", 2, max) },
    .{ "min", native.function("min", 2, min) },
    .{ "pow", native.function("pow", 2, pow) },
    .{ "random", native.function("random", 0, random) },
    .{ "round", unary("round", round) },
    .{ "sign", unary("sign", sign) },
    .{ "sin", unary("sin", sin) },
    .{ "sinh", unary("sinh", sinh) },
    .{ "sqrt", unary("sqrt", sqrt) },
    .{ "tan", unary("tan", tan) },
    .{ "tanh", unary("tanh", tanh) },
    .{ "trunc", unary("trunc", trunc) },
});

/// A function of one number.
fn unary(comptime name: []const u8, comptime f: fn (f64) f64) Value {
    return native.function(name, 1, struct {
        fn call(_: *Interpreter, _: Value, args: []const Value) Error!Value {
            return native.number(f(arg(args, 0).toNumber()));
        }
    }.call);
}

fn acos(x: f64) f64 {
    return fdlibm.acos(x);
}

fn acosh(x: f64) f64 {
    return fdlibm.acosh(x);
}

fn asin(x: f64) f64 {
    return fdlibm.asin(x);
}

fn asinh(x: f64) f64 {
    return fdlibm.asinh(x);
}

fn atan(x: f64) f64 {
    return fdlibm.atan(x);
}

fn atanh(x: f64) f64 {
    return fdlibm.atanh(x);
}

fn cbrt(x: f64) f64 {
    return fdlibm.cbrt(x);
}

fn cosh(x: f64) f64 {
    return fdlibm.cosh(x);
}

fn expm1(x: f64) f64 {
    return fdlibm.expm1(x);
}

fn log1p(x: f64) f64 {
    return fdlibm.log1p(x);
}

fn sinh(x: f64) f64 {
    return fdlibm.sinh(x);
}

fn tan(x: f64) f64 {
    return fdlibm.tan(x);
}

fn tanh(x: f64) f64 {
    return fdlibm.tanh(x);
}

fn abs(x: f64) f64 {
    return @abs(x);
}

fn ceil(x: f64) f64 {
    return @ceil(x);
}

fn floor(x: f64) f64 {
    return @floor(x);
}

fn trunc(x: f64) f64 {
    return @trunc(x);
}

fn sqrt(x: f64) f64 {
    return @sqrt(x);
}

fn sin(x: f64) f64 {
    return fdlibm.sin(x);
}

fn cos(x: f64) f64 {
    return fdlibm.cos(x);
}

fn exp(x: f64) f64 {
    return fdlibm.exp(x);
}

fn log(x: f64) f64 {
    return fdlibm.log(x);
}

fn log2(x: f64) f64 {
    return fdlibm.log2(x);
}

fn log10(x: f64) f64 {
    return fdlibm.log10(x);
}

fn fround(x: f64) f64 {
    const single: f32 = @floatCast(x);
    return single;
}

fn clz32(x: f64) f64 {
    return @floatFromInt(@clz(value.toUint32(x)));
}

/// Math.round (§21.3.2.28): to the nearest integer, a half going up, keeping the sign of zero.
fn round(x: f64) f64 {
    if (!std.math.isFinite(x) or x == 0) {
        return x;
    }
    if (x > 0 and x < 0.5) {
        return 0;
    }
    if (x < 0 and x >= -0.5) {
        return -0.0;
    }
    const f = @floor(x);
    return if (x - f >= 0.5) f + 1 else f;
}

fn sign(x: f64) f64 {
    if (std.math.isNan(x) or x == 0) {
        return x;
    }
    return if (x > 0) 1 else -1;
}

fn atan2(_: *Interpreter, _: Value, args: []const Value) Error!Value {
    return native.number(fdlibm.atan2(arg(args, 0).toNumber(), arg(args, 1).toNumber()));
}

fn pow(_: *Interpreter, _: Value, args: []const Value) Error!Value {
    return native.number(value.exponentiate(arg(args, 0).toNumber(), arg(args, 1).toNumber()));
}

fn imul(_: *Interpreter, _: Value, args: []const Value) Error!Value {
    const a = value.toInt32(arg(args, 0).toNumber());
    const b = value.toInt32(arg(args, 1).toNumber());
    return native.number(a *% b);
}

/// Math.hypot (§21.3.2.18): infinite if any argument is, otherwise NaN if any is.
fn hypot(it: *Interpreter, _: Value, args: []const Value) Error!Value {
    var largest: f64 = 0;
    var nan = false;
    var infinite = false;
    const numbers = try it.arena.alloc(f64, args.len);
    for (args, numbers) |a, *n| {
        n.* = a.toNumber();
        if (std.math.isInf(n.*)) {
            infinite = true;
        } else if (std.math.isNan(n.*)) {
            nan = true;
        } else {
            largest = @max(largest, @abs(n.*));
        }
    }
    if (infinite) {
        return native.number(std.math.inf(f64));
    }
    if (nan) {
        return native.number(std.math.nan(f64));
    }
    if (largest == 0) {
        return native.number(0);
    }
    // Scaled by the largest, so the squares don't overflow, with compensated summation.
    var sum: f64 = 0;
    var compensation: f64 = 0;
    for (numbers) |n| {
        const scaled = n / largest;
        const term = scaled * scaled - compensation;
        const next = sum + term;
        compensation = (next - sum) - term;
        sum = next;
    }
    return native.number(@sqrt(sum) * largest);
}

fn extreme(args: []const Value, comptime biggest: bool) f64 {
    var result: f64 = if (biggest) -std.math.inf(f64) else std.math.inf(f64);
    var nan = false;
    for (args) |a| {
        const n = a.toNumber();
        if (std.math.isNan(n)) {
            nan = true;
            continue;
        }
        if (biggest) {
            // +0 is bigger than -0.
            if (n > result or (n == 0 and result == 0 and !std.math.signbit(n))) {
                result = n;
            }
        } else if (n < result or (n == 0 and result == 0 and std.math.signbit(n))) {
            result = n;
        }
    }
    return if (nan) std.math.nan(f64) else result;
}

fn max(_: *Interpreter, _: Value, args: []const Value) Error!Value {
    return native.number(extreme(args, true));
}

fn min(_: *Interpreter, _: Value, args: []const Value) Error!Value {
    return native.number(extreme(args, false));
}

fn random(it: *Interpreter, _: Value, _: []const Value) Error!Value {
    return native.number(it.builtin_state.random.random().float(f64));
}
