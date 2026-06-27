const std = @import("std");

pub const TestInput = struct {
    test_name: []const u8,
    source_path: []const u8,
    output_path: []const u8,
};

pub const Status = enum {
    failed,
    passed,
    skipped,

    pub fn text(status: Status) []const u8 {
        return @tagName(status);
    }
};

pub fn testFunctionName(function_name: []const u8) []const u8 {
    if (std.mem.indexOf(u8, function_name, ".test.")) |index| {
        return function_name[index + 1 ..];
    }
    if (std.mem.indexOf(u8, function_name, ".decltest.")) |index| {
        return function_name[index + 1 ..];
    }
    return function_name;
}

pub fn findTestInput(
    test_name: []const u8,
    source_path: []const u8,
    test_inputs: []const TestInput,
) ?TestInput {
    for (test_inputs) |test_input| {
        if (std.mem.eql(u8, test_input.test_name, test_name) and
            std.mem.eql(u8, test_input.source_path, source_path))
        {
            return test_input;
        }
    }
    return null;
}

fn rawNameMatchesSource(raw_function_name: []const u8, source_path: []const u8) bool {
    const prefix_end = if (std.mem.indexOf(u8, raw_function_name, ".test.")) |index|
        index
    else if (std.mem.indexOf(u8, raw_function_name, ".decltest.")) |index|
        index
    else
        raw_function_name.len;
    const module_prefix = raw_function_name[0..prefix_end];
    const basename = std.fs.path.basename(source_path);
    const extension = std.fs.path.extension(basename);
    const stem = basename[0 .. basename.len - extension.len];

    var components = std.mem.splitScalar(u8, module_prefix, '.');
    while (components.next()) |component| {
        if (std.mem.eql(u8, component, basename) or std.mem.eql(u8, component, stem)) {
            return true;
        }
    }
    return false;
}

/// Selects a build-mode input without consulting debug symbols.
///
/// A normalized name that identifies one unconsumed input is sufficient. When
/// duplicate names exist, the raw compiler name's module prefix must identify
/// exactly one source basename; unresolved ambiguity is deliberately skipped.
pub fn findBuildTestInput(
    raw_function_name: []const u8,
    normalized_test_name: []const u8,
    test_inputs: []const TestInput,
    consumed: []const bool,
) ?usize {
    std.debug.assert(test_inputs.len == consumed.len);

    var candidate_count: usize = 0;
    var only_candidate: usize = undefined;
    for (test_inputs, consumed, 0..) |test_input, was_consumed, index| {
        if (!was_consumed and std.mem.eql(u8, test_input.test_name, normalized_test_name)) {
            candidate_count += 1;
            only_candidate = index;
        }
    }
    if (candidate_count == 1) return only_candidate;
    if (candidate_count == 0) return null;

    var source_match_count: usize = 0;
    var only_source_match: usize = undefined;
    for (test_inputs, consumed, 0..) |test_input, was_consumed, index| {
        if (was_consumed or
            !std.mem.eql(u8, test_input.test_name, normalized_test_name) or
            !rawNameMatchesSource(raw_function_name, test_input.source_path))
        {
            continue;
        }
        source_match_count += 1;
        only_source_match = index;
    }
    return if (source_match_count == 1) only_source_match else null;
}

pub fn zigLogLevel(vim_log_level: u8) std.log.Level {
    return switch (vim_log_level) {
        0, 1 => .debug,
        2 => .info,
        3 => .warn,
        4, 5 => .err,
        else => .debug,
    };
}

fn indexOfPath(line: []const u8, source_path: []const u8) ?usize {
    if (source_path.len > line.len) return null;

    for (0..line.len - source_path.len + 1) |start| {
        for (line[start .. start + source_path.len], source_path) |actual, expected| {
            const both_separators =
                (actual == '/' or actual == '\\') and (expected == '/' or expected == '\\');
            if (actual != expected and !both_separators) break;
        } else {
            return start;
        }
    }
    return null;
}

/// Finds the first Zig stack-trace frame for `source_path` and returns its
/// one-based line number as the zero-based line number Neotest expects.
pub fn traceSourceLine(trace: []const u8, source_path: []const u8) ?usize {
    var lines = std.mem.splitScalar(u8, trace, '\n');
    while (lines.next()) |line| {
        const path_start = indexOfPath(line, source_path) orelse continue;
        const line_start = path_start + source_path.len;
        if (line_start >= line.len or line[line_start] != ':') continue;

        const number_start = line_start + 1;
        const number_end = std.mem.indexOfScalarPos(u8, line, number_start, ':') orelse continue;
        const one_based = std.fmt.parseUnsigned(usize, line[number_start..number_end], 10) catch continue;
        if (one_based == 0) continue;
        return one_based - 1;
    }
    return null;
}

pub fn finalStatus(test_error: ?anyerror, leaked: bool) Status {
    if (test_error) |err| {
        if (err != error.SkipZigTest) return .failed;
    }
    if (leaked) return .failed;
    return if (test_error != null) .skipped else .passed;
}
