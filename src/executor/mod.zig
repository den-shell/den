const std = @import("std");
const types = @import("../types/mod.zig");
const IO = @import("../utils/io.zig").IO;
const Expansion = @import("../utils/expansion.zig").Expansion;
const expansion_mod = @import("../utils/expansion.zig");
const builtin = @import("builtin");
const common = @import("builtins/common.zig");
const c = common.c_exec;
const process = @import("../utils/process.zig");
const TypoCorrection = @import("../utils/typo_correction.zig").TypoCorrection;
const env_utils = @import("../utils/env.zig");
const networking = @import("networking.zig");
const memory_pool = @import("memory_pool.zig");
const redirection = @import("redirection.zig");
const builtins = @import("builtins/mod.zig");
const utilities = builtins.utilities;
const file_ops = builtins.file_ops;
const test_builtins = builtins.test_builtins;
const io_builtins = builtins.io_builtins;
const shell_builtins = builtins.shell_builtins;
const env_builtins = builtins.env_builtins;
const dir_builtins = builtins.dir_builtins;
const alias_builtins = builtins.alias_builtins;
const BuiltinContext = builtins.BuiltinContext;

// Forward declaration for Shell type
const Shell = @import("../shell.zig").Shell;

// Plugin hook types for command_not_found hook
const HookType = @import("../plugins/interface.zig").HookType;
const HookContext = @import("../plugins/interface.zig").HookContext;

// Re-export networking functions for use in this module
const openDevNet = networking.openDevNet;
const parseDevNetPath = networking.parseDevNetPath;
const parseIPv4 = networking.parseIPv4;
const parseIPv6 = networking.parseIPv6;

// C library extern declarations for environment manipulation (POSIX only)
pub const libc_env = if (builtin.os.tag != .windows) struct {
    pub extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    pub extern "c" fn unsetenv(name: [*:0]const u8) c_int;
} else struct {};

// Windows process access rights (for job control)
const PROCESS_TERMINATE: u32 = 0x0001;

// Networking code moved to networking.zig

/// Helper to execute control flow commands in a pipeline child process.
/// Isolated as a standalone function to avoid inferred error set conflicts.
fn executeControlFlowInPipeline(shell: *Shell, command: []const u8) void {
    shell.executeCommand(command) catch {};
}

pub const Executor = struct {
    allocator: std.mem.Allocator,
    environment: *std.StringHashMap([]const u8),
    shell: ?*Shell, // Optional reference to shell for options
    command_pool: memory_pool.CommandMemoryPool, // Memory pool for command execution

    /// Initialize an executor without a shell reference.
    /// Used for standalone command execution.
    pub fn init(allocator: std.mem.Allocator, environment: *std.StringHashMap([]const u8)) Executor {
        return .{
            .allocator = allocator,
            .environment = environment,
            .shell = null,
            .command_pool = memory_pool.CommandMemoryPool.init(allocator),
        };
    }

    /// Initialize an executor with a shell reference.
    /// Provides access to shell state like directory stack, aliases, and options.
    pub fn initWithShell(allocator: std.mem.Allocator, environment: *std.StringHashMap([]const u8), shell: *Shell) Executor {
        return .{
            .allocator = allocator,
            .environment = environment,
            .shell = shell,
            .command_pool = memory_pool.CommandMemoryPool.init(allocator),
        };
    }

    /// Cleanup resources
    pub fn deinit(self: *Executor) void {
        self.command_pool.deinit();
    }

    /// Get the memory pool allocator for temporary command allocations
    pub fn poolAllocator(self: *Executor) std.mem.Allocator {
        return self.command_pool.allocator();
    }

    /// Reset the memory pool after command execution
    pub fn resetPool(self: *Executor) void {
        self.command_pool.reset();
    }

    /// Execute a command chain, handling operators like && and ||.
    /// Returns the exit code of the last executed command.
    pub fn executeChain(self: *Executor, chain: *types.CommandChain) !i32 {
        // Reset the memory pool at the start of each command chain
        defer self.resetPool();

        if (chain.commands.len == 0) return 0;

        // Determine if this chain contains && or || operators (AND-OR list).
        // Per POSIX, errexit should not apply to the result of an AND-OR list.
        if (self.shell) |shell| {
            var has_and_or = false;
            for (chain.operators) |op| {
                if (op == .and_op or op == .or_op) {
                    has_and_or = true;
                    break;
                }
            }
            shell.last_chain_had_and_or = has_and_or;
        }

        // Single command - execute directly
        if (chain.commands.len == 1) {
            const exit_code = try self.executeCommand(&chain.commands[0]);

            // Update shell's last_exit_code and execute ERR trap if command failed
            if (self.shell) |shell| {
                shell.last_exit_code = exit_code;
                // A simple command sets PIPESTATUS to a one-element array == $?.
                const ps = [_]i32{exit_code};
                shell.setPipeStatus(&ps);
                if (exit_code != 0) {
                    shell.executeErrTrap();
                }
            }

            return exit_code;
        }

        // Multiple commands - handle operators
        var last_exit_code: i32 = 0;
        var i: usize = 0;

        while (i < chain.commands.len) {
            // Check if we should execute this command based on previous operator
            if (i > 0) {
                const prev_op = chain.operators[i - 1];
                switch (prev_op) {
                    .and_op => {
                        // && - only execute if previous succeeded
                        if (last_exit_code != 0) {
                            // Skip this command but continue checking subsequent operators
                            i += 1;
                            continue;
                        }
                    },
                    .or_op => {
                        // || - only execute if previous failed
                        if (last_exit_code == 0) {
                            // Skip this command but continue checking subsequent operators
                            i += 1;
                            continue;
                        }
                    },
                    .pipe => {
                        // Pipe handling - execute pipeline
                        const pipeline_start = i - 1;
                        var pipeline_end = i;

                        // Find the end of the pipeline
                        while (pipeline_end < chain.operators.len and
                            chain.operators[pipeline_end] == .pipe)
                        {
                            pipeline_end += 1;
                        }

                        // Execute the pipeline
                        last_exit_code = try self.executePipeline(chain.commands[pipeline_start .. pipeline_end + 1]);

                        // Skip to the end of the pipeline
                        i = pipeline_end + 1;
                        continue;
                    },
                    .semicolon, .background => {
                        // ; and & - always execute next command
                        // Background handling is implemented below in the execute logic
                    },
                }
            }

            // Check if this command starts a pipeline
            if (i < chain.operators.len and chain.operators[i] == .pipe) {
                const pipeline_start = i;
                var pipeline_end = i;

                // Find the end of the pipeline
                while (pipeline_end < chain.operators.len and
                    chain.operators[pipeline_end] == .pipe)
                {
                    pipeline_end += 1;
                }

                // Execute the pipeline
                last_exit_code = try self.executePipeline(chain.commands[pipeline_start .. pipeline_end + 1]);

                // Skip to the end of the pipeline
                i = pipeline_end + 1;
                continue;
            }

            // Check if this command should run in background
            const run_in_background = i < chain.operators.len and chain.operators[i] == .background;

            if (run_in_background) {
                // Execute command in background (don't wait for it)
                try self.executeCommandBackground(&chain.commands[i]);
                last_exit_code = 0; // Background commands always return 0
            } else {
                // Execute single command normally
                last_exit_code = try self.executeCommand(&chain.commands[i]);

                // Update shell's last_exit_code and execute ERR trap if command failed
                if (self.shell) |shell| {
                    shell.last_exit_code = last_exit_code;
                    // A simple command sets PIPESTATUS to a one-element array == $?.
                    const ps = [_]i32{last_exit_code};
                    shell.setPipeStatus(&ps);
                    if (last_exit_code != 0) {
                        shell.executeErrTrap();
                    }

                    // Propagate break/continue from builtins up to enclosing loop
                    if (shell.break_levels > 0 or shell.continue_levels > 0) {
                        return last_exit_code;
                    }
                }

                // Check for errexit option (set -e)
                // Per POSIX, errexit should NOT trigger for commands that are
                // part of an && or || list — those operators handle errors themselves.
                if (self.shell) |shell| {
                    if (shell.option_errexit and last_exit_code != 0) {
                        const in_and_or_chain = (i > 0 and (chain.operators[i - 1] == .and_op or chain.operators[i - 1] == .or_op)) or
                            (i < chain.operators.len and (chain.operators[i] == .and_op or chain.operators[i] == .or_op));
                        if (!in_and_or_chain) {
                            // Exit on error if errexit is enabled
                            try IO.eprint("den: command failed with exit code {d} (errexit enabled)\n", .{last_exit_code});
                            if (shell.current_line > 0) {
                                try IO.eprint("den: line {d}\n", .{shell.current_line});
                            }
                            return last_exit_code;
                        }
                    }
                }
            }

            i += 1;
        }

        return last_exit_code;
    }

    /// Execute a pipeline of commands (e.g., "cmd1 | cmd2 | cmd3").
    /// Connects stdout of each command to stdin of the next.
    fn executePipeline(self: *Executor, commands: []types.ParsedCommand) !i32 {
        if (commands.len == 0) return 0;
        // Expand every stage up-front (in the parent, before any fork) so each
        // segment sees variables set by earlier segments of the chain.
        for (commands) |*cmd| try self.ensureExpanded(cmd);
        if (commands.len == 1) return try self.executeCommand(&commands[0]);

        if (builtin.os.tag == .windows) {
            return try self.executePipelineWindows(commands);
        }
        return try self.executePipelinePosix(commands);
    }

    /// Windows-specific pipeline implementation using std.process.Child.
    fn executePipelineWindows(self: *Executor, commands: []types.ParsedCommand) !i32 {
        // Windows implementation using std.process.Child with pipes
        const num_pipes = commands.len - 1;
        if (num_pipes > 16) return error.TooManyPipes;

        // Spawn all commands as Child processes with pipe behavior
        var children_buffer: [17]std.process.Child = undefined;
        var argv_lists: [17]std.ArrayList([]const u8) = undefined;

        // Initialize argv lists
        for (0..commands.len) |i| {
            argv_lists[i] = .{};
        }
        defer {
            for (0..commands.len) |i| {
                argv_lists[i].deinit(self.allocator);
            }
        }

        // Build argv and spawn children
        for (commands, 0..) |*cmd, i| {
            // Build argv list
            try argv_lists[i].append(self.allocator, cmd.name);
            for (cmd.args) |arg| {
                try argv_lists[i].append(self.allocator, arg);
            }

            // Determine behaviors
            var stdin_behavior: std.process.SpawnOptions.StdIo = if (i > 0) .pipe else .inherit;
            var stdout_behavior: std.process.SpawnOptions.StdIo = if (i < num_pipes) .pipe else .inherit;
            var stderr_behavior: std.process.SpawnOptions.StdIo = .inherit;

            // Handle explicit redirections to determine behaviors
            for (cmd.redirections) |redir| {
                switch (redir.kind) {
                    .output_truncate, .output_append, .output_clobber => {
                        if (redir.fd == 1) {
                            stdout_behavior = .ignore;
                        } else if (redir.fd == 2) {
                            stderr_behavior = .ignore;
                        }
                    },
                    .input => {
                        stdin_behavior = .ignore;
                    },
                    .input_output => {
                        if (redir.fd == 0) {
                            stdin_behavior = .ignore;
                        } else if (redir.fd == 1) {
                            stdout_behavior = .ignore;
                        }
                    },
                    .fd_duplicate => {
                        // Handle 2>&1 (stderr to stdout)
                        if (redir.fd == 2 and std.mem.eql(u8, redir.target, "1")) {
                            stderr_behavior = .inherit; // Will inherit stdout's destination
                        }
                    },
                    else => {},
                }
            }

            children_buffer[i] = std.process.spawn(std.Options.debug_io, .{
                .argv = argv_lists[i].items,
                .stdin = stdin_behavior,
                .stdout = stdout_behavior,
                .stderr = stderr_behavior,
            }) catch |err| return err;

            // Handle explicit file redirections after spawn
            for (cmd.redirections) |redir| {
                switch (redir.kind) {
                    .output_truncate, .output_append, .output_clobber => {
                        const file = try std.Io.Dir.cwd().createFile(std.Options.debug_io, redir.target, .{
                            .truncate = (redir.kind == .output_truncate or redir.kind == .output_clobber),
                        });
                        if (redir.fd == 1) {
                            children_buffer[i].stdout = file;
                        } else if (redir.fd == 2) {
                            children_buffer[i].stderr = file;
                        }
                    },
                    .input => {
                        const file = try std.Io.Dir.cwd().openFile(std.Options.debug_io, redir.target, .{});
                        children_buffer[i].stdin = file;
                    },
                    .input_output => {
                        const file = try std.Io.Dir.cwd().openFile(std.Options.debug_io, redir.target, .{ .mode = .read_write });
                        // For <> the fd defaults to 0 (stdin) but can be specified
                        if (redir.fd == 0) {
                            children_buffer[i].stdin = file;
                        } else if (redir.fd == 1) {
                            children_buffer[i].stdout = file;
                        }
                    },
                    else => {},
                }
            }

            // Connect pipes between processes
            if (i > 0 and children_buffer[i - 1].stdout != null) {
                children_buffer[i].stdin = children_buffer[i - 1].stdout.?;
            }
        }

        // Wait for all children
        var last_status: i32 = 0;
        var pipefail_status: i32 = 0;
        for (0..commands.len) |i| {
            const term = try children_buffer[i].wait(std.Options.debug_io);
            const status: i32 = switch (term) {
                .exited => |code| code,
                else => 1,
            };
            last_status = status;
            // For pipefail: track rightmost non-zero exit status
            if (status != 0) {
                pipefail_status = status;
            }
        }

        // Handle pipefail option
        if (self.shell) |shell| {
            if (shell.option_pipefail and pipefail_status != 0) {
                return pipefail_status;
            }
        }

        return last_status;
    }

    fn executePipelinePosix(self: *Executor, commands: []types.ParsedCommand) !i32 {
        // Create pipes for communication
        var pipes_buffer: [16][2]std.posix.fd_t = undefined;
        const num_pipes = commands.len - 1;

        if (num_pipes > pipes_buffer.len) return error.TooManyPipes;

        // Create all pipes
        for (0..num_pipes) |i| {
            var fds: [2]std.posix.fd_t = undefined;
            if (std.c.pipe(&fds) != 0) return error.Unexpected;
            pipes_buffer[i] = fds;
        }

        // Spawn all commands in the pipeline
        var pids_buffer: [17]std.posix.pid_t = undefined;

        for (commands, 0..) |*cmd, i| {
            const fork_ret = std.c.fork();
            if (fork_ret < 0) return error.Unexpected;
            const pid: std.posix.pid_t = @intCast(fork_ret);

            if (pid == 0) {
                // Child process — dup2 failures must terminate immediately;
                // returning an error would continue with unredirected fds.

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

                // Execute the command
                // Check if this is a control flow construct (while, for, if, until, case)
                if (self.isControlFlowKeyword(cmd.name)) {
                    // Reconstruct the full command string and execute via shell
                    if (self.shell) |shell| {
                        var buf: [8192]u8 = undefined;
                        var pos: usize = 0;
                        // Add command name
                        if (pos + cmd.name.len < buf.len) {
                            @memcpy(buf[pos..][0..cmd.name.len], cmd.name);
                            pos += cmd.name.len;
                        }
                        // Add args
                        for (cmd.args) |arg| {
                            if (pos + 1 + arg.len < buf.len) {
                                buf[pos] = ' ';
                                pos += 1;
                                @memcpy(buf[pos..][0..arg.len], arg);
                                pos += arg.len;
                            }
                        }
                        executeControlFlowInPipeline(shell, buf[0..pos]);
                        std.c._exit(@intCast(if (shell.last_exit_code >= 0) @as(u32, @intCast(shell.last_exit_code)) else 1));
                    } else {
                        std.c._exit(1);
                    }
                } else if (self.shell != null and self.shell.?.function_manager.hasFunction(cmd.name)) {
                    // User-defined function in pipeline
                    const shell = self.shell.?;
                    const exit_code = shell.function_manager.executeFunction(shell, cmd.name, cmd.args) catch 1;
                    std.c._exit(@intCast(if (exit_code >= 0) @as(u32, @intCast(exit_code)) else 1));
                } else if (self.isBuiltin(cmd.name)) {
                    // Apply redirections for builtins in pipelines
                    if (cmd.redirections.len > 0) {
                        self.applyRedirections(cmd.redirections) catch {
                            std.c._exit(1);
                        };
                    }
                    const exit_code = self.executeBuiltin(cmd) catch 1;
                    std.c._exit(@intCast(exit_code));
                } else {
                    _ = try self.executeExternalInChild(cmd);
                    // executeExternalInChild normally execves and never returns;
                    // if it does return, exit explicitly.
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

        // Wait for all children and collect PIPESTATUS
        var last_status: i32 = 0;
        var pipefail_status: i32 = 0;
        var pipestatus_buf: [17]i32 = undefined;
        for (pids_buffer[0..commands.len], 0..) |pid, pi| {
            var wait_status: c_int = 0;
            if (comptime builtin.os.tag != .windows) {
                _ = process.waitpidIntr(pid, &wait_status, 0);
            }
            const raw: u32 = @bitCast(wait_status);
            const status: i32 = if (std.posix.W.IFSIGNALED(raw))
                128 + @as(i32, @intCast(@intFromEnum(std.posix.W.TERMSIG(raw))))
            else
                @intCast(std.posix.W.EXITSTATUS(raw));
            last_status = status;
            pipestatus_buf[pi] = status;
            // For pipefail: track rightmost non-zero exit status
            if (status != 0) {
                pipefail_status = status;
            }
        }

        // Set PIPESTATUS array in the shell (one element per pipeline stage).
        if (self.shell) |shell| {
            shell.setPipeStatus(pipestatus_buf[0..commands.len]);

            if (shell.option_pipefail and pipefail_status != 0) {
                return pipefail_status;
            }
        }

        return last_status;
    }

    fn executeExternalInChild(self: *Executor, command: *types.ParsedCommand) !void {
        // Apply redirections before exec
        try self.applyRedirections(command.redirections);

        // Build argv (command name + args)
        const argv_len = 1 + command.args.len;
        var argv = try self.allocator.alloc(?[*:0]const u8, argv_len + 1);
        defer self.allocator.free(argv);

        // Allocate command name as null-terminated string
        const cmd_z = try self.allocator.dupeSentinel(u8, command.name, 0);
        defer self.allocator.free(cmd_z);
        argv[0] = cmd_z.ptr;

        // Allocate args as null-terminated strings
        var arg_zs = try self.allocator.alloc([:0]u8, command.args.len);
        var arg_zs_filled: usize = 0;
        defer {
            for (arg_zs[0..arg_zs_filled]) |arg_z| {
                self.allocator.free(arg_z);
            }
            self.allocator.free(arg_zs);
        }

        for (command.args, 0..) |arg, i| {
            arg_zs[i] = try self.allocator.dupeSentinel(u8, arg, 0);
            arg_zs_filled = i + 1;
            argv[i + 1] = arg_zs[i].ptr;
        }
        argv[argv_len] = null;

        // Exec (no fork - we're already in child)
        // Use C's environ directly which is updated by setenv/unsetenv
        _ = c.execvp(cmd_z.ptr, @ptrCast(argv.ptr));
        IO.eprint("den: {s}: command not found\n", .{command.name}) catch {};
        std.c._exit(127);
    }

    fn applyRedirections(self: *Executor, redirections: []types.Redirection) !void {
        // Restricted mode: block output redirections
        if (self.shell) |shell| {
            if (shell.option_restricted) {
                for (redirections) |redir| {
                    switch (redir.kind) {
                        .output_truncate, .output_append, .output_clobber => {
                            IO.eprint("den: output redirection restricted\n", .{}) catch {};
                            return error.RestrictedMode;
                        },
                        .fd_duplicate => {
                            // Block >&N redirections for stdout/stderr
                            if (redir.fd == 1 or redir.fd == 2) {
                                IO.eprint("den: output redirection restricted\n", .{}) catch {};
                                return error.RestrictedMode;
                            }
                        },
                        else => {},
                    }
                }
            }
        }

        // Build expansion context from shell if available (for heredocs/herestrings)
        const expansion_context: ?redirection.ExpansionContext = if (self.shell) |shell|
            .{
                .option_nounset = shell.option_nounset,
                .option_noclobber = shell.option_noclobber,
                .var_attributes = &shell.var_attributes,
                .arrays = &shell.arrays,
                .assoc_arrays = &shell.assoc_arrays,
            }
        else
            null;

        try redirection.applyRedirections(
            self.allocator,
            redirections,
            self.environment,
            expansion_context,
        );
    }

    /// Execute a single command, either as a builtin or external program.
    /// Handles shell options like xtrace (-x) and noexec (-n).
    /// Lazily expand a command's variables/braces/globs immediately before it
    /// executes. Multi-segment foreground chains defer expansion to here so a
    /// variable set in an earlier segment is visible to a later one
    /// (`export FOO=bar && echo $FOO`). Idempotent (guarded by command.expanded)
    /// and a no-op without a shell reference, e.g. backgrounded chains that were
    /// already expanded up-front.
    fn ensureExpanded(self: *Executor, command: *types.ParsedCommand) !void {
        if (command.expanded) return;
        if (self.shell) |shell| {
            try shell.expandCommand(command);
        }
    }

    pub fn executeCommand(self: *Executor, command: *types.ParsedCommand) !i32 {
        // Expand this segment now (deferred from the shell for chains) so it
        // sees the environment mutated by earlier segments.
        try self.ensureExpanded(command);

        // Handle set -x (xtrace): print command before execution
        if (self.shell) |shell| {
            if (shell.option_xtrace) {
                // Print command with + prefix (like bash)
                try IO.eprint("+ {s}", .{command.name});
                for (command.args) |arg| {
                    try IO.eprint(" {s}", .{arg});
                }
                try IO.eprint("\n", .{});
            }

            // Handle set -n (noexec): don't execute, just return success
            if (shell.option_noexec) {
                return 0;
            }
        }

        // Empty command name (e.g. from $(exit 42) expanding to "") is a no-op.
        // Preserve the current exit code like bash does.
        // Exception: bare redirections like "> file" should still be applied.
        if (command.name.len == 0) {
            if (command.redirections.len > 0) {
                // Restricted mode: block output redirections even for bare redirections
                if (self.shell) |shell| {
                    if (shell.option_restricted) {
                        for (command.redirections) |redir| {
                            switch (redir.kind) {
                                .output_truncate, .output_append, .output_clobber => {
                                    IO.eprint("den: output redirection restricted\n", .{}) catch {};
                                    return 1;
                                },
                                else => {},
                            }
                        }
                    }
                }

                // Bare redirections: apply them to create/truncate files (POSIX behavior).
                if (comptime builtin.os.tag != .windows) {
                    for (command.redirections) |redir| {
                        switch (redir.kind) {
                            .output_truncate, .output_clobber => {
                                const path_z = self.allocator.dupeSentinel(u8, redir.target, 0) catch return 1;
                                defer self.allocator.free(path_z);
                                const fd = std.c.open(path_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c_uint, 0o644));
                                if (fd < 0) return 1;
                                // fd is c_int, std.c.close takes c_int — no cast needed
                                _ = std.c.close(fd);
                            },
                            .output_append => {
                                const path_z = self.allocator.dupeSentinel(u8, redir.target, 0) catch return 1;
                                defer self.allocator.free(path_z);
                                const fd = std.c.open(path_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, @as(c_uint, 0o644));
                                if (fd < 0) return 1;
                                _ = std.c.close(fd);
                            },
                            .input => {
                                const path_z = self.allocator.dupeSentinel(u8, redir.target, 0) catch return 1;
                                defer self.allocator.free(path_z);
                                const fd = std.c.open(path_z, .{}, @as(c_uint, 0));
                                if (fd < 0) return 1;
                                _ = std.c.close(fd);
                            },
                            else => {},
                        }
                    }
                }
                return 0;
            }
            if (self.shell) |shell| {
                return shell.last_exit_code;
            }
            return 0;
        }

        // Handle bare variable assignment: VAR=value (when command name contains =)
        if (std.mem.indexOfScalar(u8, command.name, '=')) |eq_pos| {
            if (eq_pos > 0) {
                const var_name = command.name[0..eq_pos];
                // Verify it's a valid variable name
                var is_valid = std.ascii.isAlphabetic(var_name[0]) or var_name[0] == '_';
                if (is_valid) {
                    for (var_name[1..]) |ch| {
                        if (!std.ascii.isAlphanumeric(ch) and ch != '_') {
                            is_valid = false;
                            break;
                        }
                    }
                }
                if (is_valid) {
                    // Restricted mode: block modifications to PATH, SHELL, ENV, BASH_ENV
                    if (self.shell) |shell| {
                        if (shell.option_restricted) {
                            if (std.mem.eql(u8, var_name, "PATH") or
                                std.mem.eql(u8, var_name, "SHELL") or
                                std.mem.eql(u8, var_name, "ENV") or
                                std.mem.eql(u8, var_name, "BASH_ENV"))
                            {
                                IO.eprint("den: {s}: restricted: cannot modify in restricted mode\n", .{var_name}) catch {};
                                return 1;
                            }
                        }
                    }

                    const value = command.name[eq_pos + 1 ..];
                    if (self.shell) |shell| {
                        // If inside a function and variable exists as local, update local
                        if (shell.function_manager.currentFrame()) |frame| {
                            if (frame.local_vars.getKey(var_name)) |_| {
                                const val_copy = self.allocator.dupe(u8, value) catch return 1;
                                const gop = frame.local_vars.getOrPut(var_name) catch {
                                    self.allocator.free(val_copy);
                                    return 1;
                                };
                                if (gop.found_existing) {
                                    self.allocator.free(gop.value_ptr.*);
                                }
                                gop.value_ptr.* = val_copy;
                                // Preserve exit code from command substitution (bash behavior)
                                return command.cmd_sub_exit_code orelse 0;
                            }
                        }

                        // Set the variable in the shell environment
                        const key_copy = self.allocator.dupe(u8, var_name) catch return 1;
                        const val_copy = self.allocator.dupe(u8, value) catch {
                            self.allocator.free(key_copy);
                            return 1;
                        };
                        if (shell.environment.fetchRemove(var_name)) |old| {
                            self.allocator.free(old.key);
                            self.allocator.free(old.value);
                        }
                        shell.environment.put(key_copy, val_copy) catch {
                            self.allocator.free(key_copy);
                            self.allocator.free(val_copy);
                            return 1;
                        };
                        // Also set in the C environment for child processes
                        var name_buf: [512]u8 = undefined;
                        var val_buf: [4096]u8 = undefined;
                        if (builtin.os.tag != .windows) {
                            if (var_name.len < name_buf.len and value.len < val_buf.len) {
                                @memcpy(name_buf[0..var_name.len], var_name);
                                name_buf[var_name.len] = 0;
                                @memcpy(val_buf[0..value.len], value);
                                val_buf[value.len] = 0;
                                _ = libc_env.setenv(name_buf[0..var_name.len :0], val_buf[0..value.len :0], 1);
                            }
                        }
                    }
                    // A simple command made up entirely of assignment words sets
                    // ALL of them (bash: `A=1 B=2` sets both). The command name
                    // handled the first; apply any further leading assignment args
                    // here, stopping at the first arg that is not an assignment.
                    if (self.shell) |shell| {
                        for (command.args) |arg| {
                            const aeq = std.mem.indexOfScalar(u8, arg, '=') orelse break;
                            if (aeq == 0) break;
                            const aname = arg[0..aeq];
                            var avalid = std.ascii.isAlphabetic(aname[0]) or aname[0] == '_';
                            if (avalid) {
                                for (aname[1..]) |ch| {
                                    if (!std.ascii.isAlphanumeric(ch) and ch != '_') {
                                        avalid = false;
                                        break;
                                    }
                                }
                            }
                            if (!avalid) break;
                            const aval = arg[aeq + 1 ..];
                            shell.setVariableValue(aname, aval) catch break;
                            // Export to the C environment so child processes see it too.
                            if (builtin.os.tag != .windows and aname.len < 512 and aval.len < 4096) {
                                var nb: [512]u8 = undefined;
                                var vb: [4096]u8 = undefined;
                                @memcpy(nb[0..aname.len], aname);
                                nb[aname.len] = 0;
                                @memcpy(vb[0..aval.len], aval);
                                vb[aval.len] = 0;
                                _ = libc_env.setenv(nb[0..aname.len :0], vb[0..aval.len :0], 1);
                            }
                        }
                    }
                    // Preserve exit code from command substitution (bash behavior)
                    // e.g. x=$(exit 42); echo $? → 42
                    return command.cmd_sub_exit_code orelse 0;
                }
            }
        }

        // Check if it's a user-defined function (POSIX: functions before builtins)
        if (self.shell) |shell| {
            if (shell.function_manager.hasFunction(command.name)) {
                // If function has redirections, save/restore fds around execution
                if (command.redirections.len > 0) {
                    var saved = redirection.SavedFds.save();
                    defer saved.restore();
                    self.applyRedirections(command.redirections) catch {
                        return 1;
                    };
                    const exit_code = shell.function_manager.executeFunction(shell, command.name, command.args) catch |err| {
                        try IO.eprint("den: function error: {}\n", .{err});
                        return 1;
                    };
                    return exit_code;
                }
                const exit_code = shell.function_manager.executeFunction(shell, command.name, command.args) catch |err| {
                    try IO.eprint("den: function error: {}\n", .{err});
                    return 1;
                };
                return exit_code;
            }
        }

        // Check if it's a builtin
        if (self.isBuiltin(command.name)) {
            // If builtin has redirections, save/restore file descriptors around execution.
            // We must NOT fork because builtins like cd, pushd, popd, export, etc.
            // need to affect the parent process state (working directory, environment, etc.).
            if (command.redirections.len > 0) {
                if (builtin.os.tag == .windows) {
                    // Windows: save/restore stdout/stderr instead of fork
                    return try self.executeBuiltinWithRedirectionsWindows(command);
                }

                var saved = redirection.SavedFds.save();
                self.applyRedirections(command.redirections) catch {
                    saved.restore();
                    return 1;
                };
                const result = self.executeBuiltin(command) catch 1;
                // exec with no args + redirections returns -2 to signal
                // that redirections should be kept permanent (not restored).
                if (result == -2) {
                    saved.discard();
                    return 0;
                }
                saved.restore();
                return result;
            }
            return try self.executeBuiltin(command);
        }

        // Auto-cd (like zsh): a bare directory name cds into it. Also handles
        // the multi-dot shorthand `...` -> `../..`, `....` -> `../../..` by
        // expanding it first so the directory check (and cd) see a real path.
        {
            const many = try expansion_mod.expandManyDots(self.allocator, command.name);
            defer if (many) |m| self.allocator.free(m);
            const autocd_target = many orelse command.name;

            if (try self.isDirectory(autocd_target)) {
                var args = [_][]const u8{autocd_target};
                var redirections = [_]types.Redirection{};
                var cd_command = types.ParsedCommand{
                    .name = "cd",
                    .args = args[0..],
                    .redirections = redirections[0..],
                    .type = .builtin,
                };
                return try self.executeBuiltin(&cd_command);
            }
        }

        // Check for suffix alias (zsh-style: typing "hello.ts" runs "bun hello.ts")
        if (self.shell) |shell| {
            if (self.trySuffixAlias(shell, command)) |new_command| {
                var suffix_cmd = new_command;
                return try self.executeExternal(&suffix_cmd);
            }
        }

        // Execute external command
        return try self.executeExternal(command);
    }

    fn isDirectory(self: *Executor, path: []const u8) !bool {
        _ = self;

        // Handle special directory shortcuts
        if (std.mem.eql(u8, path, "..") or
            std.mem.eql(u8, path, "../") or
            std.mem.eql(u8, path, ".") or
            std.mem.eql(u8, path, "./") or
            std.mem.eql(u8, path, "-"))
        {
            return true;
        }

        // Handle tilde expansion
        if (path.len > 0 and path[0] == '~') {
            return true;
        }

        // Check if it's a valid directory path
        // Try to open as directory
        var dir = std.Io.Dir.cwd().openDir(std.Options.debug_io, path, .{}) catch {
            // Not a directory or doesn't exist
            return false;
        };
        dir.close(std.Options.debug_io);
        return true;
    }

    /// Check for suffix alias and return a transformed command if applicable.
    /// Suffix aliases allow typing "hello.ts" to run "bun hello.ts" (zsh-style).
    fn trySuffixAlias(self: *Executor, shell: *Shell, command: *types.ParsedCommand) ?types.ParsedCommand {
        const cmd_name = command.name;

        // Get file extension (everything after the last dot)
        const dot_pos = std.mem.lastIndexOfScalar(u8, cmd_name, '.') orelse return null;
        if (dot_pos == cmd_name.len - 1) return null; // Ends with dot, no extension

        const extension = cmd_name[dot_pos + 1 ..];

        // Look up the extension in suffix aliases
        const alias_cmd = shell.suffix_aliases.get(extension) orelse return null;

        // Check if the file exists (either as absolute path, relative path, or in current directory)
        const file_exists = blk: {
            // Check if it's an absolute path or relative path that exists
            std.Io.Dir.cwd().access(std.Options.debug_io, cmd_name, .{}) catch {
                break :blk false;
            };
            break :blk true;
        };

        // Only apply suffix alias if the file exists
        if (!file_exists) return null;

        // Build new args: [original_filename] + original args
        // We need to create a new args array with the filename as first arg
        var new_args = self.allocator.alloc([]const u8, command.args.len + 1) catch return null;

        // First arg is the original command name (the filename)
        new_args[0] = self.allocator.dupe(u8, cmd_name) catch {
            self.allocator.free(new_args);
            return null;
        };

        // Copy remaining original args
        for (command.args, 0..) |arg, i| {
            new_args[i + 1] = self.allocator.dupe(u8, arg) catch {
                // Clean up on error
                for (new_args[0 .. i + 1]) |a| self.allocator.free(a);
                self.allocator.free(new_args);
                return null;
            };
        }

        // Create new command with suffix alias as the command name
        const new_cmd_name = self.allocator.dupe(u8, alias_cmd) catch {
            for (new_args) |a| self.allocator.free(a);
            self.allocator.free(new_args);
            return null;
        };

        return types.ParsedCommand{
            .name = new_cmd_name,
            .args = new_args,
            .redirections = command.redirections,
            .type = .external,
        };
    }

    /// Check if a command name is a shell builtin.
    fn isBuiltin(self: *Executor, name: []const u8) bool {
        const builtin_names = [_][]const u8{
            "cd",        "pwd",      "echo",      "exit",       "env",      "export",    "set",       "unset",
            "true",      "false",    "test",      "[",          "[[",       "alias",     "unalias",   "which",
            "type",      "help",     "read",      "printf",     "source",   ".",         "history",   "pushd",
            "popd",      "dirs",     "eval",      "exec",       "command",  "builtin",   "jobs",      "fg",
            "bg",        "wait",     "disown",    "kill",       "trap",     "times",     "umask",     "getopts",
            "clear",     "time",     "timeout",   "hash",       "yes",      "reload",    "watch",     "tree",
            "grep",      "find",     "calc",      "json",       "ls",       "seq",       "date",      "parallel",
            "http",      "base64",   "uuid",      "localip",    "shrug",    "web",       "ip",        "return",
            "local",     "copyssh",  "reloaddns", "emptytrash", "wip",      "bookmark",  "code",      "pstorm",
            "show",      "hide",     "ft",        "sys-stats",  "netstats", "net-check", "log-tail",  "proc-monitor",
            "log-parse", "dotfiles", "library",   "hook",       "ifind",    "coproc",    "break",     "continue",
            ":",         "declare",  "typeset",   "let",        "shift",
            // Nushell-inspired structured data commands
               "from",      "to",        "table",
            "grid",      "where",    "select",    "reject",     "get",      "first",     "last",      "skip",
            "take",      "length",   "flatten",   "uniq",       "sort-by",  "reverse",   "transpose", "group-by",
            "enumerate", "wrap",     "columns",   "values",     "headers",  "compact",   "rename",    "append",
            "prepend",   "str",      "path",      "math",       "into",     "encode",    "decode",    "detect",
            "bench",     "seq-char", "generate",  "par-each",   "explore",  "use",
        };
        for (builtin_names) |builtin_name| {
            if (std.mem.eql(u8, name, builtin_name)) return true;
        }
        // Check for loadable builtins
        if (self.shell) |shell| {
            if (shell.loadable_builtins.isEnabled(name)) return true;
        }
        return false;
    }

    /// Get a BuiltinContext for calling extracted builtins
    fn getBuiltinContext(self: *Executor) BuiltinContext {
        return BuiltinContext.initWithExecutor(
            self.allocator,
            self.environment,
            self.shell,
            isBuiltinStatic,
            executeCommandCallback,
            executeBuiltinCallback,
            executeExternalCallback,
            @ptrCast(self),
        );
    }

    /// Public static check for whether a name is a known builtin
    pub fn isBuiltinName(name: []const u8) bool {
        return isBuiltinStatic(name);
    }

    /// Static wrapper for isBuiltin callback
    fn isBuiltinStatic(name: []const u8) bool {
        // Check against all known builtin names
        const builtin_names = [_][]const u8{
            "echo",    "pwd",      "cd",        "env",       "export",     "set",      "unset",        "true",      "false",
            "test",    "[",        "[[",        "which",     "type",       "help",     "alias",        "unalias",   "read",
            "printf",  "source",   ".",         "history",   "pushd",      "popd",     "dirs",         "eval",      "exec",
            "command", "builtin",  "jobs",      "fg",        "bg",         "wait",     "disown",       "kill",      "trap",
            "times",   "umask",    "getopts",   "clear",     "time",       "timeout",  "hash",         "yes",       "reload",
            "watch",   "tree",     "grep",      "find",      "ft",         "calc",     "json",         "ls",        "seq",
            "date",    "parallel", "http",      "base64",    "uuid",       "localip",  "ip",           "shrug",     "web",
            "return",  "local",    "copyssh",   "reloaddns", "emptytrash", "wip",      "bookmark",     "code",      "pstorm",
            "show",    "hide",     "sys-stats", "netstats",  "net-check",  "log-tail", "proc-monitor", "log-parse", "dotfiles",
            "library", "hook",     "ifind",     "coproc",    "exit",       ":",        "declare",      "typeset",   "let",
            "shift",   "break",    "continue",
            // Nushell-inspired structured data commands
             "from",      "to",         "table",    "grid",         "where",     "select",
            "reject",  "get",      "first",     "last",      "skip",       "take",     "length",       "flatten",   "uniq",
            "sort-by", "reverse",  "transpose", "group-by",  "enumerate",  "wrap",     "columns",      "values",    "headers",
            "compact", "rename",   "append",    "prepend",   "str",        "path",     "math",         "into",      "encode",
            "decode",  "detect",   "bench",     "seq-char",  "generate",   "par-each", "explore",      "use",
        };
        for (builtin_names) |b| {
            if (std.mem.eql(u8, name, b)) return true;
        }
        return false;
    }

    /// Check if a command name is a control flow keyword (while, for, if, until, case, select)
    fn isControlFlowKeyword(_: *Executor, name: []const u8) bool {
        const cf_keywords = [_][]const u8{ "while", "for", "until", "if", "case", "select" };
        for (cf_keywords) |kw| {
            if (std.mem.eql(u8, name, kw)) return true;
        }
        return false;
    }

    /// Callback wrapper for command execution
    fn executeCommandCallback(ctx_ptr: *anyopaque, name: []const u8, args: [][]const u8) anyerror!i32 {
        const self: *Executor = @ptrCast(@alignCast(ctx_ptr));
        var cmd = types.ParsedCommand{
            .name = name,
            .args = args,
            .redirections = &[_]types.Redirection{},
        };
        return self.executeCommand(&cmd);
    }

    /// Callback wrapper for builtin execution
    fn executeBuiltinCallback(ctx_ptr: *anyopaque, cmd: *types.ParsedCommand) anyerror!i32 {
        const self: *Executor = @ptrCast(@alignCast(ctx_ptr));
        return self.executeBuiltin(cmd);
    }

    /// Callback wrapper for external command execution
    fn executeExternalCallback(ctx_ptr: *anyopaque, cmd: *types.ParsedCommand) anyerror!i32 {
        const self: *Executor = @ptrCast(@alignCast(ctx_ptr));
        return self.executeExternal(cmd);
    }

    /// Dispatch and execute a builtin command.
    fn executeBuiltin(self: *Executor, command: *types.ParsedCommand) !i32 {
        var ctx = self.getBuiltinContext();

        if (std.mem.eql(u8, command.name, "echo")) {
            return try io_builtins.echo(command);
        } else if (std.mem.eql(u8, command.name, "pwd")) {
            return try shell_builtins.pwd(&ctx, command);
        } else if (std.mem.eql(u8, command.name, "cd")) {
            return try shell_builtins.cd(&ctx, command);
        } else if (std.mem.eql(u8, command.name, "env")) {
            return try env_builtins.envCmd(&ctx, command);
        } else if (std.mem.eql(u8, command.name, "export")) {
            return try env_builtins.exportBuiltin(&ctx, command);
        } else if (std.mem.eql(u8, command.name, "set")) {
            return try env_builtins.set(&ctx, command);
        } else if (std.mem.eql(u8, command.name, "unset")) {
            return try env_builtins.unset(&ctx, command);
        } else if (std.mem.eql(u8, command.name, "true")) {
            return 0;
        } else if (std.mem.eql(u8, command.name, "false")) {
            return 1;
        } else if (std.mem.eql(u8, command.name, "test") or std.mem.eql(u8, command.name, "[")) {
            return try test_builtins.testBuiltin(command);
        } else if (std.mem.eql(u8, command.name, "[[")) {
            return try test_builtins.extendedTest(command, self.shell);
        } else if (std.mem.eql(u8, command.name, "which")) {
            return try builtins.command_builtins.which(&ctx, command);
        } else if (std.mem.eql(u8, command.name, "type")) {
            return try builtins.command_builtins.typeBuiltin(&ctx, command);
        } else if (std.mem.eql(u8, command.name, "help")) {
            // Use enhanced help system for specific topics, fallback to basic help
            if (command.args.len > 0) {
                return try builtins.help_system.helpCmd(self.allocator, command);
            }
            return try builtins.help_system.helpCmd(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "alias")) {
            return try alias_builtins.alias(&ctx, command);
        } else if (std.mem.eql(u8, command.name, "unalias")) {
            return try alias_builtins.unalias(&ctx, command);
        } else if (std.mem.eql(u8, command.name, "read")) {
            return try shell_builtins.read(&ctx, command);
        } else if (std.mem.eql(u8, command.name, "printf")) {
            return try io_builtins.printf(command);
        } else if (std.mem.eql(u8, command.name, "source") or std.mem.eql(u8, command.name, ".")) {
            return try shell_builtins.source(&ctx, command);
        } else if (std.mem.eql(u8, command.name, "history")) {
            return try shell_builtins.history(&ctx, command);
        } else if (std.mem.eql(u8, command.name, "pushd")) {
            return try dir_builtins.pushd(&ctx, command);
        } else if (std.mem.eql(u8, command.name, "popd")) {
            return try dir_builtins.popd(&ctx, command);
        } else if (std.mem.eql(u8, command.name, "dirs")) {
            return try dir_builtins.dirs(&ctx, command);
        } else if (std.mem.eql(u8, command.name, "eval")) {
            return try builtins.exec_builtins.eval(&ctx, command);
        } else if (std.mem.eql(u8, command.name, "exec")) {
            return try builtins.exec_builtins.exec(&ctx, command);
        } else if (std.mem.eql(u8, command.name, "command")) {
            return try builtins.exec_builtins.command(&ctx, command);
        } else if (std.mem.eql(u8, command.name, "builtin")) {
            return try builtins.exec_builtins.builtinCmd(&ctx, command);
        } else if (std.mem.eql(u8, command.name, "jobs")) {
            return try builtins.job_builtins.jobs(&ctx, command);
        } else if (std.mem.eql(u8, command.name, "fg")) {
            return try builtins.job_builtins.fg(&ctx, command);
        } else if (std.mem.eql(u8, command.name, "bg")) {
            return try builtins.job_builtins.bg(&ctx, command);
        } else if (std.mem.eql(u8, command.name, "wait")) {
            return try builtins.job_builtins.wait(&ctx, command);
        } else if (std.mem.eql(u8, command.name, "disown")) {
            return try builtins.job_builtins.disown(&ctx, command);
        } else if (std.mem.eql(u8, command.name, "kill")) {
            return try builtins.signal_builtins.kill(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "trap")) {
            return try builtins.state_builtins.trap(&ctx, command);
        } else if (std.mem.eql(u8, command.name, "times")) {
            return try builtins.process_builtins.times(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "umask")) {
            return try builtins.process_builtins.umask(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "getopts")) {
            return try builtins.state_builtins.getopts(&ctx, command);
        } else if (std.mem.eql(u8, command.name, "clear")) {
            return try utilities.clear(command);
        } else if (std.mem.eql(u8, command.name, "time")) {
            return try builtins.process_builtins.time(&ctx, command);
        } else if (std.mem.eql(u8, command.name, "timeout")) {
            return try builtins.process_builtins.timeout(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "hash")) {
            return try builtins.command_builtins.hash(&ctx, command);
        } else if (std.mem.eql(u8, command.name, "yes")) {
            return try utilities.yes(command);
        } else if (std.mem.eql(u8, command.name, "reload")) {
            return try builtins.state_builtins.reload(&ctx, command);
        } else if (std.mem.eql(u8, command.name, "watch")) {
            return try builtins.watch_builtins.watchCmd(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "tree")) {
            return try file_ops.tree(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "grep")) {
            return file_ops.grep(self.allocator, command) catch |err| {
                if (err == error.FallbackToExternal) return try self.executeExternal(command);
                return err;
            };
        } else if (std.mem.eql(u8, command.name, "find")) {
            return file_ops.find(self.allocator, command) catch |err| {
                if (err == error.FallbackToExternal) return try self.executeExternal(command);
                return err;
            };
        } else if (std.mem.eql(u8, command.name, "ft")) {
            return try file_ops.ft(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "calc")) {
            return try file_ops.calc(command);
        } else if (std.mem.eql(u8, command.name, "json")) {
            return try file_ops.json(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "ls")) {
            return file_ops.ls(self.allocator, command) catch |err| {
                if (err == error.FallbackToExternal) return try self.executeExternal(command);
                return err;
            };
        } else if (std.mem.eql(u8, command.name, "seq")) {
            return builtins.seq_builtins.seqCmd(self.allocator, command) catch |err| {
                if (err == error.FallbackToExternal) return try self.executeExternal(command);
                return err;
            };
        } else if (std.mem.eql(u8, command.name, "seq-char")) {
            return try builtins.seq_builtins.seqCharCmd(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "date")) {
            // Use enhanced date builtins for the den-specific subcommands only.
            if (command.args.len > 0) {
                const sub = command.args[0];
                if (std.mem.eql(u8, sub, "now") or std.mem.eql(u8, sub, "format") or
                    std.mem.eql(u8, sub, "to-record") or std.mem.eql(u8, sub, "humanize") or
                    std.mem.eql(u8, sub, "to-table"))
                {
                    return try builtins.date_builtins.dateCmd(self.allocator, command);
                }
            }
            // Standard Unix usage (bare `date`, `date +%Y`, `date -u`, …) is not
            // covered by the builtin, so defer to the real date on PATH.
            return try self.executeExternal(command);
        } else if (std.mem.eql(u8, command.name, "parallel")) {
            return try builtins.process_builtins.parallel(command);
        } else if (std.mem.eql(u8, command.name, "http")) {
            return try builtins.http_builtins.httpCmd(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "base64")) {
            return utilities.base64(self.allocator, command) catch |err| {
                if (err == error.FallbackToExternal) return try self.executeExternal(command);
                return err;
            };
        } else if (std.mem.eql(u8, command.name, "uuid")) {
            return try utilities.uuid(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "localip")) {
            return try utilities.localip(command);
        } else if (std.mem.eql(u8, command.name, "ip")) {
            return try utilities.ip(command);
        } else if (std.mem.eql(u8, command.name, "shrug")) {
            return try utilities.shrug(command);
        } else if (std.mem.eql(u8, command.name, "web")) {
            return try utilities.web(command);
        } else if (std.mem.eql(u8, command.name, "return")) {
            return try builtins.state_builtins.returnBuiltin(&ctx, command);
        } else if (std.mem.eql(u8, command.name, "local")) {
            return try builtins.state_builtins.local(&ctx, command);
        } else if (std.mem.eql(u8, command.name, "copyssh")) {
            return try builtins.macos_builtins.copyssh(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "reloaddns")) {
            return try builtins.macos_builtins.reloaddns(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "emptytrash")) {
            return try builtins.macos_builtins.emptytrash(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "wip")) {
            return try builtins.dev_builtins.wip(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "bookmark")) {
            return try builtins.state_builtins.bookmark(&ctx, command);
        } else if (std.mem.eql(u8, command.name, "code")) {
            return try builtins.dev_builtins.code(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "pstorm")) {
            return try builtins.dev_builtins.pstorm(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "show")) {
            return try builtins.macos_builtins.show(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "hide")) {
            return try builtins.macos_builtins.hide(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "sys-stats")) {
            return try builtins.monitoring_builtins.sysStats(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "netstats")) {
            return try builtins.monitoring_builtins.netstats(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "net-check")) {
            return try builtins.monitoring_builtins.netCheck(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "log-tail")) {
            return try builtins.monitoring_builtins.logTail(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "proc-monitor")) {
            return try builtins.monitoring_builtins.procMonitor(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "log-parse")) {
            return try builtins.monitoring_builtins.logParse(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "dotfiles")) {
            return try builtins.macos_builtins.dotfiles(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "library")) {
            return try builtins.macos_builtins.library(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "hook")) {
            return try builtins.state_builtins.hook(command);
        } else if (std.mem.eql(u8, command.name, "ifind")) {
            return try builtins.interactive_builtins.ifind(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "coproc")) {
            return try builtins.exec_builtins.coproc(&ctx, command);
        } else if (std.mem.eql(u8, command.name, "break")) {
            if (self.shell) |shell| {
                const levels = if (command.args.len > 0)
                    std.fmt.parseInt(u32, command.args[0], 10) catch 1
                else
                    1;
                shell.break_levels = if (levels > 0) levels else 1;
                shell.last_exit_code = 0;
            }
            return 0;
        } else if (std.mem.eql(u8, command.name, "continue")) {
            if (self.shell) |shell| {
                const levels = if (command.args.len > 0)
                    std.fmt.parseInt(u32, command.args[0], 10) catch 1
                else
                    1;
                shell.continue_levels = if (levels > 0) levels else 1;
                shell.last_exit_code = 0;
            }
            return 0;
        } else if (std.mem.eql(u8, command.name, ":")) {
            return 0; // No-op
        }

        // Nushell-inspired structured data commands
        if (std.mem.eql(u8, command.name, "from")) {
            return try builtins.data_builtins.fromCmd(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "to")) {
            return try builtins.data_builtins.toCmd(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "table")) {
            return try builtins.data_builtins.tableCmd(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "grid")) {
            return try builtins.data_builtins.gridCmd(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "where")) {
            return try builtins.pipeline_builtins.whereCmd(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "select")) {
            return try builtins.pipeline_builtins.selectCmd(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "reject")) {
            return try builtins.pipeline_builtins.rejectCmd(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "get")) {
            return try builtins.pipeline_builtins.getCmd(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "first")) {
            return try builtins.pipeline_builtins.firstCmd(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "last")) {
            return try builtins.pipeline_builtins.lastCmd(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "skip")) {
            return try builtins.pipeline_builtins.skipCmd(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "take")) {
            return try builtins.pipeline_builtins.takeCmd(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "length")) {
            return try builtins.pipeline_builtins.lengthCmd(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "flatten")) {
            return try builtins.pipeline_builtins.flattenCmd(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "uniq")) {
            return try builtins.pipeline_builtins.uniqCmd(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "sort-by")) {
            return try builtins.pipeline_builtins.sortByCmd(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "reverse")) {
            return try builtins.pipeline_builtins.reverseCmd(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "transpose")) {
            return try builtins.pipeline_builtins.transposeCmd(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "group-by")) {
            return try builtins.pipeline_builtins.groupByCmd(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "enumerate")) {
            return try builtins.pipeline_builtins.enumerateCmd(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "wrap")) {
            return try builtins.pipeline_builtins.wrapCmd(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "columns")) {
            return try builtins.pipeline_builtins.columnsCmd(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "values")) {
            return try builtins.pipeline_builtins.valuesCmd(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "headers")) {
            return try builtins.pipeline_builtins.headersCmd(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "compact")) {
            return try builtins.pipeline_builtins.compactCmd(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "rename")) {
            return try builtins.pipeline_builtins.renameCmd(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "append")) {
            return try builtins.pipeline_builtins.appendCmd(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "prepend")) {
            return try builtins.pipeline_builtins.prependCmd(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "str")) {
            return try builtins.str_builtins.strCmd(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "path")) {
            return try builtins.path_builtins.pathCmd(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "math")) {
            return try builtins.math_builtins.mathCmd(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "into")) {
            return try builtins.convert_builtins.intoCmd(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "encode")) {
            return try builtins.encode_builtins.encodeCmd(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "decode")) {
            return try builtins.encode_builtins.decodeCmd(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "detect")) {
            return try builtins.detect_builtins.detectColumns(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "bench")) {
            return try builtins.bench_builtins.bench(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "generate")) {
            return try builtins.pipeline_builtins.generateCmd(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "par-each")) {
            return try builtins.pipeline_builtins.parEachCmd(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "explore")) {
            return try builtins.explore_builtins.exploreCmd(self.allocator, command);
        } else if (std.mem.eql(u8, command.name, "use")) {
            return try shell_builtins.useModule(&ctx, command);
        }

        // Check for loadable builtins
        if (self.shell) |shell| {
            if (shell.loadable_builtins.isEnabled(command.name)) {
                return shell.loadable_builtins.execute(self.allocator, command.name, command.args) catch |err| {
                    switch (err) {
                        error.NotLoaded => try IO.eprint("den: {s}: not a loadable builtin\n", .{command.name}),
                        error.Disabled => try IO.eprint("den: {s}: loadable builtin is disabled\n", .{command.name}),
                        else => try IO.eprint("den: {s}: execution error\n", .{command.name}),
                    }
                    return 1;
                };
            }
        }

        try IO.eprint("den: builtin not implemented: {s}\n", .{command.name});
        return 1;
    }

    fn executeExternal(self: *Executor, command: *types.ParsedCommand) !i32 {
        // Check if command exists before forking to provide better error messages
        if (!self.commandExistsInPath(command.name)) {
            // Fire command_not_found hook - if a plugin handles it, skip the error
            if (self.shell) |shell| {
                var cmd_name_copy = @as([]const u8, command.name);
                var hook_ctx = HookContext{
                    .hook_type = .command_not_found,
                    .data = @ptrCast(@alignCast(&cmd_name_copy)),
                    .user_data = null,
                    .allocator = self.allocator,
                };
                if (shell.plugin_registry.executeHooksHandled(.command_not_found, &hook_ctx)) {
                    return 0; // Hook handled the missing command
                }
            }

            // Auto-cd: if command name is a directory, cd into it
            if (self.shell) |shell| {
                if (shell.shopt_autocd) {
                    var dir = std.Io.Dir.cwd().openDir(std.Options.debug_io, command.name, .{}) catch null;
                    if (dir) |*d| {
                        d.close(std.Options.debug_io);
                        // Save OLDPWD, change directory, update PWD. Use
                        // setVariableValue (which dupes) rather than raw .put —
                        // cwd_buf is a stack buffer that would otherwise be
                        // referenced by the hashmap after this frame returns.
                        var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
                        const cwd_len = std.process.currentPath(std.Options.debug_io, &cwd_buf) catch 0;
                        if (cwd_len > 0) {
                            shell.setVariableValue("OLDPWD", cwd_buf[0..cwd_len]) catch {};
                        }
                        std.process.setCurrentPath(std.Options.debug_io, command.name) catch {
                            try IO.eprint("den: cd: {s}: No such file or directory\n", .{command.name});
                            return 1;
                        };
                        // Update PWD
                        const new_len = std.process.currentPath(std.Options.debug_io, &cwd_buf) catch 0;
                        if (new_len > 0) {
                            shell.setVariableValue("PWD", cwd_buf[0..new_len]) catch {};
                        }
                        return 0;
                    }
                }
            }

            try IO.eprint("den: {s}: command not found\n", .{command.name});

            // Try to provide typo correction suggestions
            var tc = TypoCorrection.init(self.allocator);
            if (tc.formatSuggestionMessage(command.name)) |maybe_msg| {
                if (maybe_msg) |suggestion_msg| {
                    defer self.allocator.free(suggestion_msg);
                    try IO.eprint("{s}\n", .{suggestion_msg});
                }
            } else |_| {}

            return 127; // Standard "command not found" exit code
        }

        if (builtin.os.tag == .windows) {
            return try self.executeExternalWindows(command);
        }
        return try self.executeExternalPosix(command);
    }

    /// Check if a command exists in PATH or as an absolute/relative path
    fn commandExistsInPath(self: *Executor, cmd: []const u8) bool {
        _ = self;

        // If command contains a slash, it's a path - check directly
        if (std.mem.indexOf(u8, cmd, "/") != null or
            (builtin.os.tag == .windows and std.mem.indexOf(u8, cmd, "\\") != null))
        {
            const stat = std.Io.Dir.cwd().statFile(std.Options.debug_io, cmd, .{}) catch return false;
            // Check if it's executable (Unix) or just exists (Windows)
            if (builtin.os.tag == .windows) {
                return stat.kind == .file;
            }
            return (stat.permissions.toMode() & 0o111) != 0;
        }

        // Search in PATH
        const path = env_utils.getEnv("PATH") orelse return false;
        var path_iter = std.mem.splitScalar(u8, path, if (builtin.os.tag == .windows) ';' else ':');

        while (path_iter.next()) |dir_path| {
            if (dir_path.len == 0) continue;

            // Try to open the directory and check for the file
            var dir = std.Io.Dir.cwd().openDir(std.Options.debug_io, dir_path, .{}) catch continue;
            defer dir.close(std.Options.debug_io);

            const stat = dir.statFile(std.Options.debug_io, cmd, .{}) catch continue;

            // Check if it's executable
            if (builtin.os.tag == .windows) {
                // On Windows, also check common extensions
                if (stat.kind == .file) return true;
            } else {
                if ((stat.permissions.toMode() & 0o111) != 0) return true;
            }
        }

        // On Windows, also try with common extensions
        if (builtin.os.tag == .windows) {
            const extensions = [_][]const u8{ ".exe", ".cmd", ".bat", ".com" };
            for (extensions) |ext| {
                var buf: [512]u8 = undefined;
                const cmd_with_ext = std.fmt.bufPrint(&buf, "{s}{s}", .{ cmd, ext }) catch continue;

                path_iter = std.mem.splitScalar(u8, path, ';');
                while (path_iter.next()) |dir_path| {
                    if (dir_path.len == 0) continue;

                    var dir = std.Io.Dir.cwd().openDir(std.Options.debug_io, dir_path, .{}) catch continue;
                    defer dir.close(std.Options.debug_io);

                    _ = dir.statFile(std.Options.debug_io, cmd_with_ext, .{}) catch continue;
                    return true;
                }
            }
        }

        return false;
    }

    fn executeExternalWindows(self: *Executor, command: *types.ParsedCommand) !i32 {
        // Build argv list
        var argv_list: std.ArrayList([]const u8) = .empty;
        defer argv_list.deinit(self.allocator);

        try argv_list.append(self.allocator, command.name);
        for (command.args) |arg| {
            try argv_list.append(self.allocator, arg);
        }

        // Determine behaviors from redirections
        var stdin_behavior: std.process.SpawnOptions.StdIo = .inherit;
        var stdout_behavior: std.process.SpawnOptions.StdIo = .inherit;
        var stderr_behavior: std.process.SpawnOptions.StdIo = .inherit;
        var has_stdout_file = false;

        // First pass: determine behaviors
        for (command.redirections) |redir| {
            switch (redir.kind) {
                .output_truncate, .output_append, .output_clobber => {
                    if (redir.fd == 1) {
                        stdout_behavior = .ignore;
                        has_stdout_file = true;
                    } else if (redir.fd == 2) {
                        stderr_behavior = .ignore;
                    }
                },
                .input => {
                    stdin_behavior = .ignore;
                },
                .fd_duplicate => {
                    if (redir.fd == 2 and std.mem.eql(u8, redir.target, "1")) {
                        if (!has_stdout_file) {
                            stderr_behavior = stdout_behavior;
                        }
                    }
                },
                else => {},
            }
        }

        // Create child process
        var child = std.process.spawn(std.Options.debug_io, .{
            .argv = argv_list.items,
            .stdin = stdin_behavior,
            .stdout = stdout_behavior,
            .stderr = stderr_behavior,
        }) catch |err| return err;

        // Second pass: set file handles after spawn
        var stdout_file: ?std.Io.File = null;
        for (command.redirections) |redir| {
            switch (redir.kind) {
                .output_truncate, .output_append, .output_clobber => {
                    const file = try std.Io.Dir.cwd().createFile(std.Options.debug_io, redir.target, .{
                        .truncate = (redir.kind == .output_truncate or redir.kind == .output_clobber),
                    });
                    if (redir.fd == 1) {
                        child.stdout = file;
                        stdout_file = file;
                    } else if (redir.fd == 2) {
                        child.stderr = file;
                    }
                },
                .input => {
                    const file = try std.Io.Dir.cwd().openFile(std.Options.debug_io, redir.target, .{});
                    child.stdin = file;
                },
                .fd_duplicate => {
                    // Handle 2>&1 (redirect stderr to stdout)
                    if (redir.fd == 2 and std.mem.eql(u8, redir.target, "1")) {
                        if (stdout_file) |f| {
                            child.stderr = f;
                        }
                    }
                },
                else => {},
            }
        }

        const term = try child.wait(std.Options.debug_io);

        return switch (term) {
            .exited => |code| code,
            else => 1,
        };
    }

    fn executeExternalPosix(self: *Executor, command: *types.ParsedCommand) !i32 {
        // Build argv (command name + args)
        const argv_len = 1 + command.args.len;
        var argv = try self.allocator.alloc(?[*:0]const u8, argv_len + 1);
        defer self.allocator.free(argv);

        // Allocate command name as null-terminated string
        const cmd_z = try self.allocator.dupeSentinel(u8, command.name, 0);
        defer self.allocator.free(cmd_z);
        argv[0] = cmd_z.ptr;

        // Allocate args as null-terminated strings
        var arg_zs = try self.allocator.alloc([:0]u8, command.args.len);
        var arg_zs_filled: usize = 0;
        defer {
            for (arg_zs[0..arg_zs_filled]) |arg_z| {
                self.allocator.free(arg_z);
            }
            self.allocator.free(arg_zs);
        }

        for (command.args, 0..) |arg, i| {
            arg_zs[i] = try self.allocator.dupeSentinel(u8, arg, 0);
            arg_zs_filled = i + 1;
            argv[i + 1] = arg_zs[i].ptr;
        }
        argv[argv_len] = null;

        // Fork and exec
        const fork_ret = std.c.fork();
        if (fork_ret < 0) return error.Unexpected;
        const pid: std.posix.pid_t = @intCast(fork_ret);

        if (pid == 0) {
            // Child process - apply redirections before exec
            self.applyRedirections(command.redirections) catch {
                std.c._exit(1);
            };

            // Use C's environ directly which is updated by setenv/unsetenv
            _ = c.execvp(cmd_z.ptr, @ptrCast(argv.ptr));
            // If execvp returns, it failed
            IO.eprint("den: {s}: command not found\n", .{command.name}) catch {};
            std.c._exit(127);
        } else {
            // Parent process - wait for child (retry on EINTR from signals)
            var wait_status_exec: c_int = 0;
            if (comptime builtin.os.tag != .windows) {
                _ = process.waitpidIntr(pid, &wait_status_exec, 0);
                const raw: u32 = @bitCast(wait_status_exec);
                if (std.posix.W.IFSIGNALED(raw)) {
                    return 128 + @as(i32, @intCast(@intFromEnum(std.posix.W.TERMSIG(raw))));
                } else {
                    return @intCast(std.posix.W.EXITSTATUS(raw));
                }
            }
            return 0;
        }
    }

    /// Execute command in background (don't wait for it to complete)
    fn executeCommandBackground(self: *Executor, command: *types.ParsedCommand) !void {
        // Expand now (deferred from the shell for chains) before forking.
        try self.ensureExpanded(command);

        // Check if it's a builtin - builtins can't run in background
        if (self.isBuiltin(command.name)) {
            try IO.eprint("den: cannot run builtin '{s}' in background\n", .{command.name});
            return error.BuiltinBackground;
        }

        if (builtin.os.tag == .windows) {
            return try self.executeCommandBackgroundWindows(command);
        }

        // Build argv (command name + args)
        const argv_len = 1 + command.args.len;
        var argv = try self.allocator.alloc(?[*:0]const u8, argv_len + 1);
        defer self.allocator.free(argv);

        // Allocate command name as null-terminated string
        const cmd_z = try self.allocator.dupeSentinel(u8, command.name, 0);
        defer self.allocator.free(cmd_z);
        argv[0] = cmd_z.ptr;

        // Allocate args as null-terminated strings
        var arg_zs = try self.allocator.alloc([:0]u8, command.args.len);
        var arg_zs_filled: usize = 0;
        defer {
            for (arg_zs[0..arg_zs_filled]) |arg_z| {
                self.allocator.free(arg_z);
            }
            self.allocator.free(arg_zs);
        }

        for (command.args, 0..) |arg, i| {
            arg_zs[i] = try self.allocator.dupeSentinel(u8, arg, 0);
            arg_zs_filled = i + 1;
            argv[i + 1] = arg_zs[i].ptr;
        }
        argv[argv_len] = null;

        // Fork and exec
        const fork_ret = std.c.fork();
        if (fork_ret < 0) return error.Unexpected;
        const pid: std.posix.pid_t = @intCast(fork_ret);

        if (pid == 0) {
            // Child process - apply redirections before exec
            self.applyRedirections(command.redirections) catch {
                std.c._exit(1);
            };

            // Use C's environ directly which is updated by setenv/unsetenv
            _ = c.execvp(cmd_z.ptr, @ptrCast(argv.ptr));
            // If execvp returns, it failed
            IO.eprint("den: {s}: command not found\n", .{command.name}) catch {};
            std.c._exit(127);
        } else {
            // Parent process - DON'T wait, just print the PID
            try IO.print("[{d}]\n", .{pid});
        }
    }

    fn executeBuiltinWithRedirectionsWindows(self: *Executor, command: *types.ParsedCommand) !i32 {
        // Windows SetStdHandle is not exposed in Zig std lib yet
        // Note: Full builtin redirection support requires refactoring all builtin functions
        // to accept File parameters instead of using the global IO module. This is a
        // significant architectural change deferred to post-1.0. Current builtins work
        // correctly without redirections, which covers the majority of use cases.

        // Check if there are redirections and warn if so
        if (command.redirections.len > 0) {
            try IO.print("Warning: Builtin redirections not yet fully supported on Windows\n", .{});
        }

        return try self.executeBuiltin(command);
    }

    fn executeCommandBackgroundWindows(self: *Executor, command: *types.ParsedCommand) !void {
        // Build argv list
        var argv_list: std.ArrayList([]const u8) = .empty;
        defer argv_list.deinit(self.allocator);

        try argv_list.append(self.allocator, command.name);
        for (command.args) |arg| {
            try argv_list.append(self.allocator, arg);
        }

        // Create detached child process
        var child = std.process.spawn(std.Options.debug_io, .{
            .argv = argv_list.items,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch |err| return err;

        // Handle redirections after spawn
        for (command.redirections) |redir| {
            switch (redir.kind) {
                .output_truncate, .output_append, .output_clobber => {
                    const file = try std.Io.Dir.cwd().createFile(std.Options.debug_io, redir.target, .{
                        .truncate = (redir.kind == .output_truncate or redir.kind == .output_clobber),
                    });
                    if (redir.fd == 1) {
                        child.stdout = file;
                    } else if (redir.fd == 2) {
                        child.stderr = file;
                    }
                },
                .input => {
                    const file = try std.Io.Dir.cwd().openFile(std.Options.debug_io, redir.target, .{});
                    child.stdin = file;
                },
                else => {},
            }
        }

        // On Windows, process handle serves as the ID
        const handle = child.id;
        try IO.print("[{d}]\n", .{@intFromPtr(handle)});

        // Detach - don't wait for completion
        // The process will continue running independently
    }
};

// ========================================
// Tests for /dev/tcp and /dev/udp support
// ========================================

test "parseDevNetPath - valid IPv4 TCP" {
    const result = parseDevNetPath("/dev/tcp/127.0.0.1/80");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("127.0.0.1", result.?.host);
    try std.testing.expectEqual(@as(u16, 80), result.?.port);
    try std.testing.expect(result.?.is_tcp);
}

test "parseDevNetPath - valid IPv4 UDP" {
    const result = parseDevNetPath("/dev/udp/192.168.1.1/53");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("192.168.1.1", result.?.host);
    try std.testing.expectEqual(@as(u16, 53), result.?.port);
    try std.testing.expect(!result.?.is_tcp);
}

test "parseDevNetPath - valid IPv6 TCP" {
    const result = parseDevNetPath("/dev/tcp/[::1]/8080");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("::1", result.?.host);
    try std.testing.expectEqual(@as(u16, 8080), result.?.port);
    try std.testing.expect(result.?.is_tcp);
}

test "parseDevNetPath - valid IPv6 full address" {
    const result = parseDevNetPath("/dev/tcp/[2001:db8::1]/443");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("2001:db8::1", result.?.host);
    try std.testing.expectEqual(@as(u16, 443), result.?.port);
}

test "parseDevNetPath - invalid: not /dev/tcp or /dev/udp" {
    try std.testing.expect(parseDevNetPath("/dev/null") == null);
    try std.testing.expect(parseDevNetPath("/dev/tty") == null);
    try std.testing.expect(parseDevNetPath("/tmp/foo") == null);
    try std.testing.expect(parseDevNetPath("") == null);
}

test "parseDevNetPath - invalid: missing port" {
    try std.testing.expect(parseDevNetPath("/dev/tcp/127.0.0.1") == null);
    try std.testing.expect(parseDevNetPath("/dev/tcp/127.0.0.1/") == null);
}

test "parseDevNetPath - invalid: missing host" {
    try std.testing.expect(parseDevNetPath("/dev/tcp//80") == null);
    try std.testing.expect(parseDevNetPath("/dev/tcp/") == null);
}

test "parseDevNetPath - invalid: port 0" {
    try std.testing.expect(parseDevNetPath("/dev/tcp/127.0.0.1/0") == null);
}

test "parseDevNetPath - invalid: non-numeric port" {
    try std.testing.expect(parseDevNetPath("/dev/tcp/127.0.0.1/abc") == null);
}

test "parseDevNetPath - invalid: port too large" {
    try std.testing.expect(parseDevNetPath("/dev/tcp/127.0.0.1/65536") == null);
}

test "parseIPv4 - valid addresses" {
    const result1 = parseIPv4("127.0.0.1");
    try std.testing.expect(result1 != null);
    try std.testing.expectEqual([4]u8{ 127, 0, 0, 1 }, result1.?);

    const result2 = parseIPv4("192.168.1.1");
    try std.testing.expect(result2 != null);
    try std.testing.expectEqual([4]u8{ 192, 168, 1, 1 }, result2.?);

    const result3 = parseIPv4("0.0.0.0");
    try std.testing.expect(result3 != null);
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, result3.?);

    const result4 = parseIPv4("255.255.255.255");
    try std.testing.expect(result4 != null);
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, result4.?);
}

test "parseIPv4 - invalid addresses" {
    try std.testing.expect(parseIPv4("") == null);
    try std.testing.expect(parseIPv4("127.0.0") == null);
    try std.testing.expect(parseIPv4("127.0.0.1.2") == null);
    try std.testing.expect(parseIPv4("256.0.0.1") == null);
    try std.testing.expect(parseIPv4("127.0.0.256") == null);
    try std.testing.expect(parseIPv4("abc.def.ghi.jkl") == null);
    try std.testing.expect(parseIPv4("127.0.0.1a") == null);
    try std.testing.expect(parseIPv4("127..0.1") == null);
}

test "parseIPv6 - loopback" {
    const result = parseIPv6("::1");
    try std.testing.expect(result != null);
    try std.testing.expectEqual([16]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, result.?);
}

test "parseIPv6 - all zeros" {
    const result = parseIPv6("::");
    try std.testing.expect(result != null);
    try std.testing.expectEqual([16]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, result.?);
}

test "parseIPv6 - full address" {
    const result = parseIPv6("2001:db8:0:0:0:0:0:1");
    try std.testing.expect(result != null);
    try std.testing.expectEqual([16]u8{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, result.?);
}

test "parseIPv6 - invalid: too many groups" {
    try std.testing.expect(parseIPv6("1:2:3:4:5:6:7:8:9") == null);
}

test "parseIPv6 - invalid: multiple ::" {
    try std.testing.expect(parseIPv6("::1::2") == null);
}
