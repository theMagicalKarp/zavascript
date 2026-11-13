//! `console`. Output is formatted the way node's `util.format` does it: format specifiers (`%s`,
//! `%d`, ...) in a first argument that's a string, then the rest of the arguments, strings as-is
//! and everything else as `util.inspect` shows it, separated by spaces. `console.group` indents
//! what follows.

const std = @import("std");
const native = @import("native.zig");
const value = @import("../value.zig");
const number = @import("../number.zig");
const json = @import("json.zig");
const Interpreter = native.Interpreter;
const Value = native.Value;
const Error = native.Error;
const arg = native.arg;

/// What `console.count` has counted, and how far `console.group` has indented.
pub const State = struct {
    counts: std.StringArrayHashMapUnmanaged(u32) = .empty,
    indentation: usize = 0,
};

pub fn create(it: *Interpreter) Error!Value {
    const console = try it.arena.create(value.Object);
    console.* = .{ .tag = "Object [console]" };
    // Its methods are its own properties, which `console.log(console)` shows.
    inline for (.{
        .{ "log", log },     .{ "warn", warn },             .{ "dir", dir },     .{ "assert", assert },
        .{ "count", count }, .{ "countReset", countReset }, .{ "group", group }, .{ "groupEnd", groupEnd },
        .{ "debug", log },   .{ "info", log },              .{ "error", warn },  .{ "groupCollapsed", group },
    }) |entry| {
        try console.properties.put(it.arena, entry[0], native.function(entry[0], 0, entry[1]));
    }
    return .{ .object = console };
}

/// Writes a line to stdout or stderr, indented by `console.group`.
fn writeLine(it: *Interpreter, to_stderr: bool, text: []const u8) Error!void {
    const out = if (to_stderr) it.stderr else it.stdout;
    const indentation = it.builtin_state.console.indentation;
    if (indentation == 0) {
        try out.writeAll(text);
    } else {
        try out.splatByteAll(' ', indentation);
        var lines = std.mem.splitScalar(u8, text, '\n');
        var first = true;
        while (lines.next()) |line| {
            if (!first) {
                try out.writeByte('\n');
                try out.splatByteAll(' ', indentation);
            }
            first = false;
            try out.writeAll(line);
        }
    }
    try out.writeByte('\n');
}

fn inspect(it: *Interpreter, v: Value, depth: usize) Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(it.arena);
    value.inspectDepth(it.arena, &out.writer, v, depth) catch return error.OutOfMemory;
    return out.written();
}

/// node's `formatWithOptions`.
pub fn format(it: *Interpreter, args: []const Value) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var next: usize = 0;
    if (args.len > 0 and args[0] == .string) {
        const f = args[0].string;
        next = 1;
        var i: usize = 0;
        var last: usize = 0;
        while (i + 1 < f.len) : (i += 1) {
            if (f[i] != '%') {
                continue;
            }
            const spec = f[i + 1];
            if (spec == '%') {
                try out.appendSlice(it.arena, f[last..i]);
                try out.append(it.arena, '%');
                i += 1;
                last = i + 1;
                continue;
            }
            if (next >= args.len or std.mem.indexOfScalar(u8, "sdifjoOc", spec) == null) {
                continue;
            }
            const a = args[next];
            const text: []const u8 = switch (spec) {
                's' => switch (a) {
                    .string => |str| str,
                    .number => try inspect(it, a, 2),
                    .object, .array, .function, .native_function => try inspect(it, a, 0),
                    else => try a.toString(it.arena),
                },
                'd' => switch (a) {
                    .object, .array => "NaN",
                    else => try inspect(it, native.number(a.toNumber()), 2),
                },
                'i' => switch (a) {
                    .object, .array => "NaN",
                    else => try inspect(it, native.number(number.parseInt(try a.toString(it.arena), 0)), 2),
                },
                'f' => try inspect(it, native.number(number.parseFloat(try a.toString(it.arena))), 2),
                'j' => blk: {
                    const result = try it.invoke(json.members.get("stringify").?, .undefined, &.{a});
                    break :blk if (result == .undefined) "undefined" else result.string;
                },
                'O' => try inspect(it, a, 2),
                'o' => switch (a) {
                    .object, .array, .function, .native_function => return it.throw(.Unsupported, "Formatting an object with '%o' is not supported yet.", .{}),
                    else => try inspect(it, a, 4),
                },
                'c' => "",
                else => unreachable,
            };
            try out.appendSlice(it.arena, f[last..i]);
            try out.appendSlice(it.arena, text);
            next += 1;
            i += 1;
            last = i + 1;
        }
        try out.appendSlice(it.arena, f[last..]);
    }
    for (args[next..], next..) |a, i| {
        if (i > 0) {
            try out.append(it.arena, ' ');
        }
        switch (a) {
            .string => |str| try out.appendSlice(it.arena, str),
            else => try out.appendSlice(it.arena, try inspect(it, a, 2)),
        }
    }
    return out.items;
}

fn log(it: *Interpreter, _: Value, args: []const Value) Error!Value {
    try writeLine(it, false, try format(it, args));
    return .undefined;
}

fn warn(it: *Interpreter, _: Value, args: []const Value) Error!Value {
    try writeLine(it, true, try format(it, args));
    return .undefined;
}

fn dir(it: *Interpreter, _: Value, args: []const Value) Error!Value {
    try writeLine(it, false, try inspect(it, arg(args, 0), 2));
    return .undefined;
}

fn group(it: *Interpreter, _: Value, args: []const Value) Error!Value {
    if (args.len > 0) {
        try writeLine(it, false, try format(it, args));
    }
    it.builtin_state.console.indentation += 2;
    return .undefined;
}

fn groupEnd(it: *Interpreter, _: Value, _: []const Value) Error!Value {
    it.builtin_state.console.indentation -|= 2;
    return .undefined;
}

fn label(it: *Interpreter, args: []const Value) Error![]const u8 {
    return if (arg(args, 0) == .undefined) "default" else args[0].toString(it.arena);
}

fn count(it: *Interpreter, _: Value, args: []const Value) Error!Value {
    const name = try label(it, args);
    const entry = try it.builtin_state.console.counts.getOrPut(it.arena, name);
    if (!entry.found_existing) {
        entry.key_ptr.* = try it.arena.dupe(u8, name);
        entry.value_ptr.* = 0;
    }
    entry.value_ptr.* += 1;
    try writeLine(it, false, try std.fmt.allocPrint(it.arena, "{s}: {d}", .{ name, entry.value_ptr.* }));
    return .undefined;
}

fn countReset(it: *Interpreter, _: Value, args: []const Value) Error!Value {
    // node warns about a count that doesn't exist with a process warning, which isn't output.
    if (it.builtin_state.console.counts.getPtr(try label(it, args))) |n| {
        n.* = 0;
    }
    return .undefined;
}

fn assert(it: *Interpreter, _: Value, args: []const Value) Error!Value {
    if (arg(args, 0).toBoolean()) {
        return .undefined;
    }
    const rest = if (args.len > 1) args[1..] else &.{};
    // Its message goes in front, as part of a format string if there is one.
    const data = try it.arena.alloc(Value, rest.len + @intFromBool(rest.len == 0 or rest[0] != .string));
    if (rest.len > 0 and rest[0] == .string) {
        @memcpy(data, rest);
        data[0] = .{ .string = try std.fmt.allocPrint(it.arena, "Assertion failed: {s}", .{rest[0].string}) };
    } else {
        data[0] = .{ .string = "Assertion failed" };
        @memcpy(data[1..], rest);
    }
    try writeLine(it, true, try format(it, data));
    return .undefined;
}
