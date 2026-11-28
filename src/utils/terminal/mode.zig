const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const linux = std.os.linux;

// Zig's Linux termios uses the kernel layout. Keep it on the ioctl path
// because libc's termios can have a different size and field layout.
pub fn get(fd: posix.fd_t) posix.TermiosGetError!posix.termios {
    if (builtin.os.tag != .linux) return posix.tcgetattr(fd);

    var settings = std.mem.zeroes(posix.termios);
    while (true) {
        switch (linux.errno(linux.tcgetattr(fd, &settings))) {
            .SUCCESS => return settings,
            .INTR => continue,
            .NOTTY => return error.NotATerminal,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

pub fn set(fd: posix.fd_t, action: posix.TCSA, settings: posix.termios) posix.TermiosSetError!void {
    if (builtin.os.tag != .linux) return posix.tcsetattr(fd, action, settings);

    while (true) {
        switch (linux.errno(linux.tcsetattr(fd, action, &settings))) {
            .SUCCESS => return,
            .INTR => continue,
            .NOTTY => return error.NotATerminal,
            .IO => return error.ProcessOrphaned,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}
