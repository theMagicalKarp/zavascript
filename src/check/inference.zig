//! Type argument inference for calls of generic functions: what tsc's `inferTypes` and
//! `getInferredType` do, for the kinds of types we have. Each argument's type is matched against
//! its parameter's type to find candidates for the type parameters, and each type parameter's
//! candidates are then combined into its type argument.

const std = @import("std");
const types = @import("types.zig");
const Type = types.Type;

const Error = error{OutOfMemory};

/// Stands for a type parameter nothing's been inferred for yet, which nothing is inferred from
/// (tsc's `silentNeverType`).
pub const no_inference: *const Type = &no_inference_storage;
/// A variable, so its address is its own rather than `types.never`'s.
var no_inference_storage: Type = .never;

/// What's been inferred for one type parameter.
const Inference = struct {
    parameter: *const Type,
    /// Candidates from where the type parameter is used for what's passed in.
    candidates: std.ArrayList(*const Type) = .empty,
    /// Candidates from where it's used for what's passed back, like a callback's parameters.
    contra: std.ArrayList(*const Type) = .empty,
    /// Candidates from inside mapped types, like `T` from `Partial<T>`, only used when there are
    /// no others (tsc's lower inference priorities).
    weak: std.ArrayList(*const Type) = .empty,
    /// Every candidate came from the top level of a parameter's type (`x: T` or `x: T | null`),
    /// not from inside it (`x: T[]`). Only those are widened.
    top_level: bool = true,
    /// Its type argument, once it's been fixed: a callback's parameter has been typed with it, so
    /// later candidates can't change it.
    fixed: ?*const Type = null,
};

pub const Context = struct {
    arena: std.mem.Allocator,
    inferences: []Inference,
    /// For instantiating generic types the inferences go through.
    mapper: types.Mapper,

    pub fn init(arena: std.mem.Allocator, parameters: []const *const Type, mapper: types.Mapper) Error!Context {
        const inferences = try arena.alloc(Inference, parameters.len);
        for (inferences, parameters) |*i, p| {
            i.* = .{ .parameter = p };
        }
        return .{ .arena = arena, .inferences = inferences, .mapper = mapper };
    }

    fn find(this: *Context, t: *const Type) ?*Inference {
        if (t.* != .param) {
            return null;
        }
        for (this.inferences) |*i| {
            if (i.parameter == t) {
                return i;
            }
        }
        return null;
    }

    /// Whether any candidate has been found for the type parameter at `index`.
    pub fn hasCandidates(this: *const Context, index: usize) bool {
        const i = this.inferences[index];
        return i.candidates.items.len > 0 or i.contra.items.len > 0 or i.weak.items.len > 0;
    }

    /// Infers from a value of type `source` being used where `target` is expected.
    pub fn infer(this: *Context, source: *const Type, target: *const Type) Error!void {
        return this.inferIn(source, target, false, true, 0);
    }

    fn inferIn(this: *Context, source: *const Type, target: *const Type, contra: bool, top: bool, depth: u32) Error!void {
        if (depth > 32 or source == no_inference or !types.mentionsParameters(target)) {
            return;
        }
        if (this.find(target)) |i| {
            if (i.fixed != null) {
                return;
            }
            try (if (contra) &i.contra else &i.candidates).append(this.arena, source);
            if (!top) {
                i.top_level = false;
            }
            return;
        }
        if (target.* == .@"union") {
            return this.inferToUnion(source, target, contra, top, depth);
        }
        if (source.* == .@"union") {
            for (source.@"union") |m| {
                try this.inferIn(m, target, contra, false, depth + 1);
            }
            return;
        }
        switch (target.*) {
            .array, .readonly_array => |element| switch (source.*) {
                .array, .readonly_array => |e| try this.inferIn(e, element, contra, false, depth + 1),
                .tuple => |es| for (es) |e| {
                    try this.inferIn(e, element, contra, false, depth + 1);
                },
                else => {},
            },
            .tuple => |ts| switch (source.*) {
                .tuple => |ss| if (ss.len == ts.len) for (ss, ts) |s, t| {
                    try this.inferIn(s, t, contra, false, depth + 1);
                },
                .array, .readonly_array => |e| for (ts) |t| {
                    try this.inferIn(e, t, contra, false, depth + 1);
                },
                else => {},
            },
            .object => |to| {
                if (source.* != .object) {
                    return;
                }
                const so = source.object;
                if (to.generic != null and so.generic == to.generic and so.type_arguments.len == to.type_arguments.len) {
                    // `Box<number>` to `Box<T>`.
                    for (so.type_arguments, to.type_arguments) |s, t| {
                        try this.inferIn(s, t, contra, false, depth + 1);
                    }
                    return;
                }
                for (to.properties) |tp| {
                    const sp = so.find(tp.name) orelse continue;
                    try this.inferIn(sp.type, tp.type, contra, false, depth + 1);
                }
            },
            .function => |tf| {
                if (source.* != .function) {
                    return;
                }
                // A generic function is matched by what it is for any type arguments: its type
                // parameters' constraints.
                const sf = try this.baseSignature(source.function);
                const count = @max(sf.parameters.len, tf.parameters.len) + @intFromBool(sf.rest != null and tf.rest != null);
                for (0..count) |index| {
                    const s = sf.parameterType(index) orelse continue;
                    const t = tf.parameterType(index) orelse continue;
                    try this.inferIn(s, t, !contra, false, depth + 1);
                }
                try this.inferIn(sf.returns, tf.returns, contra, false, depth + 1);
            },
            .mapped => |m| try this.inferToMapped(source, m, contra, depth),
            else => {},
        }
    }

    /// tsc's `inferToMultipleTypes`: the members of `source` that match none of the target's other
    /// members are inferred for its one naked type parameter, as `number` is for `T` from
    /// `number | null` to `T | null`.
    fn inferToUnion(this: *Context, source: *const Type, target: *const Type, contra: bool, top: bool, depth: u32) Error!void {
        var naked: ?*Inference = null;
        var naked_count: usize = 0;
        for (target.@"union") |m| {
            if (this.find(m)) |i| {
                naked = i;
                naked_count += 1;
            } else {
                try this.inferIn(source, m, contra, false, depth + 1);
            }
        }
        if (naked_count != 1) {
            return;
        }
        var unmatched: std.ArrayList(*const Type) = .empty;
        var buffer: [1]*const Type = undefined;
        for (source.members(&buffer)) |s| {
            const matched = for (target.@"union") |m| {
                if (this.find(m) == null and (s.eql(m) or (s.* == .literal and m.* == .literal and types.assignable(s, m)))) {
                    break true;
                }
            } else false;
            if (!matched) {
                try unmatched.append(this.arena, s);
            }
        }
        if (unmatched.items.len == 0) {
            return;
        }
        const i = naked.?;
        if (i.fixed != null) {
            return;
        }
        const t = try types.unionOf(this.arena, unmatched.items);
        try (if (contra) &i.contra else &i.candidates).append(this.arena, t);
        if (!top) {
            i.top_level = false;
        }
    }

    /// `{ [P in keyof T]: X }` and `{ [P in K]: X }`: what tsc's `inferToMappedType` does,
    /// approximately. For the first, `T` is inferred as the source itself; for the second, `K` as
    /// the source's keys, and `X` from each property.
    fn inferToMapped(this: *Context, source: *const Type, m: *const types.Mapped, contra: bool, depth: u32) Error!void {
        if (source.* != .object) {
            return;
        }
        if (contra) {
            return;
        }
        if (m.constraint.* == .keyof) {
            if (this.find(m.constraint.keyof)) |i| {
                if (i.fixed == null) {
                    try i.weak.append(this.arena, source);
                }
            }
            return;
        }
        if (this.find(m.constraint)) |i| {
            if (try types.keyOf(this.arena, source)) |keys| {
                if (i.fixed == null) {
                    try i.weak.append(this.arena, keys);
                }
            }
            for (source.object.properties) |p| {
                try this.inferIn(p.type, m.template, contra, false, depth + 1);
            }
        }
    }

    /// A generic function with its type parameters replaced by their constraints.
    fn baseSignature(this: *Context, f: *const types.Function) Error!*const types.Function {
        if (f.type_parameters.len == 0) {
            return f;
        }
        const constraints = try this.arena.alloc(*const Type, f.type_parameters.len);
        for (constraints, f.type_parameters) |*c, p| {
            c.* = p.param.constraint orelse types.unknown;
        }
        const plain = try this.arena.create(types.Function);
        plain.* = f.*;
        plain.type_parameters = &.{};
        const t: Type = .{ .function = plain };
        const instantiated = try types.instantiate(this.arena, &t, &this.mapper.with(f.type_parameters, constraints));
        return if (instantiated.* == .function) instantiated.function else plain;
    }

    /// Fixes the type parameters that the parameters of the function types in `target` mention:
    /// those are about to type a callback's parameters (tsc's fixing mapper).
    pub fn fix(this: *Context, target: *const Type, returns: *const Type, fallback: ?*Context) Error!void {
        var mentioned: std.ArrayList(*const Type) = .empty;
        try collectCallbackParameters(this.arena, target, &mentioned, false);
        const inferred = try this.inferredTypesWith(returns, fallback, true);
        for (this.inferences, inferred) |*i, t| {
            if (i.fixed == null and std.mem.indexOfScalar(*const Type, mentioned.items, i.parameter) != null) {
                i.fixed = t;
            }
        }
    }

    /// The type argument inferred for each type parameter, as tsc's `getInferredType` works it
    /// out. `returns` is the function's return type: a type parameter that's all of it (or a
    /// member of it) keeps its literal candidates, so `id("a")` is `"a"`. `fallback` has
    /// candidates to use for type parameters that have none here, from what the call's context
    /// expects it to return.
    pub fn inferredTypes(this: *Context, returns: *const Type, fallback: ?*Context) Error![]const *const Type {
        return this.inferredTypesWith(returns, fallback, false);
    }

    /// `fixing` is for type parameters about to be fixed, whose literal candidates are widened
    /// even where they're returned.
    fn inferredTypesWith(this: *Context, returns: *const Type, fallback: ?*Context, fixing: bool) Error![]const *const Type {
        const parameters = try this.arena.alloc(*const Type, this.inferences.len);
        const result = try this.arena.alloc(*const Type, this.inferences.len);
        for (this.inferences, parameters, result) |inference, *p, *r| {
            p.* = inference.parameter;
            // Until it's known, a type parameter that a later one's constraint mentions is
            // `unknown`.
            r.* = types.unknown;
        }
        for (this.inferences, 0..) |*inference, index| {
            var i = inference;
            if (fallback) |f| {
                if (!this.hasCandidates(index) and f.hasCandidates(index)) {
                    i = &f.inferences[index];
                }
            }
            if (inference.fixed) |fixed| {
                result[index] = fixed;
                continue;
            }
            const param = i.parameter.param;
            const mapper = this.mapper.with(parameters[0..index], result[0..index]);
            const constraint = if (param.constraint) |c| try types.instantiate(this.arena, c, &mapper) else null;
            var t: ?*const Type = null;
            if (i.candidates.items.len > 0) {
                const primitive = if (param.constraint) |c| hasPrimitiveConstraint(c) else false;
                const widen = !primitive and i.top_level and (fixing or !atTopLevel(returns, i.parameter));
                const base = try this.arena.alloc(*const Type, i.candidates.items.len);
                for (base, i.candidates.items) |*b, c| {
                    b.* = if (primitive) try types.regular(this.arena, c) else if (widen) try types.widenFresh(this.arena, c) else c;
                }
                t = try commonSupertype(this.arena, base);
                // tsc's `preferCovariantType`: the covariant inference is only used if it fits
                // one of the contravariant ones, if there are any.
                if (i.contra.items.len > 0) {
                    const fits = for (i.contra.items) |c| {
                        if (types.assignable(t.?, c)) {
                            break true;
                        }
                    } else false;
                    if (!fits) {
                        t = commonSubtype(i.contra.items);
                    }
                }
            } else if (i.contra.items.len > 0) {
                t = commonSubtype(i.contra.items);
            } else if (i.weak.items.len > 0) {
                t = try commonSupertype(this.arena, i.weak.items);
            }
            if (t == null) {
                if (param.default) |d| {
                    t = try types.instantiate(this.arena, d, &mapper);
                } else {
                    t = constraint orelse types.unknown;
                }
            } else if (constraint) |c| {
                if (!types.assignable(t.?, c)) {
                    t = c;
                }
            }
            result[index] = t.?;
        }
        return result;
    }
};

/// The type parameters the parameters of function types in `t` mention.
fn collectCallbackParameters(arena: std.mem.Allocator, t: *const Type, list: *std.ArrayList(*const Type), in_parameter: bool) Error!void {
    switch (t.*) {
        .param => if (in_parameter) try list.append(arena, t),
        .@"union", .tuple => |ms| for (ms) |m| {
            try collectCallbackParameters(arena, m, list, in_parameter);
        },
        .array, .readonly_array => |e| try collectCallbackParameters(arena, e, list, in_parameter),
        .object => |o| if (o.name.len == 0) for (o.properties) |p| {
            try collectCallbackParameters(arena, p.type, list, in_parameter);
        },
        .function => |f| {
            for (f.parameters) |p| {
                try collectCallbackParameters(arena, p.type, list, true);
            }
            if (f.rest) |r| {
                try collectCallbackParameters(arena, r.type, list, true);
            }
            try collectCallbackParameters(arena, f.returns, list, in_parameter);
        },
        .keyof => |e| try collectCallbackParameters(arena, e, list, in_parameter),
        .indexed => |x| {
            try collectCallbackParameters(arena, x.object, list, in_parameter);
            try collectCallbackParameters(arena, x.index, list, in_parameter);
        },
        else => {},
    }
}

/// tsc's `hasPrimitiveConstraint`: the constraint could be a primitive, so literal candidates are
/// kept as they are.
fn hasPrimitiveConstraint(constraint: *const Type) bool {
    var buffer: [1]*const Type = undefined;
    for (constraint.members(&buffer)) |m| {
        switch (m.*) {
            .string, .number, .boolean, .bigint, .literal, .null, .undefined, .void, .keyof => return true,
            .param => |p| if (p.constraint) |c| {
                if (hasPrimitiveConstraint(c)) {
                    return true;
                }
            },
            else => {},
        }
    }
    return false;
}

/// Whether `t` is `parameter`, or a union with it as a member.
fn atTopLevel(t: *const Type, parameter: *const Type) bool {
    var buffer: [1]*const Type = undefined;
    for (t.members(&buffer)) |m| {
        if (m == parameter) {
            return true;
        }
    }
    return false;
}

/// tsc's `getCommonSupertype`: literals of the same primitive make a union (`1 | 2`); otherwise
/// the first candidate that every one before it is assignable to.
fn commonSupertype(arena: std.mem.Allocator, candidates: []const *const Type) Error!*const Type {
    if (sameBasePrimitive(candidates)) {
        return types.unionOf(arena, candidates);
    }
    var s = candidates[0];
    for (candidates[1..]) |t| {
        if (types.assignable(s, t)) {
            s = t;
        }
    }
    return s;
}

fn sameBasePrimitive(candidates: []const *const Type) bool {
    var kind: ?std.meta.Tag(Type) = null;
    for (candidates) |c| {
        var buffer: [1]*const Type = undefined;
        for (c.members(&buffer)) |m| {
            const base: std.meta.Tag(Type) = switch (m.*) {
                .literal => |lit| switch (lit.value) {
                    .number => .number,
                    .string => .string,
                    .boolean => .boolean,
                },
                .number, .string, .boolean => m.*,
                else => return false,
            };
            if (kind != null and kind.? != base) {
                return false;
            }
            kind = base;
        }
    }
    return true;
}

/// The candidate that's assignable to every other one, or else the first.
fn commonSubtype(candidates: []const *const Type) *const Type {
    for (candidates) |c| {
        const all = for (candidates) |other| {
            if (!types.assignable(c, other)) {
                break false;
            }
        } else true;
        if (all) {
            return c;
        }
    }
    return candidates[0];
}
