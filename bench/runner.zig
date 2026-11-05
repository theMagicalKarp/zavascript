//! Times each benchmark case, phase by phase, and compares the medians with a saved baseline.
//!
//! Usage: bench <cases dir> <results dir> [filter]
//!
//! Writes `<results dir>/latest.json`. If `<results dir>/baseline.json` exists, each median is
//! shown with its change from the baseline; `mise run bench:baseline` saves the latest run as the
//! new baseline. Build with -Doptimize=fast, or the numbers mean little.

const std = @import("std");
const builtin = @import("builtin");
const zavascript = @import("zavascript");

/// Keep sampling a case until both limits are reached, or `max_samples`.
const min_samples = 10;
const max_samples = 1000;
const min_time_ns = 300 * std.time.ns_per_ms;

const Phase = enum { compile, run };

const Result = struct {
    name: []const u8,
    min: [2]u64,
    median: [2]u64,
};

const Saved = struct {
    cases: []const struct { name: []const u8, compile_ns: u64, run_ns: u64 },
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var args = try init.minimal.args.iterateAllocator(arena);
    _ = args.skip();
    const cases_path = args.next() orelse return error.MissingCasesDirectory;
    const results_path = args.next() orelse return error.MissingResultsDirectory;
    const filter = args.next();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_writer.interface;
    if (builtin.mode == .debug) {
        try out.writeAll("warning: this is a Debug build; use -Doptimize=fast\n\n");
    }

    var dir = try std.Io.Dir.cwd().openDir(io, cases_path, .{ .iterate = true });
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".ts")) {
            continue;
        }
        if (filter) |f| {
            if (std.mem.indexOf(u8, entry.name, f) == null) {
                continue;
            }
        }
        try names.append(arena, try arena.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    var results_dir = try std.Io.Dir.cwd().createDirPathOpen(io, results_path, .{});
    defer results_dir.close(io);
    const baseline = loadBaseline(io, arena, results_dir);

    try out.print("{s: <28} {s: <8} {s: >12} {s: >12} {s: >12} {s: >8}\n", .{ "case", "phase", "min", "median", "baseline", "change" });
    var results: std.ArrayList(Result) = .empty;
    for (names.items) |name| {
        const source = try dir.readFileAlloc(io, name, arena, .limited(16 * 1024 * 1024));
        const result = try measure(io, gpa, name, source);
        try results.append(arena, result);
        for ([_]Phase{ .compile, .run }) |phase| {
            const i = @backingInt(phase);
            var min_buffer: [32]u8 = undefined;
            var median_buffer: [32]u8 = undefined;
            try out.print("{s: <28} {t: <8} {s: >12} {s: >12}", .{
                if (phase == .compile) name else "",
                phase,
                fmtNs(&min_buffer, result.min[i]),
                fmtNs(&median_buffer, result.median[i]),
            });
            if (baselineFor(baseline, name, phase)) |base| {
                var base_buffer: [32]u8 = undefined;
                const change = (@as(f64, @floatFromInt(result.median[i])) / @as(f64, @floatFromInt(base)) - 1) * 100;
                try out.print(" {s: >12} {d: >7.1}%", .{ fmtNs(&base_buffer, base), change });
            }
            try out.writeAll("\n");
        }
    }

    // Save the run so it can be compared against later or promoted to the baseline.
    var json: std.Io.Writer.Allocating = .init(arena);
    var cases_json: std.ArrayList(struct { name: []const u8, compile_ns: u64, run_ns: u64 }) = .empty;
    for (results.items) |r| {
        try cases_json.append(arena, .{ .name = r.name, .compile_ns = r.median[0], .run_ns = r.median[1] });
    }
    try std.json.Stringify.value(.{ .cases = cases_json.items }, .{ .whitespace = .indent_2 }, &json.writer);
    try results_dir.writeFile(io, .{ .sub_path = "latest.json", .data = json.written() });
    try out.print("\nwrote {s}/latest.json\n", .{results_path});
    try out.flush();
}

fn measure(io: std.Io, gpa: std.mem.Allocator, name: []const u8, source: []const u8) !Result {
    var samples: [2]std.ArrayList(u64) = .{ .empty, .empty };
    defer for (&samples) |*s| s.deinit(gpa);
    var discard_buffer: [256]u8 = undefined;
    var discard: std.Io.Writer.Discarding = .init(&discard_buffer);

    var total: u64 = 0;
    // One untimed warm-up run, then sample.
    var n: usize = 0;
    while (n < max_samples and (n <= min_samples or total < min_time_ns)) : (n += 1) {
        var runtime: zavascript.Runtime = try .init(gpa, .{ .stdout = &discard.writer, .stderr = &discard.writer });
        defer runtime.deinit();
        const start = std.Io.Timestamp.now(io, .awake);
        const program = runtime.compile(name, source) catch |err| {
            if (err == error.CompileError) {
                std.debug.print("{s} doesn't compile:\n", .{name});
                for (runtime.diagnostics.items()) |d| {
                    std.debug.print("{f}\n", .{d});
                }
            }
            return err;
        };
        const compiled = std.Io.Timestamp.now(io, .awake);
        _ = try runtime.execute(program);
        const finished = std.Io.Timestamp.now(io, .awake);
        if (n == 0) {
            continue;
        }
        const compile_ns: u64 = @intCast(start.durationTo(compiled).nanoseconds);
        const run_ns: u64 = @intCast(compiled.durationTo(finished).nanoseconds);
        try samples[0].append(gpa, compile_ns);
        try samples[1].append(gpa, run_ns);
        total += compile_ns + run_ns;
    }

    var result: Result = .{ .name = name, .min = undefined, .median = undefined };
    for (&samples, 0..) |*s, i| {
        std.mem.sort(u64, s.items, {}, std.sort.asc(u64));
        result.min[i] = s.items[0];
        result.median[i] = s.items[s.items.len / 2];
    }
    return result;
}

fn loadBaseline(io: std.Io, arena: std.mem.Allocator, dir: std.Io.Dir) ?Saved {
    const text = dir.readFileAlloc(io, "baseline.json", arena, .limited(1024 * 1024)) catch return null;
    return std.json.parseFromSliceLeaky(Saved, arena, text, .{ .ignore_unknown_fields = true }) catch null;
}

fn baselineFor(baseline: ?Saved, name: []const u8, phase: Phase) ?u64 {
    const saved = baseline orelse return null;
    for (saved.cases) |c| {
        if (std.mem.eql(u8, c.name, name)) {
            return switch (phase) {
                .compile => c.compile_ns,
                .run => c.run_ns,
            };
        }
    }
    return null;
}

/// Formats a duration with a unit that keeps it readable, e.g. `12.3µs`.
fn fmtNs(buffer: *[32]u8, ns: u64) []const u8 {
    const f: f64 = @floatFromInt(ns);
    return (if (ns < 1_000)
        std.fmt.bufPrint(buffer, "{d}ns", .{ns})
    else if (ns < 1_000_000)
        std.fmt.bufPrint(buffer, "{d:.1}µs", .{f / 1e3})
    else if (ns < 1_000_000_000)
        std.fmt.bufPrint(buffer, "{d:.2}ms", .{f / 1e6})
    else
        std.fmt.bufPrint(buffer, "{d:.2}s", .{f / 1e9})) catch unreachable;
}
