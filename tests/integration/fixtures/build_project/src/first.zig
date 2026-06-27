const std = @import("std");

test "first passes" {}

test "shared name" {}

test "first fails" {
    try std.testing.expectEqual(@as(u8, 1), @as(u8, 2));
}
