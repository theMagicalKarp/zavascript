//! How a test narrows a type: what tsc's `narrowTypeByTruthiness`, `narrowTypeByEquality`,
//! `narrowTypeByTypeof`, `narrowTypeByInKeyword` and `narrowTypeByDiscriminant` compute, for the
//! true or the false outcome of the test. These only work with types; the checker decides what's
//! narrowed and where.

const std = @import("std");
const types = @import("types.zig");
const Type = types.Type;

const Error = error{OutOfMemory};

/// A test that narrows what it's applied to.
pub const Test = union(enum) {
    /// The value is truthy.
    truthy,
    /// `=== value`, or `== value` when `loose`.
    equal: struct { value: *const Type, loose: bool = false },
    /// `typeof x === name`.
    typeof: []const u8,
    /// `name in x`.
    in: []const u8,
};

/// The type of something of type `t` once `test` is known to be `assume`. Null when the narrowed
/// type is one we can't represent yet (like tsc's `object`, or an intersection).
pub fn narrow(arena: std.mem.Allocator, t: *const Type, test_: Test, assume: bool) Error!?*const Type {
    return switch (test_) {
        .truthy => try truthiness(arena, t, assume),
        .equal => |e| try equality(arena, t, e.value, e.loose, assume),
        .typeof => |name| typeOf(arena, t, name, assume),
        .in => |name| inKeyword(arena, t, name, assume),
    };
}

/// `null` or `undefined` taken out: what tsc's `NEUndefinedOrNull` facts leave.
pub fn nonNullish(arena: std.mem.Allocator, t: *const Type) Error!*const Type {
    return (try equality(arena, t, types.null, true, false)).?;
}

fn truthiness(arena: std.mem.Allocator, t: *const Type, assume: bool) Error!*const Type {
    if (t.* == .any) {
        return t;
    }
    if (t.* == .unknown) {
        return if (assume) types.empty_object else t;
    }
    var kept: std.ArrayList(*const Type) = .empty;
    for (try types.expandedMembers(arena, t)) |m| {
        if (if (assume) canBeTruthy(m) else canBeFalsy(m)) {
            try kept.append(arena, m);
        }
    }
    return types.unionOf(arena, kept.items);
}

pub fn isFalsyLiteral(t: *const Type) bool {
    return switch (t.*) {
        .null, .undefined, .void => true,
        .literal => |lit| switch (lit.value) {
            .number => |n| n == 0 or std.math.isNan(n),
            .string => |s| s.len == 0,
            .boolean => |b| !b,
        },
        else => false,
    };
}

fn canBeTruthy(t: *const Type) bool {
    return !isFalsyLiteral(t) and t.* != .never;
}

fn canBeFalsy(t: *const Type) bool {
    return switch (t.*) {
        .literal => isFalsyLiteral(t),
        .object => types.isEmptyObject(t),
        .function, .array, .readonly_array, .tuple, .never => false,
        else => true,
    };
}

/// What `null` and `undefined` tests (`=== null`, `!== undefined`, `== null`, ...) keep.
const Nullish = enum { null, undefined, both };

fn nullishFacts(arena: std.mem.Allocator, t: *const Type, which: Nullish, assume: bool) Error!*const Type {
    if (t.* == .unknown) {
        // tsc's `getAdjustedTypeWithFacts` for `unknown`.
        if (assume) {
            return switch (which) {
                .null => types.null,
                .undefined => types.undefined,
                .both => types.unionOf(arena, &.{ types.null, types.undefined }),
            };
        }
        return switch (which) {
            .null => types.unionOf(arena, &.{ types.empty_object, types.undefined }),
            .undefined => types.unionOf(arena, &.{ types.empty_object, types.null }),
            .both => types.empty_object,
        };
    }
    var kept: std.ArrayList(*const Type) = .empty;
    var buffer: [1]*const Type = undefined;
    for (t.members(&buffer)) |m| {
        const is = switch (m.*) {
            .null => which != .undefined,
            .undefined, .void => which != .null,
            else => false,
        };
        // `{}` can't be `null` or `undefined`.
        if (is == assume) {
            try kept.append(arena, m);
        }
    }
    return types.unionOf(arena, kept.items);
}

fn equality(arena: std.mem.Allocator, t: *const Type, value_type: *const Type, loose: bool, assume: bool) Error!?*const Type {
    if (t.* == .any) {
        return t;
    }
    // A fresh literal stays fresh, so `let y = x` after `x === "a"` still widens.
    const value = value_type;
    if (value.* == .null or value.* == .undefined) {
        const which: Nullish = if (loose) .both else if (value.* == .null) .null else .undefined;
        return try nullishFacts(arena, t, which, assume);
    }
    if (assume) {
        const has_empty = blk: {
            var buffer: [1]*const Type = undefined;
            for (t.members(&buffer)) |m| {
                if (types.isEmptyObject(m)) {
                    break :blk true;
                }
            }
            break :blk false;
        };
        if (!loose and (t.* == .unknown or has_empty)) {
            switch (value.*) {
                .void, .undefined, .null, .boolean, .number, .string, .bigint, .literal => return value,
                .object, .function, .array, .tuple, .readonly_array => return if (types.isEmptyObject(value)) value else null,
                // That'd be an intersection with the type parameter.
                .param, .keyof, .indexed, .mapped => return null,
                // A union, `any`, `unknown` or `never` says nothing tsc keeps: what can be
                // compared with it stays.
                .@"union", .any, .unknown, .never => if (t.* == .unknown) return t,
            }
        }
        var kept: std.ArrayList(*const Type) = .empty;
        for (try types.expandedMembers(arena, t)) |m| {
            if (types.overlap(m, value) or (loose and coercible(m, value))) {
                try kept.append(arena, m);
            }
        }
        return try replacePrimitivesWithLiterals(arena, kept.items, value);
    }
    if (!types.isUnit(value)) {
        return t;
    }
    var kept: std.ArrayList(*const Type) = .empty;
    for (try types.expandedMembers(arena, t)) |m| {
        if (!(types.isUnit(m) and types.overlap(m, value))) {
            try kept.append(arena, m);
        }
    }
    return try types.unionOf(arena, kept.items);
}

/// tsc's `isCoercibleUnderDoubleEquals`: `==` can compare these even when `===` couldn't.
fn coercible(source: *const Type, target: *const Type) bool {
    const s = source.* == .number or source.* == .string or (source.* == .literal and source.literal.value == .boolean);
    var buffer: [1]*const Type = undefined;
    const t = for (target.members(&buffer)) |m| {
        if (m.* == .number or m.* == .string or m.* == .boolean or (m.* == .literal and m.literal.value == .boolean)) {
            break true;
        }
    } else false;
    return s and t;
}

/// tsc's `replacePrimitivesWithLiterals`: after `x === "a"`, a `string` in `x`'s type is `"a"`.
fn replacePrimitivesWithLiterals(arena: std.mem.Allocator, kept: []const *const Type, value: *const Type) Error!*const Type {
    var buffer: [1]*const Type = undefined;
    const literals = value.members(&buffer);
    var list: std.ArrayList(*const Type) = .empty;
    for (kept) |m| {
        const kind: ?std.meta.Tag(Type.Literal.Value) = switch (m.*) {
            .string => .string,
            .number => .number,
            else => null,
        };
        var replaced = false;
        if (kind) |k| {
            for (literals) |lit| {
                if (lit.* == .literal and lit.literal.value == k) {
                    try list.append(arena, lit);
                    replaced = true;
                }
            }
        }
        if (!replaced) {
            try list.append(arena, m);
        }
    }
    return types.unionOf(arena, list.items);
}

/// What `typeof` gives for every value of `t`, or null if that depends on the value.
fn typeofName(t: *const Type) ?[]const u8 {
    return switch (t.*) {
        .string => "string",
        .number => "number",
        .bigint => "bigint",
        .boolean => "boolean",
        .literal => |lit| switch (lit.value) {
            .string => "string",
            .number => "number",
            .boolean => "boolean",
        },
        .undefined, .void => "undefined",
        .null, .array, .tuple, .readonly_array, .mapped => "object",
        .object => if (types.isEmptyObject(t)) null else "object",
        .function => "function",
        .any, .unknown, .never, .@"union", .param, .keyof, .indexed => null,
    };
}

/// The type `typeof x === name` implies `x` has, for the primitive names.
fn impliedType(name: []const u8) ?*const Type {
    const map = std.StaticStringMap(*const Type).initComptime(.{
        .{ "string", types.string },
        .{ "number", types.number },
        .{ "boolean", types.boolean },
        .{ "undefined", types.undefined },
    });
    return map.get(name);
}

fn typeOf(arena: std.mem.Allocator, t: *const Type, name: []const u8, assume: bool) Error!?*const Type {
    if (!assume) {
        if (t.* == .any or t.* == .unknown) {
            return t;
        }
        var kept: std.ArrayList(*const Type) = .empty;
        var buffer: [1]*const Type = undefined;
        for (t.members(&buffer)) |m| {
            const n = typeofName(m) orelse {
                try kept.append(arena, m);
                continue;
            };
            if (!std.mem.eql(u8, n, name)) {
                try kept.append(arena, m);
            }
        }
        return try types.unionOf(arena, kept.items);
    }
    if (t.* == .any and (std.mem.eql(u8, name, "object") or std.mem.eql(u8, name, "function"))) {
        return t;
    }
    var kept: std.ArrayList(*const Type) = .empty;
    var buffer: [1]*const Type = undefined;
    for (t.members(&buffer)) |m| {
        if (typeofName(m)) |n| {
            if (std.mem.eql(u8, n, name)) {
                try kept.append(arena, m);
            }
            continue;
        }
        switch (m.*) {
            .never => {},
            // That'd be an intersection, like `T & string`.
            .param, .keyof, .indexed => return null,
            // `any`, `unknown` and `{}` become the type the name implies; tsc's `object` and
            // `Function` aren't there yet.
            else => {
                if (types.isEmptyObject(m) and std.mem.eql(u8, name, "undefined")) {
                    continue;
                }
                try kept.append(arena, impliedType(name) orelse return null);
            },
        }
    }
    return try types.unionOf(arena, kept.items);
}

fn inKeyword(arena: std.mem.Allocator, t: *const Type, name: []const u8, assume: bool) Error!?*const Type {
    if (t.* == .any or t.* == .unknown) {
        return t;
    }
    var buffer: [1]*const Type = undefined;
    const ms = t.members(&buffer);
    // A property no member declares would make the type an intersection with
    // `Record<name, unknown>`.
    const known = for (ms) |m| {
        if (presencePossible(m, name, true)) {
            break true;
        }
    } else false;
    if (!known) {
        return if (assume) null else t;
    }
    var kept: std.ArrayList(*const Type) = .empty;
    for (ms) |m| {
        if (presencePossible(m, name, assume)) {
            try kept.append(arena, m);
        }
    }
    return try types.unionOf(arena, kept.items);
}

/// tsc's `isTypePresencePossible`: whether a value of type `t` can have (or lack) the property.
fn presencePossible(t: *const Type, name: []const u8, assume: bool) bool {
    const optional: ?bool = switch (t.*) {
        .object => |o| if (o.find(name)) |p| p.optional else null,
        .array, .readonly_array, .tuple, .function => if (std.mem.eql(u8, name, "length")) false else null,
        else => return true,
    };
    if (optional) |o| {
        return o or assume;
    }
    return !assume;
}

/// tsc's `isDiscriminantProperty`: `t` is a union whose members have the property with different
/// types, at least one of them a literal.
pub fn isDiscriminant(t: *const Type, name: []const u8) bool {
    if (t.* != .@"union") {
        return false;
    }
    var first: ?*const Type = null;
    var uniform = true;
    var has_literal = false;
    for (t.@"union") |m| {
        if (m.* != .object) {
            continue;
        }
        const p = m.object.find(name) orelse continue;
        if (types.isLiteralType(p.type)) {
            has_literal = true;
        }
        if (first) |f| {
            if (!f.eql(p.type)) {
                uniform = false;
            }
        } else {
            first = p.type;
        }
    }
    return has_literal and !uniform;
}

/// The type of property `name` of a union's members that have it.
fn propertyType(arena: std.mem.Allocator, t: *const Type, name: []const u8) Error!*const Type {
    var parts: std.ArrayList(*const Type) = .empty;
    var buffer: [1]*const Type = undefined;
    for (t.members(&buffer)) |m| {
        if (m.* == .object) {
            if (m.object.find(name)) |p| {
                try parts.append(arena, p.type);
            }
        }
    }
    return types.unionOf(arena, parts.items);
}

/// tsc's `narrowTypeByDiscriminant`: narrows a union by a test of one of its properties, keeping
/// the members whose property could pass it. Through an optional chain (`optional`), the property
/// can be `undefined` too.
pub fn byDiscriminant(arena: std.mem.Allocator, t: *const Type, name: []const u8, test_: Test, assume: bool, optional: bool) Error!?*const Type {
    var property = try propertyType(arena, t, name);
    if (optional) {
        property = try types.unionOf(arena, &.{ property, types.undefined });
    }
    const narrowed = try narrow(arena, property, test_, assume) orelse return null;
    if (narrowed.* == .never) {
        return types.never;
    }
    var kept: std.ArrayList(*const Type) = .empty;
    var buffer: [1]*const Type = undefined;
    for (t.members(&buffer)) |m| {
        const p: *const Type = if (m.* == .object) if (m.object.find(name)) |p| p.type else types.unknown else types.unknown;
        if (p.* != .never and types.overlap(narrowed, p)) {
            try kept.append(arena, m);
        }
    }
    return try types.unionOf(arena, kept.items);
}

const testing = std.testing;

fn expectNarrowed(expected: []const u8, t: *const Type, test_: Test, assume: bool) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectFmt(expected, "{f}", .{(try narrow(arena.allocator(), t, test_, assume)).?});
}

test narrow {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const x = try types.literal(a, .{ .string = "x" });
    const t = try types.unionOf(a, &.{ types.string, types.number, types.boolean, types.null, types.undefined });
    try expectNarrowed("string | number | true", t, .truthy, true);
    try expectNarrowed("string | number | false | null | undefined", t, .truthy, false);
    try expectNarrowed("\"x\"", t, .{ .equal = .{ .value = x } }, true);
    try expectNarrowed("string | number | boolean | undefined", t, .{ .equal = .{ .value = types.null } }, false);
    try expectNarrowed("string | number | boolean", t, .{ .equal = .{ .value = types.null, .loose = true } }, false);
    try expectNarrowed("string | boolean | null | undefined", t, .{ .typeof = "number" }, false);
    try expectNarrowed("null", t, .{ .typeof = "object" }, true);
    try expectNarrowed("{}", types.unknown, .truthy, true);
    try expectNarrowed("string", types.unknown, .{ .typeof = "string" }, true);
    try testing.expectEqual(null, try narrow(a, types.unknown, .{ .typeof = "object" }, true));
}
