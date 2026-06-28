const std = @import("std");
const builtin = @import("builtin");
const core = @import("runner_core.zig");

const platform = if (builtin.os.tag == .windows)
    @import("platform/windows/platform.zig")
else
    @import("platform/posix/platform.zig");

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = runnerLogFn,
};

var log_level: std.log.Level = .err;
const log = std.log.scoped(.test_runner);

const neotest_input_path = "--neotest-input-path";
const neotest_results_path = "--neotest-results-path";
const neotest_source_path = "--neotest-source-path";
const test_runner_logs_path = "--test-runner-logs-path";
const test_runner_log_level = "--test-runner-log-level";

const Error = struct {
    message: []const u8,
    line: ?usize,
};

const TestResult = struct {
    test_name: []const u8,
    source_path: []const u8,
    output: ?[]const u8,
    status: []const u8,
    short: ?[]const u8,
    errors: ?[]Error,
};

pub fn runnerLogFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (scope == .test_runner and @intFromEnum(level) > @intFromEnum(log_level)) return;

    var buffer: [4096]u8 = undefined;
    const stderr = std.debug.lockStderr(&buffer);
    defer std.debug.unlockStderr();
    nosuspend stderr.file_writer.interface.print(
        "[" ++ comptime level.asText() ++ "] " ++ format ++ "\n",
        args,
    ) catch {};
}

/// Zig calls this root declaration from `std.testing.fuzz`.
///
/// Interactive fuzz-server mode is handled by Zig's default runner and is not
/// part of Neotest's selected-test protocol. Normal test runs execute the
/// supplied corpus and the same empty-input smoke case as Zig's 0.16 runner.
pub inline fn fuzz(
    context: anytype,
    comptime testOne: fn (context: @TypeOf(context), *std.testing.Smith) anyerror!void,
    options: std.testing.FuzzInputOptions,
) anyerror!void {
    for (options.corpus) |input| {
        var smith: std.testing.Smith = .{ .in = input };
        try testOne(context, &smith);
    }

    var smith: std.testing.Smith = .{ .in = "" };
    try testOne(context, &smith);
}

fn readFileAlloc(
    io: std.Io,
    allocator: std.mem.Allocator,
    absolute_path: []const u8,
) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io, absolute_path, .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    return reader.interface.allocRemaining(allocator, .unlimited);
}

fn writeResults(
    io: std.Io,
    absolute_path: []const u8,
    results: []const TestResult,
) !void {
    var file = try std.Io.Dir.createFileAbsolute(io, absolute_path, .{});
    defer file.close(io);

    var buffer: [65536]u8 = undefined;
    var writer = file.writer(io, &buffer);
    var json: std.json.Stringify = .{ .writer = &writer.interface };
    try json.write(results);
    try writer.interface.flush();
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var input_path: ?[]const u8 = null;
    var results_dir_path: ?[]const u8 = null;
    var source_path: ?[]const u8 = null;
    var logs_dir_path: ?[]const u8 = null;

    for (args, 0..) |arg, index| {
        if (std.mem.startsWith(u8, arg, "--seed=")) {
            std.testing.random_seed = try std.fmt.parseUnsigned(u32, arg["--seed=".len..], 0);
            continue;
        }
        const value = if (index + 1 < args.len) args[index + 1] else continue;
        if (std.mem.eql(u8, neotest_input_path, arg)) {
            input_path = value;
        } else if (std.mem.eql(u8, neotest_results_path, arg)) {
            results_dir_path = value;
        } else if (std.mem.eql(u8, neotest_source_path, arg)) {
            source_path = value;
        } else if (std.mem.eql(u8, test_runner_logs_path, arg)) {
            logs_dir_path = value;
        } else if (std.mem.eql(u8, test_runner_log_level, arg)) {
            log_level = core.zigLogLevel(try std.fmt.parseInt(u8, value, 0));
        }
    }

    const input_file_path = input_path orelse return error.MissingNeotestInputPath;
    const results_directory = results_dir_path orelse return error.MissingNeotestResultsPath;
    const logs_directory = logs_dir_path orelse return error.MissingTestRunnerLogsPath;

    const executable_path = try std.process.executablePathAlloc(init.io, allocator);
    defer allocator.free(executable_path);
    var logs_hasher = std.hash.Wyhash.init(0);
    std.hash.autoHashStrat(&logs_hasher, executable_path, .Deep);
    const logs_file_name = try std.fmt.allocPrint(allocator, "{d}", .{logs_hasher.final()});
    defer allocator.free(logs_file_name);
    const logs_file_path = try std.fs.path.join(
        allocator,
        &.{ logs_directory, logs_file_name },
    );
    defer allocator.free(logs_file_path);

    const logs_file = try platform.redirectStdErrToFile(init.io, logs_file_path);
    defer logs_file.close(init.io);
    defer platform.restoreStdErr() catch {};

    for (args, 0..) |arg, index| {
        log.debug("arg[{d}] = {s}", .{ index, arg });
    }

    const input_json = try readFileAlloc(init.io, allocator, input_file_path);
    defer allocator.free(input_json);
    var parsed_input = try std.json.parseFromSlice([]core.TestInput, allocator, input_json, .{});
    defer parsed_input.deinit();
    const test_inputs = parsed_input.value;

    var results_hasher = std.hash.Wyhash.init(0);
    std.hash.autoHashStrat(&results_hasher, executable_path, .Deep);
    for (builtin.test_functions) |test_function| {
        std.hash.autoHashStrat(&results_hasher, test_function.name, .Deep);
    }

    const results_file_name = try std.fmt.allocPrint(allocator, "{d}", .{results_hasher.final()});
    defer allocator.free(results_file_name);
    const results_file_path = try std.fs.path.join(
        allocator,
        &.{ results_directory, results_file_name },
    );
    defer allocator.free(results_file_path);

    var results: std.ArrayList(TestResult) = .empty;
    defer results.deinit(allocator);
    var result_arena = std.heap.ArenaAllocator.init(allocator);
    defer result_arena.deinit();
    const result_allocator = result_arena.allocator();
    const consumed_inputs = try allocator.alloc(bool, test_inputs.len);
    defer allocator.free(consumed_inputs);
    @memset(consumed_inputs, false);
    var processed_tests: usize = 0;

    for (builtin.test_functions) |test_function| {
        if (processed_tests == test_inputs.len) break;

        const function: *const fn () anyerror!void = test_function.func;
        const test_name = core.testFunctionName(test_function.name);
        const input_index = (if (source_path) |standalone_source_path| index: {
            for (test_inputs, consumed_inputs, 0..) |test_input, consumed, index| {
                if (!consumed and
                    std.mem.eql(u8, test_input.test_name, test_name) and
                    std.mem.eql(u8, test_input.source_path, standalone_source_path))
                {
                    break :index index;
                }
            }
            break :index null;
        } else core.findBuildTestInput(
            test_function.name,
            test_name,
            test_inputs,
            consumed_inputs,
        )) orelse continue;
        const test_input = test_inputs[input_index];
        consumed_inputs[input_index] = true;
        processed_tests += 1;

        log.debug("Running test {s}::{s}", .{ test_input.source_path, test_input.test_name });

        var output_file = try platform.redirectStdErrToFile(init.io, test_input.output_path);

        std.testing.environ = init.minimal.environ;
        std.testing.allocator_instance = .init;
        std.testing.io_instance = .init(std.testing.allocator, .{
            .argv0 = .init(init.minimal.args),
            .environ = init.minimal.environ,
        });

        const started_at = std.Io.Clock.awake.now(init.io);
        var test_error: ?anyerror = null;
        function() catch |err| {
            test_error = err;
            if (err != error.SkipZigTest) {
                if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            }
        };
        std.testing.io_instance.deinit();
        const leak_count = std.testing.allocator_instance.detectLeaks();
        std.testing.allocator_instance.deinitWithoutLeakChecks();
        const duration_ns = started_at.untilNow(init.io, .awake).nanoseconds;

        try platform.redirectStdErr(logs_file);
        output_file.close(init.io);

        const output = readFileAlloc(init.io, allocator, test_input.output_path) catch
            try allocator.dupe(u8, "Could not read output file.");
        defer allocator.free(output);
        const leaked = leak_count != 0;
        const status = core.finalStatus(test_error, leaked);

        var errors: ?[]Error = null;
        var short: []const u8 = undefined;
        switch (status) {
            .passed => {
                short = try std.fmt.allocPrint(
                    result_allocator,
                    "Test passed in {d}ms",
                    .{@divTrunc(duration_ns, std.time.ns_per_ms)},
                );
            },
            .skipped => {
                short = "Skipped";
                const error_list = try result_allocator.alloc(Error, 1);
                error_list[0] = .{ .message = "Skipped", .line = null };
                errors = error_list;
            },
            .failed => {
                if (test_error) |err| {
                    const error_line = core.traceSourceLine(output, test_input.source_path);
                    const message = try result_allocator.dupe(u8, core.failureMessage(err, output));
                    short = message;
                    const error_list = try result_allocator.alloc(Error, 1);
                    error_list[0] = .{ .message = message, .line = error_line };
                    errors = error_list;
                } else {
                    short = "Memory leaked (see full output for more details)";
                }
            },
        }

        try results.append(allocator, .{
            .source_path = test_input.source_path,
            .test_name = test_input.test_name,
            .output = test_input.output_path,
            .status = status.text(),
            .short = short,
            .errors = errors,
        });
    }

    try platform.restoreStdErr();
    try writeResults(init.io, results_file_path, results.items);
}
