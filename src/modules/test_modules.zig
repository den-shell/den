const std = @import("std");
const types = @import("types.zig");
const registry_mod = @import("registry.zig");
const languages = @import("languages.zig");

const ModuleInfo = types.ModuleInfo;
const ModuleConfig = types.ModuleConfig;
const ModuleRegistry = registry_mod.ModuleRegistry;

test "ModuleInfo - initialization" {
    const allocator = std.testing.allocator;

    var info = ModuleInfo.init("test");
    defer info.deinit(allocator);

    try std.testing.expectEqualStrings("test", info.name);
    try std.testing.expect(info.version == null);
    try std.testing.expect(info.enabled);
}

test "ModuleConfig - default initialization" {
    const config = ModuleConfig.initDefault();

    try std.testing.expect(config.enabled);
    try std.testing.expect(config.show_version);
    try std.testing.expect(config.icon == null);
    try std.testing.expect(config.color == null);
}

test "ModuleRegistry - initialization" {
    const allocator = std.testing.allocator;
    var registry = ModuleRegistry.init(allocator);
    defer registry.deinit();

    try std.testing.expectEqual(@as(usize, 0), registry.detectors.count());
}

test "ModuleRegistry - register detector" {
    const allocator = std.testing.allocator;
    var registry = ModuleRegistry.init(allocator);
    defer registry.deinit();

    const TestDetector = struct {
        fn detect(alloc: std.mem.Allocator, _: []const u8) !?ModuleInfo {
            var info = ModuleInfo.init("test");
            info.version = try alloc.dupe(u8, "1.0.0");
            return info;
        }
    };

    try registry.register("test", TestDetector.detect);
    try std.testing.expectEqual(@as(usize, 1), registry.detectors.count());
}

test "ModuleRegistry - configure module" {
    const allocator = std.testing.allocator;
    var registry = ModuleRegistry.init(allocator);
    defer registry.deinit();

    var config = ModuleConfig.initDefault();
    config.enabled = false;

    try registry.configure("test", config);

    const stored = registry.configs.get("test");
    try std.testing.expect(stored != null);
    try std.testing.expect(!stored.?.enabled);
}

test "ModuleRegistry - enable/disable module" {
    const allocator = std.testing.allocator;
    var registry = ModuleRegistry.init(allocator);
    defer registry.deinit();

    try registry.setEnabled("test", false);

    const config = registry.configs.get("test");
    try std.testing.expect(config != null);
    try std.testing.expect(!config.?.enabled);
}

test "ModuleRegistry - detect with caching" {
    const allocator = std.testing.allocator;
    var registry = ModuleRegistry.init(allocator);
    defer registry.deinit();

    const TestDetector = struct {
        fn detect(alloc: std.mem.Allocator, _: []const u8) !?ModuleInfo {
            var info = ModuleInfo.init("test");
            info.version = try alloc.dupe(u8, "1.0.0");
            return info;
        }
    };

    try registry.register("test", TestDetector.detect);

    // First detection
    const info1 = try registry.detect("test", "/tmp");
    try std.testing.expect(info1 != null);
    defer if (info1) |*i| i.deinit(allocator);

    try std.testing.expectEqualStrings("1.0.0", info1.?.version.?);

    // Should be cached
    try std.testing.expectEqual(@as(usize, 1), registry.cache.count());
}

test "ModuleRegistry - clear cache" {
    const allocator = std.testing.allocator;
    var registry = ModuleRegistry.init(allocator);
    defer registry.deinit();

    const TestDetector = struct {
        fn detect(alloc: std.mem.Allocator, _: []const u8) !?ModuleInfo {
            var info = ModuleInfo.init("test");
            info.version = try alloc.dupe(u8, "1.0.0");
            return info;
        }
    };

    try registry.register("test", TestDetector.detect);

    const info = try registry.detect("test", "/tmp");
    defer if (info) |*i| i.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), registry.cache.count());

    registry.clearCache();
    try std.testing.expectEqual(@as(usize, 0), registry.cache.count());
}

test "ModuleRegistry - render module" {
    const allocator = std.testing.allocator;
    var registry = ModuleRegistry.init(allocator);
    defer registry.deinit();

    var info = ModuleInfo.init("test");
    info.icon = "🧪";
    info.version = try allocator.dupe(u8, "1.0.0");
    defer info.deinit(allocator);

    const rendered = try registry.render(&info, null);
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "🧪") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "1.0.0") != null);
}

test "ModuleRegistry - disabled module returns null" {
    const allocator = std.testing.allocator;
    var registry = ModuleRegistry.init(allocator);
    defer registry.deinit();

    const TestDetector = struct {
        fn detect(alloc: std.mem.Allocator, _: []const u8) !?ModuleInfo {
            var info = ModuleInfo.init("test");
            info.version = try alloc.dupe(u8, "1.0.0");
            return info;
        }
    };

    try registry.register("test", TestDetector.detect);
    try registry.setEnabled("test", false);

    const info = try registry.detect("test", "/tmp");
    try std.testing.expect(info == null);
}

test "languages - parseVersion extracts version number" {
    const allocator = std.testing.allocator;

    // Test various version formats
    const test_cases = [_]struct {
        input: []const u8,
        expected: []const u8,
    }{
        .{ .input = "1.2.3", .expected = "1.2.3" },
        .{ .input = "v1.2.3", .expected = "1.2.3" },
        .{ .input = "node v18.17.0", .expected = "18.17.0" },
        .{ .input = "go version go1.21.0 darwin/arm64", .expected = "1.21.0" },
        .{ .input = "rustc 1.72.0 (5680fa18f 2023-08-23)", .expected = "1.72.0" },
    };

    for (test_cases) |tc| {
        const version = try languages.parseVersion(allocator, tc.input);
        defer allocator.free(version);
        try std.testing.expectEqualStrings(tc.expected, version);
    }
}

test "LanguageModule - constants defined" {
    try std.testing.expectEqualStrings("bun", types.LanguageModule.Bun.name);
    try std.testing.expectEqualStrings("node", types.LanguageModule.Node.name);
    try std.testing.expectEqualStrings("python", types.LanguageModule.Python.name);
    try std.testing.expectEqualStrings("go", types.LanguageModule.Go.name);
    try std.testing.expectEqualStrings("zig", types.LanguageModule.Zig.name);
    try std.testing.expectEqualStrings("rust", types.LanguageModule.Rust.name);
    try std.testing.expectEqualStrings("java", types.LanguageModule.Java.name);
    try std.testing.expectEqualStrings("ruby", types.LanguageModule.Ruby.name);
    try std.testing.expectEqualStrings("php", types.LanguageModule.PHP.name);
}

test "LanguageModule - icons defined" {
    try std.testing.expectEqualStrings("🐰", types.LanguageModule.Bun.icon);
    try std.testing.expectEqualStrings("⬢", types.LanguageModule.Node.icon);
    try std.testing.expectEqualStrings("🐍", types.LanguageModule.Python.icon);
    try std.testing.expectEqualStrings("🐹", types.LanguageModule.Go.icon);
    try std.testing.expectEqualStrings("⚡", types.LanguageModule.Zig.icon);
    try std.testing.expectEqualStrings("🦀", types.LanguageModule.Rust.icon);
    try std.testing.expectEqualStrings("☕", types.LanguageModule.Java.icon);
    try std.testing.expectEqualStrings("💎", types.LanguageModule.Ruby.icon);
    try std.testing.expectEqualStrings("🐘", types.LanguageModule.PHP.icon);
}

test "CloudProvider - constants defined" {
    try std.testing.expectEqualStrings("aws", types.CloudProvider.AWS.name);
    try std.testing.expectEqualStrings("azure", types.CloudProvider.Azure.name);
    try std.testing.expectEqualStrings("gcp", types.CloudProvider.GCP.name);
}

test "CloudContext - initialization" {
    const allocator = std.testing.allocator;

    var ctx = types.CloudContext.init(allocator, "aws", "☁️");
    defer ctx.deinit();

    try std.testing.expectEqualStrings("aws", ctx.provider);
    try std.testing.expectEqualStrings("☁️", ctx.icon);
    try std.testing.expect(ctx.profile == null);
    try std.testing.expect(ctx.region == null);
}
