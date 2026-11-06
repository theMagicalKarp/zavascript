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
//! Functions are checked where they appear. A function declaration that's used before that (it's
//! hoisted) has its return type inferred early, without reporting anything, and its body is still
//! checked for real where it's declared. Inside a function, a variable of an enclosing one is
//! narrowed the way tsc 5.4 does it: by what was known where the closure was created, if nothing
//! assigns the variable after that.
//!
//! It also resolves every identifier, and lays out where each variable lives at runtime: a slot
//! that outlives the program for top-level variables, the call's frame for a function's own
//! variables, or an environment for variables a closure captures. The interpreter reads this from
//! `Resolved` instead of looking names up again.

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
/// The scope of each `scope` index in the program, created when it's first entered.
scopes: []?*Scope,
/// The scope each identifier reference was resolved from, for counting environments.
ref_scopes: []?*Scope,
/// Which of the program's bindings a closure captures, so they need an environment.
captured: []bool,
/// What's known about each of the program's functions.
functions: []FunctionInfo,
/// The function being checked, or null at the top level.
context: ?*Context = null,
/// Functions whose return types are being inferred, innermost last, for TS7023.
inferring: std.ArrayList(u32) = .empty,
/// The variable whose initializer is being checked, so a function expression there can be
/// referred to by it before its return type is known.
initializer: ?Initializer = null,
/// The parameter whose default value is being checked, for TS2373.
parameter: ?[]const u8 = null,
/// Statements in the program, for finding a variable's last assignment.
program: []const *const Stmt,
/// While above zero, diagnostics are dropped; for checking an expression a second time.
muted: u32 = 0,
/// Variables whose types are being worked out early, for a use before their declaration; each
/// was reached from the one before it.
lazy: std.ArrayList(u32) = .empty,
/// The comma expression in `(0, a.b)()`, which isn't reported as unused (TS2695).
indirect_call: ?*const Expr = null,

const Error = error{OutOfMemory};

/// What an identifier refers to, and where a declaration stores its value.
pub const Ref = union(enum) {
    /// A builtin, looked up by name. Also used for names that didn't resolve, since such a program
    /// never runs.
    global: []const u8,
    /// A top-level variable's index in the interpreter's slots, which outlive the program. While
    /// checking, every variable is referred to this way, by its index in `Session.variables`.
    slot: u32,
    /// A variable of the running function that no closure captures: its index in the call's frame.
    local: u32,
    /// A variable that a closure captures, which lives in the environment of its scope.
    env: Env,

    pub const Env = struct {
        /// How many environments up the chain from the current one.
        hops: u32,
        index: u32,
    };

    fn eql(a: Ref, b: Ref) bool {
        return switch (a) {
            .global => |name| b == .global and std.mem.eql(u8, name, b.global),
            .slot => |slot| b == .slot and slot == b.slot,
            .local => |i| b == .local and i == b.local,
            .env => |e| b == .env and e.hops == b.env.hops and e.index == b.env.index,
        };
    }
};

/// What the interpreter needs from the checker.
pub const Resolved = struct {
    /// Indexed by `Identifier.ref`.
    refs: []const Ref,
    /// Where each binding's declaration stores its value, indexed by `binding`. An `env` here is
    /// always in the scope's own environment (`hops` is 0).
    bindings: []const Ref,
    /// How many variables each scope's environment holds, indexed by `scope`. A scope with none
    /// doesn't get an environment.
    environments: []const u32,
    /// How many local variables each function's frame holds, indexed by function `id`.
    frames: []const u32,
    slot_base: u32,
    /// `slot_base` plus the program's bindings.
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
    kind: Kind,
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
    /// A duplicate declaration has been reported here.
    redeclared: bool = false,
    /// The function whose body or parameters declare it; null at the top level.
    owner: ?u32 = null,
    /// The scope it's declared in; null for the program's top level.
    scope: ?*Scope = null,
    /// For a function's name, the function.
    function: ?*const ast.Function = null,
    /// Where the last assignment to it is (see `lastAssignment`), once worked out.
    last_assignment: ?LastAssignment = null,

    const Kind = enum {
        let,
        @"const",
        /// A function declaration, or a function expression's own name.
        function,
        parameter,
    };
};

const LastAssignment = union(enum) {
    never,
    at: u32,
    /// Assigned inside a nested function, which could run at any time.
    anywhere,
};

const Scope = struct {
    parent: ?*Scope,
    names: std.StringHashMapUnmanaged(u32) = .empty,
    kind: enum { block, parameters },
    /// The function this scope is part of; null at the top level.
    function: ?u32,
    /// After checking: how many captured variables live in this scope's environment.
    environment: u32 = 0,
};

/// A function being checked.
const Context = struct {
    function: *const ast.Function,
    parent: ?*Context,
    signature: *types.Function,
    /// For a function expression, the flow where it's created; what's narrowed there can still be
    /// narrowed inside.
    creation: ?Flow,
    /// The return type annotation's type.
    declared_return: ?*const Type,
    /// The return type the function's context expects, when it doesn't declare one.
    contextual_return: ?*const Type,
    /// The types of its `return` statements' values.
    returns: std.ArrayList(*const Type) = .empty,
    /// It has a `return;` without a value.
    empty_return: bool = false,
};

const FunctionInfo = struct {
    /// The function's type: in progress (`pending`) while its body is being checked, then final.
    /// A declaration keeps the first one it gets.
    type: ?*const Type = null,
    /// A call needed its return type while that was being inferred (TS7023).
    circular: bool = false,
};

const Initializer = struct {
    slot: u32,
    expr: *const Expr,
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
    try session.variables.appendNTimes(arena, .{ .name = "", .kind = .let, .start = 0, .end = 0, .source = source, .annotation = null, .init = null }, program.binding_count);
    const vars = try arena.alloc(VarFlow, slot_count);
    @memcpy(vars[0..session.flow.len], session.flow);
    @memset(vars[session.flow.len..], .{});

    const refs = try arena.alloc(Ref, program.reference_count);
    @memset(refs, .{ .global = "" });
    const ref_scopes = try arena.alloc(?*Scope, program.reference_count);
    @memset(ref_scopes, null);
    const scopes = try arena.alloc(?*Scope, program.scope_count);
    @memset(scopes, null);
    const captured = try arena.alloc(bool, program.binding_count);
    @memset(captured, false);
    const functions = try arena.alloc(FunctionInfo, program.function_count);
    @memset(functions, .{});

    var checker: Checker = .{
        .arena = arena,
        .source = source,
        .diagnostics = diagnostics,
        .session = session,
        .refs = refs,
        .slot_base = slot_base,
        .flow = .{ .reachable = true, .vars = vars },
        .scopes = scopes,
        .ref_scopes = ref_scopes,
        .captured = captured,
        .functions = functions,
        .program = program.statements,
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
    if (diagnostics.items().len > errors_before) {
        // It won't run.
        return .{ .refs = refs, .bindings = &.{}, .environments = &.{}, .frames = &.{}, .slot_base = slot_base, .slot_count = slot_count };
    }
    return checker.layout(program);
}

/// Decides where each variable lives at runtime, and how each reference reaches it.
fn layout(this: *Checker, program: ast.Program) Error!Resolved {
    const bindings = try this.arena.alloc(Ref, program.binding_count);
    const frames = try this.arena.alloc(u32, program.function_count);
    @memset(frames, 0);
    for (bindings, 0..) |*binding, i| {
        const slot = this.slot_base + @as(u32, @intCast(i));
        const v = this.variable(slot);
        binding.* = if (v.scope == null)
            .{ .slot = slot }
        else if (this.captured[i]) blk: {
            v.scope.?.environment += 1;
            break :blk .{ .env = .{ .hops = 0, .index = v.scope.?.environment - 1 } };
        } else if (v.owner) |owner| blk: {
            frames[owner] += 1;
            break :blk .{ .local = frames[owner] - 1 };
        } else .{ .slot = slot };
    }
    const environments = try this.arena.alloc(u32, program.scope_count);
    for (environments, this.scopes) |*size, scope| {
        size.* = if (scope) |s| s.environment else 0;
    }
    for (this.refs, this.ref_scopes) |*ref, from| {
        if (ref.* != .slot or ref.slot < this.slot_base) {
            continue;
        }
        const target = this.variable(ref.slot).scope;
        ref.* = bindings[ref.slot - this.slot_base];
        if (ref.* == .env) {
            var hops: u32 = 0;
            var s = from;
            while (s != target) : (s = s.?.parent) {
                if (s.?.environment > 0) {
                    hops += 1;
                }
            }
            ref.env.hops = hops;
        }
    }
    return .{
        .refs = this.refs,
        .bindings = bindings,
        .environments = environments,
        .frames = frames,
        .slot_base = this.slot_base,
        .slot_count = @intCast(this.session.variables.items.len),
    };
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

/// Enters the scope with index `id` (or an unnumbered one, for code that won't run), whose
/// parent is the current scope.
fn pushScope(this: *Checker, id: ?u32, kind: @FieldType(Scope, "kind")) Error!void {
    var names: std.StringHashMapUnmanaged(u32) = .empty;
    const scope = blk: {
        if (id) |i| {
            if (this.scopes[i]) |existing| {
                // A scope is entered again on each pass over a loop, and each time a function is
                // checked; its names start over.
                names = existing.names;
                names.clearRetainingCapacity();
                break :blk existing;
            }
            this.scopes[i] = try this.arena.create(Scope);
            break :blk this.scopes[i].?;
        }
        break :blk try this.arena.create(Scope);
    };
    scope.* = .{ .parent = this.scope, .names = names, .kind = kind, .function = this.currentFunction() };
    this.scope = scope;
}

fn popScope(this: *Checker) void {
    this.scope = this.scope.?.parent;
}

/// Declares a statement list's `let`, `const` and function declarations up front, so a use
/// before a variable's declaration finds it and reports TS2448 rather than an unknown name, and
/// a function can be called before its declaration.
fn prescan(this: *Checker, statements: []const *const Stmt) Error!void {
    for (statements) |stmt| {
        var s = stmt;
        while (s.data == .labeled) {
            s = s.data.labeled.body;
        }
        switch (s.data) {
            .variable => |v| for (v.declarators) |d| {
                try this.declare(this.slot_base + d.binding, .{
                    .name = d.name,
                    .kind = if (v.kind == .let) .let else .@"const",
                    .start = d.start,
                    .end = d.end,
                    .source = this.source,
                    .annotation = d.type,
                    .init = d.init,
                });
            },
            .function => |f| {
                const name = f.name.?;
                try this.declare(this.slot_base + name.binding, .{
                    .name = name.text,
                    .kind = .function,
                    .start = name.start,
                    .end = name.start,
                    .source = this.source,
                    .annotation = null,
                    .init = null,
                    .function = f,
                });
            },
            else => {},
        }
    }
}

/// Adds a name to the current scope, reporting it if the scope already has it.
fn declare(this: *Checker, slot: u32, v: Variable) Error!void {
    var declared = v;
    declared.owner = this.currentFunction();
    declared.scope = this.scope;
    this.session.variables.items[slot] = declared;
    if (this.flow.reachable) {
        // A function declaration can be used anywhere in its scope.
        this.flow.vars[slot] = .{ .initialized = v.kind == .function };
    }
    const names = if (this.scope) |scope| &scope.names else &this.session.top_level;
    // A function body's top level can't redeclare a parameter either.
    var existing = names.get(v.name);
    if (existing == null) {
        if (this.scope) |scope| {
            if (scope.kind == .block and scope.parent != null and scope.parent.?.kind == .parameters) {
                existing = scope.parent.?.names.get(v.name);
            }
        }
    }
    const first_slot = existing orelse {
        try names.put(this.arena, v.name, slot);
        if (this.scope == null) {
            try this.added.append(this.arena, v.name);
        }
        return;
    };
    const first = this.variable(first_slot);
    const Conflict = enum { block_scoped, functions, other };
    const conflict: Conflict = if (isBlockScoped(first.kind) and isBlockScoped(v.kind))
        .block_scoped
    else if (first.kind == .function and v.kind == .function)
        .functions
    else
        .other;
    const sites = [_]struct { *Variable, bool }{
        .{ first, first.source == this.source and !first.redeclared },
        .{ this.variable(slot), true },
    };
    for (sites) |site| {
        if (!site[1]) {
            continue;
        }
        site[0].redeclared = true;
        switch (conflict) {
            .block_scoped => try this.report(site[0].start, .ts(2451), "Cannot redeclare block-scoped variable '{s}'.", .{v.name}),
            .functions => try this.report(site[0].start, .ts(2393), "Duplicate function implementation.", .{}),
            .other => try this.report(site[0].start, .ts(2300), "Duplicate identifier '{s}'.", .{v.name}),
        }
    }
}

fn isBlockScoped(kind: Variable.Kind) bool {
    return kind == .let or kind == .@"const";
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
    if (v.kind == .function) {
        // A function declaration used before it's checked: work out its type now.
        const f = v.function.?;
        return this.functions[f.id].type orelse this.checkFunction(f, null, .infer);
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
    return if (v.kind == .@"const") t else types.widenFresh(this.arena, t);
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
        .array => |element| blk: {
            const t = try this.arena.create(Type);
            t.* = .{ .array = try this.resolveType(element) };
            break :blk t;
        },
        .function => |f| blk: {
            var parameters: std.ArrayList(types.Parameter) = .empty;
            var rest: ?types.Parameter = null;
            for (f.parameters) |p| {
                var t = types.any;
                if (p.type) |annotation| {
                    t = try this.resolveType(annotation);
                    if (p.rest and t.* != .array and t.* != .any) {
                        try this.report(annotation.start, .ts(2370), "A rest parameter must be of an array type.", .{});
                    }
                } else {
                    try this.report(p.start, .ts(7006), "Parameter '{s}' implicitly has an 'any' type.", .{p.name});
                    if (p.rest) {
                        t = types.any_array;
                    }
                }
                if (p.rest) {
                    rest = .{ .name = p.name, .type = t };
                } else {
                    if (p.optional) {
                        t = try types.unionOf(this.arena, &.{ t, types.undefined });
                    }
                    try parameters.append(this.arena, .{ .name = p.name, .type = t, .optional = p.optional });
                }
            }
            const function = try this.arena.create(types.Function);
            function.* = .{ .parameters = parameters.items, .rest = rest, .returns = try this.resolveType(f.returns) };
            const t = try this.arena.create(Type);
            t.* = .{ .function = function };
            break :blk t;
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
fn narrowVariable(this: *Checker, slot: u32, at: u32, comptime keep: enum { truthy, falsy, non_nullish }) Error!void {
    if (!this.flow.reachable or !types.isUnion(try this.declaredType(slot))) {
        return;
    }
    const current = this.flow.vars[slot].type orelse if (this.isOuter(slot)) blk: {
        this.muted += 1;
        defer this.muted -= 1;
        break :blk try this.outerType(slot, at, try this.declaredType(slot));
    } else return;
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
        .function => |f| _ = try this.checkFunction(f, null, .check),
        .@"return" => |value| try this.returnStatement(stmt, value),
        .block => |b| {
            try this.pushScope(b.scope, .block);
            defer this.popScope();
            try this.prescan(b.statements);
            for (b.statements) |s| {
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
    if (stmt.data == .function) {
        // tsc allows this, but in strict mode it's a syntax error.
        return this.unsupported(stmt.start, "A function declaration as the body of a statement is not supported yet.", .{});
    }
    if (stmt.data != .variable) {
        return this.statement(stmt);
    }
    try this.report(stmt.start, .ts(1156), "'{t}' declarations can only be declared inside a block.", .{stmt.data.variable.kind});
    try this.pushScope(null, .block);
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
            const annotated = if (d.type) |annotation| try this.resolveType(annotation) else null;
            variable_.resolving = d.type == null;
            this.initializer = .{ .slot = slot, .expr = init };
            const init_type = try this.contextual(init, annotated);
            this.initializer = null;
            variable_.resolving = false;
            if (annotated) |t| {
                declared = t;
                if (!types.assignable(init_type, declared)) {
                    try this.reportNotAssignable(init, init_type, declared, d.start, .assignment);
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
            try this.pushScope(stmt.data.@"for".scope, .block);
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
        if (this.context != null) {
            try this.report(stmt.start, .ts(1107), "Jump target cannot cross function boundary.", .{});
            this.flow = .unreachable_flow;
            return;
        }
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
    if (l.body.data == .variable or l.body.data == .function) {
        try this.report(stmt.start, .ts(1344), "'A label is not allowed here.", .{});
        try this.pushScope(null, .block);
        defer this.popScope();
        try this.prescan(&.{l.body});
        return this.labeledStatement(l.body, all);
    }
    try this.labeledStatement(l.body, all);
}

fn switchStatement(this: *Checker, sw: ast.Switch, labels: []const []const u8) Error!void {
    const discriminant = try this.expression(sw.discriminant);
    try this.pushScope(sw.scope, .block);
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
    .rest = .{ .name = "data", .type = types.any_array },
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
        this.ref_scopes[id.ref] = this.scope;
        const v = this.variable(slot);
        const here = this.currentFunction();
        const outer = !sameOwner(v.owner, here);
        if (outer and slot >= this.slot_base) {
            this.captured[slot - this.slot_base] = true;
        }
        // A use inside a function that runs later isn't early.
        const early = v.source == this.source and expr.start < v.end and !outer and v.kind != .function;
        if (early) {
            if (v.kind != .parameter) {
                try this.report(expr.start, .ts(2448), "Block-scoped variable '{s}' used before its declaration.", .{id.name});
            } else if (expr.start > v.start) {
                try this.report(expr.start, .ts(2372), "Parameter '{s}' cannot reference itself.", .{id.name});
            } else {
                try this.report(expr.start, .ts(2373), "Parameter '{s}' cannot reference identifier '{s}' declared after it.", .{ this.parameter orelse "", id.name });
            }
        }
        return .{ .slot = slot, .early = early };
    }
    this.refs[id.ref] = .{ .global = id.name };
    if (std.mem.eql(u8, id.name, "arguments") and this.inNonArrowFunction()) {
        try this.unsupported(expr.start, "'arguments' is not supported yet.", .{});
        return .{ .slot = null };
    }
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
    if (this.variable(slot).kind == .function or !this.flow.reachable) {
        return declared;
    }
    const state = this.flow.vars[slot];
    if (state.type) |t| {
        return t;
    }
    if (this.isOuter(slot)) {
        return this.outerType(slot, expr.start, declared);
    }
    if (this.variable(slot).kind == .parameter) {
        // Only possible from an earlier parameter's default value, already an error (TS2373).
        return declared;
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
    switch (this.variable(slot).kind) {
        .@"const" => {
            try this.report(expr.start, .ts(2588), "Cannot assign to '{s}' because it is a constant.", .{id.name});
            return null;
        },
        .function => {
            try this.report(expr.start, .ts(2630), "Cannot assign to '{s}' because it is a function.", .{id.name});
            return null;
        },
        .let, .parameter => {},
    }
    if (this.flow.reachable and !this.flow.vars[slot].initialized and !r.early and !this.isOuter(slot)) {
        try this.unsupported(expr.start, "Assigning to '{s}' before its declaration has run is not supported yet.", .{id.name});
    }
    return slot;
}

/// Whether a variable belongs to a function enclosing the one being checked.
fn isOuter(this: *const Checker, slot: u32) bool {
    return !sameOwner(this.session.variables.items[slot].owner, this.currentFunction());
}

fn sameOwner(a: ?u32, b: ?u32) bool {
    if (a == null or b == null) {
        return a == null and b == null;
    }
    return a.? == b.?;
}

fn currentFunction(this: *const Checker) ?u32 {
    return if (this.context) |c| c.function.id else null;
}

fn inNonArrowFunction(this: *const Checker) bool {
    var c = this.context;
    while (c) |ctx| : (c = ctx.parent) {
        if (ctx.function.kind != .arrow) {
            return true;
        }
    }
    return false;
}

/// The type of an enclosing function's variable, read in a closure before the closure assigns it.
/// Like tsc, what's known where a function expression is created still holds inside it if the
/// variable is a `const`, or nothing assigns it after the reference (`isPastLastAssignment`).
/// Otherwise it's the declared type, and assumed to be assigned unless nothing ever assigns it.
fn outerType(this: *Checker, slot: u32, at: u32, declared: *const Type) Error!*const Type {
    const v = this.variable(slot);
    var c = this.context.?;
    while (c.function.kind != .declaration) {
        const extends = switch (v.kind) {
            .@"const" => true,
            .let, .parameter => try this.pastLastAssignment(slot, at),
            .function => unreachable,
        };
        if (!extends) {
            break;
        }
        const parent: ?u32 = if (c.parent) |p| p.function.id else null;
        if (!sameOwner(parent, v.owner)) {
            c = c.parent.?;
            continue;
        }
        // The closure is created in the variable's own function. One created before the variable
        // is declared (or in its initializer) sees it once it is.
        const creation = c.creation.?;
        if ((v.source == this.source and c.function.start < v.end) or !creation.reachable) {
            return declared;
        }
        if (creation.vars[slot].type) |t| {
            return t;
        }
        if (!types.includesUndefined(declared)) {
            try this.report(at, .ts(2454), "Variable '{s}' is used before being assigned.", .{v.name});
        }
        return declared;
    }
    const never_initialized = v.kind == .let and v.init == null and (try this.lastAssignment(slot)) == .never;
    if (never_initialized and !types.includesUndefined(declared)) {
        try this.report(at, .ts(2454), "Variable '{s}' is used before being assigned.", .{v.name});
    }
    return declared;
}

fn pastLastAssignment(this: *Checker, slot: u32, at: u32) Error!bool {
    return switch (try this.lastAssignment(slot)) {
        .never => true,
        .at => |position| position < at,
        .anywhere => false,
    };
}

/// tsc's `lastAssignmentPos`: where the last assignment to a variable is in its function, moved to
/// the end of the outermost statement around it that comes after the declaration (so one in a
/// loop counts as at the loop's end). Names are matched without regard to shadowing.
fn lastAssignment(this: *Checker, slot: u32) Error!LastAssignment {
    const v = this.variable(slot);
    if (v.last_assignment) |last| {
        return last;
    }
    var scan: AssignmentScan = .{ .name = v.name, .after = if (v.source == this.source) v.start else 0 };
    if (v.owner) |owner| {
        var c = this.context;
        while (c) |ctx| : (c = ctx.parent) {
            if (ctx.function.id == owner) {
                scan.function(ctx.function, false);
                break;
            }
        }
    } else {
        scan.statements(this.program, null, false);
    }
    v.last_assignment = scan.result;
    return scan.result;
}

const AssignmentScan = struct {
    name: []const u8,
    /// Where the declaration is.
    after: u32,
    result: LastAssignment = .never,

    fn found(this: *AssignmentScan, at: u32, nested: bool) void {
        if (nested) {
            this.result = .anywhere;
        } else {
            switch (this.result) {
                .never => this.result = .{ .at = at },
                .at => |p| this.result = .{ .at = @max(p, at) },
                .anywhere => {},
            }
        }
    }

    fn function(this: *AssignmentScan, f: *const ast.Function, nested: bool) void {
        for (f.parameters) |p| {
            if (p.init) |init| {
                this.expr(init, null, nested);
            }
        }
        switch (f.body) {
            .block => |b| this.statements(b.statements, null, nested),
            .expression => |e| this.expr(e, null, nested),
        }
    }

    fn statements(this: *AssignmentScan, list: []const *const Stmt, outer: ?u32, nested: bool) void {
        for (list) |s| {
            this.statement(s, outer, nested);
        }
    }

    fn statement(this: *AssignmentScan, s: *const Stmt, outer_end: ?u32, nested: bool) void {
        const counts = switch (s.data) {
            .variable, .expression, .@"if", .do_while, .@"while", .@"for", .@"switch" => true,
            else => false,
        };
        const outer = outer_end orelse if (counts and s.start > this.after) s.end else null;
        switch (s.data) {
            .expression => |e| this.expr(e, outer, nested),
            .empty, .@"break", .@"continue" => {},
            .variable => |v| for (v.declarators) |d| {
                if (d.init) |init| {
                    this.expr(init, outer, nested);
                }
            },
            .function => |f| this.function(f, true),
            .@"return" => |value| if (value) |e| this.expr(e, outer, nested),
            .block => |b| this.statements(b.statements, outer, nested),
            .@"if" => |i| {
                this.expr(i.condition, outer, nested);
                this.statement(i.then, outer, nested);
                if (i.otherwise) |o| {
                    this.statement(o, outer, nested);
                }
            },
            .@"while", .do_while => |l| {
                this.expr(l.condition, outer, nested);
                this.statement(l.body, outer, nested);
            },
            .@"for" => |f| {
                if (f.init) |init| {
                    this.statement(init, outer, nested);
                }
                if (f.condition) |e| {
                    this.expr(e, outer, nested);
                }
                if (f.update) |e| {
                    this.expr(e, outer, nested);
                }
                this.statement(f.body, outer, nested);
            },
            .labeled => |l| this.statement(l.body, outer, nested),
            .@"switch" => |sw| {
                this.expr(sw.discriminant, outer, nested);
                for (sw.clauses) |clause| {
                    if (clause.case) |e| {
                        this.expr(e, outer, nested);
                    }
                    this.statements(clause.statements, outer, nested);
                }
            },
        }
    }

    fn target(this: *AssignmentScan, e: *const Expr, outer: ?u32, nested: bool) void {
        const t = ast.skipParens(e);
        if (t.data == .identifier and std.mem.eql(u8, t.data.identifier.name, this.name)) {
            this.found(outer orelse t.start, nested);
        }
    }

    fn expr(this: *AssignmentScan, e: *const Expr, outer: ?u32, nested: bool) void {
        switch (e.data) {
            .number, .string, .boolean, .null, .identifier => {},
            .template => |t| for (t.substitutions) |sub| {
                this.expr(sub, outer, nested);
            },
            .paren => |inner| this.expr(inner, outer, nested),
            .unary => |u| this.expr(u.operand, outer, nested),
            .update => |u| {
                this.target(u.operand, outer, nested);
                this.expr(u.operand, outer, nested);
            },
            .assign => |a| {
                this.target(a.target, outer, nested);
                this.expr(a.target, outer, nested);
                this.expr(a.value, outer, nested);
            },
            .binary => |b| {
                this.expr(b.left, outer, nested);
                this.expr(b.right, outer, nested);
            },
            .conditional => |c| {
                this.expr(c.condition, outer, nested);
                this.expr(c.then, outer, nested);
                this.expr(c.otherwise, outer, nested);
            },
            .member => |m| this.expr(m.object, outer, nested),
            .call => |c| {
                this.expr(c.callee, outer, nested);
                for (c.arguments) |arg| {
                    this.expr(arg, outer, nested);
                }
            },
            .function => |f| this.function(f, true),
        }
    }
};

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
        .conditional => |c| this.conditional(c, null),
        .member => |m| this.member(m),
        .call => |c| this.call(expr, c),
        .function => |f| this.checkFunction(f, null, .check),
    };
}

/// An expression checked against the type its surroundings expect, which gives an arrow
/// function's parameters their types.
fn contextual(this: *Checker, expr: *const Expr, context: ?*const Type) Error!*const Type {
    const ctx = context orelse return this.expression(expr);
    return switch (expr.data) {
        .paren => |inner| this.contextual(inner, ctx),
        .function => |f| this.checkFunction(f, ctx, .check),
        .conditional => |c| this.conditional(c, ctx),
        else => this.expression(expr),
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
            try this.narrowVariable(slot, expr.start, .truthy);
            branches.when_true = this.flow;
            this.flow = branches.when_false;
            try this.narrowVariable(slot, expr.start, .falsy);
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

fn conditional(this: *Checker, c: ast.Conditional, context: ?*const Type) Error!*const Type {
    const branches = try this.condition(c.condition, null, null);
    try this.checkTruthiness(c.condition);
    this.flow = branches.when_true;
    const then = try this.contextual(c.then, context);
    const after_then = this.flow;
    try this.checkUncalledFunction(c.condition, branches.type, .{ .expr = c.then }, null);
    this.flow = branches.when_false;
    const otherwise = try this.contextual(c.otherwise, context);
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
        const declared = try this.declaredType(slot);
        const value = try this.contextual(a.value, declared);
        if (!types.assignable(value, declared)) {
            try this.reportNotAssignable(a.value, value, declared, a.target.start, .assignment);
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
            .logical_and => try this.narrowVariable(slot, target.start, .falsy),
            .logical_or => try this.narrowVariable(slot, target.start, .truthy),
            else => try this.narrowVariable(slot, target.start, .non_nullish),
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
        .identifier, .string, .template, .number, .boolean, .null, .function => true,
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
            if (std.mem.eql(u8, m.property, "name")) {
                return types.string;
            }
            if (std.mem.eql(u8, m.property, "length")) {
                return types.number;
            }
            return this.unsupportedProperty(m, object, &.{ "apply", "bind", "call", "toString", "prototype", "arguments", "caller" });
        },
        .array => {
            if (std.mem.eql(u8, m.property, "length")) {
                return types.number;
            }
            return this.unsupportedProperty(m, object, &.{
                "toString",   "toLocaleString", "pop",    "push",    "concat",      "join",        "reverse",   "shift",
                "slice",      "sort",           "splice", "unshift", "indexOf",     "lastIndexOf", "every",     "some",
                "forEach",    "map",            "filter", "reduce",  "reduceRight", "find",        "findIndex", "fill",
                "copyWithin", "entries",        "keys",   "values",  "includes",    "flatMap",     "flat",      "at",
            });
        },
        .never => return types.never,
        else => {
            try this.unsupported(m.property_start, "Properties of '{f}' are not supported yet.", .{try types.widen(this.arena, object)});
            return types.any;
        },
    }
}

/// A property that exists but isn't implemented yet (one of `known`), or TS2339.
fn unsupportedProperty(this: *Checker, m: ast.Member, object: *const Type, known: []const []const u8) Error!*const Type {
    for (known) |name| {
        if (std.mem.eql(u8, name, m.property)) {
            try this.unsupported(m.property_start, "The '{s}' property of '{f}' is not supported yet.", .{ m.property, object });
            return types.any;
        }
    }
    try this.report(m.property_start, .ts(2339), "Property '{s}' does not exist on type '{f}'.", .{ m.property, object });
    return types.any;
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
    if (callee.* == .function) {
        return this.callFunction(expr, c, callee.function);
    }
    for (c.arguments) |arg| {
        _ = try this.expression(arg);
    }
    switch (callee.*) {
        .any => return types.any,
        .never => return types.never,
        else => {
            try this.report(c.callee.start, .ts(2349), "This expression is not callable.\n  Type '{s}' has no call signatures.", .{try this.apparentName(callee)});
            return types.any;
        },
    }
}

fn callFunction(this: *Checker, expr: *const Expr, c: ast.Call, f: *const types.Function) Error!*const Type {
    var args: std.ArrayList(*const Type) = .empty;
    for (c.arguments, 0..) |arg, i| {
        try args.append(this.arena, try this.contextual(arg, f.parameterType(i)));
    }
    if (f.pending) {
        // Its return type is what's being worked out.
        this.markCircular(f);
        return types.any;
    }
    const min = f.minArguments();
    const max = f.parameters.len;
    const count = args.items.len;
    if (count < min or (f.rest == null and count > max)) {
        const at = if (count > max) c.arguments[max].start else expr.start;
        if (f.rest != null) {
            try this.report(at, .ts(2555), "Expected at least {d} arguments, but got {d}.", .{ min, count });
        } else if (min == max) {
            try this.report(at, .ts(2554), "Expected {d} arguments, but got {d}.", .{ min, count });
        } else {
            try this.report(at, .ts(2554), "Expected {d}-{d} arguments, but got {d}.", .{ min, max, count });
        }
        return f.returns;
    }
    for (args.items, c.arguments, 0..) |arg_type, arg, i| {
        var param = f.parameterType(i).?;
        // `undefined` can be passed for any optional parameter.
        if (i < f.parameters.len and f.parameters[i].optional) {
            param = try types.unionOf(this.arena, &.{ param, types.undefined });
        }
        if (!types.assignable(arg_type, param)) {
            try this.reportNotAssignable(arg, arg_type, f.parameterType(i).?, arg.start, .argument);
        }
    }
    return f.returns;
}

/// A function's return type was needed while it was being inferred: it and every function whose
/// inference led back to it get `any` (TS7023).
fn markCircular(this: *Checker, f: *const types.Function) void {
    for (this.inferring.items, 0..) |id, i| {
        const t = this.functions[id].type orelse continue;
        if (t.function == f) {
            for (this.inferring.items[i..]) |later| {
                this.functions[later].circular = true;
            }
            return;
        }
    }
}

// Functions

const Mode = enum {
    /// Check it where it is, reporting what's wrong.
    check,
    /// Only work out its type, for a function declaration used before it's checked.
    infer,
};

/// Checks a function and returns its type. `context_type` is the type its surroundings expect,
/// which gives unannotated parameters their types.
fn checkFunction(this: *Checker, f: *const ast.Function, context_type: ?*const Type, mode: Mode) Error!*const Type {
    const info = &this.functions[f.id];
    // A declaration whose type was worked out earlier keeps that type.
    const keep = f.kind == .declaration and info.type != null;
    const parent_scope = if (f.kind == .declaration) this.variable(this.slot_base + f.name.?.binding).scope else this.scope;

    const saved_flow = this.flow;
    const saved_scope = this.scope;
    const saved_targets = this.targets;
    const saved_labels = this.labels;
    const saved_context = this.context;
    const saved_initializer = this.initializer;
    const saved_indirect = this.indirect_call;
    const saved_parameter = this.parameter;
    const saved_lazy = this.lazy;
    defer {
        this.flow = saved_flow;
        this.scope = saved_scope;
        this.targets = saved_targets;
        this.labels = saved_labels;
        this.context = saved_context;
        this.initializer = saved_initializer;
        this.indirect_call = saved_indirect;
        this.parameter = saved_parameter;
        this.lazy = saved_lazy;
    }
    if (mode == .infer) {
        this.muted += 1;
    }
    defer if (mode == .infer) {
        this.muted -= 1;
    };

    var context = contextualSignature(context_type);
    if (context) |ctx| {
        // tsc's `isAritySmaller`: a function that needs more arguments than its context passes
        // isn't typed by it.
        if (ctx.rest == null and requiredParameters(f) > ctx.parameters.len) {
            context = null;
        }
    }

    const signature = try this.arena.create(types.Function);
    signature.* = .{ .parameters = &.{}, .returns = types.any, .pending = !keep };
    const self_type = try this.arena.create(Type);
    self_type.* = .{ .function = signature };
    if (!keep) {
        info.* = .{ .type = self_type };
        try this.inferring.append(this.arena, f.id);
    }
    defer if (!keep) {
        _ = this.inferring.pop();
    };

    // The name TS7023 is reported at.
    var name: ?ast.Function.Name = f.name;
    if (f.kind == .declaration) {
        if (!keep) {
            this.variable(this.slot_base + f.name.?.binding).declared = self_type;
        }
    } else if (this.initializer) |init| {
        const e = ast.skipParens(init.expr);
        if (e.data == .function and e.data.function == f) {
            // `const f = () => f()`: the variable has the function's type while it's checked.
            const v = this.variable(init.slot);
            v.declared = self_type;
            if (name == null) {
                name = .{ .text = v.name, .start = v.start, .binding = 0 };
            }
        }
    }

    const ctx = try this.arena.create(Context);
    ctx.* = .{
        .function = f,
        .parent = saved_context,
        .signature = signature,
        .creation = if (f.kind == .declaration) null else saved_flow,
        .declared_return = null,
        .contextual_return = if (context) |c| c.returns else null,
    };
    this.context = ctx;
    this.targets = .empty;
    this.labels = .empty;
    this.lazy = .empty;
    this.initializer = null;
    this.indirect_call = null;
    const vars = try this.arena.alloc(VarFlow, this.session.variables.items.len);
    @memset(vars, .{});
    this.flow = .{ .reachable = true, .vars = vars };
    this.scope = parent_scope;
    try this.pushScope(f.scope, .parameters);

    if (f.kind == .expression) {
        if (f.name) |n| {
            const slot = this.slot_base + n.binding;
            try this.declare(slot, .{ .name = n.text, .kind = .function, .start = n.start, .end = n.start, .source = this.source, .annotation = null, .init = null, .function = f });
            this.variable(slot).declared = self_type;
        }
    }

    const parameters = try this.arena.alloc(types.Parameter, f.parameters.len - @intFromBool(f.parameters.len > 0 and f.parameters[f.parameters.len - 1].rest));
    var seen_optional = false;
    // All of them first, so a default value that uses a later one finds it (TS2373).
    for (f.parameters) |*p| {
        try this.declare(this.slot_base + p.binding, .{ .name = p.name, .kind = .parameter, .start = p.start, .end = p.end, .source = this.source, .annotation = p.type, .init = p.init });
    }
    for (f.parameters, 0..) |*p, i| {
        const slot = this.slot_base + p.binding;
        const v = this.variable(slot);
        var from_context: ?*const Type = null;
        if (context) |c| {
            if (!p.rest) {
                from_context = c.parameterType(i);
            } else if (c.rest != null and i >= c.parameters.len) {
                from_context = c.rest.?.type;
            } else if (p.type == null) {
                try this.unsupported(p.node_start, "A rest parameter typed by its context is not supported yet.", .{});
                from_context = types.any_array;
            }
        }
        var t: *const Type = types.any;
        if (p.type) |annotation| {
            t = try this.resolveType(annotation);
            if (p.rest and t.* != .array and t.* != .any) {
                try this.report(annotation.start, .ts(2370), "A rest parameter must be of an array type.", .{});
                t = types.any_array;
            }
        } else if (from_context) |c| {
            t = c;
        } else if (p.init == null) {
            if (p.rest) {
                try this.report(p.node_start, .ts(7019), "Rest parameter '{s}' implicitly has an 'any[]' type.", .{p.name});
                t = types.any_array;
            } else {
                try this.report(p.start, .ts(7006), "Parameter '{s}' implicitly has an 'any' type.", .{p.name});
            }
        }
        if (p.init) |init| {
            const typed = p.type != null or from_context != null;
            this.parameter = p.name;
            v.resolving = !typed;
            const init_type = try this.contextual(init, if (typed) t else null);
            v.resolving = false;
            this.parameter = null;
            if (!typed) {
                t = if (v.circular) types.any else try types.widenFresh(this.arena, init_type);
            } else if (!types.assignable(init_type, t)) {
                try this.reportNotAssignable(init, init_type, t, p.start, .assignment);
            }
        }
        if (!p.optional and p.init == null and !p.rest and seen_optional) {
            try this.report(p.start, .ts(1016), "A required parameter cannot follow an optional parameter.", .{});
        }
        seen_optional = seen_optional or p.optional;
        if (p.optional) {
            t = try types.unionOf(this.arena, &.{ t, types.undefined });
        }
        v.declared = t;
        this.flow.vars[slot] = .{ .initialized = true, .type = t };
        if (p.rest) {
            signature.rest = .{ .name = p.name, .type = t };
        } else {
            parameters[i] = .{ .name = p.name, .type = t, .optional = p.optional or p.init != null };
        }
    }
    // A parameter with a default value before a required one isn't optional: `undefined` has to
    // be passed for it.
    var i = parameters.len;
    var required = false;
    while (i > 0) {
        i -= 1;
        const p = &parameters[i];
        if (!p.optional) {
            required = true;
        } else if (required and !f.parameters[i].optional) {
            p.optional = false;
            p.type = try types.unionOf(this.arena, &.{ p.type, types.undefined });
        }
    }
    signature.parameters = parameters;

    const declared_return = if (f.returns) |r| try this.resolveType(r) else null;
    ctx.declared_return = declared_return;
    if (declared_return) |r| {
        // Nothing needs the body to know what it returns.
        signature.returns = r;
        signature.pending = false;
    }
    switch (f.body) {
        .block => |b| {
            try this.pushScope(b.scope, .block);
            try this.prescan(b.statements);
            for (b.statements) |s| {
                try this.statement(s);
            }
            this.popScope();
        },
        .expression => |e| {
            const t = try this.contextual(e, declared_return orelse ctx.contextual_return);
            if (declared_return) |r| {
                if (!types.assignable(t, r)) {
                    try this.reportNotAssignable(e, t, r, e.start, .assignment);
                }
            }
            try ctx.returns.append(this.arena, t);
            this.flow = .unreachable_flow;
        },
    }
    const end_reachable = this.flow.reachable;

    var returns: *const Type = undefined;
    if (declared_return) |r| {
        returns = r;
        if (end_reachable) {
            try this.checkEndReachable(f, r, ctx);
        }
    } else if (ctx.returns.items.len == 0) {
        // An arrow or function expression that never returns returns `never`; a declaration
        // returns `void` either way.
        returns = if (!end_reachable and !ctx.empty_return and f.kind != .declaration) types.never else types.void;
    } else {
        if (end_reachable or ctx.empty_return) {
            try ctx.returns.append(this.arena, types.undefined);
        }
        const t = try types.unionOf(this.arena, ctx.returns.items);
        const literal_context = if (ctx.contextual_return) |c| types.couldHaveSingletons(c) else false;
        returns = if (literal_context) t else try types.widenFresh(this.arena, t);
    }
    if (keep) {
        if (info.circular and mode == .check) {
            try this.reportCircular(f, name);
        }
        return info.type.?;
    }
    if (info.circular) {
        returns = types.any;
        if (mode == .check) {
            try this.reportCircular(f, name);
        }
    } else if (refersTo(returns, self_type)) {
        try this.unsupported(if (name) |n| n.start else f.start, "A function that returns itself is not supported yet.", .{});
        returns = types.any;
    }
    signature.returns = returns;
    signature.pending = false;
    return self_type;
}

fn reportCircular(this: *Checker, f: *const ast.Function, name: ?ast.Function.Name) Error!void {
    if (f.kind == .expression) {
        // tsc has its own rules for these.
        return this.unsupported(if (name) |n| n.start else f.start, "A function expression that calls itself without a return type annotation is not supported yet.", .{});
    }
    if (name) |n| {
        try this.report(n.start, .ts(7023), "'{s}' implicitly has return type 'any' because it does not have a return type annotation and is referenced directly or indirectly in one of its return expressions.", .{n.text});
    } else {
        try this.report(f.start, .ts(7024), "Function implicitly has return type 'any' because it does not have a return type annotation and is referenced directly or indirectly in one of its return expressions.", .{});
    }
}

/// tsc's `checkAllCodePathsInNonVoidFunctionReturnOrThrow`, for a function with a return type
/// annotation whose end can be reached.
fn checkEndReachable(this: *Checker, f: *const ast.Function, returns: *const Type, ctx: *const Context) Error!void {
    if (returns.* == .never) {
        return this.report(f.returns_start, .ts(2534), "A function returning 'never' cannot have a reachable end point.", .{});
    }
    var buffer: [1]*const Type = undefined;
    for (returns.members(&buffer)) |m| {
        if (m.* == .void or m.* == .any or (m.* == .undefined and returns.* != .@"union")) {
            return;
        }
    }
    if (ctx.returns.items.len == 0 and !ctx.empty_return) {
        return this.report(f.returns_start, .ts(2355), "A function whose declared type is neither 'undefined', 'void', nor 'any' must return a value.", .{});
    }
    if (!types.includesUndefined(returns)) {
        try this.report(f.returns_start, .ts(2366), "Function lacks ending return statement and return type does not include 'undefined'.", .{});
    }
}

/// The function type a context gives a function expression: the context itself, or its only
/// function type once `null` and `undefined` are left out.
fn contextualSignature(context: ?*const Type) ?*const types.Function {
    const t = context orelse return null;
    var found: ?*const types.Function = null;
    var buffer: [1]*const Type = undefined;
    for (t.members(&buffer)) |m| {
        switch (m.*) {
            .function => |f| {
                if (found != null) {
                    return null;
                }
                found = f;
            },
            .null, .undefined => {},
            else => return null,
        }
    }
    return found;
}

/// How many arguments a function needs.
fn requiredParameters(f: *const ast.Function) usize {
    var count: usize = 0;
    for (f.parameters, 0..) |p, i| {
        if (!p.optional and p.init == null and !p.rest) {
            count = i + 1;
        }
    }
    return count;
}

/// Whether `t` mentions `target`.
fn refersTo(t: *const Type, target: *const Type) bool {
    if (t == target) {
        return true;
    }
    return switch (t.*) {
        .@"union" => |ms| for (ms) |m| {
            if (refersTo(m, target)) {
                break true;
            }
        } else false,
        .array => |e| refersTo(e, target),
        .function => |f| refersTo(f.returns, target) or for (f.parameters) |p| {
            if (refersTo(p.type, target)) {
                break true;
            }
        } else false,
        else => false,
    };
}

fn returnStatement(this: *Checker, stmt: *const Stmt, value: ?*const Expr) Error!void {
    const ctx = this.context orelse {
        try this.report(stmt.start, .ts(1108), "A 'return' statement can only be used within a function body.", .{});
        if (value) |v| {
            _ = try this.expression(v);
        }
        this.flow = .unreachable_flow;
        return;
    };
    if (value) |v| {
        const t = try this.contextual(v, ctx.declared_return orelse ctx.contextual_return);
        if (ctx.declared_return) |r| {
            if (!types.assignable(t, r)) {
                try this.reportNotAssignable(v, t, r, stmt.start, .assignment);
            }
        }
        try ctx.returns.append(this.arena, t);
    } else {
        ctx.empty_return = true;
        if (ctx.declared_return) |r| {
            if (!types.assignable(types.undefined, r)) {
                try this.notAssignable(stmt.start, types.undefined, r);
            }
        }
    }
    this.flow = .unreachable_flow;
}

/// Reports that `expr`, of type `source`, can't be used as a `target`, as an assignment (TS2322)
/// or an argument (TS2345). Like tsc, a mismatched return type of an arrow function with an
/// expression body is reported at that expression.
fn reportNotAssignable(this: *Checker, expr: *const Expr, source: *const Type, target: *const Type, at: u32, kind: enum { assignment, argument }) Error!void {
    const e = ast.skipParens(expr);
    if (e.data == .function and source.* == .function) {
        const f = e.data.function;
        const annotated = for (f.parameters) |p| {
            if (p.type != null) {
                break true;
            }
        } else false;
        if (contextualSignature(target)) |t| {
            const mismatch = types.functionMismatch(source.function, t);
            if (f.kind == .arrow and f.body == .expression and !annotated and mismatch != null and mismatch.? == .returns) {
                return this.report(f.body.expression.start, .ts(2322), "Type '{f}' is not assignable to type '{f}'.", .{ try this.shownSource(source.function.returns, t.returns), t.returns });
            }
        }
    }
    const elaboration = try this.elaborate(source, target);
    switch (kind) {
        .assignment => {
            var shown = target;
            if (target.* == .@"union" and !includesNullish(source)) {
                const rest = try this.removeNullish(target);
                if (!types.isUnion(rest)) {
                    shown = rest;
                }
            }
            try this.report(at, .ts(2322), "Type '{f}' is not assignable to type '{f}'.{s}", .{ try this.shownSource(source, shown), shown, elaboration });
        },
        .argument => try this.report(at, .ts(2345), "Argument of type '{f}' is not assignable to parameter of type '{f}'.{s}", .{ try this.shownSource(source, target), target, elaboration }),
    }
}

/// The lines tsc adds to say why one function type isn't assignable to another.
fn elaborate(this: *Checker, source: *const Type, target: *const Type) Error![]const u8 {
    if (source.* != .function or target.* != .function) {
        return "";
    }
    const s = source.function;
    const t = target.function;
    const mismatch = types.functionMismatch(s, t) orelse return "";
    return switch (mismatch) {
        .arity => |needed| std.fmt.allocPrint(this.arena, "\n  Target signature provides too few arguments. Expected {d} or more, but got {d}.", .{ needed, t.parameters.len }),
        .parameter => |i| std.fmt.allocPrint(this.arena, "\n  Types of parameters '{s}' and '{s}' are incompatible.\n    Type '{f}' is not assignable to type '{f}'.", .{
            parameterName(s, i), parameterName(t, i), t.parameterType(i).?, s.parameterType(i).?,
        }),
        .returns => std.fmt.allocPrint(this.arena, "\n  Type '{f}' is not assignable to type '{f}'.", .{ try this.shownSource(s.returns, t.returns), t.returns }),
    };
}

fn parameterName(f: *const types.Function, i: usize) []const u8 {
    return if (i < f.parameters.len) f.parameters[i].name else f.rest.?.name;
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
        .function => .always,
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
            .object, .function, .array, .never => {},
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
        .function => |f| this.usesInFunction(f, target),
    };
}

fn usesInFunction(this: *const Checker, f: *const ast.Function, target: *const Expr) bool {
    for (f.parameters) |p| {
        if (p.init) |init| {
            if (this.uses(init, target)) {
                return true;
            }
        }
    }
    return switch (f.body) {
        .block => |b| this.usesInStatements(b.statements, target),
        .expression => |e| this.uses(e, target),
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
        .block => |b| this.usesInStatements(b.statements, target),
        .function => |f| this.usesInFunction(f, target),
        .@"return" => |value| if (value) |v| this.uses(v, target) else false,
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
