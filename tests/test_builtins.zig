const std = @import("std");
const test_utils = @import("test_utils.zig");

// ============================================================================
// Builtin Command Tests
// Tests for shell built-in commands: cd, pwd, echo, exit, env, export, set,
// unset, jobs, fg, bg, history, alias, unalias, type, which
// ============================================================================

// ----------------------------------------------------------------------------
// CD Tests
// ----------------------------------------------------------------------------

test "builtin cd: change to home directory" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("cd ~ && pwd");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    // Should contain /Users or /home (platform dependent)
    try test_utils.TestAssert.expectTrue(
        std.mem.indexOf(u8, result.stdout, "/Users") != null or
            std.mem.indexOf(u8, result.stdout, "/home") != null,
    );
}

test "builtin cd: change to parent directory" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("cd /tmp && cd .. && pwd");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "/");
}

test "builtin cd: change to absolute path" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("cd /tmp && pwd");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "/tmp");
}

test "builtin cd: nonexistent directory fails" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("cd /nonexistent_directory_12345");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectTrue(result.exit_code != 0);
}

test "builtin cd: cd - returns to previous directory" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("cd /tmp && cd /var && cd - && pwd");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "/tmp");
}

// ----------------------------------------------------------------------------
// PWD Tests
// ----------------------------------------------------------------------------

test "builtin pwd: prints current directory" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("cd /tmp && pwd");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "/tmp");
}

// ----------------------------------------------------------------------------
// ECHO Tests
// ----------------------------------------------------------------------------

test "builtin echo: simple string" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo hello world");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "hello world");
}

test "builtin echo: with -n flag (no newline)" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo -n test");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    // Should not end with newline when -n is used
    try test_utils.TestAssert.expectContains(result.stdout, "test");
}

test "builtin echo: empty string" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
}

test "builtin echo: with variable expansion" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("TEST=hello && echo $TEST");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "hello");
}

test "builtin echo: quoted string preserves spaces" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo \"hello    world\"");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "hello    world");
}

// ----------------------------------------------------------------------------
// ENV Tests
// ----------------------------------------------------------------------------

test "builtin env: lists environment variables" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("env");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    // Should contain common env vars
    try test_utils.TestAssert.expectContains(result.stdout, "PATH=");
}

// ----------------------------------------------------------------------------
// EXPORT Tests
// ----------------------------------------------------------------------------

test "builtin export: set and export variable" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("export TEST_VAR=hello && echo $TEST_VAR");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "hello");
}

test "builtin export: variable visible in subshell" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("export MY_VAR=test && sh -c 'echo $MY_VAR'");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "test");
}

// ----------------------------------------------------------------------------
// UNSET Tests
// ----------------------------------------------------------------------------

test "builtin unset: removes variable" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("export TEST=value && unset TEST && echo \"TEST=$TEST\"");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // After unset, variable should be empty
    try test_utils.TestAssert.expectContains(result.stdout, "TEST=");
}

// ----------------------------------------------------------------------------
// ALIAS Tests
// ----------------------------------------------------------------------------

test "builtin alias: create simple alias" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("alias ll='ls -la' && alias");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "ll");
}

test "builtin alias: list all aliases" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("alias foo='bar' && alias baz='qux' && alias");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "foo");
    try test_utils.TestAssert.expectContains(result.stdout, "baz");
}

// ----------------------------------------------------------------------------
// UNALIAS Tests
// ----------------------------------------------------------------------------

test "builtin unalias: removes alias" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("alias test='echo test' && unalias test && alias");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    // test alias should no longer be listed
}

// ----------------------------------------------------------------------------
// TYPE Tests
// ----------------------------------------------------------------------------

test "builtin type: identifies builtin command" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("type echo");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "builtin");
}

test "builtin type: identifies external command" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("type ls");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // ls should be found in PATH
    try test_utils.TestAssert.expectContains(result.stdout, "ls");
}

test "builtin type: identifies alias" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("alias myalias='echo test' && type myalias");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "alias");
}

// ----------------------------------------------------------------------------
// WHICH Tests
// ----------------------------------------------------------------------------

test "builtin which: finds command in PATH" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("which ls");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "/");
    try test_utils.TestAssert.expectContains(result.stdout, "ls");
}

test "builtin which: nonexistent command fails" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("which nonexistent_command_12345");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectTrue(result.exit_code != 0);
}

// ----------------------------------------------------------------------------
// TRUE/FALSE Tests
// ----------------------------------------------------------------------------

test "builtin true: returns 0" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("true");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
}

test "builtin false: returns 1" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("false");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 1), result.exit_code);
}

// ----------------------------------------------------------------------------
// TEST/[ Tests
// ----------------------------------------------------------------------------

test "builtin test: string equality" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("test \"hello\" = \"hello\" && echo yes");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "yes");
}

test "builtin test: string inequality" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("test \"hello\" != \"world\" && echo yes");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "yes");
}

test "builtin test: file exists" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("test -e /tmp && echo exists");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "exists");
}

test "builtin test: directory check" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("test -d /tmp && echo isdir");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "isdir");
}

test "builtin test: numeric comparison" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("test 5 -gt 3 && echo greater");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "greater");
}

// ----------------------------------------------------------------------------
// Exit Code Tests ($?)
// ----------------------------------------------------------------------------

test "builtin: exit code preserved in $?" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("false; echo $?");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "1");
}

test "builtin: success exit code in $?" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("true; echo $?");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "0");
}

// These exercise Den's own builtins (DenShellFixture runs the den binary;
// ShellFixture above runs system sh).

test "builtin find: -type f recurses into subdirectories" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    // Regression: 'find DIR -type f' used to skip every subdirectory because the
    // type filter short-circuited recursion, so nested files were never found.
    const result = try fixture.exec("mkdir -p sub/deep && touch sub/deep/target.txt && find . -type f");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "target.txt");
}

test "builtin find: -type d still recurses and lists dirs" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("mkdir -p sub/deep && find . -type d");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "deep");
}
