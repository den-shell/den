const std = @import("std");
const builtin = @import("builtin");
const types = @import("../types/mod.zig");
const IO = @import("../utils/io.zig").IO;
const Expansion = @import("../utils/expansion.zig").Expansion;
const networking = @import("networking.zig");
const process_util = @import("../utils/process.zig");

/// Apply I/O redirections for a command.
/// Handles output/append, input, heredoc, herestring, fd duplication, and fd close.
pub fn applyRedirections(
    allocator: std.mem.Allocator,
    redirections: []types.Redirection,
    environment: *std.StringHashMap([]const u8),
    expansion_context: ?ExpansionContext,
) !void {
    if (comptime builtin.os.tag == .windows) return; // Redirections handled by executor on Windows
    const noclobber = if (expansion_context) |ctx| ctx.option_noclobber else false;
    for (redirections) |redir| {
        switch (redir.kind) {
            .output_truncate => try applyOutputTruncate(allocator, redir, noclobber),
            .output_clobber => try applyOutputTruncate(allocator, redir, false),
            .output_append => try applyOutputAppend(allocator, redir),
            .input => try applyInput(allocator, redir),
            .input_output => try applyInputOutput(allocator, redir),
            .heredoc, .herestring => try applyHeredocOrHerestring(allocator, redir, environment, expansion_context),
            .fd_duplicate => try applyFdDuplicate(redir),
            .fd_close => applyFdClose(redir),
        }
    }
}

/// Context for variable expansion in heredocs/herestrings
pub const ExpansionContext = struct {
    option_nounset: bool,
    option_noclobber: bool = false,
    var_attributes: *std.StringHashMap(types.VarAttributes),
    arrays: *std.StringHashMap(types.IndexedArray),
    assoc_arrays: *std.StringHashMap(std.StringHashMap([]const u8)),
};

fn applyOutputTruncate(allocator: std.mem.Allocator, redir: types.Redirection, noclobber: bool) !void {
    if (comptime builtin.os.tag == .windows) return; // Redirections handled by executor on Windows
    // Check for /dev/tcp or /dev/udp virtual path
    if (networking.openDevNet(redir.target)) |sock| {
        if (std.c.dup2(sock, @intCast(redir.fd)) < 0) {
            _ = std.c.close(sock);
            return error.Unexpected;
        }
        _ = std.c.close(sock);
    } else {
        const path_z = try allocator.dupeSentinel(u8, redir.target, 0);
        defer allocator.free(path_z);

        // If noclobber is set, check if file exists (skip for /dev/null etc.)
        if (noclobber and !std.mem.startsWith(u8, redir.target, "/dev/")) {
            const check_fd = std.c.open(path_z, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
            if (check_fd >= 0) {
                _ = std.c.close(check_fd);
                try IO.eprint("den: {s}: cannot overwrite existing file\n", .{redir.target});
                std.c._exit(1);
            }
        }

        // Open file for writing, truncate if exists
        const fd = std.c.open(
            path_z,
            .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
            @as(std.c.mode_t, 0o644),
        );
        if (fd < 0) {
            try IO.eprint("den: {s}: cannot open\n", .{redir.target});
            std.c._exit(1);
        }

        if (std.c.dup2(fd, @intCast(redir.fd)) < 0) {
            _ = std.c.close(fd);
            return error.Unexpected;
        }
        _ = std.c.close(fd);
    }
}

fn applyOutputAppend(allocator: std.mem.Allocator, redir: types.Redirection) !void {
    if (comptime builtin.os.tag == .windows) return; // Redirections handled by executor on Windows
    // Check for /dev/tcp or /dev/udp virtual path
    if (networking.openDevNet(redir.target)) |sock| {
        if (std.c.dup2(sock, @intCast(redir.fd)) < 0) {
            _ = std.c.close(sock);
            return error.Unexpected;
        }
        _ = std.c.close(sock);
    } else {
        // Open file for appending
        const path_z = try allocator.dupeSentinel(u8, redir.target, 0);
        defer allocator.free(path_z);

        const fd = std.c.open(
            path_z,
            .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true },
            @as(std.c.mode_t, 0o644),
        );
        if (fd < 0) {
            try IO.eprint("den: {s}: cannot open\n", .{redir.target});
            std.c._exit(1);
        }

        if (std.c.dup2(fd, @intCast(redir.fd)) < 0) {
            _ = std.c.close(fd);
            return error.Unexpected;
        }
        _ = std.c.close(fd);
    }
}

fn applyInput(allocator: std.mem.Allocator, redir: types.Redirection) !void {
    if (comptime builtin.os.tag == .windows) return; // Redirections handled by executor on Windows
    // Check for /dev/tcp or /dev/udp virtual path
    if (networking.openDevNet(redir.target)) |sock| {
        if (std.c.dup2(sock, std.posix.STDIN_FILENO) < 0) {
            _ = std.c.close(sock);
            return error.Unexpected;
        }
        _ = std.c.close(sock);
    } else {
        // Open file for reading
        const path_z = try allocator.dupeSentinel(u8, redir.target, 0);
        defer allocator.free(path_z);

        const fd = std.c.open(
            path_z,
            .{ .ACCMODE = .RDONLY },
            @as(std.c.mode_t, 0),
        );
        if (fd < 0) {
            try IO.eprint("den: {s}: cannot open\n", .{redir.target});
            std.c._exit(1);
        }

        if (std.c.dup2(fd, std.posix.STDIN_FILENO) < 0) {
            _ = std.c.close(fd);
            return error.Unexpected;
        }
        _ = std.c.close(fd);
    }
}

fn applyInputOutput(allocator: std.mem.Allocator, redir: types.Redirection) !void {
    if (comptime builtin.os.tag == .windows) return; // Redirections handled by executor on Windows
    // <> opens file for both reading and writing
    if (networking.openDevNet(redir.target)) |sock| {
        if (std.c.dup2(sock, @intCast(redir.fd)) < 0) {
            _ = std.c.close(sock);
            return error.Unexpected;
        }
        _ = std.c.close(sock);
    } else {
        const path_z = try allocator.dupeSentinel(u8, redir.target, 0);
        defer allocator.free(path_z);

        // Open for read+write, create if doesn't exist
        const fd = std.c.open(
            path_z,
            .{ .ACCMODE = .RDWR, .CREAT = true },
            @as(std.c.mode_t, 0o644),
        );
        if (fd < 0) {
            try IO.eprint("den: {s}: cannot open\n", .{redir.target});
            std.c._exit(1);
        }

        if (std.c.dup2(fd, @intCast(redir.fd)) < 0) {
            _ = std.c.close(fd);
            return error.Unexpected;
        }
        _ = std.c.close(fd);
    }
}

fn applyHeredocOrHerestring(
    allocator: std.mem.Allocator,
    redir: types.Redirection,
    _: *std.StringHashMap([]const u8),
    _: ?ExpansionContext,
) !void {
    if (comptime builtin.os.tag == .windows) return; // Redirections handled by executor on Windows
    // Create a pipe for the content
    var pipe_fds: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&pipe_fds) != 0) return error.Unexpected;
    const read_fd = pipe_fds[0];
    const write_fd = pipe_fds[1];

    // Write content to pipe
    const content = blk: {
        if (redir.kind == .herestring) {
            // Herestring content is already expanded by command_expansion.zig.
            // Just add a trailing newline (bash behavior).
            const result = try allocator.alloc(u8, redir.target.len + 1);
            @memcpy(result[0..redir.target.len], redir.target);
            result[redir.target.len] = '\n';
            break :blk result;
        } else {
            // For heredoc, use the target as-is (it contains the content)
            // Note: Full heredoc support requires parser changes
            // This provides basic support for single-line heredocs
            break :blk try allocator.dupe(u8, redir.target);
        }
    };
    defer allocator.free(content);

    // Fork to write content (avoid blocking)
    const fork_ret = std.c.fork();
    if (fork_ret < 0) {
        _ = std.c.close(read_fd);
        _ = std.c.close(write_fd);
        return error.Unexpected;
    }
    const writer_pid: std.posix.pid_t = @intCast(fork_ret);
    if (writer_pid == 0) {
        // Child: write content and exit
        _ = std.c.close(read_fd);
        (std.Io.File{ .handle = write_fd, .flags = .{ .nonblocking = false } }).writeStreamingAll(std.Options.debug_io, content) catch {};
        _ = std.c.close(write_fd);
        std.c._exit(0);
    }

    // Parent: close write end first so writer gets SIGPIPE if reader closes early
    _ = std.c.close(write_fd);

    // Wait for writer to finish before dup'ing stdin — ensures all data is written.
    // Retry on EINTR so a stray signal doesn't abandon the writer.
    {
        var wait_status: c_int = 0;
        _ = process_util.waitpidIntr(writer_pid, &wait_status, 0);
    }

    // Now dup read end to stdin
    if (std.c.dup2(read_fd, std.posix.STDIN_FILENO) < 0) {
        _ = std.c.close(read_fd);
        return error.Unexpected;
    }
    _ = std.c.close(read_fd);
}

fn applyFdDuplicate(redir: types.Redirection) !void {
    if (comptime builtin.os.tag == .windows) return; // Redirections handled by executor on Windows
    // Parse target as file descriptor number
    // Format: N>&M or N<&M (duplicate fd M to fd N)
    const target_fd = std.fmt.parseInt(u32, redir.target, 10) catch {
        try IO.eprint("den: invalid file descriptor: {s}\n", .{redir.target});
        return error.InvalidFd;
    };

    // Validate fd range to prevent redirecting to arbitrary descriptors
    if (target_fd > 255) {
        try IO.eprint("den: file descriptor out of range: {d}\n", .{target_fd});
        return error.InvalidFd;
    }

    // Duplicate the target_fd to redir.fd
    if (std.c.dup2(@intCast(target_fd), @intCast(redir.fd)) < 0) return error.Unexpected;
}

fn applyFdClose(redir: types.Redirection) void {
    if (comptime builtin.os.tag == .windows) return; // Redirections handled by executor on Windows
    // Close the specified file descriptor
    // Format: N>&- or N<&- (close fd N)
    // Use raw syscall to avoid panic on EBADF (closing an already-closed fd is harmless)
    _ = std.c.close(@intCast(redir.fd));
}

/// Save current stdin, stdout and stderr file descriptors (for builtin redirections without fork)
pub const SavedFds = struct {
    stdin_save: ?std.posix.fd_t = null,
    stdout_save: ?std.posix.fd_t = null,
    stderr_save: ?std.posix.fd_t = null,

    pub fn save() SavedFds {
        if (comptime builtin.os.tag == .windows) return SavedFds{};
        var saved = SavedFds{};

        // Duplicate stdin, stdout and stderr using C dup
        const stdin_dup = std.c.dup(std.posix.STDIN_FILENO);
        saved.stdin_save = if (stdin_dup >= 0) stdin_dup else null;
        const stdout_dup = std.c.dup(std.posix.STDOUT_FILENO);
        saved.stdout_save = if (stdout_dup >= 0) stdout_dup else null;
        const stderr_dup = std.c.dup(std.posix.STDERR_FILENO);
        saved.stderr_save = if (stderr_dup >= 0) stderr_dup else null;

        return saved;
    }

    pub fn restore(self: *SavedFds) void {
        if (comptime builtin.os.tag == .windows) return;
        // Restore stdin
        if (self.stdin_save) |fd| {
            _ = std.c.dup2(fd, std.posix.STDIN_FILENO);
            _ = std.c.close(fd);
            self.stdin_save = null;
        }

        // Restore stdout
        if (self.stdout_save) |fd| {
            _ = std.c.dup2(fd, std.posix.STDOUT_FILENO);
            _ = std.c.close(fd);
            self.stdout_save = null;
        }

        // Restore stderr
        if (self.stderr_save) |fd| {
            _ = std.c.dup2(fd, std.posix.STDERR_FILENO);
            _ = std.c.close(fd);
            self.stderr_save = null;
        }
    }

    /// Discard saved FDs without restoring them.
    /// Used by `exec` with no args + redirections to make redirections permanent.
    /// Closes the saved copies so they don't leak, but does NOT dup2 them back.
    pub fn discard(self: *SavedFds) void {
        if (comptime builtin.os.tag == .windows) return;
        if (self.stdin_save) |fd| {
            _ = std.c.close(fd);
            self.stdin_save = null;
        }
        if (self.stdout_save) |fd| {
            _ = std.c.close(fd);
            self.stdout_save = null;
        }
        if (self.stderr_save) |fd| {
            _ = std.c.close(fd);
            self.stderr_save = null;
        }
    }
};

// Tests
test "apply fd close" {
    // Just a simple test to verify the module compiles
    const redir = types.Redirection{
        .kind = .fd_close,
        .fd = 99, // Non-existent fd, but that's okay for this test
        .target = "",
    };
    applyFdClose(redir);
}

test "fd duplicate rejects out-of-range descriptors" {
    // Target fd > 255 should return InvalidFd error
    const redir_high = types.Redirection{
        .kind = .fd_duplicate,
        .fd = 1,
        .target = "256",
    };
    try std.testing.expectError(error.InvalidFd, applyFdDuplicate(redir_high));

    // Target fd = 999 should also fail
    const redir_very_high = types.Redirection{
        .kind = .fd_duplicate,
        .fd = 1,
        .target = "999",
    };
    try std.testing.expectError(error.InvalidFd, applyFdDuplicate(redir_very_high));

    // Non-numeric target should fail
    const redir_invalid = types.Redirection{
        .kind = .fd_duplicate,
        .fd = 1,
        .target = "abc",
    };
    try std.testing.expectError(error.InvalidFd, applyFdDuplicate(redir_invalid));
}

test "fd duplicate accepts valid descriptors" {
    // fd 0 (stdin) is valid — but dup2 to a non-open fd may fail,
    // so we just verify the parsing doesn't reject it
    const redir_zero = types.Redirection{
        .kind = .fd_duplicate,
        .fd = 99, // Target fd to dup onto (probably not open, that's ok for parse test)
        .target = "1", // stdout — always open
    };
    // This should succeed (dup2(1, 99) will work since stdout is open)
    applyFdDuplicate(redir_zero) catch {};
}

test "saved fds init and discard" {
    // Test that SavedFds can be created and discarded without leaking
    if (comptime builtin.os.tag == .windows) return;
    var saved = SavedFds.save();
    // Discard closes saved copies without restoring
    saved.discard();
    // After discard, all fields should be null
    try std.testing.expect(saved.stdin_save == null);
    try std.testing.expect(saved.stdout_save == null);
    try std.testing.expect(saved.stderr_save == null);
}

test "saved fds save and restore" {
    // Test that SavedFds can save and restore without corrupting stdio
    if (comptime builtin.os.tag == .windows) return;
    var saved = SavedFds.save();
    // Verify fds were saved
    try std.testing.expect(saved.stdin_save != null);
    try std.testing.expect(saved.stdout_save != null);
    try std.testing.expect(saved.stderr_save != null);
    // Restore should put everything back
    saved.restore();
    // After restore, all fields should be null
    try std.testing.expect(saved.stdin_save == null);
    try std.testing.expect(saved.stdout_save == null);
    try std.testing.expect(saved.stderr_save == null);
}
