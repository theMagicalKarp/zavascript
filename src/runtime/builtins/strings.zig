//! `String` and `String.prototype`. Strings are WTF-8, but their indices and lengths count UTF-16
//! code units, as in JavaScript: a string that isn't all ASCII is worked on as code units.

const std = @import("std");
const native = @import("native.zig");
const value = @import("../value.zig");
const number = @import("../number.zig");
const iterators = @import("iterators.zig");
const Interpreter = native.Interpreter;
const Value = native.Value;
const Error = native.Error;
const arg = native.arg;

pub const methods: native.Table = .initComptime(.{
    .{ "toString", native.function("toString", 0, valueOf) },
    .{ "valueOf", native.function("valueOf", 0, valueOf) },
    .{ "charAt", native.function("charAt", 1, charAt) },
    .{ "charCodeAt", native.function("charCodeAt", 1, charCodeAt) },
    .{ "codePointAt", native.function("codePointAt", 1, codePointAt) },
    .{ "at", native.function("at", 1, at_) },
    .{ "concat", native.function("concat", 1, concat) },
    .{ "indexOf", native.function("indexOf", 1, indexOf) },
    .{ "lastIndexOf", native.function("lastIndexOf", 1, lastIndexOf) },
    .{ "includes", native.function("includes", 1, includes) },
    .{ "startsWith", native.function("startsWith", 1, startsWith) },
    .{ "endsWith", native.function("endsWith", 1, endsWith) },
    .{ "slice", native.function("slice", 2, slice) },
    .{ "substring", native.function("substring", 2, substring) },
    .{ "substr", native.function("substr", 2, substr) },
    .{ "split", native.function("split", 2, split) },
    .{ "toLowerCase", native.function("toLowerCase", 0, toLowerCase) },
    .{ "toUpperCase", native.function("toUpperCase", 0, toUpperCase) },
    .{ "trim", native.function("trim", 0, trim) },
    .{ "trimStart", native.function("trimStart", 0, trimStart) },
    .{ "trimEnd", native.function("trimEnd", 0, trimEnd) },
    .{ "padStart", native.function("padStart", 1, padStart) },
    .{ "padEnd", native.function("padEnd", 1, padEnd) },
    .{ "repeat", native.function("repeat", 1, repeat) },
    .{ "replace", native.function("replace", 2, replace) },
    .{ "replaceAll", native.function("replaceAll", 2, replaceAll) },
    .{ "[Symbol.iterator]", native.function("[Symbol.iterator]", 0, iterator) },
});

pub const statics: native.Table = .initComptime(.{
    .{ "fromCharCode", native.function("fromCharCode", 1, fromCharCode) },
    .{ "fromCodePoint", native.function("fromCodePoint", 1, fromCodePoint) },
});

pub const constructor = native.constructor("String", 1, call, null, &statics, true);

/// `String(value)`.
fn call(it: *Interpreter, _: Value, args: []const Value) Error!Value {
    if (args.len == 0) {
        return .{ .string = "" };
    }
    return .{ .string = try args[0].toString(it.arena) };
}

fn isAscii(s: []const u8) bool {
    for (s) |c| {
        if (c >= 0x80) {
            return false;
        }
    }
    return true;
}

/// How many UTF-16 code units `s` is.
pub fn length(s: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        const len: usize = if (c < 0x80) 1 else if (c < 0xE0) 2 else if (c < 0xF0) 3 else 4;
        n += if (len == 4) 2 else 1;
        i += len;
    }
    return n;
}

/// `s.length`. Like `Text.of`, it remembers a long string's, so a loop like `i < s.length` doesn't
/// scan all of `s` each time round.
pub fn lengthOf(it: *Interpreter, s: []const u8) usize {
    const cache = &it.builtin_state.length;
    if (s.ptr == cache.bytes.ptr and s.len == cache.bytes.len) {
        return cache.units;
    }
    const n = length(s);
    if (s.len >= Text.cached_length) {
        cache.* = .{ .bytes = s, .units = n };
    }
    return n;
}

/// `s[i]`: the code unit at `i` as a string, or `undefined` past the end.
pub fn at(it: *Interpreter, s: []const u8, i: usize) Error!Value {
    const t = try Text.of(it, s);
    if (i >= t.len()) {
        return .undefined;
    }
    return .{ .string = try t.slice(it, i, i + 1) };
}

/// A string as code units, without converting it when it's all ASCII.
pub const Text = struct {
    bytes: []const u8,
    /// Null when the string is ASCII, so a byte is a code unit.
    units: ?[]const u16,

    /// Strings at least this long are remembered, so a loop like `s.charCodeAt(i)` doesn't
    /// convert (or scan) all of `s` each time round. Shorter ones, like a needle, aren't, so they
    /// don't push it out.
    pub const cached_length = 256;

    fn of(it: *Interpreter, s: []const u8) Error!Text {
        // Strings never change, and the arena never frees one, so where one is and its length
        // identify it.
        const cache = &it.builtin_state.text;
        if (s.ptr == cache.bytes.ptr and s.len == cache.bytes.len) {
            return cache.*;
        }
        const t: Text = .{ .bytes = s, .units = if (isAscii(s)) null else try toUnits(it.arena, s) };
        if (s.len >= cached_length) {
            cache.* = t;
        }
        return t;
    }

    fn len(this: Text) usize {
        return if (this.units) |u| u.len else this.bytes.len;
    }

    fn unit(this: Text, i: usize) u16 {
        return if (this.units) |u| u[i] else this.bytes[i];
    }

    fn slice(this: Text, it: *Interpreter, start: usize, end: usize) Error![]const u8 {
        if (start >= end) {
            return "";
        }
        if (this.units) |u| {
            return fromUnits(it.arena, u[start..end]);
        }
        return this.bytes[start..end];
    }

    fn matchesAt(this: Text, needle: Text, i: usize) bool {
        if (i + needle.len() > this.len()) {
            return false;
        }
        for (0..needle.len()) |j| {
            if (this.unit(i + j) != needle.unit(j)) {
                return false;
            }
        }
        return true;
    }

    fn indexOf(this: Text, needle: Text, from: usize) ?usize {
        if (this.units == null and needle.units == null) {
            return std.mem.indexOfPos(u8, this.bytes, from, needle.bytes);
        }
        var i = from;
        while (i + needle.len() <= this.len()) : (i += 1) {
            if (this.matchesAt(needle, i)) {
                return i;
            }
        }
        return null;
    }
};

/// WTF-8 to UTF-16.
pub fn toUnits(allocator: std.mem.Allocator, s: []const u8) error{OutOfMemory}![]u16 {
    var units: std.ArrayList(u16) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        const end = @min(i + len, s.len);
        const code_point = std.unicode.wtf8Decode(s[i..end]) catch 0xFFFD;
        i = end;
        if (code_point >= 0x10000) {
            const offset = code_point - 0x10000;
            try units.appendSlice(allocator, &.{ @intCast(0xD800 + (offset >> 10)), @intCast(0xDC00 + (offset & 0x3FF)) });
        } else {
            try units.append(allocator, @intCast(code_point));
        }
    }
    return units.items;
}

/// UTF-16 to WTF-8: a surrogate pair is one code point, a lone surrogate stays one.
pub fn fromUnits(allocator: std.mem.Allocator, units: []const u16) error{OutOfMemory}![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < units.len) : (i += 1) {
        var code_point: u21 = units[i];
        if (code_point >= 0xD800 and code_point <= 0xDBFF and i + 1 < units.len and units[i + 1] >= 0xDC00 and units[i + 1] <= 0xDFFF) {
            code_point = 0x10000 + ((code_point - 0xD800) << 10) + (units[i + 1] - 0xDC00);
            i += 1;
        }
        var buffer: [4]u8 = undefined;
        const n = std.unicode.wtf8Encode(code_point, &buffer) catch unreachable;
        try out.appendSlice(allocator, buffer[0..n]);
    }
    return out.items;
}

/// `this` as a string. Only `any` can call these with something else, which is converted.
fn thisString(it: *Interpreter, this: Value) Error![]const u8 {
    return switch (this) {
        .string => |s| s,
        .undefined, .null => it.throw(.TypeError, "String.prototype method called on null or undefined", .{}),
        else => this.toString(it.arena),
    };
}

fn valueOf(it: *Interpreter, this: Value, _: []const Value) Error!Value {
    return .{ .string = try thisString(it, this) };
}

/// A position argument, clamped to 0..len.
fn position(v: Value, len: usize) usize {
    const n = native.integer(v);
    return @intFromFloat(std.math.clamp(n, 0, @as(f64, @floatFromInt(len))));
}

fn charAt(it: *Interpreter, this: Value, args: []const Value) Error!Value {
    const t = try Text.of(it, try thisString(it, this));
    const n = native.integer(arg(args, 0));
    if (n < 0 or n >= @as(f64, @floatFromInt(t.len()))) {
        return .{ .string = "" };
    }
    const i: usize = @intFromFloat(n);
    return .{ .string = try t.slice(it, i, i + 1) };
}

fn charCodeAt(it: *Interpreter, this: Value, args: []const Value) Error!Value {
    const t = try Text.of(it, try thisString(it, this));
    const n = native.integer(arg(args, 0));
    if (n < 0 or n >= @as(f64, @floatFromInt(t.len()))) {
        return native.number(std.math.nan(f64));
    }
    return native.number(t.unit(@intFromFloat(n)));
}

fn codePointAt(it: *Interpreter, this: Value, args: []const Value) Error!Value {
    const t = try Text.of(it, try thisString(it, this));
    const n = native.integer(arg(args, 0));
    if (n < 0 or n >= @as(f64, @floatFromInt(t.len()))) {
        return .undefined;
    }
    const i: usize = @intFromFloat(n);
    const first = t.unit(i);
    if (first >= 0xD800 and first <= 0xDBFF and i + 1 < t.len()) {
        const second = t.unit(i + 1);
        if (second >= 0xDC00 and second <= 0xDFFF) {
            return native.number(0x10000 + ((@as(u32, first) - 0xD800) << 10) + (second - 0xDC00));
        }
    }
    return native.number(first);
}

fn at_(it: *Interpreter, this: Value, args: []const Value) Error!Value {
    const t = try Text.of(it, try thisString(it, this));
    const n = native.integer(arg(args, 0));
    const len: f64 = @floatFromInt(t.len());
    const k = if (n < 0) len + n else n;
    if (k < 0 or k >= len) {
        return .undefined;
    }
    const i: usize = @intFromFloat(k);
    return .{ .string = try t.slice(it, i, i + 1) };
}

fn concat(it: *Interpreter, this: Value, args: []const Value) Error!Value {
    const parts = try it.arena.alloc([]const u8, args.len + 1);
    parts[0] = try thisString(it, this);
    for (args, parts[1..]) |a, *p| {
        p.* = try a.toString(it.arena);
    }
    return .{ .string = try value.concatStrings(it.arena, parts) };
}

fn indexOf(it: *Interpreter, this: Value, args: []const Value) Error!Value {
    const t = try Text.of(it, try thisString(it, this));
    const needle = try Text.of(it, try arg(args, 0).toString(it.arena));
    const start = position(arg(args, 1), t.len());
    const found = t.indexOf(needle, start) orelse return native.number(-1);
    return native.number(found);
}

fn lastIndexOf(it: *Interpreter, this: Value, args: []const Value) Error!Value {
    const t = try Text.of(it, try thisString(it, this));
    const needle = try Text.of(it, try arg(args, 0).toString(it.arena));
    const n = arg(args, 1).toNumber();
    const len = t.len();
    const from: usize = if (std.math.isNan(n)) len else position(arg(args, 1), len);
    if (needle.len() > len) {
        return native.number(-1);
    }
    var i = @min(from, len - needle.len());
    while (true) {
        if (t.matchesAt(needle, i)) {
            return native.number(i);
        }
        if (i == 0) {
            return native.number(-1);
        }
        i -= 1;
    }
}

fn includes(it: *Interpreter, this: Value, args: []const Value) Error!Value {
    const t = try Text.of(it, try thisString(it, this));
    const needle = try Text.of(it, try arg(args, 0).toString(it.arena));
    return .{ .boolean = t.indexOf(needle, position(arg(args, 1), t.len())) != null };
}

fn startsWith(it: *Interpreter, this: Value, args: []const Value) Error!Value {
    const t = try Text.of(it, try thisString(it, this));
    const needle = try Text.of(it, try arg(args, 0).toString(it.arena));
    return .{ .boolean = t.matchesAt(needle, position(arg(args, 1), t.len())) };
}

fn endsWith(it: *Interpreter, this: Value, args: []const Value) Error!Value {
    const t = try Text.of(it, try thisString(it, this));
    const needle = try Text.of(it, try arg(args, 0).toString(it.arena));
    const end = if (arg(args, 1) == .undefined) t.len() else position(arg(args, 1), t.len());
    if (needle.len() > end) {
        return .{ .boolean = false };
    }
    return .{ .boolean = t.matchesAt(needle, end - needle.len()) };
}

fn slice(it: *Interpreter, this: Value, args: []const Value) Error!Value {
    const t = try Text.of(it, try thisString(it, this));
    const start = native.relative(arg(args, 0), t.len(), 0);
    const end = native.relative(arg(args, 1), t.len(), t.len());
    return .{ .string = try t.slice(it, start, end) };
}

fn substring(it: *Interpreter, this: Value, args: []const Value) Error!Value {
    const t = try Text.of(it, try thisString(it, this));
    const a = position(arg(args, 0), t.len());
    const b = if (arg(args, 1) == .undefined) t.len() else position(arg(args, 1), t.len());
    return .{ .string = try t.slice(it, @min(a, b), @max(a, b)) };
}

fn substr(it: *Interpreter, this: Value, args: []const Value) Error!Value {
    const t = try Text.of(it, try thisString(it, this));
    const start = native.relative(arg(args, 0), t.len(), 0);
    const count: f64 = if (arg(args, 1) == .undefined) std.math.inf(f64) else native.integer(arg(args, 1));
    const end: usize = @intFromFloat(std.math.clamp(@as(f64, @floatFromInt(start)) + count, @as(f64, @floatFromInt(start)), @as(f64, @floatFromInt(t.len()))));
    return .{ .string = try t.slice(it, start, end) };
}

fn split(it: *Interpreter, this: Value, args: []const Value) Error!Value {
    const s = try thisString(it, this);
    const limit: u32 = if (arg(args, 1) == .undefined) std.math.maxInt(u32) else value.toUint32(arg(args, 1).toNumber());
    var parts: std.ArrayList(Value) = .empty;
    if (arg(args, 0) == .undefined) {
        if (limit > 0) {
            try parts.append(it.arena, .{ .string = s });
        }
        return it.newArray(parts.items);
    }
    const t = try Text.of(it, s);
    const separator = try Text.of(it, try args[0].toString(it.arena));
    if (limit == 0) {
        return it.newArray(&.{});
    }
    if (separator.len() == 0) {
        // Each code unit on its own.
        for (0..t.len()) |i| {
            if (parts.items.len == limit) {
                break;
            }
            try parts.append(it.arena, .{ .string = try t.slice(it, i, i + 1) });
        }
        return it.newArray(parts.items);
    }
    var start: usize = 0;
    while (t.indexOf(separator, start)) |found| {
        try parts.append(it.arena, .{ .string = try t.slice(it, start, found) });
        if (parts.items.len == limit) {
            return it.newArray(parts.items);
        }
        start = found + separator.len();
    }
    try parts.append(it.arena, .{ .string = try t.slice(it, start, t.len()) });
    return it.newArray(parts.items);
}

/// Whether a non-ASCII code point has no case, so changing case leaves it alone. Others outside
/// Latin-1 need Unicode's case mappings, which we don't have yet.
fn caseless(code_point: u21) bool {
    return switch (code_point) {
        0x80...0xBF, 0xD7, 0xF7, 0x2000...0x2BFF, 0x3000...0x9FFF, 0xAC00...0xD7FF, 0xE000...0xF8FF, 0xFE00...0xFE6F, 0x1F000...0x1FBFF => true,
        else => false,
    };
}

/// A Latin-1 letter in the other case, which `ß` uppercases to two of. Null for anything else,
/// except for `Ÿ`, `Μ` and `μ`, which uppercasing a Latin-1 letter can make.
fn latin1Case(code_point: u21, upper: bool) ?[]const u21 {
    const S = struct {
        const sharp_s = [_]u21{ 'S', 'S' };
        const y_diaeresis = [_]u21{0x178};
        const micro = [_]u21{0x39C};
        const small_y_diaeresis = [_]u21{0xFF};
        const small_mu = [_]u21{0x3BC};
        var single: [1]u21 = undefined;
    };
    if (upper) {
        switch (code_point) {
            0xDF => return &S.sharp_s,
            0xFF => return &S.y_diaeresis,
            0xB5, 0x3BC => return &S.micro,
            0xE0...0xF6, 0xF8...0xFE => {
                S.single[0] = code_point - 0x20;
                return &S.single;
            },
            0xC0...0xD6, 0xD8...0xDE, 0x178, 0x39C => return &.{},
            else => return null,
        }
    }
    switch (code_point) {
        0xC0...0xD6, 0xD8...0xDE => {
            S.single[0] = code_point + 0x20;
            return &S.single;
        },
        0x178 => return &S.small_y_diaeresis,
        0x39C => return &S.small_mu,
        0xDF, 0xE0...0xF6, 0xF8...0xFF, 0xB5, 0x3BC => return &.{},
        else => return null,
    }
}

fn changeCase(it: *Interpreter, this: Value, comptime upper: bool) Error!Value {
    const s = try thisString(it, this);
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(it.arena, s.len);
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c < 0x80) {
            try out.append(it.arena, if (upper) std.ascii.toUpper(c) else std.ascii.toLower(c));
            i += 1;
            continue;
        }
        const len = std.unicode.utf8ByteSequenceLength(c) catch 1;
        const end = @min(i + len, s.len);
        const code_point = std.unicode.wtf8Decode(s[i..end]) catch 0xFFFD;
        if (latin1Case(code_point, upper)) |mapped| {
            // An empty mapping means it's already in the case asked for.
            if (mapped.len == 0) {
                try out.appendSlice(it.arena, s[i..end]);
            }
            for (mapped) |m| {
                var buffer: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(m, &buffer) catch unreachable;
                try out.appendSlice(it.arena, buffer[0..n]);
            }
        } else if (caseless(code_point)) {
            try out.appendSlice(it.arena, s[i..end]);
        } else {
            return it.throw(.Unsupported, "Changing the case of '{s}' is not supported yet.", .{s});
        }
        i = end;
    }
    return .{ .string = out.items };
}

fn toLowerCase(it: *Interpreter, this: Value, _: []const Value) Error!Value {
    return changeCase(it, this, false);
}

fn toUpperCase(it: *Interpreter, this: Value, _: []const Value) Error!Value {
    return changeCase(it, this, true);
}

fn trimmedStart(s: []const u8) usize {
    var start: usize = 0;
    while (start < s.len) {
        const len = number.whitespaceAt(s[start..]);
        if (len == 0) {
            break;
        }
        start += len;
    }
    return start;
}

fn trim(it: *Interpreter, this: Value, _: []const Value) Error!Value {
    return .{ .string = number.trimWhitespace(try thisString(it, this)) };
}

fn trimStart(it: *Interpreter, this: Value, _: []const Value) Error!Value {
    const s = try thisString(it, this);
    return .{ .string = s[trimmedStart(s)..] };
}

fn trimEnd(it: *Interpreter, this: Value, _: []const Value) Error!Value {
    const s = try thisString(it, this);
    const trimmed = number.trimWhitespace(s);
    if (trimmed.len == 0) {
        return .{ .string = "" };
    }
    // What `trim` keeps ends where `trimEnd` does.
    const start = trimmedStart(s);
    return .{ .string = s[0 .. start + trimmed.len] };
}

fn pad(it: *Interpreter, this: Value, args: []const Value, comptime at_start: bool) Error!Value {
    const s = try thisString(it, this);
    const t = try Text.of(it, s);
    const max_length = native.integer(arg(args, 0));
    if (max_length <= @as(f64, @floatFromInt(t.len()))) {
        return .{ .string = s };
    }
    const fill_string = if (arg(args, 1) == .undefined) " " else try args[1].toString(it.arena);
    if (fill_string.len == 0) {
        return .{ .string = s };
    }
    if (max_length > 536870888) {
        return it.throw(.RangeError, "Invalid string length", .{});
    }
    const fill = try Text.of(it, fill_string);
    const needed: usize = @as(usize, @intFromFloat(max_length)) - t.len();
    var units: std.ArrayList(u16) = .empty;
    for (0..needed) |i| {
        try units.append(it.arena, fill.unit(i % fill.len()));
    }
    const padding = try fromUnits(it.arena, units.items);
    return .{ .string = try value.concatStrings(it.arena, if (at_start) &.{ padding, s } else &.{ s, padding }) };
}

fn padStart(it: *Interpreter, this: Value, args: []const Value) Error!Value {
    return pad(it, this, args, true);
}

fn padEnd(it: *Interpreter, this: Value, args: []const Value) Error!Value {
    return pad(it, this, args, false);
}

fn repeat(it: *Interpreter, this: Value, args: []const Value) Error!Value {
    const s = try thisString(it, this);
    const n = native.integer(arg(args, 0));
    if (n < 0 or std.math.isInf(n)) {
        return it.throw(.RangeError, "Invalid count value: {s}", .{try number.toString(it.arena, arg(args, 0).toNumber())});
    }
    if (s.len == 0 or n == 0) {
        return .{ .string = "" };
    }
    if (@as(f64, @floatFromInt(length(s))) * n > 536870888) {
        return it.throw(.RangeError, "Invalid string length", .{});
    }
    const count: usize = @intFromFloat(n);
    const out = try it.arena.alloc(u8, s.len * count);
    for (0..count) |i| {
        @memcpy(out[i * s.len ..][0..s.len], s);
    }
    return .{ .string = out };
}

/// GetSubstitution (§22.1.3.19.1) for a string pattern, which has no captures.
fn substitution(it: *Interpreter, out: *std.ArrayList(u8), t: Text, matched: []const u8, start: usize, end: usize, replacement: []const u8) Error!void {
    var i: usize = 0;
    while (i < replacement.len) : (i += 1) {
        if (replacement[i] != '$' or i + 1 == replacement.len) {
            try out.append(it.arena, replacement[i]);
            continue;
        }
        switch (replacement[i + 1]) {
            '$' => try out.append(it.arena, '$'),
            '&' => try out.appendSlice(it.arena, matched),
            '`' => try out.appendSlice(it.arena, try t.slice(it, 0, start)),
            '\'' => try out.appendSlice(it.arena, try t.slice(it, end, t.len())),
            else => {
                try out.append(it.arena, '$');
                continue;
            },
        }
        i += 1;
    }
}

fn replaceWith(it: *Interpreter, this: Value, args: []const Value, comptime all: bool) Error!Value {
    const s = try thisString(it, this);
    const t = try Text.of(it, s);
    const search = try Text.of(it, try arg(args, 0).toString(it.arena));
    const replacer = arg(args, 1);
    const functional = replacer == .function or replacer == .native_function;
    const replacement = if (functional) "" else try replacer.toString(it.arena);
    // Where each match is.
    var matches: std.ArrayList(usize) = .empty;
    var from: usize = 0;
    while (from <= t.len()) {
        const found = t.indexOf(search, from) orelse break;
        try matches.append(it.arena, found);
        if (!all) {
            break;
        }
        from = found + @max(search.len(), 1);
    }
    if (matches.items.len == 0) {
        return .{ .string = s };
    }
    var parts: std.ArrayList([]const u8) = .empty;
    var end: usize = 0;
    for (matches.items) |start| {
        try parts.append(it.arena, try t.slice(it, end, start));
        const matched = try t.slice(it, start, start + search.len());
        if (functional) {
            const result = try it.invoke(replacer, .undefined, &.{ .{ .string = matched }, native.number(start), .{ .string = s } });
            try parts.append(it.arena, try result.toString(it.arena));
        } else {
            var out: std.ArrayList(u8) = .empty;
            try substitution(it, &out, t, matched, start, start + search.len(), replacement);
            try parts.append(it.arena, out.items);
        }
        end = start + search.len();
    }
    try parts.append(it.arena, try t.slice(it, end, t.len()));
    return .{ .string = try value.concatStrings(it.arena, parts.items) };
}

fn replace(it: *Interpreter, this: Value, args: []const Value) Error!Value {
    return replaceWith(it, this, args, false);
}

fn replaceAll(it: *Interpreter, this: Value, args: []const Value) Error!Value {
    return replaceWith(it, this, args, true);
}

fn iterator(it: *Interpreter, this: Value, _: []const Value) Error!Value {
    return iterators.toValue(it, try iterators.create(it, .{ .string = try thisString(it, this) }, .values));
}

fn fromCharCode(it: *Interpreter, _: Value, args: []const Value) Error!Value {
    const units = try it.arena.alloc(u16, args.len);
    for (args, units) |a, *u| {
        u.* = @truncate(value.toUint32(a.toNumber()));
    }
    return .{ .string = try fromUnits(it.arena, units) };
}

fn fromCodePoint(it: *Interpreter, _: Value, args: []const Value) Error!Value {
    var units: std.ArrayList(u16) = .empty;
    for (args) |a| {
        const n = a.toNumber();
        if (n != @trunc(n) or n < 0 or n > 0x10FFFF) {
            return it.throw(.RangeError, "Invalid code point {s}", .{try a.toString(it.arena)});
        }
        const code_point: u21 = @intFromFloat(n);
        if (code_point >= 0x10000) {
            const offset = code_point - 0x10000;
            try units.appendSlice(it.arena, &.{ @intCast(0xD800 + (offset >> 10)), @intCast(0xDC00 + (offset & 0x3FF)) });
        } else {
            try units.append(it.arena, @intCast(code_point));
        }
    }
    return .{ .string = try fromUnits(it.arena, units.items) };
}
