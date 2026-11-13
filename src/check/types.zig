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
    /// `readonly T[]` or `ReadonlyArray<T>`, with the element type.
    readonly_array: *const Type,
    /// A type parameter, like the `T` of `function f<T>(x: T)`. Each is only equal to itself.
    param: *const Param,
    /// `keyof T`, for a `T` that's generic, so its keys aren't known yet.
    keyof: *const Type,
    /// `T[K]`, when `T` or `K` is generic.
    indexed: Indexed,
    /// `{ [P in K]: X }`, when `K` is generic.
    mapped: *const Mapped,
    /// tsc's `object`: anything but a primitive.
    non_primitive,
    /// `A & B`, with at least two members. Only the library has these so far.
    intersection: []const *const Type,
    /// A type the checker computes from its arguments, like `FlatArray<A, D>`, while they're
    /// still generic.
    intrinsic: Intrinsic,

    pub const Intrinsic = struct {
        kind: IntrinsicKind,
        arguments: []const *const Type,

        pub const IntrinsicKind = enum {
            /// `FlatArray<A, D>`: the elements of the array type `A` flattened `D` levels deep, as
            /// `flat` returns them.
            flat_array,

            pub fn name(this: IntrinsicKind) []const u8 {
                return switch (this) {
                    .flat_array => "FlatArray",
                };
            }
        };
    };

    pub const Indexed = struct {
        object: *const Type,
        index: *const Type,
    };

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
            .readonly_array => |e| b.* == .readonly_array and e.eql(b.readonly_array),
            .param => false,
            .keyof => |e| b.* == .keyof and e.eql(b.keyof),
            .indexed => |x| b.* == .indexed and x.object.eql(b.indexed.object) and x.index.eql(b.indexed.index),
            .mapped => false,
            .tuple => |es| b.* == .tuple and es.len == b.tuple.len and for (es, b.tuple) |x, y| {
                if (!x.eql(y)) {
                    break false;
                }
            } else true,
            .intersection => |ms| b.* == .intersection and ms.len == b.intersection.len and for (ms, b.intersection) |x, y| {
                if (!x.eql(y)) {
                    break false;
                }
            } else true,
            .intrinsic => |x| b.* == .intrinsic and x.kind == b.intrinsic.kind and for (x.arguments, b.intrinsic.arguments) |p, q| {
                if (!p.eql(q)) {
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
                try e.formatParenthesized(writer, e.* == .function or e.* == .@"union" or e.* == .keyof);
                try writer.writeAll("[]");
            },
            .readonly_array => |e| {
                try writer.writeAll("readonly ");
                try e.formatParenthesized(writer, e.* == .function or e.* == .@"union" or e.* == .keyof);
                try writer.writeAll("[]");
            },
            .param => |p| try writer.writeAll(p.name),
            .keyof => |e| {
                try writer.writeAll("keyof ");
                try e.formatParenthesized(writer, e.* == .function or e.* == .@"union");
            },
            .indexed => |x| {
                try x.object.formatParenthesized(writer, x.object.* == .function or x.object.* == .@"union" or x.object.* == .keyof);
                try writer.print("[{f}]", .{x.index});
            },
            .mapped => |m| try m.format(writer),
            .tuple => |es| {
                try writer.writeAll("[");
                for (es, 0..) |e, i| {
                    try writer.print("{s}{f}", .{ if (i > 0) ", " else "", e });
                }
                try writer.writeAll("]");
            },
            .non_primitive => try writer.writeAll("object"),
            .intersection => |ms| for (ms, 0..) |m, i| {
                if (i > 0) {
                    try writer.writeAll(" & ");
                }
                try m.formatParenthesized(writer, m.* == .function or m.* == .@"union");
            },
            .intrinsic => |x| {
                try writer.writeAll(x.kind.name());
                try formatArguments(writer, x.arguments);
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

pub const Param = struct {
    name: []const u8,
    /// `T extends C`
    constraint: ?*const Type = null,
    /// `T = D`
    default: ?*const Type = null,
};

pub const Modifier = enum { none, add, remove };

/// `{ readonly [P in K]?: X }`
pub const Mapped = struct {
    /// The `P`, a `param`.
    parameter: *const Type,
    constraint: *const Type,
    template: *const Type,
    optional: Modifier = .none,
    readonly: Modifier = .none,
    /// For a homomorphic mapped type, `[P in keyof T]`, the `T`, whose properties' modifiers it
    /// keeps.
    source: ?*const Type = null,

    pub fn format(this: *const Mapped, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const sign = [_][]const u8{ "", "+", "-" };
        try writer.writeAll("{ ");
        if (this.readonly != .none) {
            try writer.print("{s}readonly ", .{if (this.readonly == .remove) "-" else ""});
        }
        try writer.print("[{s} in {f}]", .{ this.parameter.param.name, this.constraint });
        if (this.optional != .none) {
            try writer.print("{s}?", .{if (this.optional == .remove) sign[2] else ""});
        }
        try writer.print(": {f}; }}", .{this.template});
    }
};

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
    /// Call signatures, `(x: T): R`, in the order overloads are tried.
    calls: []const *const Function = &.{},
    /// Construct signatures, `new (x: T): R`.
    constructs: []const *const Function = &.{},
    /// `[key: string]: T`
    string_index: ?Index = null,
    /// `[key: number]: T`
    number_index: ?Index = null,
    /// Declared by an interface, which (unlike an object literal or a type literal) doesn't get
    /// an implicit index signature: it isn't assignable to `{ [key: string]: T }`.
    interface: bool = false,
    /// The interfaces an interface extends, for `instanceof` narrowing, which (like tsc) goes by
    /// what's declared to derive from what rather than by structure.
    bases: []const *const Object = &.{},
    /// For an instantiation of a generic interface or type alias (`Box<number>`), its type
    /// arguments; for the generic declaration itself, its own type parameters.
    type_arguments: []const *const Type = &.{},
    /// The generic declaration this instantiates, which the checker knows how to instantiate
    /// again with other type arguments. Null if it isn't generic.
    generic: ?*const anyopaque = null,

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

    pub const Index = struct {
        type: *const Type,
        readonly: bool = false,
    };

    /// Whether it's callable or constructable, or has index signatures.
    pub fn hasSignatures(this: *const Object) bool {
        return this.calls.len > 0 or this.constructs.len > 0 or this.string_index != null or this.number_index != null;
    }

    fn eql(a: *const Object, b: *const Object) bool {
        if (a.name.len > 0 or b.name.len > 0 or a.properties.len != b.properties.len) {
            return false;
        }
        if (a.hasSignatures() or b.hasSignatures()) {
            if (a.calls.len != b.calls.len or a.constructs.len != b.constructs.len) {
                return false;
            }
            for (a.calls, b.calls) |x, y| {
                if (!x.eql(y)) {
                    return false;
                }
            }
            for (a.constructs, b.constructs) |x, y| {
                if (!x.eql(y)) {
                    return false;
                }
            }
            if (!indexEql(a.string_index, b.string_index) or !indexEql(a.number_index, b.number_index)) {
                return false;
            }
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
            try writer.writeAll(this.name);
            try formatArguments(writer, this.type_arguments);
            return;
        }
        if (this.properties.len == 0 and !this.hasSignatures()) {
            return writer.writeAll("{}");
        }
        // tsc shows an object type with nothing but one call signature as a function type.
        if (this.properties.len == 0 and this.calls.len == 1 and this.constructs.len == 0 and this.string_index == null and this.number_index == null) {
            return this.calls[0].format(writer);
        }
        try writer.writeAll("{ ");
        for (this.calls) |f| {
            try f.formatParameters(writer);
            try writer.writeAll(": ");
            try f.formatReturns(writer);
            try writer.writeAll("; ");
        }
        for (this.constructs) |f| {
            try writer.writeAll("new ");
            try f.formatParameters(writer);
            try writer.print(": {f}; ", .{f.returns});
        }
        if (this.string_index) |index| {
            try writer.print("{s}[x: string]: {f}; ", .{ if (index.readonly) "readonly " else "", index.type });
        }
        if (this.number_index) |index| {
            try writer.print("{s}[x: number]: {f}; ", .{ if (index.readonly) "readonly " else "", index.type });
        }
        for (this.properties) |p| {
            if (p.readonly) {
                try writer.writeAll("readonly ");
            }
            try writer.print("{s}{s}", .{ p.name, if (p.optional) "?" else "" });
            if (p.method and p.type.* == .function) {
                try p.type.function.formatParameters(writer);
                try writer.writeAll(": ");
                try p.type.function.formatReturns(writer);
                try writer.writeAll("; ");
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

fn indexEql(a: ?Object.Index, b: ?Object.Index) bool {
    if (a == null or b == null) {
        return a == null and b == null;
    }
    return a.?.readonly == b.?.readonly and a.?.type.eql(b.?.type);
}

fn formatArguments(writer: *std.Io.Writer, arguments: []const *const Type) std.Io.Writer.Error!void {
    if (arguments.len == 0) {
        return;
    }
    try writer.writeAll("<");
    for (arguments, 0..) |a, i| {
        try writer.print("{s}{f}", .{ if (i > 0) ", " else "", a });
    }
    try writer.writeAll(">");
}

pub const Function = struct {
    /// `<T, U>`, each a `param`.
    type_parameters: []const *const Type = &.{},
    parameters: []const Parameter,
    /// A `...rest` parameter, whose type is an array type (or `any`, or not one, which was
    /// reported).
    rest: ?Parameter = null,
    returns: *const Type,
    /// The return type is still being inferred from the body, and is `any` until it is. A call
    /// in the meantime is a circular reference (TS7023).
    pending: bool = false,
    /// A type guard's `x is T`; it returns `boolean`.
    predicate: ?Predicate = null,

    pub const Predicate = struct {
        /// The parameter it's about.
        index: usize,
        name: []const u8,
        type: *const Type,
    };

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
        return switch (rest.type.*) {
            .array, .readonly_array => |e| e,
            else => any,
        };
    }

    pub fn eql(a: *const Function, b: *const Function) bool {
        if (a.parameters.len != b.parameters.len or (a.rest == null) != (b.rest == null) or a.pending or b.pending) {
            return false;
        }
        if (a.type_parameters.len != b.type_parameters.len) {
            return false;
        }
        for (a.type_parameters, b.type_parameters) |x, y| {
            if (x != y) {
                return false;
            }
        }
        for (a.parameters, b.parameters) |x, y| {
            if (x.optional != y.optional or !std.mem.eql(u8, x.name, y.name) or !x.type.eql(y.type)) {
                return false;
            }
        }
        if ((a.predicate == null) != (b.predicate == null)) {
            return false;
        }
        if (a.predicate) |p| {
            if (p.index != b.predicate.?.index or !p.type.eql(b.predicate.?.type)) {
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
        try writer.writeAll(" => ");
        try this.formatReturns(writer);
    }

    pub fn formatReturns(this: *const Function, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (this.predicate) |p| {
            return writer.print("{s} is {f}", .{ p.name, p.type });
        }
        try writer.print("{f}", .{this.returns});
    }

    pub fn formatParameters(this: *const Function, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (this.type_parameters.len > 0) {
            try writer.writeAll("<");
            for (this.type_parameters, 0..) |t, i| {
                try writer.print("{s}{s}", .{ if (i > 0) ", " else "", t.param.name });
                if (t.param.constraint) |c| {
                    try writer.print(" extends {f}", .{c});
                }
                if (t.param.default) |d| {
                    try writer.print(" = {f}", .{d});
                }
            }
            try writer.writeAll(">");
        }
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
        .object, .function, .array, .tuple, .readonly_array, .param, .keyof, .indexed, .mapped, .non_primitive, .intersection, .intrinsic => 7,
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
    if (a.eql(b)) {
        return true;
    }
    if (a.* != .@"union" and isGeneric(a) and baseConstraint(a) != a) {
        return comparableWith(baseConstraint(a), b, nullish_with_anything);
    }
    if (b.* != .@"union" and isGeneric(b) and baseConstraint(b) != b) {
        return comparableWith(a, baseConstraint(b), nullish_with_anything);
    }
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
    if (arrayElement(x)) |xe| {
        if (arrayElement(y)) |ye| {
            if (x.* != .tuple and y.* != .tuple) {
                return comparableWith(xe, ye, nullish_with_anything);
            }
        }
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
        .object, .function, .array, .tuple, .readonly_array, .mapped, .non_primitive, .intersection => true,
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
    if (source.* != .@"union" and isGeneric(source) and baseConstraint(source) != source) {
        return comparableIn(baseConstraint(source), target, depth + 1);
    }
    if (target.* != .@"union" and isGeneric(target) and baseConstraint(target) != target) {
        return comparableIn(source, baseConstraint(target), depth + 1);
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
        .array, .readonly_array => |element| switch (source.*) {
            .array, .readonly_array => |e| comparableIn(e, element, depth + 1),
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
    target: ?*const Object,
    parent: ?*const Assumption,
    depth: u32,
    /// For comparing two generic function types, `<T>(x: T) => T` and `<U>(x: U) => U`: their
    /// type parameters, which correspond one to one.
    source_parameters: []const *const Type = &.{},
    target_parameters: []const *const Type = &.{},

    fn holds(this: ?*const Assumption, source: *const Type, target: *const Object) bool {
        var a = this;
        while (a) |x| : (a = x.parent) {
            if (x.source == source and x.target == target) {
                return true;
            }
        }
        return false;
    }

    /// Whether the type parameters `source` and `target` correspond.
    fn corresponds(this: ?*const Assumption, source: *const Type, target: *const Type) bool {
        var a = this;
        while (a) |x| : (a = x.parent) {
            for (x.source_parameters, x.target_parameters) |s, t| {
                if ((s == source and t == target) or (s == target and t == source)) {
                    return true;
                }
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
    if (source.* == .param and target.* == .param and Assumption.corresponds(assumed, source, target)) {
        return true;
    }
    if (target.* == .mapped) {
        const m = target.mapped;
        // `{}` is assignable to a mapped type that makes every property optional, like `Partial<T>`.
        if (m.optional == .add and isEmptyObject(source)) {
            return true;
        }
        // `T` is assignable to `Partial<T>` and `Readonly<T>`.
        const s = m.source orelse return false;
        return s.eql(source) and m.optional != .remove and m.template.* == .indexed and m.template.indexed.object.eql(s) and m.template.indexed.index == m.parameter;
    }
    if (isGeneric(source)) {
        // `T` is assignable to itself (in a union too), and to what its constraint is.
        var buffer: [1]*const Type = undefined;
        for (target.members(&buffer)) |m| {
            if (source.eql(m) or (source.* == .param and m.* == .param and Assumption.corresponds(assumed, source, m))) {
                return true;
            }
        }
        if (source.* == .@"union") {
            for (source.@"union") |m| {
                if (!assignableIn(m, target, assumed)) {
                    return false;
                }
            }
            return true;
        }
        const next = immediateConstraint(source);
        return next != source and assignableIn(next, target, assumed);
    }
    if (target.* == .keyof) {
        // `"a"` is one of the keys of a `T extends { a: number }`.
        const base = baseConstraint(target.keyof);
        if (base.* != .object) {
            return false;
        }
        var buffer: [1]*const Type = undefined;
        for (source.members(&buffer)) |m| {
            if (m.* != .literal or m.literal.value == .boolean) {
                return false;
            }
            var name_buffer: [64]u8 = undefined;
            const name = switch (m.literal.value) {
                .string => |str| str,
                .number => |n| blk: {
                    var w: std.Io.Writer = .fixed(&name_buffer);
                    @import("../runtime/number.zig").format(&w, n) catch return false;
                    break :blk w.buffered();
                },
                .boolean => unreachable,
            };
            if (base.object.find(name) == null) {
                return false;
            }
        }
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
    if (target.* == .intersection) {
        for (target.intersection) |m| {
            if (!assignableIn(source, m, assumed)) {
                return false;
            }
        }
        return true;
    }
    if (source.* == .intersection) {
        for (source.intersection) |m| {
            if (assignableIn(m, target, assumed)) {
                return true;
            }
        }
        // Together, the members can have what an object type needs.
        return target.* == .object and objectMismatch(source, target.object, assumed) == null;
    }
    return switch (target.*) {
        .number => isNumberLike(source),
        .string => isStringLike(source),
        .boolean => source.* == .literal and source.literal.value == .boolean,
        .void => source.* == .undefined,
        .array, .readonly_array => |element| switch (source.*) {
            .array => |e| assignableIn(e, element, assumed),
            // A readonly array can't be used as a mutable one (TS4104).
            .readonly_array => |e| target.* == .readonly_array and assignableIn(e, element, assumed),
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
        .function => |f| switch (source.*) {
            .function => |sf| functionMismatchIn(sf, f, assumed) == null,
            // One of an overloaded function's signatures has to do.
            .object => |o| for (o.calls) |sf| {
                if (functionMismatchIn(sf, f, assumed) == null) {
                    break true;
                }
            } else false,
            else => false,
        },
        .object => |o| objectMismatch(source, o, assumed) == null,
        .non_primitive => isNonPrimitive(source),
        else => false,
    };
}

/// Whether every value of type `t` is an object, so `t` is assignable to `object`.
fn isNonPrimitive(t: *const Type) bool {
    return switch (t.*) {
        .object, .function, .array, .tuple, .readonly_array, .non_primitive, .mapped => true,
        .intersection => |ms| for (ms) |m| {
            if (isNonPrimitive(m)) {
                break true;
            }
        } else false,
        else => false,
    };
}

/// What the checker knows about `lib.d.ts`, for relating primitives, arrays and functions to
/// object types by their apparent types: `string` to `{ length: number }`, or `number[]` to
/// `Iterable<number>`. Set while a program is checked; without it, only `length` is known.
pub threadlocal var library: ?Library = null;

pub const Library = struct {
    context: *anyopaque,
    /// The interface instantiation whose members `t` has: `String` for `string`, `Array<T>` for
    /// `T[]`. Null if there's none.
    apparent: *const fn (context: *anyopaque, t: *const Type) ?*const Type,
};

/// The object type of the members a primitive, array or function has, if the library says.
pub fn apparentObject(t: *const Type) ?*const Object {
    const l = library orelse return null;
    const a = l.apparent(l.context, t) orelse return null;
    return if (a.* == .object) a.object else null;
}

/// A property of an intersection: the first member's that has it.
fn intersectionProperty(members_: []const *const Type, name: []const u8) ?*const Property {
    for (members_) |m| {
        switch (m.*) {
            .object => |o| if (o.find(name)) |p| return p,
            else => if (apparentObject(m)) |o| if (o.find(name)) |p| return p,
        }
    }
    return null;
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
    /// Its call or construct signatures don't match.
    signature,
    /// It has no index signature for keys of this type (`"string"` or `"number"`), and can't have
    /// an implicit one.
    index_missing: []const u8,
    /// Its index signature doesn't match the index signature for keys of this type.
    index: []const u8,
    /// This property of the source doesn't match the target's index signature.
    index_property: []const u8,
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
            return signatureMismatch(s, target, &link);
        },
        .intersection => |ms| {
            for (target.properties) |p| {
                const sp = intersectionProperty(ms, p.name) orelse if (p.optional) continue else return .missing;
                if (!assignableIn(sp.type, p.type, assumed)) {
                    return .{ .property = p.name };
                }
            }
            return null;
        },
        .function => |f| {
            if (target.calls.len > 0) {
                for (target.calls) |tf| {
                    if (functionMismatchIn(f, tf, assumed) != null) {
                        return .signature;
                    }
                }
            }
            if (target.constructs.len > 0) {
                return .signature;
            }
            return primitiveMismatch(source, target, assumed);
        },
        .non_primitive => {
            for (target.properties) |p| {
                if (!p.optional) {
                    return .missing;
                }
            }
            return if (target.hasSignatures()) .signature else null;
        },
        else => return primitiveMismatch(source, target, assumed),
    }
}

/// Whether the call, construct and index signatures of `source` do what `target`'s need.
fn signatureMismatch(source: *const Object, target: *const Object, assumed: ?*const Assumption) ?ObjectMismatch {
    for (target.calls) |tf| {
        const found = for (source.calls) |sf| {
            if (functionMismatchIn(sf, tf, assumed) == null) {
                break true;
            }
        } else false;
        if (!found) {
            return .signature;
        }
    }
    for (target.constructs) |tf| {
        const found = for (source.constructs) |sf| {
            if (functionMismatchIn(sf, tf, assumed) == null) {
                break true;
            }
        } else false;
        if (!found) {
            return .signature;
        }
    }
    if (target.string_index) |index| {
        if (source.string_index) |si| {
            if (!assignableIn(si.type, index.type, assumed)) {
                return .{ .index = "string" };
            }
        } else if (source.interface) {
            return .{ .index_missing = "string" };
        }
        if (source.number_index) |si| {
            if (!assignableIn(si.type, index.type, assumed)) {
                return .{ .index = "string" };
            }
        }
        for (source.properties) |p| {
            if (!assignableIn(propertyValueType(p), index.type, assumed)) {
                return .{ .index_property = p.name };
            }
        }
    }
    if (target.number_index) |index| {
        if (source.number_index orelse source.string_index) |si| {
            if (!assignableIn(si.type, index.type, assumed)) {
                return .{ .index = "number" };
            }
        } else if (source.interface) {
            return .{ .index_missing = "number" };
        }
        for (source.properties) |p| {
            if (isNumericName(p.name) and !assignableIn(propertyValueType(p), index.type, assumed)) {
                return .{ .index_property = p.name };
            }
        }
    }
    return null;
}

/// What a property contributes to an implicit index signature: an optional one's type without
/// the `undefined` its optionality adds.
fn propertyValueType(p: Property) *const Type {
    if (!p.optional or p.type.* != .@"union") {
        return p.type;
    }
    for (p.type.@"union") |m| {
        if (m.* == .undefined) {
            // Only two members: the declared type and `undefined`.
            if (p.type.@"union".len == 2) {
                return if (p.type.@"union"[0] == m) p.type.@"union"[1] else p.type.@"union"[0];
            }
        }
    }
    return p.type;
}

/// tsc's `isNumericLiteralName`: a name a number turns into, like `0` or `1.5`.
pub fn isNumericName(name: []const u8) bool {
    const n = std.fmt.parseFloat(f64, name) catch return false;
    var buffer: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    @import("../runtime/number.zig").format(&w, n) catch return false;
    return std.mem.eql(u8, w.buffered(), name);
}

/// A primitive, array or function, related to an object type through its apparent type.
fn primitiveMismatch(source: *const Type, target: *const Object, assumed: ?*const Assumption) ?ObjectMismatch {
    if (apparentObject(source)) |apparent| {
        const a: Type = .{ .object = apparent };
        // An array's apparent type has the array's index signature.
        return objectMismatch(&a, target, assumed);
    }
    switch (source.*) {
        else => {
            // Primitives, arrays and functions: of the properties they have, only `length` is
            // known so far.
            for (target.properties) |p| {
                if (p.optional) {
                    continue;
                }
                const has_length = source.* == .array or source.* == .readonly_array or source.* == .tuple or source.* == .function;
                if (!has_length or !std.mem.eql(u8, p.name, "length")) {
                    return .missing;
                }
                const length: Type = if (source.* == .tuple) .{ .literal = .{ .value = .{ .number = @floatFromInt(source.tuple.len) } } } else .number;
                if (!assignableIn(&length, p.type, assumed)) {
                    return .{ .property = p.name };
                }
            }
            return if (target.hasSignatures()) .signature else null;
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
            .intersection => |ms| intersectionProperty(ms, p.name) != null,
            else => if (apparentObject(source)) |o| o.find(p.name) != null else switch (source.*) {
                .array, .readonly_array, .tuple, .function => std.mem.eql(u8, p.name, "length"),
                else => false,
            },
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

fn functionMismatchIn(source: *const Function, target: *const Function, outer: ?*const Assumption) ?FunctionMismatch {
    // Two generic functions with as many type parameters are compared with each type parameter of
    // one standing for the other's.
    const link: Assumption = .{
        .source = any,
        .target = null,
        .parent = outer,
        .depth = if (outer) |o| o.depth else 0,
        .source_parameters = source.type_parameters,
        .target_parameters = target.type_parameters,
    };
    const paired = source.type_parameters.len > 0 and source.type_parameters.len == target.type_parameters.len;
    const assumed: ?*const Assumption = if (paired) &link else outer;
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
    // A type guard has to guard what the target's does, with a type assignable to its.
    if (target.predicate) |tp| {
        const sp = source.predicate orelse return .returns;
        if (sp.index != tp.index or !assignableIn(sp.type, tp.type, assumed)) {
            return .returns;
        }
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
    if (t.* == .param) {
        // A type parameter with a literal constraint can be a literal.
        const c = t.param.constraint orelse return false;
        return couldHaveSingletons(c);
    }
    // `boolean` alone doesn't count, but as part of a union its `true` and `false` do.
    if (t.* != .@"union") {
        return t.* == .literal or t.* == .null or t.* == .undefined;
    }
    for (t.@"union") |m| {
        switch (m.*) {
            .literal, .null, .undefined, .boolean => return true,
            .param => if (couldHaveSingletons(m)) return true,
            else => {},
        }
    }
    return false;
}

// Generics

/// Whether `t` is generic at its top level: a type parameter, or something made of one whose
/// value isn't known until it's instantiated, like `keyof T`. `{ a: T }` isn't, since what it is
/// (an object with an `a`) is known.
pub fn isGeneric(t: *const Type) bool {
    return switch (t.*) {
        .param, .keyof, .indexed, .mapped, .intrinsic => true,
        .@"union", .intersection => |ms| for (ms) |m| {
            if (isGeneric(m)) {
                break true;
            }
        } else false,
        else => false,
    };
}

/// Whether `t` mentions a type parameter anywhere (which a generic function's own don't count
/// as, and nor do the members of named types other than their type arguments).
pub fn mentionsParameters(t: *const Type) bool {
    return switch (t.*) {
        .param, .keyof, .indexed, .mapped, .intrinsic => true,
        .@"union", .tuple, .intersection => |ms| for (ms) |m| {
            if (mentionsParameters(m)) {
                break true;
            }
        } else false,
        .array, .readonly_array => |e| mentionsParameters(e),
        .object => |o| if (o.name.len > 0) for (o.type_arguments) |a| {
            if (mentionsParameters(a)) {
                break true;
            }
        } else false else for (o.properties) |p| {
            if (mentionsParameters(p.type)) {
                break true;
            }
        } else for (o.calls) |f| {
            if (functionMentionsParameters(f)) {
                break true;
            }
        } else for (o.constructs) |f| {
            if (functionMentionsParameters(f)) {
                break true;
            }
        } else (if (o.string_index) |i| mentionsParameters(i.type) else false) or (if (o.number_index) |i| mentionsParameters(i.type) else false),
        .function => |f| functionMentionsParameters(f),
        else => false,
    };
}

fn functionMentionsParameters(f: *const Function) bool {
    if (f.predicate) |p| {
        if (mentionsParameters(p.type)) {
            return true;
        }
    }
    return mentionsParameters(f.returns) or (if (f.rest) |r| mentionsParameters(r.type) else false) or for (f.parameters) |p| {
        if (mentionsParameters(p.type)) {
            break true;
        }
    } else false;
}

/// What a generic type is known to be, whatever it's instantiated with (tsc's
/// `getBaseConstraintOfType`): a type parameter's constraint, or `unknown` if it has none.
pub fn baseConstraint(t: *const Type) *const Type {
    return switch (t.*) {
        .param => |p| if (p.constraint) |c| baseConstraint(c) else unknown,
        .keyof => string_or_number,
        .indexed => |x| blk: {
            // `T["a"]` where `T extends { a: number }` is a `number`.
            const o = baseConstraint(x.object);
            const k = baseConstraint(x.index);
            if (o.* == .object and k.* == .literal and k.literal.value == .string) {
                if (o.object.find(k.literal.value.string)) |p| {
                    break :blk p.type;
                }
            }
            if (k.* == .number or (k.* == .literal and k.literal.value == .number)) {
                if (arrayElement(o)) |e| {
                    if (o.* != .tuple) {
                        break :blk e;
                    }
                }
            }
            break :blk unknown;
        },
        else => t,
    };
}

/// What a generic type is constrained to, one step at a time: `K extends keyof T` is a
/// `keyof T`, which is a `string | number`.
fn immediateConstraint(t: *const Type) *const Type {
    return switch (t.*) {
        .param => |p| p.constraint orelse unknown,
        .keyof => string_or_number,
        .indexed => baseConstraint(t),
        .mapped => unknown,
        else => t,
    };
}

/// tsc's `keyof any`, without `symbol`.
pub const string_or_number: *const Type = &.{ .@"union" = &.{ string, number } };

/// The element type of an array, a readonly array, or a tuple with a single element type.
pub fn arrayElement(t: *const Type) ?*const Type {
    return switch (t.*) {
        .array, .readonly_array => |e| e,
        .tuple => |es| if (es.len == 1) es[0] else null,
        else => null,
    };
}

/// Type arguments for type parameters, to substitute one for the other.
pub const Mapper = struct {
    from: []const *const Type = &.{},
    to: []const *const Type = &.{},
    /// Instantiates a generic interface or type alias (an object with `generic` set) with other
    /// type arguments. Only the checker knows how, since that takes resolving its declaration.
    named: *const fn (context: *anyopaque, object: *const Object, arguments: []const *const Type) Error!*const Type,
    context: *anyopaque,

    fn lookup(this: *const Mapper, t: *const Type) ?*const Type {
        for (this.from, this.to) |f, to| {
            if (f == t) {
                return to;
            }
        }
        return null;
    }

    /// The same, but substituting `to` for `from` instead.
    pub fn with(this: *const Mapper, from: []const *const Type, to: []const *const Type) Mapper {
        return .{ .from = from, .to = to, .named = this.named, .context = this.context };
    }
};

const Error = error{OutOfMemory};

/// `t` with the type parameters `mapper` maps replaced by their type arguments.
pub fn instantiate(arena: std.mem.Allocator, t: *const Type, mapper: *const Mapper) Error!*const Type {
    if (mapper.from.len == 0) {
        return t;
    }
    return switch (t.*) {
        .param => mapper.lookup(t) orelse t,
        .@"union" => |ms| blk: {
            var changed = false;
            const list = try arena.alloc(*const Type, ms.len);
            for (ms, list) |m, *x| {
                x.* = try instantiate(arena, m, mapper);
                changed = changed or x.* != m;
            }
            break :blk if (changed) unionOf(arena, list) else t;
        },
        .array => |e| blk: {
            const x = try instantiate(arena, e, mapper);
            break :blk if (x == e) t else asPtr(.{ .array = x }, arena);
        },
        .readonly_array => |e| blk: {
            const x = try instantiate(arena, e, mapper);
            break :blk if (x == e) t else asPtr(.{ .readonly_array = x }, arena);
        },
        .tuple => |es| blk: {
            var changed = false;
            const list = try arena.alloc(*const Type, es.len);
            for (es, list) |e, *x| {
                x.* = try instantiate(arena, e, mapper);
                changed = changed or x.* != e;
            }
            break :blk if (changed) asPtr(.{ .tuple = list }, arena) else t;
        },
        .object => |o| blk: {
            if (o.generic != null) {
                var changed = false;
                const list = try arena.alloc(*const Type, o.type_arguments.len);
                for (o.type_arguments, list) |a, *x| {
                    x.* = try instantiate(arena, a, mapper);
                    changed = changed or x.* != a;
                }
                break :blk if (changed) mapper.named(mapper.context, o, list) else t;
            }
            if (o.name.len > 0) {
                break :blk t;
            }
            var changed = false;
            const properties = try arena.alloc(Property, o.properties.len);
            for (o.properties, properties) |p, *x| {
                x.* = p;
                x.type = try instantiate(arena, p.type, mapper);
                changed = changed or x.type != p.type;
            }
            const calls = try instantiateSignatures(arena, o.calls, mapper, &changed);
            const constructs = try instantiateSignatures(arena, o.constructs, mapper, &changed);
            var string_index = o.string_index;
            if (string_index) |*i| {
                const x = try instantiate(arena, i.type, mapper);
                changed = changed or x != i.type;
                i.type = x;
            }
            var number_index = o.number_index;
            if (number_index) |*i| {
                const x = try instantiate(arena, i.type, mapper);
                changed = changed or x != i.type;
                i.type = x;
            }
            if (!changed) {
                break :blk t;
            }
            const object = try arena.create(Object);
            object.* = o.*;
            object.properties = properties;
            object.calls = calls;
            object.constructs = constructs;
            object.string_index = string_index;
            object.number_index = number_index;
            break :blk asPtr(.{ .object = object }, arena);
        },
        .intersection => |ms| blk: {
            var changed = false;
            const list = try arena.alloc(*const Type, ms.len);
            for (ms, list) |m, *x| {
                x.* = try instantiate(arena, m, mapper);
                changed = changed or x.* != m;
            }
            break :blk if (changed) intersectionOf(arena, list) else t;
        },
        .intrinsic => |x| blk: {
            var changed = false;
            const list = try arena.alloc(*const Type, x.arguments.len);
            for (x.arguments, list) |a, *y| {
                y.* = try instantiate(arena, a, mapper);
                changed = changed or y.* != a;
            }
            break :blk if (changed) intrinsic(arena, x.kind, list) else t;
        },
        .function => |f| blk: {
            var changed = false;
            // A generic method of a generic interface, like `filter<S extends T>` of `Array<T>`,
            // gets type parameters of its own whose constraints are instantiated too.
            var type_parameters = f.type_parameters;
            var inner = mapper.*;
            if (f.type_parameters.len > 0 and constraintsMention(f.type_parameters, mapper)) {
                const fresh = try arena.alloc(*const Type, f.type_parameters.len);
                const params = try arena.alloc(Param, f.type_parameters.len);
                for (f.type_parameters, params, fresh) |old, *p, *x| {
                    p.* = .{ .name = old.param.name };
                    x.* = try asPtr(.{ .param = p }, arena);
                }
                inner = mapper.with(try std.mem.concat(arena, *const Type, &.{ mapper.from, f.type_parameters }), try std.mem.concat(arena, *const Type, &.{ mapper.to, fresh }));
                for (f.type_parameters, params) |old, *p| {
                    p.constraint = if (old.param.constraint) |c| try instantiate(arena, c, &inner) else null;
                    p.default = if (old.param.default) |d| try instantiate(arena, d, &inner) else null;
                }
                type_parameters = fresh;
                changed = true;
            }
            const parameters = try arena.alloc(Parameter, f.parameters.len);
            for (f.parameters, parameters) |p, *x| {
                x.* = p;
                x.type = try instantiate(arena, p.type, &inner);
                changed = changed or x.type != p.type;
            }
            var rest = f.rest;
            if (rest) |*r| {
                const x = try instantiate(arena, r.type, &inner);
                changed = changed or x != r.type;
                r.type = x;
            }
            const returns = try instantiate(arena, f.returns, &inner);
            changed = changed or returns != f.returns;
            var predicate = f.predicate;
            if (predicate) |*p| {
                const x = try instantiate(arena, p.type, &inner);
                changed = changed or x != p.type;
                p.type = x;
            }
            if (!changed) {
                break :blk t;
            }
            const function = try arena.create(Function);
            function.* = .{ .type_parameters = type_parameters, .parameters = parameters, .rest = rest, .returns = returns, .predicate = predicate };
            break :blk asPtr(.{ .function = function }, arena);
        },
        .keyof => |e| blk: {
            const x = try instantiate(arena, e, mapper);
            break :blk if (x == e) t else try keyOf(arena, x) orelse try asPtr(.{ .keyof = x }, arena);
        },
        .indexed => |i| blk: {
            const o = try instantiate(arena, i.object, mapper);
            const k = try instantiate(arena, i.index, mapper);
            if (o == i.object and k == i.index) {
                break :blk t;
            }
            break :blk try indexedAccess(arena, o, k, mapper) orelse unknown;
        },
        .mapped => |m| blk: {
            const source = if (m.source) |x| try instantiate(arena, x, mapper) else null;
            if (m.source != null and m.source.?.* == .param and source.?.* == .@"union") {
                // A homomorphic mapped type of a union is the union of it for each member:
                // `Partial<A | B>` is `Partial<A> | Partial<B>`.
                const index = std.mem.indexOfScalar(*const Type, mapper.from, m.source.?).?;
                const list = try arena.alloc(*const Type, source.?.@"union".len);
                for (source.?.@"union", list) |member, *x| {
                    const to = try arena.dupe(*const Type, mapper.to);
                    to[index] = member;
                    x.* = try instantiate(arena, t, &mapper.with(mapper.from, to));
                }
                break :blk unionOf(arena, list);
            }
            const constraint = try instantiate(arena, m.constraint, mapper);
            const template = try instantiate(arena, m.template, mapper);
            if (constraint == m.constraint and template == m.template and source == m.source) {
                break :blk t;
            }
            const mapped = try arena.create(Mapped);
            mapped.* = m.*;
            mapped.constraint = constraint;
            mapped.template = template;
            mapped.source = source;
            break :blk resolveMapped(arena, mapped, mapper);
        },
        else => t,
    };
}

/// Whether the constraints or defaults of `parameters` mention what `mapper` maps.
fn constraintsMention(parameters: []const *const Type, mapper: *const Mapper) bool {
    for (parameters) |p| {
        for ([_]?*const Type{ p.param.constraint, p.param.default }) |c| {
            const t = c orelse continue;
            for (mapper.from) |from| {
                if (refersToParameter(t, from)) {
                    return true;
                }
            }
        }
    }
    return false;
}

/// Whether `t` mentions the type parameter `parameter`, looking only as far as
/// `mentionsParameters` does.
fn refersToParameter(t: *const Type, parameter: *const Type) bool {
    return switch (t.*) {
        .param => t == parameter,
        .keyof => |e| refersToParameter(e, parameter),
        .indexed => |x| refersToParameter(x.object, parameter) or refersToParameter(x.index, parameter),
        .@"union", .tuple, .intersection => |ms| for (ms) |m| {
            if (refersToParameter(m, parameter)) {
                break true;
            }
        } else false,
        .array, .readonly_array => |e| refersToParameter(e, parameter),
        .object => |o| for (o.type_arguments) |a| {
            if (refersToParameter(a, parameter)) {
                break true;
            }
        } else for (o.properties) |p| {
            if (refersToParameter(p.type, parameter)) {
                break true;
            }
        } else (if (o.string_index) |i| refersToParameter(i.type, parameter) else false),
        .function => |f| refersToParameter(f.returns, parameter) or for (f.parameters) |p| {
            if (refersToParameter(p.type, parameter)) {
                break true;
            }
        } else false,
        else => false,
    };
}

fn instantiateSignatures(arena: std.mem.Allocator, signatures: []const *const Function, mapper: *const Mapper, changed: *bool) Error![]const *const Function {
    if (signatures.len == 0) {
        return signatures;
    }
    const list = try arena.alloc(*const Function, signatures.len);
    for (signatures, list) |f, *x| {
        const t: Type = .{ .function = f };
        const instantiated = try instantiate(arena, &t, mapper);
        x.* = instantiated.function;
        changed.* = changed.* or x.* != f;
    }
    return list;
}

/// `A & B`: the members flattened, without duplicates or `unknown`, or `never` if one is `never`.
pub fn intersectionOf(arena: std.mem.Allocator, parts: []const *const Type) Error!*const Type {
    var list: std.ArrayList(*const Type) = .empty;
    for (parts) |part| {
        if (part.* == .never) {
            return never;
        }
        if (part.* == .any) {
            return any;
        }
        const ms: []const *const Type = if (part.* == .intersection) part.intersection else &.{part};
        for (ms) |m| {
            if (m.* == .unknown) {
                continue;
            }
            const duplicate = for (list.items) |existing| {
                if (existing.eql(m)) {
                    break true;
                }
            } else false;
            if (!duplicate) {
                try list.append(arena, m);
            }
        }
    }
    return switch (list.items.len) {
        0 => unknown,
        1 => list.items[0],
        else => asPtr(.{ .intersection = list.items }, arena),
    };
}

/// An intrinsic type applied to `arguments`: computed if they're known, deferred if not. Null
/// for arguments it can't be computed for yet.
pub fn intrinsic(arena: std.mem.Allocator, kind: Type.Intrinsic.IntrinsicKind, arguments: []const *const Type) Error!*const Type {
    for (arguments) |a| {
        if (mentionsParameters(a)) {
            return asPtr(.{ .intrinsic = .{ .kind = kind, .arguments = arguments } }, arena);
        }
    }
    return switch (kind) {
        .flat_array => {
            const depth = arguments[1];
            // A depth that isn't a literal, or is one of more than 20, flattens to a union of
            // every depth in tsc, which isn't worth having.
            if (depth.* != .literal or depth.literal.value != .number) {
                return any;
            }
            const d = depth.literal.value.number;
            if (d != @trunc(d) or d < -1 or d > 20) {
                return any;
            }
            return flatArray(arena, arguments[0], @intFromFloat(d));
        },
    };
}

/// tsc's `FlatArray<A, D>`, without the conditional types: `A` itself at a depth of -1, or else
/// its elements flattened one level less deep (each member of a union on its own).
fn flatArray(arena: std.mem.Allocator, t: *const Type, depth: i32) Error!*const Type {
    if (depth == -1) {
        return t;
    }
    switch (t.*) {
        .array, .readonly_array => |e| return flatArray(arena, e, depth - 1),
        .tuple => |es| return flatArray(arena, try unionOf(arena, es), depth - 1),
        .@"union" => |ms| {
            const list = try arena.alloc(*const Type, ms.len);
            for (ms, list) |m, *x| {
                x.* = try flatArray(arena, m, depth);
            }
            return unionOf(arena, list);
        },
        else => return t,
    }
}

/// `keyof t`, deferred when `t` is generic. Null when it isn't supported yet: the keys of
/// primitives and arrays are their methods.
pub fn keyOf(arena: std.mem.Allocator, t: *const Type) Error!?*const Type {
    switch (t.*) {
        .any => return string_or_number,
        .never => return string_or_number,
        .param, .keyof, .indexed => return try asPtr(.{ .keyof = t }, arena),
        // The keys of `{ [P in K]: X }` are `K`.
        .mapped => |m| return m.constraint,
        .object => |o| {
            var keys: std.ArrayList(*const Type) = .empty;
            if (o.string_index != null) {
                try keys.appendSlice(arena, &.{ string, number });
            } else if (o.number_index != null) {
                try keys.append(arena, number);
            }
            for (o.properties) |p| {
                if (std.mem.startsWith(u8, p.name, "[")) {
                    // `[Symbol.iterator]`, a symbol.
                    continue;
                }
                try keys.append(arena, try keyLiteral(arena, p.name));
            }
            return try unionOf(arena, keys.items);
        },
        .@"union" => |ms| {
            if (isGeneric(t)) {
                return try asPtr(.{ .keyof = t }, arena);
            }
            // Only the keys every member has.
            var common: std.ArrayList(*const Type) = .empty;
            const first = try keyOf(arena, ms[0]) orelse return null;
            var buffer: [1]*const Type = undefined;
            outer: for (first.members(&buffer)) |k| {
                for (ms[1..]) |m| {
                    const keys = try keyOf(arena, m) orelse return null;
                    if (!assignable(k, keys)) {
                        continue :outer;
                    }
                }
                try common.append(arena, k);
            }
            return try unionOf(arena, common.items);
        },
        else => return null,
    }
}

/// The literal type of a property name: a number for a canonical numeric name like `0`, and a
/// string otherwise.
fn keyLiteral(arena: std.mem.Allocator, name: []const u8) Error!*const Type {
    const number_module = @import("../runtime/number.zig");
    const n = std.fmt.parseFloat(f64, name) catch return literal(arena, .{ .string = name });
    const canonical = try number_module.toString(arena, n);
    if (std.mem.eql(u8, canonical, name)) {
        return literal(arena, .{ .number = n });
    }
    return literal(arena, .{ .string = name });
}

/// The name a literal key gives, or null if it isn't one.
pub fn keyName(arena: std.mem.Allocator, key: *const Type) Error!?[]const u8 {
    if (key.* != .literal) {
        return null;
    }
    return switch (key.literal.value) {
        .string => |str| str,
        .number => |n| try @import("../runtime/number.zig").toString(arena, n),
        .boolean => null,
    };
}

/// `object[index]`, deferred when either is generic. Null when `index` can't index `object`.
pub fn indexedAccess(arena: std.mem.Allocator, object: *const Type, index: *const Type, mapper: *const Mapper) Error!?*const Type {
    if (isGeneric(object) or isGeneric(index)) {
        return try asPtr(.{ .indexed = .{ .object = object, .index = index } }, arena);
    }
    if (object.* == .any) {
        return any;
    }
    if (index.* == .@"union") {
        var parts: std.ArrayList(*const Type) = .empty;
        for (index.@"union") |k| {
            try parts.append(arena, try indexedAccess(arena, object, k, mapper) orelse return null);
        }
        return try unionOf(arena, parts.items);
    }
    if (object.* == .@"union") {
        var parts: std.ArrayList(*const Type) = .empty;
        for (object.@"union") |o| {
            try parts.append(arena, try indexedAccess(arena, o, index, mapper) orelse return null);
        }
        return try unionOf(arena, parts.items);
    }
    switch (object.*) {
        .array, .readonly_array => |e| if (isNumberLike(index)) return e,
        .tuple => |es| {
            if (index.* == .number) {
                return try unionOf(arena, es);
            }
            if (index.* == .literal and index.literal.value == .number) {
                const n = index.literal.value.number;
                if (n >= 0 and n == @trunc(n) and n < @as(f64, @floatFromInt(es.len))) {
                    return es[@intFromFloat(n)];
                }
                return null;
            }
        },
        .object => |o| {
            const name = try keyName(arena, index) orelse {
                if (isNumberLike(index)) {
                    if (o.number_index orelse o.string_index) |i| {
                        return i.type;
                    }
                } else if (isStringLike(index)) {
                    if (o.string_index) |i| {
                        return i.type;
                    }
                }
                return null;
            };
            if (o.find(name)) |p| {
                return p.type;
            }
            if (isNumericName(name)) {
                if (o.number_index) |i| {
                    return i.type;
                }
            }
            if (o.string_index) |i| {
                return i.type;
            }
            return null;
        },
        else => {},
    }
    if (std.mem.eql(u8, (try keyName(arena, index)) orelse "", "length")) {
        switch (object.*) {
            .array, .readonly_array => return number,
            .tuple => |es| return try literal(arena, .{ .number = @floatFromInt(es.len) }),
            else => {},
        }
    }
    return null;
}

/// A mapped type as an object type, once its keys are known; until then it stays deferred.
pub fn resolveMapped(arena: std.mem.Allocator, m: *const Mapped, mapper: *const Mapper) Error!*const Type {
    const deferred = try asPtr(.{ .mapped = m }, arena);
    if (isGeneric(m.constraint)) {
        return deferred;
    }
    if (m.source) |source| {
        // A homomorphic mapped type of an array is an array, and of a primitive the primitive.
        switch (source.*) {
            .array, .readonly_array => {
                var element = try instantiate(arena, m.template, &mapper.with(&.{m.parameter}, &.{number}));
                if (m.optional == .add) {
                    element = try unionOf(arena, &.{ element, @"undefined" });
                }
                const readonly = m.readonly == .add or (source.* == .readonly_array and m.readonly != .remove);
                return asPtr(if (readonly) .{ .readonly_array = element } else .{ .array = element }, arena);
            },
            .tuple => return deferred,
            .object => {},
            .any => return any,
            else => return source,
        }
    }
    var properties: std.ArrayList(Property) = .empty;
    var string_index: ?Object.Index = null;
    var number_index: ?Object.Index = null;
    var buffer: [1]*const Type = undefined;
    for (m.constraint.members(&buffer)) |key| {
        if (key.* == .string or key.* == .number) {
            // `{ [P in string]: X }` is an index signature, `{ [x: string]: X }`.
            if (key.* == .number and string_index != null) {
                continue;
            }
            var t = try instantiate(arena, m.template, &mapper.with(&.{m.parameter}, &.{key}));
            if (m.optional == .add) {
                t = try unionOf(arena, &.{ t, @"undefined" });
            }
            const index: Object.Index = .{ .type = t, .readonly = m.readonly == .add };
            if (key.* == .string) {
                string_index = index;
            } else {
                number_index = index;
            }
            continue;
        }
        const name = try keyName(arena, key) orelse return deferred;
        var t = try instantiate(arena, m.template, &mapper.with(&.{m.parameter}, &.{key}));
        var optional = false;
        var readonly = false;
        var method = false;
        if (m.source) |source| {
            if (source.object.find(name)) |p| {
                optional = p.optional;
                readonly = p.readonly;
                method = p.method and m.optional == .none and m.readonly == .none;
            }
        }
        if (m.optional == .remove and optional) {
            t = try removeUndefined(arena, t);
        }
        optional = switch (m.optional) {
            .add => true,
            .remove => false,
            .none => optional,
        };
        readonly = switch (m.readonly) {
            .add => true,
            .remove => false,
            .none => readonly,
        };
        if (optional) {
            t = try unionOf(arena, &.{ t, @"undefined" });
        }
        try properties.append(arena, .{ .name = name, .type = t, .optional = optional, .readonly = readonly, .method = method });
    }
    const object = try arena.create(Object);
    object.* = .{ .properties = properties.items, .string_index = string_index, .number_index = number_index };
    return asPtr(.{ .object = object }, arena);
}

fn removeUndefined(arena: std.mem.Allocator, t: *const Type) Error!*const Type {
    var kept: std.ArrayList(*const Type) = .empty;
    var buffer: [1]*const Type = undefined;
    for (t.members(&buffer)) |m| {
        if (m.* != .undefined) {
            try kept.append(arena, m);
        }
    }
    return unionOf(arena, kept.items);
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

fn noNamed(_: *anyopaque, _: *const Object, _: []const *const Type) Error!*const Type {
    unreachable;
}

test "instantiate" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var t_param: Param = .{ .name = "T" };
    const t: Type = .{ .param = &t_param };
    var context: u8 = 0;
    const mapper: Mapper = .{ .from = &.{&t}, .to = &.{number}, .named = noNamed, .context = &context };
    const list = try asPtr(.{ .array = try unionOf(a, &.{ &t, @"null" }) }, a);
    try testing.expectFmt("(T | null)[]", "{f}", .{list});
    try testing.expectFmt("(number | null)[]", "{f}", .{try instantiate(a, list, &mapper)});
    // `keyof T` and `T["x"]` are deferred until `T` is known.
    const object = try asPtr(.{ .object = &.{ .properties = &.{ .{ .name = "x", .type = string }, .{ .name = "0", .type = number } } } }, a);
    const keys = (try keyOf(a, &t)).?;
    try testing.expectFmt("keyof T", "{f}", .{keys});
    try testing.expectFmt("\"x\" | 0", "{f}", .{try instantiate(a, keys, &mapper.with(&.{&t}, &.{object}))});
    const x = try literal(a, .{ .string = "x" });
    const indexed = (try indexedAccess(a, &t, x, &mapper)).?;
    try testing.expectFmt("T[\"x\"]", "{f}", .{indexed});
    try testing.expectFmt("string", "{f}", .{try instantiate(a, indexed, &mapper.with(&.{&t}, &.{object}))});
}

test "type parameters" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var t_param: Param = .{ .name = "T" };
    const t: Type = .{ .param = &t_param };
    var n_param: Param = .{ .name = "N", .constraint = number };
    const n: Type = .{ .param = &n_param };
    // An unconstrained type parameter is only assignable to itself and the top types.
    try testing.expect(assignable(&t, &t));
    try testing.expect(assignable(&t, try unionOf(a, &.{ &t, @"undefined" })));
    try testing.expect(assignable(&t, unknown));
    try testing.expect(!assignable(&t, number));
    try testing.expect(!assignable(number, &t));
    // A constrained one is assignable to what its constraint is.
    try testing.expect(assignable(&n, number));
    try testing.expect(!assignable(&n, string));
    try testing.expect(!assignable(&n, &t));
}

test "readonly arrays" {
    const ro: Type = .{ .readonly_array = number };
    const rw: Type = .{ .array = number };
    try testing.expect(assignable(&rw, &ro));
    try testing.expect(!assignable(&ro, &rw));
    try testing.expectFmt("readonly number[]", "{f}", .{&ro});
}
