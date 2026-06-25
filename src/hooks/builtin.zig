const std = @import("std");
const compat = @import("compat");
pub const interface_mod = @import("interface.zig");

const HookType = interface_mod.HookType;
const HookContext = interface_mod.HookContext;

/// Built-in hook names
pub const BuiltinHook = enum {
    shell_init, // Shell initialization
    shell_start, // REPL start
    shell_exit, // Shell exit
    command_before, // Before command execution
    command_after, // After command execution
    command_error, // Command error
    directory_change, // Directory change (cd)
    prompt_before, // Before prompt render
    completion_before, // Before completion generation
    history_add, // Before adding to history

    pub fn getName(self: BuiltinHook) []const u8 {
        return switch (self) {
            .shell_init => "shell:init",
            .shell_start => "shell:start",
            .shell_exit => "shell:exit",
            .command_before => "command:before",
            .command_after => "command:after",
            .command_error => "command:error",
            .directory_change => "directory:change",
            .prompt_before => "prompt:before",
            .completion_before => "completion:before",
            .history_add => "history:add",
        };
    }

    pub fn getHookType(self: BuiltinHook) HookType {
        return switch (self) {
            .shell_init => .shell_init,
            .shell_start => .shell_init,
            .shell_exit => .shell_exit,
            .command_before => .pre_command,
            .command_after => .post_command,
            .command_error => .post_command,
            .directory_change => .post_command,
            .prompt_before => .pre_prompt,
            .completion_before => .pre_prompt,
            .history_add => .post_command,
        };
    }
};

/// Hook data for command execution
pub const CommandHookData = struct {
    command: []const u8,
    args: []const []const u8,
    exit_code: ?i32, // null for before, set for after
    error_msg: ?[]const u8, // null for success, set for error
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, command: []const u8, args: []const []const u8) !CommandHookData {
        const cmd_dup = try allocator.dupe(u8, command);
        errdefer allocator.free(cmd_dup);
        const args_dup = try allocator.dupe([]const u8, args);
        errdefer allocator.free(args_dup);
        return .{
            .command = cmd_dup,
            .args = args_dup,
            .exit_code = null,
            .error_msg = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CommandHookData) void {
        self.allocator.free(self.command);
        self.allocator.free(self.args);
        if (self.error_msg) |msg| {
            self.allocator.free(msg);
        }
    }
};

/// Hook data for directory change
pub const DirectoryHookData = struct {
    old_path: []const u8,
    new_path: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, old_path: []const u8, new_path: []const u8) !DirectoryHookData {
        const old_dup = try allocator.dupe(u8, old_path);
        errdefer allocator.free(old_dup);
        const new_dup = try allocator.dupe(u8, new_path);
        errdefer allocator.free(new_dup);
        return .{
            .old_path = old_dup,
            .new_path = new_dup,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *DirectoryHookData) void {
        self.allocator.free(self.old_path);
        self.allocator.free(self.new_path);
    }
};

/// Hook data for prompt rendering
pub const PromptHookData = struct {
    current_dir: []const u8,
    user: []const u8,
    hostname: []const u8,
    custom_prompt: ?[]const u8, // Can be set by hook to customize prompt
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, current_dir: []const u8, user: []const u8, hostname: []const u8) !PromptHookData {
        const dir_dup = try allocator.dupe(u8, current_dir);
        errdefer allocator.free(dir_dup);
        const user_dup = try allocator.dupe(u8, user);
        errdefer allocator.free(user_dup);
        const host_dup = try allocator.dupe(u8, hostname);
        errdefer allocator.free(host_dup);
        return .{
            .current_dir = dir_dup,
            .user = user_dup,
            .hostname = host_dup,
            .custom_prompt = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PromptHookData) void {
        self.allocator.free(self.current_dir);
        self.allocator.free(self.user);
        self.allocator.free(self.hostname);
        if (self.custom_prompt) |prompt| {
            self.allocator.free(prompt);
        }
    }

    pub fn setCustomPrompt(self: *PromptHookData, prompt: []const u8) !void {
        if (self.custom_prompt) |old| {
            self.allocator.free(old);
        }
        self.custom_prompt = try self.allocator.dupe(u8, prompt);
    }
};

/// Hook data for completion
pub const CompletionHookData = struct {
    input: []const u8,
    cursor_pos: usize,
    suggestions: std.ArrayList([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, input: []const u8, cursor_pos: usize) !CompletionHookData {
        return .{
            .input = try allocator.dupe(u8, input),
            .cursor_pos = cursor_pos,
            .suggestions = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CompletionHookData) void {
        self.allocator.free(self.input);
        for (self.suggestions.items) |suggestion| {
            self.allocator.free(suggestion);
        }
        self.suggestions.deinit(self.allocator);
    }

    pub fn addSuggestion(self: *CompletionHookData, suggestion: []const u8) !void {
        const dup = try self.allocator.dupe(u8, suggestion);
        errdefer self.allocator.free(dup);
        try self.suggestions.append(self.allocator, dup);
    }
};

/// Hook data for history
pub const HistoryHookData = struct {
    command: []const u8,
    timestamp: i64,
    should_add: bool, // Can be set to false to prevent adding to history
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, command: []const u8) !HistoryHookData {
        const now = compat.Instant.now() catch std.mem.zeroes(compat.Instant);
        return .{
            .command = try allocator.dupe(u8, command),
            .timestamp = now.timestamp.sec,
            .should_add = true,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *HistoryHookData) void {
        self.allocator.free(self.command);
    }
};

/// Built-in hook registry and management
pub const BuiltinHooks = struct {
    allocator: std.mem.Allocator,
    enabled_hooks: std.AutoHashMap(BuiltinHook, bool),

    pub fn init(allocator: std.mem.Allocator) BuiltinHooks {
        return .{
            .allocator = allocator,
            .enabled_hooks = std.AutoHashMap(BuiltinHook, bool).init(allocator),
        };
    }

    pub fn deinit(self: *BuiltinHooks) void {
        self.enabled_hooks.deinit();
    }

    /// Enable a built-in hook
    pub fn enable(self: *BuiltinHooks, hook: BuiltinHook) !void {
        try self.enabled_hooks.put(hook, true);
    }

    /// Disable a built-in hook
    pub fn disable(self: *BuiltinHooks, hook: BuiltinHook) !void {
        try self.enabled_hooks.put(hook, false);
    }

    /// Check if a hook is enabled
    pub fn isEnabled(self: *BuiltinHooks, hook: BuiltinHook) bool {
        return self.enabled_hooks.get(hook) orelse false;
    }

    /// Enable all hooks
    pub fn enableAll(self: *BuiltinHooks) !void {
        // std.enums.values works across zig versions; std.meta.fields was removed
        // when the reflection API moved to parallel field arrays (0.17 dev).
        inline for (std.enums.values(BuiltinHook)) |hook| {
            try self.enable(hook);
        }
    }

    /// Disable all hooks
    pub fn disableAll(self: *BuiltinHooks) !void {
        inline for (std.enums.values(BuiltinHook)) |hook| {
            try self.disable(hook);
        }
    }

    /// List all enabled hooks
    pub fn listEnabled(self: *BuiltinHooks) ![]BuiltinHook {
        var enabled_buffer: [10]BuiltinHook = undefined;
        var count: usize = 0;

        inline for (std.enums.values(BuiltinHook)) |hook| {
            if (self.isEnabled(hook)) {
                if (count < enabled_buffer.len) {
                    enabled_buffer[count] = hook;
                    count += 1;
                }
            }
        }

        const result = try self.allocator.alloc(BuiltinHook, count);
        @memcpy(result, enabled_buffer[0..count]);
        return result;
    }
};

/// Helper to create hook context for command execution
pub fn createCommandContext(allocator: std.mem.Allocator, hook_type: HookType, data: *CommandHookData) HookContext {
    return .{
        .hook_type = hook_type,
        .data = @ptrCast(data),
        .user_data = null,
        .allocator = allocator,
    };
}

/// Helper to create hook context for directory change
pub fn createDirectoryContext(allocator: std.mem.Allocator, data: *DirectoryHookData) HookContext {
    return .{
        .hook_type = .post_command,
        .data = @ptrCast(data),
        .user_data = null,
        .allocator = allocator,
    };
}

/// Helper to create hook context for prompt
pub fn createPromptContext(allocator: std.mem.Allocator, data: *PromptHookData) HookContext {
    return .{
        .hook_type = .pre_prompt,
        .data = @ptrCast(data),
        .user_data = null,
        .allocator = allocator,
    };
}

/// Helper to create hook context for completion
pub fn createCompletionContext(allocator: std.mem.Allocator, data: *CompletionHookData) HookContext {
    return .{
        .hook_type = .pre_prompt,
        .data = @ptrCast(data),
        .user_data = null,
        .allocator = allocator,
    };
}

/// Helper to create hook context for history
pub fn createHistoryContext(allocator: std.mem.Allocator, data: *HistoryHookData) HookContext {
    return .{
        .hook_type = .post_command,
        .data = @ptrCast(data),
        .user_data = null,
        .allocator = allocator,
    };
}
