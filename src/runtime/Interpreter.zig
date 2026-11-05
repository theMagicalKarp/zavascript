//! Evaluates a checked program by walking its syntax tree.

const std = @import("std");
const ast = @import("../syntax/ast.zig");
const value = @import("value.zig");
const number = @import("number.zig");
const Value = value.Value;
const Expr = ast.Expr;

const Interpreter = @This();

/// Holds every value the program creates. There's no garbage collector yet, so this lives as
/// long as the runtime.
arena: std.mem.Allocator,
/// Where `console.log` writes.
stdout: *std.Io.Writer,
/// Where `console.error` and `console.warn` write.
stderr: *std.Io.Writer,
globals: std.StringHashMapUnmanaged(Value) = .empty,

pub const Error = error{ OutOfMemory, WriteFailed };

pub fn init(arena: std.mem.Allocator, stdout: *std.Io.Writer, stderr: *std.Io.Writer) Error!Interpreter {
    var interpreter: Interpreter = .{ .arena = arena, .stdout = stdout, .stderr = stderr };
    try @import("builtins/console.zig").install(&interpreter);
    try interpreter.globals.put(arena, "undefined", .undefined);
    try interpreter.globals.put(arena, "NaN", .{ .number = std.math.nan(f64) });
    try interpreter.globals.put(arena, "Infinity", .{ .number = std.math.inf(f64) });
    return interpreter;
}

/// Runs the statements in order, returning the value of the last expression statement, which
/// is what the REPL prints.
pub fn run(this: *Interpreter, program: ast.Program) Error!Value {
    var completion: Value = .undefined;
    for (program.statements) |stmt| {
        switch (stmt.data) {
            .expression => |e| completion = try this.evaluate(e),
            .empty => {},
        }
    }
    return completion;
}

fn evaluate(this: *Interpreter, expr: *const Expr) Error!Value {
    return switch (expr.data) {
        .number => |n| .{ .number = n },
        .string => |s| .{ .string = s },
        .boolean => |b| .{ .boolean = b },
        .null => .null,
        .template => |t| this.template(t),
        // The checker has already rejected unknown names.
        .identifier => |name| this.globals.get(name).?,
        .paren => |inner| this.evaluate(inner),
        .unary => |u| this.unary(u),
        .binary => |b| this.binary(b),
        .conditional => |c| if ((try this.evaluate(c.condition)).toBoolean()) this.evaluate(c.then) else this.evaluate(c.otherwise),
        .member => |m| this.member(m),
        .call => |c| this.call(c),
    };
}

fn template(this: *Interpreter, t: ast.Template) Error!Value {
    if (t.substitutions.len == 0) {
        return .{ .string = t.quasis[0] };
    }
    var out: std.ArrayList(u8) = .empty;
    for (t.quasis, 0..) |quasi, i| {
        try out.appendSlice(this.arena, quasi);
        if (i < t.substitutions.len) {
            const sub = try this.evaluate(t.substitutions[i]);
            try out.appendSlice(this.arena, try sub.toString(this.arena));
        }
    }
    return .{ .string = try out.toOwnedSlice(this.arena) };
}

fn unary(this: *Interpreter, u: ast.Unary) Error!Value {
    const operand = try this.evaluate(u.operand);
    return switch (u.op) {
        .negate => .{ .number = -operand.toNumber() },
        .plus => .{ .number = operand.toNumber() },
        .not => .{ .boolean = !operand.toBoolean() },
        .bitwise_not => .{ .number = @floatFromInt(~value.toInt32(operand.toNumber())) },
        .typeof => .{ .string = operand.typeOf() },
        .void => .undefined,
    };
}

fn binary(this: *Interpreter, b: ast.Binary) Error!Value {
    // The short-circuiting operators evaluate the right side only when needed.
    switch (b.op) {
        .logical_and => {
            const left = try this.evaluate(b.left);
            return if (!left.toBoolean()) left else this.evaluate(b.right);
        },
        .logical_or => {
            const left = try this.evaluate(b.left);
            return if (left.toBoolean()) left else this.evaluate(b.right);
        },
        .nullish => {
            const left = try this.evaluate(b.left);
            return if (left == .null or left == .undefined) this.evaluate(b.right) else left;
        },
        else => {},
    }

    const left = try this.evaluate(b.left);
    const right = try this.evaluate(b.right);
    return switch (b.op) {
        .add => this.add(left, right),
        .subtract => .{ .number = left.toNumber() - right.toNumber() },
        .multiply => .{ .number = left.toNumber() * right.toNumber() },
        .divide => .{ .number = left.toNumber() / right.toNumber() },
        // JS `%` truncates toward zero and keeps the dividend's sign, which is `@rem`.
        .remainder => .{ .number = remainder(left.toNumber(), right.toNumber()) },
        .exponent => .{ .number = value.exponentiate(left.toNumber(), right.toNumber()) },
        .shift_left => int32(value.toInt32(left.toNumber()) << shiftCount(right)),
        .shift_right => int32(value.toInt32(left.toNumber()) >> shiftCount(right)),
        .shift_right_unsigned => .{ .number = @floatFromInt(value.toUint32(left.toNumber()) >> shiftCount(right)) },
        .bitwise_and => int32(value.toInt32(left.toNumber()) & value.toInt32(right.toNumber())),
        .bitwise_or => int32(value.toInt32(left.toNumber()) | value.toInt32(right.toNumber())),
        .bitwise_xor => int32(value.toInt32(left.toNumber()) ^ value.toInt32(right.toNumber())),
        .less => .{ .boolean = lessThan(left, right) orelse false },
        .greater => .{ .boolean = lessThan(right, left) orelse false },
        // `a <= b` is `!(b < a)`, except that NaN makes every comparison false.
        .less_equal => .{ .boolean = if (lessThan(right, left)) |r| !r else false },
        .greater_equal => .{ .boolean = if (lessThan(left, right)) |r| !r else false },
        .equal => .{ .boolean = left.looseEquals(right) },
        .not_equal => .{ .boolean = !left.looseEquals(right) },
        .strict_equal => .{ .boolean = left.strictEquals(right) },
        .strict_not_equal => .{ .boolean = !left.strictEquals(right) },
        .logical_and, .logical_or, .nullish => unreachable,
    };
}

fn int32(n: i32) Value {
    return .{ .number = @floatFromInt(n) };
}

fn shiftCount(v: Value) u5 {
    return @truncate(value.toUint32(v.toNumber()));
}

fn remainder(n: f64, d: f64) f64 {
    if (std.math.isNan(n) or std.math.isNan(d) or std.math.isInf(n) or d == 0) {
        return std.math.nan(f64);
    }
    if (std.math.isInf(d)) {
        return n;
    }
    if (n == 0) {
        return n;
    }
    return @rem(n, d);
}

/// The `+` operator (§13.15.3): string concatenation if either side is a string after
/// ToPrimitive, numeric addition otherwise.
fn add(this: *Interpreter, left: Value, right: Value) Error!Value {
    const lp = left.toPrimitive();
    const rp = right.toPrimitive();
    if (lp == .string or rp == .string) {
        const ls = try lp.toString(this.arena);
        const rs = try rp.toString(this.arena);
        return .{ .string = try std.mem.concat(this.arena, u8, &.{ ls, rs }) };
    }
    return .{ .number = lp.toNumber() + rp.toNumber() };
}

/// IsLessThan (§7.2.13): null when either side is NaN.
fn lessThan(a: Value, b: Value) ?bool {
    const ap = a.toPrimitive();
    const bp = b.toPrimitive();
    if (ap == .string and bp == .string) {
        return value.compareStrings(ap.string, bp.string) == .lt;
    }
    const x = ap.toNumber();
    const y = bp.toNumber();
    if (std.math.isNan(x) or std.math.isNan(y)) {
        return null;
    }
    return x < y;
}

fn member(this: *Interpreter, m: ast.Member) Error!Value {
    const object = try this.evaluate(m.object);
    return switch (object) {
        .object => |o| o.get(m.property),
        // The checker only lets property reads through on objects so far.
        else => unreachable,
    };
}

fn call(this: *Interpreter, c: ast.Call) Error!Value {
    var receiver: Value = .undefined;
    const callee = switch (c.callee.data) {
        .member => |m| blk: {
            receiver = try this.evaluate(m.object);
            break :blk receiver.object.get(m.property);
        },
        else => try this.evaluate(c.callee),
    };
    const args = try this.arena.alloc(Value, c.arguments.len);
    for (c.arguments, args) |arg, *slot| {
        slot.* = try this.evaluate(arg);
    }
    return switch (callee) {
        .native_function => |f| f.call(this, receiver, args) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.WriteFailed => error.WriteFailed,
            else => unreachable,
        },
        else => unreachable,
    };
}

/// Reaches the interpreter from a native function's opaque context.
pub fn fromContext(context: *anyopaque) *Interpreter {
    return @ptrCast(@alignCast(context));
}
