const std = @import("std");
const types = @import("../types/mod.zig");
const IO = @import("../utils/io.zig").IO;
const builtin = @import("builtin");
const spawn = @import("../utils/spawn.zig");
const process_util = @import("../utils/process.zig");

/// Pipeline execution for connecting multiple commands with pipes.
/// Handles both POSIX (fork/pipe) and Windows (CreateProcess) implementations.
/// Maximum number of pipes supported in a single pipeline
pub const MAX_PIPES = 16;

/// Pipeline execution result
pub const PipelineResult = struct {
    exit_code: i32,
    pipefail_code: i32, // Rightmost non-zero exit code (for pipefail option)
};

/// Execute a pipeline of commands on POSIX systems.
/// Creates pipes to connect stdout of each command to stdin of the next.
/// Returns the exit code of the last command (or pipefail code if enabled).
pub fn executePosix(
    allocator: std.mem.Allocator,
    commands: []types.ParsedCommand,
    isBuiltinFn: *const fn ([]const u8) bool,
    executeBuiltinFn: *const fn (*types.ParsedCommand) anyerror!i32,
    executeExternalFn: *const fn (*types.ParsedCommand) anyerror!void,
    applyRedirectionsFn: *const fn ([]types.Redirection) anyerror!void,
) !PipelineResult {
    _ = allocator;

    // Create pipes for communication
    var pipes_buffer: [MAX_PIPES][2]std.posix.fd_t = undefined;
    const num_pipes = commands.len - 1;

    if (num_pipes > MAX_PIPES) return error.TooManyPipes;

    // Create all pipes, cleaning up on partial failure
    var pipes_created: usize = 0;
    errdefer for (0..pipes_created) |j| {
        _ = std.c.close(pipes_buffer[j][0]);
        _ = std.c.close(pipes_buffer[j][1]);
    };
    for (0..num_pipes) |i| {
        var fds: [2]std.posix.fd_t = undefined;
        if (std.c.pipe(&fds) != 0) return error.Unexpected;
        pipes_buffer[i] = fds;
        pipes_created += 1;
    }

    // Spawn all commands in the pipeline
    var pids_buffer: [MAX_PIPES + 1]std.posix.pid_t = undefined;

    for (commands, 0..) |*cmd, i| {
        const fork_ret = std.c.fork();
        if (fork_ret < 0) return error.Unexpected;
        const pid: std.posix.pid_t = @intCast(fork_ret);

        if (pid == 0) {
            // Child process — dup2 failures here must terminate the child
            // immediately; returning an error would continue executing the
            // command with unredirected fds.

            // Set up stdin from previous pipe
            if (i > 0) {
                if (std.c.dup2(pipes_buffer[i - 1][0], std.posix.STDIN_FILENO) < 0) std.c._exit(1);
            }

            // Set up stdout to next pipe
            if (i < num_pipes) {
                if (std.c.dup2(pipes_buffer[i][1], std.posix.STDOUT_FILENO) < 0) std.c._exit(1);
            }

            // Close all pipe fds in child
            for (0..num_pipes) |j| {
                _ = std.c.close(pipes_buffer[j][0]);
                _ = std.c.close(pipes_buffer[j][1]);
            }

            // Apply redirections
            applyRedirectionsFn(cmd.redirections) catch {
                std.c._exit(1);
            };

            // Execute the command
            if (isBuiltinFn(cmd.name)) {
                const exit_code = executeBuiltinFn(cmd) catch 1;
                std.c._exit(@intCast(exit_code));
            } else {
                executeExternalFn(cmd) catch {
                    std.c._exit(127);
                };
                // executeExternalFn normally execves and does not return;
                // if it does, terminate the child explicitly.
                std.c._exit(0);
            }
        } else {
            // Parent - store pid
            pids_buffer[i] = pid;
        }
    }

    // Parent: close all pipes
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
            // Retry on EINTR so that incoming signals don't leave children as
            // zombies or cause us to read uninitialized wait_status.
            _ = process_util.waitpidIntr(pid, &wait_status, 0);
        }
        const raw_status: u32 = @bitCast(wait_status);
        var status: i32 = undefined;
        if (comptime builtin.os.tag != .windows) {
            if (std.posix.W.IFSIGNALED(raw_status)) {
                // Process was killed by a signal: exit code = 128 + signal_number (bash convention)
                status = 128 + @as(i32, @intCast(@backingInt(std.posix.W.TERMSIG(raw_status))));
            } else {
                status = @intCast(std.posix.W.EXITSTATUS(raw_status));
            }
        } else {
            status = @intCast(std.posix.W.EXITSTATUS(raw_status));
        }
        last_status = status;
        // For pipefail: track rightmost non-zero exit status
        if (status != 0) {
            pipefail_status = status;
        }
    }

    return PipelineResult{
        .exit_code = last_status,
        .pipefail_code = pipefail_status,
    };
}

/// Execute a pipeline on Windows by building a combined command string
/// and delegating to the system shell (cmd.exe) which handles pipes natively.
pub fn executeWindows(
    allocator: std.mem.Allocator,
    commands: []types.ParsedCommand,
) !PipelineResult {
    // Calculate total length for the combined command string
    var total_len: usize = 0;
    for (commands, 0..) |cmd, i| {
        if (i > 0) total_len += 3; // " | "
        total_len += cmd.name.len;
        for (cmd.args) |arg| {
            total_len += 1 + arg.len; // " " + arg
        }
    }

    var cmd_buf = try allocator.alloc(u8, total_len + 1);
    defer allocator.free(cmd_buf);
    var pos: usize = 0;

    for (commands, 0..) |cmd, i| {
        if (i > 0) {
            @memcpy(cmd_buf[pos..][0..3], " | ");
            pos += 3;
        }
        @memcpy(cmd_buf[pos..][0..cmd.name.len], cmd.name);
        pos += cmd.name.len;
        for (cmd.args) |arg| {
            cmd_buf[pos] = ' ';
            pos += 1;
            @memcpy(cmd_buf[pos..][0..arg.len], arg);
            pos += arg.len;
        }
    }

    const exit_code = spawn.shellExec(allocator, cmd_buf[0..pos]) catch {
        return PipelineResult{ .exit_code = 1, .pipefail_code = 1 };
    };

    return PipelineResult{
        .exit_code = exit_code,
        .pipefail_code = exit_code,
    };
}

/// Check if the current platform supports native pipelines
pub fn supportsNativePipelines() bool {
    return builtin.os.tag != .windows;
}

// Tests
test "pipeline constants" {
    try std.testing.expect(MAX_PIPES >= 16);
}

test "pipeline result struct" {
    const result = PipelineResult{
        .exit_code = 0,
        .pipefail_code = 0,
    };
    try std.testing.expectEqual(@as(i32, 0), result.exit_code);
    try std.testing.expectEqual(@as(i32, 0), result.pipefail_code);

    // Non-zero pipefail with zero last exit
    const result2 = PipelineResult{
        .exit_code = 0,
        .pipefail_code = 1,
    };
    try std.testing.expectEqual(@as(i32, 0), result2.exit_code);
    try std.testing.expectEqual(@as(i32, 1), result2.pipefail_code);
}

test "supports native pipelines" {
    // On non-Windows, should return true
    if (comptime builtin.os.tag != .windows) {
        try std.testing.expect(supportsNativePipelines());
    }
}
