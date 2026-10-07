const std = @import("std");
const types = @import("types.zig");
const placeholders_mod = @import("placeholders.zig");
const renderer_mod = @import("renderer.zig");
const sysinfo_mod = @import("sysinfo.zig");

const PromptContext = types.PromptContext;
const PromptTemplate = types.PromptTemplate;
const PlaceholderRegistry = placeholders_mod.PlaceholderRegistry;
const PromptRenderer = renderer_mod.PromptRenderer;
const SystemInfo = sysinfo_mod.SystemInfo;

test "PromptContext - initialization" {
    const allocator = std.testing.allocator;
    var ctx = PromptContext.init(allocator);
    defer ctx.deinit();

    try std.testing.expectEqual(@as(i32, 0), ctx.last_exit_code);
    try std.testing.expect(ctx.git_branch == null);
}

test "PromptContext - custom data" {
    const allocator = std.testing.allocator;
    var ctx = PromptContext.init(allocator);
    defer ctx.deinit();

    try ctx.setCustom("test_key", "test_value");

    const value = ctx.getCustom("test_key");
    try std.testing.expect(value != null);
    try std.testing.expectEqualStrings("test_value", value.?);
}

test "PlaceholderRegistry - initialization" {
    const allocator = std.testing.allocator;
    var registry = PlaceholderRegistry.init(allocator);
    defer registry.deinit();

    try registry.registerStandard();
}

test "PlaceholderRegistry - expand user" {
    const allocator = std.testing.allocator;
    var registry = PlaceholderRegistry.init(allocator);
    defer registry.deinit();

    try registry.registerStandard();

    var ctx = PromptContext.init(allocator);
    defer ctx.deinit();
    ctx.username = try allocator.dupe(u8, "testuser");

    const result = try registry.expand("user", &ctx);
    try std.testing.expect(result != null);
    defer if (result) |r| allocator.free(r);

    try std.testing.expectEqualStrings("testuser", result.?);
}

test "PlaceholderRegistry - expand host" {
    const allocator = std.testing.allocator;
    var registry = PlaceholderRegistry.init(allocator);
    defer registry.deinit();

    try registry.registerStandard();

    var ctx = PromptContext.init(allocator);
    defer ctx.deinit();
    ctx.hostname = try allocator.dupe(u8, "localhost");

    const result = try registry.expand("host", &ctx);
    try std.testing.expect(result != null);
    defer if (result) |r| allocator.free(r);

    try std.testing.expectEqualStrings("localhost", result.?);
}

test "PlaceholderRegistry - expand symbol (success)" {
    const allocator = std.testing.allocator;
    var registry = PlaceholderRegistry.init(allocator);
    defer registry.deinit();

    try registry.registerStandard();

    var ctx = PromptContext.init(allocator);
    defer ctx.deinit();
    ctx.last_exit_code = 0;
    ctx.is_root = false;

    const result = try registry.expand("symbol", &ctx);
    try std.testing.expect(result != null);
    defer if (result) |r| allocator.free(r);

    // expandSymbol renders the configured symbol in bold green on success.
    try std.testing.expectEqualStrings("\x1b[1;32m\xE2\x9E\x9C\x1b[0m ", result.?);
}

test "PlaceholderRegistry - expand symbol (error)" {
    const allocator = std.testing.allocator;
    var registry = PlaceholderRegistry.init(allocator);
    defer registry.deinit();

    try registry.registerStandard();

    var ctx = PromptContext.init(allocator);
    defer ctx.deinit();
    ctx.last_exit_code = 1;
    ctx.is_root = false;

    const result = try registry.expand("symbol", &ctx);
    try std.testing.expect(result != null);
    defer if (result) |r| allocator.free(r);

    // Same symbol, bold red, when the previous command failed.
    try std.testing.expectEqualStrings("\x1b[1;31m\xE2\x9E\x9C\x1b[0m ", result.?);
}

test "PlaceholderRegistry - expand symbol (root)" {
    const allocator = std.testing.allocator;
    var registry = PlaceholderRegistry.init(allocator);
    defer registry.deinit();

    try registry.registerStandard();

    var ctx = PromptContext.init(allocator);
    defer ctx.deinit();
    ctx.is_root = true;

    const result = try registry.expand("symbol", &ctx);
    try std.testing.expect(result != null);
    defer if (result) |r| allocator.free(r);

    // Root gets a red # instead of the configured symbol.
    try std.testing.expectEqualStrings("\x1b[91m#\x1b[0m ", result.?);
}

test "PlaceholderRegistry - expand git (no branch)" {
    const allocator = std.testing.allocator;
    var registry = PlaceholderRegistry.init(allocator);
    defer registry.deinit();

    try registry.registerStandard();

    var ctx = PromptContext.init(allocator);
    defer ctx.deinit();

    const result = try registry.expand("git", &ctx);
    try std.testing.expect(result != null);
    defer if (result) |r| allocator.free(r);

    try std.testing.expectEqualStrings("", result.?);
}

test "PlaceholderRegistry - expand git (with branch)" {
    const allocator = std.testing.allocator;
    var registry = PlaceholderRegistry.init(allocator);
    defer registry.deinit();

    try registry.registerStandard();

    var ctx = PromptContext.init(allocator);
    defer ctx.deinit();
    ctx.git_branch = try allocator.dupe(u8, "main");
    ctx.git_dirty = false;

    const result = try registry.expand("git", &ctx);
    try std.testing.expect(result != null);
    defer if (result) |r| allocator.free(r);

    // git_style defaults to .compact: " git:(main)" with bold-blue braces and
    // a red branch name. A clean tree adds no status markers.
    try std.testing.expectEqualStrings(" \x1b[1;34mgit:(\x1b[0;31mmain\x1b[34m)\x1b[0m", result.?);
}

test "PlaceholderRegistry - expand git (dirty)" {
    const allocator = std.testing.allocator;
    var registry = PlaceholderRegistry.init(allocator);
    defer registry.deinit();

    try registry.registerStandard();

    var ctx = PromptContext.init(allocator);
    defer ctx.deinit();
    ctx.git_branch = try allocator.dupe(u8, "main");
    ctx.git_dirty = true;

    const result = try registry.expand("git", &ctx);
    try std.testing.expect(result != null);
    defer if (result) |r| allocator.free(r);

    // With no counters set, a dirty tree is flagged with a bare yellow ✗.
    try std.testing.expect(std.mem.indexOf(u8, result.?, "\xE2\x9C\x97") != null);
}

test "PlaceholderRegistry - expand exitcode" {
    const allocator = std.testing.allocator;
    var registry = PlaceholderRegistry.init(allocator);
    defer registry.deinit();

    try registry.registerStandard();

    var ctx = PromptContext.init(allocator);
    defer ctx.deinit();
    ctx.last_exit_code = 127;

    const result = try registry.expand("exitcode", &ctx);
    try std.testing.expect(result != null);
    defer if (result) |r| allocator.free(r);

    try std.testing.expectEqualStrings("[127]", result.?);
}

test "PlaceholderRegistry - expand duration" {
    const allocator = std.testing.allocator;
    var registry = PlaceholderRegistry.init(allocator);
    defer registry.deinit();

    try registry.registerStandard();

    var ctx = PromptContext.init(allocator);
    defer ctx.deinit();
    ctx.last_duration_ms = 500;

    const result = try registry.expand("duration", &ctx);
    try std.testing.expect(result != null);
    defer if (result) |r| allocator.free(r);

    try std.testing.expectEqualStrings("500ms", result.?);
}

test "PromptTemplate - initDefault" {
    const allocator = std.testing.allocator;
    const template = try PromptTemplate.initDefault(allocator);
    var template_mut = template;
    defer template_mut.deinit(allocator);

    try std.testing.expect(template.left_format.len > 0);
}

test "PromptRenderer - initialization" {
    const allocator = std.testing.allocator;
    const template = try PromptTemplate.initDefault(allocator);
    // No `template.deinit` here: PromptRenderer.init takes the template by
    // value and its deinit frees it, so freeing a copy as well is a double free.
    var renderer = try PromptRenderer.init(allocator, template);
    defer renderer.deinit();
}

test "PromptRenderer - render simple" {
    const allocator = std.testing.allocator;
    const template = try PromptTemplate.initSimple(allocator);
    // No `template.deinit` here: PromptRenderer.init takes the template by
    // value and its deinit frees it, so freeing a copy as well is a double free.
    var renderer = try PromptRenderer.init(allocator, template);
    defer renderer.deinit();

    var ctx = PromptContext.init(allocator);
    defer ctx.deinit();
    ctx.last_exit_code = 0;

    const result = try renderer.render(&ctx, 80);
    defer allocator.free(result);

    try std.testing.expect(result.len > 0);
}

test "PromptRenderer - expand template" {
    const allocator = std.testing.allocator;
    const template = try PromptTemplate.initDefault(allocator);
    // No `template.deinit` here: PromptRenderer.init takes the template by
    // value and its deinit frees it, so freeing a copy as well is a double free.
    var renderer = try PromptRenderer.init(allocator, template);
    defer renderer.deinit();

    var ctx = PromptContext.init(allocator);
    defer ctx.deinit();
    ctx.username = try allocator.dupe(u8, "test");
    ctx.hostname = try allocator.dupe(u8, "localhost");
    ctx.current_dir = try allocator.dupe(u8, "/home/test");

    const result = try renderer.render(&ctx, 80);
    defer allocator.free(result);

    // The default left_format is {symbol}{path}{git}{pkg}{runtimes}{battery} --
    // it has no {host} or {user}, so only the path reaches the output.
    try std.testing.expect(std.mem.indexOf(u8, result, "/home/test") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "localhost") == null);
}

test "PromptRenderer - visible width" {
    const text = "\x1b[31mHello\x1b[0m World";
    const width = renderer_mod.visibleWidth(text);

    try std.testing.expectEqual(@as(usize, 11), width); // "Hello World"
}

test "SystemInfo - getUsername" {
    const allocator = std.testing.allocator;
    var sysinfo = SystemInfo.init(allocator);

    const username = try sysinfo.getUsername();
    defer allocator.free(username);

    try std.testing.expect(username.len > 0);
}

test "SystemInfo - getHostname" {
    const allocator = std.testing.allocator;
    var sysinfo = SystemInfo.init(allocator);

    const hostname = try sysinfo.getHostname();
    defer allocator.free(hostname);

    try std.testing.expect(hostname.len > 0);
}

test "SystemInfo - getCurrentDir" {
    const allocator = std.testing.allocator;
    var sysinfo = SystemInfo.init(allocator);

    const cwd = try sysinfo.getCurrentDir();
    defer allocator.free(cwd);

    try std.testing.expect(cwd.len > 0);
}

test "SystemInfo - abbreviatePath" {
    const allocator = std.testing.allocator;
    var sysinfo = SystemInfo.init(allocator);

    const home = try sysinfo.getHomeDir() orelse return;
    defer allocator.free(home);

    const test_path = try std.fmt.allocPrint(allocator, "{s}/projects", .{home});
    defer allocator.free(test_path);

    const abbreviated = try sysinfo.abbreviatePath(test_path);
    defer allocator.free(abbreviated);

    try std.testing.expect(std.mem.startsWith(u8, abbreviated, "~"));
}

test "SystemInfo - basename" {
    const allocator = std.testing.allocator;
    var sysinfo = SystemInfo.init(allocator);

    const base = try sysinfo.basename("/usr/local/bin");
    defer allocator.free(base);

    try std.testing.expectEqualStrings("bin", base);
}

test "SystemInfo - dirname" {
    const allocator = std.testing.allocator;
    var sysinfo = SystemInfo.init(allocator);

    const dir = try sysinfo.dirname("/usr/local/bin");
    defer if (dir) |d| allocator.free(d);

    try std.testing.expect(dir != null);
    try std.testing.expectEqualStrings("/usr/local", dir.?);
}
