const std = @import("std");
const core = @import("runner_core");

test "normalizes compiler test function names" {
    try std.testing.expectEqualStrings(
        "test.handles a prefixed name",
        core.testFunctionName("root.module.test.handles a prefixed name"),
    );
    try std.testing.expectEqualStrings(
        "decltest.Widget",
        core.testFunctionName("root.module.decltest.Widget"),
    );
    try std.testing.expectEqualStrings(
        "plain name",
        core.testFunctionName("plain name"),
    );
}

test "matches input by exact test name and source path" {
    const inputs = [_]core.TestInput{
        .{
            .test_name = "test.same",
            .source_path = "/project/a.zig",
            .output_path = "/tmp/a",
        },
        .{
            .test_name = "test.same",
            .source_path = "/project/b.zig",
            .output_path = "/tmp/b",
        },
    };

    const found = core.findTestInput("test.same", "/project/b.zig", &inputs);
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("/tmp/b", found.?.output_path);
    try std.testing.expect(core.findTestInput("test.same.extra", "/project/b.zig", &inputs) == null);
}

test "build matching selects a unique normalized test name without source symbols" {
    const inputs = [_]core.TestInput{
        .{
            .test_name = "test.unique",
            .source_path = "/project/src/example.zig",
            .output_path = "/tmp/unique",
        },
        .{
            .test_name = "test.other",
            .source_path = "/project/src/other.zig",
            .output_path = "/tmp/other",
        },
    };
    const consumed = [_]bool{ false, false };

    try std.testing.expectEqual(
        @as(?usize, 0),
        core.findBuildTestInput("example.test.unique", "test.unique", &inputs, &consumed),
    );
}

test "build matching resolves duplicate names from raw module prefix and source basename" {
    const inputs = [_]core.TestInput{
        .{
            .test_name = "test.same",
            .source_path = "/project/src/alpha.zig",
            .output_path = "/tmp/alpha",
        },
        .{
            .test_name = "test.same",
            .source_path = "/project/src/beta.zig",
            .output_path = "/tmp/beta",
        },
    };
    const consumed = [_]bool{ false, false };

    try std.testing.expectEqual(
        @as(?usize, 1),
        core.findBuildTestInput("root.beta.test.same", "test.same", &inputs, &consumed),
    );
}

test "build matching skips unresolved ambiguity and consumed inputs" {
    const inputs = [_]core.TestInput{
        .{
            .test_name = "test.same",
            .source_path = "/project/src/alpha.zig",
            .output_path = "/tmp/alpha",
        },
        .{
            .test_name = "test.same",
            .source_path = "/project/src/beta.zig",
            .output_path = "/tmp/beta",
        },
    };
    const available = [_]bool{ false, false };
    const first_consumed = [_]bool{ true, false };

    try std.testing.expectEqual(
        @as(?usize, null),
        core.findBuildTestInput("root.unknown.test.same", "test.same", &inputs, &available),
    );
    try std.testing.expectEqual(
        @as(?usize, 1),
        core.findBuildTestInput("root.unknown.test.same", "test.same", &inputs, &first_consumed),
    );
}

test "maps Neovim log levels to Zig log levels" {
    try std.testing.expectEqual(std.log.Level.debug, core.zigLogLevel(0));
    try std.testing.expectEqual(std.log.Level.debug, core.zigLogLevel(1));
    try std.testing.expectEqual(std.log.Level.info, core.zigLogLevel(2));
    try std.testing.expectEqual(std.log.Level.warn, core.zigLogLevel(3));
    try std.testing.expectEqual(std.log.Level.err, core.zigLogLevel(4));
    try std.testing.expectEqual(std.log.Level.err, core.zigLogLevel(5));
    try std.testing.expectEqual(std.log.Level.debug, core.zigLogLevel(99));
}

test "extracts a zero-based source line from a Zig error trace" {
    const trace =
        \\error: TestUnexpectedResult
        \\/project/src/example.zig:42:19: 0x123 in test.failure
        \\    return error.TestUnexpectedResult;
        \\/opt/zig/lib/std/start.zig:10:1: 0x456 in main
    ;

    try std.testing.expectEqual(@as(?usize, 41), core.traceSourceLine(trace, "/project/src/example.zig"));
}

test "extracts a source line when a Windows path contains a drive colon" {
    const trace =
        \\error: TestExpectedEqual
        \\C:\project\src\example.zig:7:5: 0x123 in test.failure
    ;

    try std.testing.expectEqual(@as(?usize, 6), core.traceSourceLine(trace, "C:\\project\\src\\example.zig"));
}

test "matches Windows trace paths across slash styles" {
    const trace =
        \\C:\project\src\example.zig:9:3: 0x123 in test.failure
    ;

    try std.testing.expectEqual(@as(?usize, 8), core.traceSourceLine(trace, "C:/project/src/example.zig"));
}

test "does not guess a line from a different source file" {
    const trace =
        \\/project/src/dependency.zig:42:19: 0x123 in helper
    ;

    try std.testing.expectEqual(@as(?usize, null), core.traceSourceLine(trace, "/project/src/example.zig"));
}

test "failure takes precedence over a leak and success is emitted once" {
    try std.testing.expectEqual(
        core.Status.failed,
        core.finalStatus(error.TestUnexpectedResult, true),
    );
    try std.testing.expectEqual(
        core.Status.skipped,
        core.finalStatus(error.SkipZigTest, false),
    );
    try std.testing.expectEqual(
        core.Status.failed,
        core.finalStatus(error.SkipZigTest, true),
    );
    try std.testing.expectEqual(
        core.Status.failed,
        core.finalStatus(null, true),
    );
    try std.testing.expectEqual(
        core.Status.passed,
        core.finalStatus(null, false),
    );
}
