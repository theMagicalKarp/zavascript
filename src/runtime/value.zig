//! Runtime values and the abstract operations from ECMA-262 that act on them (ToNumber,
//! ToString, ToBoolean, equality, ...).

const std = @import("std");
const number = @import("number.zig");

pub const Value = union(enum) {
    undefined,
    null,
    boolean: bool,
    number: f64,
    /// WTF-8 bytes; see `Lexer.cook`. Immutable and shared freely.
    string: []const u8,
    object: *Object,
    native_function: *const NativeFunction,

    pub fn typeOf(this: Value) []const u8 {
        return switch (this) {
            .undefined => "undefined",
            .null => "object",
            .boolean => "boolean",
            .number => "number",
            .string => "string",
            .object => "object",
            .native_function => "function",
        };
    }

    /// ToBoolean (§7.1.2).
    pub fn toBoolean(this: Value) bool {
        return switch (this) {
            .undefined, .null => false,
            .boolean => |b| b,
            .number => |n| !(n == 0 or std.math.isNan(n)),
            .string => |s| s.len > 0,
            .object, .native_function => true,
        };
    }

    /// ToNumber (§7.1.4) for primitives. Objects are first converted with `toPrimitive`.
    pub fn toNumber(this: Value) f64 {
        return switch (this) {
            .undefined => std.math.nan(f64),
            .null => 0,
            .boolean => |b| if (b) 1 else 0,
            .number => |n| n,
            .string => |s| number.parseString(s),
            .object, .native_function => toPrimitive(this).toNumber(),
        };
    }

    /// ToPrimitive (§7.1.1). There are no user-defined `valueOf`/`toString` methods yet, so every
    /// object becomes its default string.
    pub fn toPrimitive(this: Value) Value {
        return switch (this) {
            .object => .{ .string = "[object Object]" },
            .native_function => |f| .{ .string = f.source },
            else => this,
        };
    }

    /// ToString (§7.1.17), allocating only when the result isn't already a string.
    pub fn toString(this: Value, allocator: std.mem.Allocator) error{OutOfMemory}![]const u8 {
        return switch (this) {
            .undefined => "undefined",
            .null => "null",
            .boolean => |b| if (b) "true" else "false",
            .number => |n| number.toString(allocator, n),
            .string => |s| s,
            .object, .native_function => toPrimitive(this).toString(allocator),
        };
    }

    /// IsStrictlyEqual (`===`, §7.2.15).
    pub fn strictEquals(a: Value, b: Value) bool {
        return switch (a) {
            .undefined => b == .undefined,
            .null => b == .null,
            .boolean => |x| b == .boolean and b.boolean == x,
            .number => |x| b == .number and b.number == x,
            .string => |x| b == .string and std.mem.eql(u8, x, b.string),
            .object => |x| b == .object and b.object == x,
            .native_function => |x| b == .native_function and b.native_function == x,
        };
    }

    /// IsLooselyEqual (`==`, §7.2.14).
    pub fn looseEquals(a: Value, b: Value) bool {
        const a_nullish = a == .undefined or a == .null;
        const b_nullish = b == .undefined or b == .null;
        if (a_nullish or b_nullish) {
            return a_nullish and b_nullish;
        }
        if (std.meta.activeTag(a) == std.meta.activeTag(b)) {
            return strictEquals(a, b);
        }
        const a_object = a == .object or a == .native_function;
        const b_object = b == .object or b == .native_function;
        if (a_object and b_object) {
            return false;
        }
        if (a_object) {
            return looseEquals(toPrimitive(a), b);
        }
        if (b_object) {
            return looseEquals(a, toPrimitive(b));
        }
        // Different primitive types: compare as numbers.
        return a.toNumber() == b.toNumber();
    }
};

pub const Object = struct {
    /// Property names in insertion order, which is the order `console.log` prints them in.
    properties: std.StringArrayHashMapUnmanaged(Value) = .empty,
    /// Shown by `console.log`, e.g. `Object [console]`; null for plain objects.
    tag: ?[]const u8 = null,

    pub fn get(this: *const Object, name: []const u8) Value {
        return this.properties.get(name) orelse .undefined;
    }
};

pub const NativeFunction = struct {
    name: []const u8,
    /// What `String(f)` gives, e.g. `function log() { [native code] }`.
    source: []const u8,
    call: *const fn (context: *anyopaque, this: Value, args: []const Value) anyerror!Value,
};

/// Compares two strings by UTF-16 code units, which is how `<` orders strings in JS. Plain byte
/// order differs only when one side has a code point above U+FFFF and the other is in
/// U+E000..U+FFFF.
pub fn compareStrings(a: []const u8, b: []const u8) std.math.Order {
    var ai: usize = 0;
    var bi: usize = 0;
    var a_pending: ?u16 = null;
    var b_pending: ?u16 = null;
    while (true) {
        const x = nextUnit(a, &ai, &a_pending) orelse return if (nextUnit(b, &bi, &b_pending) == null) .eq else .lt;
        const y = nextUnit(b, &bi, &b_pending) orelse return .gt;
        if (x != y) {
            return std.math.order(x, y);
        }
    }
}

fn nextUnit(s: []const u8, i: *usize, pending: *?u16) ?u16 {
    if (pending.*) |low| {
        pending.* = null;
        return low;
    }
    if (i.* >= s.len) {
        return null;
    }
    const len = std.unicode.utf8ByteSequenceLength(s[i.*]) catch {
        i.* += 1;
        return 0xFFFD;
    };
    const end = @min(i.* + len, s.len);
    const code_point = std.unicode.wtf8Decode(s[i.*..end]) catch 0xFFFD;
    i.* = end;
    if (code_point < 0x10000) {
        return @intCast(code_point);
    }
    const offset = code_point - 0x10000;
    pending.* = @intCast(0xDC00 + (offset & 0x3FF));
    return @intCast(0xD800 + (offset >> 10));
}

/// ToInt32 (§7.1.6).
pub fn toInt32(n: f64) i32 {
    return @bitCast(toUint32(n));
}

/// ToUint32 (§7.1.7): truncate, then wrap modulo 2^32.
pub fn toUint32(n: f64) u32 {
    if (std.math.isNan(n) or std.math.isInf(n)) {
        return 0;
    }
    const truncated = @trunc(n);
    const wrapped = @mod(truncated, 4294967296.0);
    return @intFromFloat(wrapped);
}

/// Number::exponentiate (§6.1.6.1.3), which differs from C's `pow` for a base of ±1 with an
/// infinite or NaN exponent.
pub fn exponentiate(base: f64, exponent: f64) f64 {
    if (std.math.isNan(exponent)) {
        return std.math.nan(f64);
    }
    if (exponent == 0) {
        return 1;
    }
    if (@abs(base) == 1 and std.math.isInf(exponent)) {
        return std.math.nan(f64);
    }
    return std.math.pow(f64, base, exponent);
}

// Formatting like node's `util.inspect`, used by `console.log` and the REPL.

pub fn inspect(writer: *std.Io.Writer, value: Value) std.Io.Writer.Error!void {
    switch (value) {
        .undefined => try writer.writeAll("undefined"),
        .null => try writer.writeAll("null"),
        .boolean => |b| try writer.writeAll(if (b) "true" else "false"),
        // `util.inspect` shows the sign of zero, unlike `String(-0)`.
        .number => |n| if (n == 0 and std.math.signbit(n)) try writer.writeAll("-0") else try number.format(writer, n),
        .string => |s| try quoteString(writer, s),
        .native_function => |f| try writer.print("[Function: {s}]", .{f.name}),
        .object => |o| {
            if (o.tag) |tag| {
                try writer.print("{s} ", .{tag});
            }
            if (o.properties.count() == 0) {
                return writer.writeAll("{}");
            }
            try writer.writeAll("{ ");
            var it = o.properties.iterator();
            var first = true;
            while (it.next()) |entry| {
                if (!first) {
                    try writer.writeAll(", ");
                }
                first = false;
                try writer.print("{s}: ", .{entry.key_ptr.*});
                try inspect(writer, entry.value_ptr.*);
            }
            try writer.writeAll(" }");
        },
    }
}

/// Quotes like node: single quotes unless the string contains them, then double quotes, then
/// backticks.
fn quoteString(writer: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    const has_single = std.mem.indexOfScalar(u8, s, '\'') != null;
    const has_double = std.mem.indexOfScalar(u8, s, '"') != null;
    const has_backtick = std.mem.indexOfScalar(u8, s, '`') != null;
    const quote: u8 = if (!has_single) '\'' else if (!has_double) '"' else if (!has_backtick) '`' else '\'';
    try writer.writeByte(quote);
    for (s) |c| {
        switch (c) {
            '\n' => try writer.writeAll("\\n"),
            '\t' => try writer.writeAll("\\t"),
            '\r' => try writer.writeAll("\\r"),
            0x08 => try writer.writeAll("\\b"),
            0x0C => try writer.writeAll("\\f"),
            0x0B => try writer.writeAll("\\v"),
            '\\' => try writer.writeAll("\\\\"),
            else => if (c == quote) {
                try writer.writeByte('\\');
                try writer.writeByte(c);
            } else if (c < 0x20 or c == 0x7F) {
                try writer.print("\\x{X:0>2}", .{c});
            } else try writer.writeByte(c),
        }
    }
    try writer.writeByte(quote);
}

const testing = std.testing;

test "conversions" {
    try testing.expect(std.math.isNan((Value{ .undefined = {} }).toNumber()));
    try testing.expectEqual(@as(f64, 0), (Value{ .null = {} }).toNumber());
    try testing.expectEqual(@as(f64, 12), (Value{ .string = " 12 " }).toNumber());
    try testing.expect(!(Value{ .string = "" }).toBoolean());
    try testing.expect(!(Value{ .number = std.math.nan(f64) }).toBoolean());
    try testing.expect((Value{ .string = "0" }).toBoolean());
}

test "equality" {
    const null_value: Value = .null;
    const undefined_value: Value = .undefined;
    try testing.expect(null_value.looseEquals(undefined_value));
    try testing.expect(!null_value.strictEquals(undefined_value));
    try testing.expect((Value{ .number = 1 }).looseEquals(.{ .string = "1" }));
    try testing.expect((Value{ .boolean = true }).looseEquals(.{ .number = 1 }));
    try testing.expect(!(Value{ .number = 0 }).looseEquals(.null));
    const nan: Value = .{ .number = std.math.nan(f64) };
    try testing.expect(!nan.strictEquals(nan));
}

test compareStrings {
    try testing.expectEqual(std.math.Order.lt, compareStrings("a", "b"));
    try testing.expectEqual(std.math.Order.lt, compareStrings("a", "ab"));
    try testing.expectEqual(std.math.Order.eq, compareStrings("abc", "abc"));
    // U+1F600 is the surrogate pair D83D DE00, which sorts before U+FF5E.
    try testing.expectEqual(std.math.Order.lt, compareStrings("\u{1F600}", "\u{FF5E}"));
}

test "int conversions" {
    try testing.expectEqual(@as(i32, -1), toInt32(4294967295));
    try testing.expectEqual(@as(i32, 1), toInt32(4294967297));
    try testing.expectEqual(@as(i32, -2), toInt32(-2.7));
    try testing.expectEqual(@as(u32, 4294967295), toUint32(-1));
    try testing.expectEqual(@as(i32, 0), toInt32(std.math.inf(f64)));
}

test exponentiate {
    try testing.expect(std.math.isNan(exponentiate(1, std.math.inf(f64))));
    try testing.expectEqual(@as(f64, 1), exponentiate(std.math.nan(f64), 0));
    try testing.expectEqual(@as(f64, 8), exponentiate(2, 3));
}

test inspect {
    var buffer: [128]u8 = undefined;
    const cases = [_]struct { Value, []const u8 }{
        .{ .{ .string = "hi" }, "'hi'" },
        .{ .{ .string = "it's" }, "\"it's\"" },
        .{ .{ .string = "a\nb" }, "'a\\nb'" },
        .{ .{ .number = -0.0 }, "-0" },
        .{ .{ .number = 1.5 }, "1.5" },
        .{ .undefined, "undefined" },
    };
    for (cases) |case| {
        var writer: std.Io.Writer = .fixed(&buffer);
        try inspect(&writer, case[0]);
        try testing.expectEqualStrings(case[1], writer.buffered());
    }
}
