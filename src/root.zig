//! zavascript: a TypeScript runtime that type checks like `tsc --strict` before it runs anything.
//! `Runtime` is the API for embedding; the other declarations are the pieces it's built from.

const std = @import("std");

pub const Runtime = @import("Runtime.zig");
pub const Value = Runtime.Value;
pub const Source = @import("Source.zig");
pub const diagnostic = @import("diagnostic.zig");
pub const Diagnostic = diagnostic.Diagnostic;
pub const Diagnostics = diagnostic.Diagnostics;

pub const syntax = struct {
    pub const token = @import("syntax/token.zig");
    pub const Lexer = @import("syntax/Lexer.zig");
    pub const ast = @import("syntax/ast.zig");
    pub const Parser = @import("syntax/Parser.zig");
};

pub const check = struct {
    pub const types = @import("check/types.zig");
    pub const Checker = @import("check/Checker.zig");
};

pub const runtime = struct {
    pub const number = @import("runtime/number.zig");
    pub const value = @import("runtime/value.zig");
    pub const Interpreter = @import("runtime/Interpreter.zig");
};

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(syntax);
    std.testing.refAllDecls(check);
    std.testing.refAllDecls(runtime);
    _ = @import("runtime/builtins.zig");
    _ = @import("runtime/fdlibm.zig");
}
