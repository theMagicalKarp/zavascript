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
pub const Value = @import("runtime/value.zig").Value;

const Runtime = @This();

gpa: std.mem.Allocator,
/// Sources, syntax trees and values. Everything lives until `deinit` for now; a garbage
/// collector will replace this.
arena: *std.heap.ArenaAllocator,
/// Diagnostics from the most recent `check` or `run`.
diagnostics: diagnostic.Diagnostics,
/// Declarations from earlier programs, which later ones can use (the REPL's previous lines).
session: Checker.Session = .{},
interpreter: Interpreter,

pub const Options = struct {
    /// Where `console.log`, `console.info` and `console.debug` write.
    stdout: *std.Io.Writer,
    /// Where `console.error` and `console.warn` write.
    stderr: *std.Io.Writer,
    /// How much of the calling thread's stack the interpreter may use, in bytes. Deeper
    /// recursion throws a RangeError, as in node. Keep it well below the thread's stack size.
    max_stack: usize = 4 * 1024 * 1024,
    /// Where `Math.random` starts. The same seed gives the same numbers.
    random_seed: u64 = 0,
};

pub const Error = error{
    /// The source has syntax or type errors; they're in `diagnostics`.
    CompileError,
    /// The program threw an exception it didn't catch; it's in `exception()`.
    RuntimeError,
    OutOfMemory,
    /// Writing to `stdout` or `stderr` failed.
    WriteFailed,
};

pub const Exception = Interpreter.Exception;

/// What the last `run` or `execute` that returned `error.RuntimeError` threw.
pub fn exception(this: *const Runtime) ?Exception {
    return this.interpreter.exception;
}

pub fn init(gpa: std.mem.Allocator, options: Options) error{ OutOfMemory, WriteFailed }!Runtime {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = .init(gpa);
    errdefer arena.deinit();
    var runtime: Runtime = .{
        .gpa = gpa,
        .arena = arena,
        .diagnostics = .init(gpa),
        .interpreter = try .init(arena.allocator(), options.stdout, options.stderr, options.max_stack, options.random_seed),
    };
    errdefer runtime.diagnostics.deinit();
    try runtime.declareLibrary();
    return runtime;
}

pub fn deinit(this: *Runtime) void {
    this.diagnostics.deinit();
    this.arena.deinit();
    this.gpa.destroy(this.arena);
    this.* = undefined;
}

/// A compiled program, ready to `execute`. Owned by the runtime.
pub const Program = Interpreter.Program;

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
    if (this.diagnostics.items().len > 0) {
        return error.CompileError;
    }
    const resolved = try Checker.check(arena, source, &this.diagnostics, &this.session, program);
    if (this.diagnostics.items().len > 0) {
        // Like tsc, in source order; functions can be checked out of order.
        this.diagnostics.sort();
        return error.CompileError;
    }
    return .{ .ast = program, .resolved = resolved, .text = source.text };
}

/// Declares what `lib.d.ts` does, for every program after.
fn declareLibrary(this: *Runtime) error{OutOfMemory}!void {
    const arena = this.arena.allocator();
    const source = try arena.create(Source);
    source.* = try .init(arena, "lib.d.ts", @embedFile("lib/lib.d.ts"));
    var diagnostics: diagnostic.Diagnostics = .init(this.gpa);
    defer diagnostics.deinit();
    const program = try Parser.parse(this.gpa, arena, source, &diagnostics);
    std.debug.assert(diagnostics.items().len == 0);
    try Checker.declareLibrary(arena, &this.session, program);
}

/// Writes `value` the way node's REPL shows it.
pub fn inspect(this: *Runtime, writer: *std.Io.Writer, value: Value) error{ WriteFailed, OutOfMemory }!void {
    return @import("runtime/value.zig").inspect(this.arena.allocator(), writer, value);
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

test "keeps declarations between runs" {
    var stdout: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout.deinit();
    var runtime: Runtime = try .init(testing.allocator, .{ .stdout = &stdout.writer, .stderr = &stdout.writer });
    defer runtime.deinit();
    try testing.expectEqual(.undefined, try runtime.run("repl", "let a = 1, b: number"));
    try testing.expectEqual(@as(f64, 1), (try runtime.run("repl", "a")).number);
    // `b` hasn't been assigned yet.
    try testing.expectError(error.CompileError, runtime.run("repl", "b"));
    try testing.expectEqual(2454, runtime.diagnostics.items()[0].code.number);
    try testing.expectEqual(@as(f64, 5), (try runtime.run("repl", "b = a + 4")).number);
    try testing.expectEqual(@as(f64, 6), (try runtime.run("repl", "a + b")).number);
    // A line that doesn't compile declares nothing.
    try testing.expectError(error.CompileError, runtime.run("repl", "let c = 1; c = 'x'"));
    try testing.expectError(error.CompileError, runtime.run("repl", "c"));
    try testing.expectEqual(2304, runtime.diagnostics.items()[0].code.number);
    try testing.expectEqual(.undefined, try runtime.run("repl", "let c = 'x'"));
    try testing.expectEqualStrings("x", (try runtime.run("repl", "c")).string);
    // Redeclaring is an error, as in node's REPL.
    try testing.expectError(error.CompileError, runtime.run("repl", "let a = 2"));
    try testing.expectEqual(2451, runtime.diagnostics.items()[0].code.number);
    // Narrowing carries over: `d` is `true` until something assigns `false`.
    _ = try runtime.run("repl", "let d = true");
    try testing.expectError(error.CompileError, runtime.run("repl", "d === false"));
    _ = try runtime.run("repl", "d = 1 < 0");
    try testing.expectEqual(true, (try runtime.run("repl", "d === false")).boolean);
}

test "completion values" {
    var stdout: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout.deinit();
    var runtime: Runtime = try .init(testing.allocator, .{ .stdout = &stdout.writer, .stderr = &stdout.writer });
    defer runtime.deinit();
    try testing.expectEqual(@as(f64, 1), (try runtime.run("repl", "1; let x = 2;")).number);
    try testing.expectEqual(.undefined, try runtime.run("repl", "1; if (x) {}"));
    try testing.expectEqual(@as(f64, 3), (try runtime.run("repl", "if (x) { 3 } else { 4 }")).number);
    try testing.expectEqual(@as(f64, 9), (try runtime.run("repl", "let i = 0; while (i < 10) { if (i === 9) { i; break; } i++; }")).number);
    try testing.expectEqual(@as(f64, 2), (try runtime.run("repl", "switch (x) { case 1: 1; case 2: 2; break; default: 3 }")).number);
    try testing.expectEqual(@as(f64, 5), (try runtime.run("repl", "outer: { 5; break outer; }")).number);
}

fn expectThrows(source: []const u8, expected: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var runtime: Runtime = try .init(testing.allocator, .{ .stdout = &out.writer, .stderr = &out.writer });
    defer runtime.deinit();
    try testing.expectError(error.RuntimeError, runtime.run("test.ts", source));
    try testing.expectFmt(expected, "{f}", .{runtime.exception().?});
}

test "runtime errors" {
    try expectThrows("function f(n: number): number { return f(n + 1); } f(0)", "Uncaught RangeError: Maximum call stack size exceeded");
    try expectThrows("const f = () => x; f(); let x = 1;", "Uncaught ReferenceError: Cannot access 'x' before initialization");
    try expectThrows("function g() { y = 2; } g(); let y = 1;", "Uncaught ReferenceError: Cannot access 'y' before initialization");
    try expectThrows("function g() { y = console.log('evaluated first'); } g(); let y: void;", "Uncaught ReferenceError: Cannot access 'y' before initialization");
    try expectThrows("let a: any = 1; a()", "Uncaught TypeError: a is not a function");
    try expectThrows("let a: any = undefined; a.b", "Uncaught TypeError: Cannot read properties of undefined (reading 'b')");
    try expectThrows("let a: any = 1; a.toLocaleString()", "error ZV9001: 'toLocaleString' of a number is not supported yet.");
    try expectThrows("let a: any = 1; a.b.c", "Uncaught TypeError: Cannot read properties of undefined (reading 'c')");
    try expectThrows("const a: any = Map; a()", "Uncaught TypeError: Constructor Map requires 'new'");
    try expectThrows("const a: any = Number; new a()", "error ZV9001: Constructing 'Number' is not supported yet.");
    try expectThrows("function f(x: number | null) { if (x === null) { throw 'no ' + x; } return x; } f(null)", "Uncaught no null");
    try expectThrows("throw { code: 1 }", "Uncaught { code: 1 }");
    // A non-null assertion checks nothing.
    try expectThrows("const a: { b: number } | undefined = undefined as { b: number } | undefined; a!.b", "Uncaught TypeError: Cannot read properties of undefined (reading 'b')");
}

test "string methods remember the last long string" {
    var stdout: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout.deinit();
    var runtime: Runtime = try .init(testing.allocator, .{ .stdout = &stdout.writer, .stderr = &stdout.writer });
    defer runtime.deinit();
    // A loop that indexes a long string would otherwise convert or scan all of it each time round.
    _ = try runtime.run("test.ts", "const s = 'é'.repeat(300); let n = 0; for (let i = 0; i < s.length; i++) { n += s.charCodeAt(i); }");
    const state = &runtime.interpreter.builtin_state;
    try testing.expectEqual(600, state.text.bytes.len);
    try testing.expectEqual(300, state.text.units.?.len);
    try testing.expectEqual(600, state.length.bytes.len);
    try testing.expectEqual(300, state.length.units);
}

test "union narrowing between runs" {
    var stdout: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout.deinit();
    var runtime: Runtime = try .init(testing.allocator, .{ .stdout = &stdout.writer, .stderr = &stdout.writer });
    defer runtime.deinit();
    _ = try runtime.run("repl", "let x: string | number = 'a'");
    // What an assignment narrowed `x` to carries over to the next line.
    try testing.expectError(error.CompileError, runtime.run("repl", "const n: number = x"));
    _ = try runtime.run("repl", "x = 1");
    try testing.expectEqual(@as(f64, 2), (try runtime.run("repl", "const n: number = x; n + 1")).number);
}

test "keeps functions between runs" {
    var stdout: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout.deinit();
    var runtime: Runtime = try .init(testing.allocator, .{ .stdout = &stdout.writer, .stderr = &stdout.writer });
    defer runtime.deinit();
    _ = try runtime.run("repl", "function counter() { let n = 0; return () => ++n; }");
    _ = try runtime.run("repl", "const next = counter()");
    _ = try runtime.run("repl", "next(); next()");
    try testing.expectEqual(@as(f64, 3), (try runtime.run("repl", "next()")).number);
    try testing.expectEqual(@as(f64, 1), (try runtime.run("repl", "counter()()")).number);
    // A REPL line can call itself through an earlier one.
    _ = try runtime.run("repl", "function fact(n: number): number { return n <= 1 ? 1 : n * fact(n - 1); }");
    try testing.expectEqual(@as(f64, 120), (try runtime.run("repl", "fact(5)")).number);
    try testing.expectError(error.CompileError, runtime.run("repl", "fact('x')"));
    try testing.expectEqual(2345, runtime.diagnostics.items()[0].code.number);
}

test "keeps types and objects between runs" {
    var stdout: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout.deinit();
    var runtime: Runtime = try .init(testing.allocator, .{ .stdout = &stdout.writer, .stderr = &stdout.writer });
    defer runtime.deinit();
    _ = try runtime.run("repl", "interface P { x: number; y?: number }");
    _ = try runtime.run("repl", "const p: P = { x: 1 }");
    try testing.expectError(error.CompileError, runtime.run("repl", "const q: P = { z: 1 }"));
    try testing.expectEqual(2353, runtime.diagnostics.items()[0].code.number);
    _ = try runtime.run("repl", "p.y = 2; const { x, ...rest } = p");
    try testing.expectEqual(@as(f64, 2), (try runtime.run("repl", "rest.y")).number);
    // A line that doesn't compile declares no types either.
    try testing.expectError(error.CompileError, runtime.run("repl", "type T = number; const t: T = 'x'"));
    try testing.expectError(error.CompileError, runtime.run("repl", "let u: T"));
    try testing.expectEqual(2304, runtime.diagnostics.items()[0].code.number);
    _ = try runtime.run("repl", "type T = string");
}

test "runtime errors in builtins" {
    try expectThrows("([] as number[]).reduce((a, b) => a + b)", "Uncaught TypeError: Reduce of empty array with no initial value");
    try expectThrows("(Object.freeze([1]) as number[]).push(2)", "Uncaught TypeError: Cannot add property 1, object is not extensible");
    try expectThrows("JSON.parse('{a')", "Uncaught SyntaxError: Expected property name or '}' in JSON at position 1 (line 1 column 2)");
    try expectThrows("JSON.parse('')", "Uncaught SyntaxError: Unexpected end of JSON input");
    try expectThrows("JSON.parse('[1,]')", "Uncaught SyntaxError: Unexpected token ']', \"[1,]\" is not valid JSON");
    try expectThrows("JSON.parse('abcdefghijklmnopqrstuvwxyz')", "Uncaught SyntaxError: Unexpected token 'a', \"abcdefghij\"... is not valid JSON");
    try expectThrows("JSON.parse('1 2')", "Uncaught SyntaxError: Unexpected non-whitespace character after JSON at position 2 (line 1 column 3)");
    try expectThrows("const o: any = { a: { b: {} } }; o.a.b.c = o; JSON.stringify(o)",
        \\Uncaught TypeError: Converting circular structure to JSON
        \\    --> starting at object with constructor 'Object'
        \\    |     property 'a' -> object with constructor 'Object'
        \\    |     property 'b' -> object with constructor 'Object'
        \\    --- property 'c' closes the circle
    );
    try expectThrows("(1).toFixed(101)", "Uncaught RangeError: toFixed() digits argument must be between 0 and 100");
    try expectThrows("(255).toString(1)", "Uncaught RangeError: toString() radix argument must be between 2 and 36");
    try expectThrows("'a'.repeat(-1)", "Uncaught RangeError: Invalid count value: -1");
    try expectThrows("String.fromCodePoint(-1)", "Uncaught RangeError: Invalid code point -1");
    try expectThrows("new Map([1] as any)", "Uncaught TypeError: Iterator value 1 is not an entry object");
    try expectThrows("new Set(5 as any)", "Uncaught TypeError: number 5 is not iterable (cannot read property Symbol(Symbol.iterator))");
    try expectThrows("[1].map(5 as any)", "Uncaught TypeError: number 5 is not a function");
    try expectThrows("[1].sort(5 as any)", "Uncaught TypeError: The comparison function must be either a function or undefined: 5");
    try expectThrows("Object.keys(undefined as any)", "Uncaught TypeError: Cannot convert undefined or null to object");
    try expectThrows("JSON.parse('\"\\\\u+041\"')", "Uncaught SyntaxError: Bad Unicode escape in JSON at position 3 (line 1 column 4)");
    try expectThrows("JSON.parse('\"\\\\u0_41\"')", "Uncaught SyntaxError: Bad Unicode escape in JSON at position 4 (line 1 column 5)");
    // Recursing on a value's depth runs out of stack the way calls do.
    try expectThrows("let a: any[] = []; for (let i = 0; i < 1e6; i++) { a = [a]; } String(a)", "Uncaught RangeError: Maximum call stack size exceeded");
    try expectThrows("let a: any[] = []; for (let i = 0; i < 1e6; i++) { a = [a]; } `${[a]}`", "Uncaught RangeError: Maximum call stack size exceeded");
    try expectThrows("let a: any[] = []; for (let i = 0; i < 1e6; i++) { a = [a]; } a.join('-')", "Uncaught RangeError: Maximum call stack size exceeded");
    try expectThrows("let a: any[] = []; for (let i = 0; i < 1e6; i++) { a = [a]; } [a].map(String)", "Uncaught RangeError: Maximum call stack size exceeded");
    try expectThrows("JSON.parse('['.repeat(1e6) + ']'.repeat(1e6))", "Uncaught RangeError: Maximum call stack size exceeded");
    try expectThrows("let a: any[] = []; for (let i = 0; i < 1e6; i++) { a = [a]; } JSON.stringify(a)", "Uncaught RangeError: Maximum call stack size exceeded");
    try expectThrows("const a: any[] = []; a.push(a); a.flat(Infinity)", "Uncaught RangeError: Maximum call stack size exceeded");
    try expectThrows("Object.assign(Object.freeze([1]) as any, { 0: 5 })", "Uncaught TypeError: Cannot assign to read only property '0' of object '[object Array]'");
    try expectThrows("Object.assign(Object.freeze([1]) as any, { 1: 5 })", "Uncaught TypeError: Cannot add property 1, object is not extensible");
    try expectThrows("Object.assign(Object.freeze({ a: 1 }) as any, { b: 5 })", "Uncaught TypeError: Cannot add property b, object is not extensible");
    try expectThrows("'ά'.toUpperCase()", "error ZV9001: Changing the case of 'ά' is not supported yet.");
    try expectThrows("const a: any = [1]; a.copyWithin(0, 0)", "error ZV9001: 'copyWithin' of a object is not supported yet.");
}

test "runtime errors on objects" {
    try expectThrows("const a: any = null; const { b } = a;", "Uncaught TypeError: Cannot destructure 'null' as it is null.");
    try expectThrows("const a: any = undefined; a.b = 1", "Uncaught TypeError: Cannot set properties of undefined (setting 'b')");
    try expectThrows("const a: any = 5; for (const x of a) {}", "Uncaught TypeError: 5 is not iterable");
    try expectThrows("const a: any = 5; 'x' in a", "Uncaught TypeError: Cannot use 'in' operator to search for 'x' in 5");
    try expectThrows("const a: number[] = []; a[2] = 1", "error ZV9001: Assigning past the end of an array, which leaves holes in it, is not supported yet.");
    try expectThrows("const a = [1]; delete a[0]", "error ZV9001: Deleting an array's elements is not supported yet.");
}
