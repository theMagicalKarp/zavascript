//! The syntax tree. Every node is allocated in the arena of the `Program` that owns it, and every
//! node keeps the byte offset it starts at for diagnostics.

const std = @import("std");

pub const Program = struct {
    statements: []const *Stmt,
    /// How many `Identifier` references the program has. Each has a dense `ref` index below this,
    /// so the checker can record what each one resolves to in a flat side table.
    reference_count: u32,
    /// How many names the program declares: variables, parameters and functions. Each has a dense
    /// `binding` index below this.
    binding_count: u32,
    /// How many block scopes the program has (blocks, `for` heads, `switch` bodies and function
    /// parameter lists). Each has a dense `scope` index below this.
    scope_count: u32,
    /// How many functions the program has. Each `Function` has a dense `id` below this.
    function_count: u32,
    /// Where each type annotation is, from its `:` (or a parameter's `?`) to the end of the type,
    /// in source order. Node prints a function's source with these blanked out, since it strips
    /// types by replacing them with spaces.
    type_spans: []const Span,
};

pub const Span = struct {
    start: u32,
    end: u32,
};

pub const Stmt = struct {
    start: u32,
    end: u32,
    data: Data,

    pub const Data = union(enum) {
        expression: *Expr,
        /// A lone `;`.
        empty,
        variable: Variable,
        function: *const Function,
        @"return": ?*Expr,
        block: Block,
        @"if": If,
        @"while": Loop,
        do_while: Loop,
        @"for": For,
        @"break": Jump,
        @"continue": Jump,
        labeled: Labeled,
        @"switch": Switch,
        /// `for (x of xs)` and `for (k in o)`.
        for_each: ForEach,
        interface: *const Interface,
        type_alias: *const TypeAlias,
        throw: *Expr,
        /// `declare var x: T;` or `declare function f(): T;`, only in a `.d.ts` file.
        declare: *const Declare,
    };
};

/// A declaration of a value that exists without the program creating it, like the builtins in
/// `lib.d.ts`. A function declared more than once is overloaded.
pub const Declare = struct {
    name: []const u8,
    start: u32,
    /// A variable's type annotation, or a function's signature as a function type.
    type: *const TypeNode,
    function: bool,
};

/// `{ ... }`, which is a scope of its own.
pub const Block = struct {
    statements: []const *Stmt,
    scope: u32,
    /// It declares functions, which are created when it's entered.
    declares_functions: bool,
};

pub const VariableKind = enum {
    let,
    @"const",
};

/// `let a = 1, b: number;`
pub const Variable = struct {
    kind: VariableKind,
    declarators: []const Declarator,
};

pub const Declarator = struct {
    /// The declared name; empty when `pattern` is set.
    name: []const u8,
    /// Where the name (or the pattern) starts.
    start: u32,
    /// Where the declarator (including its initializer) ends. A reference before this point is a
    /// use before declaration (TS2448).
    end: u32,
    /// Dense index among the program's declarations; see `Program.binding_count`. Unused when
    /// `pattern` is set, since each name in the pattern has its own.
    binding: u32,
    /// `const { a, b } = ...` or `const [a, b] = ...`.
    pattern: ?*const Pattern = null,
    type: ?*const TypeNode,
    init: ?*Expr,
};

/// A destructuring pattern, or a plain name inside one.
pub const Pattern = struct {
    start: u32,
    data: Data,

    pub const Data = union(enum) {
        identifier: Binding,
        object: ObjectPattern,
        array: ArrayPattern,
    };

    /// Every name the pattern declares, in source order.
    pub fn bindings(this: *const Pattern, arena: std.mem.Allocator) error{OutOfMemory}![]const Binding {
        var list: std.ArrayList(Binding) = .empty;
        try this.collect(arena, &list);
        return list.items;
    }

    fn collect(this: *const Pattern, arena: std.mem.Allocator, list: *std.ArrayList(Binding)) error{OutOfMemory}!void {
        switch (this.data) {
            .identifier => |b| try list.append(arena, b),
            .object => |o| {
                for (o.properties) |p| {
                    try p.value.collect(arena, list);
                }
                if (o.rest) |r| {
                    try list.append(arena, r);
                }
            },
            .array => |a| {
                for (a.elements) |e| {
                    if (e) |element| {
                        try element.pattern.collect(arena, list);
                    }
                }
                if (a.rest) |r| {
                    try r.collect(arena, list);
                }
            },
        }
    }
};

pub const Binding = struct {
    name: []const u8,
    start: u32,
    binding: u32,
};

/// `{ a, b: c = 1, ...rest }`
pub const ObjectPattern = struct {
    properties: []const PatternProperty,
    rest: ?Binding,
};

pub const PatternProperty = struct {
    key: []const u8,
    key_start: u32,
    value: *const Pattern,
    /// The default value, for when the property is `undefined`.
    init: ?*Expr,
};

/// `[a, , b = 1, ...rest]`
pub const ArrayPattern = struct {
    /// Null for a hole.
    elements: []const ?PatternElement,
    rest: ?*const Pattern,
};

pub const PatternElement = struct {
    pattern: *const Pattern,
    init: ?*Expr,
};

pub const If = struct {
    condition: *Expr,
    then: *Stmt,
    otherwise: ?*Stmt,
};

/// `while (condition) body` and `do body while (condition)`.
pub const Loop = struct {
    condition: *Expr,
    body: *Stmt,
};

/// `for (const x of xs) body`, `for (k in o) body`, and so on.
pub const ForEach = struct {
    /// `of` or `in`.
    of: bool,
    /// The scope of the variables the head declares.
    scope: u32,
    /// What each value is assigned to: a declaration, or an existing variable.
    head: Head,
    right: *Expr,
    body: *Stmt,

    pub const Head = union(enum) {
        declaration: struct { kind: VariableKind, pattern: *const Pattern, end: u32 },
        target: *Expr,
    };
};

pub const For = struct {
    /// The scope of the variables the head declares.
    scope: u32,
    /// A `variable` or `expression` statement.
    init: ?*Stmt,
    condition: ?*Expr,
    update: ?*Expr,
    body: *Stmt,
};

/// `break` or `continue`, with an optional label.
pub const Jump = struct {
    label: ?[]const u8,
};

pub const Labeled = struct {
    label: []const u8,
    body: *Stmt,
};

pub const Switch = struct {
    /// The clauses share one scope.
    scope: u32,
    discriminant: *Expr,
    clauses: []const Clause,
};

pub const Clause = struct {
    start: u32,
    /// Null for `default:`.
    case: ?*Expr,
    statements: []const *Stmt,
};

/// `interface Name<T> extends A, B<T> { members }`
pub const Interface = struct {
    name: []const u8,
    start: u32,
    type_parameters: []const GenericParameter = &.{},
    extends: []const TypeReference,
    members: []const TypeMember,
};

/// `type Name<T> = T;`
pub const TypeAlias = struct {
    name: []const u8,
    start: u32,
    type_parameters: []const GenericParameter = &.{},
    type: *const TypeNode,
};

/// A type's name, with its type arguments: `Box<number>`.
pub const TypeReference = struct {
    name: []const u8,
    start: u32,
    arguments: []const *const TypeNode = &.{},
};

/// `T extends C = D` in a list of type parameters.
pub const GenericParameter = struct {
    name: []const u8,
    start: u32,
    constraint: ?*const TypeNode = null,
    default: ?*const TypeNode = null,
};

/// A property or method in an interface or an object type, or one of its signatures.
pub const TypeMember = struct {
    /// Empty for a call or construct signature; an index signature's parameter name.
    name: []const u8,
    start: u32,
    optional: bool,
    readonly: bool,
    /// `m(a: T): R`, whose type is a function type.
    method: bool,
    /// Null for a property without a type, which is `any` (and TS7008).
    type: ?*const TypeNode,
    signature: Signature = .none,

    pub const Signature = union(enum) {
        /// A property or method.
        none,
        /// `(a: T): R`, whose `type` is the function type.
        call,
        /// `new (a: T): R`, whose `type` is the function type.
        construct,
        /// `[key: K]: T`, with the key's type; `type` is the value's.
        index: *const TypeNode,
    };
};

/// A type annotation: a primitive keyword, a name, a literal, an array, tuple, object, function
/// or union type.
pub const TypeNode = struct {
    start: u32,
    data: Data,

    pub const Data = union(enum) {
        keyword: Keyword,
        reference: TypeReference,
        /// `1`, `-1`, `"a"`, `true`
        literal: Literal,
        /// `A | B`, with at least two members.
        @"union": []const *const TypeNode,
        /// `T[]`
        array: *const TypeNode,
        /// `[T, U]`
        tuple: []const *const TypeNode,
        /// `{ a: T; b?: U }`
        object: []const TypeMember,
        /// `(a: T, b?: U, ...c: V[]) => R`
        function: FunctionType,
        /// `keyof T`
        keyof: *const TypeNode,
        /// `readonly T[]`
        readonly: *const TypeNode,
        /// `T[K]`
        indexed: Indexed,
        /// `typeof x` or `typeof x.y.z`.
        query: Query,
        /// `{ readonly [P in K]?: T }`
        mapped: *const Mapped,
        /// `A & B`, with at least two members. Only in a `.d.ts` file so far.
        intersection: []const *const TypeNode,
        /// `x is T`, as a function's return type.
        predicate: Predicate,
    };

    pub const Predicate = struct {
        parameter: []const u8,
        type: *const TypeNode,
    };

    pub const Indexed = struct {
        object: *const TypeNode,
        index: *const TypeNode,
    };

    pub const Query = struct {
        name: []const u8,
        /// The properties after the name.
        path: []const []const u8,
    };

    /// A `+` or `-` modifier of a mapped type, or neither.
    pub const Modifier = enum { none, add, remove };

    pub const Mapped = struct {
        /// The `P` in `[P in K]`.
        parameter: GenericParameter,
        /// The `K`.
        constraint: *const TypeNode,
        /// Null when there's no `: T`, which is `any` (TS7008).
        type: ?*const TypeNode,
        optional: Modifier,
        readonly: Modifier,
    };

    pub const Keyword = enum { any, unknown, never, void, undefined, null, boolean, number, string, object };

    pub const Literal = union(enum) {
        number: f64,
        string: []const u8,
        boolean: bool,
    };
};

pub const FunctionType = struct {
    type_parameters: []const GenericParameter = &.{},
    parameters: []const TypeParameter,
    /// Null only for a method signature without a return type, which returns `any` (TS7010).
    returns: ?*const TypeNode,
};

/// A parameter of a function type, which only has a name and a type.
pub const TypeParameter = struct {
    name: []const u8,
    start: u32,
    type: ?*const TypeNode,
    optional: bool,
    rest: bool,
};

/// A function declaration, function expression or arrow function.
pub const Function = struct {
    kind: Kind,
    /// Dense index among the program's functions; see `Program.function_count`.
    id: u32,
    /// Where the function starts and ends, for its source text.
    start: u32,
    end: u32,
    /// The declared name, if any. A declaration's name is bound in the enclosing scope; a function
    /// expression's only inside the function itself.
    name: ?Name,
    type_parameters: []const GenericParameter = &.{},
    /// The name the function gets at runtime (its `.name`): its own, or the variable or parameter
    /// it's assigned to (ECMA-262 NamedEvaluation). Empty when there's none.
    inferred_name: []const u8 = "",
    parameters: []const Parameter,
    /// The scope the parameters (and a function expression's own name) are declared in.
    scope: u32,
    returns: ?*const TypeNode,
    /// Where the return type annotation starts, for TS2355 and TS2366.
    returns_start: u32,
    body: Body,

    pub const Kind = enum { declaration, expression, arrow };

    pub const Name = struct {
        text: []const u8,
        start: u32,
        binding: u32,
    };

    pub const Body = union(enum) {
        block: Block,
        /// An arrow function's `=> expression`.
        expression: *Expr,
    };

    /// The value of `.length`: how many parameters come before the first default or rest one.
    pub fn length(this: *const Function) u32 {
        for (this.parameters, 0..) |p, i| {
            if (p.init != null or p.rest) {
                return @intCast(i);
            }
        }
        return @intCast(this.parameters.len);
    }
};

pub const Parameter = struct {
    /// The name, or for a destructured parameter its source text.
    name: []const u8,
    /// Where the name is.
    start: u32,
    /// Where the parameter starts, which is its `...` for a rest parameter.
    node_start: u32,
    /// Where the parameter (including its default value) ends. A default value that refers to a
    /// parameter which ends after it is an error (TS2373).
    end: u32,
    /// Unused when `pattern` is set.
    binding: u32,
    /// `({ a, b }: T) => ...`
    pattern: ?*const Pattern = null,
    type: ?*const TypeNode,
    init: ?*Expr,
    /// `a?: T`
    optional: bool,
    /// `...a: T[]`
    rest: bool,
};

pub const Expr = struct {
    start: u32,
    data: Data,

    pub const Data = union(enum) {
        number: f64,
        /// The cooked value, with escapes already applied.
        string: []const u8,
        template: Template,
        boolean: bool,
        null,
        identifier: Identifier,
        unary: Unary,
        update: Update,
        assign: Assign,
        binary: Binary,
        conditional: Conditional,
        member: Member,
        call: Call,
        /// `o[k]`
        index: Index,
        object: ObjectLiteral,
        array: ArrayLiteral,
        function: *Function,
        /// An optional chain such as `a?.b.c`: the outermost expression of the chain, whose links
        /// (`member`, `index`, `call` and `non_null`) short-circuit to `undefined` together when
        /// one marked `optional` finds `null` or `undefined`.
        chain: *Expr,
        /// `e!`
        non_null: *Expr,
        /// `e as T`, `e as const` and `e satisfies T`.
        assertion: Assertion,
        /// Kept so that `(a ?? b) || c` can be told apart from `a ?? b || c`, which is an error, and
        /// so syntactic checks see through parentheses the way tsc does.
        paren: *Expr,
        /// `new C(arguments)`
        new: New,
        /// `...e`, only as a call's argument.
        spread: *Expr,
    };
};

pub const New = struct {
    callee: *Expr,
    type_arguments: []const *const TypeNode = &.{},
    arguments: []const *Expr,
};

pub const Identifier = struct {
    name: []const u8,
    /// Dense index among the program's identifier references; see `Program.reference_count`.
    ref: u32,
};

pub const Template = struct {
    /// One more than `substitutions`: the text before, between and after each `${}`.
    quasis: []const []const u8,
    substitutions: []const *Expr,
};

pub const UnaryOp = enum {
    negate,
    plus,
    not,
    bitwise_not,
    typeof,
    void,
    delete,

    pub fn lexeme(this: UnaryOp) []const u8 {
        return switch (this) {
            .negate => "-",
            .plus => "+",
            .not => "!",
            .bitwise_not => "~",
            .typeof => "typeof",
            .void => "void",
            .delete => "delete",
        };
    }
};

pub const Unary = struct {
    op: UnaryOp,
    operand: *Expr,
};

/// `++x`, `x--` and friends.
pub const Update = struct {
    increment: bool,
    prefix: bool,
    operand: *Expr,
};

/// `target = value`, or a compound assignment like `target += value` when `op` is set. The
/// logical assignments use `logical_and`, `logical_or` and `nullish`.
pub const Assign = struct {
    op: ?BinaryOp,
    target: *Expr,
    value: *Expr,
    op_start: u32,
};

pub const BinaryOp = enum {
    add,
    subtract,
    multiply,
    divide,
    remainder,
    exponent,
    shift_left,
    shift_right,
    shift_right_unsigned,
    bitwise_and,
    bitwise_or,
    bitwise_xor,
    less,
    greater,
    less_equal,
    greater_equal,
    equal,
    not_equal,
    strict_equal,
    strict_not_equal,
    logical_and,
    logical_or,
    nullish,
    /// `key in object`
    in,
    /// The comma operator.
    comma,

    pub fn lexeme(this: BinaryOp) []const u8 {
        return switch (this) {
            .add => "+",
            .subtract => "-",
            .multiply => "*",
            .divide => "/",
            .remainder => "%",
            .exponent => "**",
            .shift_left => "<<",
            .shift_right => ">>",
            .shift_right_unsigned => ">>>",
            .bitwise_and => "&",
            .bitwise_or => "|",
            .bitwise_xor => "^",
            .less => "<",
            .greater => ">",
            .less_equal => "<=",
            .greater_equal => ">=",
            .equal => "==",
            .not_equal => "!=",
            .strict_equal => "===",
            .strict_not_equal => "!==",
            .logical_and => "&&",
            .logical_or => "||",
            .nullish => "??",
            .in => "in",
            .comma => ",",
        };
    }

    pub fn isLogical(this: BinaryOp) bool {
        return this == .logical_and or this == .logical_or or this == .nullish;
    }

    /// Operators whose operands must both be numeric (TS2362/TS2363).
    pub fn isArithmetic(this: BinaryOp) bool {
        return switch (this) {
            .subtract, .multiply, .divide, .remainder, .exponent => true,
            .shift_left, .shift_right, .shift_right_unsigned => true,
            .bitwise_and, .bitwise_or, .bitwise_xor => true,
            else => false,
        };
    }
};

pub const Binary = struct {
    op: BinaryOp,
    left: *Expr,
    right: *Expr,
    /// Where the operator token starts.
    op_start: u32,
};

pub const Conditional = struct {
    condition: *Expr,
    then: *Expr,
    otherwise: *Expr,
};

pub const Member = struct {
    object: *Expr,
    property: []const u8,
    property_start: u32,
    /// `object?.property`, inside a `chain`.
    optional: bool = false,
};

pub const Call = struct {
    callee: *Expr,
    /// `f<number>(x)`
    type_arguments: []const *const TypeNode = &.{},
    arguments: []const *Expr,
    /// `callee?.(arguments)`, inside a `chain`.
    optional: bool = false,
};

pub const Index = struct {
    object: *Expr,
    index: *Expr,
    /// `object?.[index]`, inside a `chain`.
    optional: bool = false,
};

pub const Assertion = struct {
    kind: enum { as, satisfies },
    expr: *Expr,
    /// Null for `as const`.
    type: ?*const TypeNode,
    /// Where the `as` or `satisfies` keyword is.
    keyword_start: u32,
};

/// `{ a: 1, b, [k]: 2, ...o, m() {} }`
pub const ObjectLiteral = struct {
    properties: []const ObjectProperty,
};

pub const ObjectProperty = union(enum) {
    /// `key: value`, a shorthand `key` (whose value is an identifier), or a method (whose value
    /// is a function).
    property: struct {
        key: PropertyKey,
        key_start: u32,
        value: *Expr,
        method: bool = false,
    },
    spread: struct {
        /// Where the `...` is.
        start: u32,
        expr: *Expr,
    },
};

pub const PropertyKey = union(enum) {
    /// An identifier, string or number key, as the property name it gives.
    name: []const u8,
    /// `[expression]`
    computed: *Expr,
};

/// `[a, ...b, c]`
pub const ArrayLiteral = struct {
    elements: []const ArrayElement,
};

pub const ArrayElement = union(enum) {
    expr: *Expr,
    spread: *Expr,
};

/// The expression with any parentheses around it removed.
pub fn skipParens(expr: *const Expr) *const Expr {
    var e = expr;
    while (e.data == .paren) {
        e = e.data.paren;
    }
    return e;
}

/// The expression with parentheses, type assertions and non-null assertions around it removed
/// (tsc's `skipOuterExpressions`), for checks that look at what an expression is syntactically.
pub fn skipOuter(expr: *const Expr) *const Expr {
    var e = expr;
    while (true) {
        e = switch (e.data) {
            .paren, .non_null => |inner| inner,
            .assertion => |a| a.expr,
            else => return e,
        };
    }
}
