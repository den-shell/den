//! Command Execution Module
//! Handles fast path optimization, error traps, and background execution

const std = @import("std");
const builtin = @import("builtin");
const types = @import("../types/mod.zig");
const parser_mod = @import("../parser/mod.zig");
const executor_mod = @import("../executor/mod.zig");
const IO = @import("../utils/io.zig").IO;
const Shell = @import("../shell.zig").Shell;

/// Try to execute a command via the fast path (for simple commands)
/// Returns exit code if handled, null if should fall back to full parser
pub fn tryFastPath(self: *Shell, input: []const u8) ?i32 {
    // Quick check: use OptimizedParser's simple command check
    if (!parser_mod.OptimizedParser.isSimpleCommand(input)) {
        return null;
    }

    // Additional checks for features that require full parser
    for (input) |c| {
        switch (c) {
            // Variable expansion
            '$' => return null,
            // Command substitution
            '`' => return null,
            // Process substitution, grouping
            '(' => return null,
            ')' => return null,
            // Glob patterns
            '*' => return null,
            '?' => return null,
            '[' => return null,
            // Brace expansion
            '{' => return null,
            '}' => return null,
            // Escape sequences
            '\\' => return null,
            else => {},
        }
    }

    // Parse with optimized parser
    var opt_parser = parser_mod.OptimizedParser.init(self.allocator, input);
    const simple_cmd = opt_parser.parseSimpleCommand() catch return null;
    if (simple_cmd == null) return null;
    const cmd = simple_cmd.?;

    // Skip empty commands
    if (cmd.name.len == 0) return null;

    // Check if this is an alias - fall back to full parser for alias expansion
    if (self.aliases.contains(cmd.name)) {
        return null;
    }

    // Check if this is a function - fall back to full parser for function calls
    if (self.function_manager.hasFunction(cmd.name)) {
        return null;
    }

    // Handle trivial builtins directly (no I/O, no state changes except exit)
    if (std.mem.eql(u8, cmd.name, "true")) {
        return 0;
    }

    if (std.mem.eql(u8, cmd.name, "false")) {
        return 1;
    }

    if (std.mem.eql(u8, cmd.name, ":")) {
        // Bash no-op command
        return 0;
    }

    if (std.mem.eql(u8, cmd.name, "exit")) {
        const args = cmd.getArgs();
        if (args.len > 0) {
            self.last_exit_code = std.fmt.parseInt(i32, args[0], 10) catch 0;
        }
        self.running = false;
        self.exit_requested = true;
        return self.last_exit_code;
    }

    // For all other commands (cd, echo, externals, etc.)
    // fall back to full parser to ensure correct handling
    return null;
}

/// Execute ERR trap if one is set
pub fn executeErrTrap(self: *Shell) void {
    // Check if ERR trap is set
    if (self.signal_handlers.get("ERR")) |handler| {
        if (handler.len > 0) {
            // Execute the trap handler
            // Note: Save and restore last_exit_code to preserve $? for the trap
            const saved_exit_code = self.last_exit_code;

            // Parse and execute the trap handler command
            var tokenizer = parser_mod.Tokenizer.init(self.allocator, handler);
            const tokens = tokenizer.tokenize() catch return;
            defer tokenizer.deinitTokens(tokens);

            if (tokens.len == 0) return;

            var parser = parser_mod.Parser.init(self.allocator, tokens);
            var chain = parser.parse() catch return;
            defer chain.deinit(self.allocator);

            // Expand the command chain (for $?, etc)
            self.expandCommandChain(&chain) catch return;

            // Execute the trap handler (without triggering ERR trap again)
            var executor = executor_mod.Executor.initWithShell(self.allocator, &self.environment, self);
            _ = executor.executeChain(&chain) catch {};

            // Restore the original exit code
            self.last_exit_code = saved_exit_code;
        }
    }
}

/// Execute EXIT trap if one is set (called when shell is about to exit)
pub fn executeExitTrap(self: *Shell) void {
    // Check if EXIT trap is set
    if (self.signal_handlers.get("EXIT")) |handler| {
        if (handler.len > 0) {
            // Execute the trap handler
            self.executeCommand(handler) catch {};
        }
    }
}

/// Execute a command chain in the background
pub fn executeInBackground(self: *Shell, chain: *types.CommandChain, original_input: []const u8) !void {
    if (builtin.os.tag == .windows) {
        // Windows: background jobs not yet fully implemented
        try IO.print("background jobs: not fully implemented on Windows\n", .{});
        self.last_exit_code = 0;
        return;
    }

    // Fork the process
    const fork_ret = std.c.fork();
    if (fork_ret < 0) return error.Unexpected;
    const pid: std.posix.pid_t = @intCast(fork_ret);

    if (pid == 0) {
        // Child process - execute the chain
        var executor = executor_mod.Executor.init(self.allocator, &self.environment);
        const exit_code = executor.executeChain(chain) catch 1;
        std.c._exit(@intCast(exit_code));
    } else {
        // Parent process - add to background jobs
        try self.job_manager.add(pid, original_input);
    }
}
