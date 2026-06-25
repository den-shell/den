const std = @import("std");
const builtin = @import("builtin");
const process = @import("process.zig");
const posix = std.posix;

const is_windows = builtin.os.tag == .windows;

// =============================================================================
// Types
// =============================================================================

pub const SpawnOptions = struct {
    argv: []const []const u8,
    stdin_fd: ?process.FileHandle = null,
    stdout_fd: ?process.FileHandle = null,
    stderr_fd: ?process.FileHandle = null,
    cwd: ?[]const u8 = null,
    env: ?[*:null]const ?[*:0]const u8 = null,
};

pub const CaptureResult = struct {
    stdout: []const u8,
    exit_code: i32,

    pub fn deinit(self: CaptureResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
    }
};

// =============================================================================
// Platform Constants
// =============================================================================

pub fn getDefaultShell() []const u8 {
    return if (is_windows) "cmd.exe" else "/bin/sh";
}

pub fn getShellFlag() []const u8 {
    return if (is_windows) "/c" else "-c";
}

pub fn getDevNull() []const u8 {
    return if (is_windows) "NUL" else "/dev/null";
}

// =============================================================================
// Core Spawn Functions
// =============================================================================

/// Fork+exec+wait: spawn a process and wait for it to exit.
/// Returns the exit code.
pub fn spawnAndWait(allocator: std.mem.Allocator, opts: SpawnOptions) !i32 {
    if (is_windows) {
        return spawnAndWaitWindows(allocator, opts);
    } else {
        return spawnAndWaitPosix(allocator, opts);
    }
}

/// Fork+exec without waiting: spawn a background process.
/// Returns the process ID. Caller is responsible for waiting.
pub fn spawnBackground(allocator: std.mem.Allocator, opts: SpawnOptions) !process.ProcessId {
    if (is_windows) {
        return spawnBackgroundWindows(allocator, opts);
    } else {
        return spawnBackgroundPosix(allocator, opts);
    }
}

/// Fork+exec+capture stdout: spawn a process and capture its stdout output.
pub fn captureOutput(allocator: std.mem.Allocator, opts: SpawnOptions) !CaptureResult {
    if (is_windows) {
        return captureOutputWindows(allocator, opts);
    } else {
        return captureOutputPosix(allocator, opts);
    }
}

/// Execute a shell command string via the system shell.
/// On POSIX: /bin/sh -c "command"
/// On Windows: cmd.exe /c "command"
pub fn shellExec(allocator: std.mem.Allocator, cmd_str: []const u8) !i32 {
    return spawnAndWait(allocator, .{
        .argv = &.{ getDefaultShell(), getShellFlag(), cmd_str },
    });
}

/// Execute a shell command and capture its stdout.
pub fn shellCapture(allocator: std.mem.Allocator, cmd_str: []const u8) !CaptureResult {
    return captureOutput(allocator, .{
        .argv = &.{ getDefaultShell(), getShellFlag(), cmd_str },
    });
}

// =============================================================================
// POSIX Implementation
// =============================================================================

fn spawnAndWaitPosix(allocator: std.mem.Allocator, opts: SpawnOptions) !i32 {
    const pid = try forkAndExecPosix(allocator, opts);

    var wait_status: c_int = 0;
    if (comptime builtin.os.tag != .windows) {
        _ = process.waitpidIntr(pid, &wait_status, 0);
    }
    const status_u32: u32 = @bitCast(wait_status);

    if (posix.W.IFEXITED(status_u32)) {
        return @intCast(posix.W.EXITSTATUS(status_u32));
    } else if (posix.W.IFSIGNALED(status_u32)) {
        const sig: i32 = @intCast(@intFromEnum(posix.W.TERMSIG(status_u32)));
        return 128 + sig;
    }
    return 1;
}

fn spawnBackgroundPosix(allocator: std.mem.Allocator, opts: SpawnOptions) !process.ProcessId {
    return forkAndExecPosix(allocator, opts);
}

fn captureOutputPosix(allocator: std.mem.Allocator, opts: SpawnOptions) !CaptureResult {
    var pipe_fds: [2]posix.fd_t = undefined;
    if (std.c.pipe(&pipe_fds) != 0) return error.Unexpected;
    const read_end = pipe_fds[0];
    const write_end = pipe_fds[1];

    // Create modified opts with stdout redirected to pipe
    var modified_opts = opts;
    modified_opts.stdout_fd = write_end;
    // Also redirect stderr to /dev/null if not explicitly set
    // (matching the pattern from expansion.zig)

    const pid = forkAndExecPosix(allocator, modified_opts) catch |err| {
        _ = std.c.close(read_end);
        _ = std.c.close(write_end);
        return err;
    };

    // Parent: close write end, read from read end
    _ = std.c.close(write_end);

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = posix.read(read_end, &buf) catch break;
        if (n == 0) break;
        try output.appendSlice(allocator, buf[0..n]);
    }
    _ = std.c.close(read_end);

    // Wait for child
    var wait_status: c_int = 0;
    if (comptime builtin.os.tag != .windows) {
        _ = process.waitpidIntr(pid, &wait_status, 0);
    }
    const status_u32: u32 = @bitCast(wait_status);

    var exit_code: i32 = 1;
    if (posix.W.IFEXITED(status_u32)) {
        exit_code = @intCast(posix.W.EXITSTATUS(status_u32));
    }

    // Trim trailing newlines (matching expansion.zig behavior) BEFORE taking
    // ownership: re-slicing the owned slice would leave its length out of sync
    // with the underlying allocation, tripping the allocator's free-size check.
    while (output.items.len > 0 and output.items[output.items.len - 1] == '\n') {
        _ = output.pop();
    }
    const result = try output.toOwnedSlice(allocator);

    return CaptureResult{
        .stdout = result,
        .exit_code = exit_code,
    };
}

/// The core POSIX fork+exec. Returns the child PID.
fn forkAndExecPosix(allocator: std.mem.Allocator, opts: SpawnOptions) !posix.pid_t {
    // Build null-terminated argv
    const argv_buf = try allocator.alloc(?[*:0]const u8, opts.argv.len + 1);
    defer allocator.free(argv_buf);

    var arg_zs = try allocator.alloc([:0]u8, opts.argv.len);
    defer {
        for (arg_zs) |z| allocator.free(z);
        allocator.free(arg_zs);
    }

    for (opts.argv, 0..) |arg, i| {
        arg_zs[i] = try allocator.dupeSentinel(u8, arg, 0);
        argv_buf[i] = arg_zs[i].ptr;
    }
    argv_buf[opts.argv.len] = null;

    const argv_ptr: [*:null]const ?[*:0]const u8 = @ptrCast(argv_buf.ptr);

    const fork_ret = std.c.fork();
    if (fork_ret < 0) return error.Unexpected;
    const pid: posix.pid_t = @intCast(fork_ret);

    if (pid == 0) {
        // Child process: apply redirections
        if (opts.stdin_fd) |fd| {
            if (std.c.dup2(fd, posix.STDIN_FILENO) < 0) std.c._exit(1);
            _ = std.c.close(fd);
        }
        if (opts.stdout_fd) |fd| {
            if (std.c.dup2(fd, posix.STDOUT_FILENO) < 0) std.c._exit(1);
            _ = std.c.close(fd);
        }
        if (opts.stderr_fd) |fd| {
            if (std.c.dup2(fd, posix.STDERR_FILENO) < 0) std.c._exit(1);
            _ = std.c.close(fd);
        }

        // Change cwd if requested
        if (opts.cwd) |cwd| {
            const cwd_z = allocator.dupeSentinel(u8, cwd, 0) catch std.c._exit(1);
            _ = std.c.chdir(cwd_z.ptr);
        }

        // Exec
        if (opts.env) |env| {
            // Set environ directly in child process, then execvp
            // (execvpe is a GNU extension, not portable)
            const c_environ = @extern(*[*:null]?[*:0]u8, .{ .name = "environ" });
            c_environ.* = @ptrCast(@constCast(env));
            _ = cExecvp(argv_buf[0].?, argv_ptr);
        } else {
            _ = cExecvp(argv_buf[0].?, argv_ptr);
        }
        // exec failed
        std.c._exit(127);
    }

    // Parent
    return pid;
}

// C extern for execvp
const cExecvp = if (is_windows) struct {
    fn execvp(_: [*:0]const u8, _: [*:null]const ?[*:0]const u8) c_int {
        return -1;
    }
}.execvp else struct {
    extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
}.execvp;

// =============================================================================
// Windows Implementation (uses Zig 0.16 std.process.spawn API)
// =============================================================================

fn spawnAndWaitWindows(allocator: std.mem.Allocator, opts: SpawnOptions) !i32 {
    _ = allocator;
    var child = try std.process.spawn(std.Options.debug_io, buildSpawnOptions(opts));
    const term = try child.wait(std.Options.debug_io);
    return switch (term) {
        .exited => |code| @as(i32, @intCast(code)),
        .signal => 128,
        .stopped => 128,
        .unknown => 1,
    };
}

fn spawnBackgroundWindows(allocator: std.mem.Allocator, opts: SpawnOptions) !process.ProcessId {
    _ = allocator;
    const child = try std.process.spawn(std.Options.debug_io, buildSpawnOptions(opts));
    return child.id orelse return error.Unexpected;
}

fn captureOutputWindows(allocator: std.mem.Allocator, opts: SpawnOptions) !CaptureResult {
    var spawn_opts = buildSpawnOptions(opts);
    spawn_opts.stdout = .pipe;
    spawn_opts.stderr = .ignore;

    var child = try std.process.spawn(std.Options.debug_io, spawn_opts);

    // Read stdout
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    if (child.stdout) |stdout| {
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = stdout.readStreaming(std.Options.debug_io, &.{&buf}) catch break;
            if (n == 0) break;
            try output.appendSlice(allocator, buf[0..n]);
        }
    }

    const term = child.wait(std.Options.debug_io) catch {
        return CaptureResult{ .stdout = try output.toOwnedSlice(allocator), .exit_code = 1 };
    };
    const exit_code: i32 = switch (term) {
        .exited => |code| @intCast(code),
        else => 1,
    };

    var result = try output.toOwnedSlice(allocator);
    while (result.len > 0 and result[result.len - 1] == '\n') {
        result = result[0 .. result.len - 1];
    }

    return CaptureResult{
        .stdout = result,
        .exit_code = exit_code,
    };
}

fn buildSpawnOptions(opts: SpawnOptions) std.process.SpawnOptions {
    return .{
        .argv = opts.argv,
        .cwd = if (opts.cwd) |cwd| .{ .path = cwd } else .inherit,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    };
}

// =============================================================================
// Pipeline Helpers
// =============================================================================

/// Spawn a pipeline of processes connected by pipes.
/// POSIX: uses fork/pipe/dup2. Windows: uses std.process.Child with pipes.
pub fn spawnPipeline(
    allocator: std.mem.Allocator,
    commands: []const SpawnOptions,
) !PipelineResult {
    if (is_windows) {
        return spawnPipelineWindows(allocator, commands);
    } else {
        return spawnPipelinePosix(allocator, commands);
    }
}

pub const PipelineResult = struct {
    exit_code: i32,
    pipefail_code: i32,
};

fn spawnPipelinePosix(allocator: std.mem.Allocator, commands: []const SpawnOptions) !PipelineResult {
    const num_pipes = commands.len - 1;
    if (num_pipes > 16) return error.TooManyPipes;

    var pipes_buffer: [16][2]posix.fd_t = undefined;
    for (0..num_pipes) |i| {
        var fds: [2]posix.fd_t = undefined;
        if (std.c.pipe(&fds) != 0) return error.Unexpected;
        pipes_buffer[i] = fds;
    }

    var pids_buffer: [17]posix.pid_t = undefined;

    for (commands, 0..) |cmd, i| {
        var modified = cmd;

        // Connect stdin from previous pipe
        if (i > 0) {
            modified.stdin_fd = pipes_buffer[i - 1][0];
        }
        // Connect stdout to next pipe
        if (i < num_pipes) {
            modified.stdout_fd = pipes_buffer[i][1];
        }

        pids_buffer[i] = try forkAndExecPosix(allocator, modified);
    }

    // Parent: close all pipe fds
    for (0..num_pipes) |i| {
        _ = std.c.close(pipes_buffer[i][0]);
        _ = std.c.close(pipes_buffer[i][1]);
    }

    // Wait for all children
    var last_status: i32 = 0;
    var pipefail_status: i32 = 0;
    for (pids_buffer[0..commands.len]) |pid| {
        var wait_status: c_int = 0;
        if (comptime builtin.os.tag != .windows) {
            _ = process.waitpidIntr(pid, &wait_status, 0);
        }
        const status_u32: u32 = @bitCast(wait_status);
        const status: i32 = @intCast(posix.W.EXITSTATUS(status_u32));
        last_status = status;
        if (status != 0) pipefail_status = status;
    }

    return PipelineResult{
        .exit_code = last_status,
        .pipefail_code = pipefail_status,
    };
}

fn spawnPipelineWindows(allocator: std.mem.Allocator, commands: []const SpawnOptions) !PipelineResult {
    // Windows pipeline: spawn each process with pipes connecting them
    if (commands.len == 0) return PipelineResult{ .exit_code = 0, .pipefail_code = 0 };
    if (commands.len == 1) {
        const code = try spawnAndWaitWindows(allocator, commands[0]);
        return PipelineResult{ .exit_code = code, .pipefail_code = if (code != 0) code else 0 };
    }

    // For multi-command pipelines on Windows, use shell to handle piping
    // Build a combined command string
    var cmd_buf = std.ArrayList(u8).empty;
    defer cmd_buf.deinit(allocator);

    for (commands, 0..) |cmd, i| {
        if (i > 0) try cmd_buf.appendSlice(allocator, " | ");
        for (cmd.argv, 0..) |arg, j| {
            if (j > 0) try cmd_buf.append(allocator, ' ');
            try cmd_buf.appendSlice(allocator, arg);
        }
    }

    const cmd_str = try cmd_buf.toOwnedSlice(allocator);
    defer allocator.free(cmd_str);
    const code = try shellExec(allocator, cmd_str);
    return PipelineResult{ .exit_code = code, .pipefail_code = if (code != 0) code else 0 };
}

// =============================================================================
// Tests
// =============================================================================

test "getDefaultShell returns valid path" {
    const shell = getDefaultShell();
    if (is_windows) {
        try std.testing.expectEqualStrings("cmd.exe", shell);
    } else {
        try std.testing.expectEqualStrings("/bin/sh", shell);
    }
}

test "getDevNull returns valid path" {
    const devnull = getDevNull();
    if (is_windows) {
        try std.testing.expectEqualStrings("NUL", devnull);
    } else {
        try std.testing.expectEqualStrings("/dev/null", devnull);
    }
}

test "getShellFlag returns valid flag" {
    const flag = getShellFlag();
    if (is_windows) {
        try std.testing.expectEqualStrings("/c", flag);
    } else {
        try std.testing.expectEqualStrings("-c", flag);
    }
}
