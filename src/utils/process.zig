const std = @import("std");
const builtin = @import("builtin");

/// Cross-Platform Process Management
/// Provides unified API for process control across POSIX and Windows

// =============================================================================
// Type Definitions
// =============================================================================

/// Platform-agnostic process identifier
pub const ProcessId = if (builtin.os.tag == .windows)
    std.os.windows.HANDLE
else
    std.posix.pid_t;

/// Platform-agnostic file descriptor/handle
pub const FileHandle = if (builtin.os.tag == .windows)
    std.os.windows.HANDLE
else
    std.posix.fd_t;

/// Invalid handle sentinel
pub const INVALID_HANDLE: FileHandle = if (builtin.os.tag == .windows)
    std.os.windows.INVALID_HANDLE_VALUE
else
    -1;

/// Process exit status
pub const ExitStatus = struct {
    code: i32,
    signaled: bool = false,
    signal: ?u8 = null,

    pub fn success(self: ExitStatus) bool {
        return self.code == 0 and !self.signaled;
    }
};

/// Wait options
pub const WaitOptions = struct {
    no_hang: bool = false,
};

/// Wait result
pub const WaitResult = struct {
    pid: ProcessId,
    status: ExitStatus,
    still_running: bool = false,
};

// =============================================================================
// Pipe Operations
// =============================================================================

/// A pipe pair (read and write ends)
pub const Pipe = struct {
    read: FileHandle,
    write: FileHandle,

    /// Close the read end
    pub fn closeRead(self: *Pipe) void {
        if (builtin.os.tag == .windows) {
            if (self.read != std.os.windows.INVALID_HANDLE_VALUE) {
                std.os.windows.CloseHandle(self.read);
                self.read = std.os.windows.INVALID_HANDLE_VALUE;
            }
        } else {
            if (self.read != -1) {
                _ = std.c.close(self.read);
                self.read = -1;
            }
        }
    }

    /// Close the write end
    pub fn closeWrite(self: *Pipe) void {
        if (builtin.os.tag == .windows) {
            if (self.write != std.os.windows.INVALID_HANDLE_VALUE) {
                std.os.windows.CloseHandle(self.write);
                self.write = std.os.windows.INVALID_HANDLE_VALUE;
            }
        } else {
            if (self.write != -1) {
                _ = std.c.close(self.write);
                self.write = -1;
            }
        }
    }

    /// Close both ends
    pub fn close(self: *Pipe) void {
        self.closeRead();
        self.closeWrite();
    }
};

/// Create a pipe
pub fn createPipe() !Pipe {
    if (builtin.os.tag == .windows) {
        return createPipeWindows();
    } else {
        return createPipePosix();
    }
}

fn createPipePosix() !Pipe {
    var fds: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.Unexpected;
    return Pipe{
        .read = fds[0],
        .write = fds[1],
    };
}

fn createPipeWindows() !Pipe {
    var sa = std.os.windows.SECURITY_ATTRIBUTES{
        .nLength = @sizeOf(std.os.windows.SECURITY_ATTRIBUTES),
        .lpSecurityDescriptor = null,
        .bInheritHandle = 1, // TRUE - handles are inheritable
    };

    var read_handle: std.os.windows.HANDLE = undefined;
    var write_handle: std.os.windows.HANDLE = undefined;

    const result = std.os.windows.kernel32.CreatePipe(
        &read_handle,
        &write_handle,
        &sa,
        0, // Default buffer size
    );

    if (result == 0) {
        return error.PipeCreationFailed;
    }

    return Pipe{
        .read = read_handle,
        .write = write_handle,
    };
}

// =============================================================================
// File Handle Operations
// =============================================================================

/// Duplicate a file handle
pub fn duplicateHandle(handle: FileHandle) !FileHandle {
    if (builtin.os.tag == .windows) {
        return duplicateHandleWindows(handle);
    } else {
        return duplicateHandlePosix(handle);
    }
}

fn duplicateHandlePosix(fd: std.posix.fd_t) !std.posix.fd_t {
    return std.posix.dup(fd);
}

fn duplicateHandleWindows(handle: std.os.windows.HANDLE) !std.os.windows.HANDLE {
    const current_process = std.os.windows.kernel32.GetCurrentProcess();
    var new_handle: std.os.windows.HANDLE = undefined;

    const result = std.os.windows.kernel32.DuplicateHandle(
        current_process,
        handle,
        current_process,
        &new_handle,
        0,
        1, // Inheritable
        2, // DUPLICATE_SAME_ACCESS
    );

    if (result == 0) {
        return error.DuplicateHandleFailed;
    }

    return new_handle;
}

/// Duplicate handle to a specific target (like dup2)
pub fn duplicateHandleTo(source: FileHandle, target: FileHandle) !void {
    if (builtin.os.tag == .windows) {
        try duplicateHandleToWindows(source, target);
    } else {
        try duplicateHandleToPosix(source, target);
    }
}

fn duplicateHandleToPosix(source: std.posix.fd_t, target: std.posix.fd_t) !void {
    if (std.c.dup2(source, target) < 0) return error.Unexpected;
}

fn duplicateHandleToWindows(source: std.os.windows.HANDLE, target: std.os.windows.HANDLE) !void {
    // On Windows, we can't directly dup2 to a specific handle number
    // Instead, we close the target and duplicate the source
    // This is used primarily for stdin/stdout/stderr redirection
    _ = target;
    _ = source;
    // Windows redirection is typically done via SetStdHandle or process spawn attributes
    // This function is a placeholder for the concept - actual implementation
    // uses std.process.Child with stdin/stdout/stderr behavior settings
}

/// Close a file handle
pub fn closeHandle(handle: FileHandle) void {
    if (builtin.os.tag == .windows) {
        if (handle != std.os.windows.INVALID_HANDLE_VALUE) {
            std.os.windows.CloseHandle(handle);
        }
    } else {
        if (handle != -1) {
            _ = std.c.close(handle);
        }
    }
}

/// Get standard input handle
pub fn getStdin() FileHandle {
    if (builtin.os.tag == .windows) {
        return std.os.windows.kernel32.GetStdHandle(std.os.windows.STD_INPUT_HANDLE) orelse std.os.windows.INVALID_HANDLE_VALUE;
    } else {
        return std.posix.STDIN_FILENO;
    }
}

/// Get standard output handle
pub fn getStdout() FileHandle {
    if (builtin.os.tag == .windows) {
        return std.os.windows.kernel32.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) orelse std.os.windows.INVALID_HANDLE_VALUE;
    } else {
        return std.posix.STDOUT_FILENO;
    }
}

/// Get standard error handle
pub fn getStderr() FileHandle {
    if (builtin.os.tag == .windows) {
        return std.os.windows.kernel32.GetStdHandle(std.os.windows.STD_ERROR_HANDLE) orelse std.os.windows.INVALID_HANDLE_VALUE;
    } else {
        return std.posix.STDERR_FILENO;
    }
}

// =============================================================================
// Process Control
// =============================================================================

/// Low-level POSIX waitpid that retries on EINTR. Returns the kernel's
/// raw status word in `status_out`. On non-POSIX targets this is a no-op
/// that returns 0 (callers must guard with `builtin.os.tag` themselves
/// when meaningful behavior is required).
///
/// Most direct waitpid sites in this codebase want the raw `c_int` status
/// (so they can call `std.posix.W.*` macros against it), and they want
/// signal-induced EINTR returns to be retried rather than silently dropped
/// — which is exactly what this helper provides.
pub fn waitpidIntr(pid: std.posix.pid_t, status_out: *c_int, flags: c_int) std.posix.pid_t {
    if (comptime builtin.os.tag == .windows) {
        status_out.* = 0;
        return 0;
    }
    while (true) {
        const r = std.c.waitpid(pid, status_out, flags);
        if (r >= 0) return @intCast(r);
        if (std.c._errno().* == @intFromEnum(std.c.E.INTR)) continue;
        return @intCast(r);
    }
}

/// Wait for a process to exit
pub fn waitProcess(pid: ProcessId, options: WaitOptions) !WaitResult {
    if (builtin.os.tag == .windows) {
        return waitProcessWindows(pid, options);
    } else {
        return waitProcessPosix(pid, options);
    }
}

fn waitProcessPosix(pid: std.posix.pid_t, options: WaitOptions) !WaitResult {
    const flags: c_int = if (options.no_hang) std.posix.W.NOHANG else 0;

    var wait_status: c_int = 0;
    const wait_pid = if (comptime builtin.os.tag != .windows)
        waitpidIntr(pid, &wait_status, flags)
    else
        unreachable;
    const status_u32: u32 = @bitCast(wait_status);

    if (wait_pid == 0 and options.no_hang) {
        // Process still running
        return WaitResult{
            .pid = pid,
            .status = .{ .code = 0 },
            .still_running = true,
        };
    }

    var exit_status = ExitStatus{ .code = 0 };

    if (std.posix.W.IFEXITED(status_u32)) {
        exit_status.code = @intCast(std.posix.W.EXITSTATUS(status_u32));
    } else if (std.posix.W.IFSIGNALED(status_u32)) {
        exit_status.signaled = true;
        exit_status.signal = @intCast(@intFromEnum(std.posix.W.TERMSIG(status_u32)));
        exit_status.code = 128 + @as(i32, @intCast(exit_status.signal.?));
    }

    return WaitResult{
        .pid = wait_pid,
        .status = exit_status,
        .still_running = false,
    };
}

fn waitProcessWindows(handle: std.os.windows.HANDLE, options: WaitOptions) !WaitResult {
    const timeout: std.os.windows.DWORD = if (options.no_hang) 0 else std.os.windows.INFINITE;

    const wait_result = std.os.windows.kernel32.WaitForSingleObject(handle, timeout);

    if (wait_result == std.os.windows.WAIT_TIMEOUT) {
        return WaitResult{
            .pid = handle,
            .status = .{ .code = 0 },
            .still_running = true,
        };
    }

    if (wait_result == std.os.windows.WAIT_OBJECT_0) {
        var exit_code: std.os.windows.DWORD = undefined;
        if (std.os.windows.kernel32.GetExitCodeProcess(handle, &exit_code) != 0) {
            return WaitResult{
                .pid = handle,
                .status = .{ .code = @intCast(exit_code) },
                .still_running = false,
            };
        }
    }

    return error.WaitFailed;
}

/// Terminate a process
pub fn killProcess(pid: ProcessId, signal: u8) !void {
    if (builtin.os.tag == .windows) {
        try killProcessWindows(pid);
    } else {
        try killProcessPosix(pid, signal);
    }
}

fn killProcessPosix(pid: std.posix.pid_t, signal: u8) !void {
    try std.posix.kill(pid, @enumFromInt(signal));
}

fn killProcessWindows(handle: std.os.windows.HANDLE) !void {
    // On Windows, we can only terminate (equivalent to SIGKILL)
    if (std.os.windows.kernel32.TerminateProcess(handle, 1) == 0) {
        return error.TerminateProcessFailed;
    }
}

/// Send SIGTERM (or Windows equivalent - request graceful shutdown)
pub fn terminateProcess(pid: ProcessId) !void {
    if (builtin.os.tag == .windows) {
        // Windows doesn't have SIGTERM equivalent for console apps
        // Best we can do is TerminateProcess or send Ctrl+C via GenerateConsoleCtrlEvent
        try killProcessWindows(pid);
    } else {
        try killProcessPosix(pid, @intFromEnum(std.posix.SIG.TERM));
    }
}

/// Send SIGKILL (forceful termination)
pub fn forceKillProcess(pid: ProcessId) !void {
    if (builtin.os.tag == .windows) {
        try killProcessWindows(pid);
    } else {
        try killProcessPosix(pid, @intFromEnum(std.posix.SIG.KILL));
    }
}

/// Send SIGSTOP (pause process)
pub fn stopProcess(pid: ProcessId) !void {
    if (builtin.os.tag == .windows) {
        // Windows doesn't have SIGSTOP equivalent
        // Could use SuspendThread but that requires thread handles
        return error.NotSupported;
    } else {
        try killProcessPosix(pid, @intFromEnum(std.posix.SIG.STOP));
    }
}

/// Send SIGCONT (resume process)
pub fn continueProcess(pid: ProcessId) !void {
    if (builtin.os.tag == .windows) {
        // Windows doesn't have SIGCONT equivalent
        return error.NotSupported;
    } else {
        try killProcessPosix(pid, @intFromEnum(std.posix.SIG.CONT));
    }
}

// =============================================================================
// Process Group Operations (POSIX-specific with Windows stubs)
// =============================================================================

/// Set process group (POSIX only, no-op on Windows)
pub const setProcessGroup = if (builtin.os.tag == .windows)
    setProcessGroupWindows
else
    setProcessGroupPosix;

fn setProcessGroupWindows(pid: ProcessId, pgid: ProcessId) !void {
    // Windows uses Job Objects instead of process groups
    // This is a no-op for basic compatibility
    _ = pid;
    _ = pgid;
}

fn setProcessGroupPosix(pid: std.posix.pid_t, pgid: std.posix.pid_t) !void {
    // std.posix.setpgid does not exist in the pinned Zig toolchain; call libc
    // directly (consistent with the dup2/waitpid sites in this module).
    if (std.c.setpgid(pid, pgid) < 0) return error.Unexpected;
}

/// Get process group (POSIX only)
pub const getProcessGroup = if (builtin.os.tag == .windows)
    getProcessGroupWindows
else
    getProcessGroupPosix;

fn getProcessGroupWindows(pid: ProcessId) !ProcessId {
    // Windows doesn't have process groups in the POSIX sense
    return pid; // Return the process itself
}

// Neither std.posix nor std.c expose getpgid in the pinned Zig toolchain, so
// bind the libc symbol directly.
extern "c" fn getpgid(pid: std.posix.pid_t) std.posix.pid_t;

fn getProcessGroupPosix(pid: std.posix.pid_t) !std.posix.pid_t {
    const pgid = getpgid(pid);
    if (pgid < 0) return error.Unexpected;
    return pgid;
}

// =============================================================================
// Utility Functions
// =============================================================================

/// Check if a process is still running
pub fn isProcessRunning(pid: ProcessId) bool {
    const result = waitProcess(pid, .{ .no_hang = true }) catch return false;
    return result.still_running;
}

/// Get current process ID
pub fn getCurrentProcessId() ProcessId {
    if (builtin.os.tag == .windows) {
        return std.os.windows.kernel32.GetCurrentProcess();
    } else {
        return std.c.getpid();
    }
}

/// Check if running on Windows
pub fn isWindows() bool {
    return builtin.os.tag == .windows;
}

/// Check if running on POSIX-like system
pub fn isPosix() bool {
    return builtin.os.tag != .windows;
}

// =============================================================================
// Path Utilities
// =============================================================================

/// Get the platform-specific path separator
pub fn pathSeparator() u8 {
    return if (builtin.os.tag == .windows) '\\' else '/';
}

/// Get the platform-specific path list separator (PATH variable)
pub fn pathListSeparator() u8 {
    return if (builtin.os.tag == .windows) ';' else ':';
}

/// Check if a path is absolute
pub fn isAbsolutePath(path: []const u8) bool {
    if (path.len == 0) return false;

    if (builtin.os.tag == .windows) {
        // Windows: C:\ or C:/ or \\ (UNC) or //
        if (path.len >= 3 and path[1] == ':' and (path[2] == '\\' or path[2] == '/')) {
            return true;
        }
        if (path.len >= 2 and (path[0] == '\\' or path[0] == '/') and (path[1] == '\\' or path[1] == '/')) {
            return true;
        }
        return false;
    } else {
        return path[0] == '/';
    }
}

// =============================================================================
// Tests
// =============================================================================

test "pipe creation and closing" {
    var p = try createPipe();
    defer p.close();

    // Verify handles are valid
    if (builtin.os.tag == .windows) {
        try std.testing.expect(p.read != std.os.windows.INVALID_HANDLE_VALUE);
        try std.testing.expect(p.write != std.os.windows.INVALID_HANDLE_VALUE);
    } else {
        try std.testing.expect(p.read >= 0);
        try std.testing.expect(p.write >= 0);
    }
}

test "path separator" {
    const sep = pathSeparator();
    if (builtin.os.tag == .windows) {
        try std.testing.expectEqual(@as(u8, '\\'), sep);
    } else {
        try std.testing.expectEqual(@as(u8, '/'), sep);
    }
}

test "path list separator" {
    const sep = pathListSeparator();
    if (builtin.os.tag == .windows) {
        try std.testing.expectEqual(@as(u8, ';'), sep);
    } else {
        try std.testing.expectEqual(@as(u8, ':'), sep);
    }
}

test "absolute path detection" {
    if (builtin.os.tag == .windows) {
        try std.testing.expect(isAbsolutePath("C:\\Users"));
        try std.testing.expect(isAbsolutePath("C:/Users"));
        try std.testing.expect(isAbsolutePath("\\\\server\\share"));
        try std.testing.expect(!isAbsolutePath("relative\\path"));
        try std.testing.expect(!isAbsolutePath(""));
    } else {
        try std.testing.expect(isAbsolutePath("/usr/bin"));
        try std.testing.expect(!isAbsolutePath("relative/path"));
        try std.testing.expect(!isAbsolutePath(""));
    }
}

test "platform detection" {
    // These should compile and run on any platform
    _ = isWindows();
    _ = isPosix();
    _ = getCurrentProcessId();
}
