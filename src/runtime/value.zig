//! Runtime values and the abstract operations from ECMA-262 that act on them (ToNumber,
//! ToString, ToBoolean, equality, ...).

const std = @import("std");
const number = @import("number.zig");
const ast = @import("../syntax/ast.zig");
const Interpreter = @import("Interpreter.zig");

pub const Value = union(enum) {
    undefined,
    null,
    boolean: bool,
    number: f64,
    /// WTF-8 bytes; see `Lexer.cook`. Immutable and shared freely.
    string: []const u8,
    object: *Object,
    native_function: *const NativeFunction,
    function: *const Closure,
    array: *Array,
    /// What a `let` or `const` holds before its declaration runs (its temporal dead zone).
    /// Reading it is a ReferenceError, so it never gets any further.
    uninitialized,

    pub fn typeOf(this: Value) []const u8 {
        return switch (this) {
            .undefined => "undefined",
            .null => "object",
            .boolean => "boolean",
            .number => "number",
            .string => "string",
            .object, .array => "object",
            .native_function, .function => "function",
            .uninitialized => unreachable,
        };
    }

    fn isObject(this: Value) bool {
        return switch (this) {
            .object, .native_function, .function, .array => true,
            else => false,
        };
    }

    /// ToBoolean (§7.1.2).
    pub fn toBoolean(this: Value) bool {
        return switch (this) {
            .undefined, .null => false,
            .boolean => |b| b,
            .number => |n| !(n == 0 or std.math.isNan(n)),
            .string => |s| s.len > 0,
            .object, .native_function, .function, .array => true,
            .uninitialized => unreachable,
        };
    }

    /// ToNumber (§7.1.4).
    pub inline fn toNumber(this: Value) f64 {
        return switch (this) {
            .undefined => std.math.nan(f64),
            .null => 0,
            .boolean => |b| if (b) 1 else 0,
            .number => |n| n,
            .string => |s| number.parseString(s),
            // Their string forms never parse as numbers.
            .object, .native_function, .function => std.math.nan(f64),
            .array => |a| arrayToNumber(a),
            .uninitialized => unreachable,
        };
    }

    /// An array's string form joins its elements with commas, so it's a number only with a single
    /// element (`+[5]`) or none (`+[]` is 0).
    noinline fn arrayToNumber(a: *const Array) f64 {
        return switch (a.items.len) {
            0 => 0,
            1 => switch (a.items[0]) {
                .undefined, .null => 0,
                // Through `String()` and back, which makes -0 into 0.
                .number => |n| if (n == 0) 0 else n,
                else => |v| v.toNumber(),
            },
            else => std.math.nan(f64),
        };
    }

    /// ToPrimitive (§7.1.1). There are no user-defined `valueOf`/`toString` methods yet, so every
    /// object becomes its default string.
    pub fn toPrimitive(this: Value, allocator: std.mem.Allocator) error{OutOfMemory}!Value {
        return switch (this) {
            .object => .{ .string = "[object Object]" },
            .native_function => |f| .{ .string = f.source },
            .function => |f| .{ .string = try f.sourceText(allocator) },
            .array => |a| .{ .string = try a.join(allocator) },
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
            .object, .native_function, .function, .array => (try this.toPrimitive(allocator)).toString(allocator),
            .uninitialized => unreachable,
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
            .function => |x| b == .function and b.function == x,
            .array => |x| b == .array and b.array == x,
            .uninitialized => unreachable,
        };
    }

    /// IsLooselyEqual (`==`, §7.2.14).
    pub fn looseEquals(a: Value, b: Value, allocator: std.mem.Allocator) error{OutOfMemory}!bool {
        const a_nullish = a == .undefined or a == .null;
        const b_nullish = b == .undefined or b == .null;
        if (a_nullish or b_nullish) {
            return a_nullish and b_nullish;
        }
        if (std.meta.activeTag(a) == std.meta.activeTag(b)) {
            return strictEquals(a, b);
        }
        const a_object = a.isObject();
        const b_object = b.isObject();
        if (a_object and b_object) {
            return false;
        }
        if (a_object) {
            return looseEquals(try a.toPrimitive(allocator), b, allocator);
        }
        if (b_object) {
            return looseEquals(a, try b.toPrimitive(allocator), allocator);
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

/// The variables of one scope that closures capture. See `Checker.Ref.env`.
pub const Env = struct {
    parent: ?*Env,
    values: []Value,
};

/// A function value: a function from the source, with the environment it was created in.
pub const Closure = struct {
    function: *const ast.Function,
    env: ?*Env,
    /// The program it's from, whose tables its body's references index.
    program: *const Interpreter.Program,

    pub fn name(this: *const Closure) []const u8 {
        return this.function.inferred_name;
    }

    /// What `String(f)` gives: the function's source, with type annotations replaced by spaces
    /// the way node strips types.
    pub fn sourceText(this: *const Closure, allocator: std.mem.Allocator) error{OutOfMemory}![]const u8 {
        const f = this.function;
        const text = try allocator.dupe(u8, this.program.text[f.start..f.end]);
        for (this.program.ast.type_spans) |span| {
            if (span.start >= f.start and span.end <= f.end) {
                for (text[span.start - f.start .. span.end - f.start]) |*c| {
                    if (c.* != '\n' and c.* != '\r') {
                        c.* = ' ';
                    }
                }
            }
        }
        return text;
    }
};

pub const Array = struct {
    items: []Value,

    /// Array.prototype.join with `,`, which is also what `String(array)` gives.
    pub fn join(this: *const Array, allocator: std.mem.Allocator) error{OutOfMemory}![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (this.items, 0..) |item, i| {
            if (i > 0) {
                try out.append(allocator, ',');
            }
            switch (item) {
                .undefined, .null => {},
                else => try out.appendSlice(allocator, try item.toString(allocator)),
            }
        }
        return out.toOwnedSlice(allocator);
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

pub const InspectError = error{
    WriteFailed,
    OutOfMemory,
    /// Something node formats in a way that isn't implemented yet, like an array of arrays.
    Unsupported,
};

pub fn inspect(allocator: std.mem.Allocator, writer: *std.Io.Writer, value: Value) InspectError!void {
    switch (value) {
        .undefined => try writer.writeAll("undefined"),
        .null => try writer.writeAll("null"),
        .boolean => |b| try writer.writeAll(if (b) "true" else "false"),
        // `util.inspect` shows the sign of zero, unlike `String(-0)`.
        .number => |n| if (n == 0 and std.math.signbit(n)) try writer.writeAll("-0") else try number.format(writer, n),
        .string => |s| try quoteString(writer, s),
        .native_function => |f| try writer.print("[Function: {s}]", .{f.name}),
        .function => |f| if (f.name().len == 0)
            try writer.writeAll("[Function (anonymous)]")
        else
            try writer.print("[Function: {s}]", .{f.name()}),
        .array => |a| try inspectArray(allocator, writer, a),
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
                try inspect(allocator, writer, entry.value_ptr.*);
            }
            try writer.writeAll(" }");
        },
        .uninitialized => unreachable,
    }
}

/// Node's `formatList` for an array of primitives and functions at the top level: on one line if
/// it fits in 80 columns, otherwise one entry per line, or in columns (`groupArrayElements`) when
/// there are more than six.
fn inspectArray(allocator: std.mem.Allocator, writer: *std.Io.Writer, array: *const Array) InspectError!void {
    if (array.items.len == 0) {
        return writer.writeAll("[]");
    }
    const max_length = 100;
    const shown = @min(array.items.len, max_length);
    var entries: std.ArrayList([]const u8) = .empty;
    for (array.items[0..shown]) |item| {
        switch (item) {
            .array, .object => return error.Unsupported,
            // Node splits long strings over several lines.
            .string => |s| if (jsLength(s) > 76) return error.Unsupported,
            else => {},
        }
        var out: std.Io.Writer.Allocating = .init(allocator);
        inspect(allocator, &out.writer, item) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
            else => |e| return e,
        };
        try entries.append(allocator, out.written());
    }
    if (array.items.len > max_length) {
        const more = array.items.len - max_length;
        try entries.append(allocator, try std.fmt.allocPrint(allocator, "... {d} more item{s}", .{ more, if (more > 1) "s" else "" }));
    }
    var output: []const []const u8 = entries.items;
    if (entries.items.len > 6) {
        output = try groupArrayElements(allocator, entries.items, array.items.len > max_length, array.items[0..shown]);
    }
    if (output.len == entries.items.len) {
        // `isBelowBreakLength`, with `start` for the `[` and the `10` node adds.
        var total = output.len + (output.len + 1 + 10);
        for (output) |entry| {
            total += jsLength(entry);
        }
        if (total <= 80) {
            try writer.writeAll("[ ");
            for (output, 0..) |entry, i| {
                if (i > 0) {
                    try writer.writeAll(", ");
                }
                try writer.writeAll(entry);
            }
            return writer.writeAll(" ]");
        }
    }
    try writer.writeAll("[\n  ");
    for (output, 0..) |entry, i| {
        if (i > 0) {
            try writer.writeAll(",\n  ");
        }
        try writer.writeAll(entry);
    }
    try writer.writeAll("\n]");
}

/// Node's `groupArrayElements`: lays short entries out in aligned columns, numbers padded on
/// the left and anything else on the right.
fn groupArrayElements(allocator: std.mem.Allocator, output: []const []const u8, has_more: bool, values: []const Value) error{OutOfMemory}![]const []const u8 {
    const break_length = 80;
    const separator_space = 2;
    const output_length = if (has_more) output.len - 1 else output.len;
    const data_len = try allocator.alloc(usize, output_length);
    var total_length: usize = 0;
    var max_length: usize = 0;
    for (output[0..output_length], data_len) |entry, *len| {
        len.* = jsLength(entry);
        total_length += len.* + separator_space;
        max_length = @max(max_length, len.*);
    }
    const actual_max = max_length + separator_space;
    const total: f64 = @floatFromInt(total_length);
    const actual: f64 = @floatFromInt(actual_max);
    if (!(actual_max * 3 < break_length and (total / actual > 5 or max_length <= 6))) {
        return output;
    }
    const average_bias = @sqrt(actual - total / @as(f64, @floatFromInt(output.len)));
    const biased_max = @max(actual - 3 - average_bias, 1);
    const columns: usize = @intFromFloat(@min(
        @min(@round(@sqrt(2.5 * biased_max * @as(f64, @floatFromInt(output_length))) / biased_max), @floor(@as(f64, break_length) / actual)),
        @min(3 * 4, 15),
    ));
    if (columns <= 1) {
        return output;
    }
    const max_line_length = try allocator.alloc(usize, columns);
    for (max_line_length, 0..) |*line_length, i| {
        line_length.* = 0;
        var j = i;
        while (j < output_length) : (j += columns) {
            line_length.* = @max(line_length.*, data_len[j]);
        }
        line_length.* += separator_space;
    }
    const pad_start = for (values) |v| {
        if (v != .number) {
            break false;
        }
    } else true;
    var rows: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < output_length) : (i += columns) {
        const end = @min(i + columns, output_length);
        var row: std.ArrayList(u8) = .empty;
        for (i..end) |j| {
            const last = j == end - 1;
            const cell = if (last) output[j] else try std.fmt.allocPrint(allocator, "{s}, ", .{output[j]});
            const width = if (last and pad_start) max_line_length[j - i] - separator_space else if (last) 0 else max_line_length[j - i];
            const padding = width -| jsLength(cell);
            if (pad_start) {
                try row.appendNTimes(allocator, ' ', padding);
                try row.appendSlice(allocator, cell);
            } else {
                try row.appendSlice(allocator, cell);
                try row.appendNTimes(allocator, ' ', padding);
            }
        }
        try rows.append(allocator, row.items);
    }
    if (has_more) {
        try rows.append(allocator, output[output_length]);
    }
    return rows.items;
}

/// The length of a string in UTF-16 code units, which is what node measures.
fn jsLength(s: []const u8) usize {
    var length: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        length += if (len == 4) 2 else 1;
        i += len;
    }
    return length;
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
    const a = testing.allocator;
    try testing.expect(try null_value.looseEquals(undefined_value, a));
    try testing.expect(!null_value.strictEquals(undefined_value));
    try testing.expect(try (Value{ .number = 1 }).looseEquals(.{ .string = "1" }, a));
    try testing.expect(try (Value{ .boolean = true }).looseEquals(.{ .number = 1 }, a));
    try testing.expect(!try (Value{ .number = 0 }).looseEquals(.null, a));
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
        try inspect(testing.allocator, &writer, case[0]);
        try testing.expectEqualStrings(case[1], writer.buffered());
    }
}

test "inspect arrays" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { []const f64, []const u8 }{
        .{ &.{}, "[]" },
        .{ &.{ 1, 2, 3, 4, 5, 6 }, "[ 1, 2, 3, 4, 5, 6 ]" },
        .{ &.{ 1, 2, 3, 4, 5, 6, 7 }, "[\n  1, 2, 3, 4,\n  5, 6, 7\n]" },
        .{ &.{ 100000, 2, 3333, 4, 5, 6, 7777777, 8, 9 }, "[ 100000, 2, 3333, 4, 5, 6, 7777777, 8, 9 ]" },
    };
    for (cases) |case| {
        const items = try a.alloc(Value, case[0].len);
        for (items, case[0]) |*item, n| {
            item.* = .{ .number = n };
        }
        var array: Array = .{ .items = items };
        var out: std.Io.Writer.Allocating = .init(a);
        try inspect(a, &out.writer, .{ .array = &array });
        try testing.expectEqualStrings(case[1], out.written());
    }
}
