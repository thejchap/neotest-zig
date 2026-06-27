const std = @import("std");
const windows = std.os.windows;

const std_error_handle: windows.DWORD = @bitCast(@as(i32, -12));

extern "kernel32" fn GetStdHandle(std_handle: windows.DWORD) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn SetStdHandle(std_handle: windows.DWORD, handle: ?windows.HANDLE) callconv(.winapi) windows.BOOL;

fn setStdErrHandle(handle: ?windows.HANDLE) !void {
    if (SetStdHandle(std_error_handle, handle) == .FALSE) {
        return windows.unexpectedError(windows.GetLastError());
    }
}

var original_std_err_handle: ?windows.HANDLE = null;
var original_std_err_handle_captured = false;

pub fn redirectStdErrToFile(io: std.Io, absolute_file_path: []const u8) !std.Io.File {
    const file = try std.Io.Dir.createFileAbsolute(io, absolute_file_path, .{});
    errdefer file.close(io);

    if (!original_std_err_handle_captured) {
        const handle = GetStdHandle(std_error_handle);
        if (handle == windows.INVALID_HANDLE_VALUE) {
            return windows.unexpectedError(windows.GetLastError());
        }
        original_std_err_handle = handle;
        original_std_err_handle_captured = true;
    }

    try setStdErrHandle(file.handle);

    return file;
}

pub fn redirectStdErr(file: std.Io.File) !void {
    try setStdErrHandle(file.handle);
}

pub fn restoreStdErr() !void {
    if (!original_std_err_handle_captured) return;
    try setStdErrHandle(original_std_err_handle);
}
