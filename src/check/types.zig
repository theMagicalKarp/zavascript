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
    /// `T[]`, with the element type.
    array: *const Type,
    /// `[T, U]`, with the element types.
    tuple: []const *const Type,

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
            .object => |o| b.* == .object and (b.object == o or o.eql(b.object)),
            .function => |f| b.* == .function and (b.function == f or f.eql(b.function)),
            .array => |e| b.* == .array and e.eql(b.array),
            .tuple => |es| b.* == .tuple and es.len == b.tuple.len and for (es, b.tuple) |x, y| {
                if (!x.eql(y)) {
                    break false;
                }
            } else true,
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
                try m.formatParenthesized(writer, m.* == .function);
            },
            .object => |o| try o.format(writer),
            .function => |f| try f.format(writer),
            .array => |e| {
                try e.formatParenthesized(writer, e.* == .function or e.* == .@"union");
                try writer.writeAll("[]");
            },
            .tuple => |es| {
                try writer.writeAll("[");
                for (es, 0..) |e, i| {
                    try writer.print("{s}{f}", .{ if (i > 0) ", " else "", e });
                }
                try writer.writeAll("]");
            },
            else => try writer.writeAll(@tagName(this.*)),
        }
    }

    fn formatParenthesized(this: *const Type, writer: *std.Io.Writer, parenthesize: bool) std.Io.Writer.Error!void {
        if (parenthesize) {
            try writer.print("({f})", .{this});
        } else {
            try writer.print("{f}", .{this});
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
    /// For an optional property, this includes `undefined`.
    type: *const Type,
    optional: bool = false,
    readonly: bool = false,
    /// Declared as a method (`m(): void`), which only changes how it's shown.
    method: bool = false,

    fn eql(a: Property, b: Property) bool {
        return std.mem.eql(u8, a.name, b.name) and a.optional == b.optional and a.readonly == b.readonly and a.method == b.method and a.type.eql(b.type);
    }
};

/// An object type: an interface, a type alias's object type, or an anonymous one like
/// `{ a: number }` or an object literal's.
pub const Object = struct {
    /// Shown in diagnostics, e.g. `Console`. Empty for an anonymous object type, which is shown
    /// by its members and compared structurally; a named one is only equal to itself.
    name: []const u8 = "",
    properties: []const Property,

    pub fn property(this: *const Object, name: []const u8) ?*const Type {
        const p = this.find(name) orelse return null;
        return p.type;
    }

    pub fn find(this: *const Object, name: []const u8) ?*const Property {
        for (this.properties) |*p| {
            if (std.mem.eql(u8, p.name, name)) {
                return p;
            }
        }
        return null;
    }

    fn eql(a: *const Object, b: *const Object) bool {
        if (a.name.len > 0 or b.name.len > 0 or a.properties.len != b.properties.len) {
            return false;
        }
        for (a.properties) |p| {
            const q = b.find(p.name) orelse return false;
            if (!p.eql(q.*)) {
                return false;
            }
        }
        return true;
    }

    pub fn format(this: *const Object, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (this.name.len > 0) {
            return writer.writeAll(this.name);
        }
        if (this.properties.len == 0) {
            return writer.writeAll("{}");
        }
        try writer.writeAll("{ ");
        for (this.properties) |p| {
            if (p.readonly) {
                try writer.writeAll("readonly ");
            }
            try writer.print("{s}{s}", .{ p.name, if (p.optional) "?" else "" });
            if (p.method and p.type.* == .function) {
                try p.type.function.formatParameters(writer);
                try writer.print(": {f}; ", .{p.type.function.returns});
            } else {
                try writer.print(": {f}; ", .{p.type});
            }
        }
        try writer.writeAll("}");
    }
};

pub const Parameter = struct {
    name: []const u8,
    /// For a `b?: T` parameter this is `T | undefined`; for one with a default value, just `T`.
    type: *const Type,
    /// It has a `?` or a default value, so an argument for it can be left out.
    optional: bool = false,
};

pub const Function = struct {
    parameters: []const Parameter,
    /// A `...rest` parameter, whose type is an array type.
    rest: ?Parameter = null,
    returns: *const Type,
    /// The return type is still being inferred from the body, and is `any` until it is. A call
    /// in the meantime is a circular reference (TS7023).
    pending: bool = false,

    /// How many arguments a call must pass.
    pub fn minArguments(this: *const Function) usize {
        var count: usize = 0;
        for (this.parameters, 0..) |p, i| {
            if (!p.optional) {
                count = i + 1;
            }
        }
        return count;
    }

    /// The type an argument at `index` must have, or null if there's no parameter for it.
    pub fn parameterType(this: *const Function, index: usize) ?*const Type {
        if (index < this.parameters.len) {
            return this.parameters[index].type;
        }
        const rest = this.rest orelse return null;
        return rest.type.array;
    }

    pub fn eql(a: *const Function, b: *const Function) bool {
        if (a.parameters.len != b.parameters.len or (a.rest == null) != (b.rest == null) or a.pending or b.pending) {
            return false;
        }
        for (a.parameters, b.parameters) |x, y| {
            if (x.optional != y.optional or !std.mem.eql(u8, x.name, y.name) or !x.type.eql(y.type)) {
                return false;
            }
        }
        if (a.rest) |r| {
            if (!std.mem.eql(u8, r.name, b.rest.?.name) or !r.type.eql(b.rest.?.type)) {
                return false;
            }
        }
        return a.returns.eql(b.returns);
    }

    pub fn format(this: *const Function, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try this.formatParameters(writer);
        try writer.print(" => {f}", .{this.returns});
    }

    fn formatParameters(this: *const Function, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll("(");
        for (this.parameters, 0..) |p, i| {
            if (i > 0) {
                try writer.writeAll(", ");
            }
            try writer.print("{s}{s}: {f}", .{ p.name, if (p.optional) "?" else "", p.type });
        }
        if (this.rest) |r| {
            if (this.parameters.len > 0) {
                try writer.writeAll(", ");
            }
            try writer.print("...{s}: {f}", .{ r.name, r.type });
        }
        try writer.writeAll(")");
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
pub const any_array: *const Type = &.{ .array = any };
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

/// `t` with its fresh literals made regular, as `as const` and narrowing do: they no longer widen.
pub fn regular(arena: std.mem.Allocator, t: *const Type) error{OutOfMemory}!*const Type {
    return switch (t.*) {
        .literal => |lit| if (lit.fresh) literal(arena, lit.value) else t,
        .@"union" => |ms| blk: {
            var list: std.ArrayList(*const Type) = .empty;
            for (ms) |m| {
                try list.append(arena, try regular(arena, m));
            }
            break :blk unionOf(arena, list.items);
        },
        else => t,
    };
}

/// tsc's `isUnitType`: a type with a single value.
pub fn isUnit(t: *const Type) bool {
    return t.* == .literal or t.* == .null or t.* == .undefined;
}

/// The anonymous object type `{}`, which every value but `null` and `undefined` belongs to.
pub const empty_object: *const Type = &.{ .object = &.{ .properties = &.{} } };

/// Whether `t` is an object type without properties, like `{}`, which a primitive can be too.
pub fn isEmptyObject(t: *const Type) bool {
    return t.* == .object and t.object.properties.len == 0;
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

/// `t` with its members in the order `like` has them, for a union made from parts of `like` (as
/// where control flow joins), which tsc would print in `like`'s order.
pub fn orderLike(arena: std.mem.Allocator, t: *const Type, like: *const Type) error{OutOfMemory}!*const Type {
    if (t.* != .@"union" or like.* != .@"union") {
        return t;
    }
    const Ordered = struct {
        like: []const *const Type,
        fn index(this: @This(), m: *const Type) usize {
            for (this.like, 0..) |l, i| {
                if (l.eql(m)) {
                    return i;
                }
            }
            return this.like.len;
        }
        fn before(this: @This(), a: *const Type, b: *const Type) bool {
            const ra = printRank(a);
            const rb = printRank(b);
            return ra < rb or (ra == rb and this.index(a) < this.index(b));
        }
    };
    const list = try arena.dupe(*const Type, t.@"union");
    std.mem.sort(*const Type, list, Ordered{ .like = like.@"union" }, Ordered.before);
    return asPtr(.{ .@"union" = list }, arena);
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
        .object, .function, .array, .tuple => 7,
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
    return comparableWith(a, b, true);
}

/// tsc's `areTypesComparable`, which narrowing uses: like `comparable`, except that `null` and
/// `undefined` are only comparable to themselves.
pub fn overlap(a: *const Type, b: *const Type) bool {
    return comparableWith(a, b, false);
}

fn comparableWith(a: *const Type, b: *const Type, nullish_with_anything: bool) bool {
    if (a.* == .any or b.* == .any or a.* == .unknown or b.* == .unknown) {
        return true;
    }
    var a_buffer: [1]*const Type = undefined;
    var b_buffer: [1]*const Type = undefined;
    for (expandBoolean(a, &a_buffer)) |x| {
        for (expandBoolean(b, &b_buffer)) |y| {
            if (overlaps(x, y, nullish_with_anything)) {
                return true;
            }
        }
    }
    return false;
}

fn overlaps(x: *const Type, y: *const Type, nullish_with_anything: bool) bool {
    if (isNullish(x) or isNullish(y)) {
        // Under strict null checks, tsc still allows comparing anything with `null` or
        // `undefined`.
        return nullish_with_anything or std.meta.activeTag(x.*) == std.meta.activeTag(y.*) or x.* == .never or y.* == .never;
    }
    // `never` is related to everything.
    if (x.* == .never or y.* == .never) {
        return true;
    }
    if (x.* == .literal and y.* == .literal) {
        return literalEql(x.literal.value, y.literal.value);
    }
    if (x.* == .function and y.* == .function) {
        return true;
    }
    if (x.* == .array and y.* == .array) {
        return comparableWith(x.array, y.array, nullish_with_anything);
    }
    if (isObjectLike(x) or isObjectLike(y)) {
        // tsc's comparable relation holds when either side is assignable to the other, as a
        // primitive is to `{}`.
        return assignable(x, y) or assignable(y, x);
    }
    return primitiveKind(x) != .other and primitiveKind(x) == primitiveKind(y);
}

fn isObjectLike(t: *const Type) bool {
    return switch (t.*) {
        .object, .function, .array, .tuple => true,
        else => false,
    };
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

/// tsc's comparable relation, which `as` uses: like assignability, except that a union source only
/// needs one member to be related, and optional properties needn't be present.
pub fn comparableTo(source: *const Type, target: *const Type) bool {
    return comparableIn(source, target, 0);
}

fn comparableIn(source: *const Type, target: *const Type, depth: u32) bool {
    if (depth > 64 or source.eql(target)) {
        return true;
    }
    if (target.* == .any or target.* == .unknown or source.* == .any or source.* == .never or source.* == .unknown) {
        return true;
    }
    if (source.* == .@"union" or source.* == .boolean) {
        var buffer: [1]*const Type = undefined;
        for (expandBoolean(source, &buffer)) |m| {
            if (comparableIn(m, target, depth + 1)) {
                return true;
            }
        }
        return false;
    }
    if (target.* == .@"union" or target.* == .boolean) {
        var buffer: [1]*const Type = undefined;
        for (expandBoolean(target, &buffer)) |m| {
            if (comparableIn(source, m, depth + 1)) {
                return true;
            }
        }
        return false;
    }
    return switch (target.*) {
        .array => |element| switch (source.*) {
            .array => |e| comparableIn(e, element, depth + 1),
            .tuple => |es| for (es) |e| {
                if (!comparableIn(e, element, depth + 1)) {
                    break false;
                }
            } else true,
            else => false,
        },
        .tuple => |ts| source.* == .tuple and source.tuple.len == ts.len and for (source.tuple, ts) |s, t| {
            if (!comparableIn(s, t, depth + 1)) {
                break false;
            }
        } else true,
        .object => |o| switch (source.*) {
            .object => |so| for (o.properties) |p| {
                const sp = so.find(p.name) orelse if (p.optional) continue else break false;
                if (!comparableIn(sp.type, p.type, depth + 1)) {
                    break false;
                }
            } else true,
            else => assignable(source, target),
        },
        else => assignable(source, target),
    };
}

/// Whether a value of type `source` can be used where `target` is expected.
pub fn assignable(source: *const Type, target: *const Type) bool {
    return assignableIn(source, target, null);
}

/// Pairs of types being related further up, which are assumed to be related, so that recursive
/// types like `interface List { next?: List }` terminate (tsc's "maybe" stack).
pub const Assumption = struct {
    source: *const Type,
    target: *const Object,
    parent: ?*const Assumption,
    depth: u32,

    fn holds(this: ?*const Assumption, source: *const Type, target: *const Object) bool {
        var a = this;
        while (a) |x| : (a = x.parent) {
            if (x.source == source and x.target == target) {
                return true;
            }
        }
        return false;
    }
};

fn assignableIn(source: *const Type, target: *const Type, assumed: ?*const Assumption) bool {
    if (source.eql(target)) {
        return true;
    }
    if (target.* == .any or target.* == .unknown or source.* == .any or source.* == .never) {
        return true;
    }
    if (source.* == .@"union") {
        for (source.@"union") |m| {
            if (!assignableIn(m, target, assumed)) {
                return false;
            }
        }
        return true;
    }
    if (source.* == .boolean) {
        return assignableIn(@"true", target, assumed) and assignableIn(@"false", target, assumed);
    }
    if (target.* == .@"union") {
        for (target.@"union") |m| {
            if (assignableIn(source, m, assumed)) {
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
        .array => |element| switch (source.*) {
            .array => |e| assignableIn(e, element, assumed),
            .tuple => |es| for (es) |e| {
                if (!assignableIn(e, element, assumed)) {
                    break false;
                }
            } else true,
            else => false,
        },
        .tuple => |ts| source.* == .tuple and source.tuple.len == ts.len and for (source.tuple, ts) |s, t| {
            if (!assignableIn(s, t, assumed)) {
                break false;
            }
        } else true,
        .function => |f| source.* == .function and functionMismatchIn(source.function, f, assumed) == null,
        .object => |o| objectMismatch(source, o, assumed) == null,
        else => false,
    };
}

/// Why `source` isn't assignable to the object type `target`, for tsc's elaborations, or null if
/// it is.
pub const ObjectMismatch = union(enum) {
    /// `null`, `undefined` or another type that can't be an object.
    not_object,
    /// It lacks required properties; see `missingProperties`.
    missing,
    /// The property is optional in `source` but required in `target`.
    optional: []const u8,
    /// The types of this property don't match.
    property: []const u8,
};

pub fn objectMismatch(source: *const Type, target: *const Object, assumed: ?*const Assumption) ?ObjectMismatch {
    switch (source.*) {
        .null, .undefined, .void, .unknown => return .not_object,
        .object => |s| {
            if (s == target or Assumption.holds(assumed, source, target)) {
                return null;
            }
            for (target.properties) |p| {
                if (!p.optional and s.find(p.name) == null) {
                    return .missing;
                }
            }
            const depth = if (assumed) |a| a.depth + 1 else 0;
            if (depth > 64) {
                return null;
            }
            const link: Assumption = .{ .source = source, .target = target, .parent = assumed, .depth = depth };
            for (target.properties) |p| {
                const sp = s.find(p.name) orelse continue;
                if (!assignableIn(sp.type, p.type, &link)) {
                    return .{ .property = p.name };
                }
            }
            for (target.properties) |p| {
                const sp = s.find(p.name) orelse continue;
                if (sp.optional and !p.optional) {
                    return .{ .optional = p.name };
                }
            }
            return null;
        },
        else => {
            // Primitives, arrays and functions: of the properties they have, only `length` is
            // known so far.
            for (target.properties) |p| {
                if (p.optional) {
                    continue;
                }
                const has_length = source.* == .array or source.* == .tuple or source.* == .function;
                if (!has_length or !std.mem.eql(u8, p.name, "length")) {
                    return .missing;
                }
                const length: Type = if (source.* == .tuple) .{ .literal = .{ .value = .{ .number = @floatFromInt(source.tuple.len) } } } else .number;
                if (!assignableIn(&length, p.type, assumed)) {
                    return .{ .property = p.name };
                }
            }
            return null;
        },
    }
}

/// The required properties of `target` that `source` lacks.
pub fn missingProperties(arena: std.mem.Allocator, source: *const Type, target: *const Object) error{OutOfMemory}![]const []const u8 {
    var missing: std.ArrayList([]const u8) = .empty;
    for (target.properties) |p| {
        if (p.optional) {
            continue;
        }
        const has = switch (source.*) {
            .object => |s| s.find(p.name) != null,
            .array, .tuple, .function => std.mem.eql(u8, p.name, "length"),
            else => false,
        };
        if (!has) {
            try missing.append(arena, p.name);
        }
    }
    return missing.items;
}

/// Whether a function of type `source` can be called the way `target` says it will be: with at
/// least as many arguments as `source` needs, of types its parameters accept (compared
/// contravariantly, as `strictFunctionTypes` does), and returning what `target` returns.
pub fn functionAssignable(source: *const Function, target: *const Function) bool {
    return functionMismatch(source, target) == null;
}

/// Why `source` isn't assignable to `target`, for tsc's elaborations, or null if it is.
pub const FunctionMismatch = union(enum) {
    /// `target` passes fewer arguments than `source` requires.
    arity: usize,
    /// The parameters at this index don't match.
    parameter: usize,
    returns,
};

pub fn functionMismatch(source: *const Function, target: *const Function) ?FunctionMismatch {
    return functionMismatchIn(source, target, null);
}

fn functionMismatchIn(source: *const Function, target: *const Function, assumed: ?*const Assumption) ?FunctionMismatch {
    if (target.rest == null and source.minArguments() > target.parameters.len) {
        return .{ .arity = source.minArguments() };
    }
    const count = @max(source.parameters.len, target.parameters.len) + @intFromBool(source.rest != null and target.rest != null);
    for (0..count) |i| {
        const s = source.parameterType(i) orelse continue;
        const t = target.parameterType(i) orelse continue;
        if (!assignableIn(t, s, assumed)) {
            return .{ .parameter = i };
        }
    }
    if (target.returns.* != .void and !assignableIn(source.returns, target.returns, assumed)) {
        return .returns;
    }
    return null;
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

/// tsc's `isLiteralType`: a literal, `null`, `undefined`, `boolean`, or a union of those. Only
/// such a source type is shown widened in "not assignable" messages.
pub fn isLiteralType(t: *const Type) bool {
    var buffer: [1]*const Type = undefined;
    for (t.members(&buffer)) |m| {
        switch (m.*) {
            .literal, .null, .undefined, .boolean => {},
            else => return false,
        }
    }
    return true;
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

test "function types" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const number_array = try asPtr(.{ .array = number }, a);
    const f: Type = .{ .function = &.{
        .parameters = &.{ .{ .name = "a", .type = number }, .{ .name = "b", .type = try unionOf(a, &.{ string, @"undefined" }), .optional = true } },
        .rest = .{ .name = "c", .type = number_array },
        .returns = @"void",
    } };
    try testing.expectFmt("(a: number, b?: string | undefined, ...c: number[]) => void", "{f}", .{&f});
    const g: Type = .{ .function = &.{ .parameters = &.{.{ .name = "x", .type = number }}, .returns = number } };
    try testing.expectFmt("((x: number) => number)[] | undefined", "{f}", .{try unionOf(a, &.{ try asPtr(.{ .array = &g }, a), @"undefined" })});
    // Fewer parameters is fine; more required ones isn't.
    const none: Type = .{ .function = &.{ .parameters = &.{}, .returns = number } };
    try testing.expect(assignable(&none, &g));
    try testing.expect(!assignable(&g, &none));
    // Parameters are compared contravariantly.
    const takes_one: Type = .{ .function = &.{ .parameters = &.{.{ .name = "x", .type = try literal(a, .{ .number = 1 }) }}, .returns = number } };
    try testing.expect(assignable(&g, &takes_one));
    try testing.expect(!assignable(&takes_one, &g));
    // Anything can be returned where `void` is expected.
    const returns_void: Type = .{ .function = &.{ .parameters = &.{}, .returns = @"void" } };
    try testing.expect(assignable(&g, &returns_void) == false);
    try testing.expect(assignable(&none, &returns_void));
    try testing.expect(!assignable(&returns_void, &none));
}

test "format" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = try unionOf(a, &.{ try literal(a, .{ .string = "x" }), try literal(a, .{ .number = 1.5 }), @"true", @"false" });
    try testing.expectFmt("boolean | \"x\" | 1.5", "{f}", .{t});
    try testing.expectFmt("string | number | null | undefined", "{f}", .{try unionOf(a, &.{ @"undefined", @"null", number, string })});
}
