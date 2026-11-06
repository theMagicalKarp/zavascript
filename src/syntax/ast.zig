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
    };
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
    name: []const u8,
    /// Where the name starts.
    start: u32,
    /// Where the declarator (including its initializer) ends. A reference before this point is a
    /// use before declaration (TS2448).
    end: u32,
    /// Dense index among the program's declarations; see `Program.binding_count`.
    binding: u32,
    type: ?*const TypeNode,
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

/// A type annotation: a primitive keyword, an array or function type, or a name the checker
/// rejects for now.
pub const TypeNode = struct {
    start: u32,
    data: Data,

    pub const Data = union(enum) {
        keyword: Keyword,
        reference: []const u8,
        /// `T[]`
        array: *const TypeNode,
        /// `(a: T, b?: U, ...c: V[]) => R`
        function: FunctionType,
    };

    pub const Keyword = enum { any, unknown, never, void, undefined, null, boolean, number, string };
};

pub const FunctionType = struct {
    parameters: []const TypeParameter,
    returns: *const TypeNode,
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
    name: []const u8,
    /// Where the name is.
    start: u32,
    /// Where the parameter starts, which is its `...` for a rest parameter.
    node_start: u32,
    /// Where the parameter (including its default value) ends. A default value that refers to a
    /// parameter which ends after it is an error (TS2373).
    end: u32,
    binding: u32,
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
        function: *Function,
        /// Kept so that `(a ?? b) || c` can be told apart from `a ?? b || c`, which is an error, and
        /// so syntactic checks see through parentheses the way tsc does.
        paren: *Expr,
    };
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

    pub fn lexeme(this: UnaryOp) []const u8 {
        return switch (this) {
            .negate => "-",
            .plus => "+",
            .not => "!",
            .bitwise_not => "~",
            .typeof => "typeof",
            .void => "void",
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
};

pub const Call = struct {
    callee: *Expr,
    arguments: []const *Expr,
};

/// The expression with any parentheses around it removed.
pub fn skipParens(expr: *const Expr) *const Expr {
    var e = expr;
    while (e.data == .paren) {
        e = e.data.paren;
    }
    return e;
}
