//! Builds the syntax tree from tokens: recursive descent for statements, precedence climbing for
//! binary operators. Syntax we don't support yet is reported as `ZV9001` and skipped, so
//! everything after it is still checked.

const std = @import("std");
const Source = @import("../Source.zig");
const diagnostic = @import("../diagnostic.zig");
const Lexer = @import("Lexer.zig");
const token = @import("token.zig");
const ast = @import("ast.zig");
const number = @import("../runtime/number.zig");
const Token = token.Token;
const Tag = token.Tag;
const Expr = ast.Expr;
const Stmt = ast.Stmt;

const Parser = @This();

/// Owns the tree and the cooked strings.
arena: std.mem.Allocator,
source: *const Source,
diagnostics: *diagnostic.Diagnostics,
tokens: []const Token,
index: usize = 0,

/// `error.Syntax` unwinds to the enclosing statement, which reports nothing more and resyncs.
const Error = error{ OutOfMemory, Syntax };

/// Parses a whole file. Problems go to `diagnostics`; the returned program holds every statement
/// that parsed cleanly.
pub fn parse(gpa: std.mem.Allocator, arena: std.mem.Allocator, source: *const Source, diagnostics: *diagnostic.Diagnostics) error{OutOfMemory}!ast.Program {
    const tokens = try Lexer.tokenize(gpa, source, diagnostics);
    defer gpa.free(tokens);
    var parser: Parser = .{ .arena = arena, .source = source, .diagnostics = diagnostics, .tokens = tokens };
    return parser.program();
}

fn program(this: *Parser) error{OutOfMemory}!ast.Program {
    var statements: std.ArrayList(*Stmt) = .empty;
    while (this.current().tag != .eof) {
        const before = this.index;
        if (this.statement()) |stmt| {
            try statements.append(this.arena, stmt);
        } else |err| {
            switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Syntax => this.synchronize(before),
            }
        }
    }
    return .{ .statements = try statements.toOwnedSlice(this.arena) };
}

// Token helpers

fn current(this: *const Parser) Token {
    return this.tokens[this.index];
}

fn peekToken(this: *const Parser, ahead: usize) Token {
    return this.tokens[@min(this.index + ahead, this.tokens.len - 1)];
}

fn advance(this: *Parser) Token {
    const tok = this.tokens[this.index];
    if (tok.tag != .eof) {
        this.index += 1;
    }
    return tok;
}

fn eat(this: *Parser, tag: Tag) bool {
    if (this.current().tag != tag) {
        return false;
    }
    _ = this.advance();
    return true;
}

fn expect(this: *Parser, tag: Tag) Error!Token {
    if (this.current().tag == tag) {
        return this.advance();
    }
    return this.fail(this.current().start, .ts(1005), "'{s}' expected.", .{tag.lexeme().?});
}

fn tokenText(this: *const Parser, tok: Token) []const u8 {
    return tok.text(this.source.text);
}

fn isContextual(this: *const Parser, tok: Token, word: []const u8) bool {
    return tok.tag == .identifier and std.mem.eql(u8, this.tokenText(tok), word);
}

/// Reports a diagnostic and unwinds to the statement level.
fn fail(this: *Parser, at: u32, code: diagnostic.Code, comptime fmt: []const u8, args: anytype) Error {
    try this.diagnostics.addSyntax(this.source, at, code, fmt, args);
    return error.Syntax;
}

fn unsupported(this: *Parser, at: u32, comptime what: []const u8, args: anytype) Error {
    return this.fail(at, diagnostic.zv.unsupported, what ++ " not supported yet.", args);
}

/// Reports a diagnostic and keeps parsing, for errors that don't leave the parser lost.
fn report(this: *Parser, at: u32, code: diagnostic.Code, comptime fmt: []const u8, args: anytype) error{OutOfMemory}!void {
    try this.diagnostics.addSyntax(this.source, at, code, fmt, args);
}

/// Skips to where the next statement probably starts after an error: past a `;`, or before a
/// token on a new line, but never inside brackets the statement opened.
fn synchronize(this: *Parser, statement_start: usize) void {
    // Count the brackets the statement had already opened when the error happened.
    var depth: usize = 0;
    for (this.tokens[statement_start..this.index]) |tok| {
        depth = bracketDepth(tok.tag, depth) orelse 0;
    }
    // Always make progress, even if the error was at the statement's first token.
    if (this.index == statement_start) {
        depth = this.skipOne(depth) orelse return;
    }
    while (this.current().tag != .eof) {
        const tok = this.current();
        if (depth == 0) {
            if (tok.tag == .semicolon) {
                _ = this.advance();
                return;
            }
            if (tok.newline_before or tok.tag == .r_brace) {
                return;
            }
        }
        depth = this.skipOne(depth) orelse return;
    }
}

fn bracketDepth(tag: Tag, depth: usize) ?usize {
    return switch (tag) {
        .l_brace, .l_paren, .l_bracket, .template_head => depth + 1,
        .r_brace, .r_paren, .r_bracket, .template_tail => if (depth == 0) null else depth - 1,
        else => depth,
    };
}

/// Advances one token, tracking bracket depth; null means a closing bracket with nothing open.
fn skipOne(this: *Parser, depth: usize) ?usize {
    return bracketDepth(this.advance().tag, depth);
}

fn newExpr(this: *Parser, start: u32, data: Expr.Data) error{OutOfMemory}!*Expr {
    const expr = try this.arena.create(Expr);
    expr.* = .{ .start = start, .data = data };
    return expr;
}

// Statements

fn statement(this: *Parser) Error!*Stmt {
    const tok = this.current();
    switch (tok.tag) {
        .semicolon => {
            _ = this.advance();
            const stmt = try this.arena.create(Stmt);
            stmt.* = .{ .start = tok.start, .data = .empty };
            return stmt;
        },
        .r_brace => return this.fail(tok.start, .ts(1128), "Declaration or statement expected.", .{}),
        .l_brace => return this.unsupported(tok.start, "Block statements are", .{}),
        .kw_let, .kw_const, .kw_var => return this.unsupported(tok.start, "'{s}' declarations are", .{this.tokenText(tok)}),
        .kw_if, .kw_for, .kw_while, .kw_do, .kw_switch, .kw_return, .kw_break, .kw_continue, .kw_throw, .kw_try, .kw_with, .kw_debugger => {
            return this.unsupported(tok.start, "'{s}' statements are", .{this.tokenText(tok)});
        },
        .kw_function, .kw_class, .kw_enum, .kw_interface, .kw_import, .kw_export => {
            return this.unsupported(tok.start, "'{s}' declarations are", .{this.tokenText(tok)});
        },
        .identifier => {
            const following = this.peekToken(1);
            const starts_declaration = !following.newline_before and (following.tag == .identifier or following.tag.isKeyword());
            for ([_][]const u8{ "type", "declare", "namespace", "module", "abstract", "async" }) |word| {
                if (starts_declaration and this.isContextual(tok, word)) {
                    return this.unsupported(tok.start, "'{s}' declarations are", .{word});
                }
            }
            if (following.tag == .colon) {
                return this.unsupported(tok.start, "Labeled statements are", .{});
            }
        },
        else => {},
    }

    const expr = try this.expression();
    try this.semicolon();
    const stmt = try this.arena.create(Stmt);
    stmt.* = .{ .start = tok.start, .data = .{ .expression = expr } };
    return stmt;
}

/// Consumes a `;`, or accepts its absence where automatic semicolon insertion applies.
fn semicolon(this: *Parser) Error!void {
    const tok = this.current();
    if (tok.tag == .semicolon) {
        _ = this.advance();
        return;
    }
    if (tok.tag == .r_brace or tok.tag == .eof or tok.newline_before) {
        return;
    }
    return this.fail(tok.start, .ts(1005), "';' expected.", .{});
}

// Expressions

fn expression(this: *Parser) Error!*Expr {
    const expr = try this.assignment();
    if (this.current().tag == .comma) {
        return this.unsupported(this.current().start, "The comma operator is", .{});
    }
    return expr;
}

fn assignment(this: *Parser) Error!*Expr {
    const expr = try this.conditional();
    const tok = this.current();
    switch (tok.tag) {
        .equal, .plus_equal, .minus_equal, .star_equal, .slash_equal, .percent_equal, .star_star_equal => {},
        .less_less_equal, .ampersand_equal, .pipe_equal, .caret_equal => {},
        .ampersand_ampersand_equal, .pipe_pipe_equal, .question_question_equal => {},
        .arrow => return this.unsupported(tok.start, "Arrow functions are", .{}),
        .greater => if (this.greaterOperator()) |op| {
            if (op.assignment) {
                return this.unsupported(tok.start, "Assignment is", .{});
            }
            return expr;
        } else return expr,
        else => return expr,
    }
    return this.unsupported(tok.start, "Assignment is", .{});
}

fn conditional(this: *Parser) Error!*Expr {
    const condition = try this.binary(0);
    if (!this.eat(.question)) {
        return condition;
    }
    const then = try this.assignment();
    _ = try this.expect(.colon);
    const otherwise = try this.assignment();
    return this.newExpr(condition.start, .{ .conditional = .{ .condition = condition, .then = then, .otherwise = otherwise } });
}

const BinaryInfo = struct {
    op: ast.BinaryOp,
    precedence: u8,
    /// How many tokens the operator spans; more than one for `>>`, `>=` and friends.
    tokens: u8 = 1,
};

/// Binary operator precedence, loosest first. `**` is right-associative.
fn binaryInfo(this: *Parser) ?BinaryInfo {
    const tok = this.current();
    return switch (tok.tag) {
        .question_question => .{ .op = .nullish, .precedence = 1 },
        .pipe_pipe => .{ .op = .logical_or, .precedence = 2 },
        .ampersand_ampersand => .{ .op = .logical_and, .precedence = 3 },
        .pipe => .{ .op = .bitwise_or, .precedence = 4 },
        .caret => .{ .op = .bitwise_xor, .precedence = 5 },
        .ampersand => .{ .op = .bitwise_and, .precedence = 6 },
        .equal_equal => .{ .op = .equal, .precedence = 7 },
        .bang_equal => .{ .op = .not_equal, .precedence = 7 },
        .equal_equal_equal => .{ .op = .strict_equal, .precedence = 7 },
        .bang_equal_equal => .{ .op = .strict_not_equal, .precedence = 7 },
        .less => .{ .op = .less, .precedence = 8 },
        .less_equal => .{ .op = .less_equal, .precedence = 8 },
        .less_less => .{ .op = .shift_left, .precedence = 9 },
        .greater => blk: {
            const op = this.greaterOperator() orelse unreachable;
            if (op.assignment) {
                break :blk null;
            }
            break :blk .{ .op = op.op, .precedence = if (op.op == .greater or op.op == .greater_equal) 8 else 9, .tokens = op.tokens };
        },
        .plus => .{ .op = .add, .precedence = 10 },
        .minus => .{ .op = .subtract, .precedence = 10 },
        .star => .{ .op = .multiply, .precedence = 11 },
        .slash => .{ .op = .divide, .precedence = 11 },
        .percent => .{ .op = .remainder, .precedence = 11 },
        .star_star => .{ .op = .exponent, .precedence = 12 },
        else => null,
    };
}

const GreaterOperator = struct { op: ast.BinaryOp, tokens: u8, assignment: bool };

/// Puts `>`, `>=`, `>>`, `>>=`, `>>>` and `>>>=` back together from adjacent tokens.
fn greaterOperator(this: *const Parser) ?GreaterOperator {
    var count: u8 = 1;
    var end = this.current().end;
    while (count < 3) {
        const next = this.peekToken(count);
        if (next.tag != .greater or next.start != end) {
            break;
        }
        end = next.end;
        count += 1;
    }
    const next = this.peekToken(count);
    const assign = next.start == end and (next.tag == .equal or next.tag == .equal_equal or next.tag == .equal_equal_equal);
    if (assign) {
        // `>=` is a comparison; `>>=` and `>>>=` are assignments. `> ==` never touch.
        if (count == 1) {
            return if (next.tag == .equal) .{ .op = .greater_equal, .tokens = 2, .assignment = false } else null;
        }
        return if (next.tag == .equal) .{ .op = .shift_right, .tokens = count + 1, .assignment = true } else null;
    }
    return switch (count) {
        1 => .{ .op = .greater, .tokens = 1, .assignment = false },
        2 => .{ .op = .shift_right, .tokens = 2, .assignment = false },
        else => .{ .op = .shift_right_unsigned, .tokens = 3, .assignment = false },
    };
}

fn binary(this: *Parser, min_precedence: u8) Error!*Expr {
    var left = try this.unary();
    while (true) {
        const tok = this.current();
        if (tok.tag == .kw_in or tok.tag == .kw_instanceof) {
            return this.unsupported(tok.start, "The '{s}' operator is", .{this.tokenText(tok)});
        }
        if (this.isContextual(tok, "as") or this.isContextual(tok, "satisfies")) {
            if (!tok.newline_before) {
                return this.unsupported(tok.start, "'{s}' expressions are", .{this.tokenText(tok)});
            }
        }
        const info = this.binaryInfo() orelse return left;
        if (info.precedence <= min_precedence) {
            return left;
        }
        for (0..info.tokens) |_| {
            _ = this.advance();
        }
        // `**` is right-associative, so its right side binds at the same level.
        const right = try this.binary(if (info.op == .exponent) info.precedence - 1 else info.precedence);
        try this.checkNullishMixing(info.op, left, right);
        left = try this.newExpr(left.start, .{ .binary = .{ .op = info.op, .left = left, .right = right, .op_start = tok.start } });
    }
}

/// `a ?? b || c` is a syntax error without parentheses (TS5076).
fn checkNullishMixing(this: *Parser, op: ast.BinaryOp, left: *const Expr, right: *const Expr) error{OutOfMemory}!void {
    const isLogical = struct {
        fn f(o: ast.BinaryOp) bool {
            return o == .logical_and or o == .logical_or;
        }
    }.f;
    for ([_]*const Expr{ left, right }) |operand| {
        if (operand.data != .binary) {
            continue;
        }
        const inner = operand.data.binary.op;
        if ((op == .nullish and isLogical(inner)) or (isLogical(op) and inner == .nullish)) {
            const first = if (operand == left) inner else op;
            const second = if (operand == left) op else inner;
            try this.report(operand.start, .ts(5076), "'{s}' and '{s}' operations cannot be mixed without parentheses.", .{ first.lexeme(), second.lexeme() });
        }
    }
}

fn unary(this: *Parser) Error!*Expr {
    const tok = this.current();
    const op: ast.UnaryOp = switch (tok.tag) {
        .minus => .negate,
        .plus => .plus,
        .bang => .not,
        .tilde => .bitwise_not,
        .kw_typeof => .typeof,
        .kw_void => .void,
        .kw_delete, .kw_await => return this.unsupported(tok.start, "'{s}' expressions are", .{this.tokenText(tok)}),
        .plus_plus, .minus_minus => return this.unsupported(tok.start, "Increment and decrement operators are", .{}),
        .less => return this.unsupported(tok.start, "Type assertions are", .{}),
        else => return this.postfix(),
    };
    _ = this.advance();
    const operand = try this.unary();
    const expr = try this.newExpr(tok.start, .{ .unary = .{ .op = op, .operand = operand } });
    if (this.current().tag == .star_star) {
        try this.report(tok.start, .ts(17006), "An unary expression with the '{s}' operator is not allowed in the left-hand side of an exponentiation expression. Consider enclosing the expression in parentheses.", .{op.lexeme()});
    }
    return expr;
}

fn postfix(this: *Parser) Error!*Expr {
    var expr = try this.primary();
    while (true) {
        const tok = this.current();
        switch (tok.tag) {
            .dot => {
                _ = this.advance();
                const name = this.current();
                if (name.tag == .private_name) {
                    return this.unsupported(name.start, "Private names are", .{});
                }
                if (name.tag != .identifier and !name.tag.isKeyword()) {
                    return this.fail(name.start, .ts(1003), "Identifier expected.", .{});
                }
                _ = this.advance();
                expr = try this.newExpr(expr.start, .{ .member = .{ .object = expr, .property = this.tokenText(name), .property_start = name.start } });
            },
            .l_paren => {
                _ = this.advance();
                const args = try this.arguments();
                expr = try this.newExpr(expr.start, .{ .call = .{ .callee = expr, .arguments = args } });
            },
            .l_bracket => return this.unsupported(tok.start, "Element access is", .{}),
            .question_dot => return this.unsupported(tok.start, "Optional chaining is", .{}),
            .template_full, .template_head => return this.unsupported(tok.start, "Tagged templates are", .{}),
            .bang => if (!tok.newline_before) return this.unsupported(tok.start, "Non-null assertions are", .{}) else return expr,
            .plus_plus, .minus_minus => if (!tok.newline_before) return this.unsupported(tok.start, "Increment and decrement operators are", .{}) else return expr,
            else => return expr,
        }
    }
}

/// The arguments of a call, after the `(`.
fn arguments(this: *Parser) Error![]const *Expr {
    var args: std.ArrayList(*Expr) = .empty;
    while (this.current().tag != .r_paren) {
        if (this.current().tag == .ellipsis) {
            return this.unsupported(this.current().start, "Spread arguments are", .{});
        }
        try args.append(this.arena, try this.assignment());
        if (!this.eat(.comma)) {
            break;
        }
    }
    _ = try this.expect(.r_paren);
    return args.toOwnedSlice(this.arena);
}

fn primary(this: *Parser) Error!*Expr {
    const tok = this.current();
    switch (tok.tag) {
        .number => {
            _ = this.advance();
            return this.newExpr(tok.start, .{ .number = number.parseLiteral(this.tokenText(tok)) });
        },
        .string => {
            _ = this.advance();
            return this.newExpr(tok.start, .{ .string = try Lexer.cook(this.arena, this.source.text, tok) });
        },
        .template_full, .template_head => return this.template(),
        .kw_true, .kw_false => {
            _ = this.advance();
            return this.newExpr(tok.start, .{ .boolean = tok.tag == .kw_true });
        },
        .kw_null => {
            _ = this.advance();
            return this.newExpr(tok.start, .null);
        },
        .identifier => {
            _ = this.advance();
            if (this.current().tag == .arrow) {
                return this.unsupported(this.current().start, "Arrow functions are", .{});
            }
            return this.newExpr(tok.start, .{ .identifier = this.tokenText(tok) });
        },
        .l_paren => {
            _ = this.advance();
            if (this.current().tag == .r_paren) {
                return this.unsupported(tok.start, "Arrow functions are", .{});
            }
            const inner = try this.expression();
            if (this.current().tag == .colon) {
                return this.unsupported(tok.start, "Arrow functions are", .{});
            }
            _ = try this.expect(.r_paren);
            if (this.current().tag == .arrow) {
                return this.unsupported(tok.start, "Arrow functions are", .{});
            }
            return this.newExpr(tok.start, .{ .paren = inner });
        },
        .bigint => return this.unsupported(tok.start, "BigInt literals are", .{}),
        .l_bracket => return this.unsupported(tok.start, "Array literals are", .{}),
        .l_brace => return this.unsupported(tok.start, "Object literals are", .{}),
        .kw_function => return this.unsupported(tok.start, "Function expressions are", .{}),
        .kw_class => return this.unsupported(tok.start, "Class expressions are", .{}),
        .kw_new => return this.unsupported(tok.start, "'new' expressions are", .{}),
        .kw_this => return this.unsupported(tok.start, "'this' is", .{}),
        .kw_super => return this.unsupported(tok.start, "'super' is", .{}),
        .kw_import => return this.unsupported(tok.start, "Dynamic import is", .{}),
        .slash, .slash_equal => return this.unsupported(tok.start, "Regular expressions are", .{}),
        .invalid => return error.Syntax, // already reported by the lexer
        else => return this.fail(tok.start, .ts(1109), "Expression expected.", .{}),
    }
}

fn template(this: *Parser) Error!*Expr {
    const first = this.advance();
    var quasis: std.ArrayList([]const u8) = .empty;
    var substitutions: std.ArrayList(*Expr) = .empty;
    try quasis.append(this.arena, try Lexer.cook(this.arena, this.source.text, first));
    if (first.tag == .template_head) {
        while (true) {
            try substitutions.append(this.arena, try this.expression());
            const part = this.current();
            if (part.tag != .template_middle and part.tag != .template_tail) {
                return this.fail(part.start, .ts(1005), "'}}' expected.", .{});
            }
            _ = this.advance();
            try quasis.append(this.arena, try Lexer.cook(this.arena, this.source.text, part));
            if (part.tag == .template_tail) {
                break;
            }
        }
    }
    return this.newExpr(first.start, .{ .template = .{
        .quasis = try quasis.toOwnedSlice(this.arena),
        .substitutions = try substitutions.toOwnedSlice(this.arena),
    } });
}

// Tests

const testing = std.testing;

/// Renders an expression fully parenthesized, so tests can check precedence and associativity.
fn sexpr(writer: *std.Io.Writer, expr: *const Expr) std.Io.Writer.Error!void {
    switch (expr.data) {
        .number => |n| try number.format(writer, n),
        .string => |s| try writer.print("\"{s}\"", .{s}),
        .template => |t| {
            try writer.writeAll("`");
            for (t.quasis, 0..) |q, i| {
                try writer.writeAll(q);
                if (i < t.substitutions.len) {
                    try writer.writeAll("${");
                    try sexpr(writer, t.substitutions[i]);
                    try writer.writeAll("}");
                }
            }
            try writer.writeAll("`");
        },
        .boolean => |b| try writer.writeAll(if (b) "true" else "false"),
        .null => try writer.writeAll("null"),
        .identifier => |name| try writer.writeAll(name),
        .unary => |u| {
            try writer.print("({s} ", .{u.op.lexeme()});
            try sexpr(writer, u.operand);
            try writer.writeAll(")");
        },
        .binary => |b| {
            try writer.print("({s} ", .{b.op.lexeme()});
            try sexpr(writer, b.left);
            try writer.writeAll(" ");
            try sexpr(writer, b.right);
            try writer.writeAll(")");
        },
        .conditional => |c| {
            try writer.writeAll("(? ");
            try sexpr(writer, c.condition);
            try writer.writeAll(" ");
            try sexpr(writer, c.then);
            try writer.writeAll(" ");
            try sexpr(writer, c.otherwise);
            try writer.writeAll(")");
        },
        .member => |m| {
            try writer.writeAll("(. ");
            try sexpr(writer, m.object);
            try writer.print(" {s})", .{m.property});
        },
        .call => |c| {
            try writer.writeAll("(call ");
            try sexpr(writer, c.callee);
            for (c.arguments) |arg| {
                try writer.writeAll(" ");
                try sexpr(writer, arg);
            }
            try writer.writeAll(")");
        },
        .paren => |inner| {
            try writer.writeAll("[");
            try sexpr(writer, inner);
            try writer.writeAll("]");
        },
    }
}

const Parsed = struct {
    arena: std.heap.ArenaAllocator,
    source: Source,
    diagnostics: diagnostic.Diagnostics,
    program: ast.Program,

    fn init(input: []const u8) !*Parsed {
        const parsed = try testing.allocator.create(Parsed);
        parsed.arena = .init(testing.allocator);
        parsed.source = try .init(testing.allocator, "test.ts", input);
        parsed.diagnostics = .init(testing.allocator);
        parsed.program = try parse(testing.allocator, parsed.arena.allocator(), &parsed.source, &parsed.diagnostics);
        return parsed;
    }

    fn deinit(this: *Parsed) void {
        this.diagnostics.deinit();
        this.source.deinit(testing.allocator);
        this.arena.deinit();
        testing.allocator.destroy(this);
    }

    /// Each statement on its own line, `;` for empty ones.
    fn render(this: *Parsed) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(this.arena.allocator());
        for (this.program.statements) |stmt| {
            switch (stmt.data) {
                .expression => |e| try sexpr(&out.writer, e),
                .empty => try out.writer.writeAll(";"),
            }
            try out.writer.writeAll("\n");
        }
        return out.written();
    }

    fn codes(this: *Parsed) ![]const u16 {
        const result = try this.arena.allocator().alloc(u16, this.diagnostics.items().len);
        for (this.diagnostics.items(), result) |d, *code| {
            code.* = d.code.number;
        }
        return result;
    }
};

fn expectParse(input: []const u8, expected: []const u8) !void {
    const parsed: *Parsed = try .init(input);
    defer parsed.deinit();
    try testing.expectEqualSlices(u16, &.{}, try parsed.codes());
    try testing.expectEqualStrings(expected, try parsed.render());
}

fn expectErrors(input: []const u8, expected: []const u16) !void {
    const parsed: *Parsed = try .init(input);
    defer parsed.deinit();
    try testing.expectEqualSlices(u16, expected, try parsed.codes());
}

test "literals" {
    try expectParse("1; 'a'; \"b\"; true; false; null; x", "1\n\"a\"\n\"b\"\ntrue\nfalse\nnull\nx\n");
    try expectParse("`a${1}b${x}c`", "`a${1}b${x}c`\n");
    try expectParse("0x10", "16\n");
}

test "precedence" {
    try expectParse("1 + 2 * 3", "(+ 1 (* 2 3))\n");
    try expectParse("1 * 2 + 3", "(+ (* 1 2) 3)\n");
    try expectParse("1 - 2 - 3", "(- (- 1 2) 3)\n");
    try expectParse("2 ** 3 ** 2", "(** 2 (** 3 2))\n");
    try expectParse("2 * 3 ** 2", "(* 2 (** 3 2))\n");
    try expectParse("a || b && c", "(|| a (&& b c))\n");
    try expectParse("a | b ^ c & d", "(| a (^ b (& c d)))\n");
    try expectParse("a == b < c", "(== a (< b c))\n");
    try expectParse("1 << 2 + 3", "(<< 1 (+ 2 3))\n");
    try expectParse("a < b >= c", "(>= (< a b) c)\n");
    try expectParse("a >> b >>> c > d", "(> (>>> (>> a b) c) d)\n");
    try expectParse("a ?? b", "(?? a b)\n");
    try expectParse("-a * b", "(* (- a) b)\n");
    try expectParse("!a === b", "(=== (! a) b)\n");
    try expectParse("typeof a + void b", "(+ (typeof a) (void b))\n");
    try expectParse("(-2) ** 2", "(** [(- 2)] 2)\n");
    try expectParse("a ? b : c ? d : e", "(? a b (? c d e))\n");
    try expectParse("a || b ? c : d", "(? (|| a b) c d)\n");
}

test "calls and members" {
    try expectParse("console.log(1, 2)", "(call (. console log) 1 2)\n");
    try expectParse("a.b.c()", "(call (. (. a b) c))\n");
    try expectParse("f()()", "(call (call f))\n");
    try expectParse("a.if.class", "(. (. a if) class)\n");
    try expectParse("f(1,)", "(call f 1)\n");
}

test "automatic semicolon insertion" {
    try expectParse("a\nb", "a\nb\n");
    try expectParse("a;;b", "a\n;\nb\n");
    try expectParse("1 +\n2", "(+ 1 2)\n");
    // A line break doesn't end a statement when the next line continues the expression.
    try expectParse("a\n(b)", "(call a b)\n");
    try expectErrors("a b", &.{1005});
}

test "syntax errors" {
    try expectErrors("1 +", &.{1109});
    try expectErrors("f(1", &.{1005});
    try expectErrors("(1", &.{1005});
    try expectErrors("a.", &.{1003});
    try expectErrors("}", &.{1128});
    try expectErrors("a ? b", &.{1005});
    try expectErrors("-2 ** 2", &.{17006});
    try expectErrors("a ?? b || c", &.{5076});
    try expectErrors("a || b ?? c", &.{5076});
    try expectErrors("a ?? b && c", &.{5076});
    try expectParse("(a ?? b) || c", "(|| [(?? a b)] c)\n");
}

test "recovers and keeps parsing after an error" {
    const parsed: *Parsed = try .init("1 +;\nfoo(\n2\n");
    defer parsed.deinit();
    try testing.expectEqualSlices(u16, &.{ 1109, 1005 }, try parsed.codes());
}

test "unsupported syntax is reported and skipped" {
    try expectErrors("let x = 1", &.{9001});
    try expectErrors("type T = number", &.{9001});
    try expectErrors("x => x", &.{9001});
    try expectErrors("[1, 2]", &.{9001});
    try expectErrors("a = 1", &.{9001});
    try expectErrors("a >>= 1", &.{9001});
    // A multi-line declaration is skipped as one unit.
    const parsed: *Parsed = try .init("function f() {\n  return 1;\n}\nconsole.log(2)");
    defer parsed.deinit();
    try testing.expectEqualSlices(u16, &.{9001}, try parsed.codes());
    try testing.expectEqualStrings("(call (. console log) 2)\n", try parsed.render());
    // `type` and friends are still ordinary names.
    try expectParse("type\ndeclare", "type\ndeclare\n");
}
