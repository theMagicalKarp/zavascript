//! Type checks a program the way `tsc --strict` does, reporting tsc's codes and messages. A
//! program with any diagnostics never runs.
//!
//! Expressions are checked bottom-up. After an error the checker keeps going with the type the
//! expression would have had (e.g. `boolean` for a bad `<`), like tsc, so independent errors are
//! all reported but one mistake doesn't cascade.
//!
//! Alongside types, the checker follows control flow the way tsc's flow analysis does: which
//! variables are definitely assigned (TS2454), and what assignments and tests narrow a variable or
//! a property of one to (`let b = true` is `true` until something assigns `false`; after
//! `if (typeof x === "string") return;`, `x` isn't a string). What a test does to a type is in
//! `narrowing.zig`. A loop is checked repeatedly until the state at its head stops changing; only
//! the last pass's diagnostics are kept.
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
const narrowing = @import("narrowing.zig");
const inference = @import("inference.zig");
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
/// How many aliased conditions (`const isString = typeof x === "string"; if (isString)`) are
/// being narrowed by, through their initializers. Only constant references narrow then.
aliased: u32 = 0,
/// Variables whose types are being worked out early, for a use before their declaration; each
/// was reached from the one before it.
lazy: std.ArrayList(u32) = .empty,
/// The comma expression in `(0, a.b)()`, which isn't reported as unused (TS2695).
indirect_call: ?*const Expr = null,
/// Interfaces and type aliases, by the statement that declares them, so each is resolved once
/// however many times its scope is checked.
type_decls: std.AutoHashMapUnmanaged(*const Stmt, *TypeDecl) = .empty,
/// Type names this program added to the session's top level, removed again if it doesn't check.
added_types: std.ArrayList([]const u8) = .empty,
/// While above zero, a type declaration is being resolved. Its diagnostics are kept aside and
/// reported at the end, since it's only resolved once, however many times the code around it is
/// checked (or checked without reporting).
declaring: u32 = 0,
/// The type declarations being resolved, innermost last.
resolving_decls: std.ArrayList(*TypeDecl) = .empty,
/// Type arguments to check against their constraints (TS2344) once the declarations being resolved
/// are, since they can be what's being resolved: `interface Card extends Ordered<Card>`.
constraint_checks: std.ArrayList(ConstraintCheck) = .empty,
/// How many of the type annotations being resolved are deferred: tsc resolves what's in them
/// lazily, so a type alias can refer to itself in one (`type T = { next: T }`). Only a type alias
/// that's another one, or a type argument of one, isn't.
deferred: u32 = 0,
late: std.ArrayList(Late) = .empty,
/// Inside the operand of `as const`, where literals keep their types and properties are
/// `readonly`.
const_context: bool = false,
/// The generic call whose arguments are being inferred from, while one of them is checked.
argument_of: ?ArgumentOf = null,

const ConstraintCheck = struct {
    at: u32,
    argument: *const Type,
    constraint: *const Type,
};

const ArgumentOf = struct {
    inferences: *inference.Context,
    from_return: *inference.Context,
    returns: *const Type,
};

const Late = struct {
    at: u32,
    code: diagnostic.Code,
    message: []const u8,
};

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
    /// Top-level interfaces and type aliases.
    types: std.StringHashMapUnmanaged(*TypeDecl) = .empty,
    /// The scope of `lib.d.ts`'s declarations, which every program sees behind its own.
    library: ?*Scope = null,
};

/// Declares the types in `lib.d.ts`, which has nothing but interfaces and type aliases.
pub fn declareLibrary(arena: std.mem.Allocator, session: *Session, program: ast.Program) Error!void {
    const scope = try arena.create(Scope);
    scope.* = .{ .parent = null, .kind = .block, .function = null };
    for (program.statements) |stmt| {
        const decl = try arena.create(TypeDecl);
        decl.* = switch (stmt.data) {
            .interface => |i| .{ .name = i.name, .start = i.start, .node = .{ .interface = i }, .scope = scope },
            .type_alias => |a| .{ .name = a.name, .start = a.start, .node = .{ .alias = a }, .scope = scope },
            else => unreachable,
        };
        try scope.types.put(arena, decl.name, decl);
    }
    session.library = scope;
}

/// An interface, a type alias, or a type parameter.
const TypeDecl = struct {
    name: []const u8,
    start: u32,
    node: Node,
    /// The scope it's declared in, where the names it mentions are looked up.
    scope: ?*Scope,
    resolved: ?*const Type = null,
    resolving: bool = false,
    /// `Checker.deferred` when it began to be resolved.
    deferred_at: u32 = 0,
    /// Whether it's a type alias that circularly references itself (TS2456).
    circular: bool = false,
    redeclared: bool = false,
    /// A generic one's type parameters, once it's resolved.
    parameters: []const *const Type = &.{},
    /// A generic one's instantiations so far, so each is made once: an interface's has to be,
    /// since it's only equal to itself.
    instances: std.ArrayList(Instance) = .empty,
    /// Instantiations of an interface (or object type alias) made while it was still being
    /// resolved, whose properties are filled in once it is.
    waiting: std.ArrayList(*types.Object) = .empty,

    const Node = union(enum) {
        interface: *const ast.Interface,
        alias: *const ast.TypeAlias,
        /// A type parameter, which is its own type.
        param,
    };

    const Instance = struct {
        arguments: []const *const Type,
        type: *const Type,
    };

    fn typeParameters(this: *const TypeDecl) []const ast.GenericParameter {
        return switch (this.node) {
            .interface => |i| i.type_parameters,
            .alias => |a| a.type_parameters,
            .param => &.{},
        };
    }
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
    /// For a name in a destructuring declaration, the declarator, whose type it comes from.
    destructured: ?*const ast.Declarator = null,

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
    /// Interfaces and type aliases, which have names of their own.
    types: std.StringHashMapUnmanaged(*TypeDecl) = .empty,
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

/// What flow analysis knows about a property of a variable, like `o.a.b`, which a test or an
/// assignment has narrowed.
const PathFlow = struct {
    reference: Reference,
    type: *const Type,
};

/// Something narrowing can apply to: a variable, or a chain of properties of one.
const Reference = struct {
    slot: u32,
    /// Empty for the variable itself.
    path: []const []const u8 = &.{},

    fn eql(a: Reference, b: Reference) bool {
        if (a.slot != b.slot or a.path.len != b.path.len) {
            return false;
        }
        for (a.path, b.path) |x, y| {
            if (!std.mem.eql(u8, x, y)) {
                return false;
            }
        }
        return true;
    }

    /// Whether `this` is `prefix` or a property (of a property...) of it.
    fn startsWith(this: Reference, prefix: Reference) bool {
        if (this.slot != prefix.slot or this.path.len < prefix.path.len) {
            return false;
        }
        for (prefix.path, this.path[0..prefix.path.len]) |x, y| {
            if (!std.mem.eql(u8, x, y)) {
                return false;
            }
        }
        return true;
    }
};

/// The state at one point in the program. Every reachable flow has one entry per slot. Each
/// `Flow` value owns its `vars`; splitting the flow copies them. `paths` is never changed in
/// place, so flows can share it.
const Flow = struct {
    reachable: bool,
    vars: []VarFlow,
    /// Narrowed properties. One that isn't here has its declared type.
    paths: []const PathFlow = &.{},

    const unreachable_flow: Flow = .{ .reachable = false, .vars = &.{} };

    fn path(this: Flow, reference: Reference) ?*const Type {
        for (this.paths) |p| {
            if (p.reference.eql(reference)) {
                return p.type;
            }
        }
        return null;
    }

    fn eql(a: Flow, b: Flow) bool {
        if (a.reachable != b.reachable) {
            return false;
        }
        if (!a.reachable) {
            return true;
        }
        if (a.paths.len != b.paths.len) {
            return false;
        }
        for (a.paths) |p| {
            const t = b.path(p.reference) orelse return false;
            if (!t.eql(p.type)) {
                return false;
            }
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
    for (checker.late.items) |late| {
        try diagnostics.add(source, late.at, late.code, "{s}", .{late.message});
    }

    if (diagnostics.items().len > errors_before) {
        session.variables.shrinkRetainingCapacity(slot_base);
        for (checker.added.items) |name| {
            _ = session.top_level.remove(name);
        }
        for (checker.added_types.items) |name| {
            _ = session.types.remove(name);
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
    if (this.declaring > 0) {
        return this.late.append(this.arena, .{ .at = at, .code = code, .message = try std.fmt.allocPrint(this.arena, fmt, args) });
    }
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
    return .{ .reachable = true, .vars = try this.arena.dupe(VarFlow, flow.vars), .paths = flow.paths };
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
    for (into.vars, other.vars, 0..) |*a, b, slot| {
        a.initialized = a.initialized and b.initialized;
        if (a.type == null or b.type == null) {
            a.type = null;
        } else if (!a.type.?.eql(b.type.?)) {
            a.type = try types.unionOf(this.arena, &.{ a.type.?, b.type.? });
            if (this.session.variables.items[slot].declared) |declared| {
                a.type = try types.orderLike(this.arena, a.type.?, declared);
            }
        }
    }
    // A property narrowed on only one path has its declared type here.
    var paths: std.ArrayList(PathFlow) = .empty;
    for (into.paths) |p| {
        const t = other.path(p.reference) orelse continue;
        try paths.append(this.arena, .{ .reference = p.reference, .type = if (t.eql(p.type)) t else try types.unionOf(this.arena, &.{ p.type, t }) });
    }
    into.paths = paths.items;
}

fn setVariable(this: *Checker, slot: u32, t: *const Type) Error!void {
    if (this.flow.reachable) {
        this.flow.vars[slot] = .{ .initialized = true, .type = t };
        try this.forgetPaths(.{ .slot = slot });
    }
}

/// Forgets what's known about the properties of `reference` (and `reference` itself, for a
/// property), since it's been assigned.
fn forgetPaths(this: *Checker, reference: Reference) Error!void {
    var kept: std.ArrayList(PathFlow) = .empty;
    for (this.flow.paths) |p| {
        if (!p.reference.startsWith(reference)) {
            try kept.append(this.arena, p);
        }
    }
    if (kept.items.len < this.flow.paths.len) {
        this.flow.paths = kept.items;
    }
}

/// Records what a property holds: what's been assigned to it, or what a test narrowed it to.
fn setPath(this: *Checker, reference: Reference, t: *const Type) Error!void {
    if (!this.flow.reachable) {
        return;
    }
    try this.forgetPaths(reference);
    var paths: std.ArrayList(PathFlow) = .empty;
    try paths.appendSlice(this.arena, this.flow.paths);
    try paths.append(this.arena, .{ .reference = reference, .type = t });
    this.flow.paths = paths.items;
}

// Scopes and declarations

/// Enters the scope with index `id` (or an unnumbered one, for code that won't run), whose
/// parent is the current scope.
fn pushScope(this: *Checker, id: ?u32, kind: @FieldType(Scope, "kind")) Error!void {
    var names: std.StringHashMapUnmanaged(u32) = .empty;
    var type_names: std.StringHashMapUnmanaged(*TypeDecl) = .empty;
    const scope = blk: {
        if (id) |i| {
            if (this.scopes[i]) |existing| {
                // A scope is entered again on each pass over a loop, and each time a function is
                // checked; its names start over.
                names = existing.names;
                names.clearRetainingCapacity();
                type_names = existing.types;
                type_names.clearRetainingCapacity();
                break :blk existing;
            }
            this.scopes[i] = try this.arena.create(Scope);
            break :blk this.scopes[i].?;
        }
        break :blk try this.arena.create(Scope);
    };
    scope.* = .{ .parent = this.scope, .names = names, .types = type_names, .kind = kind, .function = this.currentFunction() };
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
            .variable => |v| for (v.declarators) |*d| {
                if (d.pattern) |pattern| {
                    try this.declarePattern(pattern, if (v.kind == .let) .let else .@"const", d.end, d);
                    continue;
                }
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
            .interface, .type_alias => try this.declareType(s),
            else => {},
        }
    }
}

/// Declares every name in a destructuring pattern.
fn declarePattern(this: *Checker, pattern: *const ast.Pattern, kind: Variable.Kind, end: u32, declarator: ?*const ast.Declarator) Error!void {
    for (try pattern.bindings(this.arena)) |b| {
        try this.declare(this.slot_base + b.binding, .{
            .name = b.name,
            .kind = kind,
            .start = b.start,
            .end = end,
            .source = this.source,
            .annotation = null,
            .init = null,
            .destructured = declarator,
        });
    }
}

/// Adds an interface or type alias to the current scope.
fn declareType(this: *Checker, stmt: *const Stmt) Error!void {
    const entry = try this.type_decls.getOrPut(this.arena, stmt);
    if (!entry.found_existing) {
        const decl = try this.arena.create(TypeDecl);
        decl.* = switch (stmt.data) {
            .interface => |i| .{ .name = i.name, .start = i.start, .node = .{ .interface = i }, .scope = this.scope },
            .type_alias => |a| .{ .name = a.name, .start = a.start, .node = .{ .alias = a }, .scope = this.scope },
            else => unreachable,
        };
        entry.value_ptr.* = decl;
    }
    const decl = entry.value_ptr.*;
    decl.scope = this.scope;
    const names = if (this.scope) |scope| &scope.types else &this.session.types;
    const first = names.get(decl.name) orelse {
        try names.put(this.arena, decl.name, decl);
        if (this.scope == null) {
            try this.added_types.append(this.arena, decl.name);
        }
        return;
    };
    if (first.node == .interface and decl.node == .interface) {
        return this.unsupported(decl.start, "Merging interface declarations is not supported yet.", .{});
    }
    for ([_]*TypeDecl{ first, decl }) |d| {
        if (!d.redeclared) {
            d.redeclared = true;
            try this.report(d.start, .ts(2300), "Duplicate identifier '{s}'.", .{d.name});
        }
    }
}

fn lookupType(this: *Checker, name: []const u8) ?*TypeDecl {
    var scope = this.scope;
    while (scope) |s| : (scope = s.parent) {
        if (s.types.get(name)) |decl| {
            return decl;
        }
    }
    if (this.session.types.get(name)) |decl| {
        return decl;
    }
    const library = this.session.library orelse return null;
    return library.types.get(name);
}

/// Declares type parameters in the current scope, and resolves their constraints and defaults.
fn declareTypeParameters(this: *Checker, list: []const ast.GenericParameter) Error![]const *const Type {
    const result = try this.declareTypeParameterNames(list);
    try this.constrainTypeParameters(list, result);
    return result;
}

/// Declares type parameters in the current scope, without their constraints and defaults yet.
fn declareTypeParameterNames(this: *Checker, list: []const ast.GenericParameter) Error![]const *const Type {
    if (list.len == 0) {
        return &.{};
    }
    const scope = this.scope.?;
    const result = try this.arena.alloc(*const Type, list.len);
    const params = try this.arena.alloc(types.Param, list.len);
    for (list, params, result) |g, *p, *t| {
        p.* = .{ .name = g.name };
        t.* = try this.newType(.{ .param = p });
        const decl = try this.arena.create(TypeDecl);
        decl.* = .{ .name = g.name, .start = g.start, .node = .param, .scope = scope, .resolved = t.* };
        const entry = try scope.types.getOrPut(this.arena, g.name);
        if (entry.found_existing) {
            try this.report(g.start, .ts(2300), "Duplicate identifier '{s}'.", .{g.name});
        } else {
            entry.value_ptr.* = decl;
        }
    }
    return result;
}

/// Resolves the constraints and defaults of type parameters `declareTypeParameterNames` declared.
fn constrainTypeParameters(this: *Checker, list: []const ast.GenericParameter, result: []const *const Type) Error!void {
    var seen_default = false;
    for (list, result) |g, t| {
        const p: *types.Param = @constCast(t.param);
        if (g.constraint) |c| {
            p.constraint = try this.resolveType(c);
            // `T extends T`, or `T extends U, U extends T`.
            var next = p.constraint;
            var steps: usize = 0;
            while (next) |n| : (steps += 1) {
                if (n == t or steps > list.len) {
                    try this.report(c.start, .ts(2313), "Type parameter '{s}' has a circular constraint.", .{g.name});
                    p.constraint = null;
                    break;
                }
                next = if (n.* == .param) n.param.constraint else null;
            }
        }
        if (g.default) |d| {
            seen_default = true;
            p.default = try this.resolveType(d);
            if (p.constraint) |c| {
                const constraint = try types.instantiate(this.arena, c, &this.mapper(result, result));
                try this.checkConstraint(.{ .at = d.start, .argument = p.default.?, .constraint = constraint });
            }
        } else if (seen_default) {
            try this.report(g.start, .ts(2706), "Required type parameters may not follow optional type parameters.", .{});
        }
    }
}

/// A mapper substituting `to` for `from`.
fn mapper(this: *Checker, from: []const *const Type, to: []const *const Type) types.Mapper {
    return .{ .from = from, .to = to, .named = instantiateNamed, .context = this };
}

fn instantiateNamed(context: *anyopaque, object: *const types.Object, arguments: []const *const Type) Error!*const Type {
    const this: *Checker = @ptrCast(@alignCast(context));
    const decl: *TypeDecl = @ptrCast(@alignCast(@constCast(object.generic.?)));
    return this.instantiateDecl(decl, arguments);
}

fn instantiate(this: *Checker, t: *const Type, from: []const *const Type, to: []const *const Type) Error!*const Type {
    return types.instantiate(this.arena, t, &this.mapper(from, to));
}

/// A generic interface or type alias with type arguments for its type parameters (all of them,
/// defaults included).
fn instantiateDecl(this: *Checker, decl: *TypeDecl, arguments: []const *const Type) Error!*const Type {
    const generic = try this.resolveDecl(decl);
    if (generic.* == .any) {
        // Including one that refers to itself, which has been reported.
        return generic;
    }
    const same = for (decl.parameters, arguments) |p, a| {
        if (p != a) {
            break false;
        }
    } else true;
    if (same or decl.parameters.len != arguments.len) {
        return generic;
    }
    for (decl.instances.items) |instance| {
        const eql = for (instance.arguments, arguments) |x, y| {
            if (!x.eql(y)) {
                break false;
            }
        } else true;
        if (eql) {
            return instance.type;
        }
    }
    if (generic.* == .object and generic.object.generic == @as(*const anyopaque, decl)) {
        const object = try this.arena.create(types.Object);
        object.* = .{ .name = generic.object.name, .properties = &.{}, .type_arguments = arguments, .generic = decl };
        const t = try this.newType(.{ .object = object });
        try decl.instances.append(this.arena, .{ .arguments = arguments, .type = t });
        if (decl.resolving) {
            try decl.waiting.append(this.arena, object);
        } else {
            object.properties = try this.instantiateProperties(generic.object.properties, decl.parameters, arguments);
        }
        return t;
    }
    if (decl.resolving) {
        try this.unsupported(decl.start, "A generic type alias that refers to itself is not supported yet.", .{});
        return types.any;
    }
    const t = try this.instantiate(generic, decl.parameters, arguments);
    try decl.instances.append(this.arena, .{ .arguments = arguments, .type = t });
    return t;
}

fn instantiateProperties(this: *Checker, properties: []const types.Property, from: []const *const Type, to: []const *const Type) Error![]const types.Property {
    const list = try this.arena.alloc(types.Property, properties.len);
    for (properties, list) |p, *x| {
        x.* = p;
        x.type = try this.instantiate(p.type, from, to);
    }
    return list;
}

/// The type an interface or type alias names, resolved the first time it's needed.
fn resolveDecl(this: *Checker, decl: *TypeDecl) Error!*const Type {
    if (decl.resolved) |t| {
        return t;
    }
    if (decl.resolving) {
        // Only an alias can get here: an interface (or object type alias) has its type before its
        // type parameters' constraints and its members are resolved.
        decl.resolved = types.any;
        if (decl.deferred_at == this.deferred) {
            // Each alias it refers to on the way back to itself is circular too.
            const index = std.mem.indexOfScalar(*TypeDecl, this.resolving_decls.items, decl).?;
            for (this.resolving_decls.items[index..]) |d| {
                d.circular = true;
                try this.report(d.start, .ts(2456), "Type alias '{s}' circularly references itself.", .{d.name});
            }
        } else {
            // tsc allows `type T = T[]`, which needs types that are resolved lazily.
            try this.unsupported(decl.start, "A type alias that refers to itself is not supported yet.", .{});
        }
        return types.any;
    }
    const saved_scope = this.scope;
    this.scope = decl.scope;
    this.declaring += 1;
    decl.resolving = true;
    decl.deferred_at = this.deferred;
    try this.resolving_decls.append(this.arena, decl);
    defer {
        this.scope = saved_scope;
        this.declaring -= 1;
        decl.resolving = false;
        _ = this.resolving_decls.pop();
    }
    const type_parameters = decl.typeParameters();
    if (type_parameters.len > 0) {
        // A scope of their own, for the type parameters.
        try this.pushScope(null, .block);
        decl.parameters = try this.declareTypeParameterNames(type_parameters);
    }
    // An interface or object type alias exists before its constraints, so they can refer to it.
    const object = try this.declObject(decl);
    if (type_parameters.len > 0) {
        this.deferred += 1;
        defer this.deferred -= 1;
        try this.constrainTypeParameters(type_parameters, decl.parameters);
    }
    const t = blk: {
        // What's in an interface or object type is deferred.
        const deferred = @intFromBool(object != null);
        this.deferred += deferred;
        defer this.deferred -= deferred;
        break :blk try this.resolveDeclType(decl, object);
    };
    if (decl.circular) {
        decl.resolved = types.any;
    }
    // Instantiations made while it was resolved can be filled in now.
    if (t.* == .object and !decl.circular) {
        for (decl.waiting.items) |instance| {
            instance.properties = try this.instantiateProperties(t.object.properties, decl.parameters, instance.type_arguments);
        }
    }
    decl.waiting.clearRetainingCapacity();
    if (this.resolving_decls.items.len == 1) {
        // The outermost declaration being resolved: what it needed is complete now.
        for (this.constraint_checks.items) |c| {
            try this.reportConstraint(c);
        }
        this.constraint_checks.clearRetainingCapacity();
    }
    return decl.resolved.?;
}

/// The object type an interface or object type alias is, without its members yet, so they (and
/// its type parameters' constraints) can refer to it. Null for other declarations.
fn declObject(this: *Checker, decl: *TypeDecl) Error!?*types.Object {
    const name = switch (decl.node) {
        .param => unreachable,
        .interface => |i| i.name,
        .alias => |a| if (a.type.data == .object) a.name else return null,
    };
    // tsc shows an object type alias by the alias's name.
    const generic: ?*const anyopaque = if (decl.parameters.len > 0) decl else null;
    const object = try this.arena.create(types.Object);
    object.* = .{ .name = name, .properties = &.{}, .type_arguments = decl.parameters, .generic = generic };
    decl.resolved = try this.newType(.{ .object = object });
    return object;
}

fn resolveDeclType(this: *Checker, decl: *TypeDecl, object: ?*types.Object) Error!*const Type {
    switch (decl.node) {
        .param => unreachable,
        .interface => |i| {
            const t = decl.resolved.?;
            var properties: std.ArrayList(types.Property) = .empty;
            var bases: std.ArrayList(*const types.Object) = .empty;
            for (i.extends) |base| {
                const bt = try this.resolveReference(base.start, base);
                if (bt.* != .object) {
                    if (bt.* != .any) {
                        try this.report(base.start, .ts(2312), "An interface can only extend an object type or intersection of object types with statically known members.", .{});
                    }
                    continue;
                }
                try bases.append(this.arena, bt.object);
                for (bt.object.properties) |p| {
                    try putProperty(this.arena, &properties, p);
                }
            }
            for (try this.members(i.members)) |p| {
                for (bases.items) |base| {
                    const inherited = base.find(p.name) orelse continue;
                    if (!types.assignable(p.type, inherited.type)) {
                        try this.report(i.start, .ts(2430), "Interface '{s}' incorrectly extends interface '{s}'.\n  Types of property '{s}' are incompatible.\n    Type '{f}' is not assignable to type '{f}'.", .{ i.name, base.name, p.name, p.type, inherited.type });
                    }
                }
                try putProperty(this.arena, &properties, p);
            }
            object.?.properties = properties.items;
            return t;
        },
        .alias => |a| {
            if (object) |o| {
                o.properties = try this.members(a.type.data.object);
                return decl.resolved.?;
            }
            const t = try this.resolveType(a.type);
            if (decl.resolved == null) {
                decl.resolved = t;
            }
            return decl.resolved.?;
        },
    }
}

/// Adds a property, or replaces the one with the same name.
fn putProperty(arena: std.mem.Allocator, properties: *std.ArrayList(types.Property), p: types.Property) Error!void {
    for (properties.items) |*existing| {
        if (std.mem.eql(u8, existing.name, p.name)) {
            existing.* = p;
            return;
        }
    }
    try properties.append(arena, p);
}

/// The members of an interface or object type.
fn members(this: *Checker, list: []const ast.TypeMember) Error![]const types.Property {
    var properties: std.ArrayList(types.Property) = .empty;
    // Where each property is declared, and whether a duplicate of it has been reported there.
    var starts: std.ArrayList(struct { u32, bool }) = .empty;
    for (list) |m| {
        var t = types.any;
        if (m.type) |node| {
            if (m.method and node.data.function.returns == null) {
                try this.report(m.start, .ts(7010), "'{s}', which lacks return-type annotation, implicitly has an 'any' return type.", .{m.name});
            }
            t = try this.resolveType(node);
        } else {
            try this.report(m.start, .ts(7008), "Member '{s}' implicitly has an 'any' type.", .{m.name});
        }
        if (m.optional) {
            t = try types.unionOf(this.arena, &.{ t, types.undefined });
        }
        const duplicate = for (properties.items, 0..) |p, i| {
            if (std.mem.eql(u8, p.name, m.name)) {
                break i;
            }
        } else null;
        if (duplicate) |i| {
            const first = properties.items[i];
            if (m.method and first.method) {
                try this.unsupported(m.start, "Method overloads are not supported yet.", .{});
                continue;
            }
            if (!starts.items[i][1]) {
                starts.items[i][1] = true;
                try this.report(starts.items[i][0], .ts(2300), "Duplicate identifier '{s}'.", .{m.name});
            }
            try this.report(m.start, .ts(2300), "Duplicate identifier '{s}'.", .{m.name});
            if (!first.type.eql(t)) {
                try this.report(m.start, .ts(2717), "Subsequent property declarations must have the same type.  Property '{s}' must be of type '{f}', but here has type '{f}'.", .{ m.name, first.type, t });
            }
            continue;
        }
        try properties.append(this.arena, .{ .name = m.name, .type = t, .optional = m.optional, .readonly = m.readonly, .method = m.method });
        try starts.append(this.arena, .{ m.start, false });
    }
    return properties.items;
}

/// Names of types the standard library has, which aren't supported yet.
const library_types = std.StaticStringMap(void).initComptime(.{
    .{"Omit"},         .{"Exclude"},      .{"Extract"},              .{"NonNullable"},      .{"ReturnType"},
    .{"Parameters"},   .{"InstanceType"}, .{"Awaited"},              .{"Number"},           .{"String"},
    .{"Boolean"},      .{"Object"},       .{"Function"},             .{"Symbol"},           .{"BigInt"},
    .{"Map"},          .{"Set"},          .{"WeakMap"},              .{"WeakSet"},          .{"Error"},
    .{"TypeError"},    .{"RangeError"},   .{"ReferenceError"},       .{"SyntaxError"},      .{"Promise"},
    .{"PromiseLike"},  .{"Date"},         .{"RegExp"},               .{"Math"},             .{"JSON"},
    .{"Console"},      .{"Iterable"},     .{"Iterator"},             .{"IterableIterator"}, .{"ArrayLike"},
    .{"PropertyKey"},  .{"Uppercase"},    .{"Lowercase"},            .{"Capitalize"},       .{"Uncapitalize"},
    .{"ThisType"},     .{"NoInfer"},      .{"IArguments"},           .{"Generator"},        .{"ArrayBuffer"},
    .{"object"},       .{"symbol"},       .{"bigint"},               .{"Int8Array"},        .{"Uint8Array"},
    .{"Float64Array"}, .{"DataView"},     .{"TemplateStringsArray"},
});

/// A type name in an annotation, with its type arguments.
fn resolveReference(this: *Checker, at: u32, reference: ast.TypeReference) Error!*const Type {
    const name = reference.name;
    const found = this.lookupType(name);
    const arguments = try this.arena.alloc(*const Type, reference.arguments.len);
    {
        // A type alias's type arguments are resolved with it, anything else's lazily.
        const deferred = @intFromBool(found == null or found.?.node != .alias);
        this.deferred += deferred;
        defer this.deferred -= deferred;
        for (reference.arguments, arguments) |node, *t| {
            t.* = try this.resolveType(node);
        }
    }
    if (found) |decl| {
        const t = try this.resolveDecl(decl);
        if (decl.circular) {
            if (arguments.len > 0) {
                // tsc gives a circular alias an error type, which isn't generic.
                try this.report(at, .ts(2315), "Type '{s}' is not generic.", .{name});
            }
            return types.any;
        }
        const parameters = decl.typeParameters();
        if (parameters.len == 0) {
            if (arguments.len > 0) {
                try this.report(at, .ts(2315), "Type '{s}' is not generic.", .{name});
            }
            return t;
        }
        const filled = try this.typeArguments(at, decl.name, decl.parameters, arguments, reference.arguments) orelse return types.any;
        const instance = try this.instantiateDecl(decl, filled);
        if (instance.* == .mapped and !types.isGeneric(instance.mapped.constraint)) {
            // `Record<string, T>` is an index signature.
            try this.unsupported(at, "Mapping over the keys '{f}' is not supported yet.", .{instance.mapped.constraint});
            return types.any;
        }
        return instance;
    }
    if (std.mem.eql(u8, name, "Array") or std.mem.eql(u8, name, "ReadonlyArray")) {
        if (arguments.len != 1) {
            try this.report(at, .ts(2314), "Generic type '{s}<T>' requires 1 type argument(s).", .{name});
            return types.any;
        }
        return this.newType(if (name[0] == 'A') .{ .array = arguments[0] } else .{ .readonly_array = arguments[0] });
    }
    if (library_types.has(name)) {
        try this.unsupported(at, "The type '{s}' is not supported yet.", .{name});
    } else if (this.lookup(name) != null or global(name) != null) {
        try this.report(at, .ts(2749), "'{s}' refers to a value, but is being used as a type here. Did you mean 'typeof {s}'?", .{ name, name });
    } else {
        try this.report(at, .ts(2304), "Cannot find name '{s}'.", .{name});
    }
    return types.any;
}

/// The type arguments `arguments` give `parameters`, with defaults for the ones left out, after
/// checking there are as many as there should be (TS2314) and that they satisfy their
/// constraints (TS2344). Null if there aren't.
fn typeArguments(this: *Checker, at: u32, name: []const u8, parameters: []const *const Type, arguments: []const *const Type, nodes: []const *const ast.TypeNode) Error!?[]const *const Type {
    var required: usize = 0;
    for (parameters, 0..) |p, i| {
        if (p.param.default == null) {
            required = i + 1;
        }
    }
    if (arguments.len < required or arguments.len > parameters.len) {
        var list: std.Io.Writer.Allocating = .init(this.arena);
        for (parameters, 0..) |p, i| {
            list.writer.print("{s}{s}", .{ if (i > 0) ", " else "", p.param.name }) catch return error.OutOfMemory;
        }
        if (required == parameters.len) {
            try this.report(at, .ts(2314), "Generic type '{s}<{s}>' requires {d} type argument(s).", .{ name, list.written(), required });
        } else {
            try this.report(at, .ts(2707), "Generic type '{s}<{s}>' requires between {d} and {d} type arguments.", .{ name, list.written(), required, parameters.len });
        }
        return null;
    }
    const filled = try this.arena.alloc(*const Type, parameters.len);
    @memcpy(filled[0..arguments.len], arguments);
    for (filled[arguments.len..], arguments.len..) |*t, i| {
        t.* = try this.instantiate(parameters[i].param.default.?, parameters[0..i], filled[0..i]);
    }
    for (parameters, filled, 0..) |p, t, i| {
        const c = p.param.constraint orelse continue;
        const constraint = try this.instantiate(c, parameters, filled);
        try this.checkConstraint(.{ .at = if (i < nodes.len) nodes[i].start else at, .argument = t, .constraint = constraint });
    }
    return filled;
}

/// Reports a type argument that doesn't satisfy its constraint, once the declarations being
/// resolved are.
fn checkConstraint(this: *Checker, c: ConstraintCheck) Error!void {
    if (this.resolving_decls.items.len > 0) {
        return this.constraint_checks.append(this.arena, c);
    }
    try this.reportConstraint(c);
}

fn reportConstraint(this: *Checker, c: ConstraintCheck) Error!void {
    if (!types.assignable(c.argument, c.constraint)) {
        try this.report(c.at, .ts(2344), "Type '{f}' does not satisfy the constraint '{f}'.", .{ c.argument, c.constraint });
    }
}

fn newType(this: *Checker, t: Type) Error!*const Type {
    const p = try this.arena.create(Type);
    p.* = t;
    return p;
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
    if (v.destructured) |d| {
        // Work out the whole pattern's types, as its declaration will.
        const saved = this.flow;
        defer this.flow = saved;
        this.flow = try this.copyFlow(saved);
        v.resolving = true;
        defer v.resolving = false;
        try this.lazy.append(this.arena, slot);
        defer _ = this.lazy.pop();
        const t = try this.declaratorType(d);
        _ = try this.bindPattern(d.pattern.?, t, .{ .widen = v.kind == .let, .annotated = d.type != null });
        return this.variable(slot).declared orelse types.any;
    }
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
    const deferred = @intFromBool(node.data != .reference);
    this.deferred += deferred;
    defer this.deferred -= deferred;
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
        .reference => |r| this.resolveReference(node.start, r),
        .keyof => |operand| blk: {
            const t = try this.resolveType(operand);
            break :blk try types.keyOf(this.arena, t) orelse {
                try this.unsupported(node.start, "'keyof {f}' is not supported yet.", .{t});
                break :blk types.string_or_number;
            };
        },
        .readonly => |operand| blk: {
            const t = try this.resolveType(operand);
            break :blk switch (t.*) {
                .array => |e| this.newType(.{ .readonly_array = e }),
                else => t,
            };
        },
        .indexed => |i| this.indexedType(i),
        .query => |q| this.typeQuery(node.start, q),
        .mapped => |m| this.mappedType(node.start, m),
        .literal => |l| types.literal(this.arena, switch (l) {
            .number => |n| .{ .number = n },
            .string => |str| .{ .string = str },
            .boolean => |b| .{ .boolean = b },
        }),
        .@"union" => |ms| blk: {
            const resolved = try this.arena.alloc(*const Type, ms.len);
            for (ms, resolved) |m, *t| {
                t.* = try this.resolveType(m);
            }
            break :blk types.unionOf(this.arena, resolved);
        },
        .array => |element| this.newType(.{ .array = try this.resolveType(element) }),
        .tuple => |elements| blk: {
            const resolved = try this.arena.alloc(*const Type, elements.len);
            for (elements, resolved) |e, *t| {
                t.* = try this.resolveType(e);
            }
            break :blk this.newType(.{ .tuple = resolved });
        },
        .object => |list| blk: {
            const object = try this.arena.create(types.Object);
            object.* = .{ .properties = try this.members(list) };
            break :blk this.newType(.{ .object = object });
        },
        .function => |f| blk: {
            var type_parameters: []const *const Type = &.{};
            const saved_scope = this.scope;
            defer this.scope = saved_scope;
            if (f.type_parameters.len > 0) {
                try this.pushScope(null, .block);
                type_parameters = try this.declareTypeParameters(f.type_parameters);
            }
            var parameters: std.ArrayList(types.Parameter) = .empty;
            var rest: ?types.Parameter = null;
            for (f.parameters) |p| {
                var t = types.any;
                if (p.type) |annotation| {
                    t = try this.resolveType(annotation);
                    if (p.rest and t.* != .array and t.* != .readonly_array and t.* != .any) {
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
            function.* = .{ .type_parameters = type_parameters, .parameters = parameters.items, .rest = rest, .returns = if (f.returns) |r| try this.resolveType(r) else types.any };
            const t = try this.arena.create(Type);
            t.* = .{ .function = function };
            break :blk t;
        },
    };
}

/// `T[K]`
fn indexedType(this: *Checker, i: ast.TypeNode.Indexed) Error!*const Type {
    const object = try this.resolveType(i.object);
    const index = try this.resolveType(i.index);
    if (object.* == .any or index.* == .any) {
        return types.any;
    }
    if (types.isGeneric(object) or types.isGeneric(index)) {
        // It has to be one of the keys `T` is known to have.
        const keys = try types.keyOf(this.arena, object) orelse types.never;
        if (!types.assignable(index, keys)) {
            try this.report(i.index.start, .ts(2536), "Type '{f}' cannot be used to index type '{f}'.", .{ index, object });
            return types.any;
        }
    }
    return try types.indexedAccess(this.arena, object, index, &this.mapper(&.{}, &.{})) orelse {
        if (try types.keyName(this.arena, index)) |name| {
            if (index.literal.value == .string or object.* != .tuple) {
                try this.report(i.index.start, .ts(2339), "Property '{s}' does not exist on type '{f}'.", .{ name, object });
            } else {
                try this.report(i.index.start, .ts(2493), "Tuple type '{f}' of length '{d}' has no element at index '{s}'.", .{ object, object.tuple.len, name });
            }
        } else {
            try this.report(i.index.start, .ts(2536), "Type '{f}' cannot be used to index type '{f}'.", .{ index, object });
        }
        return types.any;
    };
}

/// `typeof x` and `typeof x.y`: the type the variable has here.
fn typeQuery(this: *Checker, at: u32, q: ast.TypeNode.Query) Error!*const Type {
    var t: *const Type = undefined;
    if (this.lookup(q.name)) |slot| {
        t = try this.declaredType(slot);
        if (this.flow.reachable and this.variable(slot).kind != .function) {
            if (this.flow.vars[slot].type) |narrowed| {
                t = narrowed;
            }
        }
    } else if (global(q.name)) |g| {
        t = g;
    } else {
        try this.report(at + @as(u32, "typeof ".len), .ts(2304), "Cannot find name '{s}'.", .{q.name});
        return types.any;
    }
    for (q.path) |name| {
        const object = try this.removeNullish(t);
        t = if (try this.property(object, name, at)) |access| access.type else {
            try this.report(at, .ts(2339), "Property '{s}' does not exist on type '{f}'.", .{ name, object });
            return types.any;
        };
    }
    return types.regular(this.arena, t);
}

/// `{ [P in K]: X }`
fn mappedType(this: *Checker, at: u32, m: *const ast.TypeNode.Mapped) Error!*const Type {
    // `[P in keyof T]` is homomorphic: it keeps the modifiers of `T`'s properties.
    var source: ?*const Type = null;
    var constraint: *const Type = undefined;
    if (m.constraint.data == .keyof) {
        const operand = try this.resolveType(m.constraint.data.keyof);
        source = operand;
        constraint = try types.keyOf(this.arena, operand) orelse {
            try this.unsupported(m.constraint.start, "'keyof {f}' is not supported yet.", .{operand});
            return types.any;
        };
    } else {
        constraint = try this.resolveType(m.constraint);
    }
    if (constraint.* == .any) {
        return types.any;
    }
    if (!types.isGeneric(constraint) and !types.assignable(constraint, types.string_or_number)) {
        try this.report(m.constraint.start, .ts(2322), "Type '{f}' is not assignable to type 'string | number | symbol'.", .{constraint});
        return types.any;
    }
    const saved_scope = this.scope;
    defer this.scope = saved_scope;
    try this.pushScope(null, .block);
    const parameter = (try this.declareTypeParameters(&.{m.parameter}))[0];
    @constCast(parameter.param).constraint = constraint;
    const template = if (m.type) |node| try this.resolveType(node) else blk: {
        try this.report(at, .ts(7008), "Member '[{s} in {f}]' implicitly has an 'any' type.", .{ m.parameter.name, constraint });
        break :blk types.any;
    };
    const mapped = try this.arena.create(types.Mapped);
    mapped.* = .{
        .parameter = parameter,
        .constraint = constraint,
        .template = template,
        .optional = @fromBackingInt(@intCast(@backingInt(m.optional))),
        .readonly = @fromBackingInt(@intCast(@backingInt(m.readonly))),
        .source = source,
    };
    const t = try types.resolveMapped(this.arena, mapped, &this.mapper(&.{}, &.{}));
    if (t.* == .mapped and !types.isGeneric(constraint)) {
        try this.unsupported(m.constraint.start, "Mapping over the keys '{f}' is not supported yet.", .{constraint});
        return types.any;
    }
    return t;
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

// Statements

fn statement(this: *Checker, stmt: *const Stmt) Error!void {
    try this.labeledStatement(stmt, &.{});
}

/// `labels` are the labels directly on this statement, which `break` and `continue` can name.
fn labeledStatement(this: *Checker, stmt: *const Stmt, labels: []const []const u8) Error!void {
    switch (stmt.data) {
        .@"while", .do_while, .@"for", .for_each => return this.loop(stmt, labels),
        .@"switch" => |sw| return this.switchStatement(sw, labels),
        .labeled => |l| return this.labeled(stmt, l, labels),
        else => {},
    }
    if (labels.len > 0) {
        try this.targets.append(this.arena, .{ .kind = .label, .labels = labels });
    }
    switch (stmt.data) {
        .expression => |e| {
            _ = try this.expression(e);
            if (this.isNeverCall(e)) {
                this.flow = .unreachable_flow;
            }
        },
        .throw => |e| {
            _ = try this.expression(e);
            this.flow = .unreachable_flow;
        },
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
        .interface, .type_alias => if (this.type_decls.get(stmt)) |decl| {
            _ = try this.resolveDecl(decl);
        },
        .@"while", .do_while, .@"for", .for_each, .@"switch", .labeled => unreachable,
    }
    if (labels.len > 0) {
        const target = this.targets.pop().?;
        try this.mergeInto(&this.flow, target.breaks);
    }
}

/// tsc's rule for calls that never return: a call of a function whose declared (not inferred) type
/// returns `never` ends the code path, as a `throw` would.
fn isNeverCall(this: *const Checker, expr: *const Expr) bool {
    const e = ast.skipParens(expr);
    if (e.data != .call) {
        return false;
    }
    const callee = ast.skipParens(e.data.call.callee);
    if (callee.data != .identifier) {
        return false;
    }
    const ref = this.refs[callee.data.identifier.ref];
    if (ref != .slot) {
        return false;
    }
    const v = this.session.variables.items[ref.slot];
    const t = v.declared orelse return false;
    if (t.* != .function or t.function.returns.* != .never) {
        return false;
    }
    return switch (v.kind) {
        .function => v.function.?.returns != null,
        .let, .@"const", .parameter => v.annotation != null,
    };
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
    for (v.declarators) |*d| {
        if (d.pattern) |pattern| {
            const bindings = try pattern.bindings(this.arena);
            for (bindings) |b| {
                this.variable(this.slot_base + b.binding).resolving = d.type == null;
            }
            const t = try this.declaratorType(d);
            for (bindings) |b| {
                this.variable(this.slot_base + b.binding).resolving = false;
            }
            _ = try this.bindPattern(pattern, t, .{ .widen = v.kind == .let, .annotated = d.type != null });
            continue;
        }
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
                try this.checkAssignable(init, init_type, declared, d.start, .assignment);
            } else if (variable_.circular) {
                declared = types.any;
            } else if (v.kind == .let and isNullOrUndefined(init)) {
                try this.unsupported(d.start, "A 'let' without a type annotation, initialized to 'null' or 'undefined', is not supported yet.", .{});
            } else if (isEmptyArray(init)) {
                try this.unsupported(d.start, "A variable without a type annotation, initialized to an empty array, is not supported yet.", .{});
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
            try this.forgetPaths(.{ .slot = slot });
        }
    }
}

/// The type a destructuring declaration destructures: its annotation's, or its initializer's.
fn declaratorType(this: *Checker, d: *const ast.Declarator) Error!*const Type {
    const annotated = if (d.type) |annotation| try this.resolveType(annotation) else null;
    const init = d.init orelse return annotated orelse types.any;
    const t = annotated orelse return this.patternInitializer(init, d.pattern.?);
    const init_type = try this.contextual(init, t);
    try this.checkAssignable(init, init_type, t, d.start, .assignment);
    return t;
}

/// The type a pattern gives the literal it destructures. An array pattern makes an array literal
/// a tuple: `const [a, b] = [1, "x"]` makes `a` a number and `b` a string.
fn patternContext(this: *Checker, pattern: *const ast.Pattern) Error!?*const Type {
    switch (pattern.data) {
        .identifier => return null,
        .object => |o| {
            // A rest element takes whatever else there is.
            if (o.rest != null) {
                return null;
            }
            var properties: std.ArrayList(types.Property) = .empty;
            for (o.properties) |p| {
                try putProperty(this.arena, &properties, .{ .name = p.key, .type = try this.patternContext(p.value) orelse types.any });
            }
            const object = try this.arena.create(types.Object);
            object.* = .{ .properties = properties.items };
            return try this.newType(.{ .object = object });
        },
        .array => |a| {
            if (a.rest != null) {
                return null;
            }
            const elements = try this.arena.alloc(*const Type, a.elements.len);
            for (a.elements, elements) |element, *t| {
                t.* = types.any;
                if (element) |e| {
                    t.* = try this.patternContext(e.pattern) orelse types.any;
                }
            }
            return try this.newType(.{ .tuple = elements });
        },
    }
}

/// The type of the value a pattern without a type annotation destructures. Like tsc, an object
/// literal there can't have properties the pattern doesn't name (TS2353).
fn patternInitializer(this: *Checker, init: *const Expr, pattern: *const ast.Pattern) Error!*const Type {
    const context = try this.patternContext(pattern);
    const t = try this.contextual(init, context);
    if (context) |c| {
        _ = try this.excessProperty(init, c);
    }
    return t;
}

/// How a pattern's names get their types.
const BindMode = struct {
    /// Literal types are widened, as for `let` and parameters.
    widen: bool,
    /// The declaration has a type annotation, which default values are checked against.
    annotated: bool,
};

/// Gives the names in a destructuring pattern their types, from a value of type `source`, and
/// returns `source`. With no `source` (a parameter without a type), each name gets its default
/// value's type, or else `any` (TS7031), and what's returned is the type the pattern implies.
fn bindPattern(this: *Checker, pattern: *const ast.Pattern, source: ?*const Type, mode: BindMode) Error!*const Type {
    switch (pattern.data) {
        .identifier => |b| return this.bindName(b, source, mode),
        .object => |o| {
            var implied: std.ArrayList(types.Property) = .empty;
            for (o.properties) |p| {
                var t: ?*const Type = null;
                if (source) |s| {
                    t = types.any;
                    if (try this.property(s, p.key, p.key_start)) |access| {
                        t = access.type;
                    } else if (p.init != null) {
                        // A property with a default value can be missing.
                        t = types.undefined;
                    } else {
                        try this.report(p.key_start, .ts(2339), "Property '{s}' does not exist on type '{f}'.", .{ p.key, s });
                    }
                }
                t = try this.withDefault(p.init, t, mode, p.key_start);
                const bound = try this.bindPattern(p.value, t, mode);
                if (source == null) {
                    const optional = p.init != null;
                    try putProperty(this.arena, &implied, .{ .name = p.key, .type = if (optional) try types.unionOf(this.arena, &.{ bound, types.undefined }) else bound, .optional = optional });
                }
            }
            if (o.rest) |r| {
                _ = try this.bindName(r, if (source) |s| try this.objectRest(s, o, r.start) else types.any, mode);
            }
            if (source) |s| {
                return s;
            }
            const object = try this.arena.create(types.Object);
            object.* = .{ .properties = implied.items };
            return this.newType(.{ .object = object });
        },
        .array => |a| {
            var from = source;
            if (source) |s| {
                if (!try this.checkIterable(s, pattern.start, "Destructuring a string")) {
                    from = types.any;
                }
            }
            var implied: std.ArrayList(*const Type) = .empty;
            for (a.elements, 0..) |element, i| {
                const e = element orelse {
                    try implied.append(this.arena, types.any);
                    continue;
                };
                var t: ?*const Type = null;
                if (from) |s| {
                    t = try this.elementOf(s, i, e.pattern.start, e.init != null);
                }
                t = try this.withDefault(e.init, t, mode, e.pattern.start);
                try implied.append(this.arena, try this.bindPattern(e.pattern, t, mode));
            }
            if (a.rest) |r| {
                _ = try this.bindPattern(r, if (from) |s| try this.arrayRest(s, a.elements.len) else types.any_array, mode);
            }
            if (source) |s| {
                return s;
            }
            if (a.rest != null) {
                return types.any_array;
            }
            return this.newType(.{ .tuple = implied.items });
        },
    }
}

/// Gives one name in a pattern its type, and returns the type it's declared with.
fn bindName(this: *Checker, b: ast.Binding, source: ?*const Type, mode: BindMode) Error!*const Type {
    const t = source orelse blk: {
        try this.report(b.start, .ts(7031), "Binding element '{s}' implicitly has an 'any' type.", .{b.name});
        break :blk types.any;
    };
    const slot = this.slot_base + b.binding;
    const v = this.variable(slot);
    const declared = if (v.circular) types.any else if (mode.widen) try types.widenFresh(this.arena, t) else t;
    v.declared = declared;
    if (this.flow.reachable) {
        this.flow.vars[slot] = .{ .initialized = true, .type = try this.assignmentReduced(declared, t) };
        try this.forgetPaths(.{ .slot = slot });
    }
    return declared;
}

/// tsc's `getBindingElementTypeFromParentType`: with a default value, a destructured value is
/// never `undefined`. Under a type annotation the default has to match the annotation; without
/// one it adds its own type. With no type to start from, it's the default's type.
fn withDefault(this: *Checker, init: ?*const Expr, t: ?*const Type, mode: BindMode, at: u32) Error!?*const Type {
    const e = init orelse return t;
    const expected = if (t) |x| try this.removeUndefined(x) else null;
    const default = try this.contextual(e, expected);
    const target = expected orelse return try types.widenFresh(this.arena, default);
    if (mode.annotated) {
        try this.checkAssignable(e, default, target, at, .assignment);
        return if (types.includesUndefined(default)) t else target;
    }
    return try types.unionOf(this.arena, &.{ target, default });
}

fn removeUndefined(this: *Checker, t: *const Type) Error!*const Type {
    var kept: std.ArrayList(*const Type) = .empty;
    var buffer: [1]*const Type = undefined;
    for (t.members(&buffer)) |m| {
        if (m.* != .undefined) {
            try kept.append(this.arena, m);
        }
    }
    return types.unionOf(this.arena, kept.items);
}

/// Whether `t` can be iterated (spread, destructured with `[...]` or looped over with
/// `for...of`), reporting it if not. `what` names a use of a string, which isn't supported yet.
fn checkIterable(this: *Checker, t: *const Type, at: u32, comptime what: []const u8) Error!bool {
    var buffer: [1]*const Type = undefined;
    for (t.members(&buffer)) |m| {
        switch (m.*) {
            .any, .never, .array, .tuple, .readonly_array => {},
            else => {
                if (types.isStringLike(m)) {
                    try this.unsupported(at, what ++ " is not supported yet.", .{});
                } else {
                    try this.report(at, .ts(2488), "Type '{f}' must have a '[Symbol.iterator]()' method that returns an iterator.", .{t});
                }
                return false;
            },
        }
    }
    return true;
}

/// The type of the element at `index` when a value of type `t` (an iterable) is destructured.
/// An element with a default value can be past the end of a tuple.
fn elementOf(this: *Checker, t: *const Type, index: usize, at: u32, has_default: bool) Error!*const Type {
    var parts: std.ArrayList(*const Type) = .empty;
    var buffer: [1]*const Type = undefined;
    for (t.members(&buffer)) |m| {
        try parts.append(this.arena, switch (m.*) {
            .array, .readonly_array => |e| e,
            .tuple => |es| if (index < es.len) es[index] else if (has_default) types.undefined else blk: {
                try this.report(at, .ts(2493), "Tuple type '{f}' of length '{d}' has no element at index '{d}'.", .{ m, es.len, index });
                break :blk types.undefined;
            },
            else => m,
        });
    }
    return types.unionOf(this.arena, parts.items);
}

/// The type of `...rest` in an array pattern, after `from` elements.
fn arrayRest(this: *Checker, t: *const Type, from: usize) Error!*const Type {
    return switch (t.*) {
        .array => t,
        .readonly_array => |e| this.newType(.{ .array = e }),
        .tuple => |es| this.newType(.{ .tuple = es[@min(from, es.len)..] }),
        else => types.any,
    };
}

/// The type of `...rest` in an object pattern: the properties the pattern doesn't name.
fn objectRest(this: *Checker, t: *const Type, pattern: ast.ObjectPattern, at: u32) Error!*const Type {
    switch (t.*) {
        .any => return types.any,
        .object => |o| {
            var kept: std.ArrayList(types.Property) = .empty;
            for (o.properties) |p| {
                const named = for (pattern.properties) |q| {
                    if (std.mem.eql(u8, q.key, p.name)) {
                        break true;
                    }
                } else false;
                if (!named) {
                    var copy = p;
                    copy.method = false;
                    try kept.append(this.arena, copy);
                }
            }
            const object = try this.arena.create(types.Object);
            object.* = .{ .properties = kept.items };
            return this.newType(.{ .object = object });
        },
        else => {
            try this.unsupported(at, "A rest element destructuring '{f}' is not supported yet.", .{t});
            return types.any;
        },
    }
}

fn isEmptyArray(expr: *const Expr) bool {
    const e = ast.skipParens(expr);
    return e.data == .array and e.data.array.elements.len == 0;
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
    // What a `for...of` or `for...in` assigns on each pass.
    var element = types.any;
    if (stmt.data == .for_each) {
        const fe = stmt.data.for_each;
        try this.pushScope(fe.scope, .block);
        scoped = true;
        if (fe.head == .declaration) {
            const d = fe.head.declaration;
            if (!fe.of and d.pattern.data != .identifier) {
                try this.report(d.pattern.start, .ts(2491), "The left-hand side of a 'for...in' statement cannot be a destructuring pattern.", .{});
            }
            try this.declarePattern(d.pattern, if (d.kind == .let) .let else .@"const", d.end, null);
        }
        const right = try this.expression(fe.right);
        element = if (fe.of) try this.iterationType(fe.right, right) else try this.forInType(fe.right, right);
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
            .for_each => |fe| {
                // It finishes from the head, once there's nothing left.
                exit = try this.copyFlow(this.flow);
                try this.assignHead(fe, element);
                try this.body(fe.body);
                try this.mergeInto(&this.flow, this.targets.items[this.targets.items.len - 1].continues);
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

/// The type of the values a `for...of` loops over.
fn iterationType(this: *Checker, expr: *const Expr, t: *const Type) Error!*const Type {
    const iterable = try this.checkNonNull(expr, t);
    if (!try this.checkIterable(iterable, expr.start, "Iterating over a string")) {
        return types.any;
    }
    var parts: std.ArrayList(*const Type) = .empty;
    var buffer: [1]*const Type = undefined;
    for (iterable.members(&buffer)) |m| {
        switch (m.*) {
            .array, .readonly_array => |e| try parts.append(this.arena, e),
            .tuple => |es| try parts.appendSlice(this.arena, es),
            else => try parts.append(this.arena, m),
        }
    }
    return types.unionOf(this.arena, parts.items);
}

/// A `for...in` loops over property names, so its right side has to be an object.
fn forInType(this: *Checker, expr: *const Expr, t: *const Type) Error!*const Type {
    if (!isObjectType(t)) {
        try this.report(expr.start, .ts(2407), "The right-hand side of a 'for...in' statement must be of type 'any', an object type or a type parameter, but here has type '{f}'.", .{t});
    }
    return types.string;
}

/// Whether every member of `t` is an object (or `any`), as `in` and `for...in` require.
fn isObjectType(t: *const Type) bool {
    var buffer: [1]*const Type = undefined;
    for (t.members(&buffer)) |m| {
        switch (m.*) {
            .any, .never, .object, .array, .tuple, .readonly_array, .function => {},
            else => return false,
        }
    }
    return true;
}

/// Assigns the value a `for...of` or `for...in` is at to the variables in its head.
fn assignHead(this: *Checker, fe: ast.ForEach, element: *const Type) Error!void {
    switch (fe.head) {
        // A pattern in a `for...in` is already an error (TS2491).
        .declaration => |d| _ = try this.bindPattern(d.pattern, if (fe.of or d.pattern.data == .identifier) element else types.any, .{ .widen = d.kind == .let, .annotated = false }),
        .target => |e| {
            const target = ast.skipParens(e);
            switch (target.data) {
                .identifier => |id| {
                    const r = try this.resolve(target, id);
                    const slot = try this.writeTarget(target, id, r) orelse return;
                    const declared = try this.declaredType(slot);
                    if (!types.assignable(element, declared)) {
                        try this.notAssignable(target.start, element, declared);
                    }
                    try this.setVariable(slot, try this.assignmentReduced(declared, element));
                },
                .array, .object => try this.unsupported(target.start, "Destructuring assignments are not supported yet.", .{}),
                .member, .index => try this.unsupported(target.start, "A 'for...{s}' statement that assigns to a property is not supported yet.", .{if (fe.of) "of" else "in"}),
                else => if (fe.of)
                    try this.report(target.start, .ts(2487), "The left-hand side of a 'for...of' statement must be a variable or a property access.", .{})
                else
                    try this.report(target.start, .ts(2406), "The left-hand side of a 'for...in' statement must be a variable or a property access.", .{}),
            }
        },
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
    // The case values, for each clause; null for `default`.
    var clause_types: std.ArrayList(?*const Type) = .empty;
    var case_types: std.ArrayList(*const Type) = .empty;
    var has_default = false;
    for (sw.clauses) |clause| {
        const case = clause.case orelse {
            if (has_default) {
                try this.report(clause.start, .ts(1113), "A 'default' clause cannot appear more than once in a 'switch' statement.", .{});
            }
            has_default = true;
            try clause_types.append(this.arena, null);
            continue;
        };
        const t = try this.expression(case);
        try clause_types.append(this.arena, t);
        try case_types.append(this.arena, t);
        if (!types.comparable(discriminant, t)) {
            try this.report(case.start, .ts(2678), "Type '{f}' is not comparable to type '{f}'.", .{ try this.shownSource(t, discriminant), discriminant });
        }
    }
    const entry = try this.copyFlow(this.flow);
    // When no case matches, the switch finishes from its head, unless the cases cover everything.
    const falls_out = !has_default and !try this.exhaustive(sw.discriminant, discriminant, case_types.items);
    try this.targets.append(this.arena, .{ .kind = .@"switch", .labels = labels });
    var fallthrough: Flow = .unreachable_flow;
    for (sw.clauses, clause_types.items) |clause, case_type| {
        // A clause is entered from the switch's head, narrowed by its case, or by falling through
        // from the one before.
        this.flow = try this.copyFlow(entry);
        try this.narrowClause(sw.discriminant, case_type, case_types.items);
        try this.mergeInto(&this.flow, fallthrough);
        for (clause.statements) |s| {
            try this.statement(s);
        }
        fallthrough = this.flow;
    }
    const target = this.targets.pop().?;
    this.flow = fallthrough;
    try this.mergeInto(&this.flow, target.breaks);
    if (falls_out) {
        var rest = try this.copyFlow(entry);
        std.mem.swap(Flow, &this.flow, &rest);
        try this.narrowClause(sw.discriminant, null, case_types.items);
        std.mem.swap(Flow, &this.flow, &rest);
        try this.mergeInto(&this.flow, rest);
    }
}

/// Narrows the switch's discriminant (or what `typeof` looks at, in `switch (typeof x)`) for a
/// clause: to its case value, or for `default` (null) to what none of the cases match.
fn narrowClause(this: *Checker, discriminant: *const Expr, case: ?*const Type, cases: []const *const Type) Error!void {
    const d = ast.skipParens(discriminant);
    const typeof_operand: ?*const Expr = if (d.data == .unary and d.data.unary.op == .typeof) d.data.unary.operand else null;
    var one: [1]*const Type = undefined;
    const tested: []const *const Type = if (case) |c| blk: {
        one[0] = c;
        break :blk &one;
    } else cases;
    for (tested) |c| {
        if (typeof_operand) |operand| {
            if (c.* == .literal and c.literal.value == .string) {
                try this.narrowReference(operand, .{ .typeof = c.literal.value.string }, case != null);
            }
        } else {
            try this.narrowReference(discriminant, .{ .equal = .{ .value = c } }, case != null);
        }
    }
}

/// tsc's `isExhaustiveSwitchStatement`: the discriminant is a union of literals, and every one of
/// them has a case; or it's `typeof x`, and every type `x` can have has a case.
fn exhaustive(this: *Checker, expr: *const Expr, discriminant: *const Type, cases: []const *const Type) Error!bool {
    const d = ast.skipParens(expr);
    if (d.data == .unary and d.data.unary.op == .typeof) {
        var t = try this.typeOf(d.data.unary.operand);
        for (cases) |c| {
            if (c.* == .literal and c.literal.value == .string) {
                t = try narrowing.narrow(this.arena, t, .{ .typeof = c.literal.value.string }, false) orelse return false;
            }
        }
        return t.* == .never;
    }
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
    return if (types.couldHaveSingletons(target) or !types.isLiteralType(source)) source else types.widen(this.arena, source);
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
    if (this.aliased > 0) {
        // An aliased condition's initializer, checked again where it's tested: its names still
        // mean what they did where it's declared, which is also what the interpreter reads.
        const ref = this.refs[id.ref];
        return .{ .slot = if (ref == .slot) ref.slot else null };
    }
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
            if (p.pattern) |destructured| {
                this.pattern(destructured, null, nested);
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
                if (d.pattern) |p| {
                    this.pattern(p, outer, nested);
                }
            },
            .function => |f| this.function(f, true),
            .interface, .type_alias => {},
            .throw => |e| this.expr(e, outer, nested),
            .for_each => |f| {
                switch (f.head) {
                    .declaration => |d| this.pattern(d.pattern, outer, nested),
                    .target => |e| {
                        this.target(e, outer, nested);
                        this.expr(e, outer, nested);
                    },
                }
                this.expr(f.right, outer, nested);
                this.statement(f.body, outer, nested);
            },
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

    /// The default values in a pattern.
    fn pattern(this: *AssignmentScan, p: *const ast.Pattern, outer: ?u32, nested: bool) void {
        switch (p.data) {
            .identifier => {},
            .object => |o| for (o.properties) |prop| {
                this.pattern(prop.value, outer, nested);
                if (prop.init) |init| {
                    this.expr(init, outer, nested);
                }
            },
            .array => |a| {
                for (a.elements) |element| {
                    const e = element orelse continue;
                    this.pattern(e.pattern, outer, nested);
                    if (e.init) |init| {
                        this.expr(init, outer, nested);
                    }
                }
                if (a.rest) |r| {
                    this.pattern(r, outer, nested);
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
            .paren, .chain, .non_null => |inner| this.expr(inner, outer, nested),
            .assertion => |a| this.expr(a.expr, outer, nested),
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
            .index => |i| {
                this.expr(i.object, outer, nested);
                this.expr(i.index, outer, nested);
            },
            .call => |c| {
                this.expr(c.callee, outer, nested);
                for (c.arguments) |arg| {
                    this.expr(arg, outer, nested);
                }
            },
            .function => |f| this.function(f, true),
            .object => |o| for (o.properties) |p| switch (p) {
                .property => |prop| {
                    if (prop.key == .computed) {
                        this.expr(prop.key.computed, outer, nested);
                    }
                    this.expr(prop.value, outer, nested);
                },
                .spread => |spread| this.expr(spread.expr, outer, nested),
            },
            .array => |a| for (a.elements) |element| switch (element) {
                .expr, .spread => |x| this.expr(x, outer, nested),
            },
        }
    }
};

// Expressions

fn expression(this: *Checker, expr: *const Expr) Error!*const Type {
    if (this.const_context and !keepsConstContext(expr)) {
        // Only literals directly inside `as const` are in its context.
        this.const_context = false;
        defer this.const_context = true;
        return this.expressionOf(expr);
    }
    return this.expressionOf(expr);
}

/// tsc's `isConstContext`: the expressions whose literals `as const` applies to through them.
fn keepsConstContext(expr: *const Expr) bool {
    return switch (expr.data) {
        .number, .string, .template, .boolean, .null, .paren, .object, .array, .conditional => true,
        .unary => |u| u.op == .negate,
        else => false,
    };
}

fn expressionOf(this: *Checker, expr: *const Expr) Error!*const Type {
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
        .member => |m| this.member(expr, m),
        .index => |i| if (try this.indexAccess(expr, i)) |access| this.narrowedRead(expr, access.type) else types.any,
        .call => |c| this.call(expr, c),
        .chain => |inner| blk: {
            const link = try this.chainLink(inner);
            break :blk if (link.short) types.unionOf(this.arena, &.{ link.type, types.undefined }) else link.type;
        },
        .non_null => |inner| this.nonNull(try this.expression(inner)),
        .assertion => |a| this.assertion(expr, a),
        .function => |f| this.checkFunction(f, null, .check),
        .object => |o| this.objectLiteral(o, null),
        .array => |a| this.arrayLiteral(expr.start, a, null),
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
        .object => |o| this.objectLiteral(o, ctx),
        .array => |a| this.arrayLiteral(expr.start, a, ctx),
        .call => |c| this.callWith(expr, c, try this.calleeType(c), ctx),
        else => this.expression(expr),
    };
}

// Optional chains and assertions

/// The type of a link in an optional chain, and whether the chain can short-circuit before it.
const Link = struct {
    type: *const Type,
    short: bool = false,
};

fn chainLink(this: *Checker, expr: *const Expr) Error!Link {
    switch (expr.data) {
        .member => |m| {
            const object = try this.chainObject(m.object, m.optional);
            const access = try this.memberAccess(m, object.type) orelse return .{ .type = types.any, .short = object.short };
            return .{ .type = try this.narrowedRead(expr, access.type), .short = object.short };
        },
        .index => |i| {
            const object = try this.chainObject(i.object, i.optional);
            const access = try this.indexOn(expr, i, object.type) orelse return .{ .type = types.any, .short = object.short };
            return .{ .type = try this.narrowedRead(expr, access.type), .short = object.short };
        },
        .call => |c| {
            var callee = try this.chainLink(c.callee);
            if (c.optional) {
                callee.short = callee.short or includesNullish(callee.type) or callee.type.* == .unknown;
                callee.type = try narrowing.nonNullish(this.arena, callee.type);
            } else {
                callee.type = try this.checkCallable(c.callee, callee.type);
            }
            return .{ .type = try this.callWith(expr, c, callee.type, null), .short = callee.short };
        },
        .non_null => |inner| {
            const link = try this.chainLink(inner);
            return .{ .type = try this.nonNull(link.type), .short = link.short };
        },
        else => return .{ .type = try this.expression(expr) },
    }
}

/// What a link of a chain acts on. After `?.`, `null` and `undefined` short-circuit the chain;
/// elsewhere they're errors.
fn chainObject(this: *Checker, expr: *const Expr, optional: bool) Error!Link {
    var link = try this.chainLink(expr);
    if (optional) {
        // `unknown` is `{}` once it isn't `null` or `undefined`.
        link.short = link.short or includesNullish(link.type) or link.type.* == .unknown;
        link.type = try narrowing.nonNullish(this.arena, link.type);
    } else {
        link.type = try this.checkNonNull(expr, link.type);
    }
    return link;
}

/// The type of `e!`.
fn nonNull(this: *Checker, t: *const Type) Error!*const Type {
    if (t.* == .any or t.* == .unknown) {
        return t;
    }
    var kept: std.ArrayList(*const Type) = .empty;
    var buffer: [1]*const Type = undefined;
    for (t.members(&buffer)) |m| {
        switch (m.*) {
            .null, .undefined, .void => {},
            else => try kept.append(this.arena, m),
        }
    }
    return types.unionOf(this.arena, kept.items);
}

fn assertion(this: *Checker, expr: *const Expr, a: ast.Assertion) Error!*const Type {
    const node = a.type orelse return this.constAssertion(a);
    const target = try this.resolveType(node);
    const t = try this.contextual(a.expr, target);
    switch (a.kind) {
        .as => {
            // tsc's `checkAssertionDeferred`: either type has to be comparable to the other.
            const source = try types.widen(this.arena, t);
            if (!types.comparableTo(target, source) and !types.comparableTo(source, target)) {
                try this.report(expr.start, .ts(2352), "Conversion of type '{f}' to type '{f}' may be a mistake because neither type sufficiently overlaps with the other. If this was intentional, convert the expression to 'unknown' first.", .{ source, target });
            }
            return target;
        },
        .satisfies => {
            if (!try this.excessProperty(a.expr, target) and !types.assignable(t, target) and !try this.elaborateLiteral(a.expr, t, target)) {
                try this.report(a.keyword_start, .ts(1360), "Type '{f}' does not satisfy the expected type '{f}'.", .{ try this.shownSource(t, target), target });
            }
            return t;
        },
    }
}

/// `e as const`: literals keep their literal types, and object literals' properties are
/// `readonly`.
fn constAssertion(this: *Checker, a: ast.Assertion) Error!*const Type {
    const e = ast.skipParens(a.expr);
    if (e.data == .template and e.data.template.substitutions.len > 0) {
        // tsc gives it a template literal type.
        try this.unsupported(a.expr.start, "'as const' on a template literal with substitutions is not supported yet.", .{});
        return this.expression(a.expr);
    }
    const ok = switch (e.data) {
        .number, .string, .boolean, .object, .array, .template => true,
        .unary => |u| u.op == .negate and u.operand.data == .number,
        else => false,
    };
    if (!ok) {
        try this.report(a.expr.start, .ts(1355), "A 'const' assertion can only be applied to references to enum members, or string, number, boolean, array, or object literals.", .{});
        return this.expression(a.expr);
    }
    const saved = this.const_context;
    this.const_context = true;
    defer this.const_context = saved;
    return types.regular(this.arena, try this.expression(a.expr));
}

// Object and array literals

/// The object type a context gives an object literal: its only object type once `null` and
/// `undefined` are left out.
fn contextObject(context: ?*const Type) ?*const types.Object {
    const t = context orelse return null;
    var found: ?*const types.Object = null;
    var buffer: [1]*const Type = undefined;
    for (t.members(&buffer)) |m| {
        switch (m.*) {
            .object => |o| {
                if (found != null) {
                    return null;
                }
                found = o;
            },
            .null, .undefined => {},
            else => return null,
        }
    }
    return found;
}

/// The object types a context gives an object literal: the object members of `context`, narrowed
/// by the discriminant properties the literal sets, as tsc's
/// `discriminateContextualTypeByObjectMembers` does. Empty when there are none.
fn contextObjects(this: *Checker, context: ?*const Type, literal: ast.ObjectLiteral) Error![]const *const Type {
    const t = context orelse return &.{};
    var objects: std.ArrayList(*const Type) = .empty;
    var buffer: [1]*const Type = undefined;
    for (t.members(&buffer)) |m| {
        if (m.* == .object) {
            try objects.append(this.arena, m);
        }
    }
    if (objects.items.len < 2) {
        return objects.items;
    }
    for (literal.properties) |p| {
        if (p != .property or p.property.key != .name) {
            continue;
        }
        const name = p.property.key.name;
        const value = try this.discriminantValue(p.property.value) orelse continue;
        if (!narrowing.isDiscriminant(t, name)) {
            continue;
        }
        var kept: std.ArrayList(*const Type) = .empty;
        for (objects.items) |o| {
            const property_type = if (o.object.find(name)) |found| found.type else types.unknown;
            if (types.overlap(value, property_type)) {
                try kept.append(this.arena, o);
            }
        }
        if (kept.items.len > 0) {
            objects = kept;
        }
    }
    return objects.items;
}

/// The type of a property value that can pick out a member of a discriminated union by its
/// syntax alone: a literal, `null` or `undefined`.
fn discriminantValue(this: *Checker, expr: *const Expr) Error!?*const Type {
    const e = ast.skipParens(expr);
    return switch (e.data) {
        .string => |str| try types.literal(this.arena, .{ .string = str }),
        .number => |n| try types.literal(this.arena, .{ .number = n }),
        .boolean => |b| try types.literal(this.arena, .{ .boolean = b }),
        .template => |t| if (t.substitutions.len == 0) try types.literal(this.arena, .{ .string = t.quasis[0] }) else null,
        .unary => |u| if (u.op == .negate and u.operand.data == .number) try types.literal(this.arena, .{ .number = -u.operand.data.number }) else null,
        .null => types.null,
        .identifier => |id| if (std.mem.eql(u8, id.name, "undefined")) types.undefined else null,
        else => null,
    };
}

/// The type a property of an object literal gets from the object types of its context: the union
/// of that property's types in those that have it.
fn contextualProperty(this: *Checker, objects: []const *const Type, name: []const u8) Error!?*const Type {
    var parts: std.ArrayList(*const Type) = .empty;
    for (objects) |o| {
        if (o.object.find(name)) |p| {
            try parts.append(this.arena, p.type);
        }
    }
    if (parts.items.len == 0) {
        return null;
    }
    return try types.unionOf(this.arena, parts.items);
}

/// The type of a property every one of `objects` has, or null.
fn commonProperty(this: *Checker, objects: []const *const Type, name: []const u8) Error!?*const Type {
    for (objects) |o| {
        if (o.object.find(name) == null) {
            return null;
        }
    }
    return this.contextualProperty(objects, name);
}

const ArrayContext = union(enum) {
    none,
    element: *const Type,
    tuple: []const *const Type,
};

/// What a context expects of an array literal.
fn arrayContext(context: ?*const Type) ArrayContext {
    const t = context orelse return .none;
    var found: ArrayContext = .none;
    var buffer: [1]*const Type = undefined;
    for (t.members(&buffer)) |m| {
        const this_one: ArrayContext = switch (m.*) {
            .array, .readonly_array => |e| .{ .element = e },
            .tuple => |es| .{ .tuple = es },
            .any, .unknown => .{ .element = m },
            .null, .undefined => continue,
            else => return .none,
        };
        if (found != .none) {
            return .none;
        }
        found = this_one;
    }
    return found;
}

/// A literal's type as part of an object or array literal: widened, unless the context expects
/// a literal type there.
fn literalMember(this: *Checker, t: *const Type, context: ?*const Type) Error!*const Type {
    if (this.const_context) {
        return types.regular(this.arena, t);
    }
    if (context) |c| {
        if (types.couldHaveSingletons(c)) {
            return t;
        }
    }
    return types.widenFresh(this.arena, t);
}

fn objectLiteral(this: *Checker, o: ast.ObjectLiteral, context: ?*const Type) Error!*const Type {
    const ctx = try this.contextObjects(context, o);
    var properties: std.ArrayList(types.Property) = .empty;
    // The properties written out (not spread), for TS1117 and TS2783.
    const Written = struct { name: []const u8, at: u32 };
    var written: std.ArrayList(Written) = .empty;
    var any_spread = false;
    for (o.properties) |p| {
        switch (p) {
            .property => |prop| {
                const name: ?[]const u8 = switch (prop.key) {
                    .name => |n| n,
                    .computed => |e| try this.computedName(e),
                };
                const property_context = if (name) |n| try this.contextualProperty(ctx, n) else null;
                const t = try this.literalMember(try this.contextual(prop.value, property_context), property_context);
                const n = name orelse continue;
                if (std.mem.eql(u8, n, "toString") or std.mem.eql(u8, n, "valueOf")) {
                    // Converting the object to a primitive would have to call it.
                    try this.unsupported(prop.key_start, "An object with its own '{s}' is not supported yet.", .{n});
                }
                for (written.items) |w| {
                    if (std.mem.eql(u8, w.name, n)) {
                        try this.report(prop.key_start, .ts(1117), "An object literal cannot have multiple properties with the same name.", .{});
                        break;
                    }
                }
                try written.append(this.arena, .{ .name = n, .at = prop.key_start });
                try putProperty(this.arena, &properties, .{ .name = n, .type = t, .method = prop.method, .readonly = this.const_context });
            },
            .spread => |spread| {
                const e = spread.expr;
                const t = try this.expression(e);
                switch (t.*) {
                    .any => any_spread = true,
                    .object => |so| for (so.properties) |sp| {
                        if (!sp.optional) {
                            for (written.items) |w| {
                                if (std.mem.eql(u8, w.name, sp.name)) {
                                    try this.report(w.at, .ts(2783), "'{s}' is specified more than once, so this usage will be overwritten.", .{w.name});
                                }
                            }
                        }
                        var copy = sp;
                        copy.readonly = false;
                        try putProperty(this.arena, &properties, copy);
                    },
                    else => if (isObjectType(t) or isNullOrUndefined(e))
                        try this.unsupported(e.start, "Spreading '{f}' into an object is not supported yet.", .{t})
                    else
                        try this.report(spread.start, .ts(2698), "Spread types may only be created from object types.", .{}),
                }
            },
        }
    }
    if (any_spread) {
        return types.any;
    }
    const object = try this.arena.create(types.Object);
    object.* = .{ .properties = properties.items };
    return this.newType(.{ .object = object });
}

/// The name a computed property key gives, when its type is a literal. Null when it isn't
/// (which has been reported).
fn computedName(this: *Checker, e: *const Expr) Error!?[]const u8 {
    const t = try this.expression(e);
    if (t.* == .literal) {
        switch (t.literal.value) {
            .string => |str| return str,
            .number => |n| return try @import("../runtime/number.zig").toString(this.arena, n),
            .boolean => {},
        }
    }
    const widened = try types.widen(this.arena, t);
    if (widened.* == .any or types.isStringLike(widened) or types.isNumberLike(widened)) {
        try this.unsupported(e.start, "A computed property name of type '{f}' is not supported yet.", .{widened});
    } else {
        try this.report(e.start, .ts(2464), "A computed property name must be of type 'string', 'number', 'symbol', or 'any'.", .{});
    }
    return null;
}

fn arrayLiteral(this: *Checker, start: u32, a: ast.ArrayLiteral, context: ?*const Type) Error!*const Type {
    if (this.const_context) {
        // That's a `readonly` tuple.
        try this.unsupported(start, "'as const' on an array literal is not supported yet.", .{});
    }
    const ctx = arrayContext(context);
    const has_spread = for (a.elements) |e| {
        if (e == .spread) {
            break true;
        }
    } else false;
    if (ctx == .tuple and !has_spread) {
        const elements = try this.arena.alloc(*const Type, a.elements.len);
        for (a.elements, elements, 0..) |e, *t, i| {
            const element_context = if (i < ctx.tuple.len) ctx.tuple[i] else null;
            t.* = try this.literalMember(try this.contextual(e.expr, element_context), element_context);
        }
        return this.newType(.{ .tuple = elements });
    }
    const element_context: ?*const Type = switch (ctx) {
        .element => |t| t,
        else => null,
    };
    var parts: std.ArrayList(*const Type) = .empty;
    for (a.elements) |e| {
        switch (e) {
            .expr => |x| try parts.append(this.arena, try this.contextual(x, element_context)),
            .spread => |x| {
                const t = try this.expression(x);
                if (!try this.checkIterable(t, x.start, "Spreading a string")) {
                    try parts.append(this.arena, types.any);
                    continue;
                }
                var buffer: [1]*const Type = undefined;
                for (t.members(&buffer)) |m| {
                    switch (m.*) {
                        .array, .readonly_array => |element| try parts.append(this.arena, element),
                        .tuple => |es| try parts.appendSlice(this.arena, es),
                        else => try parts.append(this.arena, m),
                    }
                }
            },
        }
    }
    const element = try this.literalMember(try types.unionOf(this.arena, parts.items), element_context);
    return this.newType(.{ .array = element });
}

// Assignability

const Use = enum { assignment, argument };

/// Checks that `expr`, of type `source`, can be used where a `target` is expected, reporting it
/// if not. Like tsc, an object literal can't have properties the target doesn't know (TS2353),
/// and a mismatch inside a literal is reported where it is.
fn checkAssignable(this: *Checker, expr: *const Expr, given: *const Type, target: *const Type, at: u32, kind: Use) Error!void {
    const source = try this.instantiateInContext(given, target);
    if (try this.excessProperty(expr, target)) {
        return;
    }
    if (types.assignable(source, target)) {
        return;
    }
    if (try this.elaborateLiteral(expr, source, target)) {
        return;
    }
    try this.reportNotAssignable(expr, source, target, at, kind);
}

/// tsc's excess property check: reports the first property of an object literal (or one nested
/// in it) that its target type doesn't have.
fn excessProperty(this: *Checker, expr: *const Expr, target: *const Type) Error!bool {
    const e = ast.skipParens(expr);
    switch (e.data) {
        .object => |o| {
            const objects = try this.contextObjects(target, o);
            if (objects.len == 0) {
                return false;
            }
            for (objects) |t| {
                if (t.object.properties.len == 0) {
                    return false;
                }
            }
            for (o.properties) |p| {
                if (p != .property or p.property.key != .name) {
                    continue;
                }
                const prop = p.property;
                const found = try this.contextualProperty(objects, prop.key.name) orelse {
                    const shown = if (objects.len == 1) objects[0] else try this.removeNullish(target);
                    try this.report(prop.key_start, .ts(2353), "Object literal may only specify known properties, and '{s}' does not exist in type '{f}'.", .{ prop.key.name, shown });
                    return true;
                };
                if (try this.excessProperty(prop.value, found)) {
                    return true;
                }
            }
        },
        .array => |a| switch (arrayContext(target)) {
            .none => {},
            .element => |t| for (a.elements) |element| {
                if (element == .expr and try this.excessProperty(element.expr, t)) {
                    return true;
                }
            },
            .tuple => |ts| for (a.elements, 0..) |element, i| {
                if (i < ts.len and element == .expr and try this.excessProperty(element.expr, ts[i])) {
                    return true;
                }
            },
        },
        else => {},
    }
    return false;
}

/// How a target is named in TS2353: as the object type it is, without `undefined`.
fn target_shown(target: *const Type, object: *const types.Object) *const Type {
    if (target.* == .object) {
        return target;
    }
    var buffer: [1]*const Type = undefined;
    for (target.members(&buffer)) |m| {
        if (m.* == .object and m.object == object) {
            return m;
        }
    }
    return target;
}

/// tsc's `elaborateError` for literals: when an object or array literal doesn't match its
/// target, the mismatched properties or elements are reported where they are. False if there
/// was nothing to report that way.
fn elaborateLiteral(this: *Checker, expr: *const Expr, source: *const Type, target: *const Type) Error!bool {
    const e = ast.skipParens(expr);
    var reported = false;
    switch (e.data) {
        .object => |o| {
            const objects = try this.contextObjects(target, o);
            if (objects.len == 0 or source.* != .object) {
                return false;
            }
            for (o.properties) |p| {
                if (p != .property or p.property.key != .name) {
                    continue;
                }
                const prop = p.property;
                const expected = try this.commonProperty(objects, prop.key.name) orelse continue;
                const actual = source.object.find(prop.key.name) orelse continue;
                if (types.assignable(actual.type, expected)) {
                    continue;
                }
                if (!try this.elaborateLiteral(prop.value, actual.type, expected)) {
                    try this.reportNotAssignable(prop.value, actual.type, expected, prop.key_start, .assignment);
                }
                reported = true;
            }
        },
        .array => |a| {
            const ctx = arrayContext(target);
            if (ctx == .none or (ctx == .tuple and (source.* != .tuple or source.tuple.len != ctx.tuple.len))) {
                return false;
            }
            for (a.elements, 0..) |element, i| {
                if (element != .expr) {
                    continue;
                }
                const expected = switch (ctx) {
                    .element => |t| t,
                    .tuple => |ts| ts[i],
                    .none => unreachable,
                };
                const actual = if (source.* == .tuple) source.tuple[i] else try this.literalMember(try this.typeOf(element.expr), expected);
                if (types.assignable(actual, expected)) {
                    continue;
                }
                if (!try this.elaborateLiteral(element.expr, actual, expected)) {
                    try this.reportNotAssignable(element.expr, actual, expected, element.expr.start, .assignment);
                }
                reported = true;
            }
        },
        else => {},
    }
    return reported;
}

// Properties

/// A property that was found: its type, and whether it can be assigned or deleted.
const Access = struct {
    type: *const Type,
    /// The property's name, for messages.
    name: []const u8 = "",
    readonly: bool = false,
    /// A declared property rather than an element, which `delete` requires to be optional
    /// (TS2790).
    named: bool = true,
    /// An array's `length`, which can't be assigned yet.
    array_length: bool = false,
};

/// Looks up the property `name` on a value of type `object`, which isn't null or undefined. Null
/// when there's no such property; the caller reports that.
fn property(this: *Checker, object: *const Type, name: []const u8, at: u32) Error!?Access {
    switch (object.*) {
        .any => return .{ .type = types.any, .name = name, .named = false },
        // A type parameter has the properties of its constraint.
        .param, .keyof, .indexed => {
            const base = types.baseConstraint(object);
            if (base.* == .unknown or base == object) {
                return null;
            }
            return this.property(base, name, at);
        },
        .mapped => {
            try this.unsupported(at, "Properties of '{f}' are not supported yet.", .{object});
            return .{ .type = types.any, .name = name, .named = false };
        },
        // tsc reports reading a property of `never`, though indexing it is fine.
        .never => return null,
        .@"union" => |ms| {
            for (ms) |m| {
                switch (types.baseConstraint(m).*) {
                    .object, .function, .array, .tuple, .readonly_array => {},
                    else => {
                        try this.unsupported(at, "Properties of '{f}' are not supported yet.", .{try types.widen(this.arena, object)});
                        return .{ .type = types.any, .name = name, .named = false };
                    },
                }
            }
            // Every member has to have it.
            var parts: std.ArrayList(*const Type) = .empty;
            var access: Access = .{ .type = types.never, .name = name };
            for (ms) |m| {
                const a = try this.property(m, name, at) orelse return null;
                try parts.append(this.arena, a.type);
                access.readonly = access.readonly or a.readonly;
                access.named = access.named and a.named;
                access.array_length = access.array_length or a.array_length;
            }
            access.type = try types.unionOf(this.arena, parts.items);
            return access;
        },
        .object => |o| {
            const p = o.find(name) orelse return null;
            return .{ .type = p.type, .name = name, .readonly = p.readonly };
        },
        .function => {
            if (std.mem.eql(u8, name, "name")) {
                return .{ .type = types.string, .name = name, .readonly = true };
            }
            if (std.mem.eql(u8, name, "length")) {
                return .{ .type = types.number, .name = name, .readonly = true };
            }
            return this.unsupportedProperty(name, at, object, &.{ "apply", "bind", "call", "toString", "prototype", "arguments", "caller" });
        },
        .array, .tuple, .readonly_array => {
            if (std.mem.eql(u8, name, "length")) {
                if (object.* == .tuple) {
                    return .{ .type = try types.literal(this.arena, .{ .number = @floatFromInt(object.tuple.len) }), .name = name };
                }
                if (object.* == .readonly_array) {
                    return .{ .type = types.number, .name = name, .readonly = true };
                }
                return .{ .type = types.number, .name = name, .array_length = true };
            }
            if (arrayIndex(name)) |i| {
                return switch (object.*) {
                    .array => |e| .{ .type = e, .name = name, .named = false },
                    .readonly_array => |e| .{ .type = e, .name = name, .named = false, .readonly = true },
                    .tuple => |es| if (i < es.len) .{ .type = es[i], .name = name, .named = false } else null,
                    else => unreachable,
                };
            }
            return this.unsupportedProperty(name, at, object, &.{
                "toString",   "toLocaleString", "pop",        "push",     "concat",      "join",        "reverse",   "shift",
                "slice",      "sort",           "splice",     "unshift",  "indexOf",     "lastIndexOf", "every",     "some",
                "forEach",    "map",            "filter",     "reduce",   "reduceRight", "find",        "findIndex", "fill",
                "copyWithin", "entries",        "keys",       "values",   "includes",    "flatMap",     "flat",      "at",
                "findLast",   "findLastIndex",  "toReversed", "toSorted", "toSpliced",   "with",
            });
        },
        else => {
            try this.unsupported(at, "Properties of '{f}' are not supported yet.", .{try types.widen(this.arena, object)});
            return .{ .type = types.any, .name = name, .named = false };
        },
    }
}

/// `name` as an array index, if it's one in canonical form (`"0"`, `"12"`, not `"01"`).
fn arrayIndex(name: []const u8) ?usize {
    if (name.len == 0 or (name.len > 1 and name[0] == '0')) {
        return null;
    }
    return std.fmt.parseInt(u32, name, 10) catch null;
}

/// `o.name`, with `o` already checked.
fn memberAccess(this: *Checker, m: ast.Member, object: *const Type) Error!?Access {
    return try this.property(object, m.property, m.property_start) orelse {
        try this.report(m.property_start, .ts(2339), "Property '{s}' does not exist on type '{f}'.", .{ m.property, object });
        return null;
    };
}

/// `o[k]`. Null when that's an error, which has been reported.
fn indexAccess(this: *Checker, expr: *const Expr, i: ast.Index) Error!?Access {
    const object = try this.checkNonNull(i.object, try this.expression(i.object));
    return this.indexOn(expr, i, object);
}

/// `o[k]`, with `o` already checked.
fn indexOn(this: *Checker, expr: *const Expr, i: ast.Index, object: *const Type) Error!?Access {
    return this.indexWith(expr, i, object, try this.expression(i.index));
}

fn indexWith(this: *Checker, expr: *const Expr, i: ast.Index, object: *const Type, key: *const Type) Error!?Access {
    if (object.* == .@"union") {
        // Each member is indexed; the first that can't be is reported.
        var parts: std.ArrayList(*const Type) = .empty;
        var readonly = false;
        for (object.@"union") |m| {
            this.muted += 1;
            const access = try this.indexWith(expr, i, m, key);
            this.muted -= 1;
            const a = access orelse return this.indexWith(expr, i, m, key);
            try parts.append(this.arena, a.type);
            readonly = readonly or a.readonly;
        }
        return .{ .type = try types.unionOf(this.arena, parts.items), .readonly = readonly, .named = false };
    }
    if (object.* == .any or object.* == .never) {
        return .{ .type = object, .named = false };
    }
    if (types.isGeneric(object) or types.isGeneric(key)) {
        // `o[k]` with `k: K extends keyof T` is a `T[K]`.
        const keys = try types.keyOf(this.arena, object) orelse types.never;
        if (types.assignable(key, keys)) {
            const t = try types.indexedAccess(this.arena, object, key, &this.mapper(&.{}, &.{})) orelse types.any;
            return .{ .type = t, .named = false };
        }
        const apparent_object = types.baseConstraint(object);
        const apparent_key = types.baseConstraint(key);
        if (apparent_object.* == .unknown or apparent_key.* == .unknown or (apparent_object == object and apparent_key == key)) {
            try this.report(i.index.start, .ts(2536), "Type '{f}' cannot be used to index type '{f}'.", .{ key, object });
            return null;
        }
        return this.indexWith(expr, i, apparent_object, apparent_key);
    }
    // A literal key names a property.
    if (key.* == .literal and key.literal.value != .boolean) {
        const name = switch (key.literal.value) {
            .string => |str| str,
            .number => |n| try @import("../runtime/number.zig").toString(this.arena, n),
            .boolean => unreachable,
        };
        if (object.* == .tuple and key.literal.value == .number) {
            const n = key.literal.value.number;
            if (n < 0) {
                try this.report(i.index.start, .ts(2514), "A tuple type cannot be indexed with a negative value.", .{});
                return null;
            }
            if (n != @trunc(n) or n >= @as(f64, @floatFromInt(object.tuple.len))) {
                try this.report(i.index.start, .ts(2493), "Tuple type '{f}' of length '{d}' has no element at index '{s}'.", .{ object, object.tuple.len, name });
                return null;
            }
            return .{ .type = object.tuple[@intFromFloat(n)], .name = name, .named = false };
        }
        if (object.* == .array and key.literal.value == .number) {
            return .{ .type = object.array, .name = name, .named = false };
        }
        if (object.* == .readonly_array and key.literal.value == .number) {
            return .{ .type = object.readonly_array, .name = name, .named = false, .readonly = true };
        }
        return try this.property(object, name, i.index.start) orelse {
            if (object.* == .array or object.* == .tuple or object.* == .readonly_array) {
                try this.report(i.index.start, .ts(7015), "Element implicitly has an 'any' type because index expression is not of type 'number'.", .{});
                return null;
            }
            try this.report(expr.start, .ts(7053), "Element implicitly has an 'any' type because expression of type '{f}' can't be used to index type '{f}'.\n  Property '{s}' does not exist on type '{f}'.", .{ key, object, name, object });
            return null;
        };
    }
    const k = try types.widen(this.arena, key);
    if (k.* == .any) {
        return switch (object.*) {
            .array => |e| .{ .type = e, .named = false },
            .readonly_array => |e| .{ .type = e, .named = false, .readonly = true },
            .tuple => |es| .{ .type = try types.unionOf(this.arena, es), .named = false },
            else => .{ .type = types.any, .named = false },
        };
    }
    if (types.isNumberLike(k)) {
        switch (object.*) {
            .array => |e| return .{ .type = e, .named = false },
            .readonly_array => |e| return .{ .type = e, .named = false, .readonly = true },
            .tuple => |es| return .{ .type = try types.unionOf(this.arena, es), .named = false },
            else => {},
        }
    }
    if (!types.isStringLike(k) and !types.isNumberLike(k)) {
        try this.report(i.index.start, .ts(2538), "Type '{f}' cannot be used as an index type.", .{key});
        return null;
    }
    switch (object.*) {
        .array, .tuple, .readonly_array => try this.report(i.index.start, .ts(7015), "Element implicitly has an 'any' type because index expression is not of type 'number'.", .{}),
        .object => try this.report(expr.start, .ts(7053), "Element implicitly has an 'any' type because expression of type '{f}' can't be used to index type '{f}'.\n  No index signature with a parameter of type '{f}' was found on type '{f}'.", .{ k, object, k, object }),
        else => {
            try this.unsupported(expr.start, "Indexing '{f}' is not supported yet.", .{try types.widen(this.arena, object)});
            return .{ .type = types.any, .named = false };
        },
    }
    return null;
}

/// The property an assignment, `++`/`--` or `delete` writes to, `o.p` or `o[k]`. Null when it
/// can't be found, which has been reported.
fn propertyAccess(this: *Checker, target: *const Expr) Error!?Access {
    return switch (target.data) {
        .member => |m| this.memberAccess(m, try this.checkNonNull(m.object, try this.expression(m.object))),
        .index => |i| this.indexAccess(target, i),
        else => unreachable,
    };
}

/// The type an assignment to the property `target` must have, after checking it can be
/// assigned. Null when it can't, which has been reported.
fn writableProperty(this: *Checker, target: *const Expr) Error!?*const Type {
    const access = try this.propertyAccess(target) orelse return null;
    if (access.readonly) {
        const at = if (target.data == .member) target.data.member.property_start else target.data.index.index.start;
        if (!access.named) {
            try this.report(target.start, .ts(2542), "Index signature in type '{f}' only permits reading.", .{try this.typeOf(if (target.data == .member) target.data.member.object else target.data.index.object)});
            return null;
        }
        try this.report(at, .ts(2540), "Cannot assign to '{s}' because it is a read-only property.", .{access.name});
        return null;
    }
    if (access.array_length) {
        try this.unsupported(target.start, "Assigning to an array's 'length' is not supported yet.", .{});
        return null;
    }
    return access.type;
}

fn deleteExpression(this: *Checker, operand: *const Expr) Error!*const Type {
    const e = ast.skipParens(operand);
    if (e.data == .chain) {
        try this.unsupported(operand.start, "Deleting through an optional chain is not supported yet.", .{});
        return types.boolean;
    }

    if (e.data != .member and e.data != .index) {
        _ = try this.expression(operand);
        if (e.data == .identifier) {
            try this.report(operand.start, .ts(1102), "'delete' cannot be called on an identifier in strict mode.", .{});
        }
        try this.report(operand.start, .ts(2703), "The operand of a 'delete' operator must be a property reference.", .{});
        return types.boolean;
    }
    const access = try this.propertyAccess(e) orelse return types.boolean;
    if (try this.referenceOf(e)) |r| {
        try this.forgetPaths(r);
    }
    if (access.readonly) {
        try this.report(operand.start, .ts(2704), "The operand of a 'delete' operator cannot be a read-only property.", .{});
    } else if (access.named and !types.includesUndefined(access.type) and access.type.* != .never) {
        try this.report(operand.start, .ts(2790), "The operand of a 'delete' operator must be optional.", .{});
    }
    return types.boolean;
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
        .binary => |b| switch (b.op) {
            .logical_and, .logical_or, .nullish => return this.logical(b, if_body, chain),
            .equal, .not_equal, .strict_equal, .strict_not_equal => return this.equalityCondition(b),
            .in => return this.inCondition(b),
            else => {},
        },
        else => {},
    }
    const t = try this.expression(expr);
    if (try this.aliasedCondition(expr)) |init| {
        // tsc narrows by what the constant was initialized to, as if it were written here.
        this.muted += 1;
        this.aliased += 1;
        defer {
            this.muted -= 1;
            this.aliased -= 1;
        }
        const branches = try this.condition(init, null, null);
        return .{ .type = t, .when_true = branches.when_true, .when_false = branches.when_false };
    }
    var branches: Branches = .{ .type = t, .when_true = this.flow, .when_false = try this.copyFlow(this.flow) };
    // What's tested is narrowed to what can pass or fail the test: after `while (b) {}`, `b` is
    // `false`.
    try this.narrowBranches(&branches, expr, .truthy, true);
    return branches;
}

/// `a === b` and the other equality operators as a condition, which narrow either side by the
/// other, and `typeof x === "name"`, which narrows `x`.
fn equalityCondition(this: *Checker, b: ast.Binary) Error!Branches {
    const left = try this.expression(b.left);
    const right = try this.expression(b.right);
    _ = try this.operator(b.op, b.left, b.right, left, right, false);
    var branches: Branches = .{ .type = types.boolean, .when_true = this.flow, .when_false = try this.copyFlow(this.flow) };
    const equal = b.op == .strict_equal or b.op == .equal;
    const loose = b.op == .equal or b.op == .not_equal;
    const sides = [_]struct { *const Expr, *const Type }{ .{ b.left, right }, .{ b.right, left } };
    for (sides) |side| {
        const e = ast.skipParens(side[0]);
        if (e.data == .unary and e.data.unary.op == .typeof) {
            const other = side[1];
            if (other.* == .literal and other.literal.value == .string) {
                try this.narrowBranches(&branches, e.data.unary.operand, .{ .typeof = other.literal.value.string }, equal);
            }
            continue;
        }
        try this.narrowBranches(&branches, side[0], .{ .equal = .{ .value = side[1], .loose = loose } }, equal);
    }
    return branches;
}

/// `"name" in x` as a condition, which narrows `x` to the members that have (or lack) it.
fn inCondition(this: *Checker, b: ast.Binary) Error!Branches {
    const left = try this.expression(b.left);
    const right = try this.expression(b.right);
    _ = try this.operator(.in, b.left, b.right, left, right, false);
    var branches: Branches = .{ .type = types.boolean, .when_true = this.flow, .when_false = try this.copyFlow(this.flow) };
    if (left.* == .literal) {
        const name = switch (left.literal.value) {
            .string => |str| str,
            .number => |n| try @import("../runtime/number.zig").toString(this.arena, n),
            .boolean => return branches,
        };
        try this.narrowBranches(&branches, b.right, .{ .in = name }, true);
    }
    return branches;
}

/// Narrows what `expr` refers to in both branches: by `test_` passing in `when_true` (or failing,
/// when `passes` is false), and the other way round in `when_false`.
fn narrowBranches(this: *Checker, branches: *Branches, expr: *const Expr, test_: narrowing.Test, passes: bool) Error!void {
    this.flow = branches.when_true;
    try this.narrowReference(expr, test_, passes);
    branches.when_true = this.flow;
    this.flow = branches.when_false;
    try this.narrowReference(expr, test_, !passes);
    branches.when_false = this.flow;
}

/// The expression a reference is, without what doesn't change which one it is.
fn skipReference(expr: *const Expr) *const Expr {
    var e = expr;
    while (true) {
        e = switch (e.data) {
            .paren, .non_null, .chain => |inner| inner,
            else => return e,
        };
    }
}

/// A property access, `o.name` or `o["name"]`.
const AccessParts = struct {
    object: *const Expr,
    name: []const u8,
    optional: bool,
};

fn accessParts(this: *Checker, expr: *const Expr) Error!?AccessParts {
    return switch (expr.data) {
        .member => |m| .{ .object = m.object, .name = m.property, .optional = m.optional },
        .index => |i| switch (ast.skipParens(i.index).data) {
            .string => |str| .{ .object = i.object, .name = str, .optional = i.optional },
            .number => |n| .{ .object = i.object, .name = try @import("../runtime/number.zig").toString(this.arena, n), .optional = i.optional },
            // tsc's `tryGetNameFromEntityNameExpression`: `o[k]` is `o.a` when `k` is a
            // `const` of literal type `"a"`.
            .identifier => |id| blk: {
                const ref = this.refs[id.ref];
                if (ref != .slot or this.variable(ref.slot).kind != .@"const") {
                    break :blk null;
                }
                const t = this.variable(ref.slot).declared orelse break :blk null;
                if (t.* != .literal) {
                    break :blk null;
                }
                break :blk switch (t.literal.value) {
                    .string => |str| .{ .object = i.object, .name = str, .optional = i.optional },
                    .number => |n| .{ .object = i.object, .name = try @import("../runtime/number.zig").toString(this.arena, n), .optional = i.optional },
                    .boolean => null,
                };
            },
            else => null,
        },
        else => null,
    };
}

/// What narrowing can apply to: a variable, or a chain of properties of one. Identifiers have to
/// have been resolved.
fn referenceOf(this: *Checker, expr: *const Expr) Error!?Reference {
    const e = skipReference(expr);
    switch (e.data) {
        .identifier => |id| {
            const ref = this.refs[id.ref];
            if (ref != .slot or this.variable(ref.slot).kind == .function) {
                return null;
            }
            return .{ .slot = ref.slot };
        },
        .member, .index => {
            const parts = try this.accessParts(e) orelse return null;
            const base = try this.referenceOf(parts.object) orelse return null;
            const path = try this.arena.alloc([]const u8, base.path.len + 1);
            @memcpy(path[0..base.path.len], base.path);
            path[base.path.len] = parts.name;
            return .{ .slot = base.slot, .path = path };
        },
        else => return null,
    }
}

/// Narrows what `expr` refers to (a variable or a property of one) for when `test_` is `assume`.
/// A test of a discriminant property narrows the union it belongs to as well, and a test that
/// an optional chain found something narrows what the chain went through to non-nullish.
fn narrowReference(this: *Checker, expr: *const Expr, test_: narrowing.Test, assume: bool) Error!void {
    if (!this.flow.reachable) {
        return;
    }
    const e = skipReference(expr);
    if (try this.referenceOf(e)) |reference| {
        try this.narrowTo(e, reference, test_, assume);
    }
    if (test_ != .in) {
        if (try this.accessParts(e)) |parts| {
            const object = try this.referenceOf(parts.object);
            if (object != null and try this.canNarrow(object.?)) {
                const reference = object.?;
                const t = try this.typeOf(parts.object);
                // A union that's been narrowed to one member is still discriminated by its
                // declared type.
                const declared = try this.declaredReferenceType(reference);
                const union_type = if (declared.* == .@"union" and isSubset(t, declared)) declared else t;
                if (narrowing.isDiscriminant(union_type, parts.name)) {
                    const optional = parts.optional or ast.skipParens(parts.object).data == .non_null;
                    const narrowed = try narrowing.byDiscriminant(this.arena, t, parts.name, test_, assume, optional) orelse
                        return this.unsupported(expr.start, "Narrowing '{f}' by this test is not supported yet.", .{t});
                    try this.setNarrowed(reference, narrowed);
                }
            }
        }
    }
    if (ast.skipParens(expr).data == .chain and impliesPresent(test_, assume)) {
        // Every link up to the first `?.` found something.
        var link = e;
        while (true) {
            const object: *const Expr, const optional = switch (link.data) {
                .member => |m| .{ m.object, m.optional },
                .index => |i| .{ i.object, i.optional },
                .call => |c| .{ c.callee, c.optional },
                .non_null => |inner| .{ inner, false },
                else => break,
            };
            const inner = skipReference(object);
            if (try this.referenceOf(inner)) |reference| {
                try this.narrowTo(inner, reference, .{ .equal = .{ .value = types.null, .loose = true } }, false);
            }
            if (optional) {
                break;
            }
            link = object;
        }
    }
}

/// Whether passing (or failing) `test_` means the value isn't `undefined` (tsc's
/// `narrowTypeByOptionalChainContainment`).
fn impliesPresent(test_: narrowing.Test, assume: bool) bool {
    return switch (test_) {
        .truthy => assume,
        .equal => |e| blk: {
            var buffer: [1]*const Type = undefined;
            const ms = e.value.members(&buffer);
            if (assume) {
                for (ms) |m| {
                    switch (m.*) {
                        .any, .unknown, .undefined, .void => break :blk false,
                        .null => if (e.loose) break :blk false,
                        else => {},
                    }
                }
                break :blk true;
            }
            for (ms) |m| {
                switch (m.*) {
                    .undefined, .void => {},
                    .null => if (!e.loose) break :blk false,
                    else => break :blk false,
                }
            }
            break :blk true;
        },
        .typeof => |name| assume != std.mem.eql(u8, name, "undefined"),
        .in => false,
    };
}

/// Narrows one reference by a test.
fn narrowTo(this: *Checker, expr: *const Expr, reference: Reference, test_: narrowing.Test, assume: bool) Error!void {
    if (!try this.canNarrow(reference)) {
        return;
    }
    const current = try this.typeOf(expr);
    const narrowed = try narrowing.narrow(this.arena, current, test_, assume) orelse
        return this.unsupported(expr.start, "Narrowing '{f}' by this test is not supported yet.", .{current});
    try this.setNarrowed(reference, narrowed);
}

/// The type a reference has where nothing narrows it.
fn declaredReferenceType(this: *Checker, reference: Reference) Error!*const Type {
    var t = try this.declaredType(reference.slot);
    this.muted += 1;
    defer this.muted -= 1;
    for (reference.path) |name| {
        const access = try this.property(try this.removeNullish(t), name, 0) orelse return types.any;
        t = access.type;
    }
    return t;
}

/// Whether every member of `t` is one of `of`'s.
fn isSubset(t: *const Type, of: *const Type) bool {
    var buffer: [1]*const Type = undefined;
    var of_buffer: [1]*const Type = undefined;
    for (t.members(&buffer)) |m| {
        const found = for (of.members(&of_buffer)) |o| {
            if (m.eql(o)) {
                break true;
            }
        } else false;
        if (!found) {
            return false;
        }
    }
    return true;
}

/// A variable that may not be assigned yet has nothing to narrow. Through an aliased condition,
/// only a constant reference narrows.
fn canNarrow(this: *Checker, reference: Reference) Error!bool {
    if (reference.path.len == 0 and this.flow.vars[reference.slot].type == null and !this.isOuter(reference.slot)) {
        return false;
    }
    return this.aliased == 0 or try this.isConstantReference(reference);
}

/// tsc's `isConstantReference`: a `const`, or a parameter nothing assigns, and `readonly`
/// properties of one.
fn isConstantReference(this: *Checker, reference: Reference) Error!bool {
    const v = this.variable(reference.slot);
    const constant = switch (v.kind) {
        .@"const" => true,
        .parameter => try this.lastAssignment(reference.slot) == .never,
        .let, .function => false,
    };
    if (!constant) {
        return false;
    }
    var t = try this.declaredType(reference.slot);
    this.muted += 1;
    defer this.muted -= 1;
    for (reference.path) |name| {
        const access = try this.property(try this.removeNullish(t), name, 0) orelse return false;
        if (!access.readonly) {
            return false;
        }
        t = access.type;
    }
    return true;
}

/// The initializer of a condition that's a `const` without a type annotation (tsc's aliased
/// conditions), when it's made only of tests, so checking it again changes nothing. tsc follows
/// at most five of them in a row.
fn aliasedCondition(this: *Checker, expr: *const Expr) Error!?*const Expr {
    if (expr.data != .identifier or this.aliased >= 5) {
        return null;
    }
    const ref = this.refs[expr.data.identifier.ref];
    if (ref != .slot) {
        return null;
    }
    const v = this.variable(ref.slot);
    if (v.kind != .@"const" or v.annotation != null or v.destructured != null) {
        return null;
    }
    // Its names have to have been resolved, by this program.
    if (v.declared == null or v.source != this.source) {
        return null;
    }
    const init = v.init orelse return null;
    return if (isPureTest(init)) init else null;
}

/// Whether an expression only reads and compares: literals, names, property accesses and the
/// operators narrowing understands.
fn isPureTest(expr: *const Expr) bool {
    return switch (expr.data) {
        .number, .string, .boolean, .null, .identifier => true,
        .template => |t| t.substitutions.len == 0,
        .paren, .chain, .non_null => |inner| isPureTest(inner),
        .member => |m| isPureTest(m.object),
        .index => |i| isPureTest(i.object) and isPureTest(i.index),
        .unary => |u| u.op != .delete and isPureTest(u.operand),
        .binary => |b| switch (b.op) {
            .logical_and, .logical_or, .nullish, .equal, .not_equal, .strict_equal, .strict_not_equal, .in => isPureTest(b.left) and isPureTest(b.right),
            else => false,
        },
        else => false,
    };
}

/// Records what a test narrowed a reference to. Unlike an assignment, what's known about its
/// properties stays.
fn setNarrowed(this: *Checker, reference: Reference, t: *const Type) Error!void {
    if (reference.path.len == 0) {
        this.flow.vars[reference.slot].type = t;
        return;
    }
    var paths: std.ArrayList(PathFlow) = .empty;
    for (this.flow.paths) |p| {
        if (!p.reference.eql(reference)) {
            try paths.append(this.arena, p);
        }
    }
    try paths.append(this.arena, .{ .reference = reference, .type = t });
    this.flow.paths = paths.items;
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
            const inner = ast.skipOuter(b.left);
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
    if (u.op == .delete) {
        return this.deleteExpression(u.operand);
    }
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
        .delete => unreachable,
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
    if (operand.data == .chain) {
        // Like tsc, it's only reported if the operand is a number.
        if (!isNumeric(try this.checkNonNull(u.operand, try this.expression(u.operand)))) {
            try this.report(u.operand.start, .ts(2356), "An arithmetic operand " ++ arithmetic_operand, .{});
        } else {
            try this.report(u.operand.start, .ts(2777), "The operand of an increment or decrement operator may not be an optional property access.", .{});
        }
        return types.number;
    }
    if (operand.data == .non_null or operand.data == .assertion) {
        try this.unsupported(u.operand.start, "Incrementing a type assertion is not supported yet.", .{});
        return types.number;
    }
    if (operand.data == .member or operand.data == .index) {
        const t = try this.writableProperty(operand) orelse return types.number;
        if (try this.referenceOf(operand)) |r| {
            try this.forgetPaths(r);
        }
        if (!isNumeric(try this.checkNonNull(u.operand, t))) {
            try this.report(u.operand.start, .ts(2356), "An arithmetic operand " ++ arithmetic_operand, .{});
        }
        return types.number;
    }
    if (operand.data != .identifier) {
        const t = try this.checkNonNull(u.operand, try this.expression(u.operand));
        if (!isNumeric(t)) {
            try this.report(u.operand.start, .ts(2356), "An arithmetic operand " ++ arithmetic_operand, .{});
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
    try this.setVariable(slot, try this.assignmentReduced(try this.declaredType(slot), types.number));
    return types.number;
}

fn assign(this: *Checker, a: ast.Assign) Error!*const Type {
    const target = ast.skipParens(a.target);
    switch (target.data) {
        .identifier => {},
        .member, .index => return this.assignProperty(a, target),
        .object, .array => {
            try this.unsupported(a.target.start, "Destructuring assignments are not supported yet.", .{});
            return this.expression(a.value);
        },
        .chain => {
            _ = try this.expression(a.target);
            const value = try this.expression(a.value);
            try this.report(a.target.start, .ts(2779), "The left-hand side of an assignment expression may not be an optional property access.", .{});
            return value;
        },
        .non_null, .assertion => {
            try this.unsupported(a.target.start, "Assigning to a type assertion is not supported yet.", .{});
            return this.expression(a.value);
        },
        else => {
            _ = try this.expression(a.target);
            const value = try this.expression(a.value);
            try this.report(a.target.start, .ts(2364), "The left-hand side of an assignment expression must be a variable or a property access.", .{});
            return value;
        },
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
        try this.checkAssignable(a.value, value, declared, a.target.start, .assignment);
        try this.setVariable(slot, try this.assignmentReduced(declared, value));
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
            .logical_and => try this.narrowReference(target, .truthy, false),
            .logical_or => try this.narrowReference(target, .truthy, true),
            else => try this.narrowReference(target, .{ .equal = .{ .value = types.null, .loose = true } }, false),
        }
        std.mem.swap(Flow, &this.flow, &skipped);
        const value = try this.expression(a.value);
        if (!types.assignable(value, left)) {
            try this.notAssignable(a.target.start, value, left);
        }
        try this.setVariable(slot, try this.assignmentReduced(try this.declaredType(slot), value));
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
    try this.setVariable(slot, try this.assignmentReduced(try this.declaredType(slot), result.type));
    return result.type;
}

/// `o.p = v`, `o[k] += v` and so on.
fn assignProperty(this: *Checker, a: ast.Assign, target: *const Expr) Error!*const Type {
    const declared = try this.writableProperty(target);
    const reference = try this.referenceOf(target);
    const op = a.op orelse {
        const value = try this.contextual(a.value, declared);
        if (declared) |t| {
            try this.checkAssignable(a.value, value, t, a.target.start, .assignment);
            // Like a variable, the property holds what was assigned.
            if (reference) |r| {
                try this.setPath(r, try this.assignmentReduced(t, value));
            }
        }
        return value;
    };
    if (reference) |r| {
        try this.forgetPaths(r);
    }
    const current = declared orelse types.any;
    const left = try types.widen(this.arena, current);
    const value = try this.expression(a.value);
    if (op.isLogical()) {
        if (declared != null and !types.assignable(value, left)) {
            try this.notAssignable(a.target.start, value, left);
        }
        return switch (op) {
            .logical_and => if (!try this.canBeTruthy(current)) current else types.unionOf(this.arena, &.{ try this.definitelyFalsy(current), value }),
            .logical_or => if (!try this.canBeFalsy(current)) current else types.unionOf(this.arena, &.{ try this.removeDefinitelyFalsy(current), value }),
            else => types.unionOf(this.arena, &.{ try this.removeNullish(current), value }),
        };
    }
    const result = try this.operator(op, a.target, a.value, left, value, true);
    if (declared != null and result.ok and !types.assignable(result.type, left)) {
        try this.notAssignable(a.target.start, result.type, left);
    }
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
fn operator(this: *Checker, op: ast.BinaryOp, left_expr: *const Expr, right_expr: *const Expr, given_left: *const Type, given_right: *const Type, compound: bool) Error!Operation {
    // Operators see a type parameter as its constraint: `x + 1` is fine for `x: T extends number`.
    const equality = op == .equal or op == .not_equal or op == .strict_equal or op == .strict_not_equal or op == .comma;
    const left = if (equality) given_left else try this.apparentType(given_left);
    const right = if (equality) given_right else try this.apparentType(given_right);
    switch (op) {
        .comma => return .{ .type = right },
        .in => {
            var ok = true;
            if (!isAny(left) and !types.isStringLike(left) and !types.isNumberLike(left)) {
                try this.report(left_expr.start, .ts(2322), "Type '{f}' is not assignable to type 'string | number | symbol'.", .{try types.widen(this.arena, left)});
                ok = false;
            }
            const r = try this.checkNonNull(right_expr, right);
            if (!isObjectType(r)) {
                try this.report(right_expr.start, .ts(2322), "Type '{f}' is not assignable to type 'object'.", .{try types.widen(this.arena, r)});
                ok = false;
            }
            return .{ .type = types.boolean, .ok = ok };
        },
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
            // Numbers compare with numbers; anything else only with what it overlaps.
            const ok = isAny(l) or isAny(r) or
                (isNumeric(l) and isNumeric(r)) or
                (!isNumeric(l) and !isNumeric(r) and types.comparable(l, r));
            if (!ok) {
                try this.operatorError(op, compound, left_expr, l, r);
            }
            return .{ .type = types.boolean, .ok = ok };
        },
        .equal, .not_equal, .strict_equal, .strict_not_equal => {
            if (isObjectLiteral(left_expr) or isObjectLiteral(right_expr)) {
                const always = if (op == .equal or op == .strict_equal) "false" else "true";
                try this.report(left_expr.start, .ts(2839), "This condition will always return '{s}' since JavaScript compares objects by reference, not value.", .{always});
            }
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

/// `t` with its generic members replaced by their constraints, where they have one.
fn apparentType(this: *Checker, t: *const Type) Error!*const Type {
    if (!types.isGeneric(t)) {
        return t;
    }
    var list: std.ArrayList(*const Type) = .empty;
    var buffer: [1]*const Type = undefined;
    for (t.members(&buffer)) |m| {
        const base = types.baseConstraint(m);
        try list.append(this.arena, if (base.* == .unknown) m else base);
    }
    return types.unionOf(this.arena, list.items);
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
        .identifier, .string, .template, .number, .boolean, .null, .function, .object, .array => true,
        .unary => |u| u.op != .void and u.op != .delete,
        .conditional => |c| isSideEffectFree(c.then) and isSideEffectFree(c.otherwise),
        .binary => |b| isSideEffectFree(b.left) and isSideEffectFree(b.right),
        .assertion => |a| isSideEffectFree(a.expr),
        else => false,
    };
}

/// tsc's `isLiteralExpressionOfObject`: an expression that makes a new object each time.
fn isObjectLiteral(expr: *const Expr) bool {
    return expr.data == .object or expr.data == .array or expr.data == .function;
}

fn isAny(t: *const Type) bool {
    return t.* == .any;
}

fn isNumeric(t: *const Type) bool {
    return isAny(t) or types.isNumberLike(t) or types.isBigIntLike(t);
}

fn member(this: *Checker, expr: *const Expr, m: ast.Member) Error!*const Type {
    const object = try this.checkNonNull(m.object, try this.expression(m.object));
    const access = try this.memberAccess(m, object) orelse return types.any;
    return this.narrowedRead(expr, access.type);
}

/// The type a property read has: `declared`, unless flow analysis has narrowed the property.
fn narrowedRead(this: *Checker, expr: *const Expr, declared: *const Type) Error!*const Type {
    if (this.flow.paths.len == 0) {
        return declared;
    }
    const reference = try this.referenceOf(expr) orelse return declared;
    return this.flow.path(reference) orelse declared;
}

/// A property that exists but isn't implemented yet (one of `known`), or null.
fn unsupportedProperty(this: *Checker, name: []const u8, at: u32, object: *const Type, known: []const []const u8) Error!?Access {
    for (known) |k| {
        if (std.mem.eql(u8, k, name)) {
            try this.unsupported(at, "The '{s}' property of '{f}' is not supported yet.", .{ name, object });
            return .{ .type = types.any, .name = name, .named = false };
        }
    }
    return null;
}

fn call(this: *Checker, expr: *const Expr, c: ast.Call) Error!*const Type {
    return this.callWith(expr, c, try this.calleeType(c), null);
}

/// The type of what a call calls, which can't be `null` or `undefined`.
fn calleeType(this: *Checker, c: ast.Call) Error!*const Type {
    return this.checkCallable(c.callee, try this.calleeExpression(c));
}

/// tsc's `checkNonNullType` for what's called, which has messages of its own.
fn checkCallable(this: *Checker, expr: *const Expr, t: *const Type) Error!*const Type {
    const inner = ast.skipParens(expr);
    if (t.* == .unknown or inner.data == .null or this.isGlobal(expr, "undefined")) {
        return this.checkNonNull(expr, t);
    }
    const has_null = includesKind(t, .null);
    const has_undefined = includesKind(t, .undefined);
    if (!has_null and !has_undefined) {
        return t;
    }
    const what = if (has_null and has_undefined) "'null' or 'undefined'" else if (has_null) "'null'" else "'undefined'";
    const code: u16 = if (has_null and has_undefined) 2723 else if (has_null) 2721 else 2722;
    try this.report(expr.start, .ts(code), "Cannot invoke an object which is possibly {s}.", .{what});
    const rest = try this.removeNullish(t);
    return if (rest.* == .never) types.any else rest;
}

fn includesKind(t: *const Type, comptime kind: std.meta.Tag(Type)) bool {
    var buffer: [1]*const Type = undefined;
    for (t.members(&buffer)) |m| {
        if (m.* == kind) {
            return true;
        }
    }
    return false;
}

fn calleeExpression(this: *Checker, c: ast.Call) Error!*const Type {
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
    return this.expression(c.callee);
}

/// A call of something of type `callee`, which has been checked. `context` is the type the call's
/// surroundings expect it to return, which type arguments can be inferred from.
fn callWith(this: *Checker, expr: *const Expr, c: ast.Call, callee_type: *const Type, context: ?*const Type) Error!*const Type {
    if (callee_type.* == .function) {
        return this.callFunction(expr, c, callee_type.function, context);
    }
    for (c.type_arguments) |node| {
        _ = try this.resolveType(node);
    }
    if (c.type_arguments.len > 0 and callee_type.* != .any) {
        try this.report(c.type_arguments[0].start, .ts(2558), "Expected 0 type arguments, but got {d}.", .{c.type_arguments.len});
    }
    for (c.arguments) |arg| {
        _ = try this.expression(arg);
    }
    switch (callee_type.*) {
        .any => return types.any,
        .@"union" => |ms| {
            for (ms) |m| {
                if (m.* != .function) {
                    try this.report(c.callee.start, .ts(2349), "This expression is not callable.\n  Not all constituents of type '{f}' are callable.", .{callee_type});
                    return types.any;
                }
            }
            try this.unsupported(c.callee.start, "Calling a union of function types is not supported yet.", .{});
            return types.any;
        },
        else => {
            try this.report(c.callee.start, .ts(2349), "This expression is not callable.\n  Type '{s}' has no call signatures.", .{try this.apparentName(callee_type)});
            return types.any;
        },
    }
}

fn callFunction(this: *Checker, expr: *const Expr, c: ast.Call, generic: *const types.Function, context: ?*const Type) Error!*const Type {
    if (generic.pending and generic.type_parameters.len > 0) {
        // tsc gives a call to a generic function whose return type is being worked out `never`,
        // rather than reporting it (TS7023), so `return f(x)` adds nothing to it.
        for (c.arguments) |arg| {
            _ = try this.contextual(arg, null);
        }
        return types.never;
    }
    var f = generic;
    var args: std.ArrayList(*const Type) = .empty;
    if (c.type_arguments.len > 0) {
        f = try this.explicitInstantiation(c, generic);
    } else if (generic.type_parameters.len > 0) {
        f = try this.inferCall(c, generic, context, &args);
    }
    if (args.items.len == 0) {
        for (c.arguments, 0..) |arg, i| {
            try args.append(this.arena, try this.contextual(arg, f.parameterType(i)));
        }
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
        const source = try this.instantiateInContext(arg_type, param);
        if (try this.excessProperty(arg, param) or types.assignable(source, param) or try this.elaborateLiteral(arg, source, param)) {
            continue;
        }
        try this.reportNotAssignable(arg, source, f.parameterType(i).?, arg.start, .argument);
    }
    return f.returns;
}

/// `f` without type parameters, with `arguments` for them.
fn instantiateSignature(this: *Checker, f: *const types.Function, arguments: []const *const Type) Error!*const types.Function {
    const plain = try this.arena.create(types.Function);
    plain.* = f.*;
    plain.type_parameters = &.{};
    const t = try this.instantiate(try this.newType(.{ .function = plain }), f.type_parameters, arguments);
    return if (t.* == .function) t.function else plain;
}

/// `f<A, B>(...)`: the signature with the type arguments given.
fn explicitInstantiation(this: *Checker, c: ast.Call, f: *const types.Function) Error!*const types.Function {
    const arguments = try this.arena.alloc(*const Type, c.type_arguments.len);
    for (c.type_arguments, arguments) |node, *t| {
        t.* = try this.resolveType(node);
    }
    const parameters = f.type_parameters;
    var required: usize = 0;
    for (parameters, 0..) |p, i| {
        if (p.param.default == null) {
            required = i + 1;
        }
    }
    if (arguments.len < required or arguments.len > parameters.len) {
        const at = c.type_arguments[0].start;
        if (required == parameters.len) {
            try this.report(at, .ts(2558), "Expected {d} type arguments, but got {d}.", .{ required, arguments.len });
        } else {
            try this.report(at, .ts(2558), "Expected {d}-{d} type arguments, but got {d}.", .{ required, parameters.len, arguments.len });
        }
        const anys = try this.arena.alloc(*const Type, parameters.len);
        @memset(anys, types.any);
        return this.instantiateSignature(f, anys);
    }
    const filled = try this.typeArguments(c.type_arguments[0].start, "", parameters, arguments, c.type_arguments) orelse unreachable;
    return this.instantiateSignature(f, filled);
}

/// Infers a generic function's type arguments from a call's arguments, the way tsc does: first
/// from the arguments that don't need a contextual type, then from the ones that do (functions
/// with untyped parameters), each typed by what's been inferred so far. The arguments' types are
/// added to `args`, since checking them again would report their errors twice.
fn inferCall(this: *Checker, c: ast.Call, f: *const types.Function, context: ?*const Type, args: *std.ArrayList(*const Type)) Error!*const types.Function {
    var inferences = try inference.Context.init(this.arena, f.type_parameters, this.mapper(&.{}, &.{}));
    // What the call's context expects it to return is a weaker source of inferences, only used
    // for type parameters the arguments say nothing about.
    var from_return = try inference.Context.init(this.arena, f.type_parameters, this.mapper(&.{}, &.{}));
    if (context) |ctx| {
        if (ctx.* != .any and ctx.* != .unknown) {
            try from_return.infer(try this.outerInferred(ctx), f.returns);
        }
    }
    const saved_argument_of = this.argument_of;
    defer this.argument_of = saved_argument_of;
    this.argument_of = .{ .inferences = &inferences, .from_return = &from_return, .returns = f.returns };
    const arg_types = try this.arena.alloc(?*const Type, c.arguments.len);
    @memset(arg_types, null);
    for (c.arguments, arg_types, 0..) |arg, *t, i| {
        const param = f.parameterType(i) orelse continue;
        if (isContextSensitive(arg)) {
            continue;
        }
        t.* = try this.contextual(arg, param);
        try inferences.infer(t.*.?, param);
    }
    for (c.arguments, arg_types, 0..) |arg, *t, i| {
        if (t.* != null) {
            continue;
        }
        const param = f.parameterType(i) orelse {
            t.* = try this.expression(arg);
            continue;
        };
        try inferences.fix(param, f.returns, &from_return);
        const so_far = try inferences.inferredTypes(f.returns, &from_return);
        t.* = try this.contextual(arg, try this.instantiate(param, f.type_parameters, so_far));
        try inferences.infer(t.*.?, param);
    }
    for (arg_types) |t| {
        try args.append(this.arena, t.?);
    }
    return this.instantiateSignature(f, try inferences.inferredTypes(f.returns, &from_return));
}

/// What the context of an argument of a generic call expects, with that call's type parameters
/// replaced by what's been inferred for them so far, so a generic call in the argument doesn't
/// infer them as its own type arguments. Ones with nothing inferred yet give no inferences
/// (tsc's return mapper).
fn outerInferred(this: *Checker, context: *const Type) Error!*const Type {
    const outer = this.argument_of orelse return context;
    const inferred = try outer.inferences.inferredTypes(outer.returns, outer.from_return);
    const from = try this.arena.alloc(*const Type, inferred.len);
    const to = try this.arena.alloc(*const Type, inferred.len);
    for (outer.inferences.inferences, from, to, inferred, 0..) |i, *x, *y, t, index| {
        x.* = i.parameter;
        const known = i.fixed != null or outer.inferences.hasCandidates(index) or outer.from_return.hasCandidates(index);
        y.* = if (known) t else inference.no_inference;
    }
    return this.instantiate(context, from, to);
}

/// tsc's `isContextSensitive`: an expression whose type depends on the type its context
/// expects, like a function with untyped parameters. Inference leaves those for last.
fn isContextSensitive(expr: *const Expr) bool {
    const e = ast.skipParens(expr);
    return switch (e.data) {
        .function => |f| blk: {
            for (f.parameters) |p| {
                if (p.type == null) {
                    break :blk true;
                }
            }
            break :blk f.type_parameters.len == 0 and f.body == .expression and f.parameters.len > 0 and isContextSensitive(f.body.expression);
        },
        .object => |o| for (o.properties) |p| {
            if (p == .property and isContextSensitive(p.property.value)) {
                break true;
            }
        } else false,
        .array => |a| for (a.elements) |element| {
            if (element == .expr and isContextSensitive(element.expr)) {
                break true;
            }
        } else false,
        .conditional => |c| isContextSensitive(c.then) or isContextSensitive(c.otherwise),
        else => false,
    };
}

/// A generic function used where a non-generic one is expected, as `id` is in
/// `const f: (x: number) => number = id`, is instantiated for it: its type arguments are
/// inferred from the expected parameters (tsc's `instantiateSignatureInContextOf`). So is one in
/// a property or element, as in `const o: { f: (x: number) => number } = { f: id }`.
fn instantiateInContext(this: *Checker, source: *const Type, target: *const Type) Error!*const Type {
    switch (source.*) {
        .function => |f| if (f.type_parameters.len == 0) {
            return source;
        },
        .object => |o| {
            if (target.* != .object) {
                return source;
            }
            var properties: ?[]types.Property = null;
            for (o.properties, 0..) |p, i| {
                const expected = target.object.property(p.name) orelse continue;
                const t = try this.instantiateInContext(p.type, expected);
                if (t != p.type) {
                    if (properties == null) {
                        properties = try this.arena.dupe(types.Property, o.properties);
                    }
                    properties.?[i].type = t;
                }
            }
            const object = try this.arena.create(types.Object);
            object.* = .{ .properties = properties orelse return source };
            return this.newType(.{ .object = object });
        },
        .array, .readonly_array => |e| {
            const expected = types.arrayElement(target) orelse return source;
            const t = try this.instantiateInContext(e, expected);
            if (t == e) {
                return source;
            }
            return this.newType(if (source.* == .array) .{ .array = t } else .{ .readonly_array = t });
        },
        .tuple => |es| {
            var elements: ?[]*const Type = null;
            for (es, 0..) |e, i| {
                const expected = switch (target.*) {
                    .tuple => |ts| if (i < ts.len) ts[i] else continue,
                    .array, .readonly_array => |x| x,
                    else => return source,
                };
                const t = try this.instantiateInContext(e, expected);
                if (t != e) {
                    if (elements == null) {
                        elements = try this.arena.dupe(*const Type, es);
                    }
                    elements.?[i] = t;
                }
            }
            return this.newType(.{ .tuple = elements orelse return source });
        },
        else => return source,
    }
    const t = contextualSignature(target) orelse return source;
    if (t.type_parameters.len > 0) {
        return source;
    }
    const s = source.function;
    var inferences = try inference.Context.init(this.arena, s.type_parameters, this.mapper(&.{}, &.{}));
    const count = @max(s.parameters.len, t.parameters.len) + @intFromBool(s.rest != null and t.rest != null);
    for (0..count) |i| {
        const sp = s.parameterType(i) orelse continue;
        const tp = t.parameterType(i) orelse continue;
        try inferences.infer(tp, sp);
    }
    var from_return = try inference.Context.init(this.arena, s.type_parameters, this.mapper(&.{}, &.{}));
    try from_return.infer(t.returns, s.returns);
    return this.newType(.{ .function = try this.instantiateSignature(s, try inferences.inferredTypes(s.returns, &from_return)) });
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
    const saved_const = this.const_context;
    const saved_argument_of = this.argument_of;
    // A call in its body isn't an argument of a call around it.
    this.argument_of = null;
    this.const_context = false;
    defer {
        this.argument_of = saved_argument_of;
        this.const_context = saved_const;
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
        // A generic function isn't typed by a generic context.
        if (f.type_parameters.len > 0 and ctx.type_parameters.len > 0) {
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
    signature.type_parameters = try this.declareTypeParameters(f.type_parameters);
    if (context) |c| {
        // A function typed by a generic context, like `const f: <T>(x: T) => T = (x) => x`, is
        // generic too.
        const untyped = for (f.parameters) |p| {
            if (p.type == null) {
                break true;
            }
        } else false;
        if (f.type_parameters.len == 0 and untyped) {
            signature.type_parameters = c.type_parameters;
        }
    }

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
        if (p.pattern) |pattern| {
            try this.declarePattern(pattern, .parameter, p.end, null);
        } else {
            try this.declare(this.slot_base + p.binding, .{ .name = p.name, .kind = .parameter, .start = p.start, .end = p.end, .source = this.source, .annotation = p.type, .init = p.init });
        }
    }
    for (f.parameters, 0..) |*p, i| {
        const slot = this.slot_base + p.binding;
        // A destructured parameter has no variable of its own.
        const v: ?*Variable = if (p.pattern == null) this.variable(slot) else null;
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
            if (p.rest and t.* != .array and t.* != .readonly_array and t.* != .any) {
                try this.report(annotation.start, .ts(2370), "A rest parameter must be of an array type.", .{});
                t = types.any_array;
            }
        } else if (from_context) |c| {
            t = c;
        } else if (p.init == null and p.pattern == null) {
            if (p.rest) {
                try this.report(p.node_start, .ts(7019), "Rest parameter '{s}' implicitly has an 'any[]' type.", .{p.name});
                t = types.any_array;
            } else {
                try this.report(p.start, .ts(7006), "Parameter '{s}' implicitly has an 'any' type.", .{p.name});
            }
        }
        const typed = p.type != null or from_context != null;
        if (p.init) |init| {
            this.parameter = p.name;
            if (v) |x| {
                x.resolving = !typed;
            }
            const init_type = if (!typed and p.pattern != null) try this.patternInitializer(init, p.pattern.?) else try this.contextual(init, if (typed) t else null);
            if (v) |x| {
                x.resolving = false;
            }
            this.parameter = null;
            if (!typed) {
                t = if (v != null and v.?.circular) types.any else try types.widenFresh(this.arena, init_type);
            } else {
                try this.checkAssignable(init, init_type, t, p.start, .assignment);
            }
        }
        if (p.pattern) |pattern| {
            t = try this.bindPattern(pattern, if (typed or p.init != null) t else null, .{ .widen = true, .annotated = p.type != null });
        }
        if (!p.optional and p.init == null and !p.rest and seen_optional) {
            try this.report(p.start, .ts(1016), "A required parameter cannot follow an optional parameter.", .{});
        }
        seen_optional = seen_optional or p.optional;
        if (p.optional) {
            t = try types.unionOf(this.arena, &.{ t, types.undefined });
        }
        if (v) |x| {
            x.declared = t;
            this.flow.vars[slot] = .{ .initialized = true, .type = t };
        }
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
                try this.checkAssignable(e, t, r, e.start, .assignment);
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
        .array, .readonly_array => |e| refersTo(e, target),
        .tuple => |es| for (es) |e| {
            if (refersTo(e, target)) {
                break true;
            }
        } else false,
        // A named object type can refer to itself, so it isn't looked into.
        .object => |o| o.name.len == 0 and for (o.properties) |p| {
            if (refersTo(p.type, target)) {
                break true;
            }
        } else false,
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
            try this.checkAssignable(v, t, r, stmt.start, .assignment);
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
fn reportNotAssignable(this: *Checker, expr: *const Expr, source: *const Type, target: *const Type, at: u32, kind: Use) Error!void {
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
    if (source.* == .readonly_array and target.* == .array and types.assignable(source.readonly_array, target.array)) {
        const text = try std.fmt.allocPrint(this.arena, "The type '{f}' is 'readonly' and cannot be assigned to the mutable type '{f}'.", .{ source, target });
        switch (kind) {
            .assignment => return this.report(at, .ts(4104), "{s}", .{text}),
            .argument => return this.report(at, .ts(2345), "Argument of type '{f}' is not assignable to parameter of type '{f}'.\n  {s}", .{ source, target, text }),
        }
    }
    // A missing property is the whole message for an assignment, and the elaboration for an
    // argument.
    if (contextObject(target)) |object| {
        if (types.objectMismatch(source, object, null)) |mismatch| {
            if (mismatch == .missing) {
                const missing = try this.missingMessage(source, object, target);
                switch (kind) {
                    .assignment => return this.report(at, missing.code, "{s}", .{missing.text}),
                    .argument => return this.report(at, .ts(2345), "Argument of type '{f}' is not assignable to parameter of type '{f}'.\n  {s}", .{ try this.shownSource(source, target), target, missing.text }),
                }
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

const Message = struct {
    code: diagnostic.Code,
    text: []const u8,
};

/// TS2741, TS2739 or TS2740: the properties `source` lacks.
fn missingMessage(this: *Checker, source: *const Type, object: *const types.Object, target: *const Type) Error!Message {
    const missing = try types.missingProperties(this.arena, source, object);
    const shown = target_shown(target, object);
    if (missing.len == 1) {
        return .{ .code = .ts(2741), .text = try std.fmt.allocPrint(this.arena, "Property '{s}' is missing in type '{f}' but required in type '{f}'.", .{ missing[0], source, shown }) };
    }
    const listed = missing[0..@min(missing.len, 4)];
    const names = try std.mem.join(this.arena, ", ", listed);
    if (missing.len > 4) {
        return .{ .code = .ts(2740), .text = try std.fmt.allocPrint(this.arena, "Type '{f}' is missing the following properties from type '{f}': {s}, and {d} more.", .{ source, shown, names, missing.len - 4 }) };
    }
    return .{ .code = .ts(2739), .text = try std.fmt.allocPrint(this.arena, "Type '{f}' is missing the following properties from type '{f}': {s}", .{ source, shown, names }) };
}

/// The lines tsc adds to say why one type isn't assignable to another.
fn elaborate(this: *Checker, source: *const Type, target: *const Type) Error![]const u8 {
    if (contextObject(target)) |object| {
        const mismatch = types.objectMismatch(source, object, null) orelse return "";
        const shown = target_shown(target, object);
        return switch (mismatch) {
            .not_object, .missing => "",
            .optional => |name| std.fmt.allocPrint(this.arena, "\n  Property '{s}' is optional in type '{f}' but required in type '{f}'.", .{ name, source, shown }),
            .property => |name| blk: {
                if (source.* != .object) {
                    break :blk "";
                }
                const from = source.object.property(name).?;
                const to = object.property(name).?;
                break :blk std.fmt.allocPrint(this.arena, "\n  Types of property '{s}' are incompatible.\n    Type '{f}' is not assignable to type '{f}'.", .{ name, try this.shownSource(from, to), to });
            },
        };
    }
    if (target.* == .tuple) {
        if (source.* == .tuple and source.tuple.len < target.tuple.len) {
            return std.fmt.allocPrint(this.arena, "\n  Source has {d} element(s) but target requires {d}.", .{ source.tuple.len, target.tuple.len });
        }
        if (source.* == .tuple and source.tuple.len > target.tuple.len) {
            return std.fmt.allocPrint(this.arena, "\n  Source has {d} element(s) but target allows only {d}.", .{ source.tuple.len, target.tuple.len });
        }
        if (source.* == .array) {
            return std.fmt.allocPrint(this.arena, "\n  Target requires {d} element(s) but source may have fewer.", .{target.tuple.len});
        }
    }
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
        .chain => |inner| this.entityName(inner),
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
    const e = ast.skipOuter(expr);
    return switch (e.data) {
        // `while (0)` and `while (1)` are allowed idioms.
        .number => |n| if (n == 0 or n == 1) .sometimes else .always,
        .string => |s| if (s.len == 0) .never else .always,
        .template => |t| if (t.substitutions.len > 0) .sometimes else if (t.quasis[0].len == 0) .never else .always,
        .null => .never,
        .unary => |u| if (u.op == .void) .never else .sometimes,
        .identifier => if (this.isGlobal(e, "undefined")) .never else .sometimes,
        .conditional => |c| combine(this.truthySemantics(c.then), this.truthySemantics(c.otherwise)),
        .function, .object, .array => .always,
        else => .sometimes,
    };
}

/// tsc's syntactic nullishness check for the left side of `??` (TS2869/TS2871).
fn nullishSemantics(this: *const Checker, expr: *const Expr) Semantics {
    const e = ast.skipOuter(expr);
    return switch (e.data) {
        .null => .always,
        .identifier => if (this.isGlobal(e, "undefined")) .always else .sometimes,
        .member, .index, .call, .chain => .sometimes,
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

const isFalsyLiteral = narrowing.isFalsyLiteral;

fn canBeFalsy(this: *Checker, t: *const Type) Error!bool {
    var buffer: [1]*const Type = undefined;
    for (t.members(&buffer)) |m| {
        switch (m.*) {
            .literal => if (isFalsyLiteral(m)) return true,
            .object, .function, .array, .tuple, .readonly_array, .never => {},
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
        .paren, .chain, .non_null => |inner| this.uses(inner, target),
        .assertion => |a| this.uses(a.expr, target),
        .unary => |u| this.uses(u.operand, target),
        .update => |u| this.uses(u.operand, target),
        .assign => |a| this.uses(a.target, target) or this.uses(a.value, target),
        .binary => |b| this.uses(b.left, target) or this.uses(b.right, target),
        .conditional => |c| this.uses(c.condition, target) or this.uses(c.then, target) or this.uses(c.otherwise, target),
        .member => |m| this.uses(m.object, target),
        .index => |i| this.uses(i.object, target) or this.uses(i.index, target),
        .call => |c| this.uses(c.callee, target) or for (c.arguments) |arg| {
            if (this.uses(arg, target)) {
                break true;
            }
        } else false,
        .function => |f| this.usesInFunction(f, target),
        .object => |o| for (o.properties) |p| {
            const used = switch (p) {
                .property => |prop| (prop.key == .computed and this.uses(prop.key.computed, target)) or this.uses(prop.value, target),
                .spread => |spread| this.uses(spread.expr, target),
            };
            if (used) {
                break true;
            }
        } else false,
        .array => |a| for (a.elements) |element| {
            switch (element) {
                .expr, .spread => |e| if (this.uses(e, target)) break true,
            }
        } else false,
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
        .interface, .type_alias => false,
        .throw => |e| this.uses(e, target),
        .for_each => |f| (f.head == .target and this.uses(f.head.target, target)) or this.uses(f.right, target) or this.usesInStatement(f.body, target),
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
