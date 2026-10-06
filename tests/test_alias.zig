const std = @import("std");
const test_utils = @import("test_utils.zig");

// ============================================================================
// Alias Tests
// Tests for shell alias functionality
// ============================================================================

test "alias: create simple alias" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("alias greet='echo hello'; greet");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "hello");
}

test "alias: alias with arguments" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("alias myecho='echo'; myecho world");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "world");
}

test "alias: list all aliases" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("alias foo='bar' && alias baz='qux' && alias");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "foo");
    try test_utils.TestAssert.expectContains(result.stdout, "baz");
}

test "alias: show specific alias" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("alias myalias='ls -la' && alias myalias");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "ls");
}

test "alias: overwrite existing alias" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("alias greeting='echo first'; alias greeting='echo second'; greeting");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "second");
}

test "alias: alias with flags" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("alias ll='ls -la'; ll /tmp");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should execute ls -la on /tmp
    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
}

test "alias: alias with pipe" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("alias countlines='wc -l'; printf 'a\\nb\\nc\\n' | countlines");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
}

test "unalias: remove alias" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("alias mytest='echo test'; unalias mytest; alias");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    // mytest should not appear in alias list
}

test "unalias: remove nonexistent alias" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("unalias nonexistent_alias_12345");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should fail gracefully
    try test_utils.TestAssert.expectTrue(result.exit_code != 0);
}

test "unalias: remove all aliases with -a" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("alias a='1' && alias b='2' && unalias -a && alias");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    // Should have no aliases
}

test "alias: chained aliases" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    // First alias works, second alias should not expand first
    const result = try fixture.exec("alias first='echo first'; alias second='first'; second");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Depending on shell behavior, this tests alias expansion
    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
}

test "alias: alias with special characters in value" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("alias special='echo \"hello world\"'; special");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "hello world");
}

test "alias: alias not expanded in quoted strings" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("alias myalias='expanded'; echo 'myalias'");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // The literal 'myalias' should be printed, not 'expanded'
    try test_utils.TestAssert.expectContains(result.stdout, "myalias");
}

test "alias: an alias defined in the same list is not expanded" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    // The list is parsed before the alias exists, so the name is still a plain
    // command here. zsh and bash behave the same way; this is why aliases go in
    // a startup file rather than being defined and used in one line.
    const result = try fixture.exec("alias samelist='echo expanded' && samelist");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectTrue(result.exit_code != 0);
    try test_utils.TestAssert.expectContains(result.stderr, "command not found");
}

test "alias: a chained alias keeps the argument order" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    // `a Z` -> `b X Z` -> `echo Y X Z`: each step of the chain prepends its own
    // arguments ahead of what is already there.
    const result = try fixture.exec("alias b='echo Y'; alias a='b X'; a Z");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "Y X Z");
}

test "alias: a self-referencing alias expands once" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    // The `alias ls='ls -la'` form: expansion stops when the first word of the
    // replacement is the alias itself, so the real command runs with the flags
    // rather than the chain being reported as circular.
    const result = try fixture.exec("alias ls='ls -d'; ls .");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectEqual(@as(?usize, null), std.mem.indexOf(u8, result.stderr, "circular"));
}

test "alias: a real cycle is reported, not followed forever" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("alias p='q'; alias q='p'; p");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stderr, "circular reference");
}
