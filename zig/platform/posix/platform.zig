const std = @import("std");

pub fn redirectStdErrToFile(io: std.Io, absolute_file_path: []const u8) !std.Io.File {
    const file = try std.Io.Dir.createFileAbsolute(io, absolute_file_path, .{});
    try std.Io.Threaded.dup2(file.handle, std.posix.STDERR_FILENO);
    return file;
}

pub fn restoreStdErr() !void {
    try std.Io.Threaded.dup2(std.posix.STDERR_FILENO, std.posix.STDERR_FILENO);
}
