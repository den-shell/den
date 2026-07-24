const std = @import("std");
const builtin = @import("builtin");
const IO = @import("../utils/io.zig").IO;
const types = @import("../types/mod.zig");
const process = @import("../utils/process.zig");

/// Job status enum representing the current state of a background job.
pub const JobStatus = enum {
    running,
    stopped,
    done,
};

/// Cross-platform process ID type.
pub const ProcessId = if (builtin.os.tag == .windows) std.os.windows.HANDLE else std.posix.pid_t;

/// Background job information structure.
pub const BackgroundJob = struct {
    pid: ProcessId,
    job_id: usize,
    command: []const u8,
    status: JobStatus,
};

/// Maximum number of background jobs supported.
pub const MAX_JOBS = 16;

/// Extract exit status from wait status (cross-platform).
fn getExitStatus(status: u32) i32 {
    if (builtin.os.tag == .windows) {
        return @intCast(status);
    } else {
        return std.posix.W.EXITSTATUS(status);
    }
}

/// Job Manager handles all background job operations.
///
/// Centralizes job control functionality including:
/// - Adding and tracking background jobs
/// - Checking job status (non-blocking)
/// - Killing jobs on shutdown
/// - Supporting builtins: jobs, fg, bg, disown, wait
pub const JobManager = struct {
    allocator: std.mem.Allocator,
    jobs: [MAX_JOBS]?BackgroundJob,
    job_count: usize,
    next_job_id: usize,
    last_background_pid: ProcessId,
    interactive: bool,

    const Self = @This();

    /// Initialize a new JobManager.
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .jobs = @splat(null),
            .job_count = 0,
            .next_job_id = 1,
            .last_background_pid = if (builtin.os.tag == .windows) std.os.windows.INVALID_HANDLE_VALUE else 0,
            .interactive = false,
        };
    }

    /// Deinitialize and clean up all jobs.
    pub fn deinit(self: *Self) void {
        self.killAll();
        for (&self.jobs) |*maybe_job| {
            if (maybe_job.*) |job| {
                self.allocator.free(job.command);
                maybe_job.* = null;
            }
        }
    }

    /// Add a new background job.
    /// Returns error.TooManyBackgroundJobs if no slots available.
    pub fn add(self: *Self, pid: ProcessId, command: []const u8) !void {
        // Find first empty slot
        var slot_index: ?usize = null;
        for (self.jobs, 0..) |maybe_job, i| {
            if (maybe_job == null) {
                slot_index = i;
                break;
            }
        }

        if (slot_index == null) {
            return error.TooManyBackgroundJobs;
        }

        const job_id = self.next_job_id;
        self.next_job_id += 1;

        const command_copy = try self.allocator.dupe(u8, command);

        // Track last background PID
        self.last_background_pid = pid;

        self.jobs[slot_index.?] = BackgroundJob{
            .pid = pid,
            .job_id = job_id,
            .command = command_copy,
            .status = .running,
        };
        self.job_count += 1;

        if (self.interactive) {
            try IO.print("[{d}] {d}\n", .{ job_id, pid });
        }
    }

    /// Check for completed background jobs (non-blocking).
    /// Prints completion messages and removes finished jobs.
    pub fn checkCompleted(self: *Self) !void {
        if (builtin.os.tag == .windows) {
            // Windows: background jobs not fully implemented
            return;
        }

        var i: usize = 0;
        while (i < self.jobs.len) {
            if (self.jobs[i]) |job| {
                // Check if job has completed (non-blocking waitpid)
                var wait_status: c_int = 0;
                const wait_pid = if (comptime builtin.os.tag != .windows)
                    std.c.waitpid(job.pid, &wait_status, std.posix.W.NOHANG | std.c.W.UNTRACED)
                else
                    unreachable;

                if (wait_pid == job.pid) {
                    const raw: u32 = @bitCast(wait_status);
                    if (std.posix.W.IFSTOPPED(raw)) {
                        // Job was stopped (e.g. Ctrl+Z), mark as stopped but keep in table
                        self.jobs[i].?.status = .stopped;
                        i += 1;
                    } else {
                        // Job completed or was signaled
                        const exit_status = if (std.posix.W.IFSIGNALED(raw))
                            128 + @as(i32, @intCast(@intFromEnum(std.posix.W.TERMSIG(raw))))
                        else
                            getExitStatus(raw);
                        if (self.interactive) {
                            try IO.print("[{d}]  Done ({d})    {s}\n", .{ job.job_id, exit_status, job.command });
                        }

                        // Free command string and remove from array
                        self.allocator.free(job.command);
                        self.jobs[i] = null;
                        self.job_count -= 1;
                        // Don't increment i, check this slot again
                    }
                } else {
                    i += 1;
                }
            } else {
                i += 1;
            }
        }
    }

    /// Kill all background jobs (for graceful shutdown).
    pub fn killAll(self: *Self) void {
        if (builtin.os.tag == .windows) {
            // Windows: terminate processes using TerminateProcess
            for (self.jobs) |maybe_job| {
                if (maybe_job) |job| {
                    // On Windows, just terminate via the handle directly
                    _ = @import("windows_compat").TerminateProcess(job.pid, 1);
                }
            }
            return;
        }

        // Unix: send SIGTERM to all background jobs, then SIGKILL if needed
        for (self.jobs) |maybe_job| {
            if (maybe_job) |job| {
                if (job.status == .running) {
                    // First try SIGTERM for graceful termination
                    _ = std.posix.kill(job.pid, std.posix.SIG.TERM) catch {};

                    // Give process a short time to exit gracefully
                    std.Io.sleep(std.Options.debug_io, std.Io.Duration.fromNanoseconds(@as(i96, 100_000_000)), .awake) catch {}; // 100ms

                    // Check if still running
                    var kill_wait_status: c_int = 0;
                    const kill_wait_pid = if (comptime builtin.os.tag != .windows)
                        std.c.waitpid(job.pid, &kill_wait_status, std.posix.W.NOHANG)
                    else
                        unreachable;
                    if (kill_wait_pid == 0) {
                        // Still running, force kill
                        _ = std.posix.kill(job.pid, std.posix.SIG.KILL) catch {};
                        // Reap the zombie
                        var reap_status: c_int = 0;
                        if (comptime builtin.os.tag != .windows) {
                            _ = process.waitpidIntr(job.pid, &reap_status, 0);
                        }
                    }
                }
            }
        }
    }

    /// Find job by job ID.
    /// Returns the slot index if found.
    pub fn findByJobId(self: *Self, job_id: usize) ?usize {
        for (self.jobs, 0..) |maybe_job, i| {
            if (maybe_job) |job| {
                if (job.job_id == job_id) {
                    return i;
                }
            }
        }
        return null;
    }

    /// Find the most recent job (highest job ID).
    pub fn findMostRecent(self: *Self) ?usize {
        var max_id: usize = 0;
        var max_slot: ?usize = null;
        for (self.jobs, 0..) |maybe_job, i| {
            if (maybe_job) |job| {
                if (job.job_id > max_id) {
                    max_id = job.job_id;
                    max_slot = i;
                }
            }
        }
        return max_slot;
    }

    /// Find the most recent stopped job.
    pub fn findMostRecentStopped(self: *Self) ?usize {
        var max_id: usize = 0;
        var max_slot: ?usize = null;
        for (self.jobs, 0..) |maybe_job, i| {
            if (maybe_job) |job| {
                if (job.status == .stopped and job.job_id > max_id) {
                    max_id = job.job_id;
                    max_slot = i;
                }
            }
        }
        return max_slot;
    }

    /// Remove a job from the table and free its command string.
    pub fn remove(self: *Self, slot: usize) void {
        if (self.jobs[slot]) |job| {
            self.allocator.free(job.command);
            self.jobs[slot] = null;
            self.job_count -= 1;
        }
    }

    /// Get job at slot (read-only).
    pub fn get(self: *Self, slot: usize) ?BackgroundJob {
        return self.jobs[slot];
    }

    /// Get mutable pointer to job at slot.
    pub fn getMut(self: *Self, slot: usize) ?*BackgroundJob {
        if (self.jobs[slot] != null) {
            return &self.jobs[slot].?;
        }
        return null;
    }

    /// Get last background PID (for $! variable).
    pub fn getLastPid(self: *Self) ProcessId {
        return self.last_background_pid;
    }

    // ========================================
    // Builtin implementations
    // ========================================

    /// Builtin: jobs - list background jobs.
    /// Flags: -l (show PIDs), -p (PIDs only), -r (running), -s (stopped)
    pub fn builtinJobs(self: *Self, args: []const []const u8) !i32 {
        // Parse flags
        var show_pids = false;
        var pids_only = false;
        var running_only = false;
        var stopped_only = false;

        for (args) |arg| {
            if (arg.len > 0 and arg[0] == '-') {
                for (arg[1..]) |c| {
                    switch (c) {
                        'l' => show_pids = true,
                        'p' => pids_only = true,
                        'r' => running_only = true,
                        's' => stopped_only = true,
                        else => {
                            try IO.eprint("den: jobs: -{c}: invalid option\n", .{c});
                            return 1;
                        },
                    }
                }
            }
        }

        for (self.jobs) |maybe_job| {
            if (maybe_job) |job| {
                // Filter by status if requested
                if (running_only and job.status != .running) continue;
                if (stopped_only and job.status != .stopped) continue;

                if (pids_only) {
                    if (builtin.os.tag == .windows) {
                        try IO.print("{d}\n", .{@intFromPtr(job.pid)});
                    } else {
                        try IO.print("{d}\n", .{job.pid});
                    }
                } else if (show_pids) {
                    const status_str = switch (job.status) {
                        .running => "Running",
                        .stopped => "Stopped",
                        .done => "Done",
                    };
                    if (builtin.os.tag == .windows) {
                        try IO.print("[{d}]  {d} {s: <10} {s}\n", .{ job.job_id, @intFromPtr(job.pid), status_str, job.command });
                    } else {
                        try IO.print("[{d}]  {d} {s: <10} {s}\n", .{ job.job_id, job.pid, status_str, job.command });
                    }
                } else {
                    const status_str = switch (job.status) {
                        .running => "Running",
                        .stopped => "Stopped",
                        .done => "Done",
                    };
                    try IO.print("[{d}]  {s: <10} {s}\n", .{ job.job_id, status_str, job.command });
                }
            }
        }
        return 0;
    }

    /// Builtin: fg - bring background job to foreground.
    pub fn builtinFg(self: *Self, args: []const []const u8) !i32 {
        // Get job ID from argument (default to most recent)
        var job_slot: ?usize = null;

        if (args.len > 0) {
            var arg = args[0];
            if (arg.len > 0 and arg[0] == '%') {
                arg = arg[1..];
            }
            const job_id = std.fmt.parseInt(usize, arg, 10) catch {
                try IO.eprint("den: fg: {s}: no such job\n", .{args[0]});
                return 1;
            };
            job_slot = self.findByJobId(job_id);
            if (job_slot == null) {
                try IO.eprint("den: fg: {d}: no such job\n", .{job_id});
                return 1;
            }
        } else {
            job_slot = self.findMostRecent();
            if (job_slot == null) {
                try IO.eprint("den: fg: current: no such job\n", .{});
                return 1;
            }
        }

        const job = self.jobs[job_slot.?].?;
        try IO.print("{s}\n", .{job.command});

        // Wait for the job to complete
        var exit_status: i32 = 0;
        if (comptime builtin.os.tag == .windows) {
            const result = process.waitProcess(job.pid, .{}) catch {
                self.remove(job_slot.?);
                return 1;
            };
            exit_status = result.status.code;
        } else {
            // Send SIGCONT to resume the stopped process before waiting.
            // Use negative pid to target the entire process group.
            // Ignore errors: the process might already be running.
            _ = std.posix.kill(-job.pid, std.posix.SIG.CONT) catch {};

            var fg_wait_status: c_int = 0;
            // Retry on EINTR: SIGCHLD/SIGWINCH/etc. can interrupt this wait,
            // leaving an uninitialized status if we don't loop.
            _ = process.waitpidIntr(job.pid, &fg_wait_status, std.c.W.UNTRACED);

            const raw: u32 = @bitCast(fg_wait_status);
            if (std.posix.W.IFSTOPPED(raw)) {
                // Job was re-stopped (e.g. Ctrl+Z), keep in table
                if (job_slot) |slot| {
                    self.jobs[slot].?.status = .stopped;
                }
                try IO.print("\n", .{});
                exit_status = 128 + @as(i32, @intCast(@intFromEnum(std.posix.W.STOPSIG(raw))));
            } else if (std.posix.W.IFSIGNALED(raw)) {
                exit_status = 128 + @as(i32, @intCast(@intFromEnum(std.posix.W.TERMSIG(raw))));
                if (job_slot) |slot| self.remove(slot);
            } else {
                exit_status = getExitStatus(@as(u32, @bitCast(fg_wait_status)));
                if (job_slot) |slot| self.remove(slot);
            }
        }

        return exit_status;
    }

    /// Builtin: bg - continue stopped job in background.
    pub fn builtinBg(self: *Self, args: []const []const u8) !i32 {
        var job_slot: ?usize = null;

        if (args.len > 0) {
            var arg = args[0];
            if (arg.len > 0 and arg[0] == '%') {
                arg = arg[1..];
            }
            const job_id = std.fmt.parseInt(usize, arg, 10) catch {
                try IO.eprint("den: bg: {s}: no such job\n", .{args[0]});
                return 1;
            };
            job_slot = self.findByJobId(job_id);
            if (job_slot == null) {
                try IO.eprint("den: bg: {d}: no such job\n", .{job_id});
                return 1;
            }
        } else {
            job_slot = self.findMostRecentStopped();
            if (job_slot == null) {
                try IO.eprint("den: bg: current: no such job\n", .{});
                return 1;
            }
        }

        const job = self.jobs[job_slot.?].?;
        if (job.status != .stopped) {
            try IO.eprint("den: bg: job {d} already in background\n", .{job.job_id});
            return 1;
        }

        // Send SIGCONT to continue the job (Unix only)
        if (comptime builtin.os.tag != .windows) {
            _ = std.posix.kill(job.pid, std.posix.SIG.CONT) catch {};
        }
        // On Windows, we can't resume stopped processes

        // Mark as running
        self.jobs[job_slot.?].?.status = .running;
        try IO.print("[{d}]+ {s} &\n", .{ job.job_id, job.command });
        return 0;
    }

    /// Builtin: disown - remove job from job table without killing it.
    pub fn builtinDisown(self: *Self, args: []const []const u8) !i32 {
        var job_slot: ?usize = null;

        if (args.len > 0) {
            // Check for -h flag (keep in table but don't send SIGHUP)
            if (std.mem.eql(u8, args[0], "-h")) {
                // -h not fully implemented, just return success
                return 0;
            }
            // Check for -a flag (disown all)
            if (std.mem.eql(u8, args[0], "-a")) {
                for (&self.jobs) |*maybe_job| {
                    if (maybe_job.*) |job| {
                        self.allocator.free(job.command);
                        maybe_job.* = null;
                        self.job_count -= 1;
                    }
                }
                return 0;
            }

            var arg = args[0];
            if (arg.len > 0 and arg[0] == '%') {
                arg = arg[1..];
            }
            const job_id = std.fmt.parseInt(usize, arg, 10) catch {
                try IO.eprint("den: disown: {s}: no such job\n", .{args[0]});
                return 1;
            };
            job_slot = self.findByJobId(job_id);
            if (job_slot == null) {
                try IO.eprint("den: disown: {d}: no such job\n", .{job_id});
                return 1;
            }
        } else {
            job_slot = self.findMostRecent();
            if (job_slot == null) {
                try IO.eprint("den: disown: current: no such job\n", .{});
                return 1;
            }
        }

        // Remove from job table (but don't kill the process)
        self.remove(job_slot.?);
        return 0;
    }

    /// Builtin: wait - wait for background jobs to complete.
    pub fn builtinWait(self: *Self, args: []const []const u8) !i32 {
        if (builtin.os.tag == .windows) {
            try IO.eprint("den: wait: not supported on Windows\n", .{});
            return 1;
        }

        if (args.len > 0) {
            // Wait for specific job(s)
            var last_status: i32 = 0;
            for (args) |raw_arg| {
                var arg = raw_arg;
                if (arg.len > 0 and arg[0] == '%') {
                    arg = arg[1..];
                }
                const job_id = std.fmt.parseInt(usize, arg, 10) catch {
                    try IO.eprint("den: wait: {s}: no such job\n", .{raw_arg});
                    last_status = 127;
                    continue;
                };

                const slot = self.findByJobId(job_id);
                if (slot == null) {
                    try IO.eprint("den: wait: {d}: no such job\n", .{job_id});
                    last_status = 127;
                    continue;
                }

                const job = self.jobs[slot.?].?;
                var specific_wait_status: c_int = 0;
                _ = process.waitpidIntr(job.pid, &specific_wait_status, 0);
                last_status = getExitStatus(@as(u32, @bitCast(specific_wait_status)));
                self.remove(slot.?);
            }
            return last_status;
        } else {
            // Wait for all background jobs
            var last_status: i32 = 0;
            for (&self.jobs, 0..) |*maybe_job, i| {
                if (maybe_job.*) |job| {
                    var all_wait_status: c_int = 0;
                    if (comptime builtin.os.tag != .windows) {
                        _ = process.waitpidIntr(job.pid, &all_wait_status, 0);
                    }
                    last_status = getExitStatus(@as(u32, @bitCast(all_wait_status)));
                    self.allocator.free(job.command);
                    maybe_job.* = null;
                    self.job_count -= 1;
                    _ = i;
                }
            }
            return last_status;
        }
    }
};

// ========================================
// Tests
// ========================================

test "JobManager init and deinit" {
    const allocator = std.testing.allocator;
    var jm = JobManager.init(allocator);
    defer jm.deinit();

    try std.testing.expectEqual(@as(usize, 0), jm.job_count);
    try std.testing.expectEqual(@as(usize, 1), jm.next_job_id);
}

test "JobManager findByJobId" {
    const allocator = std.testing.allocator;
    var jm = JobManager.init(allocator);
    defer jm.deinit();

    // Empty manager should return null
    try std.testing.expect(jm.findByJobId(1) == null);
}
