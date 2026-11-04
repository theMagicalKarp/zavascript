//! `console.log` and friends. Arguments are formatted like node: strings as-is, everything else
//! as `util.inspect` shows it, separated by spaces. Format specifiers (`%s`, `%d`) come later.

const std = @import("std");
const value = @import("../value.zig");
const Interpreter = @import("../Interpreter.zig");
const Value = value.Value;

pub fn install(interpreter: *Interpreter) Interpreter.Error!void {
    const console = try interpreter.arena.create(value.Object);
    console.* = .{ .tag = "Object [console]" };
    inline for (.{ .{ "log", false }, .{ "info", false }, .{ "debug", false }, .{ "error", true }, .{ "warn", true } }) |entry| {
        const function = comptime &value.NativeFunction{
            .name = entry[0],
            .source = "function " ++ entry[0] ++ "() { [native code] }",
            .call = writer(entry[1]),
        };
        try console.properties.put(interpreter.arena, entry[0], .{ .native_function = function });
    }
    try interpreter.globals.put(interpreter.arena, "console", .{ .object = console });
}

fn writer(comptime to_stderr: bool) *const fn (*anyopaque, Value, []const Value) anyerror!Value {
    return struct {
        fn call(context: *anyopaque, _: Value, args: []const Value) anyerror!Value {
            const interpreter = Interpreter.fromContext(context);
            const out = if (to_stderr) interpreter.stderr else interpreter.stdout;
            try print(out, args);
            return .undefined;
        }
    }.call;
}

pub fn print(out: *std.Io.Writer, args: []const Value) std.Io.Writer.Error!void {
    for (args, 0..) |arg, i| {
        if (i > 0) try out.writeByte(' ');
        switch (arg) {
            .string => |s| try out.writeAll(s),
            else => try value.inspect(out, arg),
        }
    }
    try out.writeByte('\n');
}
