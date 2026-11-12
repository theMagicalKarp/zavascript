//! Evaluates a checked program by walking its syntax tree.
//!
//! Variables live where the checker put them (see `Checker.Ref`): top-level ones in `slots`,
//! which outlive the program so the REPL can use them later; a call's own variables in its frame
//! on `stack`; and variables a closure captures in an `Env` for their scope, created each time the
//! scope is entered.

const std = @import("std");
const ast = @import("../syntax/ast.zig");
const Checker = @import("../check/Checker.zig");
const value = @import("value.zig");
const number = @import("number.zig");
const Value = value.Value;
const Env = value.Env;
const Expr = ast.Expr;
const Stmt = ast.Stmt;

const Interpreter = @This();

/// Holds every value the program creates. There's no garbage collector yet, so this lives as
/// long as the runtime.
arena: std.mem.Allocator,
/// Where `console.log` writes.
stdout: *std.Io.Writer,
/// Where `console.error` and `console.warn` write.
stderr: *std.Io.Writer,
globals: std.StringHashMapUnmanaged(Value) = .empty,
/// Top-level variables, indexed by the slot the checker gave them, kept for the life of the
/// runtime so the REPL can use them on later lines.
slots: std.ArrayList(Value) = .empty,
/// The frames of the calls in progress, each `frames[function.id]` values long.
stack: std.ArrayList(Value) = .empty,
/// Where the running call's frame starts in `stack`.
frame: usize = 0,
/// The innermost environment of the code that's running.
env: ?*Env = null,
/// The program the running code is from; a closure's body runs with its own program's tables.
program: *const Program = undefined,
/// `program.resolved.refs`, `bindings` and `environments`, kept here since they're read so often.
refs: []const Checker.Ref = &.{},
bindings: []const Checker.Ref = &.{},
environments: []const u32 = &.{},
/// How deep the native stack may get, in bytes, before a call throws a RangeError.
max_stack: usize,
/// Calls below this stack address throw a RangeError.
stack_limit: usize = 0,
/// What was thrown, when a call returns `error.RuntimeError`.
exception: ?Exception = null,

pub const Error = error{
    OutOfMemory,
    WriteFailed,
    /// An exception was thrown and not caught; it's in `exception`.
    RuntimeError,
};

/// A runtime error, or a value a `throw` statement threw. There's no `catch` yet, so these always
/// end the program.
pub const Exception = struct {
    name: Name,
    /// For a thrown value, the value as `console.log` shows it.
    message: []const u8,

    pub const Name = enum {
        TypeError,
        ReferenceError,
        RangeError,
        /// A value from a `throw` statement.
        thrown,
        /// Something that works in JavaScript but isn't implemented yet. Not a JavaScript error,
        /// so it can never be caught.
        Unsupported,
    };

    pub fn format(this: Exception, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (this.name) {
            .Unsupported => try writer.print("error ZV9001: {s}", .{this.message}),
            .thrown => try writer.print("Uncaught {s}", .{this.message}),
            else => try writer.print("Uncaught {t}: {s}", .{ this.name, this.message }),
        }
    }
};

pub fn init(arena: std.mem.Allocator, stdout: *std.Io.Writer, stderr: *std.Io.Writer, max_stack: usize) error{OutOfMemory}!Interpreter {
    var interpreter: Interpreter = .{ .arena = arena, .stdout = stdout, .stderr = stderr, .max_stack = max_stack };
    try @import("builtins/console.zig").install(&interpreter);
    try interpreter.globals.put(arena, "undefined", .undefined);
    try interpreter.globals.put(arena, "NaN", .{ .number = std.math.nan(f64) });
    try interpreter.globals.put(arena, "Infinity", .{ .number = std.math.inf(f64) });
    return interpreter;
}

/// A checked program, ready to run.
pub const Program = struct {
    ast: ast.Program,
    resolved: Checker.Resolved,
    /// The source text, for functions' `toString`.
    text: []const u8,
};

/// Ends the program with an exception.
pub fn throw(this: *Interpreter, name: Exception.Name, comptime fmt: []const u8, args: anytype) Error {
    this.exception = .{ .name = name, .message = try std.fmt.allocPrint(this.arena, fmt, args) };
    return error.RuntimeError;
}

/// Runs the statements in order, returning the program's completion value (ECMA-262 §8.4): for
/// the most part, the value of the last expression statement that ran. It's what the REPL
/// prints.
pub fn run(this: *Interpreter, program: Program) Error!Value {
    const owned = try this.arena.create(Program);
    owned.* = program;
    this.setProgram(owned);
    this.exception = null;
    this.env = null;
    this.frame = 0;
    this.stack.clearRetainingCapacity();
    this.stack_limit = @frameAddress() -| this.max_stack;
    if (this.slots.items.len < program.resolved.slot_count) {
        try this.slots.appendNTimes(this.arena, .uninitialized, program.resolved.slot_count - this.slots.items.len);
    }
    try this.hoist(program.ast.statements);
    // There's nothing for a `break` or `return` to escape at the top level; the checker has made
    // sure.
    return switch (try this.statementList(program.ast.statements)) {
        .normal => |v| v orelse .undefined,
        else => unreachable,
    };
}

fn setProgram(this: *Interpreter, program: *const Program) void {
    this.program = program;
    this.refs = program.resolved.refs;
    this.bindings = program.resolved.bindings;
    this.environments = program.resolved.environments;
}

// Variables

fn envAt(this: *const Interpreter, hops: u32) *Env {
    var env = this.env.?;
    for (0..hops) |_| {
        env = env.parent.?;
    }
    return env;
}

/// Where a variable is, or null for a builtin.
inline fn location(this: *Interpreter, ref: Checker.Ref) ?*Value {
    return switch (ref) {
        .slot => |i| &this.slots.items[i],
        .local => |i| &this.stack.items[this.frame + i],
        .env => |e| &this.envAt(e.hops).values[e.index],
        .global => null,
    };
}

fn get(this: *Interpreter, id: ast.Identifier) Error!Value {
    const ref = this.refs[id.ref];
    const v = (this.location(ref) orelse return this.globals.get(ref.global).?).*;
    if (v == .uninitialized) {
        return this.throw(.ReferenceError, "Cannot access '{s}' before initialization", .{id.name});
    }
    return v;
}

/// A variable an assignment target writes to.
const Target = struct {
    ref: Checker.Ref,
    slot: *Value,

    /// Finds the variable again after evaluating something, which can move the stack.
    fn refresh(this: *Target, interpreter: *Interpreter) void {
        if (this.ref == .local) {
            this.slot = interpreter.location(this.ref).?;
        }
    }
};

fn target(this: *Interpreter, expr: *const Expr) Error!Target {
    return this.variableTarget(ast.skipParens(expr).data.identifier);
}

fn variableTarget(this: *Interpreter, id: ast.Identifier) Error!Target {
    const ref = this.refs[id.ref];
    const slot = this.location(ref).?;
    if (slot.* == .uninitialized) {
        return this.throw(.ReferenceError, "Cannot access '{s}' before initialization", .{id.name});
    }
    return .{ .ref = ref, .slot = slot };
}

/// Gives a declared name its first value.
fn initialize(this: *Interpreter, binding: u32, v: Value) void {
    this.location(this.bindings[binding]).?.* = v;
}

noinline fn destructure(this: *Interpreter, d: *const ast.Declarator, v: Value) Error!void {
    return this.bindPattern(d.pattern.?, v);
}

/// Gives the names in a destructuring pattern their values (BindingInitialization, §8.6.2).
noinline fn bindPattern(this: *Interpreter, pattern: *const ast.Pattern, v: Value) Error!void {
    switch (pattern.data) {
        .identifier => |b| this.initialize(b.binding, v),
        .object => |o| {
            if (v == .undefined or v == .null) {
                return this.throw(.TypeError, "Cannot destructure '{t}' as it is {t}.", .{ v, v });
            }
            for (o.properties) |p| {
                var property_value = try this.getNamed(v, p.key);
                if (property_value == .undefined) {
                    if (p.init) |default| {
                        property_value = try this.evaluate(default);
                    }
                }
                try this.bindPattern(p.value, property_value);
            }
            if (o.rest) |r| {
                const rest = try this.arena.create(value.Object);
                rest.* = .{};
                for (try this.ownKeys(v)) |key| {
                    const named = for (o.properties) |p| {
                        if (std.mem.eql(u8, p.key, key)) {
                            break true;
                        }
                    } else false;
                    if (!named) {
                        try rest.properties.put(this.arena, key, try this.getNamed(v, key));
                    }
                }
                this.initialize(r.binding, .{ .object = rest });
            }
        },
        .array => |a| {
            const array = switch (v) {
                .array => |x| x,
                .string => return this.throw(.Unsupported, "Destructuring a string is not supported yet.", .{}),
                else => return this.throw(.TypeError, "{s} is not iterable", .{try v.toString(this.arena)}),
            };
            for (a.elements, 0..) |element, i| {
                const e = element orelse continue;
                var item: Value = if (i < array.items().len) array.items()[i] else .undefined;
                if (item == .undefined) {
                    if (e.init) |default| {
                        item = try this.evaluate(default);
                    }
                }
                try this.bindPattern(e.pattern, item);
            }
            if (a.rest) |r| {
                const from = @min(a.elements.len, array.items().len);
                try this.bindPattern(r, try this.newArray(array.items()[from..]));
            }
        },
    }
}

fn newArray(this: *Interpreter, items: []const Value) Error!Value {
    const array = try this.arena.create(value.Array);
    array.* = .{ .elements = .empty };
    try array.elements.appendSlice(this.arena, items);
    return .{ .array = array };
}

/// The names of a value's own enumerable properties, in the order `for...in` and spread visit
/// them.
fn ownKeys(this: *Interpreter, v: Value) Error![]const []const u8 {
    switch (v) {
        // A copy, since the loop body can add and delete properties.
        .object => |o| return this.arena.dupe([]const u8, try o.keys(this.arena)),
        .array => |a| {
            const keys = try this.arena.alloc([]const u8, a.items().len);
            for (keys, 0..) |*key, i| {
                key.* = try std.fmt.allocPrint(this.arena, "{d}", .{i});
            }
            return keys;
        },
        .string => return this.throw(.Unsupported, "The properties of a string are not supported yet.", .{}),
        else => return &.{},
    }
}

/// Enters a scope, giving it an environment if closures capture any of its variables. The caller
/// restores `env` afterwards.
fn enterScope(this: *Interpreter, scope: u32) Error!void {
    const size = this.environments[scope];
    if (size == 0) {
        return;
    }
    const env = try this.arena.create(Env);
    const values = try this.arena.alloc(Value, size);
    @memset(values, .uninitialized);
    env.* = .{ .parent = this.env, .values = values };
    this.env = env;
}

/// CreatePerIterationEnvironment (§14.7.4.4): each pass through a `for` loop gets its own copy
/// of the variables its head declares, so closures created in different passes don't share them.
fn copyEnv(this: *Interpreter, scope: u32) Error!void {
    if (this.environments[scope] == 0) {
        return;
    }
    const env = try this.arena.create(Env);
    env.* = .{ .parent = this.env.?.parent, .values = try this.arena.dupe(Value, this.env.?.values) };
    this.env = env;
}

/// Creates the functions a statement list declares, which can be called before their
/// declarations.
fn hoist(this: *Interpreter, statements: []const *const Stmt) Error!void {
    for (statements) |stmt| {
        var s = stmt;
        while (s.data == .labeled) {
            s = s.data.labeled.body;
        }
        if (s.data == .function) {
            const f = s.data.function;
            this.initialize(f.name.?.binding, try this.closure(f));
        }
    }
}

fn closure(this: *Interpreter, f: *const ast.Function) Error!Value {
    const c = try this.arena.create(value.Closure);
    c.* = .{ .function = f, .env = this.env, .program = this.program };
    return .{ .function = c };
}

// Statements

/// How a statement finished. Null values are the spec's "empty".
const Completion = union(enum) {
    normal: ?Value,
    @"break": Jump,
    @"continue": Jump,
    @"return": Value,

    const Jump = struct {
        label: ?[]const u8,
        value: ?Value,
    };

    fn value(this: Completion) ?Value {
        return switch (this) {
            .normal => |v| v,
            .@"break", .@"continue" => |j| j.value,
            .@"return" => null,
        };
    }

    /// UpdateEmpty (§6.2.4.6): fills in the value if the statement didn't produce one.
    fn updateEmpty(this: Completion, v: Value) Completion {
        return switch (this) {
            .normal => |current| .{ .normal = current orelse v },
            .@"break" => |j| .{ .@"break" = .{ .label = j.label, .value = j.value orelse v } },
            .@"continue" => |j| .{ .@"continue" = .{ .label = j.label, .value = j.value orelse v } },
            .@"return" => this,
        };
    }
};

fn statementList(this: *Interpreter, statements: []const *Stmt) Error!Completion {
    var last: ?Value = null;
    for (statements) |stmt| {
        const completion = try this.statement(stmt, &.{});
        if (completion != .normal) {
            return if (last) |v| completion.updateEmpty(v) else completion;
        }
        last = completion.normal orelse last;
    }
    return .{ .normal = last };
}

/// `labels` are the labels directly on this statement (LabelledEvaluation's label set).
fn statement(this: *Interpreter, stmt: *const Stmt, labels: []const []const u8) Error!Completion {
    switch (stmt.data) {
        .expression => |e| return .{ .normal = try this.evaluate(e) },
        .empty => return .{ .normal = null },
        .variable => |v| {
            for (v.declarators) |*d| {
                const initial: Value = if (d.init) |e| try this.evaluate(e) else .undefined;
                if (d.pattern != null) {
                    try this.destructure(d, initial);
                } else {
                    this.initialize(d.binding, initial);
                }
            }
            return .{ .normal = null };
        },
        // Types only.
        .interface, .type_alias => return .{ .normal = null },
        // Created when its scope was entered.
        .function => return .{ .normal = null },
        .@"return" => |e| return .{ .@"return" = if (e) |v| try this.evaluate(v) else .undefined },
        .throw => |e| return this.throwValue(try this.evaluate(e)),
        .block => |b| {
            const saved = this.env;
            defer this.env = saved;
            try this.enterScope(b.scope);
            if (b.declares_functions) {
                try this.hoist(b.statements);
            }
            return this.statementList(b.statements);
        },
        .@"if" => |i| {
            const branch = if ((try this.evaluate(i.condition)).toBoolean()) i.then else i.otherwise orelse return .{ .normal = .undefined };
            return (try this.statement(branch, &.{})).updateEmpty(.undefined);
        },
        .@"while", .do_while, .@"for", .for_each => return breakable(try this.loop(stmt, labels)),
        .@"switch" => |sw| return breakable(try this.switchStatement(sw)),
        .@"break" => |j| return .{ .@"break" = .{ .label = j.label, .value = null } },
        .@"continue" => |j| return .{ .@"continue" = .{ .label = j.label, .value = null } },
        .labeled => |*l| {
            // Only `a: b: ...` needs a new list; a single label is used where it is.
            const all = if (labels.len == 0) (&l.label)[0..1] else try std.mem.concat(this.arena, []const u8, &.{ labels, &.{l.label} });
            const completion = try this.statement(l.body, all);
            if (completion == .@"break" and completion.@"break".label != null and std.mem.eql(u8, completion.@"break".label.?, l.label)) {
                return .{ .normal = completion.@"break".value };
            }
            return completion;
        },
    }
}

/// A loop or `switch` finishes normally when an unlabeled `break` leaves it.
fn breakable(completion: Completion) Completion {
    if (completion == .@"break" and completion.@"break".label == null) {
        return .{ .normal = completion.@"break".value orelse .undefined };
    }
    return completion;
}

/// LoopContinues (§14.7.1.2).
fn loopContinues(completion: Completion, labels: []const []const u8) bool {
    return switch (completion) {
        .normal => true,
        .@"break", .@"return" => false,
        .@"continue" => |j| if (j.label) |label| for (labels) |l| {
            if (std.mem.eql(u8, l, label)) {
                break true;
            }
        } else false else true,
    };
}

fn loop(this: *Interpreter, stmt: *const Stmt, labels: []const []const u8) Error!Completion {
    var v: Value = .undefined;
    switch (stmt.data) {
        .@"while" => |w| while ((try this.evaluate(w.condition)).toBoolean()) {
            const result = try this.statement(w.body, &.{});
            if (!loopContinues(result, labels)) {
                return result.updateEmpty(v);
            }
            v = result.value() orelse v;
        },
        .do_while => |d| while (true) {
            const result = try this.statement(d.body, &.{});
            if (!loopContinues(result, labels)) {
                return result.updateEmpty(v);
            }
            v = result.value() orelse v;
            if (!(try this.evaluate(d.condition)).toBoolean()) {
                break;
            }
        },
        .@"for" => |f| {
            const saved = this.env;
            defer this.env = saved;
            try this.enterScope(f.scope);
            if (f.init) |s| {
                _ = try this.statement(s, &.{});
            }
            try this.copyEnv(f.scope);
            while (true) {
                if (f.condition) |c| {
                    if (!(try this.evaluate(c)).toBoolean()) {
                        break;
                    }
                }
                const result = try this.statement(f.body, &.{});
                if (!loopContinues(result, labels)) {
                    return result.updateEmpty(v);
                }
                v = result.value() orelse v;
                try this.copyEnv(f.scope);
                if (f.update) |u| {
                    _ = try this.evaluate(u);
                }
            }
        },
        .for_each => |f| return this.forEach(f, labels),
        else => unreachable,
    }
    return .{ .normal = v };
}

/// `for...of` and `for...in`.
noinline fn forEach(this: *Interpreter, f: ast.ForEach, labels: []const []const u8) Error!Completion {
    var v: Value = .undefined;
    const saved = this.env;
    defer this.env = saved;
    // The head's names are in their temporal dead zone while the right side runs.
    try this.enterScope(f.scope);
    const right = try this.evaluate(f.right);
    if (f.of) {
        const array = switch (right) {
            .array => |a| a,
            .string => return this.throw(.Unsupported, "Iterating over a string is not supported yet.", .{}),
            else => return this.throw(.TypeError, "{s} is not iterable", .{try right.toString(this.arena)}),
        };
        // Elements added during the loop are visited too.
        var i: usize = 0;
        while (i < array.items().len) : (i += 1) {
            const result = try this.iteration(f, array.items()[i], saved);
            if (!loopContinues(result, labels)) {
                return result.updateEmpty(v);
            }
            v = result.value() orelse v;
        }
    } else {
        const keys = try this.ownKeys(right);
        for (keys) |key| {
            // A property deleted before it's reached isn't visited.
            if (right == .object and !right.object.properties.contains(key)) {
                continue;
            }
            const result = try this.iteration(f, .{ .string = key }, saved);
            if (!loopContinues(result, labels)) {
                return result.updateEmpty(v);
            }
            v = result.value() orelse v;
        }
    }
    return .{ .normal = v };
}

/// One pass of a `for...of` or `for...in`, with a fresh environment for the head's names.
fn iteration(this: *Interpreter, f: ast.ForEach, item: Value, outer: ?*Env) Error!Completion {
    this.env = outer;
    try this.enterScope(f.scope);
    switch (f.head) {
        .declaration => |d| try this.bindPattern(d.pattern, item),
        .target => |e| (try this.target(e)).slot.* = item,
    }
    return this.statement(f.body, &.{});
}

/// CaseBlockEvaluation (§14.12.4): runs from the first matching `case` (or the `default` if none
/// matches) to the end, unless something breaks out.
fn switchStatement(this: *Interpreter, sw: ast.Switch) Error!Completion {
    const discriminant = try this.evaluate(sw.discriminant);
    const saved = this.env;
    defer this.env = saved;
    try this.enterScope(sw.scope);
    for (sw.clauses) |clause| {
        try this.hoist(clause.statements);
    }
    var start: ?usize = null;
    for (sw.clauses, 0..) |clause, i| {
        const case = clause.case orelse continue;
        if ((try this.evaluate(case)).strictEquals(discriminant)) {
            start = i;
            break;
        }
    }
    if (start == null) {
        for (sw.clauses, 0..) |clause, i| {
            if (clause.case == null) {
                start = i;
            }
        }
    }
    var v: Value = .undefined;
    for (sw.clauses[start orelse return .{ .normal = v } ..]) |clause| {
        const result = try this.statementList(clause.statements);
        v = result.value() orelse v;
        if (result != .normal) {
            return result.updateEmpty(v);
        }
    }
    return .{ .normal = v };
}

fn evaluate(this: *Interpreter, expr: *const Expr) Error!Value {
    return switch (expr.data) {
        .number => |n| .{ .number = n },
        .string => |s| .{ .string = s },
        .boolean => |b| .{ .boolean = b },
        .null => .null,
        .template => |t| this.template(t),
        .identifier => |id| this.get(id),
        .function => |f| this.closure(f),
        .paren => |inner| this.evaluate(inner),
        .unary => |u| this.unary(u),
        .update => |u| this.update(u),
        .assign => |a| this.assign(a),
        .binary => |b| this.binary(b),
        .conditional => |c| if ((try this.evaluate(c.condition)).toBoolean()) this.evaluate(c.then) else this.evaluate(c.otherwise),
        .member => |m| this.member(m),
        .call => |c| this.call(c),
        .non_null => |inner| this.evaluate(inner),
        .assertion => |a| this.evaluate(a.expr),
        .index, .object, .array, .chain => this.evaluateObject(expr),
    };
}

/// Ends the program with a value from a `throw` statement.
noinline fn throwValue(this: *Interpreter, v: Value) Error {
    if (v == .string) {
        // Shown as `console.log` shows it.
        this.exception = .{ .name = .thrown, .message = v.string };
        return error.RuntimeError;
    }
    var out: std.Io.Writer.Allocating = .init(this.arena);
    // Writing to memory only fails when it runs out.
    value.inspect(this.arena, &out.writer, v) catch return error.OutOfMemory;
    this.exception = .{ .name = .thrown, .message = out.written() };
    return error.RuntimeError;
}

/// One link of an optional chain, or null when the chain short-circuits before it.
fn chainLink(this: *Interpreter, expr: *const Expr) Error!?Value {
    switch (expr.data) {
        .member => |m| {
            const object = try this.chainLink(m.object) orelse return null;
            if (m.optional and isNullish(object)) {
                return null;
            }
            return try this.getNamed(object, m.property);
        },
        .index => |i| {
            const object = try this.chainLink(i.object) orelse return null;
            if (i.optional and isNullish(object)) {
                return null;
            }
            return try this.getProperty(object, try this.evaluate(i.index));
        },
        .call => |c| {
            var receiver: Value = .undefined;
            const callee: Value = switch (c.callee.data) {
                .member => |m| blk: {
                    receiver = try this.chainLink(m.object) orelse return null;
                    if (m.optional and isNullish(receiver)) {
                        return null;
                    }
                    break :blk try this.getNamed(receiver, m.property);
                },
                .index => |i| blk: {
                    receiver = try this.chainLink(i.object) orelse return null;
                    if (i.optional and isNullish(receiver)) {
                        return null;
                    }
                    break :blk try this.getProperty(receiver, try this.evaluate(i.index));
                },
                else => try this.chainLink(c.callee) orelse return null,
            };
            if (c.optional and isNullish(callee)) {
                return null;
            }
            return try this.callValue(c, callee, receiver);
        },
        .non_null => |inner| return this.chainLink(inner),
        else => return try this.evaluate(expr),
    }
}

fn isNullish(v: Value) bool {
    return v == .null or v == .undefined;
}

/// Element access, object and array literals and optional chains, kept out of `evaluate`'s hot
/// path.
noinline fn evaluateObject(this: *Interpreter, expr: *const Expr) Error!Value {
    return switch (expr.data) {
        .index => |i| this.index(i),
        .object => |o| this.objectLiteral(o),
        .array => |a| this.arrayLiteral(a),
        .chain => |inner| try this.chainLink(inner) orelse .undefined,
        else => unreachable,
    };
}

fn member(this: *Interpreter, m: ast.Member) Error!Value {
    return this.getNamed(try this.evaluate(m.object), m.property);
}

fn index(this: *Interpreter, i: ast.Index) Error!Value {
    const object = try this.evaluate(i.object);
    return this.getProperty(object, try this.evaluate(i.index));
}

noinline fn objectLiteral(this: *Interpreter, o: ast.ObjectLiteral) Error!Value {
    const object = try this.arena.create(value.Object);
    object.* = .{};
    for (o.properties) |p| {
        switch (p) {
            .property => |prop| {
                const key = switch (prop.key) {
                    .name => |n| n,
                    .computed => |e| try this.propertyKey(try this.evaluate(e)),
                };
                var v = try this.evaluate(prop.value);
                // An anonymous function is named after its computed key.
                if (prop.key == .computed and v == .function and v.function.name().len == 0) {
                    const c = try this.arena.create(value.Closure);
                    c.* = v.function.*;
                    c.given_name = key;
                    v = .{ .function = c };
                }
                try object.properties.put(this.arena, key, v);
            },
            .spread => |spread| {
                const source = try this.evaluate(spread.expr);
                for (try this.ownKeys(source)) |key| {
                    try object.properties.put(this.arena, key, try this.getNamed(source, key));
                }
            },
        }
    }
    return .{ .object = object };
}

noinline fn arrayLiteral(this: *Interpreter, a: ast.ArrayLiteral) Error!Value {
    const array = try this.arena.create(value.Array);
    array.* = .{ .elements = .empty };
    try array.elements.ensureTotalCapacity(this.arena, a.elements.len);
    for (a.elements) |element| {
        switch (element) {
            .expr => |e| try array.elements.append(this.arena, try this.evaluate(e)),
            .spread => |e| switch (try this.evaluate(e)) {
                .array => |source| try array.elements.appendSlice(this.arena, source.items()),
                .string => return this.throw(.Unsupported, "Spreading a string is not supported yet.", .{}),
                else => |v| return this.throw(.TypeError, "{s} is not iterable", .{try v.toString(this.arena)}),
            },
        }
    }
    return .{ .array = array };
}

/// ToPropertyKey (§7.1.19).
fn propertyKey(this: *Interpreter, key: Value) Error![]const u8 {
    return key.toString(this.arena);
}

/// What an assignment, `++`/`--` or `delete` acts on.
const Reference = union(enum) {
    variable: Target,
    property: struct { object: Value, key: Value },
};

fn reference(this: *Interpreter, expr: *const Expr) Error!Reference {
    const e = ast.skipParens(expr);
    return switch (e.data) {
        .identifier => |id| .{ .variable = try this.variableTarget(id) },
        .member => |m| .{ .property = .{ .object = try this.evaluate(m.object), .key = .{ .string = m.property } } },
        .index => |i| blk: {
            const object = try this.evaluate(i.object);
            break :blk .{ .property = .{ .object = object, .key = try this.evaluate(i.index) } };
        },
        else => unreachable,
    };
}

fn getReference(this: *Interpreter, r: *Reference) Error!Value {
    return switch (r.*) {
        .variable => |t| t.slot.*,
        .property => |p| this.getProperty(p.object, p.key),
    };
}

fn setReference(this: *Interpreter, r: *Reference, v: Value) Error!void {
    switch (r.*) {
        .variable => |*t| {
            // Evaluating something since the reference was made can move the stack.
            t.refresh(this);
            t.slot.* = v;
        },
        .property => |p| try this.setProperty(p.object, p.key, v),
    }
}

fn update(this: *Interpreter, u: ast.Update) Error!Value {
    const operand = ast.skipParens(u.operand);
    if (operand.data != .identifier) {
        return this.updateProperty(u);
    }
    const t = try this.variableTarget(operand.data.identifier);
    const old = t.slot.toNumber();
    const new = if (u.increment) old + 1 else old - 1;
    t.slot.* = .{ .number = new };
    return .{ .number = if (u.prefix) new else old };
}

/// `++o.p` and friends, kept apart from the common case of a variable.
noinline fn updateProperty(this: *Interpreter, u: ast.Update) Error!Value {
    var r = try this.reference(u.operand);
    const old = (try this.getReference(&r)).toNumber();
    const new = if (u.increment) old + 1 else old - 1;
    try this.setReference(&r, .{ .number = new });
    return .{ .number = if (u.prefix) new else old };
}

fn assign(this: *Interpreter, a: ast.Assign) Error!Value {
    const target_expr = ast.skipParens(a.target);
    if (target_expr.data != .identifier) {
        return this.assignProperty(a);
    }
    const id = target_expr.data.identifier;
    const op = a.op orelse {
        // A variable still in its temporal dead zone throws only after the value is evaluated.
        const v = try this.evaluate(a.value);
        (try this.variableTarget(id)).slot.* = v;
        return v;
    };
    var t = try this.variableTarget(id);
    const current = t.slot.*;
    // The logical assignments only evaluate and assign the right side when they need it.
    const skip = switch (op) {
        .logical_and => !current.toBoolean(),
        .logical_or => current.toBoolean(),
        .nullish => current != .null and current != .undefined,
        else => {
            const result = try this.operate(op, current, try this.evaluate(a.value));
            t.refresh(this);
            t.slot.* = result;
            return result;
        },
    };
    if (skip) {
        return current;
    }
    const v = try this.evaluate(a.value);
    t.refresh(this);
    t.slot.* = v;
    return v;
}

/// An assignment to a property, kept apart from the common case of a variable.
noinline fn assignProperty(this: *Interpreter, a: ast.Assign) Error!Value {
    var r = try this.reference(a.target);
    const op = a.op orelse {
        const v = try this.evaluate(a.value);
        try this.setReference(&r, v);
        return v;
    };
    const current = try this.getReference(&r);
    const skip = switch (op) {
        .logical_and => !current.toBoolean(),
        .logical_or => current.toBoolean(),
        .nullish => current != .null and current != .undefined,
        else => {
            const result = try this.operate(op, current, try this.evaluate(a.value));
            try this.setReference(&r, result);
            return result;
        },
    };
    if (skip) {
        return current;
    }
    const v = try this.evaluate(a.value);
    try this.setReference(&r, v);
    return v;
}

fn template(this: *Interpreter, t: ast.Template) Error!Value {
    if (t.substitutions.len == 0) {
        return .{ .string = t.quasis[0] };
    }
    var out: std.ArrayList(u8) = .empty;
    for (t.quasis, 0..) |quasi, i| {
        try out.appendSlice(this.arena, quasi);
        if (i < t.substitutions.len) {
            const sub = try this.evaluate(t.substitutions[i]);
            try out.appendSlice(this.arena, try sub.toString(this.arena));
        }
    }
    return .{ .string = try out.toOwnedSlice(this.arena) };
}

fn unary(this: *Interpreter, u: ast.Unary) Error!Value {
    if (u.op == .delete) {
        return this.delete(u.operand);
    }
    const operand = try this.evaluate(u.operand);
    return switch (u.op) {
        .negate => .{ .number = -operand.toNumber() },
        .plus => .{ .number = operand.toNumber() },
        .not => .{ .boolean = !operand.toBoolean() },
        .bitwise_not => .{ .number = @floatFromInt(~value.toInt32(operand.toNumber())) },
        .typeof => .{ .string = operand.typeOf() },
        .void => .undefined,
        .delete => unreachable,
    };
}

/// The `delete` operator (§13.5.1). The checker only lets property references through.
noinline fn delete(this: *Interpreter, operand: *const Expr) Error!Value {
    const r = try this.reference(operand);
    const p = r.property;
    switch (p.object) {
        .object => |o| _ = o.properties.orderedRemove(try this.propertyKey(p.key)),
        .array => |a| {
            const key = try this.propertyKey(p.key);
            if (value.arrayIndex(key)) |i| {
                if (i < a.items().len) {
                    return this.throw(.Unsupported, "Deleting an array's elements is not supported yet.", .{});
                }
            }
        },
        .undefined, .null => return this.throw(.TypeError, "Cannot convert undefined or null to object", .{}),
        else => {},
    }
    return .{ .boolean = true };
}

/// The `in` operator (§13.10.1).
noinline fn hasProperty(this: *Interpreter, key: Value, object: Value) Error!bool {
    const name = try this.propertyKey(key);
    return switch (object) {
        .object => |o| o.properties.contains(name),
        .array => |a| std.mem.eql(u8, name, "length") or if (value.arrayIndex(name)) |i| i < a.items().len else false,
        .function => if (std.mem.eql(u8, name, "prototype"))
            this.throw(.Unsupported, "Functions' 'prototype' is not supported yet.", .{})
        else
            std.mem.eql(u8, name, "name") or std.mem.eql(u8, name, "length"),
        .native_function => std.mem.eql(u8, name, "name") or std.mem.eql(u8, name, "length"),
        else => this.throw(.TypeError, "Cannot use 'in' operator to search for '{s}' in {s}", .{ name, try object.toString(this.arena) }),
    };
}

fn binary(this: *Interpreter, b: ast.Binary) Error!Value {
    // The short-circuiting operators evaluate the right side only when needed.
    switch (b.op) {
        .logical_and => {
            const left = try this.evaluate(b.left);
            return if (!left.toBoolean()) left else this.evaluate(b.right);
        },
        .logical_or => {
            const left = try this.evaluate(b.left);
            return if (left.toBoolean()) left else this.evaluate(b.right);
        },
        .nullish => {
            const left = try this.evaluate(b.left);
            return if (left == .null or left == .undefined) this.evaluate(b.right) else left;
        },
        else => {},
    }

    const left = try this.evaluate(b.left);
    const right = try this.evaluate(b.right);
    return this.operate(b.op, left, right);
}

/// A binary operator other than the short-circuiting ones, applied to evaluated operands.
fn operate(this: *Interpreter, op: ast.BinaryOp, left: Value, right: Value) Error!Value {
    return switch (op) {
        .comma => right,
        .add => this.add(left, right),
        .subtract => .{ .number = left.toNumber() - right.toNumber() },
        .multiply => .{ .number = left.toNumber() * right.toNumber() },
        .divide => .{ .number = left.toNumber() / right.toNumber() },
        // JS `%` truncates toward zero and keeps the dividend's sign, which is `@rem`.
        .remainder => .{ .number = remainder(left.toNumber(), right.toNumber()) },
        .exponent => .{ .number = value.exponentiate(left.toNumber(), right.toNumber()) },
        .shift_left => int32(value.toInt32(left.toNumber()) << shiftCount(right)),
        .shift_right => int32(value.toInt32(left.toNumber()) >> shiftCount(right)),
        .shift_right_unsigned => .{ .number = @floatFromInt(value.toUint32(left.toNumber()) >> shiftCount(right)) },
        .bitwise_and => int32(value.toInt32(left.toNumber()) & value.toInt32(right.toNumber())),
        .bitwise_or => int32(value.toInt32(left.toNumber()) | value.toInt32(right.toNumber())),
        .bitwise_xor => int32(value.toInt32(left.toNumber()) ^ value.toInt32(right.toNumber())),
        .less => .{ .boolean = try this.lessThan(left, right) orelse false },
        .greater => .{ .boolean = try this.lessThan(right, left) orelse false },
        // `a <= b` is `!(b < a)`, except that NaN makes every comparison false.
        .less_equal => .{ .boolean = if (try this.lessThan(right, left)) |r| !r else false },
        .greater_equal => .{ .boolean = if (try this.lessThan(left, right)) |r| !r else false },
        .equal => .{ .boolean = try left.looseEquals(right, this.arena) },
        .not_equal => .{ .boolean = !try left.looseEquals(right, this.arena) },
        .strict_equal => .{ .boolean = left.strictEquals(right) },
        .strict_not_equal => .{ .boolean = !left.strictEquals(right) },
        .in => .{ .boolean = try this.hasProperty(left, right) },
        .logical_and, .logical_or, .nullish => unreachable,
    };
}

fn int32(n: i32) Value {
    return .{ .number = @floatFromInt(n) };
}

fn shiftCount(v: Value) u5 {
    return @truncate(value.toUint32(v.toNumber()));
}

fn remainder(n: f64, d: f64) f64 {
    if (std.math.isNan(n) or std.math.isNan(d) or std.math.isInf(n) or d == 0) {
        return std.math.nan(f64);
    }
    if (std.math.isInf(d)) {
        return n;
    }
    if (n == 0) {
        return n;
    }
    return @rem(n, d);
}

/// The `+` operator (§13.15.3): string concatenation if either side is a string after
/// ToPrimitive, numeric addition otherwise.
fn add(this: *Interpreter, left: Value, right: Value) Error!Value {
    if (left == .number and right == .number) {
        return .{ .number = left.number + right.number };
    }
    const lp = try left.toPrimitive(this.arena);
    const rp = try right.toPrimitive(this.arena);
    if (lp == .string or rp == .string) {
        const ls = try lp.toString(this.arena);
        const rs = try rp.toString(this.arena);
        return .{ .string = try std.mem.concat(this.arena, u8, &.{ ls, rs }) };
    }
    return .{ .number = lp.toNumber() + rp.toNumber() };
}

/// IsLessThan (§7.2.13): null when either side is NaN.
fn lessThan(this: *Interpreter, a: Value, b: Value) Error!?bool {
    if (a == .number and b == .number) {
        return if (std.math.isNan(a.number) or std.math.isNan(b.number)) null else a.number < b.number;
    }
    const ap = try a.toPrimitive(this.arena);
    const bp = try b.toPrimitive(this.arena);
    if (ap == .string and bp == .string) {
        return value.compareStrings(ap.string, bp.string) == .lt;
    }
    const x = ap.toNumber();
    const y = bp.toNumber();
    if (std.math.isNan(x) or std.math.isNan(y)) {
        return null;
    }
    return x < y;
}

/// `object[key]`.
fn getProperty(this: *Interpreter, object: Value, key: Value) Error!Value {
    // The common case, an array element, without making the key a string.
    if (object == .array and key == .number) {
        const n = key.number;
        const items = object.array.items();
        if (n >= 0 and n == @trunc(n) and n < @as(f64, @floatFromInt(items.len))) {
            return items[@intFromFloat(n)];
        }
    }
    return this.getNamed(object, try this.propertyKey(key));
}

/// `object.name`.
fn getNamed(this: *Interpreter, object: Value, name: []const u8) Error!Value {
    switch (object) {
        .object => |o| return o.get(name),
        .function => |f| {
            if (std.mem.eql(u8, name, "name")) {
                return .{ .string = f.name() };
            }
            if (std.mem.eql(u8, name, "length")) {
                return .{ .number = @floatFromInt(f.function.length()) };
            }
        },
        .native_function => |f| {
            if (std.mem.eql(u8, name, "name")) {
                return .{ .string = f.name };
            }
        },
        .array => |a| {
            if (std.mem.eql(u8, name, "length")) {
                return .{ .number = @floatFromInt(a.items().len) };
            }
            if (value.arrayIndex(name)) |i| {
                return if (i < a.items().len) a.items()[i] else .undefined;
            }
        },
        .undefined, .null => return this.throw(.TypeError, "Cannot read properties of {t} (reading '{s}')", .{ object, name }),
        else => {},
    }
    return this.throw(.Unsupported, "Reading the property '{s}' of a {s} is not supported yet.", .{ name, object.typeOf() });
}

/// `object[key] = v`.
fn setProperty(this: *Interpreter, object: Value, key: Value, v: Value) Error!void {
    const name = try this.propertyKey(key);
    switch (object) {
        .object => |o| return o.properties.put(this.arena, name, v),
        .array => |a| if (value.arrayIndex(name)) |i| {
            if (i < a.items().len) {
                a.items()[i] = v;
                return;
            }
            if (i == a.items().len) {
                return a.elements.append(this.arena, v);
            }
            return this.throw(.Unsupported, "Assigning past the end of an array, which leaves holes in it, is not supported yet.", .{});
        },
        .undefined, .null => return this.throw(.TypeError, "Cannot set properties of {t} (setting '{s}')", .{ object, name }),
        else => {},
    }
    return this.throw(.Unsupported, "Setting the property '{s}' of a {s} is not supported yet.", .{ name, object.typeOf() });
}

fn call(this: *Interpreter, c: ast.Call) Error!Value {
    var receiver: Value = .undefined;
    const callee = switch (c.callee.data) {
        .member => |m| blk: {
            receiver = try this.evaluate(m.object);
            break :blk try this.getNamed(receiver, m.property);
        },
        .index => |i| blk: {
            receiver = try this.evaluate(i.object);
            break :blk try this.getProperty(receiver, try this.evaluate(i.index));
        },
        else => try this.evaluate(c.callee),
    };
    return @call(.always_inline, callValue, .{ this, c, callee, receiver });
}

/// Evaluates a call's arguments and calls `callee` with them.
fn callValue(this: *Interpreter, c: ast.Call, callee: Value, receiver: Value) Error!Value {
    const args = try this.arena.alloc(Value, c.arguments.len);
    for (c.arguments, args) |arg, *slot| {
        slot.* = try this.evaluate(arg);
    }
    return switch (callee) {
        .native_function => |f| f.call(this, receiver, args) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.WriteFailed => error.WriteFailed,
            error.RuntimeError => error.RuntimeError,
            else => unreachable,
        },
        .function => |f| this.callFunction(f, args),
        // Only possible through `any`.
        else => this.throw(.TypeError, "{s} is not a function", .{calleeText(c.callee)}),
    };
}

/// How node names a callee in "is not a function".
fn calleeText(expr: *const Expr) []const u8 {
    return switch (expr.data) {
        .identifier => |id| id.name,
        .member => |m| m.property,
        .chain, .non_null, .paren => |inner| calleeText(inner),
        else => "expression",
    };
}

/// Calls a function from the source with evaluated arguments.
pub fn callFunction(this: *Interpreter, c: *const value.Closure, args: []const Value) Error!Value {
    if (@frameAddress() < this.stack_limit) {
        return this.throw(.RangeError, "Maximum call stack size exceeded", .{});
    }
    const f = c.function;
    const saved_program = this.program;
    const saved_env = this.env;
    const saved_frame = this.frame;
    const saved_len = this.stack.items.len;
    defer {
        this.setProgram(saved_program);
        this.env = saved_env;
        this.frame = saved_frame;
        this.stack.shrinkRetainingCapacity(saved_len);
    }
    this.setProgram(c.program);
    this.env = c.env;
    this.frame = saved_len;
    try this.stack.appendNTimes(this.arena, .undefined, this.program.resolved.frames[f.id]);

    try this.enterScope(f.scope);
    if (f.kind == .expression) {
        if (f.name) |n| {
            this.initialize(n.binding, .{ .function = c });
        }
    }
    for (f.parameters, 0..) |p, i| {
        var v: Value = undefined;
        if (p.rest) {
            v = try this.newArray(args[@min(i, args.len)..]);
        } else {
            v = if (i < args.len) args[i] else .undefined;
            if (v == .undefined) {
                if (p.init) |default| {
                    v = try this.evaluate(default);
                }
            }
        }
        if (p.pattern) |pattern| {
            try this.bindPattern(pattern, v);
        } else {
            this.initialize(p.binding, v);
        }
    }
    switch (f.body) {
        .expression => |e| return this.evaluate(e),
        .block => |b| {
            try this.enterScope(b.scope);
            try this.hoist(b.statements);
            return switch (try this.statementList(b.statements)) {
                .@"return" => |v| v,
                else => .undefined,
            };
        },
    }
}

/// Reaches the interpreter from a native function's opaque context.
pub fn fromContext(context: *anyopaque) *Interpreter {
    return @ptrCast(@alignCast(context));
}
