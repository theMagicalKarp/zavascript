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

    pub const Literal = union(enum) {
        number: f64,
        string: []const u8,
        boolean: bool,
    };

    pub fn eql(a: *const Type, b: *const Type) bool {
        if (a == b) return true;
        return switch (a.*) {
            .literal => |x| b.* == .literal and literalEql(x, b.literal),
            .@"union" => |ms| b.* == .@"union" and ms.len == b.@"union".len and for (ms) |m| {
                if (!b.contains(m)) break false;
            } else true,
            .object => |o| b.* == .object and b.object == o,
            .function => |f| b.* == .function and b.function == f,
            else => std.meta.activeTag(a.*) == std.meta.activeTag(b.*),
        };
    }

    fn contains(this: *const Type, member: *const Type) bool {
        var buffer: [1]*const Type = undefined;
        for (this.members(&buffer)) |m| if (m.eql(member)) return true;
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
            .literal => |lit| switch (lit) {
                .number => |n| try @import("../runtime/number.zig").format(writer, n),
                .string => |s| try writer.print("\"{s}\"", .{s}),
                .boolean => |b| try writer.writeAll(if (b) "true" else "false"),
            },
            .@"union" => |ms| {
                // tsc prints `boolean` for `true | false`.
                var has_true = false;
                var has_false = false;
                for (ms) |m| if (m.* == .literal and m.literal == .boolean) {
                    if (m.literal.boolean) has_true = true else has_false = true;
                };
                var first = true;
                for (ms) |m| {
                    if (has_true and has_false and m.* == .literal and m.literal == .boolean) {
                        if (!m.literal.boolean) continue;
                        if (!first) try writer.writeAll(" | ");
                        try writer.writeAll("boolean");
                    } else {
                        if (!first) try writer.writeAll(" | ");
                        try writer.print("{f}", .{m});
                    }
                    first = false;
                }
            },
            .object => |o| try writer.writeAll(o.name),
            .function => |f| try f.format(writer),
            else => try writer.writeAll(@tagName(this.*)),
        }
    }
};

fn literalEql(a: Type.Literal, b: Type.Literal) bool {
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
        for (this.properties) |p| if (std.mem.eql(u8, p.name, name)) return p.type;
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
            if (i > 0) try writer.writeAll(", ");
            try writer.print("{s}: {f}", .{ p.name, p.type });
        }
        if (this.rest) |r| {
            if (this.parameters.len > 0) try writer.writeAll(", ");
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
pub const @"true": *const Type = &.{ .literal = .{ .boolean = true } };
pub const @"false": *const Type = &.{ .literal = .{ .boolean = false } };

/// The primitive a literal type belongs to (`1` → `number`); other types are unchanged.
/// `true | false` widens to `boolean`, and so on member by member for unions.
pub fn widen(arena: std.mem.Allocator, t: *const Type) error{OutOfMemory}!*const Type {
    return switch (t.*) {
        .literal => |lit| switch (lit) {
            .number => number,
            .string => string,
            .boolean => boolean,
        },
        .@"union" => |ms| blk: {
            var widened: std.ArrayList(*const Type) = .empty;
            for (ms) |m| try widened.append(arena, try widen(arena, m));
            break :blk unionOf(arena, widened.items);
        },
        else => t,
    };
}

/// The union of `parts`, flattened and deduplicated. Literals are absorbed by their primitive,
/// `never` disappears, and `any`/`unknown` swallow everything.
pub fn unionOf(arena: std.mem.Allocator, parts: []const *const Type) error{OutOfMemory}!*const Type {
    var list: std.ArrayList(*const Type) = .empty;
    for (parts) |part| {
        if (part.* == .any) return any;
        if (part.* == .unknown) return unknown;
        var buffer: [1]*const Type = undefined;
        for (part.members(&buffer)) |m| {
            if (m.* == .never) continue;
            var duplicate = false;
            for (list.items) |existing| if (existing.eql(m)) {
                duplicate = true;
            };
            if (!duplicate) try list.append(arena, m);
        }
    }
    // Drop literals whose primitive is also present.
    var i: usize = 0;
    while (i < list.items.len) {
        const m = list.items[i];
        if (m.* == .literal) {
            const base = try widen(arena, m);
            const has_base = for (list.items) |other| {
                if (other.eql(base)) break true;
            } else false;
            if (has_base) {
                _ = list.orderedRemove(i);
                continue;
            }
        }
        i += 1;
    }
    if (list.items.len == 0) return never;
    if (list.items.len == 1) return list.items[0];
    return asPtr(.{ .@"union" = list.items }, arena);
}

fn asPtr(t: Type, arena: std.mem.Allocator) error{OutOfMemory}!*const Type {
    const p = try arena.create(Type);
    p.* = t;
    return p;
}

pub fn literal(arena: std.mem.Allocator, lit: Type.Literal) error{OutOfMemory}!*const Type {
    if (lit == .boolean) return if (lit.boolean) @"true" else @"false";
    return asPtr(.{ .literal = lit }, arena);
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
    if (a.* == .any or b.* == .any or a.* == .unknown or b.* == .unknown) return true;
    var a_buffer: [1]*const Type = undefined;
    var b_buffer: [1]*const Type = undefined;
    for (expandBoolean(a, &a_buffer)) |x| for (expandBoolean(b, &b_buffer)) |y| if (overlaps(x, y)) return true;
    return false;
}

fn overlaps(x: *const Type, y: *const Type) bool {
    // Under strict null checks, tsc still allows comparing anything with `null` or `undefined`.
    if (isNullish(x) or isNullish(y)) return true;
    if (x.* == .never or y.* == .never) return false;
    if (x.* == .literal and y.* == .literal) return literalEql(x.literal, y.literal);
    if (x.* == .object and y.* == .object) return x.object == y.object;
    if (x.* == .function and y.* == .function) return true;
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
        .literal => |lit| switch (lit) {
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
    for (t.members(&buffer)) |m| if (primitiveKind(m) != kind) return false;
    return true;
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
}

test "format" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = try unionOf(a, &.{ try literal(a, .{ .string = "x" }), try literal(a, .{ .number = 1.5 }), @"true", @"false" });
    try testing.expectFmt("\"x\" | 1.5 | boolean", "{f}", .{t});
}
