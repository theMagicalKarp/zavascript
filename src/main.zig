const std = @import("std");
const zavascript = @import("zavascript");

const usage =
    \\Usage: zavascript [options] [file.ts]
    \\
    \\Type checks and runs a TypeScript file. With no file, starts a REPL, or
    \\runs standard input when it isn't a terminal. A file of `-` also reads
    \\standard input.
    \\
    \\Options:
    \\  --check     type check only; don't run
    \\  -h, --help  print this help and exit
    \\
;

const Options = struct {
    path: ?[]const u8 = null,
    check_only: bool = false,
};

fn usageError(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("error: " ++ fmt ++ "\n\n" ++ usage, args);
    std.process.exit(2);
}

fn parseOptions(io: std.Io, args: std.process.Args, arena: std.mem.Allocator) !Options {
    var options: Options = .{};
    var it = try args.iterateAllocator(arena);
    _ = it.skip();
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--check")) {
            options.check_only = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try std.Io.File.stdout().writeStreamingAll(io, usage);
            std.process.exit(0);
        } else if (arg.len > 1 and arg[0] == '-') {
            usageError("unknown option: {s}", .{arg});
        } else if (options.path != null) {
            usageError("only one file can be given", .{});
        } else {
            options.path = try arena.dupe(u8, arg);
        }
    }
    return options;
}

/// The interpreter recurses on the native stack, so programs run on a thread with a big one; it
/// only uses address space until it's touched.
const thread_stack = 64 * 1024 * 1024;

pub fn main(init: std.process.Init) !void {
    var result: anyerror!void = {};
    const thread = try std.Thread.spawn(.{ .stack_size = thread_stack }, struct {
        fn run(i: std.process.Init, out: *anyerror!void) void {
            out.* = mainThread(i);
        }
    }.run, .{ init, &result });
    thread.join();
    return result;
}

fn mainThread(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const options = try parseOptions(io, init.minimal.args, init.arena.allocator());

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    var seed: u64 = undefined;
    io.random(std.mem.asBytes(&seed));
    var runtime: zavascript.Runtime = try .init(gpa, .{ .stdout = stdout, .stderr = stderr, .max_stack = thread_stack - 4 * 1024 * 1024, .random_seed = seed });
    defer runtime.deinit();

    const stdin = std.Io.File.stdin();
    const exit_code: u8 = if (options.path) |path| blk: {
        if (std.mem.eql(u8, path, "-")) {
            break :blk try runStdin(io, gpa, &runtime, stdin, options, stdout, stderr);
        }
        break :blk try runFile(io, gpa, &runtime, path, options, stdout, stderr);
    } else if (try stdin.isTty(io))
        try repl(io, &runtime, stdin, stdout, stderr)
    else
        try runStdin(io, gpa, &runtime, stdin, options, stdout, stderr);

    try stdout.flush();
    try stderr.flush();
    if (exit_code != 0) {
        std.process.exit(exit_code);
    }
}

fn runFile(io: std.Io, gpa: std.mem.Allocator, runtime: *zavascript.Runtime, path: []const u8, options: Options, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !u8 {
    const source = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024 * 1024)) catch |err| {
        try stderr.print("error: can't read {s}: {t}\n", .{ path, err });
        return 1;
    };
    defer gpa.free(source);
    return runSource(runtime, path, source, options, stdout, stderr);
}

fn runStdin(io: std.Io, gpa: std.mem.Allocator, runtime: *zavascript.Runtime, stdin: std.Io.File, options: Options, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !u8 {
    var buffer: [4096]u8 = undefined;
    var reader = stdin.reader(io, &buffer);
    const source = try reader.interface.allocRemaining(gpa, .limited(64 * 1024 * 1024));
    defer gpa.free(source);
    return runSource(runtime, "<stdin>", source, options, stdout, stderr);
}

fn runSource(runtime: *zavascript.Runtime, path: []const u8, source: []const u8, options: Options, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !u8 {
    const result = if (options.check_only) runtime.check(path, source) else if (runtime.run(path, source)) |_| {} else |err| err;
    result catch |err| switch (err) {
        error.CompileError => {
            // Flush program output first so diagnostics don't interleave with it.
            try stdout.flush();
            try runtime.diagnostics.render(stderr);
            return 1;
        },
        error.RuntimeError => {
            try stdout.flush();
            try runtime.exception().?.render(stderr);
            return 1;
        },
        else => return err,
    };
    return 0;
}

const repl_help =
    \\.help   show this help
    \\.exit   leave the REPL (or press Ctrl+D)
    \\
;

fn repl(io: std.Io, runtime: *zavascript.Runtime, stdin: std.Io.File, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !u8 {
    var buffer: [64 * 1024]u8 = undefined;
    var reader = stdin.reader(io, &buffer);
    try stdout.writeAll("Welcome to zavascript. Type .help for help.\n");
    while (true) {
        try stdout.writeAll("> ");
        try stdout.flush();
        const line = reader.interface.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                try stderr.writeAll("error: line too long\n");
                try stderr.flush();
                continue;
            },
            else => return err,
        } orelse break;
        const input = std.mem.trim(u8, line, " \t\r");
        if (input.len == 0) {
            continue;
        }
        if (std.mem.eql(u8, input, ".exit")) {
            break;
        }
        if (std.mem.eql(u8, input, ".help")) {
            try stdout.writeAll(repl_help);
            continue;
        }
        if (runtime.run("repl", input)) |value| {
            try runtime.inspect(stdout, value);
            try stdout.writeByte('\n');
        } else |err| {
            switch (err) {
                error.CompileError => {
                    try stdout.flush();
                    try runtime.diagnostics.render(stderr);
                    try stderr.flush();
                },
                error.RuntimeError => {
                    try stdout.flush();
                    try stderr.print("{f}\n", .{runtime.exception().?});
                    try stderr.flush();
                },
                else => return err,
            }
        }
    }
    try stdout.writeByte('\n');
    return 0;
}
