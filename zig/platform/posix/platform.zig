const std = @import("std");

var original_stderr: ?std.posix.fd_t = null;

fn duplicate(fd: std.posix.fd_t) !std.posix.fd_t {
    while (true) {
        const result = std.posix.system.dup(fd);
        switch (std.posix.errno(result)) {
            .SUCCESS => return @intCast(result),
            .INTR => continue,
            .BADF => return error.InvalidFileDescriptor,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
}

pub fn redirectStdErrToFile(io: std.Io, absolute_file_path: []const u8) !std.Io.File {
    const file = try std.Io.Dir.createFileAbsolute(io, absolute_file_path, .{});
    errdefer file.close(io);

    var saved_here = false;
    if (original_stderr == null) {
        original_stderr = try duplicate(std.posix.STDERR_FILENO);
        saved_here = true;
    }
    errdefer if (saved_here) {
        _ = std.posix.system.close(original_stderr.?);
        original_stderr = null;
    };

    try std.Io.Threaded.dup2(file.handle, std.posix.STDERR_FILENO);
    return file;
}

pub fn redirectStdErr(file: std.Io.File) !void {
    try std.Io.Threaded.dup2(file.handle, std.posix.STDERR_FILENO);
}

pub fn restoreStdErr() !void {
    const saved = original_stderr orelse return;
    try std.Io.Threaded.dup2(saved, std.posix.STDERR_FILENO);
    _ = std.posix.system.close(saved);
    original_stderr = null;
}
