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
        return switch (a.items().len) {
            0 => 0,
            1 => switch (a.items()[0]) {
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
    pub fn toPrimitive(this: Value, allocator: std.mem.Allocator) ConvertError!Value {
        return switch (this) {
            .object => |o| .{ .string = if (o.internal == .@"error") try errorString(allocator, o) else objectString(o) },
            .native_function => |f| .{ .string = f.source },
            .function => |f| .{ .string = try f.sourceText(allocator) },
            .array => |a| .{ .string = try a.join(allocator) },
            else => this,
        };
    }

    /// ToString (§7.1.17), allocating only when the result isn't already a string.
    pub fn toString(this: Value, allocator: std.mem.Allocator) ConvertError![]const u8 {
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
    pub fn looseEquals(a: Value, b: Value, allocator: std.mem.Allocator) ConvertError!bool {
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
    /// Properties in the order they were created.
    properties: std.StringArrayHashMapUnmanaged(Value) = .empty,
    /// Shown by `console.log`, e.g. `Object [console]`; null for plain objects.
    tag: ?[]const u8 = null,
    /// What a builtin object holds besides its properties.
    internal: Internal = .none,
    /// Methods (and constants) it has that aren't its own enumerable properties, like `Math.max`
    /// or a `Map`'s `get`. Its own properties come first.
    methods: ?*const Table = null,
    /// `Object.freeze` has been called on it, so its properties can't be added, changed or
    /// deleted.
    frozen: bool = false,

    pub const Internal = union(enum) {
        none,
        map: *Collection,
        set: *Collection,
        iterator: *Iterator,
        @"error": *ErrorData,
    };

    pub fn get(this: *const Object, name: []const u8) Value {
        if (this.properties.get(name)) |v| {
            return v;
        }
        if (this.internal == .@"error") {
            if (this.internal.@"error".get(name)) |v| {
                return v;
            }
        }
        if (this.methods) |methods| {
            if (methods.get(name)) |v| {
                return v;
            }
        }
        return .undefined;
    }

    /// OrdinaryOwnPropertyKeys (§10.1.11.1): array indices in ascending order, then the other
    /// names in the order they were created. This is the order `for...in`, spread and
    /// `console.log` see.
    pub fn keys(this: *const Object, allocator: std.mem.Allocator) error{OutOfMemory}![]const []const u8 {
        const all = this.properties.keys();
        var indices: std.ArrayList(Index) = .empty;
        for (all) |key| {
            if (arrayIndex(key)) |i| {
                try indices.append(allocator, .{ .index = i, .key = key });
            }
        }
        if (indices.items.len == 0) {
            return all;
        }
        std.mem.sort(Index, indices.items, {}, Index.lessThan);
        const ordered = try allocator.alloc([]const u8, all.len);
        for (indices.items, 0..) |entry, i| {
            ordered[i] = entry.key;
        }
        var n = indices.items.len;
        for (all) |key| {
            if (arrayIndex(key) == null) {
                ordered[n] = key;
                n += 1;
            }
        }
        return ordered;
    }

    const Index = struct {
        index: u32,
        key: []const u8,

        fn lessThan(_: void, a: Index, b: Index) bool {
            return a.index < b.index;
        }
    };
};

/// The constructors of the builtin errors, which name them.
pub const ErrorKind = enum {
    Error,
    EvalError,
    RangeError,
    ReferenceError,
    SyntaxError,
    TypeError,
    URIError,
};

/// What an error object has besides its own enumerable properties. Its `message`, `stack` and
/// `cause` are its own properties, but not enumerable ones; its `name` and `toString` come from
/// its prototype.
pub const ErrorData = struct {
    kind: ErrorKind,
    /// Null when it was made without one, so it has the prototype's `""`.
    message: ?Value = null,
    /// Null once it's been deleted.
    stack: ?Value = null,
    /// Null when it was made without one.
    cause: ?Value = null,

    /// One of its own properties that isn't enumerable, or one it inherits from its prototype.
    pub fn get(this: *const ErrorData, name: []const u8) ?Value {
        if (std.mem.eql(u8, name, "message")) {
            return this.message orelse .{ .string = "" };
        }
        if (std.mem.eql(u8, name, "stack")) {
            return this.stack;
        }
        if (std.mem.eql(u8, name, "name")) {
            return .{ .string = @tagName(this.kind) };
        }
        if (std.mem.eql(u8, name, "cause")) {
            return this.cause;
        }
        return null;
    }

    /// Assigns one of its own properties that isn't enumerable; false if `name` isn't one.
    pub fn set(this: *ErrorData, name: []const u8, v: Value) bool {
        if (std.mem.eql(u8, name, "message")) {
            if (this.message == null) {
                // The prototype's is inherited, so assigning makes an own, enumerable one.
                return false;
            }
            this.message = v;
        } else if (std.mem.eql(u8, name, "stack")) {
            if (this.stack == null) {
                // Deleted, so assigning makes an own, enumerable one.
                return false;
            }
            this.stack = v;
        } else if (std.mem.eql(u8, name, "cause") and this.cause != null) {
            this.cause = v;
        } else {
            return false;
        }
        return true;
    }

    /// Deletes one of its own properties that isn't enumerable, if `name` is one.
    pub fn delete(this: *ErrorData, name: []const u8) void {
        if (std.mem.eql(u8, name, "message")) {
            this.message = null;
        } else if (std.mem.eql(u8, name, "stack")) {
            this.stack = null;
        } else if (std.mem.eql(u8, name, "cause")) {
            this.cause = null;
        }
    }
};

/// Error.prototype.toString (§20.5.3.4) for an error object: `TypeError: message`, or just one of
/// the two if the other is empty.
pub fn errorString(allocator: std.mem.Allocator, o: *const Object) ConvertError![]const u8 {
    // An error whose name or message is itself (or holds it) would recurse forever, where V8
    // runs out of stack.
    if (error_string_depth == max_error_string_depth) {
        return error.NestedTooDeep;
    }
    error_string_depth += 1;
    defer error_string_depth -= 1;
    const name_value = o.get("name");
    const message_value = o.get("message");
    const name = if (name_value == .undefined) "Error" else try name_value.toString(allocator);
    const message = if (message_value == .undefined) "" else try message_value.toString(allocator);
    if (name.len == 0) {
        return message;
    }
    if (message.len == 0) {
        return name;
    }
    return std.fmt.allocPrint(allocator, "{s}: {s}", .{ name, message });
}

/// How many `errorString`s are in progress, each converting an error's name or message.
threadlocal var error_string_depth: usize = 0;
const max_error_string_depth = 1_000;

/// What `String(o)` gives for an object: `[object Object]`, or `[object Map]` and so on for the
/// builtin objects, by their `Symbol.toStringTag`.
pub fn objectString(o: *const Object) []const u8 {
    return switch (o.internal) {
        .none => if (o.tag) |tag|
            if (std.mem.eql(u8, tag, "Object [Math]")) "[object Math]" else if (std.mem.eql(u8, tag, "Object [JSON]")) "[object JSON]" else if (std.mem.eql(u8, tag, "Object [console]")) "[object console]" else "[object Object]"
        else
            "[object Object]",
        .map => "[object Map]",
        .set => "[object Set]",
        .@"error" => "[object Error]",
        .iterator => |it| switch (it.source) {
            .array => "[object Array Iterator]",
            .string => "[object String Iterator]",
            .map => "[object Map Iterator]",
            .set => "[object Set Iterator]",
        },
    };
}

/// `key` as an array index (CanonicalNumericIndexString below 2^32 - 1), if it's one.
pub fn arrayIndex(key: []const u8) ?u32 {
    if (key.len == 0 or key.len > 10 or (key.len > 1 and key[0] == '0')) {
        return null;
    }
    const n = std.fmt.parseInt(u32, key, 10) catch return null;
    return if (n == std.math.maxInt(u32)) null else n;
}

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
    /// The name it was given at runtime, as by a computed property key, if any.
    given_name: ?[]const u8 = null,

    pub fn name(this: *const Closure) []const u8 {
        return this.given_name orelse this.function.inferred_name;
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

/// What converting a value to a primitive can fail with.
pub const ConvertError = error{
    OutOfMemory,
    /// An array nested deeper than `Array.max_join_depth` was joined, where V8 would run out of
    /// stack. The interpreter throws it as a RangeError.
    NestedTooDeep,
};

pub const Array = struct {
    elements: std.ArrayList(Value),
    /// `Object.freeze` has been called on it.
    frozen: bool = false,

    pub fn items(this: *const Array) []Value {
        return this.elements.items;
    }

    /// How deep `join` goes into arrays inside arrays. V8 runs out of stack a little past 4,000 on
    /// a default stack; this is about as far as a function can recurse in V8.
    pub const max_join_depth = 10_000;

    /// Array.prototype.join with `,`, which is also what `String(array)` gives.
    pub fn join(this: *const Array, allocator: std.mem.Allocator) ConvertError![]const u8 {
        return this.joinWith(allocator, ",");
    }

    /// Array.prototype.join: the elements' string forms between `separator`s, with arrays inside
    /// it joined with `,`. An array inside itself joins as "" there, as in V8. It keeps its own
    /// stack rather than recursing, so it can't overflow the native one.
    pub fn joinWith(this: *const Array, allocator: std.mem.Allocator, separator: []const u8) ConvertError![]const u8 {
        const Frame = struct { array: *const Array, next: usize = 0 };
        var stack: std.ArrayList(Frame) = .empty;
        defer stack.deinit(allocator);
        // The arrays on `stack`.
        var joining: std.AutoHashMapUnmanaged(*const Array, void) = .empty;
        defer joining.deinit(allocator);
        try stack.append(allocator, .{ .array = this });
        try joining.put(allocator, this, {});
        var out: std.ArrayList(u8) = .empty;
        while (stack.items.len > 0) {
            const top = &stack.items[stack.items.len - 1];
            const elements = top.array.items();
            if (top.next == elements.len) {
                _ = joining.remove(stack.pop().?.array);
                continue;
            }
            const i = top.next;
            top.next += 1;
            if (i > 0) {
                try out.appendSlice(allocator, if (stack.items.len == 1) separator else ",");
            }
            switch (elements[i]) {
                .undefined, .null => {},
                .array => |inner| {
                    const entry = try joining.getOrPut(allocator, inner);
                    if (!entry.found_existing) {
                        if (stack.items.len == max_join_depth) {
                            return error.NestedTooDeep;
                        }
                        try stack.append(allocator, .{ .array = inner });
                    }
                },
                else => |item| try out.appendSlice(allocator, try item.toString(allocator)),
            }
        }
        return out.toOwnedSlice(allocator);
    }
};

pub const NativeFunction = struct {
    name: []const u8,
    /// What `String(f)` gives, e.g. `function log() { [native code] }`.
    source: []const u8,
    /// Null for a constructor that can only be called with `new`, like `Map`.
    call: ?Call,
    /// What `new` does with it, for a constructor.
    construct: ?Call = null,
    /// Its own properties, like `Number.isInteger`.
    statics: ?*const Table = null,
    /// Its `length`: how many arguments it expects.
    length: u32 = 0,
    /// It's a constructor JavaScript can call (or construct with) where `call` (or `construct`) is
    /// null, which we don't support yet.
    unsupported: bool = false,

    pub const Call = *const fn (context: *anyopaque, this: Value, args: []const Value) anyerror!Value;
};

/// Builtin properties, found by name: a prototype's methods or a namespace's members.
pub const Table = std.StaticStringMap(Value);

/// The entries of a `Map` or a `Set`, in the order they were added. A deleted entry stays where
/// it was, marked `removed`, so iterators that are going through them don't lose their place.
pub const Collection = struct {
    entries: std.ArrayList(Entry) = .empty,
    /// Where each key's entry is.
    index: std.HashMapUnmanaged(Value, u32, KeyContext, std.hash_map.default_max_load_percentage) = .empty,
    size: u32 = 0,

    pub const Entry = struct {
        key: Value,
        /// The same as `key` in a `Set`.
        value: Value,
        removed: bool = false,
    };

    pub fn get(this: *const Collection, key: Value) ?Value {
        const i = this.index.get(normalizeKey(key)) orelse return null;
        return this.entries.items[i].value;
    }

    pub fn has(this: *const Collection, key: Value) bool {
        return this.index.contains(normalizeKey(key));
    }

    pub fn set(this: *Collection, allocator: std.mem.Allocator, key: Value, v: Value) error{OutOfMemory}!void {
        const k = normalizeKey(key);
        const entry = try this.index.getOrPut(allocator, k);
        if (entry.found_existing) {
            this.entries.items[entry.value_ptr.*].value = v;
            return;
        }
        entry.value_ptr.* = @intCast(this.entries.items.len);
        try this.entries.append(allocator, .{ .key = k, .value = v });
        this.size += 1;
    }

    /// Adds a value to a `Set`, where it's its own key: `-0` goes in as `0`.
    pub fn add(this: *Collection, allocator: std.mem.Allocator, v: Value) error{OutOfMemory}!void {
        const k = normalizeKey(v);
        return this.set(allocator, k, k);
    }

    pub fn delete(this: *Collection, key: Value) bool {
        const removed = this.index.fetchRemove(normalizeKey(key)) orelse return false;
        this.entries.items[removed.value].removed = true;
        this.size -= 1;
        return true;
    }

    pub fn clear(this: *Collection) void {
        for (this.entries.items) |*e| {
            e.removed = true;
        }
        this.index.clearRetainingCapacity();
        this.size = 0;
    }

    /// `-0` is the same key as `0`.
    fn normalizeKey(key: Value) Value {
        if (key == .number and key.number == 0) {
            return .{ .number = 0 };
        }
        return key;
    }
};

/// SameValueZero (§7.2.11) as a hash map's equality, which is how `Map` and `Set` compare keys.
const KeyContext = struct {
    pub fn hash(_: KeyContext, key: Value) u64 {
        var h: std.hash.Wyhash = .init(@backingInt(std.meta.activeTag(key)));
        switch (key) {
            .number => |n| {
                const bits: u64 = if (std.math.isNan(n)) 0x7FF8000000000000 else @bitCast(n);
                h.update(std.mem.asBytes(&bits));
            },
            .string => |str| h.update(str),
            .boolean => |b| h.update(&.{@intFromBool(b)}),
            .undefined, .null, .uninitialized => {},
            inline .object, .native_function, .function, .array => |ptr| h.update(std.mem.asBytes(&@intFromPtr(ptr))),
        }
        return h.final();
    }

    pub fn eql(_: KeyContext, a: Value, b: Value) bool {
        return sameValueZero(a, b);
    }
};

/// SameValueZero (§7.2.11): `===`, except that `NaN` is itself.
pub fn sameValueZero(a: Value, b: Value) bool {
    if (a == .number and b == .number and std.math.isNan(a.number) and std.math.isNan(b.number)) {
        return true;
    }
    return a.strictEquals(b);
}

/// The state of a builtin iterator: what it goes through and how far it's got.
pub const Iterator = struct {
    source: Source,
    kind: Kind = .values,
    /// The next index (or byte offset, for a string) to look at.
    position: usize = 0,
    done: bool = false,

    pub const Source = union(enum) {
        array: *Array,
        string: []const u8,
        map: *Collection,
        set: *Collection,
    };

    pub const Kind = enum { keys, values, entries };
};

/// Joins strings, as `+` does. Since they're WTF-8, a lone high surrogate at the end of one and a
/// lone low surrogate at the start of the next make one code point together.
pub fn concatStrings(allocator: std.mem.Allocator, parts: []const []const u8) error{OutOfMemory}![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (parts) |part| {
        var rest = part;
        if (out.items.len >= 3 and rest.len >= 3 and isHighSurrogate(out.items[out.items.len - 3 ..]) and isLowSurrogate(rest[0..3])) {
            const high = std.unicode.wtf8Decode(out.items[out.items.len - 3 ..]) catch unreachable;
            const low = std.unicode.wtf8Decode(rest[0..3]) catch unreachable;
            out.shrinkRetainingCapacity(out.items.len - 3);
            var buffer: [4]u8 = undefined;
            const code_point = 0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00);
            const n = std.unicode.utf8Encode(code_point, &buffer) catch unreachable;
            try out.appendSlice(allocator, buffer[0..n]);
            rest = rest[3..];
        }
        try out.appendSlice(allocator, rest);
    }
    return out.toOwnedSlice(allocator);
}

fn isHighSurrogate(bytes: []const u8) bool {
    return bytes[0] == 0xED and bytes[1] >= 0xA0 and bytes[1] <= 0xAF;
}

fn isLowSurrogate(bytes: []const u8) bool {
    return bytes[0] == 0xED and bytes[1] >= 0xB0 and bytes[1] <= 0xBF;
}

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
    return @import("fdlibm.zig").pow(base, exponent);
}

// Formatting like node's `util.inspect`, used by `console.log` and the REPL.

pub const InspectError = error{ WriteFailed, OutOfMemory };

pub fn inspect(allocator: std.mem.Allocator, writer: *std.Io.Writer, value: Value) InspectError!void {
    return inspectDepth(allocator, writer, value, 2);
}

/// `util.inspect` with nested objects shown `depth` levels deep.
pub fn inspectDepth(allocator: std.mem.Allocator, writer: *std.Io.Writer, value: Value, depth: usize) InspectError!void {
    var inspector: Inspector = .{ .allocator = allocator, .max_depth = depth };
    try writer.writeAll(try inspector.format(value, 0));
}

/// Node's `formatValue` with its default options: nested objects shown to a depth of 2, at most
/// 100 array elements, and lines broken at 80 columns.
const Inspector = struct {
    allocator: std.mem.Allocator,
    /// How far the current entry is indented.
    indentation: usize = 0,
    /// The depth of the object most recently entered (`ctx.currentDepth`).
    current_depth: usize = 0,
    /// The objects being formatted, outermost first, for spotting circular references.
    seen: std.ArrayList(*const anyopaque) = .empty,
    /// Objects referred to circularly; `*1` is the first.
    circular: std.ArrayList(*const anyopaque) = .empty,

    /// How deep nested objects are shown.
    max_depth: usize = 2,

    const break_length = 80;
    const max_array_length = 100;

    fn format(this: *Inspector, value: Value, depth: usize) InspectError![]const u8 {
        return switch (value) {
            .undefined => "undefined",
            .null => "null",
            .boolean => |b| if (b) "true" else "false",
            // `util.inspect` shows the sign of zero, unlike `String(-0)`.
            .number => |n| if (n == 0 and std.math.signbit(n)) "-0" else number.toString(this.allocator, n),
            .string => |str| this.formatString(str),
            .native_function => |f| std.fmt.allocPrint(this.allocator, "[Function: {s}]", .{f.name}),
            .function => |f| if (f.name().len == 0)
                "[Function (anonymous)]"
            else
                std.fmt.allocPrint(this.allocator, "[Function: {s}]", .{f.name()}),
            .array => |a| this.formatObject(.{ .array = a }, depth),
            .object => |o| switch (o.internal) {
                .none => this.formatObject(.{ .object = o }, depth),
                .map, .set => |c| this.formatObject(.{ .collection = .{ .object = o, .entries = c, .map = o.internal == .map } }, depth),
                .iterator => |it| this.formatIterator(o, it, depth),
                .@"error" => this.formatObject(.{ .object = o }, depth),
            },
            .uninitialized => unreachable,
        };
    }

    /// An array or string iterator shows as its tag; a map or set iterator as what's left.
    fn formatIterator(this: *Inspector, o: *const Object, it: *const Iterator, depth: usize) InspectError![]const u8 {
        const collection, const map = switch (it.source) {
            .array, .string => return std.fmt.allocPrint(this.allocator, "{s} {{}}", .{o.tag.?}),
            .map => |c| .{ c, true },
            .set => |c| .{ c, false },
        };
        return this.formatObject(.{ .remaining = .{ .iterator = it, .entries = collection, .map = map } }, depth);
    }

    /// `formatPrimitive` for a string: quoted, and split after each line break if it's too long
    /// to fit.
    fn formatString(this: *Inspector, s: []const u8) InspectError![]const u8 {
        const length = jsLength(s);
        if (length <= 16 or length <= break_length -| (this.indentation + 4) or std.mem.indexOfScalar(u8, s[0 .. s.len - 1], '\n') == null) {
            return quoted(this.allocator, s);
        }
        var out: std.ArrayList(u8) = .empty;
        var rest = s;
        while (rest.len > 0) {
            const end = if (std.mem.indexOfScalar(u8, rest, '\n')) |i| i + 1 else rest.len;
            if (out.items.len > 0) {
                try out.appendSlice(this.allocator, " +\n");
                try out.appendNTimes(this.allocator, ' ', this.indentation + 2);
            }
            try out.appendSlice(this.allocator, try quoted(this.allocator, rest[0..end]));
            rest = rest[end..];
        }
        return out.items;
    }

    const Container = union(enum) {
        array: *const Array,
        object: *const Object,
        /// A `Map` or `Set`.
        collection: struct { object: *const Object, entries: *const Collection, map: bool },
        /// What a `Map` or `Set` iterator has left.
        remaining: struct { iterator: *const Iterator, entries: *const Collection, map: bool },

        fn ptr(this: Container) *const anyopaque {
            return switch (this) {
                .array => |p| p,
                .object => |p| p,
                .collection => |c| c.object,
                .remaining => |r| r.iterator,
            };
        }
    };

    /// `formatValue` and `formatRaw` for arrays and objects.
    fn formatObject(this: *Inspector, container: Container, depth: usize) InspectError![]const u8 {
        const ptr = container.ptr();
        if (std.mem.indexOfScalar(*const anyopaque, this.seen.items, ptr) != null) {
            const index = std.mem.indexOfScalar(*const anyopaque, this.circular.items, ptr) orelse blk: {
                try this.circular.append(this.allocator, ptr);
                break :blk this.circular.items.len - 1;
            };
            return std.fmt.allocPrint(this.allocator, "[Circular *{d}]", .{index + 1});
        }
        var open: []const u8 = "{";
        var close: []const u8 = "}";
        var keys: []const []const u8 = &.{};
        // What an error shows before its own enumerable properties, if it has any.
        var error_base: []const u8 = "";
        switch (container) {
            .array => |a| {
                open = "[";
                close = "]";
                if (a.items().len == 0) {
                    return "[]";
                }
            },
            .object => |o| {
                if (o.tag) |tag| {
                    open = try std.fmt.allocPrint(this.allocator, "{s} {{", .{tag});
                }
                keys = try o.keys(this.allocator);
                if (o.internal == .@"error") {
                    error_base = try this.errorBase(o);
                    if (keys.len == 0) {
                        return error_base;
                    }
                } else if (keys.len == 0) {
                    return std.fmt.allocPrint(this.allocator, "{s}}}", .{open});
                }
            },
            .collection => |c| {
                open = try std.fmt.allocPrint(this.allocator, "{s}({d}) {{", .{ if (c.map) "Map" else "Set", c.entries.size });
                if (c.entries.size == 0) {
                    return std.fmt.allocPrint(this.allocator, "{s}}}", .{open});
                }
            },
            .remaining => |r| {
                const entries = r.iterator.kind == .entries;
                open = if (r.map) (if (entries) "[Map Entries] {" else "[Map Iterator] {") else if (entries) "[Set Entries] {" else "[Set Iterator] {";
            },
        }
        if (depth > this.max_depth) {
            return switch (container) {
                .array => "[Array]",
                .collection => |c| if (c.map) "[Map]" else "[Set]",
                else => "[Object]",
            };
        }
        const inner = depth + 1;
        try this.seen.append(this.allocator, ptr);
        this.current_depth = inner;
        var output: std.ArrayList([]const u8) = .empty;
        switch (container) {
            .array => |a| {
                const shown = @min(a.items().len, max_array_length);
                for (a.items()[0..shown]) |item| {
                    try output.append(this.allocator, try this.entry(item, inner));
                }
                if (a.items().len > shown) {
                    const more = a.items().len - shown;
                    try output.append(this.allocator, try std.fmt.allocPrint(this.allocator, "... {d} more item{s}", .{ more, if (more > 1) "s" else "" }));
                }
            },
            .object => |o| for (keys) |key| {
                const name = if (isIdentifier(key)) key else try quoted(this.allocator, key);
                try output.append(this.allocator, try std.fmt.allocPrint(this.allocator, "{s}: {s}", .{ name, try this.entry(o.get(key), inner) }));
            },
            .collection => |c| for (c.entries.entries.items) |e| {
                if (e.removed) {
                    continue;
                }
                if (c.map) {
                    try output.append(this.allocator, try std.fmt.allocPrint(this.allocator, "{s} => {s}", .{ try this.entry(e.key, inner), try this.entry(e.value, inner) }));
                } else {
                    try output.append(this.allocator, try this.entry(e.value, inner));
                }
            },
            .remaining => |r| for (r.entries.entries.items[@min(r.iterator.position, r.entries.entries.items.len)..]) |e| {
                if (e.removed or r.iterator.done) {
                    continue;
                }
                try output.append(this.allocator, switch (r.iterator.kind) {
                    .keys => try this.entry(e.key, inner),
                    .values => try this.entry(e.value, inner),
                    .entries => blk: {
                        // Each entry is shown as the array `next()` gives.
                        this.indentation += 2;
                        defer this.indentation -= 2;
                        var pair = [_]Value{ e.key, e.value };
                        var array: Array = .{ .elements = .fromOwnedSlice(&pair) };
                        break :blk try this.formatObject(.{ .array = &array }, inner);
                    },
                });
            },
        }
        var base: []const u8 = error_base;
        if (std.mem.indexOfScalar(*const anyopaque, this.circular.items, ptr)) |index| {
            base = try std.fmt.allocPrint(this.allocator, "<ref *{d}>{s}{s}", .{ index + 1, if (base.len > 0) " " else "", base });
        }
        _ = this.seen.pop();
        return this.reduceToSingleString(output.items, base, open, close, container, inner);
    }

    /// Node's `formatError`: an error's stack (or what `toString` gives, in brackets, if it has
    /// no frames), with its lines indented as far as the error is.
    fn errorBase(this: *Inspector, o: *const Object) InspectError![]const u8 {
        const stack = o.get("stack");
        var text = if (stack == .string and stack.string.len > 0) stack.string else errorString(this.allocator, o) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NestedTooDeep => "Error",
        };
        if (std.mem.indexOf(u8, text, "\n    at") == null) {
            text = try std.fmt.allocPrint(this.allocator, "[{s}]", .{text});
        }
        if (this.indentation == 0 or std.mem.indexOfScalar(u8, text, '\n') == null) {
            return text;
        }
        var out: std.ArrayList(u8) = .empty;
        var lines = std.mem.splitScalar(u8, text, '\n');
        try out.appendSlice(this.allocator, lines.first());
        while (lines.next()) |line| {
            try out.append(this.allocator, '\n');
            try out.appendNTimes(this.allocator, ' ', this.indentation);
            try out.appendSlice(this.allocator, line);
        }
        return out.items;
    }

    /// A property's value or an array's element, indented two more than its container.
    fn entry(this: *Inspector, value: Value, depth: usize) InspectError![]const u8 {
        this.indentation += 2;
        defer this.indentation -= 2;
        return this.format(value, depth);
    }

    /// Node's `reduceToSingleString`: the entries on one line if they fit and nothing in them is
    /// nested too deeply, otherwise one per line (or in columns, for a long array).
    fn reduceToSingleString(this: *Inspector, entries: []const []const u8, base: []const u8, open: []const u8, close: []const u8, container: Container, depth: usize) InspectError![]const u8 {
        var output = entries;
        if (container == .array and entries.len > 6) {
            output = try this.groupArrayElements(entries, container.array);
        }
        if (this.current_depth -| depth < 3 and entries.len == output.len) {
            const start = output.len + this.indentation + open.len + base.len + 10;
            if (isBelowBreakLength(output, start, base)) {
                const joined = try std.mem.join(this.allocator, ", ", output);
                if (std.mem.indexOfScalar(u8, joined, '\n') == null) {
                    return std.fmt.allocPrint(this.allocator, "{s}{s}{s} {s} {s}", .{ base, if (base.len > 0) " " else "", open, joined, close });
                }
            }
        }
        var indentation: std.ArrayList(u8) = .empty;
        try indentation.append(this.allocator, '\n');
        try indentation.appendNTimes(this.allocator, ' ', this.indentation);
        const separator = try std.fmt.allocPrint(this.allocator, ",{s}  ", .{indentation.items});
        return std.fmt.allocPrint(this.allocator, "{s}{s}{s}{s}  {s}{s}{s}", .{
            base, if (base.len > 0) " " else "", open, indentation.items, try std.mem.join(this.allocator, separator, output), indentation.items, close,
        });
    }

    fn isBelowBreakLength(output: []const []const u8, start: usize, base: []const u8) bool {
        var total = output.len + start;
        if (total + output.len > break_length) {
            return false;
        }
        for (output) |entry_text| {
            total += jsLength(entry_text);
            if (total > break_length) {
                return false;
            }
        }
        return base.len == 0 or std.mem.indexOfScalar(u8, base, '\n') == null;
    }

    /// Node's `groupArrayElements`: lays short entries out in aligned columns, numbers padded on
    /// the left and anything else on the right.
    fn groupArrayElements(this: *Inspector, output: []const []const u8, array: *const Array) InspectError![]const []const u8 {
        const separator_space = 2;
        const has_more = array.items().len > max_array_length;
        const output_length = if (has_more) output.len - 1 else output.len;
        const data_len = try this.allocator.alloc(usize, output_length);
        var total_length: usize = 0;
        var max_length: usize = 0;
        for (output[0..output_length], data_len) |entry_text, *len| {
            len.* = jsLength(entry_text);
            total_length += len.* + separator_space;
            max_length = @max(max_length, len.*);
        }
        const actual_max = max_length + separator_space;
        const total: f64 = @floatFromInt(total_length);
        const actual: f64 = @floatFromInt(actual_max);
        if (!(actual_max * 3 + this.indentation < break_length and (total / actual > 5 or max_length <= 6))) {
            return output;
        }
        const average_bias = @sqrt(actual - total / @as(f64, @floatFromInt(output.len)));
        const biased_max = @max(actual - 3 - average_bias, 1);
        const columns: usize = @intFromFloat(@min(
            @min(@round(@sqrt(2.5 * biased_max * @as(f64, @floatFromInt(output_length))) / biased_max), @floor(@as(f64, @floatFromInt(break_length -| this.indentation)) / actual)),
            @min(3 * 4, 15),
        ));
        if (columns <= 1) {
            return output;
        }
        const max_line_length = try this.allocator.alloc(usize, columns);
        for (max_line_length, 0..) |*line_length, i| {
            line_length.* = 0;
            var j = i;
            while (j < output_length) : (j += columns) {
                line_length.* = @max(line_length.*, data_len[j]);
            }
            line_length.* += separator_space;
        }
        const pad_start = for (array.items()[0..@min(output.len, array.items().len)]) |v| {
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
                const cell = if (last) output[j] else try std.fmt.allocPrint(this.allocator, "{s}, ", .{output[j]});
                const width = if (last and pad_start) max_line_length[j - i] - separator_space else if (last) 0 else max_line_length[j - i];
                const padding = width -| jsLength(cell);
                if (pad_start) {
                    try row.appendNTimes(this.allocator, ' ', padding);
                    try row.appendSlice(this.allocator, cell);
                } else {
                    try row.appendSlice(this.allocator, cell);
                    try row.appendNTimes(this.allocator, ' ', padding);
                }
            }
            try rows.append(this.allocator, row.items);
        }
        if (has_more) {
            try rows.append(this.allocator, output[output_length]);
        }
        return rows.items;
    }
};

/// Whether node shows a property name without quotes (`keyStrRegExp`).
fn isIdentifier(key: []const u8) bool {
    if (key.len == 0 or std.ascii.isDigit(key[0])) {
        return false;
    }
    for (key) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') {
            return false;
        }
    }
    return true;
}

fn quoted(allocator: std.mem.Allocator, s: []const u8) error{OutOfMemory}![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    quoteString(&out.writer, s) catch return error.OutOfMemory;
    return out.written();
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
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        // Lone surrogates, which WTF-8 has as three bytes, and the C1 controls are escaped.
        if (c == 0xED and i + 2 < s.len and s[i + 1] >= 0xA0) {
            const code_point = std.unicode.wtf8Decode(s[i .. i + 3]) catch 0xFFFD;
            try writer.print("\\u{x}", .{code_point});
            i += 2;
            continue;
        }
        if (c == 0xC2 and i + 1 < s.len and s[i + 1] >= 0x80 and s[i + 1] <= 0x9F) {
            try writer.print("\\x{X}", .{s[i + 1]});
            i += 1;
            continue;
        }
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
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
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
        try inspect(arena.allocator(), &writer, case[0]);
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
        var array: Array = .{ .elements = .fromOwnedSlice(items) };
        var out: std.Io.Writer.Allocating = .init(a);
        try inspect(a, &out.writer, .{ .array = &array });
        try testing.expectEqualStrings(case[1], out.written());
    }
}
