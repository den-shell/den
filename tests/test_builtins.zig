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

// ----------------------------------------------------------------------------
// `which`: paths, builtins, aliases (DenShellFixture → real den binary)
// ----------------------------------------------------------------------------

test "builtin which: reports an absolute path directly" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    // Regression: `which /abs/path` (e.g. `which $SHELL`) used to fail because it
    // only searched PATH for the literal string.
    const result = try fixture.execDirect("which /bin/sh");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "/bin/sh");
}

test "builtin which: identifies a shell builtin" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.execDirect("which cd");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "built-in");
}

test "builtin which: reports an alias" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.execDirect("alias ll='ls -la'; which ll");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "aliased to");
}

// ----------------------------------------------------------------------------
// Coreutils builtins fall back to the real tool for unsupported usage
// (these assume the standard /bin coreutils are on PATH, as on any Unix host)
// ----------------------------------------------------------------------------

test "builtin grep: -o falls back to real grep" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.execDirect("printf 'a1b2\\n' | grep -o '[0-9]'");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "1");
    try test_utils.TestAssert.expectContains(result.stdout, "2");
    try test_utils.TestAssert.expectTrue(std.mem.indexOf(u8, result.stderr, "invalid option") == null);
}

test "builtin grep: supported flags still use the builtin" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.execDirect("printf 'yes\\nno\\n' | grep yes");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "yes");
    try test_utils.TestAssert.expectTrue(std.mem.indexOf(u8, result.stdout, "no") == null);
}

// A regex pattern must reach a real regex engine.
//
// The builtin matches literal substrings, so `^FOO=` was searched for as those
// five characters and found nothing - reported as "no match" rather than an
// error. `grep '^KEY=' .env | cut -d= -f2-` therefore produced an empty
// string, and callers treated that emptiness as a fact about the file. One
// such pipeline stored an empty GitHub Actions secret and reported success.
test "builtin grep: an anchored pattern matches" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.execDirect("printf 'FOO=bar\\nxFOO=no\\n' | builtin grep '^FOO='");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "FOO=bar");
    try test_utils.TestAssert.expectTrue(std.mem.indexOf(u8, result.stdout, "xFOO=no") == null);
}

test "builtin grep: an end anchor matches" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.execDirect("printf 'keep\\nkeeper\\n' | builtin grep 'keep$'");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "keep");
    try test_utils.TestAssert.expectTrue(std.mem.indexOf(u8, result.stdout, "keeper") == null);
}

test "builtin grep: a character class matches" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.execDirect("printf 'a1\\nbb\\n' | builtin grep '[0-9]'");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "a1");
    try test_utils.TestAssert.expectTrue(std.mem.indexOf(u8, result.stdout, "bb") == null);
}

// A caret that is not an anchor is still a literal character, and handing the
// pattern to real grep keeps that true rather than trading one wrong answer
// for another.
test "builtin grep: a caret inside the pattern stays literal" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.execDirect("printf 'a^b\\nab\\n' | builtin grep 'a^b'");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "a^b");
}

test "builtin date: +FORMAT falls back to real date" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    // Regression: the builtin printed epoch garbage ("Jan 1 +6:+12:+4 1970").
    const result = try fixture.execDirect("date +%Y");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectTrue(std.mem.indexOf(u8, result.stdout, "1970") == null);
    try test_utils.TestAssert.expectTrue(std.mem.indexOf(u8, result.stdout, ":") == null);
}

test "builtin base64: reads stdin via fallback" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    // Regression: 'echo x | base64' used to fail with "missing input".
    const result = try fixture.execDirect("printf abc | base64");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "YWJj");
}

test "builtin seq: attached -s separator and plain range" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const sep = try fixture.execDirect("seq -s, 1 3");
    defer allocator.free(sep.stdout);
    defer allocator.free(sep.stderr);
    try test_utils.TestAssert.expectContains(sep.stdout, "1,2,3");

    const plain = try fixture.execDirect("seq 1 3");
    defer allocator.free(plain.stdout);
    defer allocator.free(plain.stderr);
    try test_utils.TestAssert.expectContains(plain.stdout, "1");
    try test_utils.TestAssert.expectContains(plain.stdout, "3");
}

test "builtin ls: default command resolves to Den implementation" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.execDirect("type ls");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "shell builtin");
}

test "builtin ls: color option stays on the native path" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("builtin ls --color=never");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectTrue(std.mem.indexOf(u8, result.stdout, "\x1b[") == null);
    try test_utils.TestAssert.expectTrue(std.mem.indexOf(u8, result.stderr, "invalid option") == null);
}

test "builtin ls: lists directories larger than 512 entries" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, fixture.getTempPath(), .{});
    defer dir.close(std.testing.io);

    for (0..600) |i| {
        const name = try std.fmt.allocPrint(allocator, "entry-{d}", .{i});
        defer allocator.free(name);
        const file = try dir.createFile(std.testing.io, name, .{});
        file.close(std.testing.io);
    }

    const result = try fixture.exec("builtin ls --color=never");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectEqual(@as(usize, 600), std.mem.count(u8, result.stdout, "\n"));
    try test_utils.TestAssert.expectTrue(std.mem.indexOf(u8, result.stderr, "truncated") == null);
}

// ----------------------------------------------------------------------------
// test -t FD: is the file descriptor a terminal?
//
// Under the test harness stdin/stdout are pipes, so `-t` is always false.
// We assert the exit status rather than a tty, which the harness can't provide.
// ----------------------------------------------------------------------------

test "builtin test: -t 0 is false when stdin is not a tty" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    // Pipe ensures fd 0 is definitely not a terminal; `-t 0` must return false.
    const result = try fixture.execDirect("echo hi | { test -t 0; echo rc=$?; }");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "rc=1");
}

test "builtin test: [ -t 1 ] takes the else branch on a pipe" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.execDirect("if [ -t 1 ]; then echo tty; else echo notty; fi | cat");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "notty");
}

// ----------------------------------------------------------------------------
// printf %.Nd integer precision: pad the number to at least N digits.
// ----------------------------------------------------------------------------

test "builtin printf: %.5d pads an integer to five digits" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.execDirect("printf '%.5d\\n' 42");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "00042");
}

test "builtin printf: %.3d precision composes with surrounding text" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.execDirect("printf '[%.3d]\\n' 7");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "[007]");
}

// ----------------------------------------------------------------------------
// $'\NNN' octal escapes in ANSI-C quoting.
// ----------------------------------------------------------------------------

test "builtin: ANSI-C $'\\NNN' octal escapes decode to bytes" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    // \101 \102 \103 -> A B C
    const result = try fixture.execDirect("printf '%s\\n' $'\\101\\102\\103'");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "ABC");
}

test "builtin: ANSI-C octal escapes for digit characters" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    // \060 \061 \062 -> 0 1 2
    const result = try fixture.execDirect("printf '%s\\n' $'\\060\\061\\062'");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "012");
}

test "builtin: ANSI-C $'\\cX' control-character escapes" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    // \cI -> 0x09 (tab), \c[ -> 0x1B (ESC).
    const result = try fixture.execDirect("printf 'A%sB%sC' $'\\cI' $'\\c['");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "A\tB");
    try test_utils.TestAssert.expectContains(result.stdout, "\x1B");
}

// ---------------------------------------------------------------------------
// bindkey / zle
//
// These run through DenShellFixture, which executes the den binary (plain
// ShellFixture shells out to /bin/sh and would test the wrong shell entirely).
// `den -c` is non-interactive and never creates a line editor, so this suite
// also guards the requirement that the keymaps live on the Shell rather than on
// the editor.
// ---------------------------------------------------------------------------

test "builtin bindkey: lists the default bindings" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try fixture.execDirect("bindkey");
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), r.exit_code);
    try test_utils.TestAssert.expectContains(r.stdout, "\"^A\" beginning-of-line");
    try test_utils.TestAssert.expectContains(r.stdout, "\"^E\" end-of-line");
    try test_utils.TestAssert.expectContains(r.stdout, "\"^[[A\" up-line-or-history");
}

test "builtin bindkey: -l lists the keymap names" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try fixture.execDirect("bindkey -l");
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), r.exit_code);
    try test_utils.TestAssert.expectContains(r.stdout, "emacs");
    try test_utils.TestAssert.expectContains(r.stdout, "main");
    try test_utils.TestAssert.expectContains(r.stdout, "vicmd");
}

test "builtin bindkey: every -L line is re-runnable" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try fixture.execDirect("bindkey -L");
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), r.exit_code);
    var lines = std.mem.splitScalar(u8, r.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try test_utils.TestAssert.expectTrue(std.mem.startsWith(u8, line, "bindkey "));
    }
}

test "builtin bindkey: -L output sources cleanly and is a fixed point" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    // `exec` runs in the fixture's temp directory, so the dumps do not land in
    // the working tree.
    const r = try fixture.exec(
        "bindkey -L > a.txt; source a.txt; bindkey -L > b.txt; diff a.txt b.txt && echo identical",
    );
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), r.exit_code);
    try test_utils.TestAssert.expectContains(r.stdout, "identical");
}

test "builtin bindkey: binds a widget and reports it back" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try fixture.execDirect("bindkey '^T' kill-whole-line && bindkey '^T'");
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), r.exit_code);
    try test_utils.TestAssert.expectContains(r.stdout, "\"^T\" kill-whole-line");
}

test "builtin bindkey: querying an unbound sequence exits 1" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try fixture.execDirect("bindkey '^X^Q'");
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 1), r.exit_code);
    try test_utils.TestAssert.expectEqual(@as(usize, 0), r.stdout.len);
}

test "builtin bindkey: -r disables a default binding" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try fixture.execDirect("bindkey -r '^A'; bindkey '^A'; echo exit=$?");
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "exit=1");
}

test "builtin bindkey: -r of an unbound key succeeds quietly" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try fixture.execDirect("bindkey -r '^X^Q'");
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), r.exit_code);
    try test_utils.TestAssert.expectEqual(@as(usize, 0), r.stderr.len);
}

test "builtin bindkey: -s round-trips through -L" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try fixture.execDirect("bindkey -s '^X^Z' 'fg\\n'; bindkey -L");
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), r.exit_code);
    try test_utils.TestAssert.expectContains(r.stdout, "bindkey -s \"^X^Z\"");
}

test "builtin bindkey: -M vicmd leaves the main keymap alone" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try fixture.execDirect("bindkey -M vicmd 'Y' yank; bindkey -M vicmd 'Y'; bindkey 'Y'; echo main=$?");
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "\"Y\" yank");
    try test_utils.TestAssert.expectContains(r.stdout, "main=1");
}

test "builtin bindkey: -d restores the defaults" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try fixture.execDirect("bindkey '^A' yank; bindkey -d; bindkey '^A'");
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), r.exit_code);
    try test_utils.TestAssert.expectContains(r.stdout, "\"^A\" beginning-of-line");
}

test "builtin bindkey: -e and -v only switch keymaps" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try fixture.execDirect("bindkey -v; bindkey -e; echo done");
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), r.exit_code);
    try test_utils.TestAssert.expectEqual(@as(usize, "done\n".len), r.stdout.len);
}

test "builtin bindkey: unknown widget is a diagnostic" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try fixture.execDirect("bindkey '^T' no-such-widget");
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 1), r.exit_code);
    try test_utils.TestAssert.expectContains(r.stderr, "no such widget: no-such-widget");
}

test "builtin bindkey: a shell function of that name points at zle -N" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try fixture.execDirect("my-widget() { echo hi; }; bindkey '^T' my-widget");
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 1), r.exit_code);
    try test_utils.TestAssert.expectContains(r.stderr, "zle -N");
}

test "builtin bindkey: malformed key spec is a diagnostic" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try fixture.execDirect("bindkey '\\x' yank");
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 1), r.exit_code);
    try test_utils.TestAssert.expectContains(r.stderr, "must be followed by a hex digit");
}

test "builtin bindkey: unknown keymap is a diagnostic" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try fixture.execDirect("bindkey -M nope 'x' yank");
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 1), r.exit_code);
    try test_utils.TestAssert.expectContains(r.stderr, "no such keymap: nope");
}

test "builtin bindkey: a bad option prints usage and exits 2" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try fixture.execDirect("bindkey -Q");
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 2), r.exit_code);
    try test_utils.TestAssert.expectContains(r.stderr, "bad option: -Q");
    try test_utils.TestAssert.expectContains(r.stderr, "usage: bindkey");
}

test "builtin bindkey: unsupported flags explain themselves" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try fixture.execDirect("bindkey -A");
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 2), r.exit_code);
    try test_utils.TestAssert.expectContains(r.stderr, "fixed set of keymaps");
}

test "builtin bindkey: every documented default is still bound" {
    const allocator = std.testing.allocator;
    const seqs = [_][]const u8{
        "^A",     "^E",     "^B",      "^F",     "^K",     "^U",      "^W",
        "^R",     "^L",     "^D",      "^P",     "^N",     "^Y",      "^T",
        "^I",     "^?",     "^[[A",    "^[[B",   "^[[C",   "^[[D",    "^[b",
        "^[f",    "^[d",    "^[[3~",   "^[[H",   "^[[F",
    };
    for (seqs) |seq| {
        const cmd = try std.fmt.allocPrint(allocator, "bindkey '{s}'", .{seq});
        defer allocator.free(cmd);
        var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try fixture.execDirect(cmd);
        defer allocator.free(r.stdout);
        defer allocator.free(r.stderr);

        try test_utils.TestAssert.expectEqual(@as(u8, 0), r.exit_code);
        try test_utils.TestAssert.expectTrue(r.stdout.len > 0);
    }
}

test "builtin type: reports bindkey as a shell builtin" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try fixture.execDirect("type bindkey");
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), r.exit_code);
    try test_utils.TestAssert.expectContains(r.stdout, "shell builtin");
}

// ---------------------------------------------------------------------------
// Shell-level builtins outside a bare command
//
// These are implemented on the Shell rather than in the executor. The executor
// kept its own copy of the builtin-name list, and twelve of them were missing
// from it, so each failed with "command not found" anywhere the executor ran the
// command -- after `&&`, inside a pipeline, in a subshell. The executor now asks
// the Shell instead of repeating the list.
// ---------------------------------------------------------------------------

test "shell builtins: setopt runs after &&" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try fixture.execDirect("true && setopt nullglob && echo ok");
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), r.exit_code);
    try test_utils.TestAssert.expectContains(r.stdout, "ok");
}

test "shell builtins: setopt takes effect after &&" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try fixture.execDirect("true && setopt nullglob; setopt");
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), r.exit_code);
    try test_utils.TestAssert.expectContains(r.stdout, "nullglob");
}

test "shell builtins: unsetopt runs after &&" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try fixture.execDirect("setopt nullglob; true && unsetopt nullglob && echo ok");
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), r.exit_code);
    try test_utils.TestAssert.expectContains(r.stdout, "ok");
}

test "shell builtins: shopt runs after &&" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try fixture.execDirect("true && shopt -s extglob && shopt");
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), r.exit_code);
    try test_utils.TestAssert.expectContains(r.stdout, "extglob");
}

test "shell builtins: enable, compgen and complete run after &&" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try fixture.execDirect("true && enable -a > /dev/null && true && compgen -b > /dev/null && true && complete > /dev/null; echo ok");
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "ok");
    try test_utils.TestAssert.expectEqual(@as(?usize, null), std.mem.indexOf(u8, r.stderr, "command not found"));
}

test "shell builtins: readonly and caller run after &&" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try fixture.execDirect("true && readonly RO_VAR=yes && echo $RO_VAR; true && caller; echo done");
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "yes");
    try test_utils.TestAssert.expectContains(r.stdout, "done");
    try test_utils.TestAssert.expectEqual(@as(?usize, null), std.mem.indexOf(u8, r.stderr, "command not found"));
}

test "shell builtins: bindkey runs in a pipeline" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try fixture.execDirect("bindkey -L | grep -c 'beginning-of-line'");
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), r.exit_code);
    try test_utils.TestAssert.expectEqual(@as(?usize, null), std.mem.indexOf(u8, r.stderr, "command not found"));
}

test "shell builtins: setopt runs in a pipeline" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try fixture.execDirect("setopt nullglob; setopt | grep -c nullglob");
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), r.exit_code);
    try test_utils.TestAssert.expectContains(r.stdout, "1");
}

test "shell builtins: an unknown name is still not found" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try fixture.execDirect("true && definitely_not_a_builtin_xyz");
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 127), r.exit_code);
    try test_utils.TestAssert.expectContains(r.stderr, "command not found");
}

// ---------------------------------------------------------------------------
// zle: widgets made from shell functions
//
// These cover the registry and the diagnostics, which `den -c` can reach.
// Actually running a widget needs a line editor, so that is covered by driving
// a pty instead.
// ---------------------------------------------------------------------------

test "builtin zle: -N defines a widget and -l lists it" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try fixture.execDirect("zle -N my-widget my-func; zle -l");
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), r.exit_code);
    try test_utils.TestAssert.expectContains(r.stdout, "my-widget");
}

test "builtin zle: the function defaults to the widget name" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try fixture.execDirect("zle -N solo; zle -l");
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), r.exit_code);
    try test_utils.TestAssert.expectContains(r.stdout, "solo");
}

test "builtin zle: -D removes a widget" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try fixture.execDirect("zle -N gone; zle -D gone; zle -l; echo end");
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "end");
    try test_utils.TestAssert.expectEqual(@as(?usize, null), std.mem.indexOf(u8, r.stdout, "gone"));
}

test "builtin zle: -D on an unknown widget is a diagnostic" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try fixture.execDirect("zle -D nope");
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 1), r.exit_code);
    try test_utils.TestAssert.expectContains(r.stderr, "no such widget: nope");
}

test "builtin zle: invoking a widget outside one is refused" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try fixture.execDirect("zle beginning-of-line");
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 1), r.exit_code);
    try test_utils.TestAssert.expectContains(r.stderr, "can only be called from a widget");
}

test "builtin zle: a bad option prints usage" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try fixture.execDirect("zle -Q");
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 2), r.exit_code);
    try test_utils.TestAssert.expectContains(r.stderr, "bad option: -Q");
}

test "builtin bindkey: binds a widget defined by zle -N" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try fixture.execDirect("zle -N mine my-func; bindkey '^X^F' mine; bindkey '^X^F'");
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), r.exit_code);
    try test_utils.TestAssert.expectContains(r.stdout, "\"^X^F\" mine");
}

test "builtin bindkey: -L prints a user widget by its own name" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try fixture.execDirect("zle -N mine my-func; bindkey '^X^F' mine; bindkey -L");
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), r.exit_code);
    try test_utils.TestAssert.expectContains(r.stdout, "bindkey \"^X^F\" mine");
}

test "builtin bindkey: a shell function points at zle -N" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try fixture.execDirect("myfn() { echo hi; }; bindkey '^T' myfn");
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 1), r.exit_code);
    try test_utils.TestAssert.expectContains(r.stderr, "zle -N myfn");
}

// ---------------------------------------------------------------------------
// zstyle
// ---------------------------------------------------------------------------

test "builtin zstyle: sets a style and lists it" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try fixture.execDirect("zstyle ':completion:*' verbose yes; zstyle");
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), r.exit_code);
    try test_utils.TestAssert.expectContains(r.stdout, "zstyle ':completion:*' verbose yes");
}

test "builtin zstyle: -L output quotes what the shell would otherwise expand" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try fixture.execDirect("zstyle ':completion:*' matcher-list '' 'm:{a-z}={A-Z}'; zstyle -L");
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), r.exit_code);
    // The pattern has a `*` and the matcher has braces; both must come back quoted.
    try test_utils.TestAssert.expectContains(r.stdout, "zstyle ':completion:*' matcher-list '' 'm:{a-z}={A-Z}'");
}

test "builtin zstyle: -L output re-runs to the same thing" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try fixture.exec(
        "zstyle ':completion:*' matcher-list '' 'm:{a-z}={A-Z}'; zstyle ':zle:*' x 1; " ++
            "zstyle -L > a.txt; zstyle -d; source a.txt; zstyle -L > b.txt; diff a.txt b.txt && echo identical",
    );
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), r.exit_code);
    try test_utils.TestAssert.expectContains(r.stdout, "identical");
}

test "builtin zstyle: the most specific pattern wins" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try fixture.execDirect(
        "zstyle '*' v broad; zstyle ':completion:*' v narrow; zstyle -s ':completion:x' v OUT; echo got=$OUT",
    );
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "got=narrow");
}

test "builtin zstyle: -t tests a style, -T defaults an unset one to true" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try fixture.execDirect(
        "zstyle ':completion:*' menu select; zstyle -t ':completion:x' menu select; echo a=$?; " ++
            "zstyle -t ':completion:x' absent; echo b=$?; zstyle -T ':completion:x' absent; echo c=$?",
    );
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "a=0");
    try test_utils.TestAssert.expectContains(r.stdout, "b=1");
    try test_utils.TestAssert.expectContains(r.stdout, "c=0");
}

test "builtin zstyle: -b reads a style as a boolean" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try fixture.execDirect(
        "zstyle ':completion:*' flag on; zstyle -b ':completion:x' flag B; echo b=$B; " ++
            "zstyle ':completion:*' flag off; zstyle -b ':completion:x' flag C; echo c=$C",
    );
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "b=yes");
    try test_utils.TestAssert.expectContains(r.stdout, "c=no");
}

test "builtin zstyle: -g collects patterns, styles and values" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try fixture.execDirect(
        "zstyle ':completion:*' a 1; zstyle ':completion:*' b 2; zstyle ':zle:*' c 3; " ++
            // Quoted: the collected patterns contain `*`, which would otherwise
            // be split and globbed before echo saw it.
            "zstyle -g P; echo \"p=$P\"; zstyle -g S ':completion:*'; echo \"s=$S\"; " ++
            "zstyle -g V ':completion:*' b; echo \"v=$V\"",
    );
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    // A pattern carrying two styles is collected once, as zsh reports it.
    try test_utils.TestAssert.expectContains(r.stdout, "p=:completion:* :zle:*");
    try test_utils.TestAssert.expectContains(r.stdout, "s=a b");
    try test_utils.TestAssert.expectContains(r.stdout, "v=2");
}

test "builtin zstyle: -g succeeds when listing, fails only on a missing style" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    // Only the three-argument form is a lookup. Collecting patterns or style
    // names reports success even with nothing to collect, matching zsh -- a
    // `.zshrc` that guards on `zstyle -g` must not take the failure branch.
    const r = try fixture.execDirect(
        "zstyle -g A; echo \"empty=$?\"; zstyle ':x:*' s v; " ++
            "zstyle -g B ':y:*'; echo \"nomatch=$?\"; " ++
            "zstyle -g C ':x:*' nosuch; echo \"nostyle=$?\"; " ++
            "zstyle -g D ':x:*' s; echo \"hit=$? v=$D\"",
    );
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "empty=0");
    try test_utils.TestAssert.expectContains(r.stdout, "nomatch=0");
    try test_utils.TestAssert.expectContains(r.stdout, "nostyle=1");
    try test_utils.TestAssert.expectContains(r.stdout, "hit=0 v=v");
}

test "builtin zstyle: -g matches the stored pattern, not a context" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    // Unlike -s/-b/-t, -g's second argument is the pattern as stored: zsh does
    // not match a context against it, so a real context finds nothing.
    const r = try fixture.execDirect(
        "zstyle ':completion:*' b 2; " ++
            "zstyle -g V ':completion:xx' b; echo \"ctx=$? v=[$V]\"; " ++
            "zstyle -g W ':completion:*' b; echo \"lit=$? w=[$W]\"",
    );
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "ctx=1 v=[]");
    try test_utils.TestAssert.expectContains(r.stdout, "lit=0 w=[2]");
}

test "builtin zstyle: -d removes styles" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try fixture.execDirect(
        "zstyle ':completion:*' a 1; zstyle ':completion:*' b 2; zstyle -d ':completion:*' a; zstyle -L; echo end",
    );
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "end");
    try test_utils.TestAssert.expectContains(r.stdout, " b 2");
    try test_utils.TestAssert.expectEqual(@as(?usize, null), std.mem.indexOf(u8, r.stdout, " a 1"));
}

test "builtin zstyle: -m matches a style's value" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try fixture.execDirect(
        "zstyle ':completion:*' matcher-list 'm:{a-z}={A-Z}'; zstyle -m ':completion:x' matcher-list '*a-z*'; echo hit=$?; " ++
            "zstyle -m ':completion:x' matcher-list '*nope*'; echo miss=$?",
    );
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "hit=0");
    try test_utils.TestAssert.expectContains(r.stdout, "miss=1");
}

test "builtin zstyle: -e says it is unsupported" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try fixture.execDirect("zstyle -e ':completion:*' x 'reply=(1)'");
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 2), r.exit_code);
    try test_utils.TestAssert.expectContains(r.stderr, "not supported");
}

test "builtin zstyle: a bad option prints usage" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try fixture.execDirect("zstyle -Q");
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 2), r.exit_code);
    try test_utils.TestAssert.expectContains(r.stderr, "bad option: -Q");
}

test "builtin zstyle: a real zshrc completion block is accepted" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    // The lines people actually paste. None of these should error.
    const r = try fixture.execDirect(
        "zstyle ':completion:*' menu select; " ++
            "zstyle ':completion:*' matcher-list '' 'm:{a-zA-Z}={A-Za-z}'; " ++
            "zstyle ':completion:*' list-colors ''; " ++
            "zstyle ':completion:*:descriptions' format '%B%d%b'; " ++
            "zstyle ':completion:*' use-cache on; echo ok",
    );
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), r.exit_code);
    try test_utils.TestAssert.expectContains(r.stdout, "ok");
    try test_utils.TestAssert.expectEqual(@as(usize, 0), r.stderr.len);
}

test "builtin type: reports zstyle as a shell builtin" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try fixture.execDirect("type zstyle");
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), r.exit_code);
    try test_utils.TestAssert.expectContains(r.stdout, "shell builtin");
}
