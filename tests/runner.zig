//! Runs every conformance case in `tests/cases` through the library and checks it against the
//! expectations written in its comments:
//!
//!   console.log(1 + 2); //> 3          one expected line of stdout, in source order
//!   const n: number = "x"; //! TS2322  diagnostics expected to start on this line
//!
//! A case that expects diagnostics must not also expect output, since it never runs.
//! `tests/oracle.mjs` checks the same annotations against tsc and node.
//!
//! Usage: conformance <cases dir> [filter]   (only cases whose path contains `filter`)

const std = @import("std");
const zavascript = @import("zavascript");

const Expectation = struct {
    stdout: []const u8,
    /// Sorted `line:code` strings, e.g. `3:TS2322`.
    diagnostics: []const []const u8,
};

/// Reads the `//>` and `//!` annotations out of a case's source.
fn parseExpectation(arena: std.mem.Allocator, source: []const u8) !Expectation {
    var stdout: std.ArrayList(u8) = .empty;
    var diagnostics: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, source, '\n');
    var line_number: usize = 0;
    while (lines.next()) |raw_line| {
        line_number += 1;
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (std.mem.indexOf(u8, line, "//>")) |i| {
            var text = line[i + 3 ..];
            if (text.len > 0 and text[0] == ' ') {
                text = text[1..];
            }
            try stdout.appendSlice(arena, text);
            try stdout.append(arena, '\n');
        } else if (std.mem.indexOf(u8, line, "//!")) |i| {
            var codes = std.mem.tokenizeAny(u8, line[i + 3 ..], " \t");
            while (codes.next()) |code| {
                try diagnostics.append(arena, try std.fmt.allocPrint(arena, "{d}:{s}", .{ line_number, code }));
            }
        }
    }
    std.mem.sort([]const u8, diagnostics.items, {}, lessThanString);
    return .{ .stdout = stdout.items, .diagnostics = diagnostics.items };
}

fn lessThanString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

const Outcome = union(enum) {
    pass,
    fail: []const u8,
};

fn runCase(gpa: std.mem.Allocator, arena: std.mem.Allocator, path: []const u8, source: []const u8) !Outcome {
    const expected = try parseExpectation(arena, source);
    if (expected.diagnostics.len > 0 and expected.stdout.len > 0) {
        return .{ .fail = "case expects both diagnostics (//!) and output (//>); a case with errors never runs" };
    }

    var stdout: std.Io.Writer.Allocating = .init(arena);
    var stderr: std.Io.Writer.Allocating = .init(arena);
    var runtime: zavascript.Runtime = try .init(gpa, .{ .stdout = &stdout.writer, .stderr = &stderr.writer, .max_stack = thread_stack - 4 * 1024 * 1024 });
    defer runtime.deinit();

    var report: std.Io.Writer.Allocating = .init(arena);
    const w = &report.writer;

    _ = runtime.run(path, source) catch |err| switch (err) {
        error.CompileError => {
            var actual: std.ArrayList([]const u8) = .empty;
            for (runtime.diagnostics.items()) |d| {
                const loc = d.source.location(d.start);
                try actual.append(arena, try std.fmt.allocPrint(arena, "{d}:{f}", .{ loc.line, d.code }));
            }
            std.mem.sort([]const u8, actual.items, {}, lessThanString);
            if (equalLists(expected.diagnostics, actual.items)) {
                return .pass;
            }
            try w.writeAll("diagnostics differ\n  expected:");
            for (expected.diagnostics) |d| {
                try w.print(" {s}", .{d});
            }
            try w.writeAll("\n  actual:  ");
            for (actual.items) |d| {
                try w.print(" {s}", .{d});
            }
            try w.writeAll("\n");
            try runtime.diagnostics.render(w);
            return .{ .fail = report.written() };
        },
        error.RuntimeError => {
            try w.print("threw: {f}\n", .{runtime.exception().?});
            return .{ .fail = report.written() };
        },
        else => return err,
    };

    if (expected.diagnostics.len > 0) {
        try w.writeAll("expected diagnostics, but it compiled and ran:");
        for (expected.diagnostics) |d| {
            try w.print(" {s}", .{d});
        }
        return .{ .fail = report.written() };
    }
    if (std.mem.eql(u8, expected.stdout, stdout.written())) {
        return .pass;
    }
    try w.writeAll("stdout differs\n");
    try diffLines(w, expected.stdout, stdout.written());
    return .{ .fail = report.written() };
}

fn equalLists(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) {
        return false;
    }
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x, y)) {
            return false;
        }
    }
    return true;
}

/// A line-by-line comparison; enough to spot the first difference in small outputs.
fn diffLines(w: *std.Io.Writer, expected: []const u8, actual: []const u8) !void {
    var e = std.mem.splitScalar(u8, expected, '\n');
    var a = std.mem.splitScalar(u8, actual, '\n');
    var line: usize = 1;
    while (true) : (line += 1) {
        const x = e.next();
        const y = a.next();
        if (x == null and y == null) {
            break;
        }
        const same = x != null and y != null and std.mem.eql(u8, x.?, y.?);
        if (same) {
            try w.print("    {d: >3}   {s}\n", .{ line, x.? });
        } else {
            if (x) |text| {
                try w.print("  - {d: >3}   {s}\n", .{ line, text });
            }
            if (y) |text| {
                try w.print("  + {d: >3}   {s}\n", .{ line, text });
            }
        }
    }
}

/// Cases run on a thread with a big stack, like the CLI's, so deep recursion works the same.
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
    const arena = init.arena.allocator();

    var args = try init.minimal.args.iterateAllocator(arena);
    _ = args.skip();
    const cases_path = args.next() orelse return error.MissingCasesDirectory;
    const filter = args.next();

    var dir = try std.Io.Dir.cwd().openDir(io, cases_path, .{ .iterate = true });
    defer dir.close(io);

    var paths: std.ArrayList([]const u8) = .empty;
    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) {
            continue;
        }
        if (!std.mem.endsWith(u8, entry.path, ".ts") or std.mem.endsWith(u8, entry.path, ".d.ts")) {
            continue;
        }
        if (filter) |f| {
            if (std.mem.indexOf(u8, entry.path, f) == null) {
                continue;
            }
        }
        try paths.append(arena, try arena.dupe(u8, entry.path));
    }
    std.mem.sort([]const u8, paths.items, {}, lessThanString);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_writer.interface;

    var passed: usize = 0;
    var failed: usize = 0;
    for (paths.items) |path| {
        var case_arena: std.heap.ArenaAllocator = .init(gpa);
        defer case_arena.deinit();
        const source = try dir.readFileAlloc(io, path, case_arena.allocator(), .limited(16 * 1024 * 1024));
        switch (try runCase(gpa, case_arena.allocator(), path, source)) {
            .pass => passed += 1,
            .fail => |why| {
                failed += 1;
                try out.print("FAIL {s}\n{s}\n", .{ path, why });
            },
        }
    }
    try out.print("conformance: {d} passed, {d} failed\n", .{ passed, failed });
    try out.flush();
    if (failed > 0) {
        std.process.exit(1);
    }
}
