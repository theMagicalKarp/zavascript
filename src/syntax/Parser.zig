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
/// Counters for the dense indices in `ast.Program`.
reference_count: u32 = 0,
binding_count: u32 = 0,
/// Set while parsing a `for` head, where `in` starts a `for...in` instead of being an operator.
no_in: bool = false,

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
        try statements.appendSlice(this.arena, try this.statementList(.eof));
        // A stray `}` at the top level.
        if (this.current().tag == .r_brace) {
            try this.report(this.current().start, .ts(1128), "Declaration or statement expected.", .{});
            _ = this.advance();
        }
    }
    return .{
        .statements = try statements.toOwnedSlice(this.arena),
        .reference_count = this.reference_count,
        .binding_count = this.binding_count,
    };
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
/// token on a new line, but never inside brackets the statement opened. A `}` that closes a
/// block the statement is inside also ends it, even if the statement left a `(` open.
fn synchronize(this: *Parser, statement_start: usize) void {
    // The brackets the statement had already opened when the error happened.
    var open: Brackets = .{};
    for (this.tokens[statement_start..this.index]) |tok| {
        _ = open.step(tok.tag);
    }
    // Always make progress, even if the error was at the statement's first token.
    if (this.index == statement_start and !open.step(this.advance().tag)) {
        return;
    }
    while (this.current().tag != .eof) {
        const tok = this.current();
        if (open.len == 0) {
            if (tok.tag == .semicolon) {
                _ = this.advance();
                return;
            }
            if (tok.newline_before or tok.tag == .r_brace) {
                return;
            }
        }
        if (tok.tag == .r_brace and !open.has(.l_brace)) {
            return;
        }
        if (!open.step(this.advance().tag)) {
            return;
        }
    }
}

/// The brackets open at some point, innermost last.
const Brackets = struct {
    tags: [64]Tag = undefined,
    len: usize = 0,
    /// Brackets nested too deeply to remember.
    overflow: usize = 0,

    /// Opens or closes a bracket. Returns false for a closing bracket with nothing open.
    fn step(this: *Brackets, tag: Tag) bool {
        switch (tag) {
            .l_brace, .l_paren, .l_bracket, .template_head => {
                if (this.len == this.tags.len) {
                    this.overflow += 1;
                } else {
                    this.tags[this.len] = tag;
                    this.len += 1;
                }
            },
            .r_brace, .r_paren, .r_bracket, .template_tail => {
                if (this.overflow > 0) {
                    this.overflow -= 1;
                } else if (this.len == 0) {
                    return false;
                } else {
                    this.len -= 1;
                }
            },
            else => {},
        }
        return true;
    }

    fn has(this: *const Brackets, tag: Tag) bool {
        return this.overflow > 0 or std.mem.indexOfScalar(Tag, this.tags[0..this.len], tag) != null;
    }
};

fn newExpr(this: *Parser, start: u32, data: Expr.Data) error{OutOfMemory}!*Expr {
    const expr = try this.arena.create(Expr);
    expr.* = .{ .start = start, .data = data };
    return expr;
}

// Statements

fn newStmt(this: *Parser, start: u32, data: Stmt.Data) error{OutOfMemory}!*Stmt {
    const stmt = try this.arena.create(Stmt);
    stmt.* = .{ .start = start, .data = data };
    return stmt;
}

/// Statements up to `end` (a `}` or the end of the file). A statement with a syntax error is
/// skipped, and parsing resumes at the next one.
fn statementList(this: *Parser, end: Tag) error{OutOfMemory}![]const *Stmt {
    var statements: std.ArrayList(*Stmt) = .empty;
    while (this.current().tag != end and this.current().tag != .eof) {
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
    return statements.toOwnedSlice(this.arena);
}

fn statement(this: *Parser) Error!*Stmt {
    const tok = this.current();
    switch (tok.tag) {
        .semicolon => {
            _ = this.advance();
            return this.newStmt(tok.start, .empty);
        },
        .r_brace => return this.fail(tok.start, .ts(1128), "Declaration or statement expected.", .{}),
        .l_brace => {
            _ = this.advance();
            const statements = try this.statementList(.r_brace);
            _ = try this.expect(.r_brace);
            return this.newStmt(tok.start, .{ .block = statements });
        },
        .kw_let, .kw_const => {
            if (tok.tag == .kw_const and this.peekToken(1).tag == .kw_enum) {
                return this.unsupported(tok.start, "'const enum' declarations are", .{});
            }
            const stmt = try this.variableStatement();
            try this.semicolon();
            return stmt;
        },
        .kw_var => return this.unsupported(tok.start, "'var' declarations are", .{}),
        .kw_if => return this.ifStatement(),
        .kw_while => {
            _ = this.advance();
            const condition = try this.parenthesized();
            const body = try this.statement();
            return this.newStmt(tok.start, .{ .@"while" = .{ .condition = condition, .body = body } });
        },
        .kw_do => {
            _ = this.advance();
            const body = try this.statement();
            _ = try this.expect(.kw_while);
            const condition = try this.parenthesized();
            // The `;` after `do ... while (x)` is always optional, even on the same line.
            _ = this.eat(.semicolon);
            return this.newStmt(tok.start, .{ .do_while = .{ .condition = condition, .body = body } });
        },
        .kw_for => return this.forStatement(),
        .kw_break, .kw_continue => {
            _ = this.advance();
            var label: ?[]const u8 = null;
            const next = this.current();
            if (next.tag == .identifier and !next.newline_before) {
                _ = this.advance();
                label = this.tokenText(next);
            }
            try this.semicolon();
            const jump: ast.Jump = .{ .label = label };
            return this.newStmt(tok.start, if (tok.tag == .kw_break) .{ .@"break" = jump } else .{ .@"continue" = jump });
        },
        .kw_switch => return this.switchStatement(),
        .kw_return, .kw_throw, .kw_try, .kw_with, .kw_debugger => {
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
                _ = this.advance();
                _ = this.advance();
                const body = try this.statement();
                return this.newStmt(tok.start, .{ .labeled = .{ .label = this.tokenText(tok), .body = body } });
            }
        },
        else => {},
    }

    const expr = try this.expression();
    try this.semicolon();
    return this.newStmt(tok.start, .{ .expression = expr });
}

/// `( expression )`, as in `if` and `while`.
fn parenthesized(this: *Parser) Error!*Expr {
    _ = try this.expect(.l_paren);
    const expr = try this.expression();
    _ = try this.expect(.r_paren);
    return expr;
}

fn ifStatement(this: *Parser) Error!*Stmt {
    const start = this.advance().start;
    const condition = try this.parenthesized();
    const then = try this.statement();
    const otherwise = if (this.eat(.kw_else)) try this.statement() else null;
    return this.newStmt(start, .{ .@"if" = .{ .condition = condition, .then = then, .otherwise = otherwise } });
}

/// A `let` or `const` declaration list, without the `;`, which a `for` head doesn't have.
fn variableStatement(this: *Parser) Error!*Stmt {
    const keyword = this.advance();
    const kind: ast.VariableKind = if (keyword.tag == .kw_let) .let else .@"const";
    var declarators: std.ArrayList(ast.Declarator) = .empty;
    while (true) {
        const name = this.current();
        switch (name.tag) {
            .identifier => {},
            .l_bracket, .l_brace => return this.unsupported(name.start, "Destructuring is", .{}),
            else => if (name.tag.isKeyword()) {
                return this.fail(name.start, .ts(1389), "'{s}' is not allowed as a variable declaration name.", .{this.tokenText(name)});
            } else {
                return this.fail(name.start, .ts(1134), "Variable declaration expected.", .{});
            },
        }
        _ = this.advance();
        if (this.current().tag == .bang) {
            return this.unsupported(this.current().start, "Definite assignment assertions are", .{});
        }
        const annotation = if (this.eat(.colon)) try this.typeAnnotation() else null;
        const init = if (this.eat(.equal)) try this.assignment() else null;
        try declarators.append(this.arena, .{
            .name = this.tokenText(name),
            .start = name.start,
            .end = this.previousEnd(),
            .binding = this.binding_count,
            .type = annotation,
            .init = init,
        });
        this.binding_count += 1;
        if (!this.eat(.comma)) {
            break;
        }
    }
    return this.newStmt(keyword.start, .{ .variable = .{
        .kind = kind,
        .declarators = try declarators.toOwnedSlice(this.arena),
    } });
}

/// Where the last consumed token ends.
fn previousEnd(this: *const Parser) u32 {
    return if (this.index == 0) 0 else this.tokens[this.index - 1].end;
}

fn forStatement(this: *Parser) Error!*Stmt {
    const start = this.advance().start;
    if (this.current().tag == .kw_await) {
        return this.unsupported(this.current().start, "'for await' statements are", .{});
    }
    _ = try this.expect(.l_paren);
    var init: ?*Stmt = null;
    const first = this.current();
    switch (first.tag) {
        .semicolon => {},
        .kw_let, .kw_const => init = try this.variableStatement(),
        .kw_var => return this.unsupported(first.start, "'var' declarations are", .{}),
        else => {
            // `in` would be a `for...in`, not the operator.
            this.no_in = true;
            defer this.no_in = false;
            init = try this.newStmt(first.start, .{ .expression = try this.expression() });
        },
    }
    const after = this.current();
    if (after.tag == .kw_in or this.isContextual(after, "of")) {
        return this.unsupported(start, "'for...{s}' statements are", .{this.tokenText(after)});
    }
    _ = try this.expect(.semicolon);
    const condition = if (this.current().tag != .semicolon) try this.expression() else null;
    _ = try this.expect(.semicolon);
    const update = if (this.current().tag != .r_paren) try this.expression() else null;
    _ = try this.expect(.r_paren);
    const body = try this.statement();
    return this.newStmt(start, .{ .@"for" = .{ .init = init, .condition = condition, .update = update, .body = body } });
}

fn switchStatement(this: *Parser) Error!*Stmt {
    const start = this.advance().start;
    const discriminant = try this.parenthesized();
    _ = try this.expect(.l_brace);
    var clauses: std.ArrayList(ast.Clause) = .empty;
    while (this.current().tag != .r_brace) {
        const tok = this.current();
        var case: ?*Expr = null;
        switch (tok.tag) {
            .kw_case => {
                _ = this.advance();
                case = try this.expression();
            },
            .kw_default => _ = this.advance(),
            else => return this.fail(tok.start, .ts(1130), "'case' or 'default' expected.", .{}),
        }
        _ = try this.expect(.colon);
        var statements: std.ArrayList(*Stmt) = .empty;
        while (true) {
            switch (this.current().tag) {
                .kw_case, .kw_default, .r_brace, .eof => break,
                else => try statements.append(this.arena, try this.statement()),
            }
        }
        try clauses.append(this.arena, .{ .start = tok.start, .case = case, .statements = try statements.toOwnedSlice(this.arena) });
    }
    _ = this.advance();
    return this.newStmt(start, .{ .@"switch" = .{ .discriminant = discriminant, .clauses = try clauses.toOwnedSlice(this.arena) } });
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

// Types

/// The type after a `:`. Only primitive keywords and plain names parse; the rest of the type
/// syntax is reported as unsupported.
fn typeAnnotation(this: *Parser) Error!*const ast.TypeNode {
    const tok = this.current();
    const data: ast.TypeNode.Data = switch (tok.tag) {
        .identifier => blk: {
            const text = this.tokenText(tok);
            break :blk if (std.meta.stringToEnum(ast.TypeNode.Keyword, text)) |keyword|
                .{ .keyword = keyword }
            else
                .{ .reference = text };
        },
        .kw_void => .{ .keyword = .void },
        .kw_null => .{ .keyword = .null },
        .string, .number, .kw_true, .kw_false, .minus, .template_full => return this.unsupported(tok.start, "Literal types are", .{}),
        .pipe, .ampersand => return this.unsupported(tok.start, "Union and intersection types are", .{}),
        .l_paren, .kw_new, .less => return this.unsupported(tok.start, "Function types are", .{}),
        .l_brace => return this.unsupported(tok.start, "Object types are", .{}),
        .l_bracket => return this.unsupported(tok.start, "Tuple types are", .{}),
        .kw_typeof => return this.unsupported(tok.start, "'typeof' types are", .{}),
        .kw_this => return this.unsupported(tok.start, "'this' types are", .{}),
        else => return this.fail(tok.start, .ts(1110), "Type expected.", .{}),
    };
    _ = this.advance();
    const next = this.current();
    switch (next.tag) {
        .pipe, .ampersand => return this.unsupported(next.start, "Union and intersection types are", .{}),
        .l_bracket => if (!next.newline_before) return this.unsupported(next.start, "Array types are", .{}),
        .less => return this.unsupported(next.start, "Generic types are", .{}),
        .dot => return this.unsupported(next.start, "Qualified type names are", .{}),
        else => {},
    }
    const node = try this.arena.create(ast.TypeNode);
    node.* = .{ .start = tok.start, .data = data };
    return node;
}

// Expressions

fn expression(this: *Parser) Error!*Expr {
    var expr = try this.assignment();
    while (this.current().tag == .comma) {
        const tok = this.advance();
        const right = try this.assignment();
        expr = try this.newExpr(expr.start, .{ .binary = .{ .op = .comma, .left = expr, .right = right, .op_start = tok.start } });
    }
    return expr;
}

fn assignment(this: *Parser) Error!*Expr {
    const target = try this.conditional();
    // Only a left-hand-side expression can be assigned to; after anything else, like `a + 1`,
    // the `=` is left for the statement to report. (`1 = 2` parses, and the checker rejects it.)
    switch (target.data) {
        .unary, .update, .assign, .binary, .conditional => return target,
        else => {},
    }
    const tok = this.current();
    var tokens: u8 = 1;
    const op: ?ast.BinaryOp = switch (tok.tag) {
        .equal => null,
        .plus_equal => .add,
        .minus_equal => .subtract,
        .star_equal => .multiply,
        .slash_equal => .divide,
        .percent_equal => .remainder,
        .star_star_equal => .exponent,
        .less_less_equal => .shift_left,
        .ampersand_equal => .bitwise_and,
        .pipe_equal => .bitwise_or,
        .caret_equal => .bitwise_xor,
        .ampersand_ampersand_equal => .logical_and,
        .pipe_pipe_equal => .logical_or,
        .question_question_equal => .nullish,
        .arrow => return this.unsupported(tok.start, "Arrow functions are", .{}),
        .greater => blk: {
            const greater = this.greaterOperator() orelse return target;
            if (!greater.assignment) {
                return target;
            }
            tokens = greater.tokens;
            break :blk greater.op;
        },
        else => return target,
    };
    for (0..tokens) |_| {
        _ = this.advance();
    }
    // Assignment is right-associative: `a = b = c` is `a = (b = c)`.
    const value = try this.assignment();
    return this.newExpr(target.start, .{ .assign = .{ .op = op, .target = target, .value = value, .op_start = tok.start } });
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
        if (next.tag != .equal) {
            return null;
        }
        return .{ .op = if (count == 2) .shift_right else .shift_right_unsigned, .tokens = count + 1, .assignment = true };
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
        if (tok.tag == .kw_in and this.no_in) {
            return left;
        }
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
        .plus_plus, .minus_minus => {
            _ = this.advance();
            const operand = try this.unary();
            return this.newExpr(tok.start, .{ .update = .{ .increment = tok.tag == .plus_plus, .prefix = true, .operand = operand } });
        },
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
            .plus_plus, .minus_minus => {
                // `a\n++b` is `a; ++b`.
                if (tok.newline_before) {
                    return expr;
                }
                _ = this.advance();
                return this.newExpr(expr.start, .{ .update = .{ .increment = tok.tag == .plus_plus, .prefix = false, .operand = expr } });
            },
            else => return expr,
        }
    }
}

/// The arguments of a call, after the `(`.
fn arguments(this: *Parser) Error![]const *Expr {
    var args: std.ArrayList(*Expr) = .empty;
    while (this.current().tag != .r_paren) {
        switch (this.current().tag) {
            .ellipsis => return this.unsupported(this.current().start, "Spread arguments are", .{}),
            .r_brace, .r_bracket, .semicolon, .eof => return this.fail(this.current().start, .ts(1135), "Argument expression expected.", .{}),
            else => {},
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
            const ref = this.reference_count;
            this.reference_count += 1;
            return this.newExpr(tok.start, .{ .identifier = .{ .name = this.tokenText(tok), .ref = ref } });
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
        .identifier => |id| try writer.writeAll(id.name),
        // `(++ a)` for `++a`, `(a ++)` for `a++`.
        .update => |u| {
            const op = if (u.increment) "++" else "--";
            if (u.prefix) {
                try writer.print("({s} ", .{op});
                try sexpr(writer, u.operand);
                try writer.writeAll(")");
            } else {
                try writer.writeAll("(");
                try sexpr(writer, u.operand);
                try writer.print(" {s})", .{op});
            }
        },
        .assign => |a| {
            try writer.print("({s}= ", .{if (a.op) |op| op.lexeme() else ""});
            try sexpr(writer, a.target);
            try writer.writeAll(" ");
            try sexpr(writer, a.value);
            try writer.writeAll(")");
        },
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

/// Renders a statement on one line, with expressions as `sexpr` does.
fn renderStmt(writer: *std.Io.Writer, stmt: *const Stmt) std.Io.Writer.Error!void {
    switch (stmt.data) {
        .expression => |e| try sexpr(writer, e),
        .empty => try writer.writeAll(";"),
        .variable => |v| {
            try writer.writeAll(@tagName(v.kind));
            for (v.declarators) |d| {
                try writer.print(" {s}#{d}", .{ d.name, d.binding });
                if (d.type) |t| {
                    switch (t.data) {
                        .keyword => |k| try writer.print(": {t}", .{k}),
                        .reference => |name| try writer.print(": {s}", .{name}),
                    }
                }
                if (d.init) |init| {
                    try writer.writeAll(" = ");
                    try sexpr(writer, init);
                }
            }
        },
        .block => |statements| {
            try writer.writeAll("{");
            for (statements) |s| {
                try writer.writeAll(" ");
                try renderStmt(writer, s);
            }
            try writer.writeAll(" }");
        },
        .@"if" => |i| {
            try writer.writeAll("if ");
            try sexpr(writer, i.condition);
            try writer.writeAll(" ");
            try renderStmt(writer, i.then);
            if (i.otherwise) |o| {
                try writer.writeAll(" else ");
                try renderStmt(writer, o);
            }
        },
        .@"while", .do_while => |l| {
            try writer.print("{s} ", .{if (stmt.data == .@"while") "while" else "do-while"});
            try sexpr(writer, l.condition);
            try writer.writeAll(" ");
            try renderStmt(writer, l.body);
        },
        .@"for" => |f| {
            try writer.writeAll("for (");
            if (f.init) |init| {
                try renderStmt(writer, init);
            }
            try writer.writeAll("; ");
            if (f.condition) |c| {
                try sexpr(writer, c);
            }
            try writer.writeAll("; ");
            if (f.update) |u| {
                try sexpr(writer, u);
            }
            try writer.writeAll(") ");
            try renderStmt(writer, f.body);
        },
        .@"break", .@"continue" => |j| {
            try writer.writeAll(if (stmt.data == .@"break") "break" else "continue");
            if (j.label) |label| {
                try writer.print(" {s}", .{label});
            }
        },
        .labeled => |l| {
            try writer.print("{s}: ", .{l.label});
            try renderStmt(writer, l.body);
        },
        .@"switch" => |sw| {
            try writer.writeAll("switch ");
            try sexpr(writer, sw.discriminant);
            for (sw.clauses) |clause| {
                if (clause.case) |c| {
                    try writer.writeAll(" case ");
                    try sexpr(writer, c);
                    try writer.writeAll(":");
                } else {
                    try writer.writeAll(" default:");
                }
                for (clause.statements) |s| {
                    try writer.writeAll(" ");
                    try renderStmt(writer, s);
                }
            }
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
            try renderStmt(&out.writer, stmt);
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

test "assignment" {
    try expectParse("a = b = 1", "(= a (= b 1))\n");
    try expectParse("a += 1; a **= 2; a ??= 3", "(+= a 1)\n(**= a 2)\n(??= a 3)\n");
    try expectParse("a >>= 1; a >>>= 2; a >= 3", "(>>= a 1)\n(>>>= a 2)\n(>= a 3)\n");
    try expectParse("a = b ? c : d", "(= a (? b c d))\n");
    try expectParse("a ? b : c = d", "(? a b (= c d))\n");
    try expectParse("a || (b = c)", "(|| a [(= b c)])\n");
}

test "update and comma" {
    try expectParse("++a; a--; -a++", "(++ a)\n(a --)\n(- (a ++))\n");
    try expectParse("a\n++b", "a\n(++ b)\n");
    try expectParse("a, b = 1, c", "(, (, a (= b 1)) c)\n");
    try expectParse("f((a, b), c)", "(call f [(, a b)] c)\n");
}

test "statements" {
    try expectParse("let a = 1, b: number; const c = a", "let a#0 = 1 b#1: number\nconst c#2 = a\n");
    try expectParse("{ a; { b } }", "{ a { b } }\n");
    try expectParse("if (a) b; else if (c) d; else e", "if a b else if c d else e\n");
    try expectParse("while (a) { b }", "while a { b }\n");
    try expectParse("do a; while (b) c", "do-while b a\nc\n");
    try expectParse("for (let i = 0; i < 3; i++) a", "for (let i#0 = 0; (< i 3); (i ++)) a\n");
    try expectParse("for (;;) {}", "for (; ; ) { }\n");
    try expectParse("for (a = 0, b = 1; ; a++, b++) ;", "for ((, (= a 0) (= b 1)); ; (, (a ++) (b ++))) ;\n");
    try expectParse("x: for (;;) { break x; continue }", "x: for (; ; ) { break x continue }\n");
    try expectParse("break\nx", "break\nx\n");
    try expectParse("switch (a) { case 1: b; case 2: default: c; d }", "switch a case 1: b case 2: default: c d\n");
}

test "statement errors" {
    try expectErrors("let 1", &.{1134});
    try expectErrors("let if = 1", &.{1389});
    try expectErrors("let x: = 1", &.{1110});
    try expectErrors("switch (a) { b }", &.{1130});
    try expectErrors("if (a) { b", &.{1005});
    try expectErrors("a + 1 = 2", &.{1005});
    try expectErrors("a++ = 2", &.{1005});
    try expectParse("1 = 2", "(= 1 2)\n");
    // An error inside a block doesn't hide the statements after it.
    const parsed: *Parsed = try .init("{\n  a +;\n  b(\n}\nc");
    defer parsed.deinit();
    try testing.expectEqualSlices(u16, &.{ 1109, 1135 }, try parsed.codes());
    try testing.expectEqualStrings("{ }\nc\n", try parsed.render());
}

test "unsupported syntax is reported and skipped" {
    try expectErrors("var x = 1", &.{9001});
    try expectErrors("let [a] = b", &.{9001});
    try expectErrors("let a: number | string", &.{9001});
    try expectErrors("let a: number[]", &.{9001});
    try expectErrors("let a: 1", &.{9001});
    try expectErrors("for (const x of y) {}", &.{9001});
    try expectErrors("for (x in y) {}", &.{9001});
    try expectErrors("type T = number", &.{9001});
    try expectErrors("x => x", &.{9001});
    try expectErrors("[1, 2]", &.{9001});
    // A multi-line declaration is skipped as one unit.
    const parsed: *Parsed = try .init("function f() {\n  return 1;\n}\nconsole.log(2)");
    defer parsed.deinit();
    try testing.expectEqualSlices(u16, &.{9001}, try parsed.codes());
    try testing.expectEqualStrings("(call (. console log) 2)\n", try parsed.render());
    // `type` and friends are still ordinary names.
    try expectParse("type\ndeclare", "type\ndeclare\n");
}
