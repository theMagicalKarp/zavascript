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
scope_count: u32 = 0,
function_count: u32 = 0,
type_spans: std.ArrayList(ast.Span) = .empty,
/// Set while parsing a `for` head, where `in` starts a `for...in` instead of being an operator.
no_in: bool = false,
/// A `.d.ts` file, which only declares things: `declare`, overloads, intersections and
/// `[Symbol.iterator]` members are allowed there.
ambient: bool = false,

/// `error.Syntax` unwinds to the enclosing statement, which reports nothing more and resyncs.
const Error = error{ OutOfMemory, Syntax };

/// Parses a whole file. Problems go to `diagnostics`; the returned program holds every statement
/// that parsed cleanly.
pub fn parse(gpa: std.mem.Allocator, arena: std.mem.Allocator, source: *const Source, diagnostics: *diagnostic.Diagnostics) error{OutOfMemory}!ast.Program {
    const tokens = try Lexer.tokenize(gpa, source, diagnostics);
    defer gpa.free(tokens);
    var parser: Parser = .{ .arena = arena, .source = source, .diagnostics = diagnostics, .tokens = tokens, .ambient = std.mem.endsWith(u8, source.path, ".d.ts") };
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
        .scope_count = this.scope_count,
        .function_count = this.function_count,
        .type_spans = try this.type_spans.toOwnedSlice(this.arena),
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

/// Everything a failed speculative parse has to undo.
const Mark = struct {
    index: usize,
    reference_count: u32,
    binding_count: u32,
    scope_count: u32,
    function_count: u32,
    type_spans: usize,
    diagnostics: usize,
};

fn mark(this: *const Parser) Mark {
    return .{
        .index = this.index,
        .reference_count = this.reference_count,
        .binding_count = this.binding_count,
        .scope_count = this.scope_count,
        .function_count = this.function_count,
        .type_spans = this.type_spans.items.len,
        .diagnostics = this.diagnostics.items().len,
    };
}

fn reset(this: *Parser, m: Mark) void {
    this.index = m.index;
    this.reference_count = m.reference_count;
    this.binding_count = m.binding_count;
    this.scope_count = m.scope_count;
    this.function_count = m.function_count;
    this.type_spans.shrinkRetainingCapacity(m.type_spans);
    this.diagnostics.truncate(m.diagnostics);
}

fn newBinding(this: *Parser) u32 {
    const binding = this.binding_count;
    this.binding_count += 1;
    return binding;
}

fn newFunction(this: *Parser) u32 {
    const id = this.function_count;
    this.function_count += 1;
    return id;
}

fn newScope(this: *Parser) u32 {
    const scope = this.scope_count;
    this.scope_count += 1;
    return scope;
}

fn newExpr(this: *Parser, start: u32, data: Expr.Data) error{OutOfMemory}!*Expr {
    const expr = try this.arena.create(Expr);
    expr.* = .{ .start = start, .data = data };
    return expr;
}

// Statements

fn newStmt(this: *Parser, start: u32, data: Stmt.Data) error{OutOfMemory}!*Stmt {
    const stmt = try this.arena.create(Stmt);
    stmt.* = .{ .start = start, .end = this.previousEnd(), .data = data };
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
        .l_brace => return this.newStmt(tok.start, .{ .block = try this.block() }),
        .kw_let, .kw_const => {
            if (tok.tag == .kw_const and this.peekToken(1).tag == .kw_enum) {
                return this.unsupported(tok.start, "'const enum' declarations are", .{});
            }
            const stmt = try this.variableStatement(false);
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
        .kw_return => {
            _ = this.advance();
            const next = this.current();
            const value = switch (next.tag) {
                .semicolon, .r_brace, .eof => null,
                else => if (next.newline_before) null else try this.expression(),
            };
            try this.semicolon();
            return this.newStmt(tok.start, .{ .@"return" = value });
        },
        .kw_function => {
            _ = this.advance();
            return this.newStmt(tok.start, .{ .function = try this.function(.declaration, tok.start) });
        },
        .kw_throw => {
            _ = this.advance();
            const next = this.current();
            if (next.newline_before) {
                return this.fail(next.start, .ts(1142), "Line break not permitted here.", .{});
            }
            const value = try this.expression();
            try this.semicolon();
            return this.newStmt(tok.start, .{ .throw = value });
        },
        .kw_try => return this.tryStatement(),
        .kw_with, .kw_debugger => {
            return this.unsupported(tok.start, "'{s}' statements are", .{this.tokenText(tok)});
        },
        .kw_interface => return this.interfaceDeclaration(),
        .kw_class, .kw_enum, .kw_import, .kw_export => {
            return this.unsupported(tok.start, "'{s}' declarations are", .{this.tokenText(tok)});
        },
        .identifier => {
            const following = this.peekToken(1);
            const starts_declaration = !following.newline_before and (following.tag == .identifier or following.tag.isKeyword());
            if (starts_declaration and this.isContextual(tok, "type")) {
                return this.typeAlias();
            }
            if (starts_declaration and this.ambient and this.isContextual(tok, "declare")) {
                return this.declaration();
            }
            for ([_][]const u8{ "declare", "namespace", "module", "abstract", "async" }) |word| {
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

/// `{ statements }`
fn block(this: *Parser) Error!ast.Block {
    _ = try this.expect(.l_brace);
    const saved_no_in = this.no_in;
    this.no_in = false;
    defer this.no_in = saved_no_in;
    const scope = this.newScope();
    const statements = try this.statementList(.r_brace);
    _ = try this.expect(.r_brace);
    const declares_functions = for (statements) |stmt| {
        var st = stmt;
        while (st.data == .labeled) {
            st = st.data.labeled.body;
        }
        if (st.data == .function) {
            break true;
        }
    } else false;
    return .{ .statements = statements, .scope = scope, .declares_functions = declares_functions };
}

/// `( expression )`, as in `if` and `while`.
fn parenthesized(this: *Parser) Error!*Expr {
    _ = try this.expect(.l_paren);
    const expr = try this.expression();
    _ = try this.expect(.r_paren);
    return expr;
}

fn tryStatement(this: *Parser) Error!*Stmt {
    const start = this.advance().start;
    const body = try this.block();
    var handler: ?ast.Catch = null;
    if (this.current().tag == .kw_catch) {
        const catch_start = this.advance().start;
        const scope = this.newScope();
        var parameter: ?*const ast.Pattern = null;
        var annotation: ?*const ast.TypeNode = null;
        if (this.eat(.l_paren)) {
            parameter = try this.bindingPattern();
            if (this.current().tag == .colon) {
                annotation = try this.typeAnnotation(this.advance().start);
            }
            if (this.current().tag == .equal) {
                return this.fail(this.current().start, .ts(1197), "Catch clause variable cannot have an initializer.", .{});
            }
            _ = try this.expect(.r_paren);
        }
        handler = .{ .start = catch_start, .scope = scope, .parameter = parameter, .type = annotation, .block = try this.block() };
    }
    var finalizer: ?ast.Block = null;
    if (this.eat(.kw_finally)) {
        finalizer = try this.block();
    }
    if (handler == null and finalizer == null) {
        return this.fail(this.current().start, .ts(1472), "'catch' or 'finally' expected.", .{});
    }
    return this.newStmt(start, .{ .@"try" = .{ .block = body, .handler = handler, .finalizer = finalizer } });
}

fn ifStatement(this: *Parser) Error!*Stmt {
    const start = this.advance().start;
    const condition = try this.parenthesized();
    const then = try this.statement();
    const otherwise = if (this.eat(.kw_else)) try this.statement() else null;
    return this.newStmt(start, .{ .@"if" = .{ .condition = condition, .then = then, .otherwise = otherwise } });
}

/// A `let` or `const` declaration list, without the `;`, which a `for` head doesn't have. In a
/// `for` head (`for_head`), a destructuring declaration doesn't need an initializer, since a
/// `for...of` gives it its values.
fn variableStatement(this: *Parser, for_head: bool) Error!*Stmt {
    const keyword = this.advance();
    const kind: ast.VariableKind = if (keyword.tag == .kw_let) .let else .@"const";
    var declarators: std.ArrayList(ast.Declarator) = .empty;
    while (true) {
        const name = this.current();
        switch (name.tag) {
            .identifier => {},
            .l_bracket, .l_brace => {
                const pattern = try this.bindingPattern();
                const annotation = if (this.current().tag == .colon) try this.typeAnnotation(this.advance().start) else null;
                const init = if (this.eat(.equal)) try this.assignment() else null;
                if (init == null and !for_head) {
                    try this.report(name.start, .ts(1182), "A destructuring declaration must have an initializer.", .{});
                }
                try declarators.append(this.arena, .{
                    .name = "",
                    .start = name.start,
                    .end = this.previousEnd(),
                    .binding = 0,
                    .pattern = pattern,
                    .type = annotation,
                    .init = init,
                });
                if (!this.eat(.comma)) {
                    break;
                }
                continue;
            },
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
        const annotation = if (this.current().tag == .colon) try this.typeAnnotation(this.advance().start) else null;
        const init = if (this.eat(.equal)) try this.assignment() else null;
        if (init) |e| {
            nameFunction(e, this.tokenText(name));
        }
        try declarators.append(this.arena, .{
            .name = this.tokenText(name),
            .start = name.start,
            .end = this.previousEnd(),
            .binding = this.newBinding(),
            .type = annotation,
            .init = init,
        });
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
    const scope = this.newScope();
    var init: ?*Stmt = null;
    const first = this.current();
    {
        // `in` would be a `for...in`, not the operator.
        this.no_in = true;
        defer this.no_in = false;
        switch (first.tag) {
            .semicolon => {},
            .kw_let, .kw_const => init = try this.variableStatement(true),
            .kw_var => return this.unsupported(first.start, "'var' declarations are", .{}),
            else => init = try this.newStmt(first.start, .{ .expression = try this.expression() }),
        }
    }
    const after = this.current();
    if (after.tag == .kw_in or this.isContextual(after, "of")) {
        return this.forEach(start, scope, init.?, after.tag != .kw_in);
    }
    if (init) |s| {
        if (s.data == .variable) {
            for (s.data.variable.declarators) |d| {
                if (d.pattern != null and d.init == null) {
                    try this.report(d.start, .ts(1182), "A destructuring declaration must have an initializer.", .{});
                }
            }
        }
    }
    _ = try this.expect(.semicolon);
    const condition = if (this.current().tag != .semicolon) try this.expression() else null;
    _ = try this.expect(.semicolon);
    const update = if (this.current().tag != .r_paren) try this.expression() else null;
    _ = try this.expect(.r_paren);
    const body = try this.statement();
    return this.newStmt(start, .{ .@"for" = .{ .scope = scope, .init = init, .condition = condition, .update = update, .body = body } });
}

/// The rest of a `for...of` or `for...in` statement, from its `of` or `in`.
fn forEach(this: *Parser, start: u32, scope: u32, init: *Stmt, of: bool) Error!*Stmt {
    const keyword = if (of) "of" else "in";
    _ = this.advance();
    var head: ast.ForEach.Head = undefined;
    switch (init.data) {
        .variable => |v| {
            const d = v.declarators[0];
            if (v.declarators.len > 1) {
                try this.report(v.declarators[1].start, if (of) .ts(1188) else .ts(1091), "Only a single variable declaration is allowed in a 'for...{s}' statement.", .{keyword});
            }
            if (d.init) |e| {
                try this.report(e.start, if (of) .ts(1190) else .ts(1189), "The variable declaration of a 'for...{s}' statement cannot have an initializer.", .{keyword});
            }
            if (d.type) |t| {
                try this.report(t.start, if (of) .ts(2483) else .ts(2404), "The left-hand side of a 'for...{s}' statement cannot use a type annotation.", .{keyword});
            }
            const pattern = d.pattern orelse blk: {
                const p = try this.arena.create(ast.Pattern);
                p.* = .{ .start = d.start, .data = .{ .identifier = .{ .name = d.name, .start = d.start, .binding = d.binding } } };
                break :blk p;
            };
            head = .{ .declaration = .{ .kind = v.kind, .pattern = pattern, .end = d.end } };
        },
        .expression => |e| head = .{ .target = e },
        else => unreachable,
    }
    const right = if (of) try this.assignment() else try this.expression();
    _ = try this.expect(.r_paren);
    const body = try this.statement();
    return this.newStmt(start, .{ .for_each = .{ .of = of, .scope = scope, .head = head, .right = right, .body = body } });
}

fn switchStatement(this: *Parser) Error!*Stmt {
    const start = this.advance().start;
    const discriminant = try this.parenthesized();
    _ = try this.expect(.l_brace);
    const scope = this.newScope();
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
    return this.newStmt(start, .{ .@"switch" = .{ .scope = scope, .discriminant = discriminant, .clauses = try clauses.toOwnedSlice(this.arena) } });
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

// Type declarations

/// `interface Name extends A, B { ... }`
fn interfaceDeclaration(this: *Parser) Error!*Stmt {
    const start = this.advance().start;
    const name = try this.declarationName("Interface");
    const type_parameters = try this.genericParameters(false);
    var extends: std.ArrayList(ast.TypeReference) = .empty;
    if (this.eat(.kw_extends)) {
        while (true) {
            const tok = try this.expect(.identifier);
            if (this.current().tag == .dot) {
                return this.unsupported(this.current().start, "Qualified type names are", .{});
            }
            try extends.append(this.arena, .{ .name = this.tokenText(tok), .start = tok.start, .arguments = try this.typeArguments() });
            if (!this.eat(.comma)) {
                break;
            }
        }
    }
    const members = try this.typeMembers();
    const node = try this.arena.create(ast.Interface);
    node.* = .{ .name = this.tokenText(name), .start = name.start, .type_parameters = type_parameters, .extends = extends.items, .members = members };
    return this.newStmt(start, .{ .interface = node });
}

/// `type Name = T;`
fn typeAlias(this: *Parser) Error!*Stmt {
    const start = this.advance().start;
    const name = try this.declarationName("Type alias");
    const type_parameters = try this.genericParameters(false);
    _ = try this.expect(.equal);
    const t = try this.typeNode();
    try this.semicolon();
    const node = try this.arena.create(ast.TypeAlias);
    node.* = .{ .name = this.tokenText(name), .start = name.start, .type_parameters = type_parameters, .type = t };
    return this.newStmt(start, .{ .type_alias = node });
}

/// `declare var x: T;`, `declare const x: T;` or `declare function f(x: T): R;`, in a `.d.ts`
/// file.
fn declaration(this: *Parser) Error!*Stmt {
    const start = this.advance().start;
    const keyword = this.advance();
    const is_function = switch (keyword.tag) {
        .kw_var, .kw_let, .kw_const => false,
        .kw_function => true,
        else => return this.unsupported(keyword.start, "'declare {s}' declarations are", .{this.tokenText(keyword)}),
    };
    const name = try this.expect(.identifier);
    const t = if (is_function) blk: {
        const at = this.current().start;
        const type_parameters = try this.genericParameters(false);
        const parameters = try this.typeParameters();
        _ = try this.expect(.colon);
        const returns = try this.returnType();
        break :blk try this.newType(at, .{ .function = .{ .type_parameters = type_parameters, .parameters = parameters, .returns = returns } });
    } else blk: {
        _ = try this.expect(.colon);
        break :blk try this.typeNode();
    };
    try this.semicolon();
    const node = try this.arena.create(ast.Declare);
    node.* = .{ .name = this.tokenText(name), .start = name.start, .type = t, .function = is_function };
    return this.newStmt(start, .{ .declare = node });
}

/// The name of an interface or type alias, which can't be one of the built-in types' names.
fn declarationName(this: *Parser, comptime what: []const u8) Error!Token {
    const name = this.current();
    if (name.tag != .identifier) {
        return this.fail(name.start, .ts(1003), "Identifier expected.", .{});
    }
    _ = this.advance();
    if (std.meta.stringToEnum(ast.TypeNode.Keyword, this.tokenText(name)) != null or this.isContextual(name, "object") or this.isContextual(name, "symbol") or this.isContextual(name, "bigint")) {
        try this.report(name.start, if (what[0] == 'I') .ts(2427) else .ts(2457), what ++ " name cannot be '{s}'.", .{this.tokenText(name)});
    }
    return name;
}

/// The members of an interface or object type, from its `{` to its `}`.
fn typeMembers(this: *Parser) Error![]const ast.TypeMember {
    _ = try this.expect(.l_brace);
    var members: std.ArrayList(ast.TypeMember) = .empty;
    while (this.current().tag != .r_brace) {
        var tok = this.current();
        var readonly = false;
        // `readonly` is a modifier unless it's the property's name.
        if (this.isContextual(tok, "readonly") and startsPropertyName(this.peekToken(1).tag)) {
            _ = this.advance();
            readonly = true;
            tok = this.current();
        }
        if ((this.isContextual(tok, "get") or this.isContextual(tok, "set")) and startsPropertyName(this.peekToken(1).tag)) {
            return this.unsupported(tok.start, "Accessors are", .{});
        }
        if (tok.tag == .l_paren or tok.tag == .less or (tok.tag == .kw_new and (this.peekToken(1).tag == .l_paren or this.peekToken(1).tag == .less))) {
            const construct = tok.tag == .kw_new;
            if (construct) {
                _ = this.advance();
            }
            const start = this.current().start;
            const type_parameters = try this.genericParameters(false);
            const parameters = try this.typeParameters();
            const returns = if (this.eat(.colon)) try this.returnType() else null;
            const signature = try this.newType(start, .{ .function = .{ .type_parameters = type_parameters, .parameters = parameters, .returns = returns } });
            try members.append(this.arena, .{ .name = "", .start = tok.start, .optional = false, .readonly = readonly, .method = true, .type = signature, .signature = if (construct) .construct else .call });
            try this.memberSeparator();
            continue;
        }
        if (tok.tag == .l_bracket and this.startsIndexSignature()) {
            _ = this.advance();
            const key_name = this.advance();
            _ = try this.expect(.colon);
            const key = try this.typeNode();
            _ = try this.expect(.r_bracket);
            _ = try this.expect(.colon);
            const value = try this.typeNode();
            try members.append(this.arena, .{ .name = this.tokenText(key_name), .start = tok.start, .optional = false, .readonly = readonly, .method = false, .type = value, .signature = .{ .index = key } });
            try this.memberSeparator();
            continue;
        }
        const name: []const u8 = switch (tok.tag) {
            .identifier => this.tokenText(tok),
            .string => try Lexer.cook(this.arena, this.source.text, tok),
            .number => try number.toString(this.arena, number.parseLiteral(this.tokenText(tok))),
            .l_bracket => blk: {
                // A well-known symbol like `[Symbol.iterator]`, which the builtins need.
                if (this.ambient and this.isContextual(this.peekToken(1), "Symbol") and this.peekToken(2).tag == .dot and this.peekToken(3).tag == .identifier and this.peekToken(4).tag == .r_bracket) {
                    const symbol = this.peekToken(3);
                    for (0..4) |_| {
                        _ = this.advance();
                    }
                    break :blk try std.fmt.allocPrint(this.arena, "[Symbol.{s}]", .{this.tokenText(symbol)});
                }
                return this.unsupported(tok.start, "Computed property names are", .{});
            },
            else => if (tok.tag.isKeyword())
                this.tokenText(tok)
            else
                return this.fail(tok.start, .ts(1131), "Property or signature expected.", .{}),
        };
        _ = this.advance();
        const optional = this.eat(.question);
        var member: ast.TypeMember = .{ .name = name, .start = tok.start, .optional = optional, .readonly = readonly, .method = false, .type = null };
        switch (this.current().tag) {
            .l_paren, .less => {
                const start = this.current().start;
                const type_parameters = try this.genericParameters(false);
                const parameters = try this.typeParameters();
                const returns = if (this.eat(.colon)) try this.returnType() else null;
                member.method = true;
                member.type = try this.newType(start, .{ .function = .{ .type_parameters = type_parameters, .parameters = parameters, .returns = returns } });
            },
            .colon => {
                _ = this.advance();
                member.type = try this.typeNode();
            },
            else => {},
        }
        try members.append(this.arena, member);
        try this.memberSeparator();
    }
    _ = this.advance();
    return members.items;
}

/// What a `[Symbol.iterator]` member is named, which no identifier or string key can be.
pub const symbol_iterator = "[Symbol.iterator]";

/// The `;` or `,` after a member, which a line break can stand in for.
fn memberSeparator(this: *Parser) Error!void {
    if (!this.eat(.semicolon) and !this.eat(.comma)) {
        const next = this.current();
        if (next.tag != .r_brace and !next.newline_before) {
            return this.fail(next.start, .ts(1005), "';' expected.", .{});
        }
    }
}

/// Whether the `[` at the current token starts an index signature, `[key: string]: T`.
fn startsIndexSignature(this: *const Parser) bool {
    const name = this.peekToken(1);
    return (name.tag == .identifier or name.tag.isKeyword()) and this.peekToken(2).tag == .colon;
}

/// A return type annotation, which can be a type predicate: `x is T`.
fn returnType(this: *Parser) Error!*const ast.TypeNode {
    const tok = this.current();
    const next = this.peekToken(1);
    if ((tok.tag == .identifier or tok.tag == .kw_this) and this.isContextual(next, "is") and !next.newline_before) {
        if (tok.tag == .kw_this) {
            return this.unsupported(tok.start, "'this' type predicates are", .{});
        }
        _ = this.advance();
        _ = this.advance();
        const t = try this.typeNode();
        return this.newType(tok.start, .{ .predicate = .{ .parameter = this.tokenText(tok), .type = t } });
    }
    if (this.isContextual(tok, "asserts") and (next.tag == .identifier or next.tag == .kw_this) and !next.newline_before) {
        return this.unsupported(tok.start, "Assertion signatures are", .{});
    }
    return this.typeNode();
}

/// Whether a token can start a property name, as after `readonly` or `get`.
fn startsPropertyName(tag: Tag) bool {
    return tag == .identifier or tag == .string or tag == .number or tag == .l_bracket or tag.isKeyword();
}

// Types

/// The type after an annotation's `:`, which has been consumed. `span_start` is where the
/// annotation starts (the `:`, or a parameter's `?`), for `Program.type_spans`.
fn typeAnnotation(this: *Parser, span_start: u32) Error!*const ast.TypeNode {
    const node = try this.typeNode();
    try this.type_spans.append(this.arena, .{ .start = span_start, .end = this.previousEnd() });
    return node;
}

/// A function's return type annotation, after its `:`; see `typeAnnotation`.
fn returnAnnotation(this: *Parser, span_start: u32) Error!*const ast.TypeNode {
    const node = try this.returnType();
    try this.type_spans.append(this.arena, .{ .start = span_start, .end = this.previousEnd() });
    return node;
}

fn newType(this: *Parser, start: u32, data: ast.TypeNode.Data) error{OutOfMemory}!*const ast.TypeNode {
    const node = try this.arena.create(ast.TypeNode);
    node.* = .{ .start = start, .data = data };
    return node;
}

/// A type. The primitive keywords, names, literals, arrays, tuples, object, function and union
/// types parse; the rest of the type syntax is reported as unsupported.
fn typeNode(this: *Parser) Error!*const ast.TypeNode {
    const start = this.current().start;
    // A union can start with a `|`.
    const leading = this.eat(.pipe);
    if (this.current().tag == .ampersand) {
        return this.unsupported(this.current().start, "Union and intersection types are", .{});
    }
    const first = try this.intersection(leading);
    if (this.current().tag != .pipe) {
        return first;
    }
    var members: std.ArrayList(*const ast.TypeNode) = .empty;
    try members.append(this.arena, first);
    while (this.eat(.pipe)) {
        try members.append(this.arena, try this.intersection(true));
    }
    return this.newType(start, .{ .@"union" = members.items });
}

/// `A & B`, which binds tighter than `|`. Only a `.d.ts` file can have one so far.
fn intersection(this: *Parser, in_union: bool) Error!*const ast.TypeNode {
    const first = try this.unionMember(in_union);
    if (this.current().tag != .ampersand) {
        return first;
    }
    if (!this.ambient) {
        return this.unsupported(this.current().start, "Intersection types are", .{});
    }
    var members: std.ArrayList(*const ast.TypeNode) = .empty;
    try members.append(this.arena, first);
    while (this.eat(.ampersand)) {
        try members.append(this.arena, try this.unionMember(false));
    }
    return this.newType(first.start, .{ .intersection = members.items });
}

/// One member of a union type. A function type there has to be parenthesized (TS1385).
fn unionMember(this: *Parser, in_union: bool) Error!*const ast.TypeNode {
    const tok = this.current();
    if (in_union and tok.tag == .l_paren and this.startsFunctionType()) {
        try this.report(tok.start, .ts(1385), "Function type notation must be parenthesized when used in a union type.", .{});
    }
    return this.primaryType();
}

/// A type that isn't a union: a primary type, and any `[]` after it.
fn primaryType(this: *Parser) Error!*const ast.TypeNode {
    const tok = this.current();
    var node: *const ast.TypeNode = switch (tok.tag) {
        .identifier => blk: {
            for ([_][]const u8{ "keyof", "readonly", "unique", "infer" }) |word| {
                const following = this.peekToken(1);
                if (!this.isContextual(tok, word) or following.newline_before or !(following.tag == .identifier or following.tag == .l_paren or following.tag == .l_bracket or following.tag == .l_brace or following.tag.isKeyword())) {
                    continue;
                }
                if (word[0] == 'u' or word[0] == 'i') {
                    return this.unsupported(tok.start, "'{s}' type operators are", .{word});
                }
                _ = this.advance();
                const operand = try this.primaryType();
                if (word[0] == 'k') {
                    return this.newType(tok.start, .{ .keyof = operand });
                }
                switch (operand.data) {
                    .array => {},
                    // A `.d.ts` file only has them as parameters, where they're the same as
                    // mutable ones for anything we can pass.
                    .tuple => if (this.ambient) {
                        return operand;
                    } else return this.unsupported(tok.start, "Readonly tuple types are", .{}),
                    else => {
                        try this.report(tok.start, .ts(1354), "'readonly' type modifier is only permitted on array and tuple literal types.", .{});
                        return operand;
                    },
                }
                return this.newType(tok.start, .{ .readonly = operand });
            }
            _ = this.advance();
            const text = this.tokenText(tok);
            if (this.current().tag == .dot) {
                return this.unsupported(this.current().start, "Qualified type names are", .{});
            }
            const type_arguments = try this.typeArguments();
            if (type_arguments.len == 0) {
                if (std.meta.stringToEnum(ast.TypeNode.Keyword, text)) |keyword| {
                    break :blk try this.newType(tok.start, .{ .keyword = keyword });
                }
            }
            break :blk try this.newType(tok.start, .{ .reference = .{ .name = text, .start = tok.start, .arguments = type_arguments } });
        },
        .kw_void, .kw_null => blk: {
            _ = this.advance();
            break :blk try this.newType(tok.start, .{ .keyword = if (tok.tag == .kw_void) .void else .null });
        },
        .l_paren => if (this.startsFunctionType())
            try this.functionType()
        else blk: {
            _ = this.advance();
            const inner = try this.typeNode();
            _ = try this.expect(.r_paren);
            break :blk inner;
        },
        .string, .template_full => blk: {
            _ = this.advance();
            break :blk try this.newType(tok.start, .{ .literal = .{ .string = try Lexer.cook(this.arena, this.source.text, tok) } });
        },
        .number => blk: {
            _ = this.advance();
            break :blk try this.newType(tok.start, .{ .literal = .{ .number = number.parseLiteral(this.tokenText(tok)) } });
        },
        .minus => blk: {
            _ = this.advance();
            const n = this.current();
            if (n.tag != .number) {
                return this.fail(n.start, .ts(1110), "Type expected.", .{});
            }
            _ = this.advance();
            break :blk try this.newType(tok.start, .{ .literal = .{ .number = -number.parseLiteral(this.tokenText(n)) } });
        },
        .kw_true, .kw_false => blk: {
            _ = this.advance();
            break :blk try this.newType(tok.start, .{ .literal = .{ .boolean = tok.tag == .kw_true } });
        },
        .template_head => return this.unsupported(tok.start, "Template literal types are", .{}),
        .ampersand => return this.unsupported(tok.start, "Union and intersection types are", .{}),
        .kw_new => return this.unsupported(tok.start, "Constructor types are", .{}),
        .less => try this.functionType(),
        .l_brace => if (this.startsMappedType())
            try this.mappedType()
        else
            try this.newType(tok.start, .{ .object = try this.typeMembers() }),
        .l_bracket => try this.tupleType(),
        .kw_typeof => try this.typeQuery(),
        .kw_this => return this.unsupported(tok.start, "'this' types are", .{}),
        else => return this.fail(tok.start, .ts(1110), "Type expected.", .{}),
    };
    while (true) {
        const next = this.current();
        switch (next.tag) {
            .l_bracket => {
                if (next.newline_before) {
                    break;
                }
                _ = this.advance();
                if (this.eat(.r_bracket)) {
                    node = try this.newType(node.start, .{ .array = node });
                    continue;
                }
                const index = try this.typeNode();
                _ = try this.expect(.r_bracket);
                node = try this.newType(node.start, .{ .indexed = .{ .object = node, .index = index } });
            },
            else => break,
        }
    }
    return node;
}

/// Whether the `(` at the current token starts a function type rather than a parenthesized
/// type (tsc's `isStartOfFunctionTypeOrConstructorType`).
fn startsFunctionType(this: *const Parser) bool {
    const next = this.peekToken(1);
    switch (next.tag) {
        .r_paren, .ellipsis => return true,
        .identifier, .kw_this => {},
        else => return next.tag.isKeyword(),
    }
    return switch (this.peekToken(2).tag) {
        .colon, .comma, .question, .equal => true,
        .r_paren => this.peekToken(3).tag == .arrow,
        else => false,
    };
}

/// `[T, U]`
fn tupleType(this: *Parser) Error!*const ast.TypeNode {
    const start = this.advance().start;
    var elements: std.ArrayList(*const ast.TypeNode) = .empty;
    while (this.current().tag != .r_bracket) {
        const tok = this.current();
        if (tok.tag == .ellipsis) {
            return this.unsupported(tok.start, "Rest elements in tuple types are", .{});
        }
        const next = this.peekToken(1);
        if ((tok.tag == .identifier or tok.tag.isKeyword()) and (next.tag == .colon or (next.tag == .question and this.peekToken(2).tag == .colon))) {
            return this.unsupported(tok.start, "Named tuple members are", .{});
        }
        try elements.append(this.arena, try this.typeNode());
        if (this.current().tag == .question) {
            return this.unsupported(this.current().start, "Optional tuple elements are", .{});
        }
        if (!this.eat(.comma)) {
            break;
        }
    }
    _ = try this.expect(.r_bracket);
    return this.newType(start, .{ .tuple = elements.items });
}

fn functionType(this: *Parser) Error!*const ast.TypeNode {
    const start = this.current().start;
    const type_parameters = try this.genericParameters(false);
    const parameters = try this.typeParameters();
    _ = try this.expect(.arrow);
    const returns = try this.returnType();
    return this.newType(start, .{ .function = .{ .type_parameters = type_parameters, .parameters = parameters, .returns = returns } });
}

/// `typeof x` or `typeof x.y` in a type.
fn typeQuery(this: *Parser) Error!*const ast.TypeNode {
    const start = this.advance().start;
    const name = this.current();
    if (name.tag != .identifier) {
        if (name.tag == .kw_this) {
            return this.unsupported(name.start, "'typeof this' is", .{});
        }
        return this.fail(name.start, .ts(1003), "Identifier expected.", .{});
    }
    _ = this.advance();
    var path: std.ArrayList([]const u8) = .empty;
    while (this.eat(.dot)) {
        const p = this.current();
        if (p.tag != .identifier and !p.tag.isKeyword()) {
            return this.fail(p.start, .ts(1003), "Identifier expected.", .{});
        }
        _ = this.advance();
        try path.append(this.arena, this.tokenText(p));
    }
    if (this.current().tag == .less and !this.current().newline_before) {
        return this.unsupported(this.current().start, "Instantiation expressions are", .{});
    }
    return this.newType(start, .{ .query = .{ .name = this.tokenText(name), .path = path.items } });
}

/// Whether the `{` at the current token starts a mapped type, `{ [P in K]: T }`.
fn startsMappedType(this: *const Parser) bool {
    var i: usize = 1;
    const first = this.peekToken(i);
    if (first.tag == .plus or first.tag == .minus) {
        i += 1;
        if (!this.isContextual(this.peekToken(i), "readonly")) {
            return false;
        }
        i += 1;
    } else if (this.isContextual(first, "readonly")) {
        i += 1;
    }
    return this.peekToken(i).tag == .l_bracket and this.peekToken(i + 1).tag == .identifier and this.peekToken(i + 2).tag == .kw_in;
}

/// `{ readonly [P in K]?: T }`, with `+` or `-` on either modifier.
fn mappedType(this: *Parser) Error!*const ast.TypeNode {
    const start = this.advance().start;
    var readonly: ast.TypeNode.Modifier = .none;
    if (this.eat(.plus)) {
        readonly = .add;
    } else if (this.eat(.minus)) {
        readonly = .remove;
    }
    if (this.isContextual(this.current(), "readonly")) {
        _ = this.advance();
        if (readonly == .none) {
            readonly = .add;
        }
    }
    _ = try this.expect(.l_bracket);
    const name = try this.expect(.identifier);
    _ = try this.expect(.kw_in);
    const constraint = try this.typeNode();
    if (this.isContextual(this.current(), "as")) {
        return this.unsupported(this.current().start, "Key remapping in mapped types is", .{});
    }
    _ = try this.expect(.r_bracket);
    var optional: ast.TypeNode.Modifier = .none;
    if (this.eat(.plus)) {
        optional = .add;
        _ = try this.expect(.question);
    } else if (this.eat(.minus)) {
        optional = .remove;
        _ = try this.expect(.question);
    } else if (this.eat(.question)) {
        optional = .add;
    }
    const t = if (this.eat(.colon)) try this.typeNode() else null;
    _ = this.eat(.semicolon) or this.eat(.comma);
    _ = try this.expect(.r_brace);
    const mapped = try this.arena.create(ast.TypeNode.Mapped);
    mapped.* = .{
        .parameter = .{ .name = this.tokenText(name), .start = name.start },
        .constraint = constraint,
        .type = t,
        .optional = optional,
        .readonly = readonly,
    };
    return this.newType(start, .{ .mapped = mapped });
}

/// `<T extends C = D, U>`, if there is one. `span` records it for `Program.type_spans`, for the
/// type parameters of a function, which node blanks out of its source.
fn genericParameters(this: *Parser, span: bool) Error![]const ast.GenericParameter {
    if (this.current().tag != .less) {
        return &.{};
    }
    const start = this.advance().start;
    var parameters: std.ArrayList(ast.GenericParameter) = .empty;
    while (this.current().tag != .greater) {
        const tok = this.current();
        if (this.isContextual(tok, "const") or tok.tag == .kw_const or this.isContextual(tok, "in") or tok.tag == .kw_in or this.isContextual(tok, "out")) {
            if (this.peekToken(1).tag == .identifier) {
                return this.unsupported(tok.start, "Type parameter modifiers are", .{});
            }
        }
        if (tok.tag != .identifier) {
            return this.fail(tok.start, .ts(1139), "Type parameter declaration expected.", .{});
        }
        _ = this.advance();
        var parameter: ast.GenericParameter = .{ .name = this.tokenText(tok), .start = tok.start };
        if (this.eat(.kw_extends)) {
            parameter.constraint = try this.typeNode();
        }
        if (this.eat(.equal)) {
            parameter.default = try this.typeNode();
        }
        try parameters.append(this.arena, parameter);
        if (!this.eat(.comma)) {
            break;
        }
    }
    _ = try this.expect(.greater);
    if (parameters.items.len == 0) {
        try this.report(start, .ts(1098), "Type parameter list cannot be empty.", .{});
    }
    if (span) {
        try this.type_spans.append(this.arena, .{ .start = start, .end = this.previousEnd() });
    }
    return parameters.items;
}

/// `<A, B>` after a type's name, if there is one.
fn typeArguments(this: *Parser) Error![]const *const ast.TypeNode {
    if (this.current().tag != .less) {
        return &.{};
    }
    const start = this.advance().start;
    var list: std.ArrayList(*const ast.TypeNode) = .empty;
    while (this.current().tag != .greater) {
        try list.append(this.arena, try this.typeNode());
        if (!this.eat(.comma)) {
            break;
        }
    }
    _ = try this.expect(.greater);
    if (list.items.len == 0) {
        try this.report(start, .ts(1099), "Type argument list cannot be empty.", .{});
    }
    return list.items;
}

/// `f<A, B>(...)`: type arguments where the `<` could also be a comparison. Only taken as type
/// arguments when a `(` follows (tsc's `parseTypeArgumentsInExpression`); otherwise nothing is
/// consumed and null is returned.
fn callTypeArguments(this: *Parser) Error!?[]const *const ast.TypeNode {
    const m = this.mark();
    const list = this.typeArguments() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Syntax => {
            this.reset(m);
            return null;
        },
    };
    if (this.current().tag != .l_paren or this.diagnostics.items().len > m.diagnostics) {
        this.reset(m);
        return null;
    }
    try this.type_spans.append(this.arena, .{ .start = this.tokens[m.index].start, .end = this.previousEnd() });
    return list;
}

/// The `( ... )` of a function type or method signature.
fn typeParameters(this: *Parser) Error![]const ast.TypeParameter {
    _ = try this.expect(.l_paren);
    var parameters: std.ArrayList(ast.TypeParameter) = .empty;
    while (this.current().tag != .r_paren) {
        const rest = this.eat(.ellipsis);
        const name = this.current();
        switch (name.tag) {
            .identifier => {},
            .kw_this => return this.unsupported(name.start, "'this' parameters are", .{}),
            .l_bracket, .l_brace => return this.unsupported(name.start, "Destructuring in function types is", .{}),
            else => return this.fail(name.start, .ts(1003), "Identifier expected.", .{}),
        }
        _ = this.advance();
        const optional = this.eat(.question);
        const annotation = if (this.eat(.colon)) try this.typeNode() else null;
        try parameters.append(this.arena, .{
            .name = this.tokenText(name),
            .start = name.start,
            .type = annotation,
            .optional = optional,
            .rest = rest,
        });
        if (!this.eat(.comma)) {
            break;
        }
    }
    _ = try this.expect(.r_paren);
    return parameters.toOwnedSlice(this.arena);
}

// Functions

/// A function declaration or expression, after the `function` keyword (at `start`).
fn function(this: *Parser, kind: ast.Function.Kind, start: u32) Error!*ast.Function {
    if (this.current().tag == .star) {
        return this.unsupported(this.current().start, "Generators are", .{});
    }
    var name: ?ast.Function.Name = null;
    const tok = this.current();
    if (tok.tag == .identifier) {
        _ = this.advance();
        name = .{ .text = this.tokenText(tok), .start = tok.start, .binding = this.newBinding() };
    } else if (kind == .declaration) {
        if (tok.tag.isKeyword() and tok.tag != .kw_this) {
            return this.fail(tok.start, .ts(1389), "'{s}' is not allowed as a function declaration name.", .{this.tokenText(tok)});
        }
        return this.fail(tok.start, .ts(1003), "Identifier expected.", .{});
    }
    const function_id = this.newFunction();
    const scope = this.newScope();
    const type_parameters = try this.genericParameters(true);
    const parameters = try this.parameterList();
    var returns: ?*const ast.TypeNode = null;
    var returns_start: u32 = 0;
    if (this.current().tag == .colon) {
        const colon = this.advance();
        returns_start = this.current().start;
        returns = try this.returnAnnotation(colon.start);
    }
    if (this.current().tag != .l_brace and kind == .declaration) {
        return this.unsupported(start, "Function overloads are", .{});
    }
    const body = try this.block();
    const node = try this.arena.create(ast.Function);
    node.* = .{
        .kind = kind,
        .id = function_id,
        .start = start,
        .end = this.previousEnd(),
        .name = name,
        .type_parameters = type_parameters,
        .inferred_name = if (name) |n| n.text else "",
        .parameters = parameters,
        .scope = scope,
        .returns = returns,
        .returns_start = returns_start,
        .body = .{ .block = body },
    };
    return node;
}

/// `( parameters )`
fn parameterList(this: *Parser) Error![]const ast.Parameter {
    _ = try this.expect(.l_paren);
    var parameters: std.ArrayList(ast.Parameter) = .empty;
    while (this.current().tag != .r_paren) {
        const first = this.current();
        const rest = this.eat(.ellipsis);
        const name = this.current();
        var pattern: ?*const ast.Pattern = null;
        switch (name.tag) {
            .identifier => _ = this.advance(),
            .kw_this => return this.unsupported(name.start, "'this' parameters are", .{}),
            .l_bracket, .l_brace => pattern = try this.bindingPattern(),
            else => if (name.tag.isKeyword()) {
                return this.fail(name.start, .ts(1390), "'{s}' is not allowed as a parameter name.", .{this.tokenText(name)});
            } else {
                return this.fail(name.start, .ts(1138), "Parameter declaration expected.", .{});
            },
        }
        const name_text = if (pattern != null) this.source.text[name.start..this.previousEnd()] else this.tokenText(name);
        var span_start: ?u32 = null;
        const question = this.current();
        const optional = this.eat(.question);
        if (optional) {
            span_start = question.start;
        }
        var annotation: ?*const ast.TypeNode = null;
        if (this.current().tag == .colon) {
            const colon = this.advance();
            annotation = try this.typeAnnotation(span_start orelse colon.start);
        } else if (span_start) |at| {
            try this.type_spans.append(this.arena, .{ .start = at, .end = this.previousEnd() });
        }
        var init: ?*Expr = null;
        if (this.current().tag == .equal) {
            const equal = this.advance();
            if (rest) {
                try this.report(equal.start, .ts(1048), "A rest parameter cannot have an initializer.", .{});
            } else if (optional) {
                try this.report(name.start, .ts(1015), "Parameter cannot have question mark and initializer.", .{});
            }
            init = try this.assignment();
            if (pattern == null) {
                nameFunction(init.?, name_text);
            }
        }
        if (rest and optional) {
            try this.report(question.start, .ts(1047), "A rest parameter cannot be optional.", .{});
        }
        try parameters.append(this.arena, .{
            .name = name_text,
            .start = name.start,
            .node_start = first.start,
            .end = this.previousEnd(),
            .binding = if (pattern == null) this.newBinding() else 0,
            .pattern = pattern,
            .type = annotation,
            .init = init,
            .optional = optional,
            .rest = rest,
        });
        if (!this.eat(.comma)) {
            break;
        }
        if (rest) {
            if (this.current().tag == .r_paren) {
                try this.report(first.start, .ts(1013), "A rest parameter or binding pattern may not have a trailing comma.", .{});
            } else {
                try this.report(first.start, .ts(1014), "A rest parameter must be last in a parameter list.", .{});
            }
        }
    }
    _ = try this.expect(.r_paren);
    return parameters.toOwnedSlice(this.arena);
}

/// An arrow function at the current token, or null (having consumed nothing) if there isn't one.
fn arrowFunction(this: *Parser) Error!?*Expr {
    const tok = this.current();
    switch (tok.tag) {
        .identifier => {
            const next = this.peekToken(1);
            if (this.isContextual(tok, "async") and !next.newline_before) {
                switch (next.tag) {
                    .kw_function, .identifier => return this.unsupported(tok.start, "Async functions are", .{}),
                    .l_paren => {
                        // `async (x) => ...` rather than a call to something named `async`.
                        const m = this.mark();
                        _ = this.advance();
                        const is_arrow = if (this.skipParens()) this.current().tag == .arrow or this.current().tag == .colon else false;
                        this.reset(m);
                        if (is_arrow) {
                            return this.unsupported(tok.start, "Async functions are", .{});
                        }
                    },
                    else => {},
                }
            }
            if (next.tag != .arrow) {
                return null;
            }
            _ = this.advance();
            const parameters = try this.arena.alloc(ast.Parameter, 1);
            parameters[0] = .{
                .name = this.tokenText(tok),
                .start = tok.start,
                .node_start = tok.start,
                .end = tok.end,
                .binding = this.newBinding(),
                .type = null,
                .init = null,
                .optional = false,
                .rest = false,
            };
            const function_id = this.newFunction();
            return try this.arrowBody(tok.start, function_id, this.newScope(), parameters, .{ .parameters = parameters, .returns = null, .returns_start = 0 });
        },
        .l_paren => {
            // Parse the head speculatively: `(a, b)` is only a parameter list if `=>` follows.
            const m = this.mark();
            const function_id = this.newFunction();
            const scope = this.newScope();
            const head = this.arrowHead() catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Syntax => {
                    this.reset(m);
                    return null;
                },
            } orelse {
                this.reset(m);
                return null;
            };
            return try this.arrowBody(tok.start, function_id, scope, head.parameters, head);
        },
        .less => {
            // `<T>(x: T) => x`, which in a `.ts` file can't be anything else.
            const m = this.mark();
            const function_id = this.newFunction();
            const scope = this.newScope();
            const head = this.genericArrowHead() catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Syntax => {
                    this.reset(m);
                    return null;
                },
            } orelse {
                this.reset(m);
                return null;
            };
            return try this.arrowBody(tok.start, function_id, scope, head.parameters, head);
        },
        else => return null,
    }
}

fn genericArrowHead(this: *Parser) Error!?ArrowHead {
    const type_parameters = try this.genericParameters(true);
    if (this.current().tag != .l_paren) {
        return null;
    }
    const start = this.current().start;
    var head = try this.arrowHead() orelse return null;
    head.type_parameters = type_parameters;
    head.source_start = start;
    return head;
}

const ArrowHead = struct {
    type_parameters: []const ast.GenericParameter = &.{},
    /// Where the function's source text starts, for a generic arrow, whose type parameters node
    /// blanks out: its `(`.
    source_start: ?u32 = null,
    parameters: []const ast.Parameter,
    returns: ?*const ast.TypeNode,
    returns_start: u32,
};

/// `(parameters): type` followed by `=>`, or null if what's there isn't that.
fn arrowHead(this: *Parser) Error!?ArrowHead {
    const parameters = try this.parameterList();
    var returns: ?*const ast.TypeNode = null;
    var returns_start: u32 = 0;
    if (this.current().tag == .colon) {
        const colon = this.advance();
        returns_start = this.current().start;
        returns = try this.returnAnnotation(colon.start);
    }
    if (this.current().tag != .arrow) {
        return null;
    }
    return .{ .parameters = parameters, .returns = returns, .returns_start = returns_start };
}

/// Skips a balanced `( ... )` starting at the current token. False if it isn't closed.
fn skipParens(this: *Parser) bool {
    var depth: usize = 0;
    while (true) {
        const tok = this.advance();
        switch (tok.tag) {
            .l_paren => depth += 1,
            .r_paren => {
                depth -= 1;
                if (depth == 0) {
                    return true;
                }
            },
            .eof => return false,
            else => {},
        }
    }
}

/// An arrow function from its `=>` on.
fn arrowBody(this: *Parser, start: u32, function_id: u32, scope: u32, parameters: []const ast.Parameter, head: ArrowHead) Error!*Expr {
    const arrow = this.advance();
    if (arrow.newline_before) {
        try this.report(arrow.start, .ts(1200), "Line terminator not permitted before arrow.", .{});
    }
    const body: ast.Function.Body = if (this.current().tag == .l_brace)
        .{ .block = try this.block() }
    else
        .{ .expression = try this.assignment() };
    const node = try this.arena.create(ast.Function);
    node.* = .{
        .kind = .arrow,
        .id = function_id,
        .start = head.source_start orelse start,
        .end = this.previousEnd(),
        .name = null,
        .type_parameters = head.type_parameters,
        .parameters = parameters,
        .scope = scope,
        .returns = head.returns,
        .returns_start = head.returns_start,
        .body = body,
    };
    return this.newExpr(start, .{ .function = node });
}

/// NamedEvaluation (ECMA-262 §8.4.5): an anonymous function assigned straight to a name takes
/// that name.
fn nameFunction(value: *Expr, name: []const u8) void {
    var e = value;
    while (e.data == .paren) {
        e = e.data.paren;
    }
    if (e.data == .function and e.data.function.inferred_name.len == 0) {
        e.data.function.inferred_name = name;
    }
}

// Destructuring

/// A name, or an object or array pattern, in a declaration or parameter.
fn bindingPattern(this: *Parser) Error!*const ast.Pattern {
    const tok = this.current();
    const pattern = try this.arena.create(ast.Pattern);
    pattern.start = tok.start;
    switch (tok.tag) {
        .identifier => {
            _ = this.advance();
            pattern.data = .{ .identifier = .{ .name = this.tokenText(tok), .start = tok.start, .binding = this.newBinding() } };
        },
        .l_brace => pattern.data = .{ .object = try this.objectPattern() },
        .l_bracket => pattern.data = .{ .array = try this.arrayPattern() },
        else => if (tok.tag.isKeyword()) {
            return this.fail(tok.start, .ts(1389), "'{s}' is not allowed as a variable declaration name.", .{this.tokenText(tok)});
        } else {
            return this.fail(tok.start, .ts(1003), "Identifier expected.", .{});
        },
    }
    return pattern;
}

/// After a rest element: the pattern has to close.
fn endRest(this: *Parser, at: u32, close: Tag) Error!void {
    if (this.current().tag == .comma) {
        if (this.peekToken(1).tag == close) {
            return this.fail(at, .ts(1013), "A rest parameter or binding pattern may not have a trailing comma.", .{});
        }
        return this.fail(at, .ts(2462), "A rest element must be last in a destructuring pattern.", .{});
    }
}

fn objectPattern(this: *Parser) Error!ast.ObjectPattern {
    _ = this.advance();
    var properties: std.ArrayList(ast.PatternProperty) = .empty;
    var rest: ?ast.Binding = null;
    while (this.current().tag != .r_brace) {
        const tok = this.current();
        if (this.eat(.ellipsis)) {
            const name = this.current();
            if (name.tag != .identifier) {
                return this.fail(name.start, .ts(1003), "Identifier expected.", .{});
            }
            _ = this.advance();
            rest = .{ .name = this.tokenText(name), .start = name.start, .binding = this.newBinding() };
            try this.endRest(tok.start, .r_brace);
            break;
        }
        const key: []const u8 = switch (tok.tag) {
            .identifier => this.tokenText(tok),
            .string => try Lexer.cook(this.arena, this.source.text, tok),
            .number => try number.toString(this.arena, number.parseLiteral(this.tokenText(tok))),
            .l_bracket => return this.unsupported(tok.start, "Computed property names in destructuring are", .{}),
            else => if (tok.tag.isKeyword()) this.tokenText(tok) else return this.fail(tok.start, .ts(1003), "Identifier expected.", .{}),
        };
        _ = this.advance();
        var value: *const ast.Pattern = undefined;
        if (this.eat(.colon)) {
            value = try this.bindingPattern();
        } else {
            if (tok.tag != .identifier) {
                return this.fail(this.current().start, .ts(1005), "':' expected.", .{});
            }
            const p = try this.arena.create(ast.Pattern);
            p.* = .{ .start = tok.start, .data = .{ .identifier = .{ .name = key, .start = tok.start, .binding = this.newBinding() } } };
            value = p;
        }
        const init = if (this.eat(.equal)) try this.assignment() else null;
        if (init) |e| {
            if (value.data == .identifier) {
                nameFunction(e, value.data.identifier.name);
            }
        }
        try properties.append(this.arena, .{ .key = key, .key_start = tok.start, .value = value, .init = init });
        if (!this.eat(.comma)) {
            break;
        }
    }
    _ = try this.expect(.r_brace);
    return .{ .properties = properties.items, .rest = rest };
}

fn arrayPattern(this: *Parser) Error!ast.ArrayPattern {
    _ = this.advance();
    var elements: std.ArrayList(?ast.PatternElement) = .empty;
    var rest: ?*const ast.Pattern = null;
    while (this.current().tag != .r_bracket) {
        const tok = this.current();
        if (tok.tag == .comma) {
            _ = this.advance();
            try elements.append(this.arena, null);
            continue;
        }
        if (this.eat(.ellipsis)) {
            rest = try this.bindingPattern();
            try this.endRest(tok.start, .r_bracket);
            break;
        }
        const pattern = try this.bindingPattern();
        const init = if (this.eat(.equal)) try this.assignment() else null;
        if (init) |e| {
            if (pattern.data == .identifier) {
                nameFunction(e, pattern.data.identifier.name);
            }
        }
        try elements.append(this.arena, .{ .pattern = pattern, .init = init });
        if (!this.eat(.comma)) {
            break;
        }
    }
    _ = try this.expect(.r_bracket);
    return .{ .elements = elements.items, .rest = rest };
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
    if (try this.arrowFunction()) |arrow| {
        return arrow;
    }
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
        .arrow => return this.fail(tok.start, .ts(1005), "';' expected.", .{}),
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
    const plain = target.data == .identifier and (op == null or op.?.isLogical());
    if (plain) {
        nameFunction(value, target.data.identifier.name);
    }
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

const relational_precedence = 8;

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
        .kw_in => .{ .op = .in, .precedence = 8 },
        .kw_instanceof => .{ .op = .instanceof, .precedence = 8 },
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
        // `as` and `satisfies` bind like the relational operators.
        if ((this.isContextual(tok, "as") or this.isContextual(tok, "satisfies")) and !tok.newline_before) {
            if (relational_precedence <= min_precedence) {
                return left;
            }
            _ = this.advance();
            const is_as = this.isContextual(tok, "as");
            var annotation: ?*const ast.TypeNode = null;
            if (is_as and this.current().tag == .kw_const) {
                _ = this.advance();
            } else {
                annotation = try this.typeNode();
            }
            try this.type_spans.append(this.arena, .{ .start = tok.start, .end = this.previousEnd() });
            left = try this.newExpr(left.start, .{ .assertion = .{ .kind = if (is_as) .as else .satisfies, .expr = left, .type = annotation, .keyword_start = tok.start } });
            continue;
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
        .kw_delete => .delete,
        .kw_await => return this.unsupported(tok.start, "'{s}' expressions are", .{this.tokenText(tok)}),
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
    const start = this.current().start;
    var expr = try this.primary();
    // Whether the expression so far is part of an optional chain.
    var chain = false;
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
            .less => {
                const type_arguments = try this.callTypeArguments() orelse break;
                _ = this.advance();
                const args = try this.arguments();
                expr = try this.newExpr(expr.start, .{ .call = .{ .callee = expr, .type_arguments = type_arguments, .arguments = args } });
            },
            .l_bracket => {
                _ = this.advance();
                const saved_no_in = this.no_in;
                this.no_in = false;
                defer this.no_in = saved_no_in;
                if (this.current().tag == .r_bracket) {
                    return this.fail(this.current().start, .ts(1011), "An element access expression should take an argument.", .{});
                }
                const index = try this.expression();
                _ = try this.expect(.r_bracket);
                expr = try this.newExpr(expr.start, .{ .index = .{ .object = expr, .index = index } });
            },
            .question_dot => {
                _ = this.advance();
                chain = true;
                const next = this.current();
                switch (next.tag) {
                    .l_paren => {
                        _ = this.advance();
                        const args = try this.arguments();
                        expr = try this.newExpr(expr.start, .{ .call = .{ .callee = expr, .arguments = args, .optional = true } });
                    },
                    .l_bracket => {
                        _ = this.advance();
                        const saved_no_in = this.no_in;
                        this.no_in = false;
                        defer this.no_in = saved_no_in;
                        const index = try this.expression();
                        _ = try this.expect(.r_bracket);
                        expr = try this.newExpr(expr.start, .{ .index = .{ .object = expr, .index = index, .optional = true } });
                    },
                    .private_name => return this.unsupported(next.start, "Private names are", .{}),
                    .template_full, .template_head => return this.fail(next.start, .ts(1358), "Tagged template expressions are not permitted in an optional chain.", .{}),
                    else => {
                        if (next.tag != .identifier and !next.tag.isKeyword()) {
                            return this.fail(next.start, .ts(1003), "Identifier expected.", .{});
                        }
                        _ = this.advance();
                        expr = try this.newExpr(expr.start, .{ .member = .{ .object = expr, .property = this.tokenText(next), .property_start = next.start, .optional = true } });
                    },
                }
            },
            .template_full, .template_head => {
                if (chain) {
                    return this.fail(tok.start, .ts(1358), "Tagged template expressions are not permitted in an optional chain.", .{});
                }
                return this.unsupported(tok.start, "Tagged templates are", .{});
            },
            .bang => {
                if (tok.newline_before) {
                    break;
                }
                _ = this.advance();
                try this.type_spans.append(this.arena, .{ .start = tok.start, .end = tok.end });
                expr = try this.newExpr(expr.start, .{ .non_null = expr });
            },
            else => break,
        }
    }
    if (chain) {
        // A `!` at the end applies to the whole chain, short-circuit included; one inside it
        // (`a?.b!.c`) doesn't.
        var bangs: usize = 0;
        while (expr.data == .non_null) : (bangs += 1) {
            expr = expr.data.non_null;
        }
        expr = try this.newExpr(start, .{ .chain = expr });
        for (0..bangs) |_| {
            expr = try this.newExpr(start, .{ .non_null = expr });
        }
    }
    const tok = this.current();
    // `a\n++b` is `a; ++b`.
    if ((tok.tag == .plus_plus or tok.tag == .minus_minus) and !tok.newline_before) {
        _ = this.advance();
        return this.newExpr(expr.start, .{ .update = .{ .increment = tok.tag == .plus_plus, .prefix = false, .operand = expr } });
    }
    return expr;
}

/// The arguments of a call, after the `(`.
fn arguments(this: *Parser) Error![]const *Expr {
    const saved_no_in = this.no_in;
    this.no_in = false;
    defer this.no_in = saved_no_in;
    var args: std.ArrayList(*Expr) = .empty;
    while (this.current().tag != .r_paren) {
        switch (this.current().tag) {
            .ellipsis => {
                const start = this.advance().start;
                try args.append(this.arena, try this.newExpr(start, .{ .spread = try this.assignment() }));
                if (!this.eat(.comma)) {
                    break;
                }
                continue;
            },
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
            const ref = this.reference_count;
            this.reference_count += 1;
            return this.newExpr(tok.start, .{ .identifier = .{ .name = this.tokenText(tok), .ref = ref } });
        },
        .l_paren => {
            _ = this.advance();
            const saved_no_in = this.no_in;
            this.no_in = false;
            defer this.no_in = saved_no_in;
            const inner = try this.expression();
            _ = try this.expect(.r_paren);
            return this.newExpr(tok.start, .{ .paren = inner });
        },
        .bigint => return this.unsupported(tok.start, "BigInt literals are", .{}),
        .l_bracket => return this.arrayLiteral(),
        .l_brace => return this.objectLiteral(),
        .kw_function => {
            _ = this.advance();
            return this.newExpr(tok.start, .{ .function = try this.function(.expression, tok.start) });
        },
        .kw_class => return this.unsupported(tok.start, "Class expressions are", .{}),
        .kw_new => return this.newExpression(),
        .kw_this => return this.unsupported(tok.start, "'this' is", .{}),
        .kw_super => return this.unsupported(tok.start, "'super' is", .{}),
        .kw_import => return this.unsupported(tok.start, "Dynamic import is", .{}),
        .slash, .slash_equal => return this.unsupported(tok.start, "Regular expressions are", .{}),
        .invalid => return error.Syntax, // already reported by the lexer
        else => return this.fail(tok.start, .ts(1109), "Expression expected.", .{}),
    }
}

/// `new C(arguments)`, `new C<T>(arguments)` or `new C`. What's constructed is a member expression
/// without calls: `new a.b()` constructs `a.b`.
fn newExpression(this: *Parser) Error!*Expr {
    const start = this.advance().start;
    if (this.current().tag == .dot) {
        return this.unsupported(start, "'new.target' is", .{});
    }
    var callee = if (this.current().tag == .kw_new) try this.newExpression() else try this.primary();
    while (true) {
        const tok = this.current();
        switch (tok.tag) {
            .dot => {
                _ = this.advance();
                const name = this.current();
                if (name.tag != .identifier and !name.tag.isKeyword()) {
                    return this.fail(name.start, .ts(1003), "Identifier expected.", .{});
                }
                _ = this.advance();
                callee = try this.newExpr(callee.start, .{ .member = .{ .object = callee, .property = this.tokenText(name), .property_start = name.start } });
            },
            .l_bracket => {
                _ = this.advance();
                const index = try this.expression();
                _ = try this.expect(.r_bracket);
                callee = try this.newExpr(callee.start, .{ .index = .{ .object = callee, .index = index } });
            },
            .question_dot => return this.fail(tok.start, .ts(1209), "Invalid optional chain from new expression. Did you mean to call '{s}()'?", .{this.source.text[callee.start..this.previousEnd()]}),
            else => break,
        }
    }
    var type_arguments: []const *const ast.TypeNode = &.{};
    if (this.current().tag == .less) {
        type_arguments = try this.callTypeArguments() orelse &.{};
    }
    var args: []const *Expr = &.{};
    if (this.eat(.l_paren)) {
        args = try this.arguments();
    }
    return this.newExpr(start, .{ .new = .{ .callee = callee, .type_arguments = type_arguments, .arguments = args } });
}

fn arrayLiteral(this: *Parser) Error!*Expr {
    const start = this.advance().start;
    const saved_no_in = this.no_in;
    this.no_in = false;
    defer this.no_in = saved_no_in;
    var elements: std.ArrayList(ast.ArrayElement) = .empty;
    while (this.current().tag != .r_bracket) {
        if (this.current().tag == .comma) {
            return this.unsupported(this.current().start, "Holes in array literals are", .{});
        }
        if (this.eat(.ellipsis)) {
            try elements.append(this.arena, .{ .spread = try this.assignment() });
        } else {
            try elements.append(this.arena, .{ .expr = try this.assignment() });
        }
        if (!this.eat(.comma)) {
            break;
        }
    }
    _ = try this.expect(.r_bracket);
    return this.newExpr(start, .{ .array = .{ .elements = elements.items } });
}

fn objectLiteral(this: *Parser) Error!*Expr {
    const start = this.advance().start;
    const saved_no_in = this.no_in;
    this.no_in = false;
    defer this.no_in = saved_no_in;
    var properties: std.ArrayList(ast.ObjectProperty) = .empty;
    while (this.current().tag != .r_brace) {
        const tok = this.current();
        if (this.eat(.ellipsis)) {
            try properties.append(this.arena, .{ .spread = .{ .start = tok.start, .expr = try this.assignment() } });
        } else {
            try properties.append(this.arena, try this.objectProperty());
        }
        if (!this.eat(.comma)) {
            break;
        }
    }
    _ = try this.expect(.r_brace);
    return this.newExpr(start, .{ .object = .{ .properties = properties.items } });
}

fn objectProperty(this: *Parser) Error!ast.ObjectProperty {
    const tok = this.current();
    const next = this.peekToken(1);
    if (tok.tag == .star) {
        return this.unsupported(tok.start, "Generator methods are", .{});
    }
    if ((this.isContextual(tok, "get") or this.isContextual(tok, "set")) and startsPropertyName(next.tag)) {
        return this.unsupported(tok.start, "Getters and setters are", .{});
    }
    if (this.isContextual(tok, "async") and !next.newline_before and (startsPropertyName(next.tag) or next.tag == .star)) {
        return this.unsupported(tok.start, "Async methods are", .{});
    }
    const key: ast.PropertyKey = switch (tok.tag) {
        .identifier => .{ .name = this.tokenText(tok) },
        .string => .{ .name = try Lexer.cook(this.arena, this.source.text, tok) },
        .number => .{ .name = try number.toString(this.arena, number.parseLiteral(this.tokenText(tok))) },
        .bigint => return this.unsupported(tok.start, "BigInt literals are", .{}),
        .l_bracket => blk: {
            _ = this.advance();
            const e = try this.assignment();
            if (this.current().tag != .r_bracket) {
                return this.fail(this.current().start, .ts(1005), "']' expected.", .{});
            }
            break :blk .{ .computed = e };
        },
        else => if (tok.tag.isKeyword()) .{ .name = this.tokenText(tok) } else return this.fail(tok.start, .ts(1136), "Property assignment expected.", .{}),
    };
    _ = this.advance();
    switch (this.current().tag) {
        .colon => {
            _ = this.advance();
            const value = try this.assignment();
            if (key == .name) {
                nameFunction(value, key.name);
            }
            return .{ .property = .{ .key = key, .key_start = tok.start, .value = value } };
        },
        .l_paren, .less => {
            const f = try this.function(.expression, tok.start);
            f.method = true;
            if (key == .name) {
                f.inferred_name = key.name;
            }
            const value = try this.newExpr(tok.start, .{ .function = f });
            return .{ .property = .{ .key = key, .key_start = tok.start, .value = value, .method = true } };
        },
        .equal => return this.fail(this.current().start, .ts(1312), "Did you mean to use a ':'? An '=' can only follow a property name when the containing object literal is part of a destructuring pattern.", .{}),
        else => {
            if (tok.tag != .identifier) {
                return this.fail(this.current().start, .ts(1005), "':' expected.", .{});
            }
            const ref = this.reference_count;
            this.reference_count += 1;
            const value = try this.newExpr(tok.start, .{ .identifier = .{ .name = key.name, .ref = ref } });
            return .{ .property = .{ .key = key, .key_start = tok.start, .value = value } };
        },
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
        .new => |n| {
            try writer.writeAll("(new ");
            try sexpr(writer, n.callee);
            for (n.arguments) |a| {
                try writer.writeAll(" ");
                try sexpr(writer, a);
            }
            try writer.writeAll(")");
        },
        .spread => |inner| {
            try writer.writeAll("...");
            try sexpr(writer, inner);
        },
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
            try writer.writeAll(if (m.optional) "(?. " else "(. ");
            try sexpr(writer, m.object);
            try writer.print(" {s})", .{m.property});
        },
        .chain => |inner| {
            try writer.writeAll("(chain ");
            try sexpr(writer, inner);
            try writer.writeAll(")");
        },
        .non_null => |inner| {
            try writer.writeAll("(! ");
            try sexpr(writer, inner);
            try writer.writeAll(")");
        },
        .assertion => |a| {
            try writer.print("({t} ", .{a.kind});
            try sexpr(writer, a.expr);
            try writer.writeAll(" ");
            if (a.type) |t| {
                try renderType(writer, t);
            } else {
                try writer.writeAll("const");
            }
            try writer.writeAll(")");
        },
        .call => |c| {
            try writer.writeAll(if (c.optional) "(?.call " else "(call ");
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
        .function => |f| try renderFunction(writer, f),
        .index => |i| {
            try writer.writeAll(if (i.optional) "(?.index " else "(index ");
            try sexpr(writer, i.object);
            try writer.writeAll(" ");
            try sexpr(writer, i.index);
            try writer.writeAll(")");
        },
        .array => |a| {
            try writer.writeAll("(array");
            for (a.elements) |e| {
                try writer.writeAll(" ");
                switch (e) {
                    .expr => |x| try sexpr(writer, x),
                    .spread => |x| {
                        try writer.writeAll("...");
                        try sexpr(writer, x);
                    },
                }
            }
            try writer.writeAll(")");
        },
        .object => |o| {
            try writer.writeAll("(object");
            for (o.properties) |p| {
                try writer.writeAll(" ");
                switch (p) {
                    .property => |prop| {
                        switch (prop.key) {
                            .name => |n| try writer.writeAll(n),
                            .computed => |c| {
                                try writer.writeAll("[");
                                try sexpr(writer, c);
                                try writer.writeAll("]");
                            },
                        }
                        try writer.writeAll(":");
                        try sexpr(writer, prop.value);
                    },
                    .spread => |x| {
                        try writer.writeAll("...");
                        try sexpr(writer, x.expr);
                    },
                }
            }
            try writer.writeAll(")");
        },
    }
}

fn renderPattern(writer: *std.Io.Writer, p: *const ast.Pattern) std.Io.Writer.Error!void {
    switch (p.data) {
        .identifier => |b| try writer.print("{s}#{d}", .{ b.name, b.binding }),
        .object => |o| {
            try writer.writeAll("{");
            for (o.properties, 0..) |prop, i| {
                try writer.print("{s}{s}: ", .{ if (i > 0) " " else "", prop.key });
                try renderPattern(writer, prop.value);
                if (prop.init) |init| {
                    try writer.writeAll(" = ");
                    try sexpr(writer, init);
                }
            }
            if (o.rest) |r| {
                try writer.print("{s}...{s}#{d}", .{ if (o.properties.len > 0) " " else "", r.name, r.binding });
            }
            try writer.writeAll("}");
        },
        .array => |a| {
            try writer.writeAll("[");
            for (a.elements, 0..) |element, i| {
                if (i > 0) {
                    try writer.writeAll(" ");
                }
                const e = element orelse {
                    try writer.writeAll("_");
                    continue;
                };
                try renderPattern(writer, e.pattern);
                if (e.init) |init| {
                    try writer.writeAll(" = ");
                    try sexpr(writer, init);
                }
            }
            if (a.rest) |r| {
                try writer.writeAll(if (a.elements.len > 0) " ..." else "...");
                try renderPattern(writer, r);
            }
            try writer.writeAll("]");
        },
    }
}

/// `(fn name#id (a#0: number b#1 = 1 ...c#2) : number body)`
fn renderFunction(writer: *std.Io.Writer, f: *const ast.Function) std.Io.Writer.Error!void {
    try writer.print("({s}", .{switch (f.kind) {
        .declaration, .expression => "fn",
        .arrow => "=>",
    }});
    if (f.name) |n| {
        try writer.print(" {s}#{d}", .{ n.text, n.binding });
    }
    try writer.writeAll(" (");
    for (f.parameters, 0..) |p, i| {
        if (i > 0) {
            try writer.writeAll(" ");
        }
        if (p.pattern) |pattern| {
            try writer.writeAll(if (p.rest) "..." else "");
            try renderPattern(writer, pattern);
        } else {
            try writer.print("{s}{s}#{d}{s}", .{ if (p.rest) "..." else "", p.name, p.binding, if (p.optional) "?" else "" });
        }
        if (p.type) |t| {
            try writer.writeAll(": ");
            try renderType(writer, t);
        }
        if (p.init) |init| {
            try writer.writeAll(" = ");
            try sexpr(writer, init);
        }
    }
    try writer.writeAll(")");
    if (f.returns) |t| {
        try writer.writeAll(": ");
        try renderType(writer, t);
    }
    try writer.writeAll(" ");
    switch (f.body) {
        .block => |b| try renderStmt(writer, &.{ .start = 0, .end = 0, .data = .{ .block = b } }),
        .expression => |e| try sexpr(writer, e),
    }
    try writer.writeAll(")");
}

fn renderType(writer: *std.Io.Writer, t: *const ast.TypeNode) std.Io.Writer.Error!void {
    switch (t.data) {
        .intersection => |ms| for (ms, 0..) |m, i| {
            if (i > 0) {
                try writer.writeAll(" & ");
            }
            try renderType(writer, m);
        },
        .predicate => |p| {
            try writer.print("{s} is ", .{p.parameter});
            try renderType(writer, p.type);
        },
        .keyword => |k| try writer.print("{t}", .{k}),
        .reference => |r| {
            try writer.writeAll(r.name);
            if (r.arguments.len > 0) {
                try writer.writeAll("<");
                for (r.arguments, 0..) |a, i| {
                    if (i > 0) {
                        try writer.writeAll(", ");
                    }
                    try renderType(writer, a);
                }
                try writer.writeAll(">");
            }
        },
        .keyof => |operand| {
            try writer.writeAll("keyof ");
            try renderType(writer, operand);
        },
        .readonly => |operand| {
            try writer.writeAll("readonly ");
            try renderType(writer, operand);
        },
        .indexed => |i| {
            try renderType(writer, i.object);
            try writer.writeAll("[");
            try renderType(writer, i.index);
            try writer.writeAll("]");
        },
        .query => |q| {
            try writer.print("typeof {s}", .{q.name});
            for (q.path) |p| {
                try writer.print(".{s}", .{p});
            }
        },
        .mapped => |m| {
            try writer.print("{{ [{s} in ", .{m.parameter.name});
            try renderType(writer, m.constraint);
            try writer.writeAll("]: ");
            if (m.type) |mt| {
                try renderType(writer, mt);
            }
            try writer.writeAll(" }");
        },
        .literal => |l| switch (l) {
            .number => |n| try number.format(writer, n),
            .string => |str| try writer.print("\"{s}\"", .{str}),
            .boolean => |b| try writer.writeAll(if (b) "true" else "false"),
        },
        .@"union" => |ms| for (ms, 0..) |m, i| {
            if (i > 0) {
                try writer.writeAll(" | ");
            }
            try renderType(writer, m);
        },
        .array => |element| {
            try renderType(writer, element);
            try writer.writeAll("[]");
        },
        .function => |f| {
            try writer.writeAll("(");
            for (f.parameters, 0..) |p, i| {
                if (i > 0) {
                    try writer.writeAll(", ");
                }
                try writer.print("{s}{s}{s}", .{ if (p.rest) "..." else "", p.name, if (p.optional) "?" else "" });
                if (p.type) |pt| {
                    try writer.writeAll(": ");
                    try renderType(writer, pt);
                }
            }
            try writer.writeAll(") => ");
            if (f.returns) |r| {
                try renderType(writer, r);
            }
        },
        .tuple => |elements| {
            try writer.writeAll("[");
            for (elements, 0..) |e, i| {
                if (i > 0) {
                    try writer.writeAll(", ");
                }
                try renderType(writer, e);
            }
            try writer.writeAll("]");
        },
        .object => |members| try renderMembers(writer, members),
    }
}

fn renderMembers(writer: *std.Io.Writer, members: []const ast.TypeMember) std.Io.Writer.Error!void {
    try writer.writeAll("{");
    for (members) |m| {
        switch (m.signature) {
            .none => {},
            .call, .construct => {
                try writer.writeAll(if (m.signature == .call) " " else " new ");
                try renderType(writer, m.type.?);
                try writer.writeAll(";");
                continue;
            },
            .index => |key| {
                try writer.print(" {s}[{s}: ", .{ if (m.readonly) "readonly " else "", m.name });
                try renderType(writer, key);
                try writer.writeAll("]: ");
                try renderType(writer, m.type.?);
                try writer.writeAll(";");
                continue;
            },
        }
        try writer.print(" {s}{s}{s}", .{ if (m.readonly) "readonly " else "", m.name, if (m.optional) "?" else "" });
        if (m.type) |t| {
            try writer.writeAll(if (m.method) "" else ": ");
            try renderType(writer, t);
        }
        try writer.writeAll(";");
    }
    try writer.writeAll(" }");
}

/// Renders a statement on one line, with expressions as `sexpr` does.
fn renderStmt(writer: *std.Io.Writer, stmt: *const Stmt) std.Io.Writer.Error!void {
    switch (stmt.data) {
        .expression => |e| try sexpr(writer, e),
        .empty => try writer.writeAll(";"),
        .variable => |v| {
            try writer.writeAll(@tagName(v.kind));
            for (v.declarators) |d| {
                if (d.pattern) |p| {
                    try writer.writeAll(" ");
                    try renderPattern(writer, p);
                } else {
                    try writer.print(" {s}#{d}", .{ d.name, d.binding });
                }
                if (d.type) |t| {
                    try writer.writeAll(": ");
                    try renderType(writer, t);
                }
                if (d.init) |init| {
                    try writer.writeAll(" = ");
                    try sexpr(writer, init);
                }
            }
        },
        .function => |f| try renderFunction(writer, f),
        .@"return" => |value| {
            try writer.writeAll("return");
            if (value) |v| {
                try writer.writeAll(" ");
                try sexpr(writer, v);
            }
        },
        .block => |b| {
            try writer.writeAll("{");
            for (b.statements) |s| {
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
        .for_each => |f| {
            try writer.writeAll("for (");
            switch (f.head) {
                .declaration => |d| {
                    try writer.print("{t} ", .{d.kind});
                    try renderPattern(writer, d.pattern);
                },
                .target => |e| try sexpr(writer, e),
            }
            try writer.writeAll(if (f.of) " of " else " in ");
            try sexpr(writer, f.right);
            try writer.writeAll(") ");
            try renderStmt(writer, f.body);
        },
        .interface => |i| {
            try writer.print("interface {s}", .{i.name});
            for (i.extends, 0..) |e, n| {
                try writer.print("{s}{s}", .{ if (n == 0) " extends " else ", ", e.name });
            }
            try writer.writeAll(" ");
            try renderMembers(writer, i.members);
        },
        .type_alias => |a| {
            try writer.print("type {s} = ", .{a.name});
            try renderType(writer, a.type);
        },
        .declare => |d| {
            try writer.print("declare {s} {s}: ", .{ if (d.function) "function" else "var", d.name });
            try renderType(writer, d.type);
        },
        .throw => |e| {
            try writer.writeAll("throw ");
            try sexpr(writer, e);
        },
        .@"try" => |t| {
            try writer.writeAll("try ");
            try renderStmt(writer, &.{ .start = 0, .end = 0, .data = .{ .block = t.block } });
            if (t.handler) |h| {
                try writer.writeAll(" catch ");
                if (h.parameter) |p| {
                    try writer.writeAll("(");
                    try renderPattern(writer, p);
                    if (h.type) |annotation| {
                        try writer.writeAll(": ");
                        try renderType(writer, annotation);
                    }
                    try writer.writeAll(") ");
                }
                try renderStmt(writer, &.{ .start = 0, .end = 0, .data = .{ .block = h.block } });
            }
            if (t.finalizer) |f| {
                try writer.writeAll(" finally ");
                try renderStmt(writer, &.{ .start = 0, .end = 0, .data = .{ .block = f } });
            }
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

test "optional chains and assertions" {
    try expectParse("a?.b.c", "(chain (. (?. a b) c))\n");
    try expectParse("a?.[0]?.(1)", "(chain (?.call (?.index a 0) 1))\n");
    try expectParse("(a?.b).c", "(. [(chain (?. a b))] c)\n");
    try expectParse("a?.b!.c", "(chain (. (! (?. a b)) c))\n");
    try expectParse("a?.b!", "(! (chain (?. a b)))\n");
    try expectParse("a!++", "((! a) ++)\n");
    try expectParse("a!\nb", "(! a)\nb\n");
    try expectParse("a\n!b", "a\n(! b)\n");
    try expectParse("x ? .5 : 1", "(? x 0.5 1)\n");
    try expectParse("a + b as T", "(as (+ a b) T)\n");
    try expectParse("a < b as T", "(as (< a b) T)\n");
    try expectParse("a as const satisfies T as U", "(as (satisfies (as a const) T) U)\n");
    try expectParse("a\nas", "a\nas\n");
    try expectErrors("a?.`x`", &.{1358});
    try expectParse("throw a + 1", "throw (+ a 1)\n");
    try expectErrors("throw\na", &.{1142});
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

test "try statements" {
    try expectParse("try { a } catch (e) { b } finally { c }", "try { a } catch (e#0) { b } finally { c }\n");
    try expectParse("try { a } catch { b }", "try { a } catch { b }\n");
    try expectParse("try { a } catch ({ message }: any) { b }", "try { a } catch ({message: message#0}: any) { b }\n");
    try expectParse("try {} finally {}", "try { } finally { }\n");
    try expectParse("a instanceof b && c", "(&& (instanceof a b) c)\n");
    try expectErrors("try {}", &.{1472});
    try expectErrors("try {} catch (e = 1) {}", &.{1197});
}

test "unsupported syntax is reported and skipped" {
    try expectErrors("var x = 1", &.{9001});
    try expectErrors("let a: number & string", &.{9001});
    try expectErrors("let a: typeof this", &.{9001});
    try expectErrors("[1, , 2]", &.{9001});
    try expectErrors("({ get a() { return 1 } })", &.{9001});
    try expectErrors("let a: [number?]", &.{9001});
    try expectErrors("let a: { [Symbol.iterator](): void }", &.{9001});
    try expectErrors("declare const x: number;", &.{9001});
    // A multi-line declaration is skipped as one unit.
    const parsed: *Parsed = try .init("class A {\n  x = 1;\n}\nconsole.log(2)");
    defer parsed.deinit();
    try testing.expectEqualSlices(u16, &.{9001}, try parsed.codes());
    try testing.expectEqualStrings("(call (. console log) 2)\n", try parsed.render());
    // `type` and friends are still ordinary names.
    try expectParse("type\ndeclare", "type\ndeclare\n");
}

test "functions" {
    try expectParse("function f(a: number, b = 1, ...c: number[]): void { return; }", "(fn f#0 (a#1: number b#2 = 1 ...c#3: number[]): void { return })\n");
    try expectParse("const g = function h() { return 1 }", "const g#1 = (fn h#0 () { return 1 })\n");
    try expectParse("x => x + 1", "(=> (x#0) (+ x 1))\n");
    try expectParse("(a, b?: string) => { a }", "(=> (a#0 b#1?: string) { a })\n");
    try expectParse("(): number => 1", "(=> (): number 1)\n");
    try expectParse("a => b => a", "(=> (a#0) (=> (b#1) a))\n");
    try expectParse("(a)", "[a]\n");
    try expectParse("(a, b)", "[(, a b)]\n");
    try expectParse("f((x) => x, 1)", "(call f (=> (x#0) x) 1)\n");
    try expectParse("c ? (a) : b", "(? c [a] b)\n");
    try expectParse("return\nx", "return\nx\n");
    try expectParse("let f: (a: number, b?: string, ...c: number[]) => void", "let f#0: (a: number, b?: string, ...c: number[]) => void\n");
    try expectParse("let f: (() => number)[]", "let f#0: () => number[]\n");
    try expectParse("let f: (number)", "let f#0: number\n");
}

test "objects and arrays" {
    try expectParse("({ a: 1, b, [c]: 2, ...d, 'e f': 3, 4: 5 })", "[(object a:1 b:b [c]:2 ...d e f:3 4:5)]\n");
    try expectParse("[1, ...a, 2,]", "(array 1 ...a 2)\n");
    try expectParse("a[1][b]", "(index (index a 1) b)\n");
    try expectParse("'a' in b; delete a.b", "(in \"a\" b)\n(delete (. a b))\n");
    try expectParse("({ m(x) { return x } })", "[(object m:(fn (x#0) { return x }))]\n");
    try expectErrors("({ a = 1 })", &.{1312});
    try expectErrors("({ 'a' })", &.{1005});
}

test "destructuring" {
    try expectParse("const { a, b: [c, , d = 1], ...e } = f", "const {a: a#0 b: [c#1 _ d#2 = 1] ...e#3} = f\n");
    try expectParse("let [x, ...y] = z", "let [x#0 ...y#1] = z\n");
    try expectParse("function f({ a }: T, [b] = c) {}", "(fn f#0 ({a: a#1}: T [b#2] = c) { })\n");
    try expectParse("({ a }) => a", "(=> ({a: a#0}) a)\n");
    try expectParse("([a, b])", "[(array a b)]\n");
    try expectErrors("let { a }", &.{1182});
    try expectErrors("let [...a, b] = c", &.{2462});
    try expectErrors("let { ...a, } = c", &.{1013});
}

test "for...of and for...in" {
    try expectParse("for (const x of xs) a", "for (const x#0 of xs) a\n");
    try expectParse("for (let [k, v] of e) {}", "for (let [k#0 v#1] of e) { }\n");
    try expectParse("for (k in o) ;", "for (k in o) ;\n");
    try expectParse("for (let i = ('a' in o) ? 1 : 0; ;) ;", "for (let i#0 = (? [(in \"a\" o)] 1 0); ; ) ;\n");
    try expectErrors("for (const x = 1 of xs) ;", &.{1190});
    try expectErrors("for (const x: number of xs) ;", &.{2483});
    try expectErrors("for (const a, b in o) ;", &.{1091});
}

test "type declarations" {
    try expectParse("interface A extends B, C { a: number; readonly b?: string, m(x: number): void }", "interface A extends B, C { a: number; readonly b?: string; m(x: number) => void; }\n");
    try expectParse("type T = { a: [number, string][] }", "type T = { a: [number, string][]; }\n");
    try expectParse("let readonly: number; type\nx", "let readonly#0: number\ntype\nx\n");
    try expectErrors("type number = string", &.{2457});
    try expectParse("interface I { (x: number): void; new (): I; readonly [k: string]: number }", "interface I { (x: number) => void; new () => I; readonly [k: string]: number; }\n");
    try expectParse("function f(x: unknown): x is string { return true }", "(fn f#0 (x#1: unknown): x is string { return true })\n");
    try expectParse("new Map<string, number>(...xs)", "(new Map ...xs)\n");
    try expectParse("new a.B", "(new (. a B))\n");
    try expectParse("type T = | 1 | -2 | \"a\" | true | null | string[]", "type T = 1 | -2 | \"a\" | true | null | string[]\n");
    try expectParse("type T = (A | B)[] | (() => C | D)", "type T = A | B[] | () => C | D\n");
    try expectErrors("type T = A | () => void", &.{1385});
}

test "function names" {
    const parsed: *Parsed = try .init("const a = () => 1; let b; b = (function () {}); function c(d = () => 1) {}");
    defer parsed.deinit();
    const statements = parsed.program.statements;
    try testing.expectEqualStrings("a", statements[0].data.variable.declarators[0].init.?.data.function.inferred_name);
    try testing.expectEqualStrings("b", statements[2].data.expression.data.assign.value.data.paren.data.function.inferred_name);
    const c = statements[3].data.function;
    try testing.expectEqualStrings("c", c.inferred_name);
    try testing.expectEqualStrings("d", c.parameters[0].init.?.data.function.inferred_name);
}

test "function errors" {
    try expectErrors("function () {}", &.{1003});
    try expectErrors("function f(...a, b) {}", &.{1014});
    try expectErrors("function f(...a = 1) {}", &.{1048});
    try expectErrors("function f(a?, b) {}", &.{});
    try expectErrors("function f(a?: number = 1) {}", &.{1015});
    try expectErrors("function* f() {}", &.{9001});
    try expectErrors("function f(): void;", &.{9001});
    try expectErrors("async function f() {}", &.{9001});
    try expectErrors("const f = async () => 1", &.{9001});
    try expectErrors("const f = async x => 1", &.{9001});
    try expectParse("async(1)", "(call async 1)\n");
    try expectErrors("let f: new () => void", &.{9001});
    try expectErrors("let a: unique symbol", &.{9001});
    try expectErrors("(a, b)\n=> a", &.{1200});
}
