//! `JSON.parse` and `JSON.stringify`, with V8's error messages.

const std = @import("std");
const native = @import("native.zig");
const value = @import("../value.zig");
const number = @import("../number.zig");
const strings = @import("strings.zig");
const Interpreter = native.Interpreter;
const Value = native.Value;
const Error = native.Error;
const arg = native.arg;

pub const members: native.Table = .initComptime(.{
    .{ "parse", native.function("parse", 2, parse) },
    .{ "stringify", native.function("stringify", 3, stringify) },
});

// Stringifying

const Stringifier = struct {
    it: *Interpreter,
    replacer: Value = .undefined,
    /// The property names a replacer array allows, in its order.
    allowed: ?[]const []const u8 = null,
    gap: []const u8 = "",
    indent: std.ArrayList(u8) = .empty,
    /// The objects and arrays being serialized, outermost first, with the key each was reached by.
    stack: std.ArrayList(struct { ptr: *const anyopaque, key: []const u8, array: bool }) = .empty,

    /// SerializeJSONProperty (§25.5.2.2): null when the value is left out.
    fn property(this: *Stringifier, out: *std.ArrayList(u8), holder: Value, key: []const u8, given: Value) Error!bool {
        const it = this.it;
        try it.checkStack();
        var v = given;
        if (v == .object or v == .array) {
            const to_json = try it.getNamed(v, "toJSON");
            if (to_json == .function or to_json == .native_function) {
                v = try it.invoke(to_json, v, &.{.{ .string = key }});
            }
        }
        if (this.replacer != .undefined) {
            v = try it.invoke(this.replacer, holder, &.{ .{ .string = key }, v });
        }
        switch (v) {
            .null => try out.appendSlice(it.arena, "null"),
            .boolean => |b| try out.appendSlice(it.arena, if (b) "true" else "false"),
            .string => |s| try quote(it, out, s),
            .number => |n| try out.appendSlice(it.arena, if (std.math.isFinite(n)) try number.toString(it.arena, n) else "null"),
            .array => |a| try this.array(out, a, key),
            .object => |o| try this.object(out, o, key),
            .undefined, .function, .native_function => return false,
            .uninitialized => unreachable,
        }
        return true;
    }

    fn enter(this: *Stringifier, ptr: *const anyopaque, key: []const u8, is_array: bool) Error!void {
        for (this.stack.items, 0..) |entry, i| {
            if (entry.ptr == ptr) {
                return this.circular(i, key);
            }
        }
        try this.stack.append(this.it.arena, .{ .ptr = ptr, .key = key, .array = is_array });
    }

    /// V8's TypeError for a cycle, which traces it from where it starts.
    fn circular(this: *Stringifier, start: usize, key: []const u8) Error {
        const it = this.it;
        var message: std.ArrayList(u8) = .empty;
        const items = this.stack.items;
        try message.print(it.arena, "Converting circular structure to JSON\n    --> starting at object with constructor '{s}'", .{constructorName(items[start].array)});
        for (items[start + 1 ..]) |entry| {
            try message.print(it.arena, "\n    |     {s} -> object with constructor '{s}'", .{ try describeKey(it, entry.key), constructorName(entry.array) });
        }
        try message.print(it.arena, "\n    --- {s} closes the circle", .{try describeKey(it, key)});
        return it.throw(.TypeError, "{s}", .{message.items});
    }

    fn constructorName(is_array: bool) []const u8 {
        return if (is_array) "Array" else "Object";
    }

    fn describeKey(it: *Interpreter, key: []const u8) Error![]const u8 {
        if (value.arrayIndex(key) != null) {
            return std.fmt.allocPrint(it.arena, "index {s}", .{key});
        }
        return std.fmt.allocPrint(it.arena, "property '{s}'", .{key});
    }

    fn object(this: *Stringifier, out: *std.ArrayList(u8), o: *value.Object, key: []const u8) Error!void {
        const it = this.it;
        try this.enter(o, key, false);
        defer _ = this.stack.pop();
        const stepback = this.indent.items.len;
        try this.indent.appendSlice(it.arena, this.gap);
        defer this.indent.shrinkRetainingCapacity(stepback);
        const holder: Value = .{ .object = o };
        const names = this.allowed orelse try it.ownKeys(holder);
        var written: usize = 0;
        try out.append(it.arena, '{');
        for (names) |name| {
            if (this.allowed != null and !o.properties.contains(name)) {
                continue;
            }
            var member: std.ArrayList(u8) = .empty;
            if (!try this.property(&member, holder, name, o.get(name))) {
                continue;
            }
            if (written > 0) {
                try out.append(it.arena, ',');
            }
            try this.newline(out);
            try quote(it, out, name);
            try out.append(it.arena, ':');
            if (this.gap.len > 0) {
                try out.append(it.arena, ' ');
            }
            try out.appendSlice(it.arena, member.items);
            written += 1;
        }
        this.indent.shrinkRetainingCapacity(stepback);
        if (written > 0) {
            try this.newline(out);
        }
        try out.append(it.arena, '}');
    }

    fn array(this: *Stringifier, out: *std.ArrayList(u8), a: *value.Array, key: []const u8) Error!void {
        const it = this.it;
        try this.enter(a, key, true);
        defer _ = this.stack.pop();
        const stepback = this.indent.items.len;
        try this.indent.appendSlice(it.arena, this.gap);
        defer this.indent.shrinkRetainingCapacity(stepback);
        try out.append(it.arena, '[');
        const holder: Value = .{ .array = a };
        var i: usize = 0;
        while (i < a.items().len) : (i += 1) {
            if (i > 0) {
                try out.append(it.arena, ',');
            }
            try this.newline(out);
            const index = try std.fmt.allocPrint(it.arena, "{d}", .{i});
            if (!try this.property(out, holder, index, a.items()[i])) {
                try out.appendSlice(it.arena, "null");
            }
        }
        const empty = a.items().len == 0;
        this.indent.shrinkRetainingCapacity(stepback);
        if (!empty) {
            try this.newline(out);
        }
        try out.append(it.arena, ']');
    }

    fn newline(this: *Stringifier, out: *std.ArrayList(u8)) Error!void {
        if (this.gap.len > 0) {
            try out.append(this.it.arena, '\n');
            try out.appendSlice(this.it.arena, this.indent.items);
        }
    }
};

/// QuoteJSONString (§25.5.2.3), escaping lone surrogates so the result is well-formed.
fn quote(it: *Interpreter, out: *std.ArrayList(u8), s: []const u8) Error!void {
    try out.append(it.arena, '"');
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        switch (c) {
            '"' => try out.appendSlice(it.arena, "\\\""),
            '\\' => try out.appendSlice(it.arena, "\\\\"),
            0x08 => try out.appendSlice(it.arena, "\\b"),
            0x0C => try out.appendSlice(it.arena, "\\f"),
            '\n' => try out.appendSlice(it.arena, "\\n"),
            '\r' => try out.appendSlice(it.arena, "\\r"),
            '\t' => try out.appendSlice(it.arena, "\\t"),
            else => {
                if (c < 0x20) {
                    try out.print(it.arena, "\\u{x:0>4}", .{c});
                } else if (c == 0xED and i + 2 < s.len and s[i + 1] >= 0xA0) {
                    // A lone surrogate, which WTF-8 has as three bytes.
                    const code_point = std.unicode.wtf8Decode(s[i .. i + 3]) catch 0xFFFD;
                    try out.print(it.arena, "\\u{x:0>4}", .{code_point});
                    i += 3;
                    continue;
                } else {
                    try out.append(it.arena, c);
                }
            },
        }
        i += 1;
    }
    try out.append(it.arena, '"');
}

fn stringify(it: *Interpreter, _: Value, args: []const Value) Error!Value {
    var s: Stringifier = .{ .it = it };
    const replacer = arg(args, 1);
    switch (replacer) {
        .function, .native_function => s.replacer = replacer,
        .array => |a| {
            var allowed: std.ArrayList([]const u8) = .empty;
            for (a.items()) |item| {
                const name = switch (item) {
                    .string => |str| str,
                    .number => try item.toString(it.arena),
                    else => continue,
                };
                const seen = for (allowed.items) |existing| {
                    if (std.mem.eql(u8, existing, name)) {
                        break true;
                    }
                } else false;
                if (!seen) {
                    try allowed.append(it.arena, name);
                }
            }
            s.allowed = allowed.items;
        },
        else => {},
    }
    switch (arg(args, 2)) {
        .number => {
            const n = @min(10, native.integer(args[2]));
            if (n >= 1) {
                const gap = try it.arena.alloc(u8, @intFromFloat(n));
                @memset(gap, ' ');
                s.gap = gap;
            }
        },
        .string => |str| s.gap = str[0..@min(str.len, 10)],
        else => {},
    }
    const wrapper = try native.object(it, &.{.{ "", arg(args, 0) }});
    var out: std.ArrayList(u8) = .empty;
    if (!try s.property(&out, wrapper, "", arg(args, 0))) {
        return .undefined;
    }
    return .{ .string = out.items };
}

// Parsing

const Parser = struct {
    it: *Interpreter,
    text: []const u8,
    i: usize = 0,

    fn whitespace(this: *Parser) void {
        while (this.i < this.text.len) : (this.i += 1) {
            switch (this.text[this.i]) {
                ' ', '\t', '\n', '\r' => {},
                else => return,
            }
        }
    }

    /// Where `at` is, as V8 says it: `position 4 (line 1 column 5)`.
    fn where(this: *Parser, at: usize) Error![]const u8 {
        var line: usize = 1;
        var column: usize = 1;
        for (this.text[0..at]) |c| {
            if (c == '\n') {
                line += 1;
                column = 1;
            } else {
                column += 1;
            }
        }
        return std.fmt.allocPrint(this.it.arena, "position {d} (line {d} column {d})", .{ at, line, column });
    }

    fn fail(this: *Parser, comptime what: []const u8) Error {
        return this.it.throw(.SyntaxError, what ++ " in JSON at {s}", .{try this.where(this.i)});
    }

    /// What's left after the value, which is only allowed to be whitespace.
    fn trailing(this: *Parser) Error {
        return this.it.throw(.SyntaxError, "Unexpected non-whitespace character after JSON at {s}", .{try this.where(this.i)});
    }

    /// V8's message for a character that can't be where it is.
    fn unexpected(this: *Parser) Error {
        if (this.i >= this.text.len) {
            return this.it.throw(.SyntaxError, "Unexpected end of JSON input", .{});
        }
        const len = std.unicode.utf8ByteSequenceLength(this.text[this.i]) catch 1;
        const token = this.text[this.i..@min(this.i + len, this.text.len)];
        if (this.text.len < 21) {
            return this.it.throw(.SyntaxError, "Unexpected token '{s}', \"{s}\" is not valid JSON", .{ token, this.text });
        }
        // A window of text around it.
        const start = this.i -| 10;
        const end = @min(this.i + 10, this.text.len);
        return this.it.throw(.SyntaxError, "Unexpected token '{s}', {s}\"{s}\"{s} is not valid JSON", .{
            token, if (start > 0) "..." else "", this.text[start..end], if (end < this.text.len) "..." else "",
        });
    }

    fn parseValue(this: *Parser) Error!Value {
        try this.it.checkStack();
        this.whitespace();
        if (this.i >= this.text.len) {
            return this.unexpected();
        }
        switch (this.text[this.i]) {
            '{' => return this.parseObject(),
            '[' => return this.parseArray(),
            '"' => return .{ .string = try this.parseString() },
            '-', '0'...'9' => return this.parseNumber(),
            else => {
                for ([_]struct { []const u8, Value }{ .{ "true", .{ .boolean = true } }, .{ "false", .{ .boolean = false } }, .{ "null", .null } }) |literal| {
                    if (std.mem.startsWith(u8, this.text[this.i..], literal[0])) {
                        this.i += literal[0].len;
                        return literal[1];
                    }
                }
                // As far as the literal matches, then what doesn't.
                for ([_][]const u8{ "true", "false", "null" }) |literal| {
                    if (this.text[this.i] == literal[0]) {
                        var j: usize = 0;
                        while (this.i + j < this.text.len and j < literal.len and this.text[this.i + j] == literal[j]) {
                            j += 1;
                        }
                        this.i += j;
                        return this.unexpected();
                    }
                }
                return this.unexpected();
            },
        }
    }

    fn parseObject(this: *Parser) Error!Value {
        this.i += 1;
        const o = try this.it.arena.create(value.Object);
        o.* = .{};
        this.whitespace();
        if (this.i < this.text.len and this.text[this.i] == '}') {
            this.i += 1;
            return .{ .object = o };
        }
        var first = true;
        while (true) {
            this.whitespace();
            // V8 says where, even at the end of the input.
            if (this.i >= this.text.len or this.text[this.i] != '"') {
                return if (first) this.fail("Expected property name or '}}'") else this.fail("Expected double-quoted property name");
            }
            first = false;
            const key = try this.parseString();
            this.whitespace();
            if (this.i >= this.text.len or this.text[this.i] != ':') {
                return this.fail("Expected ':' after property name");
            }
            this.i += 1;
            try o.properties.put(this.it.arena, key, try this.parseValue());
            this.whitespace();
            if (this.i >= this.text.len) {
                return this.unexpected();
            }
            switch (this.text[this.i]) {
                ',' => this.i += 1,
                '}' => {
                    this.i += 1;
                    return .{ .object = o };
                },
                else => return this.fail("Expected ',' or '}}' after property value"),
            }
        }
    }

    fn parseArray(this: *Parser) Error!Value {
        this.i += 1;
        var items: std.ArrayList(Value) = .empty;
        this.whitespace();
        if (this.i < this.text.len and this.text[this.i] == ']') {
            this.i += 1;
            return this.it.newArray(&.{});
        }
        while (true) {
            try items.append(this.it.arena, try this.parseValue());
            this.whitespace();
            if (this.i >= this.text.len) {
                return this.unexpected();
            }
            switch (this.text[this.i]) {
                ',' => this.i += 1,
                ']' => {
                    this.i += 1;
                    return this.it.newArray(items.items);
                },
                else => return this.fail("Expected ',' or ']' after array element"),
            }
        }
    }

    fn parseString(this: *Parser) Error![]const u8 {
        const start = this.i;
        this.i += 1;
        var units: std.ArrayList(u16) = .empty;
        var plain = true;
        while (true) {
            if (this.i >= this.text.len) {
                this.i = start;
                return this.fail("Unterminated string");
            }
            const c = this.text[this.i];
            if (c == '"') {
                this.i += 1;
                if (plain) {
                    return this.text[start + 1 .. this.i - 1];
                }
                return strings.fromUnits(this.it.arena, units.items);
            }
            if (c < 0x20) {
                return this.fail("Bad control character in string literal");
            }
            if (c != '\\') {
                const len = std.unicode.utf8ByteSequenceLength(c) catch 1;
                const end = @min(this.i + len, this.text.len);
                try units.appendSlice(this.it.arena, try strings.toUnits(this.it.arena, this.text[this.i..end]));
                this.i = end;
                continue;
            }
            plain = false;
            if (this.i + 1 >= this.text.len) {
                this.i = start;
                return this.fail("Unterminated string");
            }
            this.i += 1;
            const unit: u16 = switch (this.text[this.i]) {
                '"' => '"',
                '\\' => '\\',
                '/' => '/',
                'b' => 0x08,
                'f' => 0x0C,
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                'u' => blk: {
                    if (this.i + 4 >= this.text.len) {
                        return this.fail("Bad Unicode escape");
                    }
                    const hex = this.text[this.i + 1 .. this.i + 5];
                    // Exactly four hex digits: `parseInt` would also take a sign or `_`.
                    for (hex, 1..) |digit, offset| {
                        if (!std.ascii.isHex(digit)) {
                            // V8 points at the digit.
                            this.i += offset;
                            return this.fail("Bad Unicode escape");
                        }
                    }
                    const n = std.fmt.parseInt(u16, hex, 16) catch unreachable;
                    this.i += 4;
                    break :blk n;
                },
                else => return this.fail("Bad escaped character"),
            };
            try units.append(this.it.arena, unit);
            this.i += 1;
        }
    }

    fn parseNumber(this: *Parser) Error!Value {
        const start = this.i;
        if (this.text[this.i] == '-') {
            this.i += 1;
            if (this.i >= this.text.len or !std.ascii.isDigit(this.text[this.i])) {
                return this.fail("No number after minus sign");
            }
        }
        if (this.text[this.i] == '0') {
            this.i += 1;
        } else {
            while (this.i < this.text.len and std.ascii.isDigit(this.text[this.i])) {
                this.i += 1;
            }
        }
        if (this.i < this.text.len and this.text[this.i] == '.') {
            this.i += 1;
            if (this.i >= this.text.len or !std.ascii.isDigit(this.text[this.i])) {
                return this.fail("Unterminated fractional number");
            }
            while (this.i < this.text.len and std.ascii.isDigit(this.text[this.i])) {
                this.i += 1;
            }
        }
        if (this.i < this.text.len and (this.text[this.i] == 'e' or this.text[this.i] == 'E')) {
            this.i += 1;
            if (this.i < this.text.len and (this.text[this.i] == '+' or this.text[this.i] == '-')) {
                this.i += 1;
            }
            if (this.i >= this.text.len or !std.ascii.isDigit(this.text[this.i])) {
                return this.fail("Exponent part is missing a number");
            }
            while (this.i < this.text.len and std.ascii.isDigit(this.text[this.i])) {
                this.i += 1;
            }
        }
        return native.number(std.fmt.parseFloat(f64, this.text[start..this.i]) catch unreachable);
    }
};

fn parse(it: *Interpreter, _: Value, args: []const Value) Error!Value {
    const text = try arg(args, 0).toString(it.arena);
    var p: Parser = .{ .it = it, .text = text };
    const result = try p.parseValue();
    p.whitespace();
    if (p.i < text.len) {
        return p.trailing();
    }
    const reviver = arg(args, 1);
    if (reviver != .function and reviver != .native_function) {
        return result;
    }
    const root = try native.object(it, &.{.{ "", result }});
    return internalize(it, root, "", reviver);
}

/// InternalizeJSONProperty (§25.5.1.1): the reviver sees each value, innermost first.
fn internalize(it: *Interpreter, holder: Value, name: []const u8, reviver: Value) Error!Value {
    try it.checkStack();
    const v = try it.getNamed(holder, name);
    switch (v) {
        .array => |a| for (0..a.items().len) |i| {
            const index = try std.fmt.allocPrint(it.arena, "{d}", .{i});
            const element = try internalize(it, v, index, reviver);
            if (element == .undefined) {
                return it.throw(.Unsupported, "A reviver that leaves holes in an array is not supported yet.", .{});
            }
            a.items()[i] = element;
        },
        .object => |o| for (try it.ownKeys(v)) |key| {
            const element = try internalize(it, v, key, reviver);
            if (element == .undefined) {
                _ = o.properties.orderedRemove(key);
            } else {
                try o.properties.put(it.arena, key, element);
            }
        },
        else => {},
    }
    return it.invoke(reviver, holder, &.{ .{ .string = name }, v });
}
