//! Types, and the relations between them that the checker needs. Types are values passed by
//! pointer; the primitives are static singletons, and anything built while checking lives in the
//! checker's arena.

const std = @import("std");

pub const Type = union(enum) {
    any,
    unknown,
    never,
    void,
    undefined,
    null,
    boolean,
    number,
    string,
    bigint,
    /// A literal type such as `1`, `"a"` or `true`.
    literal: Literal,
    /// Flattened (never contains another union) with no duplicates and at least two members.
    @"union": []const *const Type,
    object: *const Object,
    function: *const Function,

    pub const Literal = struct {
        value: Value,
        /// tsc's "fresh" literal types come straight from a literal in the source, and are the
        /// only ones a `let` declaration widens: `let a = 1` is a `number`, but `let t = typeof x`
        /// keeps the literal union `typeof` produces. Freshness doesn't affect identity.
        fresh: bool = false,

        pub const Value = union(enum) {
            number: f64,
            string: []const u8,
            boolean: bool,
        };
    };

    pub fn eql(a: *const Type, b: *const Type) bool {
        if (a == b) {
            return true;
        }
        return switch (a.*) {
            .literal => |x| b.* == .literal and literalEql(x.value, b.literal.value),
            .@"union" => |ms| b.* == .@"union" and ms.len == b.@"union".len and for (ms) |m| {
                if (!b.contains(m)) {
                    break false;
                }
            } else true,
            .object => |o| b.* == .object and b.object == o,
            .function => |f| b.* == .function and b.function == f,
            else => std.meta.activeTag(a.*) == std.meta.activeTag(b.*),
        };
    }

    fn contains(this: *const Type, member: *const Type) bool {
        var buffer: [1]*const Type = undefined;
        for (this.members(&buffer)) |m| {
            if (m.eql(member)) {
                return true;
            }
        }
        return false;
    }

    /// The members of a union, or the type itself; `buffer` holds the latter.
    pub fn members(this: *const Type, buffer: *[1]*const Type) []const *const Type {
        return switch (this.*) {
            .@"union" => |m| m,
            else => {
                buffer[0] = this;
                return buffer;
            },
        };
    }

    pub fn format(this: *const Type, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (this.*) {
            .literal => |lit| switch (lit.value) {
                .number => |n| try @import("../runtime/number.zig").format(writer, n),
                .string => |s| try writer.print("\"{s}\"", .{s}),
                .boolean => |b| try writer.writeAll(if (b) "true" else "false"),
            },
            .@"union" => |ms| for (ms, 0..) |m, i| {
                if (i > 0) {
                    try writer.writeAll(" | ");
                }
                try writer.print("{f}", .{m});
            },
            .object => |o| try writer.writeAll(o.name),
            .function => |f| try f.format(writer),
            else => try writer.writeAll(@tagName(this.*)),
        }
    }
};

fn literalEql(a: Type.Literal.Value, b: Type.Literal.Value) bool {
    return switch (a) {
        .number => |x| b == .number and (x == b.number or (std.math.isNan(x) and std.math.isNan(b.number))),
        .string => |x| b == .string and std.mem.eql(u8, x, b.string),
        .boolean => |x| b == .boolean and x == b.boolean,
    };
}

pub const Property = struct {
    name: []const u8,
    type: *const Type,
};

pub const Object = struct {
    /// Shown in diagnostics, e.g. `Console`.
    name: []const u8,
    properties: []const Property,

    pub fn property(this: *const Object, name: []const u8) ?*const Type {
        for (this.properties) |p| {
            if (std.mem.eql(u8, p.name, name)) {
                return p.type;
            }
        }
        return null;
    }
};

pub const Parameter = struct {
    name: []const u8,
    type: *const Type,
};

pub const Function = struct {
    parameters: []const Parameter,
    /// The element type of a `...rest` parameter.
    rest: ?Parameter = null,
    returns: *const Type,

    pub fn format(this: *const Function, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll("(");
        for (this.parameters, 0..) |p, i| {
            if (i > 0) {
                try writer.writeAll(", ");
            }
            try writer.print("{s}: {f}", .{ p.name, p.type });
        }
        if (this.rest) |r| {
            if (this.parameters.len > 0) {
                try writer.writeAll(", ");
            }
            try writer.print("...{s}: {f}[]", .{ r.name, r.type });
        }
        try writer.print(") => {f}", .{this.returns});
    }
};

// Singletons for the types without data.
pub const any: *const Type = &.any;
pub const unknown: *const Type = &.unknown;
pub const never: *const Type = &.never;
pub const @"void": *const Type = &.void;
pub const @"undefined": *const Type = &.undefined;
pub const @"null": *const Type = &.null;
pub const boolean: *const Type = &.boolean;
pub const number: *const Type = &.number;
pub const string: *const Type = &.string;
pub const @"true": *const Type = &.{ .literal = .{ .value = .{ .boolean = true } } };
pub const @"false": *const Type = &.{ .literal = .{ .value = .{ .boolean = false } } };
const fresh_true: *const Type = &.{ .literal = .{ .value = .{ .boolean = true }, .fresh = true } };
const fresh_false: *const Type = &.{ .literal = .{ .value = .{ .boolean = false }, .fresh = true } };

/// The primitive a literal type belongs to (`1` → `number`); other types are unchanged.
/// `true | false` widens to `boolean`, and so on member by member for unions.
pub fn widen(arena: std.mem.Allocator, t: *const Type) error{OutOfMemory}!*const Type {
    return switch (t.*) {
        .literal => |lit| switch (lit.value) {
            .number => number,
            .string => string,
            .boolean => boolean,
        },
        .@"union" => |ms| blk: {
            var widened: std.ArrayList(*const Type) = .empty;
            for (ms) |m| {
                try widened.append(arena, try widen(arena, m));
            }
            break :blk unionOf(arena, widened.items);
        },
        else => t,
    };
}

/// Like `widen`, but only for fresh literals; what a `let` declaration does to its initializer's
/// type (tsc's `getWidenedLiteralType`).
pub fn widenFresh(arena: std.mem.Allocator, t: *const Type) error{OutOfMemory}!*const Type {
    return switch (t.*) {
        .literal => |lit| if (lit.fresh) widen(arena, t) else t,
        .@"union" => |ms| blk: {
            var widened: std.ArrayList(*const Type) = .empty;
            for (ms) |m| {
                try widened.append(arena, try widenFresh(arena, m));
            }
            break :blk unionOf(arena, widened.items);
        },
        else => t,
    };
}

/// The union of `parts`, flattened and deduplicated. Literals are absorbed by their primitive,
/// `never` disappears, `any`/`unknown` swallow everything, and `true | false` is `boolean`.
/// Members are kept in the order tsc prints them.
pub fn unionOf(arena: std.mem.Allocator, parts: []const *const Type) error{OutOfMemory}!*const Type {
    var list: std.ArrayList(*const Type) = .empty;
    for (parts) |part| {
        if (part.* == .any) {
            return any;
        }
        if (part.* == .unknown) {
            return unknown;
        }
        var buffer: [1]*const Type = undefined;
        for (part.members(&buffer)) |m| {
            if (m.* == .never) {
                continue;
            }
            const index = for (list.items, 0..) |existing, i| {
                if (existing.eql(m)) {
                    break i;
                }
            } else null;
            if (index) |i| {
                // Like tsc, a regular literal wins over a fresh one.
                if (m.* == .literal and !m.literal.fresh) {
                    list.items[i] = m;
                }
            } else {
                try list.append(arena, m);
            }
        }
    }
    // `true | false` is `boolean`.
    var has_true = false;
    var has_false = false;
    for (list.items) |m| {
        if (m.* == .literal and m.literal.value == .boolean) {
            if (m.literal.value.boolean) {
                has_true = true;
            } else {
                has_false = true;
            }
        }
    }
    if (has_true and has_false) {
        var i: usize = 0;
        while (i < list.items.len) {
            if (list.items[i].* == .literal and list.items[i].literal.value == .boolean) {
                _ = list.orderedRemove(i);
            } else {
                i += 1;
            }
        }
        try list.append(arena, boolean);
    }
    // Drop literals whose primitive is also present.
    var i: usize = 0;
    while (i < list.items.len) {
        const m = list.items[i];
        if (m.* == .literal) {
            const base = try widen(arena, m);
            const has_base = for (list.items) |other| {
                if (other.eql(base)) {
                    break true;
                }
            } else false;
            if (has_base) {
                _ = list.orderedRemove(i);
                continue;
            }
        }
        i += 1;
    }
    if (list.items.len == 0) {
        return never;
    }
    if (list.items.len == 1) {
        return list.items[0];
    }
    std.mem.sort(*const Type, list.items, {}, printsBefore);
    return asPtr(.{ .@"union" = list.items }, arena);
}

/// tsc orders a union's members by when each type was created: its built-in types first (in a
/// fixed order), then literals in the order the program mentions them. It prints `null` and
/// `undefined` last. The sort is stable, so literals keep their relative order.
fn printsBefore(_: void, a: *const Type, b: *const Type) bool {
    return printRank(a) < printRank(b);
}

fn printRank(t: *const Type) u8 {
    return switch (t.*) {
        .string => 0,
        .number => 1,
        .bigint => 2,
        .boolean => 3,
        .literal => |lit| switch (lit.value) {
            .boolean => |b| if (b) 4 else 3,
            else => 5,
        },
        .void => 6,
        .object, .function => 7,
        .null => 8,
        .undefined => 9,
        .any, .unknown, .never, .@"union" => 10,
    };
}

fn asPtr(t: Type, arena: std.mem.Allocator) error{OutOfMemory}!*const Type {
    const p = try arena.create(Type);
    p.* = t;
    return p;
}

/// A regular (not fresh) literal type.
pub fn literal(arena: std.mem.Allocator, value: Type.Literal.Value) error{OutOfMemory}!*const Type {
    if (value == .boolean) {
        return if (value.boolean) @"true" else @"false";
    }
    return asPtr(.{ .literal = .{ .value = value } }, arena);
}

/// The type of a literal in the source.
pub fn freshLiteral(arena: std.mem.Allocator, value: Type.Literal.Value) error{OutOfMemory}!*const Type {
    if (value == .boolean) {
        return if (value.boolean) fresh_true else fresh_false;
    }
    return asPtr(.{ .literal = .{ .value = value, .fresh = true } }, arena);
}

/// Whether `t` is a union as far as narrowing is concerned, which `boolean` (`true | false`) is.
pub fn isUnion(t: *const Type) bool {
    return t.* == .@"union" or t.* == .boolean;
}

/// The members of `t` with `boolean` split into `true` and `false`, which is how narrowing and
/// comparisons see it.
pub fn expandedMembers(arena: std.mem.Allocator, t: *const Type) error{OutOfMemory}![]const *const Type {
    var buffer: [1]*const Type = undefined;
    const ms = t.members(&buffer);
    var list: std.ArrayList(*const Type) = .empty;
    for (ms) |m| {
        if (m.* == .boolean) {
            try list.appendSlice(arena, &.{ @"true", @"false" });
        } else {
            try list.append(arena, m);
        }
    }
    return list.items;
}

/// `boolean` as the union `true | false`, which is how narrowing and comparisons see it.
fn expandBoolean(t: *const Type, buffer: *[1]*const Type) []const *const Type {
    const both = &[_]*const Type{ @"true", @"false" };
    return if (t.* == .boolean) both else t.members(buffer);
}

/// Whether `===` between the two types could ever be true; tsc reports TS2367 when not.
/// This is tsc's "comparable" relation, which for the types we have so far means the two share
/// at least one possible value.
pub fn comparable(a: *const Type, b: *const Type) bool {
    if (a.* == .any or b.* == .any or a.* == .unknown or b.* == .unknown) {
        return true;
    }
    var a_buffer: [1]*const Type = undefined;
    var b_buffer: [1]*const Type = undefined;
    for (expandBoolean(a, &a_buffer)) |x| {
        for (expandBoolean(b, &b_buffer)) |y| {
            if (overlaps(x, y)) {
                return true;
            }
        }
    }
    return false;
}

fn overlaps(x: *const Type, y: *const Type) bool {
    // Under strict null checks, tsc still allows comparing anything with `null` or `undefined`.
    if (isNullish(x) or isNullish(y)) {
        return true;
    }
    // `never` is related to everything.
    if (x.* == .never or y.* == .never) {
        return true;
    }
    if (x.* == .literal and y.* == .literal) {
        return literalEql(x.literal.value, y.literal.value);
    }
    if (x.* == .object and y.* == .object) {
        return x.object == y.object;
    }
    if (x.* == .function and y.* == .function) {
        return true;
    }
    return primitiveKind(x) != .other and primitiveKind(x) == primitiveKind(y);
}

fn isNullish(t: *const Type) bool {
    return t.* == .null or t.* == .undefined;
}

const Kind = enum { number, string, boolean, bigint, other };

fn primitiveKind(t: *const Type) Kind {
    return switch (t.*) {
        .number => .number,
        .string => .string,
        .boolean => .boolean,
        .bigint => .bigint,
        .literal => |lit| switch (lit.value) {
            .number => .number,
            .string => .string,
            .boolean => .boolean,
        },
        else => .other,
    };
}

/// Every member is a number or numeric literal.
pub fn isNumberLike(t: *const Type) bool {
    return allOfKind(t, .number);
}

pub fn isStringLike(t: *const Type) bool {
    return allOfKind(t, .string);
}

pub fn isBigIntLike(t: *const Type) bool {
    return allOfKind(t, .bigint);
}

fn allOfKind(t: *const Type, kind: Kind) bool {
    var buffer: [1]*const Type = undefined;
    for (t.members(&buffer)) |m| {
        if (primitiveKind(m) != kind) {
            return false;
        }
    }
    return true;
}

/// Whether a value of type `source` can be used where `target` is expected.
pub fn assignable(source: *const Type, target: *const Type) bool {
    if (source.eql(target)) {
        return true;
    }
    if (target.* == .any or target.* == .unknown or source.* == .any or source.* == .never) {
        return true;
    }
    if (source.* == .@"union") {
        for (source.@"union") |m| {
            if (!assignable(m, target)) {
                return false;
            }
        }
        return true;
    }
    if (source.* == .boolean) {
        return assignable(@"true", target) and assignable(@"false", target);
    }
    if (target.* == .@"union") {
        for (target.@"union") |m| {
            if (assignable(source, m)) {
                return true;
            }
        }
        return false;
    }
    return switch (target.*) {
        .number => isNumberLike(source),
        .string => isStringLike(source),
        .boolean => source.* == .literal and source.literal.value == .boolean,
        .void => source.* == .undefined,
        else => false,
    };
}

/// Whether `t` is or includes `undefined` (or `void`, `any` or `unknown`, which can all hold it).
pub fn includesUndefined(t: *const Type) bool {
    var buffer: [1]*const Type = undefined;
    for (t.members(&buffer)) |m| {
        switch (m.*) {
            .undefined, .void, .any, .unknown => return true,
            else => {},
        }
    }
    return false;
}

/// tsc's `typeCouldHaveTopLevelSingletonTypes`: when it's false, a literal source type is shown
/// widened in "not assignable" messages (`Type 'string'` rather than `Type '"a"'`).
pub fn couldHaveSingletons(t: *const Type) bool {
    // `boolean` alone doesn't count, but as part of a union its `true` and `false` do.
    if (t.* != .@"union") {
        return t.* == .literal or t.* == .null or t.* == .undefined;
    }
    for (t.@"union") |m| {
        switch (m.*) {
            .literal, .null, .undefined, .boolean => return true,
            else => {},
        }
    }
    return false;
}

const testing = std.testing;

test unionOf {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one = try literal(a, .{ .number = 1 });
    const two = try literal(a, .{ .number = 2 });
    try testing.expect((try unionOf(a, &.{ one, one })).eql(one));
    try testing.expect((try unionOf(a, &.{ one, number })).eql(number));
    var buffer: [1]*const Type = undefined;
    try testing.expectEqual(2, (try unionOf(a, &.{ one, two })).members(&buffer).len);
    try testing.expect((try unionOf(a, &.{ never, string })).eql(string));
    try testing.expect((try unionOf(a, &.{ string, any })).eql(any));
    const nested = try unionOf(a, &.{ try unionOf(a, &.{ one, string }), two });
    try testing.expectEqual(3, nested.members(&buffer).len);
}

test comparable {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one = try literal(a, .{ .number = 1 });
    const two = try literal(a, .{ .number = 2 });
    try testing.expect(comparable(one, number));
    try testing.expect(comparable(one, one));
    try testing.expect(!comparable(one, two));
    try testing.expect(!comparable(number, string));
    try testing.expect(comparable(number, @"null"));
    try testing.expect(comparable(@"null", @"undefined"));
    try testing.expect(comparable(boolean, @"true"));
    try testing.expect(!comparable(@"true", @"false"));
    try testing.expect(comparable(try unionOf(a, &.{ one, string }), string));
    try testing.expect(comparable(any, string));
    try testing.expect(comparable(never, string));
}

test assignable {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one = try freshLiteral(a, .{ .number = 1 });
    try testing.expect(assignable(one, number));
    try testing.expect(!assignable(number, one));
    try testing.expect(assignable(boolean, try unionOf(a, &.{ @"true", @"false", string })));
    try testing.expect(assignable(@"undefined", @"void"));
    try testing.expect(!assignable(@"null", number));
    try testing.expect(assignable(try unionOf(a, &.{ one, string }), try unionOf(a, &.{ number, string })));
}

test widenFresh {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fresh = try unionOf(a, &.{ try freshLiteral(a, .{ .number = 1 }), try literal(a, .{ .string = "x" }) });
    try testing.expectFmt("number | \"x\"", "{f}", .{try widenFresh(a, fresh)});
    try testing.expectFmt("boolean", "{f}", .{try widenFresh(a, fresh_true)});
}

test "format" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = try unionOf(a, &.{ try literal(a, .{ .string = "x" }), try literal(a, .{ .number = 1.5 }), @"true", @"false" });
    try testing.expectFmt("boolean | \"x\" | 1.5", "{f}", .{t});
    try testing.expectFmt("string | number | null | undefined", "{f}", .{try unionOf(a, &.{ @"undefined", @"null", number, string })});
}
