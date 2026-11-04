//! Type checks a program the way `tsc --strict` does, reporting tsc's codes and messages. A
//! program with any diagnostics never runs.
//!
//! Expressions are checked bottom-up. After an error the checker keeps going with the type the
//! expression would have had (e.g. `boolean` for a bad `<`), like tsc, so independent errors are
//! all reported but one mistake doesn't cascade.

const std = @import("std");
const Source = @import("../Source.zig");
const diagnostic = @import("../diagnostic.zig");
const ast = @import("../syntax/ast.zig");
const types = @import("types.zig");
const Type = types.Type;
const Expr = ast.Expr;

const Checker = @This();

arena: std.mem.Allocator,
source: *const Source,
diagnostics: *diagnostic.Diagnostics,

const Error = error{OutOfMemory};

pub fn check(arena: std.mem.Allocator, source: *const Source, diagnostics: *diagnostic.Diagnostics, program: ast.Program) Error!void {
    var checker: Checker = .{ .arena = arena, .source = source, .diagnostics = diagnostics };
    for (program.statements) |stmt| try checker.statement(stmt);
}

fn report(this: *Checker, at: u32, code: diagnostic.Code, comptime fmt: []const u8, args: anytype) Error!void {
    try this.diagnostics.add(this.source, at, code, fmt, args);
}

fn statement(this: *Checker, stmt: *const ast.Stmt) Error!void {
    switch (stmt.data) {
        .expression => |e| _ = try this.expression(e),
        .empty => {},
    }
}

// Globals. These move to `lib.d.ts` once the checker can read declarations.

const log_function: Type = .{ .function = &.{
    .parameters = &.{},
    .rest = .{ .name = "data", .type = types.any },
    .returns = types.void,
} };

const console_object: types.Object = .{
    .name = "Console",
    .properties = &.{
        .{ .name = "log", .type = &log_function },
        .{ .name = "error", .type = &log_function },
        .{ .name = "warn", .type = &log_function },
        .{ .name = "info", .type = &log_function },
        .{ .name = "debug", .type = &log_function },
    },
};

const console_type: Type = .{ .object = &console_object };

fn global(name: []const u8) ?*const Type {
    const globals = std.StaticStringMap(*const Type).initComptime(.{
        .{ "console", &console_type },
        .{ "undefined", types.undefined },
        .{ "NaN", types.number },
        .{ "Infinity", types.number },
    });
    return globals.get(name);
}

// Expressions

fn expression(this: *Checker, expr: *const Expr) Error!*const Type {
    return switch (expr.data) {
        .number => |n| types.literal(this.arena, .{ .number = n }),
        .string => |s| types.literal(this.arena, .{ .string = s }),
        .template => |t| blk: {
            for (t.substitutions) |sub| _ = try this.expression(sub);
            // A template without substitutions has a literal type, like a string literal.
            if (t.substitutions.len == 0) break :blk types.literal(this.arena, .{ .string = t.quasis[0] });
            break :blk types.string;
        },
        .boolean => |b| if (b) types.true else types.false,
        .null => types.null,
        .identifier => |name| global(name) orelse blk: {
            try this.report(expr.start, .ts(2304), "Cannot find name '{s}'.", .{name});
            break :blk types.any;
        },
        .paren => |inner| this.expression(inner),
        .unary => |u| this.unary(u),
        .binary => |b| this.binary(b),
        .conditional => |c| blk: {
            const condition = try this.expression(c.condition);
            try this.checkTruthiness(c.condition, condition);
            break :blk types.unionOf(this.arena, &.{ try this.expression(c.then), try this.expression(c.otherwise) });
        },
        .member => |m| this.member(m),
        .call => |c| this.call(expr, c),
    };
}

fn unary(this: *Checker, u: ast.Unary) Error!*const Type {
    const operand = try this.expression(u.operand);
    switch (u.op) {
        .not => {
            try this.checkTruthiness(u.operand, operand);
            return types.boolean;
        },
        .negate, .plus, .bitwise_not => {
            _ = try this.checkNonNull(u.operand, operand);
            // `-1` is the literal type `-1`, not `number`.
            if (u.op == .negate and u.operand.data == .number) return types.literal(this.arena, .{ .number = -u.operand.data.number });
            return types.number;
        },
        .typeof => {
            var names: [8]*const Type = undefined;
            for ([_][]const u8{ "string", "number", "bigint", "boolean", "symbol", "undefined", "object", "function" }, &names) |name, *t| {
                t.* = try types.literal(this.arena, .{ .string = name });
            }
            return types.unionOf(this.arena, &names);
        },
        .void => return types.undefined,
    }
}

const arithmetic_operand = "must be of type 'any', 'number', 'bigint' or an enum type.";

fn binary(this: *Checker, b: ast.Binary) Error!*const Type {
    const left = try this.expression(b.left);
    const right = try this.expression(b.right);
    switch (b.op) {
        .logical_and => {
            try this.checkTruthiness(b.left, left);
            if (!try this.canBeTruthy(left)) return left;
            return types.unionOf(this.arena, &.{ try this.definitelyFalsy(left), right });
        },
        .logical_or => {
            try this.checkTruthiness(b.left, left);
            if (!try this.canBeFalsy(left)) return left;
            return types.unionOf(this.arena, &.{ try this.removeDefinitelyFalsy(left), right });
        },
        .nullish => {
            const inner = ast.skipParens(b.left);
            switch (nullishSemantics(inner)) {
                .never => try this.report(inner.start, .ts(2869), "Right operand of ?? is unreachable because the left operand is never nullish.", .{}),
                .always => try this.report(inner.start, .ts(2871), "This expression is always nullish.", .{}),
                .sometimes => {},
            }
            const non_null = try this.removeNullish(left);
            if (non_null.eql(left)) return left;
            return types.unionOf(this.arena, &.{ non_null, right });
        },
        .add => {
            var l = left;
            var r = right;
            if (!types.isStringLike(left) and !types.isStringLike(right)) {
                l = try this.checkNonNull(b.left, left);
                r = try this.checkNonNull(b.right, right);
            }
            if (isAny(l) and isAny(r)) return types.any;
            if (types.isNumberLike(l) and types.isNumberLike(r)) return types.number;
            if (types.isStringLike(l) or types.isStringLike(r)) return types.string;
            if (isAny(l) or isAny(r)) return types.any;
            try this.operatorError(b, l, r);
            return types.any;
        },
        .less, .greater, .less_equal, .greater_equal => {
            const l = try types.widen(this.arena, try this.checkNonNull(b.left, left));
            const r = try types.widen(this.arena, try this.checkNonNull(b.right, right));
            const ok = isAny(l) or isAny(r) or
                (types.isNumberLike(l) and types.isNumberLike(r)) or
                types.comparable(l, r);
            if (!ok) try this.operatorError(b, l, r);
            return types.boolean;
        },
        .equal, .not_equal, .strict_equal, .strict_not_equal => {
            for ([_]*const Expr{ b.left, b.right }) |operand| {
                const inner = ast.skipParens(operand);
                if (inner.data == .identifier and std.mem.eql(u8, inner.data.identifier, "NaN")) {
                    const always = if (b.op == .equal or b.op == .strict_equal) "false" else "true";
                    try this.report(b.left.start, .ts(2845), "This condition will always return '{s}'.", .{always});
                    return types.boolean;
                }
            }
            if (!types.comparable(left, right)) {
                // tsc names the widened types when those don't overlap either.
                const wl = try types.widen(this.arena, left);
                const wr = try types.widen(this.arena, right);
                const show_widened = !types.comparable(wl, wr);
                try this.report(b.left.start, .ts(2367), "This comparison appears to be unintentional because the types '{f}' and '{f}' have no overlap.", .{
                    if (show_widened) wl else left,
                    if (show_widened) wr else right,
                });
            }
            return types.boolean;
        },
        else => {
            std.debug.assert(b.op.isArithmetic());
            const l = try this.checkNonNull(b.left, left);
            const r = try this.checkNonNull(b.right, right);
            if (!isNumeric(l)) try this.report(b.left.start, .ts(2362), "The left-hand side of an arithmetic operation " ++ arithmetic_operand, .{});
            if (!isNumeric(r)) try this.report(b.right.start, .ts(2363), "The right-hand side of an arithmetic operation " ++ arithmetic_operand, .{});
            return types.number;
        },
    }
}

fn operatorError(this: *Checker, b: ast.Binary, left: *const Type, right: *const Type) Error!void {
    try this.report(b.left.start, .ts(2365), "Operator '{s}' cannot be applied to types '{f}' and '{f}'.", .{
        b.op.lexeme(),
        try types.widen(this.arena, left),
        try types.widen(this.arena, right),
    });
}

fn isAny(t: *const Type) bool {
    return t.* == .any;
}

fn isNumeric(t: *const Type) bool {
    return isAny(t) or types.isNumberLike(t) or types.isBigIntLike(t);
}

fn member(this: *Checker, m: ast.Member) Error!*const Type {
    const object = try this.checkNonNull(m.object, try this.expression(m.object));
    switch (object.*) {
        .any => return types.any,
        .object => |o| return o.property(m.property) orelse {
            try this.report(m.property_start, .ts(2339), "Property '{s}' does not exist on type '{f}'.", .{ m.property, object });
            return types.any;
        },
        .function => {
            for ([_][]const u8{ "apply", "bind", "call", "length", "name", "toString" }) |known| {
                if (std.mem.eql(u8, known, m.property)) {
                    try this.report(m.property_start, diagnostic.zv.unsupported, "Properties of functions are not supported yet.", .{});
                    return types.any;
                }
            }
            try this.report(m.property_start, .ts(2339), "Property '{s}' does not exist on type '{f}'.", .{ m.property, object });
            return types.any;
        },
        .never => return types.never,
        else => {
            try this.report(m.property_start, diagnostic.zv.unsupported, "Properties of '{f}' are not supported yet.", .{try types.widen(this.arena, object)});
            return types.any;
        },
    }
}

fn call(this: *Checker, expr: *const Expr, c: ast.Call) Error!*const Type {
    const callee = try this.checkNonNull(c.callee, try this.expression(c.callee));
    var args: std.ArrayList(*const Type) = .empty;
    for (c.arguments) |arg| try args.append(this.arena, try this.expression(arg));

    switch (callee.*) {
        .any => return types.any,
        .function => |f| {
            const required = f.parameters.len;
            if (args.items.len < required or (f.rest == null and args.items.len > required)) {
                if (f.rest != null) {
                    try this.report(expr.start, .ts(2555), "Expected at least {d} arguments, but got {d}.", .{ required, args.items.len });
                } else {
                    try this.report(expr.start, .ts(2554), "Expected {d} arguments, but got {d}.", .{ required, args.items.len });
                }
                return f.returns;
            }
            for (args.items, c.arguments, 0..) |arg_type, arg, i| {
                const param = if (i < f.parameters.len) f.parameters[i].type else f.rest.?.type;
                if (!assignable(arg_type, param)) {
                    try this.report(arg.start, .ts(2345), "Argument of type '{f}' is not assignable to parameter of type '{f}'.", .{ arg_type, param });
                }
            }
            return f.returns;
        },
        .never => return types.never,
        else => {
            try this.report(c.callee.start, .ts(2349), "This expression is not callable.\n  Type '{s}' has no call signatures.", .{try this.apparentName(callee)});
            return types.any;
        },
    }
}

/// The name tsc uses for a type's methods: `Number` for `number` and `1`, and so on.
fn apparentName(this: *Checker, t: *const Type) Error![]const u8 {
    const widened = try types.widen(this.arena, t);
    return switch (widened.*) {
        .number => "Number",
        .string => "String",
        .boolean => "Boolean",
        .bigint => "BigInt",
        else => std.fmt.allocPrint(this.arena, "{f}", .{widened}),
    };
}

/// Whether a value of type `source` can be used where `target` is expected.
fn assignable(source: *const Type, target: *const Type) bool {
    if (source.eql(target)) return true;
    if (target.* == .any or target.* == .unknown or source.* == .any or source.* == .never) return true;
    if (source.* == .@"union") {
        for (source.@"union") |m| if (!assignable(m, target)) return false;
        return true;
    }
    if (target.* == .@"union") {
        for (target.@"union") |m| if (assignable(source, m)) return true;
        return false;
    }
    return switch (target.*) {
        .number => types.isNumberLike(source),
        .string => types.isStringLike(source),
        .boolean => source.* == .literal and source.literal == .boolean,
        .void => source.* == .undefined,
        else => false,
    };
}

// Null and undefined

/// tsc's `checkNonNullType`: a value that could be `null` or `undefined` can't be used as an
/// operand, called, or have its properties read. Returns the type with those removed.
fn checkNonNull(this: *Checker, expr: *const Expr, t: *const Type) Error!*const Type {
    const inner = ast.skipParens(expr);
    const is_null_literal = inner.data == .null;
    const is_undefined_literal = inner.data == .identifier and std.mem.eql(u8, inner.data.identifier, "undefined");
    if (is_null_literal or is_undefined_literal) {
        try this.report(expr.start, .ts(18050), "The value '{s}' cannot be used here.", .{if (is_null_literal) "null" else "undefined"});
        // Like tsc's error type: the problem is reported, so nothing downstream complains again.
        return types.any;
    }
    var has_null = false;
    var has_undefined = false;
    var buffer: [1]*const Type = undefined;
    for (t.members(&buffer)) |m| switch (m.*) {
        .null => has_null = true,
        .undefined => has_undefined = true,
        else => {},
    };
    if (has_null and has_undefined) {
        try this.report(expr.start, .ts(2533), "Object is possibly 'null' or 'undefined'.", .{});
    } else if (has_null) {
        try this.report(expr.start, .ts(2531), "Object is possibly 'null'.", .{});
    } else if (has_undefined) {
        try this.report(expr.start, .ts(2532), "Object is possibly 'undefined'.", .{});
    } else return t;
    const rest = try this.removeNullish(t);
    return if (rest.* == .never) types.any else rest;
}

fn removeNullish(this: *Checker, t: *const Type) Error!*const Type {
    var kept: std.ArrayList(*const Type) = .empty;
    var buffer: [1]*const Type = undefined;
    for (t.members(&buffer)) |m| if (m.* != .null and m.* != .undefined) try kept.append(this.arena, m);
    return types.unionOf(this.arena, kept.items);
}

// Truthiness

const Semantics = enum { always, never, sometimes };

/// tsc's syntactic truthiness check (TS2872/TS2873): conditions that are literals or other
/// expressions whose truthiness is known from their syntax alone.
fn checkTruthiness(this: *Checker, expr: *const Expr, t: *const Type) Error!void {
    _ = t;
    switch (truthySemantics(expr)) {
        .always => try this.report(expr.start, .ts(2872), "This kind of expression is always truthy.", .{}),
        .never => try this.report(expr.start, .ts(2873), "This kind of expression is always falsy.", .{}),
        .sometimes => {},
    }
}

fn truthySemantics(expr: *const Expr) Semantics {
    const e = ast.skipParens(expr);
    return switch (e.data) {
        // `while (0)` and `while (1)` are allowed idioms.
        .number => |n| if (n == 0 or n == 1) .sometimes else .always,
        .string => |s| if (s.len == 0) .never else .always,
        .template => |t| if (t.substitutions.len > 0) .sometimes else if (t.quasis[0].len == 0) .never else .always,
        .null => .never,
        .unary => |u| if (u.op == .void) .never else .sometimes,
        .identifier => |name| if (std.mem.eql(u8, name, "undefined")) .never else .sometimes,
        .conditional => |c| combine(truthySemantics(c.then), truthySemantics(c.otherwise)),
        else => .sometimes,
    };
}

/// tsc's syntactic nullishness check for the left side of `??` (TS2869/TS2871).
fn nullishSemantics(expr: *const Expr) Semantics {
    const e = ast.skipParens(expr);
    return switch (e.data) {
        .null => .always,
        .identifier => |name| if (std.mem.eql(u8, name, "undefined")) .always else .sometimes,
        .member, .call => .sometimes,
        .binary => |b| switch (b.op) {
            .nullish, .logical_or, .logical_and => .sometimes,
            else => .never,
        },
        .conditional => |c| combine(nullishSemantics(c.then), nullishSemantics(c.otherwise)),
        else => .never,
    };
}

fn combine(a: Semantics, b: Semantics) Semantics {
    return if (a == b) a else .sometimes;
}

fn isFalsyLiteral(t: *const Type) bool {
    return switch (t.*) {
        .null, .undefined, .void => true,
        .literal => |lit| switch (lit) {
            .number => |n| n == 0 or std.math.isNan(n),
            .string => |s| s.len == 0,
            .boolean => |b| !b,
        },
        else => false,
    };
}

fn canBeFalsy(this: *Checker, t: *const Type) Error!bool {
    var buffer: [1]*const Type = undefined;
    for (t.members(&buffer)) |m| switch (m.*) {
        .literal => if (isFalsyLiteral(m)) return true,
        .object, .function, .never => {},
        else => return true,
    };
    _ = this;
    return false;
}

fn canBeTruthy(this: *Checker, t: *const Type) Error!bool {
    var buffer: [1]*const Type = undefined;
    for (t.members(&buffer)) |m| if (!isFalsyLiteral(m) and m.* != .never) return true;
    _ = this;
    return false;
}

/// The falsy values a type can hold: `number` contributes `0`, `string` contributes `""`, and so on.
fn definitelyFalsy(this: *Checker, t: *const Type) Error!*const Type {
    var falsy: std.ArrayList(*const Type) = .empty;
    var buffer: [1]*const Type = undefined;
    for (t.members(&buffer)) |m| {
        const part: ?*const Type = switch (m.*) {
            .number => try types.literal(this.arena, .{ .number = 0 }),
            .string => try types.literal(this.arena, .{ .string = "" }),
            .boolean => types.false,
            .any, .unknown => m,
            else => if (isFalsyLiteral(m)) m else null,
        };
        if (part) |p| try falsy.append(this.arena, p);
    }
    return types.unionOf(this.arena, falsy.items);
}

fn removeDefinitelyFalsy(this: *Checker, t: *const Type) Error!*const Type {
    var kept: std.ArrayList(*const Type) = .empty;
    var buffer: [1]*const Type = undefined;
    for (t.members(&buffer)) |m| {
        if (isFalsyLiteral(m)) continue;
        try kept.append(this.arena, if (m.* == .boolean) types.true else m);
    }
    return types.unionOf(this.arena, kept.items);
}
