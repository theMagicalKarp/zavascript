//! The syntax tree. Every node is allocated in the arena of the `Program` that owns it, and every
//! node keeps the byte offset it starts at for diagnostics.

const std = @import("std");

pub const Program = struct {
    statements: []const *Stmt,
};

pub const Stmt = struct {
    start: u32,
    data: Data,

    pub const Data = union(enum) {
        expression: *Expr,
        /// A lone `;`.
        empty,
    };
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
        identifier: []const u8,
        unary: Unary,
        binary: Binary,
        conditional: Conditional,
        member: Member,
        call: Call,
        /// Kept so that `(a ?? b) || c` can be told apart from `a ?? b || c`, which is an error, and
        /// so syntactic checks see through parentheses the way tsc does.
        paren: *Expr,
    };
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
        };
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
    while (e.data == .paren) e = e.data.paren;
    return e;
}
