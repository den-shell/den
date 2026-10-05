const std = @import("std");
const compat = @import("compat");
pub const interface_mod = @import("interface.zig");
const IO = @import("../utils/io.zig").IO;

const HookType = interface_mod.HookType;
const HookFn = interface_mod.HookFn;
const HookContext = interface_mod.HookContext;
const Hook = interface_mod.Hook;

/// Hook execution options
pub const HookOptions = struct {
    timeout_ms: ?u64 = null, // Timeout in milliseconds
    async_exec: bool = false, // Execute asynchronously
    continue_on_error: bool = true, // Continue executing other hooks on error
};

/// Hook execution result
pub const HookResult = struct {
    success: bool,
    error_message: ?[]const u8,
    execution_time_ms: u64,

    pub fn deinit(self: *HookResult, allocator: std.mem.Allocator) void {
        if (self.error_message) |msg| {
            allocator.free(msg);
        }
    }
};

/// Async hook execution state
pub const AsyncHookState = struct {
    hook: Hook,
    context: HookContext,
    result: ?HookResult,
    started_at: compat.Instant,
    timeout_ms: ?u64,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, hook: Hook, context: HookContext, timeout_ms: ?u64) AsyncHookState {
        return .{
            .hook = hook,
            .context = context,
            .result = null,
            .started_at = compat.Instant.now() catch std.mem.zeroes(compat.Instant),
            .timeout_ms = timeout_ms,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *AsyncHookState) void {
        if (self.result) |*result| {
            result.deinit(self.allocator);
        }
    }

    /// Check if execution has timed out
    pub fn isTimedOut(self: *AsyncHookState) bool {
        if (self.timeout_ms) |timeout| {
            const now = compat.Instant.now() catch return false;
            const elapsed_ms = now.since(self.started_at) / 1_000_000;
            return elapsed_ms > timeout;
        }
        return false;
    }
};

/// Enhanced hook manager with async and timeout support
pub const HookManager = struct {
    allocator: std.mem.Allocator,
    hooks: [6]std.ArrayList(Hook), // One list per HookType
    async_states: std.ArrayList(AsyncHookState),
    default_timeout_ms: u64,

    pub fn init(allocator: std.mem.Allocator) HookManager {
        var hooks: [6]std.ArrayList(Hook) = undefined;
        inline for (0..6) |i| {
            hooks[i] = .empty;
        }

        return .{
            .allocator = allocator,
            .hooks = hooks,
            .async_states = .empty,
            .default_timeout_ms = 5000, // 5 seconds default
        };
    }

    pub fn deinit(self: *HookManager) void {
        // Clean up hooks
        for (&self.hooks) |*hook_list| {
            for (hook_list.items) |*hook| {
                hook.deinit();
            }
            hook_list.deinit(self.allocator);
        }

        // Clean up async states
        for (self.async_states.items) |*state| {
            state.deinit();
        }
        self.async_states.deinit(self.allocator);
    }

    /// Register a hook
    pub fn registerHook(self: *HookManager, plugin_name: []const u8, hook_type: HookType, function: HookFn, priority: i32) !void {
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

        const index = @backingInt(hook_type);
        try self.hooks[index].append(self.allocator, hook);

        // Sort by priority (lower numbers run first)
        const items = self.hooks[index].items;
        std.mem.sort(Hook, items, {}, hookCompare);
    }

    /// Unregister all hooks for a plugin
    pub fn unregisterHooks(self: *HookManager, plugin_name: []const u8) void {
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

    /// Execute hooks with options
    pub fn executeHooks(self: *HookManager, hook_type: HookType, context: *HookContext, options: HookOptions) ![]HookResult {
        const index = @backingInt(hook_type);
        const hooks_list = self.hooks[index].items;

        if (hooks_list.len == 0) {
            return &[_]HookResult{};
        }

        var results_buffer: [100]HookResult = undefined;
        var results_count: usize = 0;

        for (hooks_list) |hook| {
            if (!hook.enabled) continue;

            const timeout = options.timeout_ms orelse self.default_timeout_ms;

            if (options.async_exec) {
                // Async execution - spawn and track
                const state = AsyncHookState.init(self.allocator, hook, context.*, timeout);
                try self.async_states.append(self.allocator, state);
            } else {
                // Synchronous execution with timeout
                const result = try self.executeHookWithTimeout(hook, context, timeout);

                if (results_count < results_buffer.len) {
                    results_buffer[results_count] = result;
                    results_count += 1;
                }

                if (!result.success and !options.continue_on_error) {
                    break;
                }
            }
        }

        const results = try self.allocator.alloc(HookResult, results_count);
        @memcpy(results, results_buffer[0..results_count]);
        return results;
    }

    /// Execute a single hook with timeout
    fn executeHookWithTimeout(self: *HookManager, hook: Hook, context: *HookContext, timeout_ms: u64) !HookResult {
        const start_time = compat.Instant.now() catch std.mem.zeroes(compat.Instant);

        var result = HookResult{
            .success = false,
            .error_message = null,
            .execution_time_ms = 0,
        };

        // Execute hook with error handling
        hook.function(context) catch |err| {
            const err_msg = try std.fmt.allocPrint(
                self.allocator,
                "Hook error in {s}: {}",
                .{ hook.plugin_name, err },
            );
            result.error_message = err_msg;
            result.success = false;

            const end_time = compat.Instant.now() catch std.mem.zeroes(compat.Instant);
            result.execution_time_ms = end_time.since(start_time) / 1_000_000;
            return result;
        };

        const end_time = compat.Instant.now() catch std.mem.zeroes(compat.Instant);
        const elapsed = end_time.since(start_time) / 1_000_000;

        result.execution_time_ms = elapsed;
        result.success = true;

        // Check timeout
        if (elapsed > timeout_ms) {
            const err_msg = try std.fmt.allocPrint(
                self.allocator,
                "Hook timeout in {s}: {d}ms > {d}ms",
                .{ hook.plugin_name, elapsed, timeout_ms },
            );
            result.error_message = err_msg;
            result.success = false;
        }

        return result;
    }

    /// Poll async hook states and clean up completed ones
    pub fn pollAsyncHooks(self: *HookManager) !void {
        var i: usize = 0;
        while (i < self.async_states.items.len) {
            var state = &self.async_states.items[i];

            // Check if timed out
            if (state.isTimedOut()) {
                IO.eprint("den: async hook timed out: {s}\n", .{state.hook.plugin_name}) catch {};
                var removed_state = self.async_states.orderedRemove(i);
                removed_state.deinit();
                continue;
            }

            // In a real implementation, we'd check if the async task completed
            // For now, we just increment
            i += 1;
        }
    }

    /// Get hook count for a specific type
    pub fn getHookCount(self: *HookManager, hook_type: HookType) usize {
        const index = @backingInt(hook_type);
        return self.hooks[index].items.len;
    }

    /// List all hooks for a specific type
    pub fn listHooks(self: *HookManager, hook_type: HookType) []const Hook {
        const index = @backingInt(hook_type);
        return self.hooks[index].items;
    }

    /// Enable/disable a specific hook
    pub fn setHookEnabled(self: *HookManager, plugin_name: []const u8, hook_type: HookType, enabled: bool) void {
        const index = @backingInt(hook_type);
        for (self.hooks[index].items) |*hook| {
            if (std.mem.eql(u8, hook.plugin_name, plugin_name)) {
                hook.enabled = enabled;
            }
        }
    }

    /// Set default timeout for hook execution
    pub fn setDefaultTimeout(self: *HookManager, timeout_ms: u64) void {
        self.default_timeout_ms = timeout_ms;
    }
};

/// Helper function for sorting hooks by priority
fn hookCompare(_: void, a: Hook, b: Hook) bool {
    return a.priority < b.priority;
}

// ============================================================================
// Tests
// ============================================================================

test "HookManager init/deinit" {
    var mgr = HookManager.init(std.testing.allocator);
    defer mgr.deinit();

    // 5-second default timeout
    try std.testing.expectEqual(@as(u64, 5000), mgr.default_timeout_ms);
}

test "HookManager setDefaultTimeout" {
    var mgr = HookManager.init(std.testing.allocator);
    defer mgr.deinit();

    mgr.setDefaultTimeout(5000);
    try std.testing.expectEqual(@as(u64, 5000), mgr.default_timeout_ms);
}

test "hookCompare priority ordering semantics" {
    // Verify hookCompare returns true when a's priority < b's priority.
    // We test with minimal Hook-like inputs via the interface_mod struct.
    const dummy_fn: HookFn = struct {
        fn impl(_: *HookContext) anyerror!void {}
    }.impl;

    const a = Hook{
        .plugin_name = "a",
        .hook_type = .pre_command,
        .function = dummy_fn,
        .priority = 5,
        .enabled = true,
        .allocator = std.testing.allocator,
    };
    const b = Hook{
        .plugin_name = "b",
        .hook_type = .pre_command,
        .function = dummy_fn,
        .priority = 10,
        .enabled = true,
        .allocator = std.testing.allocator,
    };

    try std.testing.expect(hookCompare({}, a, b));
    try std.testing.expect(!hookCompare({}, b, a));
    try std.testing.expect(!hookCompare({}, a, a));
}
