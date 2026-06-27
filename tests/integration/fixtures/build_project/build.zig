const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const first_tests = b.addTest(.{
        .name = "first-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/first.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_first_tests = b.addRunArtifact(first_tests);

    const second_tests = b.addTest(.{
        .name = "second-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/second.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_second_tests = b.addRunArtifact(second_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_first_tests.step);
    test_step.dependOn(&run_second_tests.step);
}
