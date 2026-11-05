//! Requires the bodies of `if`, `else`, `while` and `for` statements to be blocks, which
//! `zig fmt` cannot enforce:
//!
//!   if (done) return;            // rejected
//!   if (done) {                  // accepted
//!       return;
//!   }
//!
//! Only statements are checked. An `if` used as a value (`const x = if (c) a else b;`) is left
//! alone, since wrapping its branches in blocks would change what it means. `else if` chains
//! are fine as they are.
//!
//! Usage: braces [--fix] <file or dir>...
//!
//! Without `--fix`, lists each offending body and exits with status 1 if there were any. With
//! `--fix`, wraps them in braces, formats the result as `zig fmt` would, and writes it back.

const std = @import("std");
const Ast = std.zig.Ast;

/// Replaces `len` bytes of the source at `offset` with `text`.
const Edit = struct {
    offset: usize,
    len: usize = 0,
    text: []const u8,

    fn lessThan(_: void, a: Edit, b: Edit) bool {
        return a.offset < b.offset;
    }
};

/// A statement body that is not a block.
const Violation = struct {
    keyword: []const u8,
    body: Ast.Node.Index,

    fn lessThan(tree: Ast, a: Violation, b: Violation) bool {
        return tree.firstToken(a.body) < tree.firstToken(b.body);
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var args = try init.minimal.args.iterateAllocator(arena);
    _ = args.skip();
    var fix = false;
    var paths: std.ArrayList([]const u8) = .empty;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--fix")) {
            fix = true;
        } else {
            try paths.append(arena, arg);
        }
    }
    if (paths.items.len == 0) {
        return error.MissingPaths;
    }

    var files: std.ArrayList([]const u8) = .empty;
    const cwd = std.Io.Dir.cwd();
    for (paths.items) |path| {
        if (std.mem.endsWith(u8, path, ".zig")) {
            try files.append(arena, path);
            continue;
        }
        var dir = try cwd.openDir(io, path, .{ .iterate = true });
        defer dir.close(io);
        var walker = try dir.walk(arena);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) {
                continue;
            }
            try files.append(arena, try std.fs.path.join(arena, &.{ path, entry.path }));
        }
    }

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_writer.interface;

    var found: usize = 0;
    for (files.items) |path| {
        const source = try cwd.readFileAllocOptions(io, path, gpa, .unlimited, .of(u8), 0);
        defer gpa.free(source);
        if (fix) {
            const fixed = try fixSource(gpa, source) orelse {
                try out.print("{s}: skipped, it does not parse\n", .{path});
                continue;
            };
            defer gpa.free(fixed);
            if (std.mem.eql(u8, source, fixed)) {
                continue;
            }
            try cwd.writeFile(io, .{ .sub_path = path, .data = fixed });
            try out.print("{s}: fixed\n", .{path});
        } else {
            found += try report(gpa, out, path, source);
        }
    }

    if (found > 0) {
        try out.print("\n{d} bodies need braces; run with --fix to add them\n", .{found});
        try out.flush();
        std.process.exit(1);
    }
    try out.flush();
}

/// Prints each violation in `source` and returns how many there were.
fn report(gpa: std.mem.Allocator, out: *std.Io.Writer, path: []const u8, source: [:0]const u8) !usize {
    var tree = try Ast.parse(gpa, source, .{});
    defer tree.deinit(gpa);
    if (tree.errors.len > 0) {
        try out.print("{s}: skipped, it does not parse\n", .{path});
        return 0;
    }
    var violations: std.ArrayList(Violation) = .empty;
    defer violations.deinit(gpa);
    try findViolations(gpa, tree, &violations);
    std.mem.sort(Violation, violations.items, tree, Violation.lessThan);
    for (violations.items) |v| {
        const loc = tree.tokenLocation(0, tree.firstToken(v.body));
        try out.print("{s}:{d}:{d}: body of `{s}` must be a block\n", .{ path, loc.line + 1, loc.column + 1, v.keyword });
    }
    return violations.items.len;
}

/// Returns `source` with every violation wrapped in braces and formatted, or null if it does not
/// parse. Repeats until nothing changes, since a fix can expose a nested body as a statement:
/// `if (a) if (b) f();` becomes `if (a) { if (b) f(); }`.
fn fixSource(gpa: std.mem.Allocator, source: [:0]const u8) !?[:0]u8 {
    var current = try gpa.dupeSentinel(u8, source, 0);
    errdefer gpa.free(current);
    while (true) {
        var tree = try Ast.parse(gpa, current, .{});
        defer tree.deinit(gpa);
        if (tree.errors.len > 0) {
            gpa.free(current);
            return null;
        }

        var violations: std.ArrayList(Violation) = .empty;
        defer violations.deinit(gpa);
        try findViolations(gpa, tree, &violations);
        if (violations.items.len == 0) {
            var formatted: std.Io.Writer.Allocating = .init(gpa);
            defer formatted.deinit();
            try tree.render(gpa, &formatted.writer, .{});
            gpa.free(current);
            return try gpa.dupeSentinel(u8, formatted.written(), 0);
        }

        var edits: std.ArrayList(Edit) = .empty;
        defer edits.deinit(gpa);
        for (violations.items) |v| {
            try addBraces(gpa, tree, v.body, &edits);
        }
        std.mem.sort(Edit, edits.items, {}, Edit.lessThan);

        var next: std.ArrayList(u8) = .empty;
        errdefer next.deinit(gpa);
        var copied: usize = 0;
        for (edits.items) |edit| {
            try next.appendSlice(gpa, current[copied..edit.offset]);
            try next.appendSlice(gpa, edit.text);
            copied = edit.offset + edit.len;
        }
        try next.appendSlice(gpa, current[copied..]);
        gpa.free(current);
        current = try next.toOwnedSliceSentinel(gpa, 0);
    }
}

/// Finds every non-block body of an `if`, `while` or `for` that is a statement in some block.
fn findViolations(gpa: std.mem.Allocator, tree: Ast, violations: *std.ArrayList(Violation)) !void {
    for (0..tree.nodes.len) |i| {
        var buffer: [2]Ast.Node.Index = undefined;
        const statements = tree.blockStatements(&buffer, @fromBackingInt(@intCast(i))) orelse continue;
        for (statements) |statement| {
            try checkStatement(gpa, tree, statement, violations);
        }
    }
}

fn checkStatement(gpa: std.mem.Allocator, tree: Ast, node: Ast.Node.Index, violations: *std.ArrayList(Violation)) !void {
    if (tree.fullIf(node)) |full| {
        try checkBody(gpa, tree, "if", full.ast.then_expr, violations);
        if (full.ast.else_expr.unwrap()) |else_expr| {
            // `else if` continues the chain rather than being a body of its own.
            if (tree.fullIf(else_expr) != null) {
                try checkStatement(gpa, tree, else_expr, violations);
            } else {
                try checkBody(gpa, tree, "else", else_expr, violations);
            }
        }
    } else if (tree.fullWhile(node)) |full| {
        try checkBody(gpa, tree, "while", full.ast.then_expr, violations);
        if (full.ast.else_expr.unwrap()) |else_expr| {
            try checkBody(gpa, tree, "else", else_expr, violations);
        }
    } else if (tree.fullFor(node)) |full| {
        try checkBody(gpa, tree, "for", full.ast.then_expr, violations);
        if (full.ast.else_expr.unwrap()) |else_expr| {
            try checkBody(gpa, tree, "else", else_expr, violations);
        }
    }
}

fn checkBody(gpa: std.mem.Allocator, tree: Ast, keyword: []const u8, body: Ast.Node.Index, violations: *std.ArrayList(Violation)) !void {
    switch (tree.nodeTag(body)) {
        .block, .block_semicolon, .block_two, .block_two_semicolon => {},
        else => try violations.append(gpa, .{ .keyword = keyword, .body = body }),
    }
}

/// Adds the edits that wrap `body` in braces. The opening brace goes right after the token
/// before the body, so a comment between the condition and the body ends up inside the block.
fn addBraces(gpa: std.mem.Allocator, tree: Ast, body: Ast.Node.Index, edits: *std.ArrayList(Edit)) !void {
    const before = tree.firstToken(body) - 1;
    try edits.append(gpa, .{ .offset = tokenEnd(tree, before), .text = " {" });

    // The statement's own `;` follows the last body (`if (c) f();`) and moves inside the block,
    // except after a body like `switch (x) {}`, where it would be a stray empty statement. A body
    // followed by `else` has no `;`, so it needs one, unless it ends in a block of its own.
    const last = tree.lastToken(body);
    if (tree.tokenTag(last + 1) == .semicolon) {
        if (endsInBlock(tree, body)) {
            try edits.append(gpa, .{ .offset = tree.tokenStart(last + 1), .len = 1, .text = " }" });
        } else {
            try edits.append(gpa, .{ .offset = tokenEnd(tree, last + 1), .text = " }" });
        }
    } else if (endsInBlock(tree, body)) {
        try edits.append(gpa, .{ .offset = tokenEnd(tree, last), .text = " }" });
    } else {
        try edits.append(gpa, .{ .offset = tokenEnd(tree, last), .text = "; }" });
    }
}

/// Whether `node` is a statement that needs no `;`, like `while (x) {}` or `switch (x) {}`.
fn endsInBlock(tree: Ast, node: Ast.Node.Index) bool {
    if (tree.tokenTag(tree.lastToken(node)) != .r_brace) {
        return false;
    }
    return switch (tree.nodeTag(node)) {
        .@"if", .if_simple, .@"while", .while_simple, .while_cont, .@"for", .for_simple, .@"switch", .switch_comma => true,
        else => false,
    };
}

fn tokenEnd(tree: Ast, token: Ast.TokenIndex) usize {
    return tree.tokenStart(token) + tree.tokenSlice(token).len;
}

fn expectFix(input: [:0]const u8, expected: []const u8) !void {
    const fixed = (try fixSource(std.testing.allocator, input)).?;
    defer std.testing.allocator.free(fixed);
    try std.testing.expectEqualStrings(expected, fixed);
}

test "wraps a single statement body" {
    try expectFix(
        \\fn f(x: bool) void {
        \\    if (x) return;
        \\}
        \\
    ,
        \\fn f(x: bool) void {
        \\    if (x) {
        \\        return;
        \\    }
        \\}
        \\
    );
}

test "wraps both branches and else-if chains" {
    try expectFix(
        \\fn f(a: bool, b: bool) void {
        \\    if (a) g() else if (b) h() else g();
        \\}
        \\
    ,
        \\fn f(a: bool, b: bool) void {
        \\    if (a) {
        \\        g();
        \\    } else if (b) {
        \\        h();
        \\    } else {
        \\        g();
        \\    }
        \\}
        \\
    );
}

test "wraps loops and nested bodies" {
    try expectFix(
        \\fn f(xs: []u8) void {
        \\    var i: usize = 0;
        \\    while (i < xs.len) : (i += 1) for (xs) |*x| if (x.* == 0) x.* = 1;
        \\}
        \\
    ,
        \\fn f(xs: []u8) void {
        \\    var i: usize = 0;
        \\    while (i < xs.len) : (i += 1) {
        \\        for (xs) |*x| {
        \\            if (x.* == 0) {
        \\                x.* = 1;
        \\            }
        \\        }
        \\    }
        \\}
        \\
    );
}

test "drops the semicolon after a body that ends in a block" {
    try expectFix(
        \\fn f(s: []const u8) void {
        \\    for (s) |c| switch (c) {
        \\        else => {},
        \\    };
        \\}
        \\
    ,
        \\fn f(s: []const u8) void {
        \\    for (s) |c| {
        \\        switch (c) {
        \\            else => {},
        \\        }
        \\    }
        \\}
        \\
    );
}

test "leaves value-producing ifs alone" {
    const source =
        \\fn f(c: bool) u8 {
        \\    const x = if (c) 1 else 2;
        \\    return if (c) x else 0;
        \\}
        \\
    ;
    try expectFix(source, source);
}
