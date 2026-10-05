const std = @import("std");
const interface_mod = @import("interface.zig");
const example_plugins = @import("example_plugins.zig");

const HookType = interface_mod.HookType;
const HookContext = interface_mod.HookContext;
const PluginRegistry = interface_mod.PluginRegistry;

test "PluginRegistry - initialization" {
    const allocator = std.testing.allocator;

    var registry = PluginRegistry.init(allocator);
    defer registry.deinit();

    // Verify empty state
    try std.testing.expectEqual(@as(usize, 0), registry.commands.count());
    try std.testing.expectEqual(@as(usize, 0), registry.completions.items.len);
}

test "PluginRegistry - register hook" {
    const allocator = std.testing.allocator;

    var registry = PluginRegistry.init(allocator);
    defer registry.deinit();

    // Register a pre_command hook
    try registry.registerHook("test_plugin", .pre_command, example_plugins.counterPreCommand, 0);

    // Verify hook was registered
    const index = @backingInt(HookType.pre_command);
    try std.testing.expectEqual(@as(usize, 1), registry.hooks[index].items.len);

    const hook = registry.hooks[index].items[0];
    try std.testing.expectEqualStrings("test_plugin", hook.plugin_name);
    try std.testing.expectEqual(HookType.pre_command, hook.hook_type);
    try std.testing.expect(hook.enabled);
}

test "PluginRegistry - register multiple hooks with priority" {
    const allocator = std.testing.allocator;

    var registry = PluginRegistry.init(allocator);
    defer registry.deinit();

    // Register hooks with different priorities
    try registry.registerHook("plugin_low", .pre_command, example_plugins.counterPreCommand, 100);
    try registry.registerHook("plugin_high", .pre_command, example_plugins.timerPreCommand, 0);
    try registry.registerHook("plugin_mid", .pre_command, example_plugins.loggerPreCommand, 50);

    // Verify hooks are sorted by priority
    const index = @backingInt(HookType.pre_command);
    try std.testing.expectEqual(@as(usize, 3), registry.hooks[index].items.len);

    // Should be sorted: high (0) < mid (50) < low (100)
    try std.testing.expectEqual(@as(i32, 0), registry.hooks[index].items[0].priority);
    try std.testing.expectEqual(@as(i32, 50), registry.hooks[index].items[1].priority);
    try std.testing.expectEqual(@as(i32, 100), registry.hooks[index].items[2].priority);
}

test "PluginRegistry - unregister hooks" {
    const allocator = std.testing.allocator;

    var registry = PluginRegistry.init(allocator);
    defer registry.deinit();

    // Register multiple hooks from different plugins
    try registry.registerHook("plugin_a", .pre_command, example_plugins.counterPreCommand, 0);
    try registry.registerHook("plugin_b", .pre_command, example_plugins.timerPreCommand, 0);
    try registry.registerHook("plugin_a", .post_command, example_plugins.counterPostCommand, 0);

    // Verify initial state
    const pre_index = @backingInt(HookType.pre_command);
    const post_index = @backingInt(HookType.post_command);
    try std.testing.expectEqual(@as(usize, 2), registry.hooks[pre_index].items.len);
    try std.testing.expectEqual(@as(usize, 1), registry.hooks[post_index].items.len);

    // Unregister plugin_a hooks
    registry.unregisterHooks("plugin_a");

    // Verify plugin_a hooks removed, plugin_b remains
    try std.testing.expectEqual(@as(usize, 1), registry.hooks[pre_index].items.len);
    try std.testing.expectEqual(@as(usize, 0), registry.hooks[post_index].items.len);
    try std.testing.expectEqualStrings("plugin_b", registry.hooks[pre_index].items[0].plugin_name);
}

test "PluginRegistry - execute hooks" {
    const allocator = std.testing.allocator;

    var registry = PluginRegistry.init(allocator);
    defer registry.deinit();

    // Initialize logger plugin
    example_plugins.loggerInit(allocator);
    defer example_plugins.loggerShutdown();

    // Register hooks
    try registry.registerHook("counter", .pre_command, example_plugins.counterPreCommand, 0);
    try registry.registerHook("logger", .pre_command, example_plugins.loggerPreCommand, 10);

    // Create hook context
    const cmd = try allocator.dupe(u8, "test command");
    defer allocator.free(cmd);
    var cmd_ptr = cmd;
    var context = HookContext{
        .hook_type = .pre_command,
        .data = @ptrCast(@alignCast(&cmd_ptr)),
        .user_data = null,
        .allocator = allocator,
    };

    // Execute hooks
    try registry.executeHooks(.pre_command, &context);

    // Both hooks should have been called
    // (We can't directly verify counter_count since it's private, but we can verify no errors)
}

test "PluginRegistry - register command" {
    const allocator = std.testing.allocator;

    var registry = PluginRegistry.init(allocator);
    defer registry.deinit();

    // Register a command
    try registry.registerCommand("math_plugin", "add", "Add two numbers", example_plugins.mathAdd);

    // Verify command was registered
    try std.testing.expectEqual(@as(usize, 1), registry.commands.count());

    const cmd = registry.getCommand("add");
    try std.testing.expect(cmd != null);
    try std.testing.expectEqualStrings("add", cmd.?.name);
    try std.testing.expectEqualStrings("math_plugin", cmd.?.plugin_name);
    try std.testing.expectEqualStrings("Add two numbers", cmd.?.description);
    try std.testing.expect(cmd.?.enabled);
}

test "PluginRegistry - register duplicate command fails" {
    const allocator = std.testing.allocator;

    var registry = PluginRegistry.init(allocator);
    defer registry.deinit();

    // Register a command
    try registry.registerCommand("plugin1", "add", "First add", example_plugins.mathAdd);

    // Try to register same command name again
    const result = registry.registerCommand("plugin2", "add", "Second add", example_plugins.mathSubtract);
    try std.testing.expectError(error.CommandAlreadyExists, result);
}

test "PluginRegistry - execute command" {
    const allocator = std.testing.allocator;

    var registry = PluginRegistry.init(allocator);
    defer registry.deinit();

    // Register math commands
    try registry.registerCommand("math", "add", "Add two numbers", example_plugins.mathAdd);
    try registry.registerCommand("math", "subtract", "Subtract two numbers", example_plugins.mathSubtract);
    try registry.registerCommand("math", "multiply", "Multiply two numbers", example_plugins.mathMultiply);

    // Execute add command
    const args1 = [_][]const u8{ "10", "20" };
    const exit_code1 = try registry.executeCommand("add", &args1);
    try std.testing.expectEqual(@as(i32, 0), exit_code1);

    // Execute subtract command
    const args2 = [_][]const u8{ "100", "30" };
    const exit_code2 = try registry.executeCommand("subtract", &args2);
    try std.testing.expectEqual(@as(i32, 0), exit_code2);

    // Execute multiply command
    const args3 = [_][]const u8{ "5", "7" };
    const exit_code3 = try registry.executeCommand("multiply", &args3);
    try std.testing.expectEqual(@as(i32, 0), exit_code3);
}

test "PluginRegistry - execute nonexistent command fails" {
    const allocator = std.testing.allocator;

    var registry = PluginRegistry.init(allocator);
    defer registry.deinit();

    const args = [_][]const u8{};
    const result = registry.executeCommand("nonexistent", &args);
    try std.testing.expectError(error.CommandNotFound, result);
}

test "PluginRegistry - unregister commands" {
    const allocator = std.testing.allocator;

    var registry = PluginRegistry.init(allocator);
    defer registry.deinit();

    // Register commands from multiple plugins
    try registry.registerCommand("math", "add", "Add", example_plugins.mathAdd);
    try registry.registerCommand("math", "subtract", "Subtract", example_plugins.mathSubtract);
    try registry.registerCommand("greeter", "hello", "Say hello", example_plugins.greeterSayHello);

    try std.testing.expectEqual(@as(usize, 3), registry.commands.count());

    // Unregister math plugin commands
    registry.unregisterCommands("math");

    // Only greeter command should remain
    try std.testing.expectEqual(@as(usize, 1), registry.commands.count());
    try std.testing.expect(registry.getCommand("add") == null);
    try std.testing.expect(registry.getCommand("subtract") == null);
    try std.testing.expect(registry.getCommand("hello") != null);
}

test "PluginRegistry - list commands" {
    const allocator = std.testing.allocator;

    var registry = PluginRegistry.init(allocator);
    defer registry.deinit();

    // Register commands
    try registry.registerCommand("math", "add", "Add", example_plugins.mathAdd);
    try registry.registerCommand("math", "subtract", "Subtract", example_plugins.mathSubtract);
    try registry.registerCommand("greeter", "hello", "Hello", example_plugins.greeterSayHello);

    const names = try registry.listCommands();
    defer allocator.free(names);

    try std.testing.expectEqual(@as(usize, 3), names.len);

    // Verify all command names are present (order may vary)
    var found_add = false;
    var found_subtract = false;
    var found_hello = false;

    for (names) |name| {
        if (std.mem.eql(u8, name, "add")) found_add = true;
        if (std.mem.eql(u8, name, "subtract")) found_subtract = true;
        if (std.mem.eql(u8, name, "hello")) found_hello = true;
    }

    try std.testing.expect(found_add);
    try std.testing.expect(found_subtract);
    try std.testing.expect(found_hello);
}

test "PluginRegistry - register completion" {
    const allocator = std.testing.allocator;

    var registry = PluginRegistry.init(allocator);
    defer registry.deinit();

    // Register a completion provider
    try registry.registerCompletion("plugin_manager", "plugin:", example_plugins.pluginCompletion);

    // Verify completion was registered
    try std.testing.expectEqual(@as(usize, 1), registry.completions.items.len);

    const completion = registry.completions.items[0];
    try std.testing.expectEqualStrings("plugin_manager", completion.plugin_name);
    try std.testing.expectEqualStrings("plugin:", completion.prefix);
    try std.testing.expect(completion.enabled);
}

test "PluginRegistry - get completions" {
    const allocator = std.testing.allocator;

    var registry = PluginRegistry.init(allocator);
    defer registry.deinit();

    // Register completion provider
    try registry.registerCompletion("plugin_manager", "plugin:", example_plugins.pluginCompletion);

    // Get completions for matching prefix
    const completions = try registry.getCompletions("plugin:");
    defer {
        for (completions) |completion| {
            allocator.free(completion);
        }
        allocator.free(completions);
    }

    // Should get all plugin: suggestions
    try std.testing.expect(completions.len > 0);

    // Verify at least one expected completion
    var found_list = false;
    for (completions) |completion| {
        if (std.mem.eql(u8, completion, "plugin:list")) {
            found_list = true;
        }
    }
    try std.testing.expect(found_list);
}

test "PluginRegistry - get completions with no match" {
    const allocator = std.testing.allocator;

    var registry = PluginRegistry.init(allocator);
    defer registry.deinit();

    // Register completion provider for "plugin:"
    try registry.registerCompletion("plugin_manager", "plugin:", example_plugins.pluginCompletion);

    // Get completions for non-matching prefix
    const completions = try registry.getCompletions("command:");
    defer allocator.free(completions);

    // Should get no completions
    try std.testing.expectEqual(@as(usize, 0), completions.len);
}

test "PluginRegistry - unregister completions" {
    const allocator = std.testing.allocator;

    var registry = PluginRegistry.init(allocator);
    defer registry.deinit();

    // Register completions from multiple plugins
    try registry.registerCompletion("plugin_a", "plugin:", example_plugins.pluginCompletion);
    try registry.registerCompletion("plugin_b", "cmd:", example_plugins.pluginCompletion);

    try std.testing.expectEqual(@as(usize, 2), registry.completions.items.len);

    // Unregister plugin_a completions
    registry.unregisterCompletions("plugin_a");

    // Only plugin_b completion should remain
    try std.testing.expectEqual(@as(usize, 1), registry.completions.items.len);
    try std.testing.expectEqualStrings("plugin_b", registry.completions.items[0].plugin_name);
}

test "HookContext - getCommand" {
    const allocator = std.testing.allocator;

    const cmd = try allocator.dupe(u8, "test command");
    defer allocator.free(cmd);
    var cmd_ptr = cmd;
    var context = HookContext{
        .hook_type = .pre_command,
        .data = @ptrCast(@alignCast(&cmd_ptr)),
        .user_data = null,
        .allocator = allocator,
    };

    const retrieved_cmd = context.getCommand();
    try std.testing.expect(retrieved_cmd != null);
    try std.testing.expectEqualStrings("test command", retrieved_cmd.?);
}

test "HookContext - user data" {
    const allocator = std.testing.allocator;

    var user_value: i32 = 42;

    var context = HookContext{
        .hook_type = .shell_init,
        .data = null,
        .user_data = null,
        .allocator = allocator,
    };

    // Set user data
    context.setUserData(@ptrCast(&user_value));

    // Get user data
    const retrieved = context.getUserData();
    try std.testing.expect(retrieved != null);

    const value_ptr: *i32 = @ptrCast(@alignCast(retrieved.?));
    try std.testing.expectEqual(@as(i32, 42), value_ptr.*);
}

test "PluginCommand - execute when disabled" {
    const allocator = std.testing.allocator;

    var cmd = interface_mod.PluginCommand{
        .name = try allocator.dupe(u8, "add"),
        .plugin_name = try allocator.dupe(u8, "math"),
        .description = try allocator.dupe(u8, "Add numbers"),
        .function = example_plugins.mathAdd,
        .enabled = false,
        .allocator = allocator,
    };
    defer cmd.deinit();

    const args = [_][]const u8{ "1", "2" };
    const result = cmd.execute(&args);
    try std.testing.expectError(error.CommandDisabled, result);
}

test "CompletionProvider - disabled provider" {
    const allocator = std.testing.allocator;

    var provider = interface_mod.CompletionProvider{
        .plugin_name = try allocator.dupe(u8, "test"),
        .prefix = try allocator.dupe(u8, "plugin:"),
        .function = example_plugins.pluginCompletion,
        .enabled = false,
        .allocator = allocator,
    };
    defer provider.deinit();

    const completions = try provider.getCompletions("plugin:", allocator);
    defer allocator.free(completions);

    // Disabled provider returns empty array
    try std.testing.expectEqual(@as(usize, 0), completions.len);
}
