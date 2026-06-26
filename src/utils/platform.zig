const std = @import("std");
const builtin = @import("builtin");

/// Platform abstraction layer for cross-platform shell operations.
///
/// This module provides a unified API for platform-specific operations:
/// - Process spawning and management
/// - Signal handling
/// - Terminal detection and control
/// - Path operations

// ========================================
// Process Management
// ========================================

/// Cross-platform process ID type.
pub const ProcessId = if (builtin.os.tag == .windows)
    std.os.windows.HANDLE
else
    std.posix.pid_t;

/// Process wait result.
pub const WaitResult = struct {
    status: i32,
    signaled: bool,
    signal: ?u8,
};

/// Wait for a process to complete.
pub fn waitProcess(pid: ProcessId, options: struct { no_hang: bool = false }) !WaitResult {
    if (builtin.os.tag == .windows) {
        return waitProcessWindows(pid, options);
    } else {
        return waitProcessPosix(pid, options);
    }
}

fn waitProcessPosix(pid: std.posix.pid_t, options: struct { no_hang: bool = false }) !WaitResult {
    const flags: c_int = if (options.no_hang) std.posix.W.NOHANG else 0;
    var wait_status: c_int = 0;
    const wait_pid = if (comptime builtin.os.tag != .windows)
        std.c.waitpid(pid, &wait_status, flags)
    else
        unreachable;
    const status_u32: u32 = @bitCast(wait_status);

    if (wait_pid == 0 and options.no_hang) {
        // Process still running
        return WaitResult{
            .status = 0,
            .signaled = false,
            .signal = null,
        };
    }

    const signaled = std.posix.W.IFSIGNALED(status_u32);
    return WaitResult{
        .status = if (signaled) 128 + @as(i32, @intCast(@intFromEnum(std.posix.W.TERMSIG(status_u32)))) else @as(i32, std.posix.W.EXITSTATUS(status_u32)),
        .signaled = signaled,
        .signal = if (signaled) @as(u8, @intCast(@intFromEnum(std.posix.W.TERMSIG(status_u32)))) else null,
    };
}

fn waitProcessWindows(handle: std.os.windows.HANDLE, options: struct { no_hang: bool = false }) !WaitResult {
    _ = handle;
    _ = options;
    // Windows implementation placeholder
    return WaitResult{
        .status = 0,
        .signaled = false,
        .signal = null,
    };
}

/// Send a signal to a process.
pub fn killProcess(pid: ProcessId, signal: u8) !void {
    if (builtin.os.tag == .windows) {
        return killProcessWindows(pid);
    } else {
        return killProcessPosix(pid, signal);
    }
}

fn killProcessPosix(pid: std.posix.pid_t, signal: u8) !void {
    try std.posix.kill(pid, signal);
}

fn killProcessWindows(handle: std.os.windows.HANDLE) !void {
    _ = handle;
    // Windows: would use TerminateProcess
}

/// Continue a stopped process (SIGCONT).
pub fn continueProcess(pid: ProcessId) !void {
    if (builtin.os.tag == .windows) {
        // Windows: not directly applicable
        return;
    } else {
        try std.posix.kill(pid, std.posix.SIG.CONT);
    }
}

// ========================================
// Terminal Operations
// ========================================

/// Check if file descriptor is a TTY.
pub fn isTty(fd: std.posix.fd_t) bool {
    if (builtin.os.tag == .windows) {
        return isTtyWindows(fd);
    } else {
        return (std.Io.File{ .handle = fd, .flags = .{ .nonblocking = false } }).isTty(std.Options.debug_io) catch false;
    }
}

fn isTtyWindows(fd: std.posix.fd_t) bool {
    _ = fd;
    // Windows: would check console mode
    return true;
}

/// Get terminal size.
pub const TerminalSize = struct {
    rows: u16,
    cols: u16,
};

pub fn getTerminalSize() ?TerminalSize {
    if (builtin.os.tag == .windows) {
        return getTerminalSizeWindows();
    } else {
        return getTerminalSizePosix();
    }
}

fn getTerminalSizePosix() ?TerminalSize {
    var ws: std.posix.winsize = undefined;
    const result = std.posix.system.ioctl(std.posix.STDOUT_FILENO, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
    if (result == 0) {
        return TerminalSize{
            .rows = ws.row,
            .cols = ws.col,
        };
    }
    return null;
}

fn getTerminalSizeWindows() ?TerminalSize {
    // Windows: would use GetConsoleScreenBufferInfo
    return TerminalSize{
        .rows = 24,
        .cols = 80,
    };
}

// ========================================
// Environment
// ========================================

/// Get an environment variable.
pub fn getEnv(key: []const u8) ?[]const u8 {
    // posix.getenv removed in Zig 0.16; use libc getenv
    var buf: [512]u8 = undefined;
    if (key.len >= buf.len) return null;
    @memcpy(buf[0..key.len], key);
    buf[key.len] = 0;
    const result = std.c.getenv(buf[0..key.len :0]) orelse return null;
    return std.mem.span(@as([*:0]const u8, @ptrCast(result)));
}

/// Get the home directory.
pub fn getHomeDir() ?[]const u8 {
    if (builtin.os.tag == .windows) {
        return getEnv("USERPROFILE");
    } else {
        return getEnv("HOME");
    }
}

/// Get the current user's username.
pub fn getUsername() []const u8 {
    if (builtin.os.tag == .windows) {
        return getEnv("USERNAME") orelse "user";
    } else {
        return getEnv("USER") orelse getEnv("LOGNAME") orelse "user";
    }
}

/// Check if running as root/admin.
pub fn isRoot() bool {
    if (builtin.os.tag == .windows) {
        // Windows: would check admin privileges
        return false;
    } else {
        return std.posix.system.getuid() == 0;
    }
}

// ========================================
// Path Operations
// ========================================

/// Path separator for the current platform.
pub const path_separator = if (builtin.os.tag == .windows) '\\' else '/';

/// Path list separator (PATH env var).
pub const path_list_separator = if (builtin.os.tag == .windows) ';' else ':';

/// Check if a path is absolute.
pub fn isAbsolutePath(path: []const u8) bool {
    if (builtin.os.tag == .windows) {
        // Windows: check for drive letter or UNC
        if (path.len >= 2 and path[1] == ':') return true;
        if (path.len >= 2 and path[0] == '\\' and path[1] == '\\') return true;
        return false;
    } else {
        return path.len > 0 and path[0] == '/';
    }
}

// ========================================
// Signal Constants
// ========================================

pub const signals = struct {
    pub const TERM = if (builtin.os.tag == .windows) 0 else std.posix.SIG.TERM;
    pub const INT = if (builtin.os.tag == .windows) 0 else std.posix.SIG.INT;
    pub const KILL = if (builtin.os.tag == .windows) 0 else std.posix.SIG.KILL;
    pub const STOP = if (builtin.os.tag == .windows) 0 else std.posix.SIG.STOP;
    pub const CONT = if (builtin.os.tag == .windows) 0 else std.posix.SIG.CONT;
    pub const HUP = if (builtin.os.tag == .windows) 0 else std.posix.SIG.HUP;
    pub const QUIT = if (builtin.os.tag == .windows) 0 else std.posix.SIG.QUIT;
};

// ========================================
// Process Groups (Job Control)
// ========================================
//
// Process-group manipulation lives in src/utils/process.zig
// (setProcessGroup/getProcessGroup), the process module den's job control
// already imports. Duplicate wrappers used to live here but were dead code:
// nothing imported this module's versions, and the POSIX paths referenced
// std.posix.setpgid / std.posix.getpgid, which do not exist in the pinned Zig
// toolchain. If terminal foreground-group control is ever added to
// job_control.zig, call std.posix.tcsetpgrp / std.posix.tcgetpgrp directly
// (both exist) using the split-function comptime pattern below.

// ========================================
// Pipes
// ========================================

/// Pipe file descriptors.
pub const Pipe = struct {
    read_end: std.posix.fd_t,
    write_end: std.posix.fd_t,
};

/// Create a pipe.
pub fn createPipe() !Pipe {
    if (builtin.os.tag == .windows) {
        return createPipeWindows();
    } else {
        var fds: [2]std.posix.fd_t = undefined;
        if (std.c.pipe(&fds) != 0) return error.Unexpected;
        return Pipe{
            .read_end = fds[0],
            .write_end = fds[1],
        };
    }
}

fn createPipeWindows() !Pipe {
    // Windows: would use CreatePipe
    return error.NotSupported;
}

/// Duplicate file descriptor.
pub const duplicateFd = if (builtin.os.tag == .windows)
    duplicateFdWindows
else
    duplicateFdPosix;

fn duplicateFdPosix(old_fd: std.posix.fd_t, new_fd: std.posix.fd_t) !void {
    if (std.c.dup2(old_fd, new_fd) < 0) return error.Unexpected;
}

fn duplicateFdWindows(old_fd: std.posix.fd_t, new_fd: std.posix.fd_t) !void {
    // Windows: would use DuplicateHandle + SetStdHandle
    _ = old_fd;
    _ = new_fd;
    return error.NotSupported;
}

/// Close file descriptor.
pub const closeFd = if (builtin.os.tag == .windows)
    closeFdWindows
else
    closeFdPosix;

fn closeFdPosix(fd: std.posix.fd_t) void {
    _ = std.c.close(fd);
}

fn closeFdWindows(fd: std.posix.fd_t) void {
    // Windows: would use CloseHandle
    _ = fd;
}

// ========================================
// File Operations
// ========================================

/// Check if a file exists.
pub fn fileExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(std.Options.debug_io, path, .{}) catch return false;
    return true;
}

/// Check if a path is a directory.
pub fn isDirectory(path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(std.Options.debug_io, path, .{}) catch return false;
    return stat.kind == .directory;
}

/// Check if a file is executable.
pub fn isExecutable(path: []const u8) bool {
    if (builtin.os.tag == .windows) {
        // Windows: check file extension
        const lower = std.ascii.lowerString(undefined, path);
        _ = lower;
        return std.mem.endsWith(u8, path, ".exe") or
            std.mem.endsWith(u8, path, ".cmd") or
            std.mem.endsWith(u8, path, ".bat") or
            std.mem.endsWith(u8, path, ".com");
    } else {
        std.Io.Dir.cwd().access(std.Options.debug_io, path, .{ .execute = true }) catch return false;
        return true;
    }
}

// ========================================
// Tests
// ========================================

test "platform detection" {
    const is_windows = builtin.os.tag == .windows;
    const is_posix = !is_windows;

    try std.testing.expect(is_windows or is_posix);
}

test "isAbsolutePath" {
    if (builtin.os.tag == .windows) {
        try std.testing.expect(isAbsolutePath("C:\\Windows"));
        try std.testing.expect(isAbsolutePath("\\\\server\\share"));
        try std.testing.expect(!isAbsolutePath("relative\\path"));
    } else {
        try std.testing.expect(isAbsolutePath("/usr/bin"));
        try std.testing.expect(!isAbsolutePath("relative/path"));
    }
}

test "getHomeDir" {
    // Just verify it doesn't crash
    _ = getHomeDir();
}

test "getUsername" {
    const username = getUsername();
    try std.testing.expect(username.len > 0);
}

test "isTty" {
    // stdout might or might not be a tty in test environment
    _ = isTty(std.posix.STDOUT_FILENO);
}
