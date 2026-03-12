const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main library module
    const zigzag_mod = b.addModule("zigzag", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Examples
    const examples = [_][]const u8{
        "hello_world",
        "counter",
        "todo_list",
        "text_editor",
        "file_browser",
        "dashboard",
        "charts",
        "showcase",
        "focus_form",
        "modal",
        "tooltip",
        "tabs",
        "clipboard_osc52",
    };

    for (examples) |example_name| {
        const example = b.addExecutable(.{
            .name = example_name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}.zig", .{example_name})),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "zigzag", .module = zigzag_mod },
                },
            }),
        });
        b.installArtifact(example);

        const run_cmd = b.addRunArtifact(example);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        const run_step = b.step(
            b.fmt("run-{s}", .{example_name}),
            b.fmt("Run the {s} example", .{example_name}),
        );
        run_step.dependOn(&run_cmd.step);
    }

    // Tests
    const test_files = [_][]const u8{
        "tests/style_tests.zig",
        "tests/input_tests.zig",
        "tests/layout_tests.zig",
        "tests/unicode_tests.zig",
        "tests/program_tests.zig",
        "tests/focus_tests.zig",
        "tests/modal_tests.zig",
        "tests/tooltip_tests.zig",
        "tests/tab_group_tests.zig",
        "tests/chart_tests.zig",
        "tests/viewport_tests.zig",
    };

    const test_step = b.step("test", "Run unit tests");

    for (test_files) |test_file| {
        const unit_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(test_file),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "zigzag", .module = zigzag_mod },
                },
            }),
        });

        const run_unit_tests = b.addRunArtifact(unit_tests);
        test_step.dependOn(&run_unit_tests.step);
    }

    // Also run tests on the main library
    const lib_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_lib_tests = b.addRunArtifact(lib_tests);
    test_step.dependOn(&run_lib_tests.step);
}
