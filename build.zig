const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("zavascript", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "zavascript",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zavascript", .module = mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run a file, or the REPL when no file is given");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const test_step = b.step("test", "Run unit tests and the conformance cases");

    const mod_tests = b.addTest(.{ .root_module = mod });
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);

    const conformance = b.addExecutable(.{
        .name = "conformance",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/runner.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zavascript", .module = mod },
            },
        }),
    });
    const run_conformance = b.addRunArtifact(conformance);
    run_conformance.addDirectoryArg(b.path("tests/cases"));
    run_conformance.addPassthruArgs();
    test_step.dependOn(&run_conformance.step);

    const bench = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/runner.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zavascript", .module = mod },
            },
        }),
    });
    const run_bench = b.addRunArtifact(bench);
    run_bench.addDirectoryArg(b.path("bench/cases"));
    run_bench.setCwd(b.path("."));
    run_bench.addArg(".bench");
    run_bench.addPassthruArgs();
    run_bench.has_side_effects = true;
    const bench_step = b.step("bench", "Run the benchmarks (use -Doptimize=fast)");
    bench_step.dependOn(&run_bench.step);

    const braces = b.addExecutable(.{
        .name = "braces",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/braces.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = braces.root_module })).step);

    const lint_step = b.step("lint", "Check that if/else/while/for bodies are blocks");
    const lint_fix_step = b.step("lint-fix", "Wrap if/else/while/for bodies in blocks");
    for ([_]struct { *std.Build.Step, bool }{ .{ lint_step, false }, .{ lint_fix_step, true } }) |entry| {
        const step, const fix = entry;
        const run_braces = b.addRunArtifact(braces);
        run_braces.setCwd(b.path("."));
        if (fix) {
            run_braces.addArg("--fix");
        }
        run_braces.addArgs(&.{ "build.zig", "src", "tests", "bench", "tools" });
        run_braces.has_side_effects = true;
        step.dependOn(&run_braces.step);
    }
}
