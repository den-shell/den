const std = @import("std");
const builtin = @import("builtin");

fn getenvFromSlice(key: []const u8) ?[]const u8 {
    var env_buf: [512]u8 = undefined;
    if (key.len >= env_buf.len) return null;
    @memcpy(env_buf[0..key.len], key);
    env_buf[key.len] = 0;
    const value = std.c.getenv(env_buf[0..key.len :0]) orelse return null;
    return std.mem.span(@as([*:0]const u8, @ptrCast(value)));
}

/// Hook types that plugins can register
pub const HookType = enum {
    pre_command, // Before command execution
    post_command, // After command execution
    pre_prompt, // Before showing prompt
    post_prompt, // After prompt input
    shell_init, // Shell initialization
    shell_exit, // Shell exit
    command_not_found, // When a command is not found (return success from hook to suppress error)
    env_change, // When an environment variable changes (especially PWD)
};

/// Custom command hook - triggers on specific command patterns
pub const CustomHook = struct {
    name: []const u8, // Hook name (e.g., "git:push")
    pattern: []const u8, // Command pattern to match (e.g., "git push")
    script: ?[]const u8, // Script to execute (shell command)
    function: ?HookFn, // Function to call (for plugins)
    enabled: bool,
    priority: i32, // Lower runs first
    condition: ?HookCondition, // Optional condition
};

/// Hook condition types
pub const HookCondition = union(enum) {
    file_exists: []const u8, // Run only if file exists
    env_set: []const u8, // Run only if env var is set
    env_equals: struct { // Run only if env var equals value
        name: []const u8,
        value: []const u8,
    },
    always: void, // Always run
};

/// Custom hook registry
pub const CustomHookRegistry = struct {
    allocator: std.mem.Allocator,
    hooks: std.ArrayListUnmanaged(CustomHook),

    pub fn init(allocator: std.mem.Allocator) CustomHookRegistry {
        return .{
            .allocator = allocator,
            .hooks = .empty,
        };
    }

    pub fn deinit(self: *CustomHookRegistry) void {
        for (self.hooks.items) |hook| {
            self.allocator.free(hook.name);
            self.allocator.free(hook.pattern);
            if (hook.script) |script| {
                self.allocator.free(script);
            }
            if (hook.condition) |cond| {
                switch (cond) {
                    .file_exists => |path| self.allocator.free(path),
                    .env_set => |name| self.allocator.free(name),
                    .env_equals => |eq| {
                        self.allocator.free(eq.name);
                        self.allocator.free(eq.value);
                    },
                    .always => {},
                }
            }
        }
        self.hooks.deinit(self.allocator);
    }

    /// Register a custom command hook
    pub fn register(self: *CustomHookRegistry, name: []const u8, pattern: []const u8, script: ?[]const u8, function: ?HookFn, condition: ?HookCondition, priority: i32) !void {
        const name_dup = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_dup);
        const pattern_dup = try self.allocator.dupe(u8, pattern);
        errdefer self.allocator.free(pattern_dup);
        const script_dup: ?[]const u8 = if (script) |s| try self.allocator.dupe(u8, s) else null;
        errdefer if (script_dup) |s| self.allocator.free(s);

        var cond_dup: ?HookCondition = null;
        errdefer if (cond_dup) |cd| switch (cd) {
            .file_exists => |path| self.allocator.free(path),
            .env_set => |n| self.allocator.free(n),
            .env_equals => |eq| {
                self.allocator.free(eq.name);
                self.allocator.free(eq.value);
            },
            .always => {},
        };
        if (condition) |cond| {
            cond_dup = switch (cond) {
                .file_exists => |path| HookCondition{ .file_exists = try self.allocator.dupe(u8, path) },
                .env_set => |name_str| HookCondition{ .env_set = try self.allocator.dupe(u8, name_str) },
                .env_equals => |eq| blk: {
                    const n = try self.allocator.dupe(u8, eq.name);
                    errdefer self.allocator.free(n);
                    const v = try self.allocator.dupe(u8, eq.value);
                    break :blk HookCondition{ .env_equals = .{ .name = n, .value = v } };
                },
                .always => HookCondition{ .always = {} },
            };
        }

        const hook = CustomHook{
            .name = name_dup,
            .pattern = pattern_dup,
            .script = script_dup,
            .function = function,
            .enabled = true,
            .priority = priority,
            .condition = cond_dup,
        };
        try self.hooks.append(self.allocator, hook);
    }

    /// Find hooks matching a command. Returns a heap-allocated slice owned by
    /// the caller — call `allocator.free(result)` when done. The hook entries
    /// themselves are borrowed from the registry (not copied), so they remain
    /// valid only as long as the registry is not modified.
    pub fn findMatchingHooks(self: *CustomHookRegistry, command: []const u8) ![]CustomHook {
        var matches: std.ArrayListUnmanaged(CustomHook) = .empty;
        errdefer matches.deinit(self.allocator);

        for (self.hooks.items) |hook| {
            if (!hook.enabled) continue;

            // Check if command starts with pattern
            if (std.mem.startsWith(u8, command, hook.pattern)) {
                // Verify pattern is followed by space or end of command
                if (command.len == hook.pattern.len or
                    (command.len > hook.pattern.len and command[hook.pattern.len] == ' '))
                {
                    try matches.append(self.allocator, hook);
                }
            }
        }

        const result = try matches.toOwnedSlice(self.allocator);

        // Sort by priority (lower first)
        std.mem.sort(CustomHook, result, {}, struct {
            fn lessThan(_: void, a: CustomHook, b: CustomHook) bool {
                return a.priority < b.priority;
            }
        }.lessThan);

        return result;
    }

    /// Check if a hook condition is met
    pub fn checkCondition(cond: ?HookCondition) bool {
        const condition = cond orelse return true; // No condition = always run

        switch (condition) {
            .file_exists => |path| {
                _ = std.Io.Dir.cwd().statFile(std.Options.debug_io, path, .{}) catch return false;
                return true;
            },
            .env_set => |name| {
                return getenvFromSlice(name) != null;
            },
            .env_equals => |eq| {
                const value = getenvFromSlice(eq.name) orelse return false;
                return std.mem.eql(u8, value, eq.value);
            },
            .always => return true,
        }
    }

    /// Unregister a hook by name
    pub fn unregister(self: *CustomHookRegistry, name: []const u8) bool {
        var i: usize = 0;
        while (i < self.hooks.items.len) {
            if (std.mem.eql(u8, self.hooks.items[i].name, name)) {
                const hook = self.hooks.orderedRemove(i);
                self.allocator.free(hook.name);
                self.allocator.free(hook.pattern);
                if (hook.script) |script| self.allocator.free(script);
                return true;
            }
            i += 1;
        }
        return false;
    }

    /// List all registered hooks
    pub fn list(self: *CustomHookRegistry) []const CustomHook {
        return self.hooks.items;
    }

    /// Enable/disable a hook
    pub fn setEnabled(self: *CustomHookRegistry, name: []const u8, enabled: bool) bool {
        for (self.hooks.items) |*hook| {
            if (std.mem.eql(u8, hook.name, name)) {
                hook.enabled = enabled;
                return true;
            }
        }
        return false;
    }
};

/// Hook function signature
pub const HookFn = *const fn (context: *HookContext) anyerror!void;

/// Hook context passed to hook functions
pub const HookContext = struct {
    hook_type: HookType,
    data: ?*anyopaque, // Hook-specific data
    user_data: ?*anyopaque, // Plugin-specific data
    allocator: std.mem.Allocator,

    /// Get command string (for pre/post_command hooks)
    pub fn getCommand(self: *HookContext) ?[]const u8 {
        if (self.data) |data| {
            // Cast to []const u8
            const cmd: *[]const u8 = @ptrCast(@alignCast(data));
            return cmd.*;
        }
        return null;
    }

    /// Set user data
    pub fn setUserData(self: *HookContext, data: *anyopaque) void {
        self.user_data = data;
    }

    /// Get user data
    pub fn getUserData(self: *HookContext) ?*anyopaque {
        return self.user_data;
    }
};

/// Registered hook
pub const Hook = struct {
    plugin_name: []const u8,
    hook_type: HookType,
    function: HookFn,
    priority: i32, // Lower numbers run first
    enabled: bool,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Hook) void {
        self.allocator.free(self.plugin_name);
    }
};

/// Plugin command function signature
pub const CommandFn = *const fn (args: []const []const u8) anyerror!i32;

/// Registered plugin command
pub const PluginCommand = struct {
    name: []const u8,
    plugin_name: []const u8,
    description: []const u8,
    function: CommandFn,
    enabled: bool,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *PluginCommand) void {
        self.allocator.free(self.name);
        self.allocator.free(self.plugin_name);
        self.allocator.free(self.description);
    }

    /// Execute the command
    pub fn execute(self: *PluginCommand, args: []const []const u8) !i32 {
        if (!self.enabled) {
            return error.CommandDisabled;
        }
        return try self.function(args);
    }
};

/// Completion function signature
pub const CompletionFn = *const fn (input: []const u8, allocator: std.mem.Allocator) anyerror![][]const u8;

/// Registered completion provider
pub const CompletionProvider = struct {
    plugin_name: []const u8,
    prefix: []const u8, // Command/path prefix to match
    function: CompletionFn,
    enabled: bool,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *CompletionProvider) void {
        self.allocator.free(self.plugin_name);
        self.allocator.free(self.prefix);
    }

    /// Get completions
    pub fn getCompletions(self: *CompletionProvider, input: []const u8, allocator: std.mem.Allocator) ![][]const u8 {
        if (!self.enabled) {
            return &[_][]const u8{};
        }
        return try self.function(input, allocator);
    }
};

/// Plugin Interface Registry - manages hooks, commands, and completions
/// Error statistics for a plugin
pub const PluginErrorStats = struct {
    plugin_name: []const u8,
    hook_errors: u64 = 0,
    command_errors: u64 = 0,
    last_error: ?[]const u8 = null,
    last_error_time: i64 = 0,
};

pub const PluginRegistry = struct {
    allocator: std.mem.Allocator,
    hooks: [8]std.ArrayList(Hook), // One list per HookType
    commands: std.StringHashMap(PluginCommand),
    completions: std.ArrayList(CompletionProvider),
    error_stats: std.StringHashMap(PluginErrorStats), // Error tracking per plugin
    verbose_errors: bool = true, // Whether to print errors to stderr

    pub fn init(allocator: std.mem.Allocator) PluginRegistry {
        var hooks: [8]std.ArrayList(Hook) = undefined;
        inline for (0..8) |i| {
            hooks[i] = .empty;
        }

        return .{
            .allocator = allocator,
            .hooks = hooks,
            .commands = std.StringHashMap(PluginCommand).init(allocator),
            .completions = .empty,
            .error_stats = std.StringHashMap(PluginErrorStats).init(allocator),
            .verbose_errors = true,
        };
    }

    pub fn deinit(self: *PluginRegistry) void {
        // Clean up hooks
        for (&self.hooks) |*hook_list| {
            for (hook_list.items) |*hook| {
                hook.deinit();
            }
            hook_list.deinit(self.allocator);
        }

        // Clean up commands
        var cmd_iter = self.commands.iterator();
        while (cmd_iter.next()) |entry| {
            var cmd = entry.value_ptr;
            cmd.deinit();
        }
        self.commands.deinit();

        // Clean up completions
        for (self.completions.items) |*completion| {
            completion.deinit();
        }
        self.completions.deinit(self.allocator);

        // Clean up error stats
        var stats_iter = self.error_stats.iterator();
        while (stats_iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.plugin_name);
            if (entry.value_ptr.last_error) |err_msg| {
                self.allocator.free(err_msg);
            }
        }
        self.error_stats.deinit();
    }

    /// Register a hook
    pub fn registerHook(self: *PluginRegistry, plugin_name: []const u8, hook_type: HookType, function: HookFn, priority: i32) !void {
        const name_dup = try self.allocator.dupe(u8, plugin_name);
        errdefer self.allocator.free(name_dup);

        const hook = Hook{
            .plugin_name = name_dup,
            .hook_type = hook_type,
            .function = function,
            .priority = priority,
            .enabled = true,
            .allocator = self.allocator,
        };

        const index = @intFromEnum(hook_type);
        try self.hooks[index].append(self.allocator, hook);

        // Sort by priority
        const items = self.hooks[index].items;
        std.mem.sort(Hook, items, {}, hookCompare);
    }

    /// Unregister all hooks for a plugin
    pub fn unregisterHooks(self: *PluginRegistry, plugin_name: []const u8) void {
        for (&self.hooks) |*hook_list| {
            var i: usize = 0;
            while (i < hook_list.items.len) {
                if (std.mem.eql(u8, hook_list.items[i].plugin_name, plugin_name)) {
                    var hook = hook_list.orderedRemove(i);
                    hook.deinit();
                } else {
                    i += 1;
                }
            }
        }
    }

    /// Record an error for a plugin
    fn recordError(self: *PluginRegistry, plugin_name: []const u8, error_type: []const u8, err: anyerror) !void {
        const gop = try self.error_stats.getOrPut(plugin_name);
        if (!gop.found_existing) {
            gop.value_ptr.* = PluginErrorStats{
                .plugin_name = try self.allocator.dupe(u8, plugin_name),
            };
        }

        // Increment appropriate counter
        if (std.mem.eql(u8, error_type, "hook")) {
            gop.value_ptr.hook_errors += 1;
        } else if (std.mem.eql(u8, error_type, "command")) {
            gop.value_ptr.command_errors += 1;
        }

        // Update last error
        if (gop.value_ptr.last_error) |old_err| {
            self.allocator.free(old_err);
        }
        const err_msg = try std.fmt.allocPrint(self.allocator, "{s}: {}", .{ error_type, err });
        gop.value_ptr.last_error = err_msg;
        gop.value_ptr.last_error_time = 0; // Timestamp not available in Zig 0.16
    }

    /// Execute hooks of a specific type
    pub fn executeHooks(self: *PluginRegistry, hook_type: HookType, context: *HookContext) !void {
        const index = @intFromEnum(hook_type);
        for (self.hooks[index].items) |hook| {
            if (hook.enabled) {
                hook.function(context) catch |err| {
                    // Record the error
                    self.recordError(hook.plugin_name, "hook", err) catch {};

                    // Print error if verbose mode is enabled
                    if (self.verbose_errors) {
                        var buf: [512]u8 = undefined;
                        const msg = std.fmt.bufPrint(&buf, "[Plugin Error] {s} hook '{s}' failed: {}\n", .{
                            hook.plugin_name,
                            @tagName(hook_type),
                            err,
                        }) catch "[Plugin Error] Failed to format error message\n";

                        // Skip stderr output if we can't get a handle (rather
                        // than panic via unreachable — this path is already
                        // handling a plugin error and shouldn't cascade to a crash).
                        const maybe_stderr: ?std.Io.File = if (builtin.os.tag == .windows) blk: {
                            const h = @import("windows_compat").GetStdHandle(@import("windows_compat").STD_ERROR_HANDLE) orelse break :blk null;
                            break :blk std.Io.File{ .handle = h, .flags = .{ .nonblocking = false } };
                        } else std.Io.File{ .handle = std.posix.STDERR_FILENO, .flags = .{ .nonblocking = false } };
                        if (maybe_stderr) |stderr_file| {
                            stderr_file.writeStreamingAll(std.Options.debug_io, msg) catch {};
                        }
                    }
                };
            }
        }
    }

    /// Execute hooks of a specific type, returning true if any hook handled the event
    /// (i.e., completed without error). Used for command_not_found to allow hooks to
    /// handle missing commands before the shell prints an error.
    pub fn executeHooksHandled(self: *PluginRegistry, hook_type: HookType, context: *HookContext) bool {
        const index = @intFromEnum(hook_type);
        var handled = false;
        for (self.hooks[index].items) |hook| {
            if (hook.enabled) {
                hook.function(context) catch |err| {
                    // Record the error
                    self.recordError(hook.plugin_name, "hook", err) catch {};

                    if (self.verbose_errors) {
                        var buf: [512]u8 = undefined;
                        const msg = std.fmt.bufPrint(&buf, "[Plugin Error] {s} hook '{s}' failed: {}\n", .{
                            hook.plugin_name,
                            @tagName(hook_type),
                            err,
                        }) catch "[Plugin Error] Failed to format error message\n";

                        // Skip stderr output if we can't get a handle (rather
                        // than panic via unreachable — this path is already
                        // handling a plugin error and shouldn't cascade to a crash).
                        const maybe_stderr: ?std.Io.File = if (builtin.os.tag == .windows) blk: {
                            const h = @import("windows_compat").GetStdHandle(@import("windows_compat").STD_ERROR_HANDLE) orelse break :blk null;
                            break :blk std.Io.File{ .handle = h, .flags = .{ .nonblocking = false } };
                        } else std.Io.File{ .handle = std.posix.STDERR_FILENO, .flags = .{ .nonblocking = false } };
                        if (maybe_stderr) |stderr_file| {
                            stderr_file.writeStreamingAll(std.Options.debug_io, msg) catch {};
                        }
                    }
                    continue;
                };
                // Hook succeeded without error - it handled the event
                handled = true;
            }
        }
        return handled;
    }

    /// Register a command
    pub fn registerCommand(self: *PluginRegistry, plugin_name: []const u8, name: []const u8, description: []const u8, function: CommandFn) !void {
        // Check if command already exists
        if (self.commands.contains(name)) {
            return error.CommandAlreadyExists;
        }

        const name_dup = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_dup);
        const plugin_dup = try self.allocator.dupe(u8, plugin_name);
        errdefer self.allocator.free(plugin_dup);
        const desc_dup = try self.allocator.dupe(u8, description);
        errdefer self.allocator.free(desc_dup);

        const cmd = PluginCommand{
            .name = name_dup,
            .plugin_name = plugin_dup,
            .description = desc_dup,
            .function = function,
            .enabled = true,
            .allocator = self.allocator,
        };

        try self.commands.put(cmd.name, cmd);
    }

    /// Unregister all commands for a plugin. Previously capped at 256 commands
    /// (silent truncation caused memory leaks on plugin shutdown if a plugin
    /// registered more); now uses dynamic allocation.
    pub fn unregisterCommands(self: *PluginRegistry, plugin_name: []const u8) void {
        var to_remove: std.ArrayListUnmanaged([]const u8) = .empty;
        defer to_remove.deinit(self.allocator);

        var iter = self.commands.iterator();
        while (iter.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.plugin_name, plugin_name)) {
                // On append failure the plugin can't be fully cleaned up,
                // but we continue so we at least remove what we can track.
                to_remove.append(self.allocator, entry.key_ptr.*) catch break;
            }
        }

        for (to_remove.items) |name| {
            if (self.commands.fetchRemove(name)) |kv| {
                var cmd = kv.value;
                cmd.deinit();
            }
        }
    }

    /// Get a command by name
    pub fn getCommand(self: *PluginRegistry, name: []const u8) ?*PluginCommand {
        return self.commands.getPtr(name);
    }

    /// Execute a plugin command
    pub fn executeCommand(self: *PluginRegistry, name: []const u8, args: []const []const u8) !i32 {
        const cmd = self.getCommand(name) orelse return error.CommandNotFound;
        return try cmd.execute(args);
    }

    /// List all registered commands. Returns a heap-allocated slice owned by
    /// the caller (free with `self.allocator.free(result)`). No silent
    /// truncation — all commands are returned regardless of count.
    pub fn listCommands(self: *PluginRegistry) ![][]const u8 {
        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer names.deinit(self.allocator);

        var iter = self.commands.iterator();
        while (iter.next()) |entry| {
            try names.append(self.allocator, entry.key_ptr.*);
        }

        return try names.toOwnedSlice(self.allocator);
    }

    /// Register a completion provider
    pub fn registerCompletion(self: *PluginRegistry, plugin_name: []const u8, prefix: []const u8, function: CompletionFn) !void {
        const completion = CompletionProvider{
            .plugin_name = try self.allocator.dupe(u8, plugin_name),
            .prefix = try self.allocator.dupe(u8, prefix),
            .function = function,
            .enabled = true,
            .allocator = self.allocator,
        };

        try self.completions.append(self.allocator, completion);
    }

    /// Unregister all completions for a plugin
    pub fn unregisterCompletions(self: *PluginRegistry, plugin_name: []const u8) void {
        var i: usize = 0;
        while (i < self.completions.items.len) {
            if (std.mem.eql(u8, self.completions.items[i].plugin_name, plugin_name)) {
                var completion = self.completions.orderedRemove(i);
                completion.deinit();
            } else {
                i += 1;
            }
        }
    }

    /// Get completions for input. Previously capped at 1000 (with items beyond
    /// the cap leaked as they were never freed); now uses dynamic allocation.
    pub fn getCompletions(self: *PluginRegistry, input: []const u8) ![][]const u8 {
        var all_completions: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer all_completions.deinit(self.allocator);

        for (self.completions.items) |*completion| {
            if (completion.enabled and std.mem.startsWith(u8, input, completion.prefix)) {
                const items = try completion.getCompletions(input, self.allocator);
                defer self.allocator.free(items);
                try all_completions.appendSlice(self.allocator, items);
            }
        }

        return try all_completions.toOwnedSlice(self.allocator);
    }

    /// Get error statistics for a specific plugin
    pub fn getPluginErrors(self: *PluginRegistry, plugin_name: []const u8) ?PluginErrorStats {
        return self.error_stats.get(plugin_name);
    }

    /// Get all plugin error statistics. Returns a heap-allocated slice owned
    /// by the caller. No silent truncation — all error stats are returned.
    pub fn getAllErrors(self: *PluginRegistry) ![]PluginErrorStats {
        var stats: std.ArrayListUnmanaged(PluginErrorStats) = .empty;
        errdefer stats.deinit(self.allocator);

        var iter = self.error_stats.iterator();
        while (iter.next()) |entry| {
            try stats.append(self.allocator, entry.value_ptr.*);
        }

        return try stats.toOwnedSlice(self.allocator);
    }

    /// Clear error statistics for a plugin
    pub fn clearPluginErrors(self: *PluginRegistry, plugin_name: []const u8) void {
        if (self.error_stats.fetchRemove(plugin_name)) |kv| {
            self.allocator.free(kv.value.plugin_name);
            if (kv.value.last_error) |err| {
                self.allocator.free(err);
            }
        }
    }

    /// Set verbose error reporting
    pub fn setVerboseErrors(self: *PluginRegistry, verbose: bool) void {
        self.verbose_errors = verbose;
    }
};

/// Helper function for sorting hooks by priority
fn hookCompare(_: void, a: Hook, b: Hook) bool {
    return a.priority < b.priority;
}

// ============================================================================
// Tests
// ============================================================================

test "CustomHookRegistry findMatchingHooks returns heap-allocated slice" {
    var registry = CustomHookRegistry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.register("test1", "git push", null, null, null, 0);
    try registry.register("test2", "git pull", null, null, null, 0);
    try registry.register("test3", "git push", null, null, null, 1);

    // Returned slice should be owned by caller (heap-allocated)
    const matches = try registry.findMatchingHooks("git push origin main");
    defer std.testing.allocator.free(matches);

    try std.testing.expectEqual(@as(usize, 2), matches.len);
    // Sorted by priority: test1 (priority 0) should come first
    try std.testing.expectEqualStrings("test1", matches[0].name);
    try std.testing.expectEqualStrings("test3", matches[1].name);
}

test "findMatchingHooks empty when no match" {
    var registry = CustomHookRegistry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.register("test1", "git push", null, null, null, 0);

    const matches = try registry.findMatchingHooks("ls -la");
    defer std.testing.allocator.free(matches);

    try std.testing.expectEqual(@as(usize, 0), matches.len);
}

test "findMatchingHooks exact command match" {
    var registry = CustomHookRegistry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.register("exact", "ls", null, null, null, 0);

    // Exact match (no trailing space)
    const matches1 = try registry.findMatchingHooks("ls");
    defer std.testing.allocator.free(matches1);
    try std.testing.expectEqual(@as(usize, 1), matches1.len);

    // With space after should match
    const matches2 = try registry.findMatchingHooks("ls -la");
    defer std.testing.allocator.free(matches2);
    try std.testing.expectEqual(@as(usize, 1), matches2.len);

    // Substring should NOT match (no space boundary)
    const matches3 = try registry.findMatchingHooks("lsof");
    defer std.testing.allocator.free(matches3);
    try std.testing.expectEqual(@as(usize, 0), matches3.len);
}

test "findMatchingHooks respects enabled flag" {
    var registry = CustomHookRegistry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.register("disabled_hook", "test", null, null, null, 0);
    _ = registry.setEnabled("disabled_hook", false);

    const matches = try registry.findMatchingHooks("test command");
    defer std.testing.allocator.free(matches);

    try std.testing.expectEqual(@as(usize, 0), matches.len);
}

test "findMatchingHooks supports many hooks (beyond old 32 limit)" {
    var registry = CustomHookRegistry.init(std.testing.allocator);
    defer registry.deinit();

    // Register 50 hooks (more than the old fixed limit of 32)
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "hook_{d}", .{i});
        try registry.register(name, "run", null, null, null, @intCast(i));
    }

    const matches = try registry.findMatchingHooks("run all");
    defer std.testing.allocator.free(matches);

    try std.testing.expectEqual(@as(usize, 50), matches.len);
    // Should be sorted by priority ascending
    try std.testing.expectEqualStrings("hook_0", matches[0].name);
    try std.testing.expectEqualStrings("hook_49", matches[49].name);
}

test "HookType enum values" {
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(HookType.pre_command));
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(HookType.post_command));
}

test "CustomHook fields" {
    const hook = CustomHook{
        .name = "test",
        .pattern = "git",
        .script = null,
        .function = null,
        .enabled = true,
        .priority = 5,
        .condition = null,
    };
    try std.testing.expect(hook.enabled);
    try std.testing.expectEqual(@as(i32, 5), hook.priority);
}

test "PluginRegistry listCommands is heap-allocated" {
    var registry = PluginRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const names = try registry.listCommands();
    defer std.testing.allocator.free(names);

    // Empty registry returns empty slice, but type must be heap-owned
    try std.testing.expectEqual(@as(usize, 0), names.len);
}

test "PluginRegistry getAllErrors is heap-allocated" {
    var registry = PluginRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const stats = try registry.getAllErrors();
    defer std.testing.allocator.free(stats);

    // Empty registry returns empty slice, no silent truncation
    try std.testing.expectEqual(@as(usize, 0), stats.len);
}

test "PluginRegistry getCompletions empty" {
    var registry = PluginRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const completions = try registry.getCompletions("test");
    defer std.testing.allocator.free(completions);

    try std.testing.expectEqual(@as(usize, 0), completions.len);
}

test "PluginRegistry unregisterCommands no-op on empty" {
    var registry = PluginRegistry.init(std.testing.allocator);
    defer registry.deinit();

    // Should not panic on empty registry
    registry.unregisterCommands("nonexistent");
}
