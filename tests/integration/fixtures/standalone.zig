const std = @import("std");

const FuzzContext = struct {
    calls: usize = 0,
};

fn fuzzOne(context: *FuzzContext, smith: *std.testing.Smith) !void {
    _ = smith;
    context.calls += 1;
}

test "passes" {}

test "passes prefix collision" {}

test "fails" {
    try std.testing.expectEqual(@as(u8, 1), @as(u8, 2));
}

test "skips" {
    return error.SkipZigTest;
}

test "prints" {
    std.debug.print("debug-output\n", .{});
    std.log.info("info-output", .{});
}

test "uses testing io" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
}

test "fuzz smoke" {
    var context: FuzzContext = .{};
    try std.testing.fuzz(&context, fuzzOne, .{});
    try std.testing.expect(context.calls > 0);
}

test "leaks once" {
    _ = try std.testing.allocator.alloc(u8, 1);
}

test "passes after leak" {}
