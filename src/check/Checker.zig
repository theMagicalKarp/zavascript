//! Type checks a program the way `tsc --strict` does, reporting tsc's codes and messages. A
//! program with any diagnostics never runs.
//!
//! Expressions are checked bottom-up. After an error the checker keeps going with the type the
//! expression would have had (e.g. `boolean` for a bad `<`), like tsc, so independent errors are
//! all reported but one mistake doesn't cascade.
//!
//! Alongside types, the checker follows control flow the way tsc's flow analysis does: which
//! variables are definitely assigned (TS2454), and what an assignment narrows a variable to
//! (`let b = true` is `true` until something assigns `false`). A loop is checked repeatedly until
//! the state at its head stops changing; only the last pass's diagnostics are kept.
//!
//! It also resolves every identifier to a variable slot or a global, which the interpreter reads
//! from `Resolved.refs` instead of looking names up again.

const std = @import("std");
const Source = @import("../Source.zig");
const diagnostic = @import("../diagnostic.zig");
const ast = @import("../syntax/ast.zig");
const types = @import("types.zig");
const Type = types.Type;
const Expr = ast.Expr;
const Stmt = ast.Stmt;

const Checker = @This();

arena: std.mem.Allocator,
source: *const Source,
diagnostics: *diagnostic.Diagnostics,
session: *Session,
refs: []Ref,
/// The slot of the program's first variable; `Declarator.binding` counts from here.
slot_base: u32,
/// The innermost block scope, or null at the top level, whose names live in the session.
scope: ?*Scope = null,
flow: Flow,
/// Enclosing statements that `break` and `continue` can jump to, innermost last.
targets: std.ArrayList(Target) = .empty,
/// Every enclosing label, for TS1114.
labels: std.ArrayList([]const u8) = .empty,
/// Names this program added to the session's top level, removed again if it doesn't check.
added: std.ArrayList([]const u8) = .empty,
/// Uncalled-function checks (TS2774) waiting until the code they look at has been checked.
pending: std.ArrayList(Pending) = .empty,
/// While above zero, diagnostics are dropped; for checking an expression a second time.
muted: u32 = 0,
/// Variables whose types are being worked out early, for a use before their declaration; each
/// was reached from the one before it.
lazy: std.ArrayList(u32) = .empty,
/// The comma expression in `(0, a.b)()`, which isn't reported as unused (TS2695).
indirect_call: ?*const Expr = null,

const Error = error{OutOfMemory};

/// What an identifier refers to.
pub const Ref = union(enum) {
    /// A builtin, looked up by name. Also used for names that didn't resolve, since such a program
    /// never runs.
    global: []const u8,
    /// A variable's index in the interpreter's slots.
    slot: u32,

    fn eql(a: Ref, b: Ref) bool {
        return switch (a) {
            .global => |name| b == .global and std.mem.eql(u8, name, b.global),
            .slot => |slot| b == .slot and slot == b.slot,
        };
    }
};

/// What the interpreter needs from the checker.
pub const Resolved = struct {
    /// Indexed by `Identifier.ref`.
    refs: []const Ref,
    slot_base: u32,
    /// `slot_base` plus the program's variables.
    slot_count: u32,
};

/// Declarations that outlive one program, so the REPL can use them on later lines.
pub const Session = struct {
    /// Every variable so far, indexed by slot.
    variables: std.ArrayList(Variable) = .empty,
    /// Top-level names, mapped to slots.
    top_level: std.StringHashMapUnmanaged(u32) = .empty,
    /// The flow state at the end of the last program that checked cleanly.
    flow: []VarFlow = &.{},
};

const Variable = struct {
    name: []const u8,
    kind: ast.VariableKind,
    /// Where the name is.
    start: u32,
    /// Where the declarator ends; see `ast.Declarator.end`.
    end: u32,
    source: *const Source,
    annotation: ?*const ast.TypeNode,
    init: ?*const Expr,
    /// Null until the declaration has been checked.
    declared: ?*const Type = null,
    /// Its initializer is being checked, so a reference now is circular (TS7022).
    resolving: bool = false,
    circular: bool = false,
    /// TS2451 has been reported at this declaration.
    redeclared: bool = false,
};

const Scope = struct {
    parent: ?*Scope,
    names: std.StringHashMapUnmanaged(u32) = .empty,
};

/// What flow analysis knows about one variable at one point in the program.
pub const VarFlow = struct {
    /// Its declaration has run, so it's out of its temporal dead zone.
    initialized: bool = false,
    /// What it holds, narrowed by the last assignment; null when it may not have been assigned.
    type: ?*const Type = null,
};

/// The state at one point in the program. Every reachable flow has one entry per slot. Each
/// `Flow` value owns its `vars`; splitting the flow copies them.
const Flow = struct {
    reachable: bool,
    vars: []VarFlow,

    const unreachable_flow: Flow = .{ .reachable = false, .vars = &.{} };

    fn eql(a: Flow, b: Flow) bool {
        if (a.reachable != b.reachable) {
            return false;
        }
        if (!a.reachable) {
            return true;
        }
        for (a.vars, b.vars) |x, y| {
            if (x.initialized != y.initialized) {
                return false;
            }
            if (x.type == null or y.type == null) {
                if (x.type != y.type) {
                    return false;
                }
            } else if (!x.type.?.eql(y.type.?)) {
                return false;
            }
        }
        return true;
    }
};

const Target = struct {
    kind: enum { loop, @"switch", label },
    /// Labels that name this statement.
    labels: []const []const u8,
    breaks: Flow = .unreachable_flow,
    continues: Flow = .unreachable_flow,
};

/// The right operands of the `&&` expressions a condition is the left operand of, innermost first.
const AndChain = struct {
    right: *const Expr,
    parent: ?*const AndChain,
};

/// What a condition is tested against for TS2774: the code that runs when it's true.
const Body = union(enum) {
    none,
    stmt: *const Stmt,
    expr: *const Expr,
};

const Pending = struct {
    condition: *const Expr,
    type: *const Type,
    body: Body,
    chain: ?*const AndChain,
};

/// A condition's type, and the flow when it's true and when it's false.
const Branches = struct {
    type: *const Type,
    when_true: Flow,
    when_false: Flow,
};

/// Checks `program`, adding its top-level declarations to `session` if there are no errors.
pub fn check(arena: std.mem.Allocator, source: *const Source, diagnostics: *diagnostic.Diagnostics, session: *Session, program: ast.Program) Error!Resolved {
    const slot_base: u32 = @intCast(session.variables.items.len);
    const slot_count = slot_base + program.binding_count;
    try session.variables.resize(arena, slot_count);
    const vars = try arena.alloc(VarFlow, slot_count);
    @memcpy(vars[0..session.flow.len], session.flow);
    @memset(vars[session.flow.len..], .{});

    var checker: Checker = .{
        .arena = arena,
        .source = source,
        .diagnostics = diagnostics,
        .session = session,
        .refs = try arena.alloc(Ref, program.reference_count),
        .slot_base = slot_base,
        .flow = .{ .reachable = true, .vars = vars },
    };
    const errors_before = diagnostics.items().len;
    try checker.prescan(program.statements);
    for (program.statements) |stmt| {
        try checker.statement(stmt);
    }

    if (diagnostics.items().len > errors_before) {
        session.variables.shrinkRetainingCapacity(slot_base);
        for (checker.added.items) |name| {
            _ = session.top_level.remove(name);
        }
    } else if (checker.flow.reachable) {
        session.flow = checker.flow.vars;
    } else {
        // The program never finishes (`while (true) {}`), so nothing after it runs either.
        @memset(vars[session.flow.len..], .{ .initialized = true });
        session.flow = vars;
    }
    return .{ .refs = checker.refs, .slot_base = slot_base, .slot_count = slot_count };
}

fn report(this: *Checker, at: u32, code: diagnostic.Code, comptime fmt: []const u8, args: anytype) Error!void {
    if (this.muted > 0) {
        return;
    }
    try this.diagnostics.add(this.source, at, code, fmt, args);
}

fn unsupported(this: *Checker, at: u32, comptime fmt: []const u8, args: anytype) Error!void {
    try this.report(at, diagnostic.zv.unsupported, fmt, args);
}

// Flow

fn copyFlow(this: *Checker, flow: Flow) Error!Flow {
    if (!flow.reachable) {
        return .unreachable_flow;
    }
    return .{ .reachable = true, .vars = try this.arena.dupe(VarFlow, flow.vars) };
}

/// Where two paths meet: a variable is assigned if it is on both, and holds either path's type.
fn mergeInto(this: *Checker, into: *Flow, other: Flow) Error!void {
    if (!other.reachable) {
        return;
    }
    if (!into.reachable) {
        into.* = try this.copyFlow(other);
        return;
    }
    for (into.vars, other.vars) |*a, b| {
        a.initialized = a.initialized and b.initialized;
        if (a.type == null or b.type == null) {
            a.type = null;
        } else if (!a.type.?.eql(b.type.?)) {
            a.type = try types.unionOf(this.arena, &.{ a.type.?, b.type.? });
        }
    }
}

fn setVariable(this: *Checker, slot: u32, t: *const Type) void {
    if (this.flow.reachable) {
        this.flow.vars[slot] = .{ .initialized = true, .type = t };
    }
}

// Scopes and declarations

fn pushScope(this: *Checker) Error!void {
    const scope = try this.arena.create(Scope);
    scope.* = .{ .parent = this.scope };
    this.scope = scope;
}

fn popScope(this: *Checker) void {
    this.scope = this.scope.?.parent;
}

/// Declares a statement list's `let` and `const` variables up front, so a use before the
/// declaration finds it and reports TS2448 rather than an unknown name.
fn prescan(this: *Checker, statements: []const *const Stmt) Error!void {
    for (statements) |stmt| {
        var s = stmt;
        while (s.data == .labeled) {
            s = s.data.labeled.body;
        }
        if (s.data == .variable) {
            try this.declare(s.data.variable);
        }
    }
}

fn declare(this: *Checker, v: ast.Variable) Error!void {
    for (v.declarators) |d| {
        const slot = this.slot_base + d.binding;
        this.session.variables.items[slot] = .{
            .name = d.name,
            .kind = v.kind,
            .start = d.start,
            .end = d.end,
            .source = this.source,
            .annotation = d.type,
            .init = d.init,
        };
        if (this.flow.reachable) {
            this.flow.vars[slot] = .{};
        }
        const names = if (this.scope) |scope| &scope.names else &this.session.top_level;
        const entry = try names.getOrPut(this.arena, d.name);
        if (!entry.found_existing) {
            entry.value_ptr.* = slot;
            if (this.scope == null) {
                try this.added.append(this.arena, d.name);
            }
            continue;
        }
        const first = &this.session.variables.items[entry.value_ptr.*];
        if (first.source == this.source and !first.redeclared) {
            try this.report(first.start, .ts(2451), "Cannot redeclare block-scoped variable '{s}'.", .{d.name});
            first.redeclared = true;
        }
        try this.report(d.start, .ts(2451), "Cannot redeclare block-scoped variable '{s}'.", .{d.name});
    }
}

fn lookup(this: *Checker, name: []const u8) ?u32 {
    var scope = this.scope;
    while (scope) |s| : (scope = s.parent) {
        if (s.names.get(name)) |slot| {
            return slot;
        }
    }
    return this.session.top_level.get(name);
}

fn variable(this: *Checker, slot: u32) *Variable {
    return &this.session.variables.items[slot];
}

/// A variable's type. For a use before the declaration has been checked (already an error), the
/// type is worked out from the declaration without reporting anything.
fn declaredType(this: *Checker, slot: u32) Error!*const Type {
    const v = this.variable(slot);
    if (v.declared) |t| {
        return t;
    }
    if (v.resolving) {
        // Every variable on the way back here is part of the cycle.
        const from = if (std.mem.indexOfScalar(u32, this.lazy.items, slot)) |i| i + 1 else 0;
        try this.circular(slot);
        for (this.lazy.items[from..]) |s| {
            try this.circular(s);
        }
        return types.any;
    }
    this.muted += 1;
    defer this.muted -= 1;
    if (v.annotation) |annotation| {
        return this.resolveType(annotation);
    }
    const init = v.init orelse return types.any;
    const saved = this.flow;
    defer this.flow = saved;
    this.flow = try this.copyFlow(saved);
    v.resolving = true;
    defer v.resolving = false;
    try this.lazy.append(this.arena, slot);
    defer _ = this.lazy.pop();
    const t = try this.expression(init);
    return if (v.kind == .let) types.widenFresh(this.arena, t) else t;
}

/// Reports a variable whose type depends on itself (TS7022), even while muted, since the
/// variable's type is `any` because of it.
fn circular(this: *Checker, slot: u32) Error!void {
    const v = this.variable(slot);
    if (v.circular) {
        return;
    }
    v.circular = true;
    try this.diagnostics.add(this.source, v.start, .ts(7022), "'{s}' implicitly has type 'any' because it does not have a type annotation and is referenced directly or indirectly in its own initializer.", .{v.name});
}

fn resolveType(this: *Checker, node: *const ast.TypeNode) Error!*const Type {
    return switch (node.data) {
        .keyword => |keyword| switch (keyword) {
            .any => types.any,
            .unknown => types.unknown,
            .never => types.never,
            .void => types.void,
            .undefined => types.undefined,
            .null => types.null,
            .boolean => types.boolean,
            .number => types.number,
            .string => types.string,
        },
        .reference => |name| blk: {
            try this.unsupported(node.start, "The type '{s}' is not supported yet.", .{name});
            break :blk types.any;
        },
    };
}

/// tsc's `getAssignmentReducedType`: assigning to a variable whose type is a union narrows it to
/// the members the assigned value could be. Other types aren't narrowed.
fn assignmentReduced(this: *Checker, declared: *const Type, assigned: *const Type) Error!*const Type {
    if (!types.isUnion(declared)) {
        return declared;
    }
    const sources = try types.expandedMembers(this.arena, assigned);
    var kept: std.ArrayList(*const Type) = .empty;
    for (try types.expandedMembers(this.arena, declared)) |m| {
        for (sources) |source| {
            if (!types.assignable(source, m)) {
                continue;
            }
            // Keep a fresh `true` fresh, so `let c = b` still widens to `boolean`.
            const fresh = source.* == .literal and source.literal.fresh and m.* == .literal;
            try kept.append(this.arena, if (fresh) try types.freshLiteral(this.arena, m.literal.value) else m);
            break;
        }
    }
    const reduced = try types.unionOf(this.arena, kept.items);
    return if (types.assignable(assigned, reduced)) reduced else declared;
}

/// Narrows a variable's type to the members that can pass (or fail) a truthiness or nullishness
/// test, for the branch of a logical assignment that doesn't assign.
fn narrowVariable(this: *Checker, slot: u32, comptime keep: enum { truthy, falsy, non_nullish }) Error!void {
    if (!this.flow.reachable or !types.isUnion(try this.declaredType(slot))) {
        return;
    }
    const current = this.flow.vars[slot].type orelse return;
    var kept: std.ArrayList(*const Type) = .empty;
    for (try types.expandedMembers(this.arena, current)) |m| {
        const ok = switch (keep) {
            .truthy => !isFalsyLiteral(m),
            .falsy => try this.canBeFalsy(m),
            .non_nullish => m.* != .null and m.* != .undefined,
        };
        if (ok) {
            try kept.append(this.arena, m);
        }
    }
    this.flow.vars[slot].type = try types.unionOf(this.arena, kept.items);
}

// Statements

fn statement(this: *Checker, stmt: *const Stmt) Error!void {
    try this.labeledStatement(stmt, &.{});
}

/// `labels` are the labels directly on this statement, which `break` and `continue` can name.
fn labeledStatement(this: *Checker, stmt: *const Stmt, labels: []const []const u8) Error!void {
    switch (stmt.data) {
        .@"while", .do_while, .@"for" => return this.loop(stmt, labels),
        .@"switch" => |sw| return this.switchStatement(sw, labels),
        .labeled => |l| return this.labeled(stmt, l, labels),
        else => {},
    }
    if (labels.len > 0) {
        try this.targets.append(this.arena, .{ .kind = .label, .labels = labels });
    }
    switch (stmt.data) {
        .expression => |e| _ = try this.expression(e),
        .empty => {},
        .variable => |v| try this.variableStatement(v),
        .block => |statements| {
            try this.pushScope();
            defer this.popScope();
            try this.prescan(statements);
            for (statements) |s| {
                try this.statement(s);
            }
        },
        .@"if" => |i| try this.ifStatement(i),
        .@"break" => |j| try this.jump(stmt, j, .@"break"),
        .@"continue" => |j| try this.jump(stmt, j, .@"continue"),
        .@"while", .do_while, .@"for", .@"switch", .labeled => unreachable,
    }
    if (labels.len > 0) {
        const target = this.targets.pop().?;
        try this.mergeInto(&this.flow, target.breaks);
    }
}

/// The body of an `if`, a loop or a label, where a declaration needs a block around it.
fn body(this: *Checker, stmt: *const Stmt) Error!void {
    if (stmt.data != .variable) {
        return this.statement(stmt);
    }
    try this.report(stmt.start, .ts(1156), "'{t}' declarations can only be declared inside a block.", .{stmt.data.variable.kind});
    try this.pushScope();
    defer this.popScope();
    try this.prescan(&.{stmt});
    try this.statement(stmt);
}

fn variableStatement(this: *Checker, v: ast.Variable) Error!void {
    for (v.declarators) |d| {
        const slot = this.slot_base + d.binding;
        const variable_ = this.variable(slot);
        var declared: *const Type = types.any;
        var assigned: ?*const Type = null;
        if (d.init) |init| {
            variable_.resolving = d.type == null;
            const init_type = try this.expression(init);
            variable_.resolving = false;
            if (d.type) |annotation| {
                declared = try this.resolveType(annotation);
                if (!types.assignable(init_type, declared)) {
                    try this.notAssignable(d.start, init_type, declared);
                }
            } else if (variable_.circular) {
                declared = types.any;
            } else if (v.kind == .let and isNullOrUndefined(init)) {
                try this.unsupported(d.start, "A 'let' without a type annotation, initialized to 'null' or 'undefined', is not supported yet.", .{});
            } else {
                declared = if (v.kind == .let) try types.widenFresh(this.arena, init_type) else init_type;
            }
            assigned = try this.assignmentReduced(declared, init_type);
        } else {
            if (d.type) |annotation| {
                declared = try this.resolveType(annotation);
            }
            if (v.kind == .@"const") {
                try this.report(d.start, .ts(1155), "'const' declarations must be initialized.", .{});
                if (d.type == null) {
                    try this.report(d.start, .ts(7005), "Variable '{s}' implicitly has an 'any' type.", .{d.name});
                }
                assigned = declared;
            } else if (d.type == null) {
                try this.unsupported(d.start, "A 'let' without a type annotation or an initializer is not supported yet.", .{});
            }
        }
        variable_.declared = declared;
        if (this.flow.reachable) {
            this.flow.vars[slot] = .{ .initialized = true, .type = assigned };
        }
    }
}

fn isNullOrUndefined(expr: *const Expr) bool {
    const e = ast.skipParens(expr);
    return e.data == .null or (e.data == .identifier and std.mem.eql(u8, e.data.identifier.name, "undefined"));
}

fn ifStatement(this: *Checker, i: ast.If) Error!void {
    const pending = this.pending.items.len;
    const branches = try this.condition(i.condition, i.then, null);
    try this.checkTruthiness(i.condition);
    this.flow = branches.when_true;
    try this.body(i.then);
    const after_then = this.flow;
    this.flow = branches.when_false;
    if (i.otherwise) |otherwise| {
        try this.body(otherwise);
    }
    try this.mergeInto(&this.flow, after_then);
    // Now that the body's names are resolved, see whether it calls the function it tests.
    try this.checkUncalledFunction(i.condition, branches.type, .{ .stmt = i.then }, null);
    try this.flushPending(pending);
}

fn loop(this: *Checker, stmt: *const Stmt, labels: []const []const u8) Error!void {
    var scoped = false;
    if (stmt.data == .@"for") {
        if (stmt.data.@"for".init) |init| {
            try this.pushScope();
            scoped = true;
            try this.prescan(&.{init});
            try this.statement(init);
        }
    }
    defer if (scoped) this.popScope();

    // Check the loop until the state at its head stops changing, keeping only the last pass's
    // diagnostics.
    var head = try this.copyFlow(this.flow);
    while (true) {
        const mark = this.diagnostics.items().len;
        this.flow = try this.copyFlow(head);
        try this.targets.append(this.arena, .{ .kind = .loop, .labels = labels });
        var exit: Flow = .unreachable_flow;
        switch (stmt.data) {
            .@"while" => |w| {
                const branches = try this.testCondition(w.condition);
                exit = branches.when_false;
                this.flow = branches.when_true;
                try this.body(w.body);
                try this.mergeInto(&this.flow, this.targets.items[this.targets.items.len - 1].continues);
            },
            .do_while => |d| {
                try this.body(d.body);
                try this.mergeInto(&this.flow, this.targets.items[this.targets.items.len - 1].continues);
                const branches = try this.testCondition(d.condition);
                exit = branches.when_false;
                this.flow = branches.when_true;
            },
            .@"for" => |f| {
                if (f.condition) |c| {
                    const branches = try this.testCondition(c);
                    exit = branches.when_false;
                    this.flow = branches.when_true;
                }
                try this.body(f.body);
                try this.mergeInto(&this.flow, this.targets.items[this.targets.items.len - 1].continues);
                if (f.update) |u| {
                    _ = try this.expression(u);
                }
            },
            else => unreachable,
        }
        const target = this.targets.pop().?;
        var next = try this.copyFlow(head);
        try this.mergeInto(&next, this.flow);
        if (next.eql(head)) {
            try this.mergeInto(&exit, target.breaks);
            this.flow = exit;
            return;
        }
        this.diagnostics.truncate(mark);
        head = next;
    }
}

/// The condition of a loop.
fn testCondition(this: *Checker, expr: *const Expr) Error!Branches {
    const branches = try this.condition(expr, null, null);
    try this.checkTruthiness(expr);
    return branches;
}

fn jump(this: *Checker, stmt: *const Stmt, j: ast.Jump, comptime kind: enum { @"break", @"continue" }) Error!void {
    const index: ?usize = blk: {
        var i = this.targets.items.len;
        while (i > 0) {
            i -= 1;
            const target = this.targets.items[i];
            if (j.label) |label| {
                for (target.labels) |l| {
                    if (std.mem.eql(u8, l, label)) {
                        break :blk if (kind == .@"continue" and target.kind != .loop) null else i;
                    }
                }
            } else if (target.kind == .loop or (kind == .@"break" and target.kind == .@"switch")) {
                break :blk i;
            }
        }
        break :blk null;
    };
    const target = if (index) |i| &this.targets.items[i] else {
        switch (kind) {
            .@"break" => if (j.label != null)
                try this.report(stmt.start, .ts(1116), "A 'break' statement can only jump to a label of an enclosing statement.", .{})
            else
                try this.report(stmt.start, .ts(1105), "A 'break' statement can only be used within an enclosing iteration or switch statement.", .{}),
            .@"continue" => if (j.label != null)
                try this.report(stmt.start, .ts(1115), "A 'continue' statement can only jump to a label of an enclosing iteration statement.", .{})
            else
                try this.report(stmt.start, .ts(1104), "A 'continue' statement can only be used within an enclosing iteration statement.", .{}),
        }
        this.flow = .unreachable_flow;
        return;
    };
    try this.mergeInto(if (kind == .@"break") &target.breaks else &target.continues, this.flow);
    this.flow = .unreachable_flow;
}

fn labeled(this: *Checker, stmt: *const Stmt, l: ast.Labeled, labels: []const []const u8) Error!void {
    for (this.labels.items) |enclosing| {
        if (std.mem.eql(u8, enclosing, l.label)) {
            try this.report(stmt.start, .ts(1114), "Duplicate label '{s}'.", .{l.label});
            break;
        }
    }
    try this.labels.append(this.arena, l.label);
    defer _ = this.labels.pop();
    const all = try std.mem.concat(this.arena, []const u8, &.{ labels, &.{l.label} });
    if (l.body.data == .variable) {
        try this.report(stmt.start, .ts(1344), "'A label is not allowed here.", .{});
        try this.pushScope();
        defer this.popScope();
        try this.prescan(&.{l.body});
        return this.labeledStatement(l.body, all);
    }
    try this.labeledStatement(l.body, all);
}

fn switchStatement(this: *Checker, sw: ast.Switch, labels: []const []const u8) Error!void {
    const discriminant = try this.expression(sw.discriminant);
    try this.pushScope();
    defer this.popScope();
    for (sw.clauses) |clause| {
        try this.prescan(clause.statements);
    }
    const entry = try this.copyFlow(this.flow);
    try this.targets.append(this.arena, .{ .kind = .@"switch", .labels = labels });
    var fallthrough: Flow = .unreachable_flow;
    var has_default = false;
    var case_types: std.ArrayList(*const Type) = .empty;
    for (sw.clauses) |clause| {
        // A clause is entered from the switch's head, or by falling through from the one before.
        this.flow = try this.copyFlow(entry);
        try this.mergeInto(&this.flow, fallthrough);
        if (clause.case) |case| {
            const t = try this.expression(case);
            try case_types.append(this.arena, t);
            if (!types.comparable(discriminant, t)) {
                try this.report(case.start, .ts(2678), "Type '{f}' is not comparable to type '{f}'.", .{ try this.shownSource(t, discriminant), discriminant });
            }
        } else if (has_default) {
            try this.report(clause.start, .ts(1113), "A 'default' clause cannot appear more than once in a 'switch' statement.", .{});
        } else {
            has_default = true;
        }
        for (clause.statements) |s| {
            try this.statement(s);
        }
        fallthrough = this.flow;
    }
    const target = this.targets.pop().?;
    this.flow = fallthrough;
    try this.mergeInto(&this.flow, target.breaks);
    if (!has_default and !try this.exhaustive(discriminant, case_types.items)) {
        try this.mergeInto(&this.flow, entry);
    }
}

/// tsc's `isExhaustiveSwitchStatement`: the discriminant is a union of literals, and every one of
/// them has a case.
fn exhaustive(this: *Checker, discriminant: *const Type, cases: []const *const Type) Error!bool {
    if (discriminant.* == .never) {
        return false;
    }
    for (try types.expandedMembers(this.arena, discriminant)) |m| {
        if (m.* != .literal and m.* != .null and m.* != .undefined) {
            return false;
        }
        if (!hasCase(cases, m)) {
            return false;
        }
    }
    return true;
}

fn hasCase(cases: []const *const Type, value: *const Type) bool {
    for (cases) |case| {
        var buffer: [1]*const Type = undefined;
        for (case.members(&buffer)) |c| {
            if (c.eql(value)) {
                return true;
            }
        }
    }
    return false;
}

/// How tsc shows `source` in "not assignable"/"not comparable" messages: literals widened, unless
/// the target could be a literal itself.
fn shownSource(this: *Checker, source: *const Type, target: *const Type) Error!*const Type {
    return if (types.couldHaveSingletons(target)) source else types.widen(this.arena, source);
}

fn notAssignable(this: *Checker, at: u32, source: *const Type, target: *const Type) Error!void {
    // tsc leaves `null` and `undefined` out of the target when the rest of it is a single type.
    var shown = target;
    if (target.* == .@"union" and !includesNullish(source)) {
        const rest = try this.removeNullish(target);
        if (!types.isUnion(rest)) {
            shown = rest;
        }
    }
    try this.report(at, .ts(2322), "Type '{f}' is not assignable to type '{f}'.", .{ try this.shownSource(source, shown), shown });
}

fn includesNullish(t: *const Type) bool {
    var buffer: [1]*const Type = undefined;
    for (t.members(&buffer)) |m| {
        if (m.* == .null or m.* == .undefined) {
            return true;
        }
    }
    return false;
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

// Identifiers

const Resolution = struct {
    /// Null for a global, or a name that didn't resolve.
    slot: ?u32,
    /// Used before its declaration (TS2448, already reported).
    early: bool = false,
};

fn resolve(this: *Checker, expr: *const Expr, id: ast.Identifier) Error!Resolution {
    if (this.lookup(id.name)) |slot| {
        this.refs[id.ref] = .{ .slot = slot };
        const v = this.variable(slot);
        const early = v.source == this.source and expr.start < v.end;
        if (early) {
            try this.report(expr.start, .ts(2448), "Block-scoped variable '{s}' used before its declaration.", .{id.name});
        }
        return .{ .slot = slot, .early = early };
    }
    this.refs[id.ref] = .{ .global = id.name };
    if (global(id.name) == null) {
        try this.report(expr.start, .ts(2304), "Cannot find name '{s}'.", .{id.name});
    }
    return .{ .slot = null };
}

/// Whether `expr` is the builtin `name`, not a variable that shadows it.
fn isGlobal(this: *const Checker, expr: *const Expr, name: []const u8) bool {
    const e = ast.skipParens(expr);
    if (e.data != .identifier or !std.mem.eql(u8, e.data.identifier.name, name)) {
        return false;
    }
    return this.refs[e.data.identifier.ref] == .global;
}

fn read(this: *Checker, expr: *const Expr, id: ast.Identifier) Error!*const Type {
    return this.readResolved(expr, id, try this.resolve(expr, id));
}

fn readResolved(this: *Checker, expr: *const Expr, id: ast.Identifier, r: Resolution) Error!*const Type {
    const slot = r.slot orelse return global(id.name) orelse types.any;
    const declared = try this.declaredType(slot);
    if (!this.flow.reachable) {
        return declared;
    }
    const state = this.flow.vars[slot];
    if (state.type) |t| {
        return t;
    }
    if (!types.includesUndefined(declared)) {
        try this.report(expr.start, .ts(2454), "Variable '{s}' is used before being assigned.", .{id.name});
    } else if (!state.initialized and !r.early) {
        try this.unsupported(expr.start, "Reading '{s}' before its declaration has run is not supported yet.", .{id.name});
    }
    return declared;
}

/// Checks that an identifier can be assigned to, returning its slot. Null means the target is
/// already an error (or didn't resolve), and like tsc's error type it isn't checked further.
fn writeTarget(this: *Checker, expr: *const Expr, id: ast.Identifier, r: Resolution) Error!?u32 {
    const slot = r.slot orelse {
        if (std.mem.eql(u8, id.name, "undefined")) {
            try this.report(expr.start, .ts(2539), "Cannot assign to 'undefined' because it is not a variable.", .{});
        } else if (global(id.name) != null) {
            try this.unsupported(expr.start, "Assigning to the global '{s}' is not supported yet.", .{id.name});
        }
        return null;
    };
    if (this.variable(slot).kind == .@"const") {
        try this.report(expr.start, .ts(2588), "Cannot assign to '{s}' because it is a constant.", .{id.name});
        return null;
    } else if (this.flow.reachable and !this.flow.vars[slot].initialized and !r.early) {
        try this.unsupported(expr.start, "Assigning to '{s}' before its declaration has run is not supported yet.", .{id.name});
    }
    return slot;
}

// Expressions

fn expression(this: *Checker, expr: *const Expr) Error!*const Type {
    return switch (expr.data) {
        .number => |n| types.freshLiteral(this.arena, .{ .number = n }),
        .string => |s| types.freshLiteral(this.arena, .{ .string = s }),
        .template => |t| blk: {
            for (t.substitutions) |sub| {
                _ = try this.expression(sub);
            }
            // A template without substitutions has a literal type, like a string literal.
            if (t.substitutions.len == 0) {
                break :blk types.freshLiteral(this.arena, .{ .string = t.quasis[0] });
            }
            break :blk types.string;
        },
        .boolean => |b| types.freshLiteral(this.arena, .{ .boolean = b }),
        .null => types.null,
        .identifier => |id| this.read(expr, id),
        .paren => |inner| this.expression(inner),
        .unary => |u| this.unary(u),
        .update => |u| this.update(u),
        .assign => |a| this.assign(a),
        .binary => |b| if (b.op.isLogical()) blk: {
            const branches = try this.condition(expr, null, null);
            this.flow = branches.when_true;
            try this.mergeInto(&this.flow, branches.when_false);
            break :blk branches.type;
        } else this.binary(expr, b),
        .conditional => |c| this.conditional(c),
        .member => |m| this.member(m),
        .call => |c| this.call(expr, c),
    };
}

/// An expression tested for truthiness, which follows the true and false paths separately
/// through `&&`, `||`, `??` and `!` (tsc's `bindCondition`). `if_body` is the `if` statement the
/// condition belongs to, if any, and `chain` the `&&` expressions it's the left side of.
fn condition(this: *Checker, expr: *const Expr, if_body: ?*const Stmt, chain: ?*const AndChain) Error!Branches {
    switch (expr.data) {
        .paren => |inner| return this.condition(inner, if_body, null),
        .unary => |u| if (u.op == .not) {
            const branches = try this.condition(u.operand, null, null);
            try this.checkTruthiness(u.operand);
            return .{ .type = try this.negation(branches.type), .when_true = branches.when_false, .when_false = branches.when_true };
        },
        // `if (true)` never takes its `else`.
        .boolean => |b| {
            const t = try types.freshLiteral(this.arena, .{ .boolean = b });
            return if (b)
                .{ .type = t, .when_true = this.flow, .when_false = .unreachable_flow }
            else
                .{ .type = t, .when_true = .unreachable_flow, .when_false = this.flow };
        },
        .binary => |b| if (b.op.isLogical()) {
            return this.logical(b, if_body, chain);
        },
        else => {},
    }
    const t = try this.expression(expr);
    var branches: Branches = .{ .type = t, .when_true = this.flow, .when_false = try this.copyFlow(this.flow) };
    // A variable tested on its own is narrowed to the members that can pass or fail the test:
    // after `while (b) {}`, `b` is `false`. Narrowing by other tests comes later.
    if (expr.data == .identifier) {
        if (this.refs[expr.data.identifier.ref] == .slot) {
            const slot = this.refs[expr.data.identifier.ref].slot;
            this.flow = branches.when_true;
            try this.narrowVariable(slot, .truthy);
            branches.when_true = this.flow;
            this.flow = branches.when_false;
            try this.narrowVariable(slot, .falsy);
            branches.when_false = this.flow;
        }
    }
    return branches;
}

fn logical(this: *Checker, b: ast.Binary, if_body: ?*const Stmt, chain: ?*const AndChain) Error!Branches {
    const pending = this.pending.items.len;
    var link: ?*AndChain = null;
    if (b.op == .logical_and) {
        link = try this.arena.create(AndChain);
        link.?.* = .{ .right = b.right, .parent = chain };
    }
    const left = try this.condition(b.left, if_body, link);
    var result: Branches = undefined;
    switch (b.op) {
        .logical_and => {
            this.flow = left.when_true;
            const right = try this.condition(b.right, if_body, null);
            var when_false = left.when_false;
            try this.mergeInto(&when_false, right.when_false);
            result = .{ .type = right.type, .when_true = right.when_true, .when_false = when_false };
        },
        .logical_or, .nullish => {
            this.flow = left.when_false;
            const right = try this.condition(b.right, if_body, null);
            var when_true = left.when_true;
            try this.mergeInto(&when_true, right.when_true);
            result = .{ .type = right.type, .when_true = when_true, .when_false = right.when_false };
        },
        else => unreachable,
    }
    const right = result.type;
    result.type = switch (b.op) {
        .logical_and => blk: {
            try this.checkTruthiness(b.left);
            try this.pending.append(this.arena, .{
                .condition = b.left,
                .type = left.type,
                .body = if (if_body) |s| .{ .stmt = s } else .none,
                .chain = link,
            });
            if (!try this.canBeTruthy(left.type)) {
                break :blk left.type;
            }
            break :blk try types.unionOf(this.arena, &.{ try this.definitelyFalsy(left.type), right });
        },
        .logical_or => blk: {
            try this.checkTruthiness(b.left);
            if (!try this.canBeFalsy(left.type)) {
                break :blk left.type;
            }
            break :blk try types.unionOf(this.arena, &.{ try this.removeDefinitelyFalsy(left.type), right });
        },
        .nullish => blk: {
            const inner = ast.skipParens(b.left);
            switch (this.nullishSemantics(inner)) {
                .never => try this.report(inner.start, .ts(2869), "Right operand of ?? is unreachable because the left operand is never nullish.", .{}),
                .always => try this.report(inner.start, .ts(2871), "This expression is always nullish.", .{}),
                .sometimes => {},
            }
            const non_null = try this.removeNullish(left.type);
            if (non_null.eql(left.type)) {
                break :blk left.type;
            }
            break :blk try types.unionOf(this.arena, &.{ non_null, right });
        },
        else => unreachable,
    };
    // At the outermost `&&` outside an `if`, every right side its checks look at has been checked.
    if (chain == null and if_body == null) {
        try this.flushPending(pending);
    }
    return result;
}

fn conditional(this: *Checker, c: ast.Conditional) Error!*const Type {
    const branches = try this.condition(c.condition, null, null);
    try this.checkTruthiness(c.condition);
    this.flow = branches.when_true;
    const then = try this.expression(c.then);
    const after_then = this.flow;
    try this.checkUncalledFunction(c.condition, branches.type, .{ .expr = c.then }, null);
    this.flow = branches.when_false;
    const otherwise = try this.expression(c.otherwise);
    try this.mergeInto(&this.flow, after_then);
    return types.unionOf(this.arena, &.{ then, otherwise });
}

fn unary(this: *Checker, u: ast.Unary) Error!*const Type {
    const operand = try this.expression(u.operand);
    switch (u.op) {
        .not => {
            try this.checkTruthiness(u.operand);
            return this.negation(operand);
        },
        .negate, .plus, .bitwise_not => {
            _ = try this.checkNonNull(u.operand, operand);
            // `-1` is the literal type `-1`, not `number`.
            if (u.op == .negate and u.operand.data == .number) {
                return types.freshLiteral(this.arena, .{ .number = -u.operand.data.number });
            }
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

/// The type of `!x`: `false` if `x` is always truthy, `true` if it's always falsy.
fn negation(this: *Checker, operand: *const Type) Error!*const Type {
    if (!try this.canBeFalsy(operand)) {
        return types.false;
    }
    if (!try this.canBeTruthy(operand)) {
        return types.true;
    }
    return types.boolean;
}

const arithmetic_operand = "must be of type 'any', 'number', 'bigint' or an enum type.";

fn update(this: *Checker, u: ast.Update) Error!*const Type {
    const operand = ast.skipParens(u.operand);
    if (operand.data != .identifier) {
        const t = try this.checkNonNull(u.operand, try this.expression(u.operand));
        if (!isNumeric(t)) {
            try this.report(u.operand.start, .ts(2356), "An arithmetic operand " ++ arithmetic_operand, .{});
        } else if (operand.data == .member) {
            try this.unsupported(u.operand.start, "Assigning to properties is not supported yet.", .{});
        } else {
            try this.report(u.operand.start, .ts(2357), "The operand of an increment or decrement operator must be a variable or a property access.", .{});
        }
        return types.number;
    }
    const id = operand.data.identifier;
    const r = try this.resolve(operand, id);
    const slot = try this.writeTarget(operand, id, r) orelse return types.number;
    const t = try this.checkNonNull(u.operand, try this.readResolved(operand, id, r));
    if (!isNumeric(t)) {
        try this.report(u.operand.start, .ts(2356), "An arithmetic operand " ++ arithmetic_operand, .{});
    }
    this.setVariable(slot, try this.assignmentReduced(try this.declaredType(slot), types.number));
    return types.number;
}

fn assign(this: *Checker, a: ast.Assign) Error!*const Type {
    const target = ast.skipParens(a.target);
    if (target.data != .identifier) {
        _ = try this.expression(a.target);
        const value = try this.expression(a.value);
        if (target.data == .member) {
            try this.unsupported(a.target.start, "Assigning to properties is not supported yet.", .{});
        } else {
            try this.report(a.target.start, .ts(2364), "The left-hand side of an assignment expression must be a variable or a property access.", .{});
        }
        return value;
    }
    const id = target.data.identifier;
    const r = try this.resolve(target, id);
    const slot = try this.writeTarget(target, id, r) orelse {
        _ = try this.expression(a.value);
        return types.any;
    };

    const op = a.op orelse {
        const value = try this.expression(a.value);
        const declared = try this.declaredType(slot);
        if (!types.assignable(value, declared)) {
            try this.notAssignable(a.target.start, value, declared);
        }
        this.setVariable(slot, try this.assignmentReduced(declared, value));
        return value;
    };

    if (op.isLogical()) {
        // Reading the variable here isn't checked for definite assignment, as in tsc.
        const narrowed = if (this.flow.reachable) this.flow.vars[slot].type else null;
        const current = narrowed orelse try this.declaredType(slot);
        const left = try types.widen(this.arena, current);
        // The path where the value isn't assigned.
        var skipped = try this.copyFlow(this.flow);
        std.mem.swap(Flow, &this.flow, &skipped);
        switch (op) {
            .logical_and => try this.narrowVariable(slot, .falsy),
            .logical_or => try this.narrowVariable(slot, .truthy),
            else => try this.narrowVariable(slot, .non_nullish),
        }
        std.mem.swap(Flow, &this.flow, &skipped);
        const value = try this.expression(a.value);
        if (!types.assignable(value, left)) {
            try this.notAssignable(a.target.start, value, left);
        }
        this.setVariable(slot, try this.assignmentReduced(try this.declaredType(slot), value));
        try this.mergeInto(&this.flow, skipped);
        return switch (op) {
            .logical_and => if (!try this.canBeTruthy(current)) current else types.unionOf(this.arena, &.{ try this.definitelyFalsy(current), value }),
            .logical_or => if (!try this.canBeFalsy(current)) current else types.unionOf(this.arena, &.{ try this.removeDefinitelyFalsy(current), value }),
            else => types.unionOf(this.arena, &.{ try this.removeNullish(current), value }),
        };
    }

    const left = try types.widen(this.arena, try this.readResolved(target, id, r));
    const value = try this.expression(a.value);
    const result = try this.operator(op, a.target, a.value, left, value, true);
    if (result.ok and !types.assignable(result.type, left)) {
        try this.notAssignable(a.target.start, result.type, left);
    }
    this.setVariable(slot, try this.assignmentReduced(try this.declaredType(slot), result.type));
    return result.type;
}

fn binary(this: *Checker, expr: *const Expr, b: ast.Binary) Error!*const Type {
    const left = try this.expression(b.left);
    if (b.op == .comma and this.indirect_call != expr and isSideEffectFree(b.left)) {
        try this.report(b.left.start, .ts(2695), "Left side of comma operator is unused and has no side effects.", .{});
    }
    const right = try this.expression(b.right);
    return (try this.operator(b.op, b.left, b.right, left, right, false)).type;
}

const Operation = struct {
    type: *const Type,
    /// The operands were valid; when not, an error has been reported.
    ok: bool = true,
};

/// The checks and result type of a binary operator, also used for compound assignments
/// (`compound` adds the `=` to the operator in messages).
fn operator(this: *Checker, op: ast.BinaryOp, left_expr: *const Expr, right_expr: *const Expr, left: *const Type, right: *const Type, compound: bool) Error!Operation {
    switch (op) {
        .comma => return .{ .type = right },
        .add => {
            var l = left;
            var r = right;
            if (!types.isStringLike(left) and !types.isStringLike(right)) {
                l = try this.checkNonNull(left_expr, left);
                r = try this.checkNonNull(right_expr, right);
            }
            if (isAny(l) and isAny(r)) {
                return .{ .type = types.any };
            }
            if (types.isNumberLike(l) and types.isNumberLike(r)) {
                return .{ .type = types.number };
            }
            if (types.isStringLike(l) or types.isStringLike(r)) {
                return .{ .type = types.string };
            }
            if (isAny(l) or isAny(r)) {
                return .{ .type = types.any };
            }
            try this.operatorError(op, compound, left_expr, l, r);
            return .{ .type = types.any, .ok = false };
        },
        .less, .greater, .less_equal, .greater_equal => {
            const l = try types.widen(this.arena, try this.checkNonNull(left_expr, left));
            const r = try types.widen(this.arena, try this.checkNonNull(right_expr, right));
            const ok = isAny(l) or isAny(r) or
                (types.isNumberLike(l) and types.isNumberLike(r)) or
                types.comparable(l, r);
            if (!ok) {
                try this.operatorError(op, compound, left_expr, l, r);
            }
            return .{ .type = types.boolean, .ok = ok };
        },
        .equal, .not_equal, .strict_equal, .strict_not_equal => {
            for ([_]*const Expr{ left_expr, right_expr }) |operand| {
                if (this.isGlobal(operand, "NaN")) {
                    const always = if (op == .equal or op == .strict_equal) "false" else "true";
                    try this.report(left_expr.start, .ts(2845), "This condition will always return '{s}'.", .{always});
                    return .{ .type = types.boolean };
                }
            }
            if (!types.comparable(left, right)) {
                // tsc names the widened types when those don't overlap either.
                const wl = try types.widen(this.arena, left);
                const wr = try types.widen(this.arena, right);
                const show_widened = !types.comparable(wl, wr);
                try this.report(left_expr.start, .ts(2367), "This comparison appears to be unintentional because the types '{f}' and '{f}' have no overlap.", .{
                    if (show_widened) wl else left,
                    if (show_widened) wr else right,
                });
            }
            return .{ .type = types.boolean };
        },
        else => {
            std.debug.assert(op.isArithmetic());
            const l = try this.checkNonNull(left_expr, left);
            const r = try this.checkNonNull(right_expr, right);
            var ok = true;
            if (!isNumeric(l)) {
                try this.report(left_expr.start, .ts(2362), "The left-hand side of an arithmetic operation " ++ arithmetic_operand, .{});
                ok = false;
            }
            if (!isNumeric(r)) {
                try this.report(right_expr.start, .ts(2363), "The right-hand side of an arithmetic operation " ++ arithmetic_operand, .{});
                ok = false;
            }
            return .{ .type = types.number, .ok = ok };
        },
    }
}

fn operatorError(this: *Checker, op: ast.BinaryOp, compound: bool, left_expr: *const Expr, left: *const Type, right: *const Type) Error!void {
    try this.report(left_expr.start, .ts(2365), "Operator '{s}{s}' cannot be applied to types '{f}' and '{f}'.", .{
        op.lexeme(),
        if (compound) "=" else "",
        try types.widen(this.arena, left),
        try types.widen(this.arena, right),
    });
}

/// tsc's `isSideEffectFree`, for the left side of a comma (TS2695).
fn isSideEffectFree(expr: *const Expr) bool {
    const e = ast.skipParens(expr);
    return switch (e.data) {
        .identifier, .string, .template, .number, .boolean, .null => true,
        .unary => |u| u.op != .void,
        .conditional => |c| isSideEffectFree(c.then) and isSideEffectFree(c.otherwise),
        .binary => |b| isSideEffectFree(b.left) and isSideEffectFree(b.right),
        else => false,
    };
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
                    try this.unsupported(m.property_start, "Properties of functions are not supported yet.", .{});
                    return types.any;
                }
            }
            try this.report(m.property_start, .ts(2339), "Property '{s}' does not exist on type '{f}'.", .{ m.property, object });
            return types.any;
        },
        .never => return types.never,
        else => {
            try this.unsupported(m.property_start, "Properties of '{f}' are not supported yet.", .{try types.widen(this.arena, object)});
            return types.any;
        },
    }
}

fn call(this: *Checker, expr: *const Expr, c: ast.Call) Error!*const Type {
    // `(0, a.b)()` calls `a.b` without `a` as `this`; the `0` isn't a mistake.
    if (c.callee.data == .paren) {
        const inner = c.callee.data.paren;
        if (inner.data == .binary and inner.data.binary.op == .comma) {
            const b = inner.data.binary;
            if (b.left.data == .number and b.left.data.number == 0 and b.right.data == .member) {
                this.indirect_call = inner;
            }
        }
    }
    const callee = try this.checkNonNull(c.callee, try this.expression(c.callee));
    var args: std.ArrayList(*const Type) = .empty;
    for (c.arguments) |arg| {
        try args.append(this.arena, try this.expression(arg));
    }

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
                if (!types.assignable(arg_type, param)) {
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

// Null, undefined and unknown

/// tsc's `checkNonNullType`: a value that could be `null` or `undefined`, or is `unknown`, can't
/// be used as an operand, called, or have its properties read. Returns the type with `null` and
/// `undefined` removed.
fn checkNonNull(this: *Checker, expr: *const Expr, t: *const Type) Error!*const Type {
    if (t.* == .unknown) {
        if (try this.entityName(expr)) |name| {
            try this.report(expr.start, .ts(18046), "'{s}' is of type 'unknown'.", .{name});
        } else {
            try this.report(expr.start, .ts(2571), "Object is of type 'unknown'.", .{});
        }
        return types.any;
    }
    var has_null = false;
    var has_undefined = false;
    var buffer: [1]*const Type = undefined;
    for (t.members(&buffer)) |m| {
        switch (m.*) {
            .null => has_null = true,
            .undefined => has_undefined = true,
            else => {},
        }
    }
    if (!has_null and !has_undefined) {
        return t;
    }
    const inner = ast.skipParens(expr);
    if (inner.data == .null or this.isGlobal(expr, "undefined")) {
        try this.report(expr.start, .ts(18050), "The value '{s}' cannot be used here.", .{if (inner.data == .null) "null" else "undefined"});
        // Like tsc's error type: the problem is reported, so nothing downstream complains again.
        return types.any;
    }
    if (try this.entityName(expr)) |name| {
        if (has_null and has_undefined) {
            try this.report(expr.start, .ts(18049), "'{s}' is possibly 'null' or 'undefined'.", .{name});
        } else if (has_null) {
            try this.report(expr.start, .ts(18047), "'{s}' is possibly 'null'.", .{name});
        } else {
            try this.report(expr.start, .ts(18048), "'{s}' is possibly 'undefined'.", .{name});
        }
    } else if (has_null and has_undefined) {
        try this.report(expr.start, .ts(2533), "Object is possibly 'null' or 'undefined'.", .{});
    } else if (has_null) {
        try this.report(expr.start, .ts(2531), "Object is possibly 'null'.", .{});
    } else {
        try this.report(expr.start, .ts(2532), "Object is possibly 'undefined'.", .{});
    }
    const rest = try this.removeNullish(t);
    return if (rest.* == .never) types.any else rest;
}

/// The text of an identifier or a chain of property accesses on one, like `console.log`, which
/// tsc puts in some messages instead of "Object".
fn entityName(this: *Checker, expr: *const Expr) Error!?[]const u8 {
    return switch (expr.data) {
        .identifier => |id| id.name,
        .member => |m| if (try this.entityName(m.object)) |object|
            try std.fmt.allocPrint(this.arena, "{s}.{s}", .{ object, m.property })
        else
            null,
        else => null,
    };
}

fn removeNullish(this: *Checker, t: *const Type) Error!*const Type {
    var kept: std.ArrayList(*const Type) = .empty;
    var buffer: [1]*const Type = undefined;
    for (t.members(&buffer)) |m| {
        if (m.* != .null and m.* != .undefined) {
            try kept.append(this.arena, m);
        }
    }
    return types.unionOf(this.arena, kept.items);
}

// Truthiness

const Semantics = enum { always, never, sometimes };

/// tsc's syntactic truthiness check (TS2872/TS2873): conditions that are literals or other
/// expressions whose truthiness is known from their syntax alone.
fn checkTruthiness(this: *Checker, expr: *const Expr) Error!void {
    switch (this.truthySemantics(expr)) {
        .always => try this.report(expr.start, .ts(2872), "This kind of expression is always truthy.", .{}),
        .never => try this.report(expr.start, .ts(2873), "This kind of expression is always falsy.", .{}),
        .sometimes => {},
    }
}

fn truthySemantics(this: *const Checker, expr: *const Expr) Semantics {
    const e = ast.skipParens(expr);
    return switch (e.data) {
        // `while (0)` and `while (1)` are allowed idioms.
        .number => |n| if (n == 0 or n == 1) .sometimes else .always,
        .string => |s| if (s.len == 0) .never else .always,
        .template => |t| if (t.substitutions.len > 0) .sometimes else if (t.quasis[0].len == 0) .never else .always,
        .null => .never,
        .unary => |u| if (u.op == .void) .never else .sometimes,
        .identifier => if (this.isGlobal(e, "undefined")) .never else .sometimes,
        .conditional => |c| combine(this.truthySemantics(c.then), this.truthySemantics(c.otherwise)),
        else => .sometimes,
    };
}

/// tsc's syntactic nullishness check for the left side of `??` (TS2869/TS2871).
fn nullishSemantics(this: *const Checker, expr: *const Expr) Semantics {
    const e = ast.skipParens(expr);
    return switch (e.data) {
        .null => .always,
        .identifier => if (this.isGlobal(e, "undefined")) .always else .sometimes,
        .member, .call => .sometimes,
        .binary => |b| switch (b.op) {
            .nullish, .logical_or, .logical_and => .sometimes,
            .comma => this.nullishSemantics(b.right),
            else => .never,
        },
        .assign => |a| if (a.op == null or a.op.?.isLogical()) .sometimes else .never,
        .conditional => |c| combine(this.nullishSemantics(c.then), this.nullishSemantics(c.otherwise)),
        else => .never,
    };
}

fn combine(a: Semantics, b: Semantics) Semantics {
    return if (a == b) a else .sometimes;
}

fn isFalsyLiteral(t: *const Type) bool {
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

fn canBeFalsy(this: *Checker, t: *const Type) Error!bool {
    var buffer: [1]*const Type = undefined;
    for (t.members(&buffer)) |m| {
        switch (m.*) {
            .literal => if (isFalsyLiteral(m)) return true,
            .object, .function, .never => {},
            else => return true,
        }
    }
    _ = this;
    return false;
}

fn canBeTruthy(this: *Checker, t: *const Type) Error!bool {
    var buffer: [1]*const Type = undefined;
    for (t.members(&buffer)) |m| {
        if (!isFalsyLiteral(m) and m.* != .never) {
            return true;
        }
    }
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
        if (part) |p| {
            try falsy.append(this.arena, p);
        }
    }
    return types.unionOf(this.arena, falsy.items);
}

fn removeDefinitelyFalsy(this: *Checker, t: *const Type) Error!*const Type {
    var kept: std.ArrayList(*const Type) = .empty;
    var buffer: [1]*const Type = undefined;
    for (t.members(&buffer)) |m| {
        if (isFalsyLiteral(m)) {
            continue;
        }
        try kept.append(this.arena, if (m.* == .boolean) types.true else m);
    }
    return types.unionOf(this.arena, kept.items);
}

// Uncalled functions

fn flushPending(this: *Checker, from: usize) Error!void {
    var i = from;
    while (i < this.pending.items.len) : (i += 1) {
        const p = this.pending.items[i];
        try this.checkUncalledFunction(p.condition, p.type, p.body, p.chain);
    }
    this.pending.shrinkRetainingCapacity(from);
}

/// tsc's `checkTestingKnownTruthyCallableOrAwaitableOrEnumMemberType` (TS2774): testing a
/// function for truthiness, as in `if (console.log)`, is almost always a missing call, unless
/// the body (or the rest of the `&&` chain) uses it.
fn checkUncalledFunction(this: *Checker, cond: *const Expr, cond_type: *const Type, b: Body, chain: ?*const AndChain) Error!void {
    var c = ast.skipParens(cond);
    try this.uncalledHelper(c, cond_type, b, chain);
    while (c.data == .binary and (c.data.binary.op == .logical_or or c.data.binary.op == .nullish)) {
        c = ast.skipParens(c.data.binary.left);
        try this.uncalledHelper(c, cond_type, b, null);
    }
}

fn uncalledHelper(this: *Checker, cond: *const Expr, cond_type: *const Type, b: Body, chain: ?*const AndChain) Error!void {
    const is_logical = cond.data == .binary and cond.data.binary.op.isLogical();
    const location = if (is_logical) ast.skipParens(cond.data.binary.right) else cond;
    if (location.data == .binary and location.data.binary.op.isLogical()) {
        return this.checkUncalledFunction(location, cond_type, b, null);
    }
    if (location.data != .identifier and location.data != .member) {
        return;
    }
    const t = if (location == cond) cond_type else try this.typeOf(location);
    if (t.* != .function) {
        return;
    }
    var link = chain;
    while (link) |l| : (link = l.parent) {
        if (this.uses(l.right, location)) {
            return;
        }
    }
    const used = switch (b) {
        .none => false,
        .stmt => |s| this.usesInStatement(s, location),
        .expr => |e| this.uses(e, location),
    };
    if (!used) {
        try this.report(location.start, .ts(2774), "This condition will always return true since this function is always defined. Did you mean to call it instead?", .{});
    }
}

/// An expression's type, checked again without reporting anything or changing the flow.
fn typeOf(this: *Checker, expr: *const Expr) Error!*const Type {
    this.muted += 1;
    defer this.muted -= 1;
    const saved = this.flow;
    defer this.flow = saved;
    this.flow = try this.copyFlow(saved);
    return this.expression(expr);
}

/// Whether two expressions name the same thing: the same variable, or the same property of the
/// same thing.
fn sameReference(this: *const Checker, a: *const Expr, b: *const Expr) bool {
    const x = ast.skipParens(a);
    const y = ast.skipParens(b);
    return switch (x.data) {
        .identifier => |id| y.data == .identifier and this.refs[id.ref].eql(this.refs[y.data.identifier.ref]),
        .member => |m| y.data == .member and std.mem.eql(u8, m.property, y.data.member.property) and this.sameReference(m.object, y.data.member.object),
        .call => |c| y.data == .call and this.sameReference(c.callee, y.data.call.callee),
        else => false,
    };
}

fn uses(this: *const Checker, expr: *const Expr, target: *const Expr) bool {
    if (this.sameReference(expr, target)) {
        return true;
    }
    return switch (expr.data) {
        .number, .string, .boolean, .null, .identifier => false,
        .template => |t| for (t.substitutions) |s| {
            if (this.uses(s, target)) {
                break true;
            }
        } else false,
        .paren => |inner| this.uses(inner, target),
        .unary => |u| this.uses(u.operand, target),
        .update => |u| this.uses(u.operand, target),
        .assign => |a| this.uses(a.target, target) or this.uses(a.value, target),
        .binary => |b| this.uses(b.left, target) or this.uses(b.right, target),
        .conditional => |c| this.uses(c.condition, target) or this.uses(c.then, target) or this.uses(c.otherwise, target),
        .member => |m| this.uses(m.object, target),
        .call => |c| this.uses(c.callee, target) or for (c.arguments) |arg| {
            if (this.uses(arg, target)) {
                break true;
            }
        } else false,
    };
}

fn usesInStatement(this: *const Checker, stmt: *const Stmt, target: *const Expr) bool {
    return switch (stmt.data) {
        .expression => |e| this.uses(e, target),
        .empty, .@"break", .@"continue" => false,
        .variable => |v| for (v.declarators) |d| {
            if (d.init) |init| {
                if (this.uses(init, target)) {
                    break true;
                }
            }
        } else false,
        .block => |statements| this.usesInStatements(statements, target),
        .@"if" => |i| this.uses(i.condition, target) or this.usesInStatement(i.then, target) or
            (if (i.otherwise) |o| this.usesInStatement(o, target) else false),
        .@"while", .do_while => |l| this.uses(l.condition, target) or this.usesInStatement(l.body, target),
        .@"for" => |f| (if (f.init) |s| this.usesInStatement(s, target) else false) or
            (if (f.condition) |c| this.uses(c, target) else false) or
            (if (f.update) |u| this.uses(u, target) else false) or
            this.usesInStatement(f.body, target),
        .labeled => |l| this.usesInStatement(l.body, target),
        .@"switch" => |sw| this.uses(sw.discriminant, target) or for (sw.clauses) |clause| {
            if (clause.case) |c| {
                if (this.uses(c, target)) {
                    break true;
                }
            }
            if (this.usesInStatements(clause.statements, target)) {
                break true;
            }
        } else false,
    };
}

fn usesInStatements(this: *const Checker, statements: []const *const Stmt, target: *const Expr) bool {
    for (statements) |s| {
        if (this.usesInStatement(s, target)) {
            return true;
        }
    }
    return false;
}
