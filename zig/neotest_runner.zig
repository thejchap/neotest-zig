const std = @import("std");
const builtin = @import("builtin");

const platform = if (builtin.os.tag == .windows)
    @import("platform/windows/platform.zig")
else
    @import("platform/posix/platform.zig");

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = runnerLogFn,
};

var log_level: std.log.Level = std.log.Level.err;
const log = std.log.scoped(.test_runner);

pub fn runnerLogFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    if (scope == .test_runner and @intFromEnum(level) > @intFromEnum(log_level)) {
        return;
    }

    const prefix = "[" ++ comptime level.asText() ++ "] ";

    if (@hasDecl(std.debug, "lockStderr")) {
        // zig >= 0.16: lockStderr returns a LockedStderr value.
        var buf: [4096]u8 = undefined;
        const stderr = std.debug.lockStderr(&buf);
        defer std.debug.unlockStderr();
        nosuspend stderr.file_writer.interface.print(prefix ++ format ++ "\n", args) catch return;
    } else if (@hasDecl(std.debug, "lockStderrWriter")) {
        // zig >= 0.15: lockStderrWriter locks + returns *Writer in one call
        var buf: [4096]u8 = undefined;
        const stderr = std.debug.lockStderrWriter(&buf);
        defer std.debug.unlockStderrWriter();
        nosuspend stderr.print(prefix ++ format ++ "\n", args) catch return;
    } else {
        // zig <= 0.14
        lockStderr();
        defer unlockStdErr();
        const stderr = std.io.getStdErr().writer();
        nosuspend stderr.print(prefix ++ format ++ "\n", args) catch return;
    }
}

fn lockStderr() void {
    if (@hasDecl(std.debug, "lockStdErr")) {
        std.debug.lockStdErr();
    } else {
        // v0.12.0 compatability
        std.debug.getStderrMutex().lock();
    }
}

fn unlockStdErr() void {
    if (@hasDecl(std.debug, "unlockStdErr")) {
        std.debug.unlockStdErr();
    } else {
        // v0.12.0 compatability
        std.debug.getStderrMutex().unlock();
    }
}

const STATUS_FAILED = "failed";
const STATUS_PASSED = "passed";
const STATUS_SKIPPED = "skipped";

const NEOTEST_INPUT_PATH = "--neotest-input-path";
const NEOTEST_RESULTS_PATH = "--neotest-results-path";
const NEOTEST_SOURCE_PATH = "--neotest-source-path";
const TEST_RUNNER_LOGS_PATH = "--test-runner-logs-path";
const TEST_RUNNER_LOG_LEVEL = "--test-runner-log-level";

const TestInput = struct {
    test_name: []const u8,
    source_path: []const u8,
    output_path: []const u8,
};

const Error = struct {
    message: []const u8,
    line: ?usize,
};

const TestResult = struct {
    test_name: []const u8,
    source_path: []const u8,
    output: ?[]const u8, // A path to a file containing full output for this test.
    status: []const u8,
    short: ?[]const u8, // A shortened version of the output.
    errors: ?[]Error,
};

const Symbol = if (builtin.zig_version.minor == 13)
    std.debug.SymbolInfo
else
    std.debug.Symbol;

fn getSymbolName(symbol: Symbol) []const u8 {
    return if (builtin.zig_version.minor == 13)
        symbol.symbol_name
    else if (builtin.zig_version.minor >= 16)
        symbol.name orelse ""
    else
        symbol.name;
}

fn getSymbolFilename(symbol: Symbol) ?[]const u8 {
    return if (builtin.zig_version.minor == 13)
        if (symbol.line_info) |line_info| line_info.file_name else null
    else if (symbol.source_location) |source_location| source_location.file_name else null;
}

fn getSymbolLine(symbol: Symbol) ?u64 {
    return if (builtin.zig_version.minor == 13)
        if (symbol.line_info) |line_info| line_info.line else null
    else if (symbol.source_location) |source_location| source_location.line else null;
}

fn getTestInput(
    test_name: []const u8,
    source_path: []const u8,
    test_inputs: []TestInput,
) ?TestInput {
    log.debug("Got needle {s} -> {s}", .{ source_path, test_name });
    for (test_inputs) |test_input| {
        log.debug("Comparing to {s} -> {s} ", .{ test_input.source_path, test_input.test_name });
        if (std.mem.eql(u8, test_input.test_name, test_name) and std.mem.eql(u8, test_input.source_path, source_path)) {
            return test_input;
        }
    }
    return null;
}

fn getTestFunctionName(test_function_name: []const u8) []const u8 {
    if (std.mem.indexOf(u8, test_function_name, ".test.")) |index| {
        return test_function_name[index + 1 ..];
    }
    if (std.mem.indexOf(u8, test_function_name, ".decltest.")) |index| {
        return test_function_name[index + 1 ..];
    }
    return test_function_name;
}

fn getSymbolAtAddress(
    allocator: std.mem.Allocator,
    io: std.Io,
    debug_info: *std.debug.SelfInfo,
    address: usize,
) !Symbol {
    if (builtin.zig_version.minor >= 16) {
        var text_arena = std.heap.ArenaAllocator.init(allocator);
        defer text_arena.deinit();

        var symbols = try std.ArrayList(Symbol).initCapacity(allocator, 1);
        defer symbols.deinit(allocator);

        try debug_info.getSymbols(io, allocator, text_arena.allocator(), address, false, &symbols);
        if (symbols.items.len == 0) {
            return error.MissingDebugInfo;
        }

        const symbol = symbols.items[0];
        return .{
            .name = if (symbol.name) |name| try allocator.dupe(u8, name) else null,
            .compile_unit_name = if (symbol.compile_unit_name) |name| try allocator.dupe(u8, name) else null,
            .source_location = if (symbol.source_location) |source_location| .{
                .line = source_location.line,
                .column = source_location.column,
                .file_name = try allocator.dupe(u8, source_location.file_name),
            } else null,
        };
    } else {
        const module = try debug_info.getModuleForAddress(address);
        return try module.getSymbolAtAddress(allocator, address);
    }
}

fn getFuncSymbolInfo(allocator: std.mem.Allocator, io: std.Io, func: *const fn () anyerror!void) !Symbol {
    const debug_info = try std.debug.getSelfDebugInfo();
    const func_address = @intFromPtr(func);
    return getSymbolAtAddress(allocator, io, debug_info, func_address);
}

fn getZigLogLevelFromVimLogLevel(vim_log_level: u8) std.log.Level {
    return switch (vim_log_level) {
        0, 1 => std.log.Level.debug,
        2 => std.log.Level.info,
        3 => std.log.Level.warn,
        4, 5 => std.log.Level.err,
        else => std.log.Level.debug,
    };
}

pub inline fn fuzz(
    context: anytype,
    comptime testOne: fn (context: @TypeOf(context), input: []const u8) anyerror!void,
    options: std.testing.FuzzInputOptions,
) anyerror!void {
    _ = testOne;
    _ = options;
    return;
}

pub fn main(init: std.process.Init) !void {
    const DebugAllocator = if (@hasDecl(std.heap, "GeneralPurposeAllocator"))
        std.heap.GeneralPurposeAllocator
    else
        std.heap.DebugAllocator;
    var gpa = DebugAllocator(.{}){};
    // zig >= 0.15: ArrayList = unmanaged; managed moved to array_list.Managed
    // zig <= 0.14: ArrayList = managed (stores allocator)
    const TestResultList = if (builtin.zig_version.minor >= 15)
        std.array_list.Managed(TestResult)
    else
        std.ArrayList(TestResult);
    var test_results = TestResultList.init(gpa.allocator());
    const debug_info = try std.debug.getSelfDebugInfo();

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var input_path: []const u8 = undefined;
    var results_dir_path: []const u8 = undefined;
    var source_path: ?[]const u8 = null;
    var logs_dir_path: []const u8 = undefined;
    for (args, 0..) |arg, i| {
        if (std.mem.eql(u8, NEOTEST_INPUT_PATH, arg) and args.len > i + 1) {
            input_path = args[i + 1];
        } else if (std.mem.eql(u8, NEOTEST_RESULTS_PATH, arg) and args.len > i + 1) {
            results_dir_path = args[i + 1];
        } else if (std.mem.eql(u8, NEOTEST_SOURCE_PATH, arg) and args.len > i + 1) {
            source_path = args[i + 1];
        } else if (std.mem.eql(u8, TEST_RUNNER_LOGS_PATH, arg) and args.len > i + 1) {
            logs_dir_path = args[i + 1];
        } else if (std.mem.eql(u8, TEST_RUNNER_LOG_LEVEL, arg) and args.len > i + 1) {
            log_level = getZigLogLevelFromVimLogLevel(try std.fmt.parseInt(u8, args[i + 1], 0));
        }
    }

    const logs_file_path = blk: {
        const self_exe_path = try std.process.executablePathAlloc(init.io, gpa.allocator());
        defer gpa.allocator().free(self_exe_path);
        var hasher = std.hash.Wyhash.init(0);
        std.hash.autoHashStrat(&hasher, self_exe_path, .Deep);
        const hash_value = hasher.final();
        var hash_buffer: [64]u8 = undefined;
        const logs_file_name = try std.fmt.bufPrint(&hash_buffer, "{d}", .{hash_value});
        break :blk try std.fs.path.join(gpa.allocator(), &.{ logs_dir_path, logs_file_name });
    };
    const logs_file = try platform.redirectStdErrToFile(init.io, logs_file_path);
    defer logs_file.close(init.io);

    for (args, 0..) |arg, i| {
        log.debug("arg[{d}] = {s}", .{ i, arg });
    }

    const input = blk: {
        var input_file = try std.Io.Dir.openFileAbsolute(init.io, input_path, .{});
        defer input_file.close(init.io);
        var read_buf: [4096]u8 = undefined;
        var input_reader = input_file.reader(init.io, &read_buf);
        const input_json = try input_reader.interface.allocRemaining(gpa.allocator(), .unlimited);
        const input_parsed = try std.json.parseFromSlice([]TestInput, gpa.allocator(), input_json, .{});
        break :blk input_parsed.value;
    };

    // Get a hash value, which identifies this run step from others.
    // The hash value will be used as a name for test results file.
    var hasher = std.hash.Wyhash.init(0);
    log.debug("\n--------------\nFOUND THESE TESTS:\n", .{});
    for (builtin.test_functions) |test_function| {
        const test_func: *const fn () anyerror!void = test_function.func;
        const test_symbol_name = getTestFunctionName(test_function.name);
        log.debug(" > {s} \n", .{test_symbol_name});
        if (source_path) |symbol_file_name| {
            std.hash.autoHashStrat(&hasher, symbol_file_name, .Deep);
        } else {
            const test_symbol = getFuncSymbolInfo(gpa.allocator(), init.io, test_func) catch continue;
            if (getSymbolFilename(test_symbol)) |symbol_file_name| {
                std.hash.autoHashStrat(&hasher, symbol_file_name, .Deep);
            }
        }
        std.hash.autoHashStrat(&hasher, test_symbol_name, .Deep);
    }
    const hash_value = hasher.final();
    var hash_buffer: [64]u8 = undefined;
    const hash_string = try std.fmt.bufPrint(&hash_buffer, "{d}", .{hash_value});
    const results_file_path = try std.fs.path.join(gpa.allocator(), &.{ results_dir_path, hash_string });

    var processed_tests: usize = 0;

    var test_started_at = std.Io.Clock.awake.now(init.io);

    for (builtin.test_functions) |test_function| {
        const file = try platform.redirectStdErrToFile(init.io, logs_file_path);
        defer file.close(init.io);

        if (processed_tests == input.len) {
            // All requested tests have been processed.
            break;
        }

        const test_func: *const fn () anyerror!void = test_function.func;
        const test_symbol_name = getTestFunctionName(test_function.name);
        const test_file_name = source_path orelse blk: {
            const test_symbol = getFuncSymbolInfo(gpa.allocator(), init.io, test_func) catch {
                log.debug("getFuncSymbolInfo got error", .{});
                continue;
            };
            break :blk getSymbolFilename(test_symbol) orelse {
                log.debug("test_file_name not found", .{});
                continue;
            };
        };

        // This is a work around for the issue where `LineInfo.file_name` returns
        // incorrect path when invoked from `zig test` (`zig build test` works ok).
        // When `zig test` is used, neotest adapter provides the `--neotest-source-path`
        // argument, which provides the correct path.
        // https://github.com/ziglang/zig/issues/19556
        const test_source_path = test_file_name;

        const test_input = getTestInput(test_symbol_name, test_source_path, input) orelse {
            log.debug("getTestInput not found", .{});
            continue;
        };

        log.debug("Running test {s}::{s}", .{ test_input.source_path, test_input.test_name });

        const test_input_file = try platform.redirectStdErrToFile(init.io, test_input.output_path);
        defer test_input_file.close(init.io);

        processed_tests += 1;

        test_started_at = std.Io.Clock.awake.now(init.io);
        test_func() catch |err| {
            var errors = try gpa.allocator().alloc(Error, 1);
            var error_line: ?usize = null;

            if (@errorReturnTrace()) |trace| {
                std.debug.dumpErrorReturnTrace(trace);
                const last_frame_index = @min(trace.index, trace.instruction_addresses.len) - 1;
                const return_address = trace.instruction_addresses[last_frame_index];
                const address = return_address - 1;
                const symbol_info = try getSymbolAtAddress(gpa.allocator(), init.io, debug_info, address);
                const symbol_line = getSymbolLine(symbol_info) orelse {
                    std.debug.print("Unable to retrieve line info\n", .{});
                    return;
                };
                error_line = symbol_line - 1;
            }

            if (err == error.SkipZigTest) {
                errors[0] = .{ .message = "Skipped", .line = error_line };
                try test_results.append(
                    .{
                        .source_path = test_input.source_path,
                        .test_name = test_input.test_name,
                        .output = test_input.output_path,
                        .status = STATUS_SKIPPED,
                        .short = "Skipped",
                        .errors = errors,
                    },
                );
            } else {
                var first_output_line: []const u8 = undefined;
                blk: {
                    const output_file = std.Io.Dir.openFileAbsolute(init.io, test_input.output_path, .{}) catch {
                        first_output_line = "Could not open output buffer.";
                        break :blk;
                    };
                    defer output_file.close(init.io);
                    if (builtin.zig_version.minor >= 15) {
                        // zig >= 0.15: reader() takes explicit buf; use interface for generic methods
                        var read_buf: [4096]u8 = undefined;
                        var output_reader = output_file.reader(init.io, &read_buf);
                        first_output_line = output_reader.interface.takeDelimiterExclusive('\n') catch
                            "Could not read output file.";
                    } else {
                        // zig <= 0.14: bufferedReader wraps reader()
                        var buffered_output_reader = std.io.bufferedReader(output_file.reader());
                        const output_reader = buffered_output_reader.reader();
                        first_output_line = output_reader.readUntilDelimiterAlloc(gpa.allocator(), '\n', 300) catch
                            "Could not read output file.";
                    }
                }

                const short = try std.mem.concat(gpa.allocator(), u8, &.{ @errorName(err), ": ", first_output_line });
                const error_message = switch (err) {
                    error.TestExpectedEqual => if (std.mem.startsWith(u8, first_output_line, "expected")) first_output_line else @errorName(err),
                    else => @errorName(err),
                };
                errors[0] = .{ .message = error_message, .line = error_line };
                try test_results.append(
                    .{
                        .source_path = test_input.source_path,
                        .test_name = test_input.test_name,
                        .output = test_input.output_path,
                        .status = STATUS_FAILED,
                        .short = short,
                        .errors = errors,
                    },
                );
            }

            continue;
        };

        const test_run_duration_in_ns = test_started_at.untilNow(init.io, .awake).nanoseconds;

        if (std.testing.allocator_instance.detectLeaks() != 0) {
            try test_results.append(
                .{
                    .source_path = test_input.source_path,
                    .test_name = test_input.test_name,
                    .output = test_input.output_path,
                    .status = STATUS_FAILED,
                    .short = "Memory leaked (see full output for more details)",
                    .errors = null,
                },
            );
        }

        // zig >= 0.15: fmtDuration removed; zig <= 0.14: fmtDuration exists
        const short_output = if (builtin.zig_version.minor >= 15)
            try std.fmt.allocPrint(gpa.allocator(), "Test passed in {d}ms", .{@divTrunc(test_run_duration_in_ns, std.time.ns_per_ms)})
        else
            try std.fmt.allocPrint(gpa.allocator(), "Test passed in {}", .{std.fmt.fmtDuration(test_run_duration_in_ns)});

        std.log.info("{s}", .{short_output});

        try test_results.append(
            .{
                .source_path = test_input.source_path,
                .test_name = test_input.test_name,
                .output = test_input.output_path,
                .status = STATUS_PASSED,
                .short = short_output,
                .errors = null,
            },
        );
    }

    try platform.restoreStdErr();

    const results_file = try std.Io.Dir.createFileAbsolute(init.io, results_file_path, .{});
    defer results_file.close(init.io);
    if (builtin.zig_version.minor >= 15) {
        // zig >= 0.15: stringifyAlloc gone; use Stringify writer directly
        var write_buf: [65536]u8 = undefined;
        var file_writer = results_file.writer(init.io, &write_buf);
        var jw: std.json.Stringify = .{ .writer = &file_writer.interface };
        try jw.write(test_results.items);
        try file_writer.interface.flush();
    } else {
        // zig <= 0.14
        const test_results_json = try std.json.stringifyAlloc(gpa.allocator(), test_results.items, .{});
        try results_file.writeAll(test_results_json);
    }
}
