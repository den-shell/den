const std = @import("std");
const api_mod = @import("api.zig");
const interface_mod = @import("interface.zig");

const PluginAPI = api_mod.PluginAPI;
const Logger = api_mod.Logger;
const PluginContext = api_mod.PluginContext;
const LogLevel = api_mod.LogLevel;
const PluginRegistry = interface_mod.PluginRegistry;
const HookContext = interface_mod.HookContext;

// Test hook function
fn testHook(ctx: *HookContext) !void {
    _ = ctx;
}

// Test command function
fn testCommand(args: []const []const u8) !i32 {
    _ = args;
    return 0;
}

// Test completion function
fn testCompletion(input: []const u8, allocator: std.mem.Allocator) ![][]const u8 {
    _ = input;
    return try allocator.alloc([]const u8, 0);
}

test "PluginAPI - initialization" {
    const allocator = std.testing.allocator;

    var registry = PluginRegistry.init(allocator);
    defer registry.deinit();

    var plugin_api = try PluginAPI.init(allocator, "test-plugin", &registry);
    defer plugin_api.deinit();

    try std.testing.expectEqualStrings("test-plugin", plugin_api.plugin_name);
}

test "PluginAPI - register hook" {
    const allocator = std.testing.allocator;

    var registry = PluginRegistry.init(allocator);
    defer registry.deinit();

    var plugin_api = try PluginAPI.init(allocator, "test-plugin", &registry);
    defer plugin_api.deinit();

    try plugin_api.registerHook(.pre_command, testHook, 0);

    const index = @backingInt(interface_mod.HookType.pre_command);
    try std.testing.expectEqual(@as(usize, 1), registry.hooks[index].items.len);
}

test "PluginAPI - unregister hooks" {
    const allocator = std.testing.allocator;

    var registry = PluginRegistry.init(allocator);
    defer registry.deinit();

    var plugin_api = try PluginAPI.init(allocator, "test-plugin", &registry);
    defer plugin_api.deinit();

    try plugin_api.registerHook(.pre_command, testHook, 0);
    try plugin_api.registerHook(.post_command, testHook, 0);

    plugin_api.unregisterHooks();

    const pre_index = @backingInt(interface_mod.HookType.pre_command);
    const post_index = @backingInt(interface_mod.HookType.post_command);
    try std.testing.expectEqual(@as(usize, 0), registry.hooks[pre_index].items.len);
    try std.testing.expectEqual(@as(usize, 0), registry.hooks[post_index].items.len);
}

test "PluginAPI - register command" {
    const allocator = std.testing.allocator;

    var registry = PluginRegistry.init(allocator);
    defer registry.deinit();

    var plugin_api = try PluginAPI.init(allocator, "test-plugin", &registry);
    defer plugin_api.deinit();

    try plugin_api.registerCommand("hello", "Say hello", testCommand);

    const cmd = registry.getCommand("hello");
    try std.testing.expect(cmd != null);
    try std.testing.expectEqualStrings("test-plugin", cmd.?.plugin_name);
}

test "PluginAPI - unregister commands" {
    const allocator = std.testing.allocator;

    var registry = PluginRegistry.init(allocator);
    defer registry.deinit();

    var plugin_api = try PluginAPI.init(allocator, "test-plugin", &registry);
    defer plugin_api.deinit();

    try plugin_api.registerCommand("cmd1", "Command 1", testCommand);
    try plugin_api.registerCommand("cmd2", "Command 2", testCommand);

    try std.testing.expectEqual(@as(usize, 2), registry.commands.count());

    plugin_api.unregisterCommands();

    try std.testing.expectEqual(@as(usize, 0), registry.commands.count());
}

test "PluginAPI - register completion" {
    const allocator = std.testing.allocator;

    var registry = PluginRegistry.init(allocator);
    defer registry.deinit();

    var plugin_api = try PluginAPI.init(allocator, "test-plugin", &registry);
    defer plugin_api.deinit();

    try plugin_api.registerCompletion("test:", testCompletion);

    try std.testing.expectEqual(@as(usize, 1), registry.completions.items.len);
    try std.testing.expectEqualStrings("test-plugin", registry.completions.items[0].plugin_name);
}

test "PluginAPI - unregister completions" {
    const allocator = std.testing.allocator;

    var registry = PluginRegistry.init(allocator);
    defer registry.deinit();

    var plugin_api = try PluginAPI.init(allocator, "test-plugin", &registry);
    defer plugin_api.deinit();

    try plugin_api.registerCompletion("test:", testCompletion);

    try std.testing.expectEqual(@as(usize, 1), registry.completions.items.len);

    plugin_api.unregisterCompletions();

    try std.testing.expectEqual(@as(usize, 0), registry.completions.items.len);
}

test "PluginAPI - configuration get/set" {
    const allocator = std.testing.allocator;

    var registry = PluginRegistry.init(allocator);
    defer registry.deinit();

    var plugin_api = try PluginAPI.init(allocator, "test-plugin", &registry);
    defer plugin_api.deinit();

    try plugin_api.setConfig("key1", "value1");
    try plugin_api.setConfig("key2", "value2");

    const value1 = plugin_api.getConfig("key1");
    const value2 = plugin_api.getConfig("key2");
    const value3 = plugin_api.getConfig("key3");

    try std.testing.expect(value1 != null);
    try std.testing.expect(value2 != null);
    try std.testing.expect(value3 == null);

    try std.testing.expectEqualStrings("value1", value1.?);
    try std.testing.expectEqualStrings("value2", value2.?);
}

test "PluginAPI - configuration getOr" {
    const allocator = std.testing.allocator;

    var registry = PluginRegistry.init(allocator);
    defer registry.deinit();

    var plugin_api = try PluginAPI.init(allocator, "test-plugin", &registry);
    defer plugin_api.deinit();

    try plugin_api.setConfig("exists", "value");

    const value1 = plugin_api.getConfigOr("exists", "default");
    const value2 = plugin_api.getConfigOr("missing", "default");

    try std.testing.expectEqualStrings("value", value1);
    try std.testing.expectEqualStrings("default", value2);
}

test "PluginAPI - configuration hasConfig" {
    const allocator = std.testing.allocator;

    var registry = PluginRegistry.init(allocator);
    defer registry.deinit();

    var plugin_api = try PluginAPI.init(allocator, "test-plugin", &registry);
    defer plugin_api.deinit();

    try plugin_api.setConfig("exists", "value");

    try std.testing.expect(plugin_api.hasConfig("exists"));
    try std.testing.expect(!plugin_api.hasConfig("missing"));
}

test "PluginAPI - configuration update" {
    const allocator = std.testing.allocator;

    var registry = PluginRegistry.init(allocator);
    defer registry.deinit();

    var plugin_api = try PluginAPI.init(allocator, "test-plugin", &registry);
    defer plugin_api.deinit();

    try plugin_api.setConfig("key", "value1");
    const value1 = plugin_api.getConfig("key");
    try std.testing.expectEqualStrings("value1", value1.?);

    try plugin_api.setConfig("key", "value2");
    const value2 = plugin_api.getConfig("key");
    try std.testing.expectEqualStrings("value2", value2.?);
}

test "PluginAPI - utility splitString" {
    const allocator = std.testing.allocator;

    var registry = PluginRegistry.init(allocator);
    defer registry.deinit();

    var plugin_api = try PluginAPI.init(allocator, "test-plugin", &registry);
    defer plugin_api.deinit();

    const parts = try plugin_api.splitString("one:two:three", ':');
    defer {
        for (parts) |part| {
            allocator.free(part);
        }
        allocator.free(parts);
    }

    try std.testing.expectEqual(@as(usize, 3), parts.len);
    try std.testing.expectEqualStrings("one", parts[0]);
    try std.testing.expectEqualStrings("two", parts[1]);
    try std.testing.expectEqualStrings("three", parts[2]);
}

test "PluginAPI - utility joinStrings" {
    const allocator = std.testing.allocator;

    var registry = PluginRegistry.init(allocator);
    defer registry.deinit();

    var plugin_api = try PluginAPI.init(allocator, "test-plugin", &registry);
    defer plugin_api.deinit();

    const parts = [_][]const u8{ "one", "two", "three" };
    const joined = try plugin_api.joinStrings(&parts, ", ");
    defer allocator.free(joined);

    try std.testing.expectEqualStrings("one, two, three", joined);
}

test "PluginAPI - utility trimString" {
    const allocator = std.testing.allocator;

    var registry = PluginRegistry.init(allocator);
    defer registry.deinit();

    var plugin_api = try PluginAPI.init(allocator, "test-plugin", &registry);
    defer plugin_api.deinit();

    const trimmed = try plugin_api.trimString("  hello world  ");
    defer allocator.free(trimmed);

    try std.testing.expectEqualStrings("hello world", trimmed);
}

test "PluginAPI - utility startsWith" {
    const allocator = std.testing.allocator;

    var registry = PluginRegistry.init(allocator);
    defer registry.deinit();

    var plugin_api = try PluginAPI.init(allocator, "test-plugin", &registry);
    defer plugin_api.deinit();

    try std.testing.expect(plugin_api.startsWith("hello world", "hello"));
    try std.testing.expect(!plugin_api.startsWith("hello world", "world"));
}

test "PluginAPI - utility endsWith" {
    const allocator = std.testing.allocator;

    var registry = PluginRegistry.init(allocator);
    defer registry.deinit();

    var plugin_api = try PluginAPI.init(allocator, "test-plugin", &registry);
    defer plugin_api.deinit();

    try std.testing.expect(plugin_api.endsWith("hello world", "world"));
    try std.testing.expect(!plugin_api.endsWith("hello world", "hello"));
}

test "PluginAPI - utility timestamp" {
    const allocator = std.testing.allocator;

    var registry = PluginRegistry.init(allocator);
    defer registry.deinit();

    var plugin_api = try PluginAPI.init(allocator, "test-plugin", &registry);
    defer plugin_api.deinit();

    const ts1 = plugin_api.timestamp();
    const ts2 = plugin_api.timestamp();

    try std.testing.expect(ts2 >= ts1);
}

test "PluginContext - convenience methods" {
    const allocator = std.testing.allocator;

    var registry = PluginRegistry.init(allocator);
    defer registry.deinit();

    var plugin_api = try PluginAPI.init(allocator, "test-plugin", &registry);
    defer plugin_api.deinit();

    const ctx = PluginContext.init(&plugin_api);

    try std.testing.expectEqualStrings("test-plugin", ctx.getName());
    try std.testing.expectEqual(allocator, ctx.getAllocator());

    try ctx.hook(.pre_command, testHook, 0);
    try ctx.command("test", "Test command", testCommand);
    try ctx.completion("test:", testCompletion);

    const index = @backingInt(interface_mod.HookType.pre_command);
    try std.testing.expectEqual(@as(usize, 1), registry.hooks[index].items.len);
    try std.testing.expectEqual(@as(usize, 1), registry.commands.count());
    try std.testing.expectEqual(@as(usize, 1), registry.completions.items.len);
}

test "Logger - log levels" {
    const allocator = std.testing.allocator;

    var logger = Logger.init(allocator, "test");

    // Set minimum level to warn
    logger.setMinLevel(.warn);

    // These should not produce output (tested by no crash)
    try logger.log(.debug, "Debug message", .{});
    try logger.log(.info, "Info message", .{});

    // These should produce output
    try logger.log(.warn, "Warning message", .{});
    try logger.log(.err, "Error message", .{});
}
