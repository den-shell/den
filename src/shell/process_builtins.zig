//! Process Builtins Implementation
//!
//! This module implements process-related shell builtins:
//! - exec: replace shell with command
//! - kill: send signals to processes

const std = @import("std");
const builtin = @import("builtin");
const IO = @import("../utils/io.zig").IO;
const types = @import("../types/mod.zig");
const executor_mod = @import("../executor/mod.zig");

// Forward declaration for Shell type
const Shell = @import("../shell.zig").Shell;

/// Builtin: exec - replace shell with command
pub fn builtinExec(self: *Shell, cmd: *types.ParsedCommand) !void {
    // Restricted mode: exec is not allowed
    if (self.option_restricted) {
        try IO.eprint("den: exec: restricted\n", .{});
        self.last_exit_code = 1;
        return;
    }

    if (cmd.args.len == 0) {
        try IO.eprint("den: exec: command required\n", .{});
        self.last_exit_code = 1;
        return;
    }

    // In a full implementation, this would use execvpe to replace the shell process
    // For now, execute the command and set running=false to exit the shell
    const new_cmd = types.ParsedCommand{
        .name = cmd.args[0],
        .args = if (cmd.args.len > 1) cmd.args[1..] else &[_][]const u8{},
        .redirections = &[_]types.Redirection{},
    };

    const cmds = [_]types.ParsedCommand{new_cmd};
    const ops = [_]types.Operator{};
    var chain = types.CommandChain{
        .commands = @constCast(&cmds),
        .operators = @constCast(&ops),
    };

    // Execute the command
    var executor = executor_mod.Executor.init(self.allocator, &self.environment);
    const exit_code = try executor.executeChain(&chain);
    self.last_exit_code = exit_code;

    // Mark shell as not running to exit after this command
    self.running = false;
    self.exit_requested = true;
}

/// Builtin: kill - send signal to job or process
pub fn builtinKill(self: *Shell, cmd: *types.ParsedCommand) !void {
    if (comptime builtin.os.tag == .windows) {
        // Windows: kill command not yet fully implemented
        try IO.print("kill: not fully implemented on Windows\n", .{});
        self.last_exit_code = 0;
        return;
    }

    // Check for -l flag (list signals)
    if (cmd.args.len >= 1) {
        const first_arg = cmd.args[0];
        if (std.mem.eql(u8, first_arg, "-l") or std.mem.eql(u8, first_arg, "-L")) {
            // List all signals
            const signal_table = [_]struct { num: u6, name: []const u8 }{
                .{ .num = 1, .name = "HUP" },
                .{ .num = 2, .name = "INT" },
                .{ .num = 3, .name = "QUIT" },
                .{ .num = 4, .name = "ILL" },
                .{ .num = 5, .name = "TRAP" },
                .{ .num = 6, .name = "ABRT" },
                .{ .num = 7, .name = "BUS" },
                .{ .num = 8, .name = "FPE" },
                .{ .num = 9, .name = "KILL" },
                .{ .num = 10, .name = "USR1" },
                .{ .num = 11, .name = "SEGV" },
                .{ .num = 12, .name = "USR2" },
                .{ .num = 13, .name = "PIPE" },
                .{ .num = 14, .name = "ALRM" },
                .{ .num = 15, .name = "TERM" },
                .{ .num = 17, .name = "CHLD" },
                .{ .num = 18, .name = "CONT" },
                .{ .num = 19, .name = "STOP" },
                .{ .num = 20, .name = "TSTP" },
                .{ .num = 21, .name = "TTIN" },
                .{ .num = 22, .name = "TTOU" },
                .{ .num = 23, .name = "URG" },
                .{ .num = 24, .name = "XCPU" },
                .{ .num = 25, .name = "XFSZ" },
                .{ .num = 26, .name = "VTALRM" },
                .{ .num = 27, .name = "PROF" },
                .{ .num = 28, .name = "WINCH" },
                .{ .num = 29, .name = "IO" },
                .{ .num = 30, .name = "PWR" },
                .{ .num = 31, .name = "SYS" },
            };

            // If a signal number is given after -l, print just that signal name
            if (cmd.args.len >= 2) {
                const sig_num = std.fmt.parseInt(u6, cmd.args[1], 10) catch {
                    try IO.eprint("den: kill: {s}: invalid signal specification\n", .{cmd.args[1]});
                    self.last_exit_code = 1;
                    return;
                };
                for (signal_table) |sig| {
                    if (sig.num == sig_num) {
                        try IO.print("{s}\n", .{sig.name});
                        self.last_exit_code = 0;
                        return;
                    }
                }
                try IO.eprint("den: kill: {d}: invalid signal specification\n", .{sig_num});
                self.last_exit_code = 1;
                return;
            }

            // Print all signals
            var col: usize = 0;
            for (signal_table) |sig| {
                try IO.print("{d:>2}) SIG{s: <8}", .{ sig.num, sig.name });
                col += 1;
                if (col >= 4) {
                    try IO.print("\n", .{});
                    col = 0;
                }
            }
            if (col > 0) {
                try IO.print("\n", .{});
            }
            self.last_exit_code = 0;
            return;
        }
    }

    if (cmd.args.len == 0) {
        try IO.eprint("den: kill: usage: kill [-s sigspec | -n signum | -sigspec] pid | jobspec ...\n", .{});
        self.last_exit_code = 1;
        return;
    }

    var signal: std.posix.SIG = .TERM; // Default signal
    var arg_idx: usize = 0;

    // Parse signal specification
    if (cmd.args.len > 1 and cmd.args[0][0] == '-') {
        const sig_arg = cmd.args[0];
        if (sig_arg.len > 1) {
            // Try to parse as name (e.g., -TERM, -KILL)
            const sig_name = sig_arg[1..];
            if (std.mem.eql(u8, sig_name, "TERM")) {
                signal = .TERM;
            } else if (std.mem.eql(u8, sig_name, "KILL")) {
                signal = .KILL;
            } else if (std.mem.eql(u8, sig_name, "INT")) {
                signal = .INT;
            } else if (std.mem.eql(u8, sig_name, "HUP")) {
                signal = .HUP;
            } else if (std.mem.eql(u8, sig_name, "STOP")) {
                signal = .STOP;
            } else if (std.mem.eql(u8, sig_name, "CONT")) {
                signal = .CONT;
            } else if (std.fmt.parseInt(u32, sig_arg[1..], 10)) |sig_num| {
                // Try to parse as number (e.g., -9)
                signal = @enumFromInt(sig_num);
            } else |_| {
                try IO.eprint("den: kill: {s}: invalid signal specification\n", .{sig_name});
                self.last_exit_code = 1;
                return;
            }
            arg_idx = 1;
        }
    }

    // Send signal to each specified process/job
    while (arg_idx < cmd.args.len) : (arg_idx += 1) {
        const target = cmd.args[arg_idx];

        if (target[0] == '%') {
            // Job specification
            const job_id = std.fmt.parseInt(usize, target[1..], 10) catch {
                try IO.eprint("den: kill: {s}: invalid job specification\n", .{target});
                self.last_exit_code = 1;
                continue;
            };

            // Find job by ID and get its PID
            if (self.job_manager.findByJobId(job_id)) |slot| {
                if (self.job_manager.get(slot)) |job| {
                    std.posix.kill(job.pid, signal) catch {
                        try IO.eprint("den: kill: ({d}) - No such process\n", .{job.pid});
                        self.last_exit_code = 1;
                        continue;
                    };
                }
            } else {
                try IO.eprint("den: kill: %{d}: no such job\n", .{job_id});
                self.last_exit_code = 1;
                continue;
            }
        } else {
            // PID specification
            const pid = std.fmt.parseInt(i32, target, 10) catch {
                try IO.eprint("den: kill: {s}: arguments must be process or job IDs\n", .{target});
                self.last_exit_code = 1;
                continue;
            };

            std.posix.kill(pid, signal) catch {
                try IO.eprint("den: kill: ({d}) - No such process\n", .{pid});
                self.last_exit_code = 1;
                continue;
            };
        }
    }

    self.last_exit_code = 0;
}
