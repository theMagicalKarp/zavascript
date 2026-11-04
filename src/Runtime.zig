//! The entry point for running TypeScript: compile (lex, parse, type check) and then evaluate.
//! Code with any diagnostics never runs.
//!
//! ```zig
//! var runtime: zavascript.Runtime = try .init(gpa, .{ .stdout = stdout, .stderr = stderr });
//! defer runtime.deinit();
//! _ = runtime.run("main.ts", source) catch |err| switch (err) {
//!     error.CompileError => try runtime.diagnostics.render(stderr),
//!     else => return err,
//! };
//! ```

const std = @import("std");
const Source = @import("Source.zig");
const diagnostic = @import("diagnostic.zig");
const Parser = @import("syntax/Parser.zig");
const Checker = @import("check/Checker.zig");
const Interpreter = @import("runtime/Interpreter.zig");
const ast = @import("syntax/ast.zig");
pub const Value = @import("runtime/value.zig").Value;

const Runtime = @This();

gpa: std.mem.Allocator,
/// Sources, syntax trees and values. Everything lives until `deinit` for now; a garbage
/// collector will replace this.
arena: *std.heap.ArenaAllocator,
/// Diagnostics from the most recent `check` or `run`.
diagnostics: diagnostic.Diagnostics,
interpreter: Interpreter,

pub const Options = struct {
    /// Where `console.log`, `console.info` and `console.debug` write.
    stdout: *std.Io.Writer,
    /// Where `console.error` and `console.warn` write.
    stderr: *std.Io.Writer,
};

pub const Error = error{
    /// The source has syntax or type errors; they're in `diagnostics`.
    CompileError,
    OutOfMemory,
    /// Writing to `stdout` or `stderr` failed.
    WriteFailed,
};

pub fn init(gpa: std.mem.Allocator, options: Options) error{ OutOfMemory, WriteFailed }!Runtime {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = .init(gpa);
    errdefer arena.deinit();
    return .{
        .gpa = gpa,
        .arena = arena,
        .diagnostics = .init(gpa),
        .interpreter = try .init(arena.allocator(), options.stdout, options.stderr),
    };
}

pub fn deinit(this: *Runtime) void {
    this.diagnostics.deinit();
    this.arena.deinit();
    this.gpa.destroy(this.arena);
    this.* = undefined;
}

/// A compiled program, ready to `execute`. Owned by the runtime.
pub const Program = ast.Program;

/// Parses and type checks `text` without running it. `path` is only used in diagnostics.
pub fn check(this: *Runtime, path: []const u8, text: []const u8) Error!void {
    _ = try this.compile(path, text);
}

/// Compiles and runs `text`, returning the value of its last expression statement (what the
/// REPL prints). `path` is only used in diagnostics.
pub fn run(this: *Runtime, path: []const u8, text: []const u8) Error!Value {
    return this.execute(try this.compile(path, text));
}

/// Runs a program `compile` returned.
pub fn execute(this: *Runtime, program: Program) Error!Value {
    return this.interpreter.run(program);
}

/// Parses and type checks `text`. On `error.CompileError` the problems are in `diagnostics`.
pub fn compile(this: *Runtime, path: []const u8, text: []const u8) Error!Program {
    this.diagnostics.clear();
    const arena = this.arena.allocator();
    const source = try arena.create(Source);
    source.* = try .init(arena, try arena.dupe(u8, path), try arena.dupe(u8, text));
    const program = try Parser.parse(this.gpa, arena, source, &this.diagnostics);
    // Like tsc, only type check a file that parsed cleanly, so syntax errors don't cascade.
    if (this.diagnostics.items().len > 0) return error.CompileError;
    try Checker.check(arena, source, &this.diagnostics, program);
    if (this.diagnostics.items().len > 0) return error.CompileError;
    return program;
}

/// Writes `value` the way node's REPL shows it.
pub fn inspect(writer: *std.Io.Writer, value: Value) std.Io.Writer.Error!void {
    return @import("runtime/value.zig").inspect(writer, value);
}

const testing = std.testing;

fn expectOutput(source: []const u8, expected: []const u8) !void {
    var stdout: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr.deinit();
    var runtime: Runtime = try .init(testing.allocator, .{ .stdout = &stdout.writer, .stderr = &stderr.writer });
    defer runtime.deinit();
    _ = try runtime.run("test.ts", source);
    try testing.expectEqualStrings(expected, stdout.written());
}

test "runs a program" {
    try expectOutput("console.log(1 + 2 * 3)", "7\n");
    try expectOutput("console.log('a' + 1, `x${1 + 1}y`)", "a1 x2y\n");
}

test "refuses to run code with type errors" {
    var stdout: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout.deinit();
    var runtime: Runtime = try .init(testing.allocator, .{ .stdout = &stdout.writer, .stderr = &stdout.writer });
    defer runtime.deinit();
    try testing.expectError(error.CompileError, runtime.run("test.ts", "console.log(1); console.log('a' * 2)"));
    try testing.expectEqualStrings("", stdout.written());
    try testing.expectEqual(2362, runtime.diagnostics.items()[0].code.number);
}

test "keeps state between runs" {
    var stdout: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout.deinit();
    var runtime: Runtime = try .init(testing.allocator, .{ .stdout = &stdout.writer, .stderr = &stdout.writer });
    defer runtime.deinit();
    try testing.expectEqual(@as(f64, 3), (try runtime.run("repl", "1 + 2")).number);
    try testing.expectError(error.CompileError, runtime.run("repl", "nope"));
    try testing.expectEqualStrings("ok", (try runtime.run("repl", "'ok'")).string);
}
