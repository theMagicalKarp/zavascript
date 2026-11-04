//! Compile errors. Codes and messages follow tsc wherever tsc reports the same problem, so our
//! output can be compared with `tsc --pretty false`. Problems tsc doesn't have, such as features we
//! haven't implemented, use `ZV` codes.

const std = @import("std");
const Source = @import("Source.zig");

pub const Code = struct {
    prefix: Prefix,
    number: u16,

    pub const Prefix = enum { TS, ZV };

    pub fn ts(number: u16) Code {
        return .{ .prefix = .TS, .number = number };
    }

    pub fn zv(number: u16) Code {
        return .{ .prefix = .ZV, .number = number };
    }

    pub fn format(this: Code, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{t}{d}", .{ this.prefix, this.number });
    }
};

/// `ZV` codes. tsc codes are written inline at the call site with `Code.ts`.
pub const zv = struct {
    /// Syntax tsc accepts that we don't implement yet.
    pub const unsupported = Code.zv(9001);
};

pub const Diagnostic = struct {
    source: *const Source,
    /// Byte offset where the problem starts.
    start: u32,
    code: Code,
    message: []const u8,

    /// Renders like `tsc --pretty false`: `path(line,col): error TS2304: Cannot find name 'x'.`
    pub fn format(this: Diagnostic, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const loc = this.source.location(this.start);
        try writer.print("{s}({d},{d}): error {f}: {s}", .{ this.source.path, loc.line, loc.column, this.code, this.message });
    }
};

/// Collects every diagnostic from one compile, so all errors are reported, not just the first.
pub const Diagnostics = struct {
    /// Owns the list and the message text.
    arena: std.heap.ArenaAllocator,
    list: std.ArrayList(Diagnostic) = .empty,

    pub fn init(gpa: std.mem.Allocator) Diagnostics {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(this: *Diagnostics) void {
        this.arena.deinit();
        this.* = undefined;
    }

    pub fn clear(this: *Diagnostics) void {
        this.list = .empty;
        _ = this.arena.reset(.retain_capacity);
    }

    pub fn add(this: *Diagnostics, source: *const Source, start: u32, code: Code, comptime fmt: []const u8, args: anytype) error{OutOfMemory}!void {
        const allocator = this.arena.allocator();
        const message = try std.fmt.allocPrint(allocator, fmt, args);
        try this.list.append(allocator, .{ .source = source, .start = start, .code = code, .message = message });
    }

    /// For syntax errors: like tsc's parser, drops an error at the same position as the previous
    /// one, since that's almost always a consequence of it.
    pub fn addSyntax(this: *Diagnostics, source: *const Source, start: u32, code: Code, comptime fmt: []const u8, args: anytype) error{OutOfMemory}!void {
        if (this.list.items.len > 0) {
            const last = this.list.items[this.list.items.len - 1];
            if (last.source == source and last.start == start) return;
        }
        return this.add(source, start, code, fmt, args);
    }

    pub fn items(this: *const Diagnostics) []const Diagnostic {
        return this.list.items;
    }

    /// One diagnostic per line, in the order they were found.
    pub fn render(this: *const Diagnostics, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        for (this.list.items) |diagnostic| try writer.print("{f}\n", .{diagnostic});
    }
};

test "renders like tsc" {
    var source: Source = try .init(std.testing.allocator, "main.ts", "let a = 1;\nfoo;\n");
    defer source.deinit(std.testing.allocator);
    var diagnostics: Diagnostics = .init(std.testing.allocator);
    defer diagnostics.deinit();
    try diagnostics.add(&source, 11, .ts(2304), "Cannot find name '{s}'.", .{"foo"});
    try diagnostics.add(&source, 0, zv.unsupported, "'let' is not supported yet.", .{});

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try diagnostics.render(&out.writer);
    try std.testing.expectEqualStrings(
        \\main.ts(2,1): error TS2304: Cannot find name 'foo'.
        \\main.ts(1,1): error ZV9001: 'let' is not supported yet.
        \\
    , out.written());
}
