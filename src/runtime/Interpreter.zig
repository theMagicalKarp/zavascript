//! Evaluates a checked program by walking its syntax tree.

const std = @import("std");
const ast = @import("../syntax/ast.zig");
const Checker = @import("../check/Checker.zig");
const value = @import("value.zig");
const number = @import("number.zig");
const Value = value.Value;
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
/// Every variable's value, indexed by the slot the checker gave it. There are no functions yet,
/// so each declaration has exactly one slot, kept for the life of the runtime so the REPL can
/// use it on later lines.
slots: std.ArrayList(Value) = .empty,
/// What the identifiers of the program being run resolve to.
refs: []const Checker.Ref = &.{},
/// The slot of the running program's first variable.
slot_base: u32 = 0,

pub const Error = error{ OutOfMemory, WriteFailed };

pub fn init(arena: std.mem.Allocator, stdout: *std.Io.Writer, stderr: *std.Io.Writer) Error!Interpreter {
    var interpreter: Interpreter = .{ .arena = arena, .stdout = stdout, .stderr = stderr };
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
};

/// Runs the statements in order, returning the program's completion value (ECMA-262 §8.4): for
/// the most part, the value of the last expression statement that ran. It's what the REPL
/// prints.
pub fn run(this: *Interpreter, program: Program) Error!Value {
    this.refs = program.resolved.refs;
    this.slot_base = program.resolved.slot_base;
    if (this.slots.items.len < program.resolved.slot_count) {
        try this.slots.appendNTimes(this.arena, .undefined, program.resolved.slot_count - this.slots.items.len);
    }
    // There's nothing for a `break` to escape at the top level; the checker has made sure.
    return switch (try this.statementList(program.ast.statements)) {
        .normal => |v| v orelse .undefined,
        else => unreachable,
    };
}

// Statements

/// How a statement finished. Null values are the spec's "empty".
const Completion = union(enum) {
    normal: ?Value,
    @"break": Jump,
    @"continue": Jump,

    const Jump = struct {
        label: ?[]const u8,
        value: ?Value,
    };

    fn value(this: Completion) ?Value {
        return switch (this) {
            .normal => |v| v,
            .@"break", .@"continue" => |j| j.value,
        };
    }

    /// UpdateEmpty (§6.2.4.6): fills in the value if the statement didn't produce one.
    fn updateEmpty(this: Completion, v: Value) Completion {
        return switch (this) {
            .normal => |current| .{ .normal = current orelse v },
            .@"break" => |j| .{ .@"break" = .{ .label = j.label, .value = j.value orelse v } },
            .@"continue" => |j| .{ .@"continue" = .{ .label = j.label, .value = j.value orelse v } },
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
            for (v.declarators) |d| {
                const initial: Value = if (d.init) |e| try this.evaluate(e) else .undefined;
                this.slots.items[this.slotOf(d)] = initial;
            }
            return .{ .normal = null };
        },
        .block => |statements| return this.statementList(statements),
        .@"if" => |i| {
            const branch = if ((try this.evaluate(i.condition)).toBoolean()) i.then else i.otherwise orelse return .{ .normal = .undefined };
            return (try this.statement(branch, &.{})).updateEmpty(.undefined);
        },
        .@"while", .do_while, .@"for" => return breakable(try this.loop(stmt, labels)),
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

fn slotOf(this: *const Interpreter, d: ast.Declarator) u32 {
    return this.slot_base + d.binding;
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
        .@"break" => false,
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
            if (f.init) |s| {
                _ = try this.statement(s, &.{});
            }
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
                if (f.update) |u| {
                    _ = try this.evaluate(u);
                }
            }
        },
        else => unreachable,
    }
    return .{ .normal = v };
}

/// CaseBlockEvaluation (§14.12.4): runs from the first matching `case` (or the `default` if none
/// matches) to the end, unless something breaks out.
fn switchStatement(this: *Interpreter, sw: ast.Switch) Error!Completion {
    const discriminant = try this.evaluate(sw.discriminant);
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
        .paren => |inner| this.evaluate(inner),
        .unary => |u| this.unary(u),
        .update => |u| this.update(u),
        .assign => |a| this.assign(a),
        .binary => |b| this.binary(b),
        .conditional => |c| if ((try this.evaluate(c.condition)).toBoolean()) this.evaluate(c.then) else this.evaluate(c.otherwise),
        .member => |m| this.member(m),
        .call => |c| this.call(c),
    };
}

fn get(this: *Interpreter, id: ast.Identifier) Value {
    return switch (this.refs[id.ref]) {
        .slot => |slot| this.slots.items[slot],
        // The checker has already rejected unknown names.
        .global => |name| this.globals.get(name).?,
    };
}

/// The slot an assignment target writes to. The checker only lets variables through.
fn targetSlot(this: *const Interpreter, target: *const Expr) u32 {
    return this.refs[ast.skipParens(target).data.identifier.ref].slot;
}

fn update(this: *Interpreter, u: ast.Update) Error!Value {
    const slot = this.targetSlot(u.operand);
    const old = this.slots.items[slot].toNumber();
    const new = if (u.increment) old + 1 else old - 1;
    this.slots.items[slot] = .{ .number = new };
    return .{ .number = if (u.prefix) new else old };
}

fn assign(this: *Interpreter, a: ast.Assign) Error!Value {
    const slot = this.targetSlot(a.target);
    const op = a.op orelse {
        const v = try this.evaluate(a.value);
        this.slots.items[slot] = v;
        return v;
    };
    const current = this.slots.items[slot];
    // The logical assignments only evaluate and assign the right side when they need it.
    const skip = switch (op) {
        .logical_and => !current.toBoolean(),
        .logical_or => current.toBoolean(),
        .nullish => current != .null and current != .undefined,
        else => {
            const result = try this.operate(op, current, try this.evaluate(a.value));
            this.slots.items[slot] = result;
            return result;
        },
    };
    if (skip) {
        return current;
    }
    const v = try this.evaluate(a.value);
    this.slots.items[slot] = v;
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
    const operand = try this.evaluate(u.operand);
    return switch (u.op) {
        .negate => .{ .number = -operand.toNumber() },
        .plus => .{ .number = operand.toNumber() },
        .not => .{ .boolean = !operand.toBoolean() },
        .bitwise_not => .{ .number = @floatFromInt(~value.toInt32(operand.toNumber())) },
        .typeof => .{ .string = operand.typeOf() },
        .void => .undefined,
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
        .less => .{ .boolean = lessThan(left, right) orelse false },
        .greater => .{ .boolean = lessThan(right, left) orelse false },
        // `a <= b` is `!(b < a)`, except that NaN makes every comparison false.
        .less_equal => .{ .boolean = if (lessThan(right, left)) |r| !r else false },
        .greater_equal => .{ .boolean = if (lessThan(left, right)) |r| !r else false },
        .equal => .{ .boolean = left.looseEquals(right) },
        .not_equal => .{ .boolean = !left.looseEquals(right) },
        .strict_equal => .{ .boolean = left.strictEquals(right) },
        .strict_not_equal => .{ .boolean = !left.strictEquals(right) },
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
    const lp = left.toPrimitive();
    const rp = right.toPrimitive();
    if (lp == .string or rp == .string) {
        const ls = try lp.toString(this.arena);
        const rs = try rp.toString(this.arena);
        return .{ .string = try std.mem.concat(this.arena, u8, &.{ ls, rs }) };
    }
    return .{ .number = lp.toNumber() + rp.toNumber() };
}

/// IsLessThan (§7.2.13): null when either side is NaN.
fn lessThan(a: Value, b: Value) ?bool {
    const ap = a.toPrimitive();
    const bp = b.toPrimitive();
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

fn member(this: *Interpreter, m: ast.Member) Error!Value {
    const object = try this.evaluate(m.object);
    return switch (object) {
        .object => |o| o.get(m.property),
        // The checker only lets property reads through on objects so far.
        else => unreachable,
    };
}

fn call(this: *Interpreter, c: ast.Call) Error!Value {
    var receiver: Value = .undefined;
    const callee = switch (c.callee.data) {
        .member => |m| blk: {
            receiver = try this.evaluate(m.object);
            break :blk receiver.object.get(m.property);
        },
        else => try this.evaluate(c.callee),
    };
    const args = try this.arena.alloc(Value, c.arguments.len);
    for (c.arguments, args) |arg, *slot| {
        slot.* = try this.evaluate(arg);
    }
    return switch (callee) {
        .native_function => |f| f.call(this, receiver, args) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.WriteFailed => error.WriteFailed,
            else => unreachable,
        },
        else => unreachable,
    };
}

/// Reaches the interpreter from a native function's opaque context.
pub fn fromContext(context: *anyopaque) *Interpreter {
    return @ptrCast(@alignCast(context));
}
