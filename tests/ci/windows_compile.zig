const std = @import("std");
const windows = std.os.windows;
const platform = @import("platform");

const std_error_handle: windows.DWORD = @bitCast(@as(i32, -12));

extern "kernel32" fn GetStdHandle(std_handle: windows.DWORD) callconv(.winapi) ?windows.HANDLE;

test "Windows stderr redirection restores the original handle" {
    const original = GetStdHandle(std_error_handle);
    var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(std.testing.io, &cwd_buffer);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        "{s}{c}neotest-zig-stderr-test.log",
        .{ cwd_buffer[0..cwd_len], std.fs.path.sep },
    );
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, path) catch {};

    const file = try platform.redirectStdErrToFile(std.testing.io, path);
    defer file.close(std.testing.io);

    try platform.restoreStdErr();
    try std.testing.expectEqual(original, GetStdHandle(std_error_handle));
}
