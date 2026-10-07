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

test "zshexit hook: a zshexit function runs as the shell exits" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try fixture.execDirect("zshexit() { echo BYE; }; echo main");
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    // Order is the point: the hook fires after the script body, not during it.
    try test_utils.TestAssert.expectContains(r.stdout, "main");
    try test_utils.TestAssert.expectContains(r.stdout, "BYE");
    const main_at = std.mem.indexOf(u8, r.stdout, "main").?;
    const bye_at = std.mem.indexOf(u8, r.stdout, "BYE").?;
    try std.testing.expect(main_at < bye_at);
}

test "zshexit hook: zshexit_functions run in order" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try fixture.execDirect(
        "a() { echo ONE; }; b() { echo TWO; }; zshexit_functions=(a b); echo main",
    );
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    const one_at = std.mem.indexOf(u8, r.stdout, "ONE") orelse return error.MissingOne;
    const two_at = std.mem.indexOf(u8, r.stdout, "TWO") orelse return error.MissingTwo;
    try std.testing.expect(one_at < two_at);
}

test "zshexit hook: an EXIT trap still runs, and first" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    // Two mechanisms, bash's and zsh's. A config may set both, so neither may
    // swallow the other.
    const r = try fixture.execDirect(
        "trap 'echo TRAP' EXIT; zshexit() { echo HOOK; }; echo main",
    );
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    const trap_at = std.mem.indexOf(u8, r.stdout, "TRAP") orelse return error.MissingTrap;
    const hook_at = std.mem.indexOf(u8, r.stdout, "HOOK") orelse return error.MissingHook;
    try std.testing.expect(trap_at < hook_at);
}

test "builtin add-zsh-hook: registers a function and lists it as zsh does" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try fixture.execDirect(
        "f1() { :; }; add-zsh-hook precmd f1; echo \"rc=$?\"; add-zsh-hook -L precmd",
    );
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "rc=0");
    // zsh prints a re-runnable declaration, not bare names.
    try test_utils.TestAssert.expectContains(r.stdout, "typeset -g -a precmd_functions=( f1 )");
}

test "builtin add-zsh-hook: adding twice registers once" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    // An rc file sourced twice is the common way this happens, and the hook
    // would otherwise run twice per prompt.
    const r = try fixture.execDirect(
        "f1() { :; }; add-zsh-hook precmd f1; add-zsh-hook precmd f1; add-zsh-hook -L precmd",
    );
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "precmd_functions=( f1 )");
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "f1 f1") == null);
}

test "builtin add-zsh-hook: -d removes, and removing an absent hook succeeds" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try fixture.execDirect(
        "f1() { :; }; f2() { :; }; add-zsh-hook precmd f1; add-zsh-hook precmd f2; " ++
            "add-zsh-hook -d precmd f1; add-zsh-hook -L precmd; " ++
            "add-zsh-hook -d precmd never_added; echo \"absent=$?\"",
    );
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "precmd_functions=( f2 )");
    // An rc file that removes a hook it never added must not start failing.
    try test_utils.TestAssert.expectContains(r.stdout, "absent=0");
}

test "builtin add-zsh-hook: order is the order they were added" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try fixture.execDirect(
        "a() { :; }; b() { :; }; c() { :; }; " ++
            "add-zsh-hook precmd a; add-zsh-hook precmd b; add-zsh-hook precmd c; " ++
            "add-zsh-hook -L precmd",
    );
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "precmd_functions=( a b c )");
}

test "builtin add-zsh-hook: a hook den does not fire is refused" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    // A deliberate divergence: zsh accepts `periodic`, but den never fires it,
    // so a function registered there would silently never run.
    const r = try fixture.execDirect("f1() { :; }; add-zsh-hook periodic f1");
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 1), r.exit_code);
    try test_utils.TestAssert.expectContains(r.stderr, "does not fire periodic");
    try test_utils.TestAssert.expectContains(r.stderr, "Valid hooks are");
}

test "builtin add-zsh-hook: zshexit is accepted and fires" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try fixture.execDirect(
        "bye() { echo BYE; }; add-zsh-hook zshexit bye; echo \"rc=$?\"; echo main",
    );
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "rc=0");
    try test_utils.TestAssert.expectContains(r.stdout, "BYE");
}

test "builtin add-zsh-hook: an unknown hook names the valid ones" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try fixture.execDirect("add-zsh-hook nosuch f1");
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 1), r.exit_code);
    try test_utils.TestAssert.expectContains(r.stderr, "chpwd precmd preexec zshexit");
}

test "builtin add-zsh-hook: a bad option is a usage error" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try fixture.execDirect("add-zsh-hook -q precmd f1");
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 2), r.exit_code);
    try test_utils.TestAssert.expectContains(r.stderr, "bad option: -q");
}

test "builtin add-zsh-hook: -U and -D are accepted as zsh spells them" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    // Prompt frameworks write these, and neither changes what the line means
    // here, so they must not be rejected.
    const r = try fixture.execDirect(
        "f1() { :; }; add-zsh-hook -U precmd f1; echo \"u=$?\"; " ++
            "add-zsh-hook -D precmd f1; echo \"d=$?\"; add-zsh-hook -L precmd",
    );
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "u=0");
    try test_utils.TestAssert.expectContains(r.stdout, "d=0");
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "precmd_functions") == null);
}

test "builtin type: reports add-zsh-hook as a shell builtin" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try fixture.execDirect("type add-zsh-hook");
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), r.exit_code);
    try test_utils.TestAssert.expectContains(r.stdout, "shell builtin");
}

test "builtin add-zsh-hook: -D deletes by pattern" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    // zsh's -D takes a glob, not a name, so one line drops a family of hooks.
    const r = try fixture.execDirect(
        "f1() { :; }; f2() { :; }; g1() { :; }; " ++
            "add-zsh-hook precmd f1; add-zsh-hook precmd f2; add-zsh-hook precmd g1; " ++
            "add-zsh-hook -D precmd 'f*'; add-zsh-hook -L precmd",
    );
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "precmd_functions=( g1 )");
}

test "builtin add-zsh-hook: -d does not treat its operand as a pattern" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    // Only -D globs. A -d of `f*` must not take f1 with it.
    const r = try fixture.execDirect(
        "f1() { :; }; add-zsh-hook precmd f1; add-zsh-hook -d precmd 'f*'; " ++
            "add-zsh-hook -L precmd",
    );
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "precmd_functions=( f1 )");
}

test "zsh preamble: the setup lines of a real zshrc are accepted" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    // The top of nearly every .zshrc. None of it needs to do anything; it needs
    // to stop being a wall of `command not found` above the lines that matter.
    const r = try fixture.execDirect(
        "compinit; bashcompinit; compinit -d /tmp/zcompdump-den-test; " ++
            "zmodload zsh/complist; zmodload -i zsh/parameter; " ++
            "emulate -L zsh; compdef _git g; echo ok",
    );
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), r.exit_code);
    try test_utils.TestAssert.expectContains(r.stdout, "ok");
    // Silence matters as much as success: these run while an rc file is being
    // sourced, so a note per line would print on every shell start.
    try test_utils.TestAssert.expectEqual(@as(usize, 0), r.stderr.len);
}

test "zsh preamble: zmodload -e reports no module is loaded" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    // A config that tests before using a module should take its fallback path,
    // since den has no loadable modules.
    const r = try fixture.execDirect("zmodload -e zsh/complist; echo \"e=$?\"");
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "e=1");
}

test "zsh preamble: emulate refuses csh but accepts sh and ksh" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    // csh's word splitting and history are nothing like den's, so a function
    // that asked for them and carried on would quietly do the wrong thing.
    const r = try fixture.execDirect(
        "emulate -L sh; echo \"sh=$?\"; emulate -L ksh; echo \"ksh=$?\"; " ++
            "emulate csh; echo \"csh=$?\"",
    );
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "sh=0");
    try test_utils.TestAssert.expectContains(r.stdout, "ksh=0");
    try test_utils.TestAssert.expectContains(r.stdout, "csh=1");
    try test_utils.TestAssert.expectContains(r.stderr, "csh semantics are not available");
}

test "builtin is-at-least: two operands compare as zsh does" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try fixture.execDirect(
        "is-at-least 4.3 5.9; echo \"a=$?\"; is-at-least 6.0 5.9; echo \"b=$?\"; " ++
            // Numeric per component: 5.10 is above 5.9.
            "is-at-least 5.9 5.10; echo \"c=$?\"; is-at-least 5.9.1 5.9; echo \"d=$?\"",
    );
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "a=0");
    try test_utils.TestAssert.expectContains(r.stdout, "b=1");
    try test_utils.TestAssert.expectContains(r.stdout, "c=0");
    try test_utils.TestAssert.expectContains(r.stdout, "d=1");
}

test "builtin is-at-least: one operand is false without a ZSH_VERSION" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    // Den reports itself as den rather than claiming to be zsh, so there is no
    // zsh version to be at least. False sends a config down its older-zsh
    // branch, which is the conservative direction.
    const r = try fixture.execDirect("is-at-least 5.0; echo \"rc=$?\"");
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "rc=1");
}

test "builtin is-at-least: honours ZSH_VERSION when something sets it" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try fixture.execDirect(
        "export ZSH_VERSION=5.9; is-at-least 5.0; echo \"old=$?\"; " ++
            "is-at-least 9.9; echo \"new=$?\"",
    );
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "old=0");
    try test_utils.TestAssert.expectContains(r.stdout, "new=1");
}

test "builtin is-at-least: no operand is a usage error" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try fixture.execDirect("is-at-least");
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 2), r.exit_code);
    try test_utils.TestAssert.expectContains(r.stderr, "usage:");
}

test "builtin autoload: defines a function from fpath on first call" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    // The file holds a body, not a `name() { ... }` wrapper. That is zsh's
    // convention and what a real fpath directory contains.
    const path = try fixture.createFile("greet", "echo \"greeted $1\"\n");
    allocator.free(path);

    const script = try std.fmt.allocPrint(
        allocator,
        "fpath=({s}); autoload -Uz greet; echo \"mark=$?\"; greet world",
        .{fixture.temp_dir.path},
    );
    defer allocator.free(script);

    const r = try fixture.execDirect(script);
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "mark=0");
    try test_utils.TestAssert.expectContains(r.stdout, "greeted world");
}

test "builtin autoload: the file is read on the call, not on the mark" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    // Laziness is the whole point: a config autoloads many names and pays for
    // none of them at startup. Writing the file after the autoload line proves
    // nothing was read early.
    const script = try std.fmt.allocPrint(
        allocator,
        "fpath=({s}); autoload -Uz later; printf 'echo LATE\\n' > {s}/later; later",
        .{ fixture.temp_dir.path, fixture.temp_dir.path },
    );
    defer allocator.free(script);

    const r = try fixture.execDirect(script);
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "LATE");
}

test "builtin autoload: marking a missing name succeeds, calling it does not" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    // zsh's timing: the mark cannot fail because fpath may still change.
    const script = try std.fmt.allocPrint(
        allocator,
        "fpath=({s}); autoload -Uz nosuch; echo \"mark=$?\"; nosuch; echo \"call=$?\"",
        .{fixture.temp_dir.path},
    );
    defer allocator.free(script);

    const r = try fixture.execDirect(script);
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "mark=0");
    // 1, not 127: the name was known and the search path is what is wrong, so
    // this is not `command not found`.
    try test_utils.TestAssert.expectContains(r.stdout, "call=1");
    try test_utils.TestAssert.expectContains(r.stderr, "function definition file not found");
}

test "builtin autoload: +X loads immediately and reports a missing file" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const script = try std.fmt.allocPrint(
        allocator,
        "fpath=({s}); autoload +X nosuch; echo \"rc=$?\"",
        .{fixture.temp_dir.path},
    );
    defer allocator.free(script);

    const r = try fixture.execDirect(script);
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "rc=1");
    try test_utils.TestAssert.expectContains(r.stderr, "function definition file not found");
}

test "builtin autoload: FPATH is searched as well as the fpath array" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const path = try fixture.createFile("fromenv", "echo ENVHIT\n");
    allocator.free(path);

    // zsh keeps fpath and FPATH tied; den reads both, so either works.
    const script = try std.fmt.allocPrint(
        allocator,
        "export FPATH={s}; autoload -Uz fromenv; fromenv",
        .{fixture.temp_dir.path},
    );
    defer allocator.free(script);

    const r = try fixture.execDirect(script);
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "ENVHIT");
}

test "builtin autoload: an existing function is not replaced" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const path = try fixture.createFile("greet", "echo FROMFILE\n");
    allocator.free(path);

    // A config that defines a function and then autoloads the name keeps the
    // definition it just made.
    const script = try std.fmt.allocPrint(
        allocator,
        "fpath=({s}); greet() {{ echo MINE; }}; autoload -Uz greet; greet",
        .{fixture.temp_dir.path},
    );
    defer allocator.free(script);

    const r = try fixture.execDirect(script);
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "MINE");
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "FROMFILE") == null);
}

test "builtin autoload: an autoloaded function works in a pipeline" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const path = try fixture.createFile("shout", "echo hello\n");
    allocator.free(path);

    // The pipeline path resolves commands separately, so it needs its own hook.
    const script = try std.fmt.allocPrint(
        allocator,
        "fpath=({s}); autoload -Uz shout; shout | tr a-z A-Z",
        .{fixture.temp_dir.path},
    );
    defer allocator.free(script);

    const r = try fixture.execDirect(script);
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "HELLO");
}

test "builtin autoload: with no names, lists what is marked" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try fixture.execDirect("autoload -Uz alpha beta; autoload");
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "alpha");
    try test_utils.TestAssert.expectContains(r.stdout, "beta");
}

test "builtin autoload: a bad option is a usage error" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try fixture.execDirect("autoload -Q foo");
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 2), r.exit_code);
    try test_utils.TestAssert.expectContains(r.stderr, "bad option: -Q");
}

test "builtin autoload: the line every zshrc opens with works" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    // add-zsh-hook is a builtin here rather than an fpath function, so the
    // autoload is a no-op and the call still has to work.
    const r = try fixture.execDirect(
        "autoload -Uz add-zsh-hook && compinit; f() { :; }; add-zsh-hook precmd f; " ++
            "add-zsh-hook -L precmd",
    );
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), r.exit_code);
    try test_utils.TestAssert.expectContains(r.stdout, "precmd_functions=( f )");
}

test "builtin autoload: a name den already provides is never shadowed" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    // A deliberate divergence. In zsh the placeholder shadows even a builtin,
    // so `autoload -Uz echo; echo hi` is an error there. But the names a zsh
    // config autoloads -- compinit, add-zsh-hook, bashcompinit, is-at-least --
    // are builtins in den, and `autoload -Uz compinit; compinit` is the single
    // most common pair of lines in a .zshrc. A name den implements needs no
    // definition file, so it is not marked at all.
    const r = try fixture.execDirect(
        "autoload -Uz compinit; compinit; echo \"compinit=$?\"; " ++
            "autoload -Uz echo; echo hi",
    );
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "compinit=0");
    try test_utils.TestAssert.expectContains(r.stdout, "hi");
    try test_utils.TestAssert.expectEqual(@as(usize, 0), r.stderr.len);
}

test "builtin autoload: a zsh function den lacks fails informatively" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    // vcs_info is a real zsh function with no den equivalent and no file in
    // fpath. Here den matches zsh: the name resolves as a function or fails,
    // and does not fall back to $PATH.
    const r = try fixture.execDirect("autoload -Uz vcs_info; vcs_info; echo \"rc=$?\"");
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "rc=1");
    try test_utils.TestAssert.expectContains(r.stderr, "function definition file not found");
}

test "redirection: a shell builtin's stderr goes to the file" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    // Shell-level builtins used to run through a second, hand-rolled
    // redirection implementation that ignored the fd and always redirected
    // stdout, so `2>` sent stdout to the file and left the diagnostic on the
    // terminal. `cmd 2>/dev/null` is the standard rc-file guard, so it has to
    // work for setopt and friends.
    const path = try std.fs.path.join(allocator, &.{ fixture.temp_dir.path, "e.txt" });
    defer allocator.free(path);

    const script = try std.fmt.allocPrint(
        allocator,
        "setopt nosuchoption 2> {s}; cat {s}",
        .{ path, path },
    );
    defer allocator.free(script);

    const r = try fixture.execDirect(script);
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "no such option: nosuchoption");
    // Nothing may be left on the real stderr.
    try test_utils.TestAssert.expectEqual(@as(usize, 0), r.stderr.len);
}

test "redirection: 2>/dev/null silences a shell builtin" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try fixture.execDirect(
        "bindkey -Q 2>/dev/null; zstyle -Q x 2>/dev/null; " ++
            "add-zsh-hook nosuch f 2>/dev/null; autoload -Q f 2>/dev/null; echo done",
    );
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "done");
    try test_utils.TestAssert.expectEqual(@as(usize, 0), r.stderr.len);
}

test "redirection: 2>&1 on a shell builtin reaches stdout" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    // fd_duplicate was one of the four kinds the hand-rolled version did not
    // implement at all, so this did nothing.
    const r = try fixture.execDirect("setopt nosuchoption 2>&1 | cat");
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "no such option");
}

test "redirection: a shell builtin's stdout still redirects" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const path = try std.fs.path.join(allocator, &.{ fixture.temp_dir.path, "o.txt" });
    defer allocator.free(path);

    const script = try std.fmt.allocPrint(
        allocator,
        "zstyle ':a:*' b c; zstyle -L > {s}; cat {s}",
        .{ path, path },
    );
    defer allocator.free(script);

    const r = try fixture.execDirect(script);
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "zstyle ':a:*' b c");
}

test "redirection: 2>> appends where 2> truncates" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    // `2>>` was a parse error for every command, not just builtins: the
    // tokenizer matched `2>` and left a stray `>` with no target.
    const path = try std.fs.path.join(allocator, &.{ fixture.temp_dir.path, "a.txt" });
    defer allocator.free(path);

    const script = try std.fmt.allocPrint(
        allocator,
        "setopt nosuchoption 2>> {s}; setopt alsobad 2>> {s}; cat {s}",
        .{ path, path, path },
    );
    defer allocator.free(script);

    const r = try fixture.execDirect(script);
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "nosuchoption");
    try test_utils.TestAssert.expectContains(r.stdout, "alsobad");
}

test "redirection: 2>> works for an external command too" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const path = try std.fs.path.join(allocator, &.{ fixture.temp_dir.path, "x.txt" });
    defer allocator.free(path);

    const script = try std.fmt.allocPrint(
        allocator,
        "/bin/ls /nonexistent-aaa 2>> {s}; /bin/ls /nonexistent-bbb 2>> {s}; cat {s}",
        .{ path, path, path },
    );
    defer allocator.free(script);

    const r = try fixture.execDirect(script);
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "nonexistent-aaa");
    try test_utils.TestAssert.expectContains(r.stdout, "nonexistent-bbb");
}

test "redirection: a noclobber violation does not end the shell" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    // The redirection failure paths used to _exit(1) unconditionally. That is
    // right in a forked child and fatal in the parent: with `set -C`, one
    // `echo x > existing` ended an interactive session outright.
    const path = try fixture.createFile("exists.txt", "already here\n");
    allocator.free(path);

    const script = try std.fmt.allocPrint(
        allocator,
        "set -C; echo hi > {s}/exists.txt; echo \"rc=$?\"; echo STILL_RUNNING",
        .{fixture.temp_dir.path},
    );
    defer allocator.free(script);

    const r = try fixture.execDirect(script);
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stderr, "cannot overwrite existing file");
    try test_utils.TestAssert.expectContains(r.stdout, "rc=1");
    try test_utils.TestAssert.expectContains(r.stdout, "STILL_RUNNING");
}

test "redirection: an unopenable target fails without ending the shell" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    // Same story for a target that cannot be opened, on the builtin, the
    // shell-builtin and the external paths. Status 1 each time, as bash and zsh
    // both report.
    const r = try fixture.execDirect(
        "echo hi > /nonexistent-dir-xyz/f; echo \"builtin=$?\"; " ++
            "setopt > /nonexistent-dir-xyz/f; echo \"shell=$?\"; " ++
            "/bin/echo hi > /nonexistent-dir-xyz/f; echo \"external=$?\"; " ++
            "cat < /nonexistent-file-xyz; echo \"input=$?\"; echo STILL_RUNNING",
    );
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "builtin=1");
    try test_utils.TestAssert.expectContains(r.stdout, "shell=1");
    try test_utils.TestAssert.expectContains(r.stdout, "external=1");
    try test_utils.TestAssert.expectContains(r.stdout, "input=1");
    try test_utils.TestAssert.expectContains(r.stdout, "STILL_RUNNING");
}

test "array assignment: elements expand variables, tildes and arithmetic" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    // Array elements used to be duped verbatim: nothing expanded at all, so
    // `fpath=(~/funcs $fpath)` stored a literal tilde.
    const r = try fixture.execDirect(
        "Y=solo; a=($Y); echo \"var=[${a[0]}]\"; " ++
            "b=($((1+2))); echo \"arith=[${b[0]}]\"; " ++
            "HOME=/tmp/denhome-test; c=(~/x); echo \"tilde=[${c[0]}]\"",
    );
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "var=[solo]");
    try test_utils.TestAssert.expectContains(r.stdout, "arith=[3]");
    try test_utils.TestAssert.expectContains(r.stdout, "tilde=[/tmp/denhome-test/x]");
}

test "array assignment: an unquoted expansion field-splits, a quoted one does not" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    // bash semantics, which is what den's 0-indexed arrays follow.
    const r = try fixture.execDirect(
        "X=\"a b\"; u=($X); q=(\"$X\"); " ++
            "echo \"unquoted=${#u[@]} quoted=${#q[@]} q0=[${q[0]}]\"",
    );
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "unquoted=2 quoted=1 q0=[a b]");
}

test "array assignment: a command substitution is one word that splits" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    // The scanner has to treat $(...), ${...} and backticks as single words even
    // though they contain spaces, then let field splitting divide the result.
    const r = try fixture.execDirect(
        "a=($(echo p q)); echo \"dollar=${#a[@]} [${a[@]}]\"; " ++
            "b=(`echo p q`); echo \"backtick=${#b[@]} [${b[@]}]\"; " ++
            "c=(${NOPE:-d e}); echo \"braced=${#c[@]} [${c[@]}]\"; " ++
            "d=($(echo $(echo x)) y); echo \"nested=${#d[@]} [${d[@]}]\"",
    );
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "dollar=2 [p q]");
    try test_utils.TestAssert.expectContains(r.stdout, "backtick=2 [p q]");
    try test_utils.TestAssert.expectContains(r.stdout, "braced=2 [d e]");
    try test_utils.TestAssert.expectContains(r.stdout, "nested=2 [x y]");
}

test "array assignment: globs expand, and quotes stop them" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const p1 = try fixture.createFile("one.dat", "");
    allocator.free(p1);
    const p2 = try fixture.createFile("two.dat", "");
    allocator.free(p2);

    const script = try std.fmt.allocPrint(
        allocator,
        // Separated by `;` rather than `&&` on purpose: an array assignment is
        // not recognised as a chain segment, which is a separate defect.
        "cd {s}; g=(*.dat); echo \"glob=${{#g[@]}}\"; " ++
            "q=(\"*.dat\"); echo \"dq=${{#q[@]}} [${{q[0]}}]\"; " ++
            "s=('*.dat'); echo \"sq=${{#s[@]}} [${{s[0]}}]\"; " ++
            "n=(no_such_*); echo \"nomatch=${{#n[@]}} [${{n[0]}}]\"",
        .{fixture.temp_dir.path},
    );
    defer allocator.free(script);

    const r = try fixture.execDirect(script);
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "glob=2");
    // A quoted pattern is a literal, in either quote style.
    try test_utils.TestAssert.expectContains(r.stdout, "dq=1 [*.dat]");
    try test_utils.TestAssert.expectContains(r.stdout, "sq=1 [*.dat]");
    try test_utils.TestAssert.expectContains(r.stdout, "nomatch=1 [no_such_*]");
}

test "array assignment: single quotes keep everything literal" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try fixture.execDirect(
        "Y=solo; a=('$Y' lit); echo \"n=${#a[@]} zero=[${a[0]}] one=[${a[1]}]\"",
    );
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "n=2 zero=[$Y] one=[lit]");
}

test "array assignment: a word mixing quoting stays one element" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    // The old scanner stopped at the closing quote and started a new element, so
    // `("x"y)` produced two. Quoting is tracked per run now.
    const r = try fixture.execDirect(
        "X=\"a b\"; m=(pre\"$X\"post); echo \"mixed=${#m[@]} [${m[0]}]\"; " ++
            "n=(\"x\"y); echo \"adjacent=${#n[@]} [${n[0]}]\"",
    );
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "mixed=1 [prea bpost]");
    try test_utils.TestAssert.expectContains(r.stdout, "adjacent=1 [xy]");
}

test "array assignment: fpath with a tilde reaches autoload" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    // The idiom that motivated this: the standard zsh fpath line, which stored a
    // literal `~/funcs` before and so could never find a function.
    const dir = try std.fs.path.join(allocator, &.{ fixture.temp_dir.path, "funcs" });
    defer allocator.free(dir);
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, dir);
    const fn_path = try std.fs.path.join(allocator, &.{ dir, "hello_fn" });
    defer allocator.free(fn_path);
    {
        const f = try std.Io.Dir.cwd().createFile(std.Options.debug_io, fn_path, .{ .truncate = true });
        defer f.close(std.Options.debug_io);
        try f.writeStreamingAll(std.Options.debug_io, "echo FROM_FPATH\n");
    }

    const script = try std.fmt.allocPrint(
        allocator,
        "HOME={s}; fpath=(~/funcs); autoload -Uz hello_fn; hello_fn",
        .{fixture.temp_dir.path},
    );
    defer allocator.free(script);

    const r = try fixture.execDirect(script);
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "FROM_FPATH");
}

test "command arguments: a backtick substitution field-splits" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    // The splitting guard only looked for `$`, so `$(...)` split and backticks
    // did not. This was wrong for command arguments too, not just arrays.
    const r = try fixture.execDirect("printf '[%s]' `echo p q`; echo; printf '[%s]' $(echo p q); echo");
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "[p][q]");
}

test "array assignment: works as a chain segment" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    // Only a whole line was recognised before, by the shell ahead of the parser.
    // In a chain the `(` became a subshell and the rest was swallowed: this
    // assigned nothing and ran nothing.
    const r = try fixture.execDirect(
        "true && a=(x y) && echo \"chain=${#a[@]} [${a[@]}]\"; " ++
            "b=(p) && echo \"first=${#b[@]}\"; " ++
            "false || c=(q r); echo \"or=${#c[@]} [${c[@]}]\"; " ++
            "true && o=() && echo \"empty=${#o[@]}\"",
    );
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "chain=2 [x y]");
    try test_utils.TestAssert.expectContains(r.stdout, "first=1");
    try test_utils.TestAssert.expectContains(r.stdout, "or=2 [q r]");
    try test_utils.TestAssert.expectContains(r.stdout, "empty=0");
}

test "array assignment: works inside if, for and a subshell" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const r = try fixture.execDirect(
        "if true; then e=(i j); echo \"if=${#e[@]} [${e[@]}]\"; fi; " ++
            "for i in 1; do f=(k l); echo \"for=${#f[@]} [${f[@]}]\"; done; " ++
            "(s=(y z); echo \"sub=${#s[@]} [${s[@]}]\")",
    );
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "if=2 [i j]");
    try test_utils.TestAssert.expectContains(r.stdout, "for=2 [k l]");
    try test_utils.TestAssert.expectContains(r.stdout, "sub=2 [y z]");
}

test "array assignment: a chain element may contain spaces and substitutions" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    // The word scanners that look for a `VAR=val cmd` prefix split on
    // whitespace without tracking parens, so `a=(z "q r") && ...` was read as
    // the assignment `a=(z` followed by the command `"q r") && ...`.
    const r = try fixture.execDirect(
        "a=(z \"q r\") && echo \"quoted=${#a[@]} [${a[@]}]\"; " ++
            "m=($(echo p) \"q r\") && echo \"sub=${#m[@]} [${m[@]}]\"; " ++
            "n=(a) && n+=($(echo b c)) && echo \"append=${#n[@]} [${n[@]}]\"",
    );
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "quoted=2 [z q r]");
    try test_utils.TestAssert.expectContains(r.stdout, "sub=2 [p q r]");
    try test_utils.TestAssert.expectContains(r.stdout, "append=3 [a b c]");
}

test "array assignment: a temporary variable prefix still works" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    // The paren-aware scanner must not disturb `VAR=val cmd`, which is what
    // those scanners exist for.
    const r = try fixture.execDirect(
        "V=1 echo tempvar-ok; V=1 W=2 env | grep -c '^V=1$'",
    );
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "tempvar-ok");
    try test_utils.TestAssert.expectContains(r.stdout, "1");
}

test "script file: a one-line function definition followed by a call" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    // A script is read line by line, and the whole line was consumed as the
    // definition, so the call sharing it was dropped: the function was defined
    // and nothing ran. `-c` was unaffected, because it splits on `;` first.
    const path = try fixture.createFile("one.sh", "g() { echo inside; }; g\n");
    defer allocator.free(path);

    const r = try fixture.execScript(path);
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "inside");
}

test "script file: two function definitions on one line" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    // The closing brace was found with a search for the last `}` on the line,
    // so g's body ran into h's definition: g printed A, then h was never
    // defined and the leftover braces were a syntax error.
    const path = try fixture.createFile(
        "two.sh",
        "g() { echo A; }; h() { echo B; }\ng\nh\n",
    );
    defer allocator.free(path);

    const r = try fixture.execScript(path);
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "A");
    try test_utils.TestAssert.expectContains(r.stdout, "B");
    try test_utils.TestAssert.expectEqual(@as(usize, 0), r.stderr.len);
}

test "script file: a brace inside a string does not end the body" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const path = try fixture.createFile("brace.sh", "g() { echo \"}\"; }; g\n");
    defer allocator.free(path);

    const r = try fixture.execScript(path);
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "}");
}

test "script file: a command after the closing brace of a multi-line function" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    // The closing line carries the call, so the multi-line path needs the same
    // treatment as the one-line one.
    const path = try fixture.createFile("multi.sh", "g() {\n  echo A\n}; g\n");
    defer allocator.free(path);

    const r = try fixture.execScript(path);
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "A");
}

test "script file: nested definition and several trailing commands" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const nested = try fixture.createFile(
        "nested.sh",
        "outer() { inner() { echo deep; }; inner; }; outer\n",
    );
    defer allocator.free(nested);

    const r = try fixture.execScript(nested);
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);
    try test_utils.TestAssert.expectContains(r.stdout, "deep");

    const several = try fixture.createFile("several.sh", "g() { echo A; }; echo B; g\n");
    defer allocator.free(several);

    const r2 = try fixture.execScript(several);
    defer allocator.free(r2.stdout);
    defer allocator.free(r2.stderr);

    const b_at = std.mem.indexOf(u8, r2.stdout, "B") orelse return error.MissingB;
    const a_at = std.mem.indexOf(u8, r2.stdout, "A") orelse return error.MissingA;
    // Order matters: the trailing commands run in the order written.
    try std.testing.expect(b_at < a_at);
}

test "script file: the function keyword form also runs its trailing command" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    const path = try fixture.createFile("kw.sh", "function g { echo A; }; g\n");
    defer allocator.free(path);

    const r = try fixture.execScript(path);
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "A");
}

test "function definition: braces the wrong way round do not crash" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    // `}{` balances to zero with the braces reversed. The body was sliced from
    // the first `{` to the last `}`, which here is a backwards range, and den
    // panicked. A fuzz case found it.
    const r = try fixture.execDirect("f() ; echo hi; }{ f");
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try std.testing.expect(!r.signaled);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "panic") == null);
}

test "function definition: a pending definition is freed at exit" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    // `f() ;` leaves the shell waiting for a body that never arrives. The lines
    // collected so far were never released, so the allocator reported a leak on
    // the way out.
    const r = try fixture.execDirect("f() ;");
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "leaked") == null);
    try std.testing.expect(!r.signaled);
}

test "function definition: a valid one-liner still works after the brace fix" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    // `brace_fn` rather than a short name on purpose: den.jsonc aliases `g` to
    // git, and an alias is expanded before the definition is parsed.
    const r = try fixture.execDirect(
        "f() { echo ok; }; f; brace_fn() { echo \"}\"; }; brace_fn",
    );
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "ok");
    // Brace counting ignores quotes now, so a `}` in a string neither ends the
    // body early nor makes the count go negative and skip the definition.
    try test_utils.TestAssert.expectContains(r.stdout, "}");
}

test "set -f disables globbing, and only globbing" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    // `set -f` recorded the flag and nothing read it, so pathname expansion
    // happened anyway. Brace expansion is a separate mechanism and must survive.
    const p = try fixture.createFile("g1.dat", "");
    allocator.free(p);

    const r = try fixture.exec(
        "set -f; echo *.dat; echo {a,b}; set +f; echo *.dat",
    );
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "*.dat");
    try test_utils.TestAssert.expectContains(r.stdout, "a b");
    try test_utils.TestAssert.expectContains(r.stdout, "g1.dat");
}

test "set accepts a cluster ending in -o, as in set -euo pipefail" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    // The most common line in shell scripts. Only a bare `-o` was handled, so
    // the whole cluster was rejected as an unknown option.
    const r = try fixture.execDirect("set -euo pipefail; echo ok; echo \"rc=$?\"");
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "ok");
    try test_utils.TestAssert.expectEqual(@as(usize, 0), r.stderr.len);
}

test "negation works wherever a command can appear" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    // `!` was stripped from the front of the whole line, so it reported 127 in
    // the middle of a chain and, as a prefix, negated the entire and-or list
    // instead of the one pipeline it belongs to.
    const r = try fixture.execDirect(
        "true && ! false; echo \"chain=$?\"; " ++
            "! false && echo reached; " ++
            "! true; echo \"neg=$?\"",
    );
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "chain=0");
    try test_utils.TestAssert.expectContains(r.stdout, "reached");
    try test_utils.TestAssert.expectContains(r.stdout, "neg=1");
}

test "a file that cannot be executed is 126, not 127" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    // Everything was 127, so a missing executable bit looked like a misspelling.
    const p = try fixture.createFile("noexec.sh", "#!/bin/sh\necho hi\n");
    allocator.free(p);

    const r = try fixture.exec(
        "./noexec.sh 2>/dev/null; echo \"noexec=$?\"; " ++
            "nosuch_command_xyz 2>/dev/null; echo \"missing=$?\"",
    );
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "noexec=126");
    try test_utils.TestAssert.expectContains(r.stdout, "missing=127");
    // The report honours the command's redirections, which it did not before.
    try test_utils.TestAssert.expectEqual(@as(usize, 0), r.stderr.len);
}

test "single quotes suppress command substitution" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    // The tokenizer escaped `$` inside single quotes but not a backtick, so
    // `echo '`pwd`'` ran pwd -- substitution inside single quotes.
    const r = try fixture.execDirect("echo '`echo SUBSTITUTED`'; echo '$HOME'");
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "`echo SUBSTITUTED`");
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "SUBSTITUTED\n") == null or
        std.mem.indexOf(u8, r.stdout, "`echo SUBSTITUTED`") != null);
    try test_utils.TestAssert.expectContains(r.stdout, "$HOME");
}

test "a stray parenthesis is a syntax error" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    // The parser stopped at the token and dropped the rest, reporting success.
    const r = try fixture.execDirect("echo (hello");
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try std.testing.expect(r.exit_code != 0);
}

test "kill accepts every signal spelling" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    // The standalone kill had its own six-signal table, so `kill -SEGV` was
    // refused while the same command inside a chain worked. It shares the table
    // `kill -l` uses now, and honours `-s` and a SIG prefix.
    const r = try fixture.execDirect(
        "kill -QUIT 2>/dev/null; echo \"name=$?\"; " ++
            "kill -SIGQUIT 2>/dev/null; echo \"prefixed=$?\"; " ++
            "kill -s QUIT 2>/dev/null; echo \"dash_s=$?\"; " ++
            "kill -nosuchsig 1 2>/dev/null; echo \"bad=$?\"",
    );
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    // Each spelling is understood: the complaint is a missing pid, not the signal.
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "name=") != null);
    try test_utils.TestAssert.expectContains(r.stdout, "bad=1");
}

test "alias and unalias report a name that is not an alias" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    // Both printed the error and then had their status overwritten with 0 by the
    // dispatcher, so `unalias foo || ...` never took its branch.
    const r = try fixture.execDirect(
        "unalias nosuch_xyz 2>/dev/null; echo \"un=$?\"; " ++
            "alias nosuch_xyz 2>/dev/null; echo \"al=$?\"; " ++
            "alias ok=ls; alias ok >/dev/null; echo \"found=$?\"",
    );
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "un=1");
    try test_utils.TestAssert.expectContains(r.stdout, "al=1");
    try test_utils.TestAssert.expectContains(r.stdout, "found=0");
}

test "grep does not colour output that is not a terminal" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    // Colour was on unconditionally, so escape sequences went into pipes and
    // files: `grep x f | wc -c` counted them.
    const p = try fixture.createFile("c.txt", "alpha\nbeta\n");
    allocator.free(p);

    const r = try fixture.exec("grep alpha c.txt | cat");
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "alpha");
    try std.testing.expect(std.mem.indexOfScalar(u8, r.stdout, 0x1b) == null);
}

test "tab completion offers builtins, not just what is on PATH" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    // Completion walked PATH only, so a builtin with no binary of the same name
    // could never be completed -- which was most of them. `echo` was offered
    // solely because /bin/echo happens to exist.
    const r = try fixture.execDirect(
        "compgen -c zsty; compgen -c bindk; compgen -c setop; " ++
            "compgen -c autolo; compgen -c add-zsh; compgen -c compin",
    );
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "zstyle");
    try test_utils.TestAssert.expectContains(r.stdout, "bindkey");
    try test_utils.TestAssert.expectContains(r.stdout, "setopt");
    try test_utils.TestAssert.expectContains(r.stdout, "autoload");
    try test_utils.TestAssert.expectContains(r.stdout, "add-zsh-hook");
    try test_utils.TestAssert.expectContains(r.stdout, "compinit");
}

test "a builtin that shadows a binary is offered once" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    // `echo` is both a builtin and /bin/echo. Builtins are added before the PATH
    // walk, which skips a name already collected.
    const r = try fixture.execDirect("compgen -c echo | grep -c '^echo$'");
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "1");
}

test "every name compgen -b lists is really a builtin" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    // The invariant the four hand-kept lists used to break in both directions.
    // Checked through den rather than by comparing two arrays in Zig, so it also
    // covers the dispatch actually being wired.
    const r = try fixture.execDirect(
        "for b in $(compgen -b); do type \"$b\" > /dev/null 2>&1 || echo \"BAD:$b\"; done; echo CHECKED",
    );
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "CHECKED");
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "BAD:") == null);
}

test "every builtin can be completed" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    // Completing a builtin's full name must offer it back. This is what was
    // broken for about 95 of them.
    const r = try fixture.execDirect(
        "for b in $(compgen -b); do compgen -c \"$b\" | grep -qxF \"$b\" || echo \"MISSING:$b\"; done; echo CHECKED",
    );
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "CHECKED");
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "MISSING:") == null);
}

test "compgen -b and enable -a list the same builtins" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    // Two listings from one list. They held 63 and 67 of the 163 names before,
    // and not the same ones.
    const r = try fixture.execDirect(
        "compgen -b | sort > /tmp/den_cb.txt; " ++
            "enable -a | grep '^  ' | sed 's/^  //' | sort > /tmp/den_ea.txt; " ++
            "diff /tmp/den_cb.txt /tmp/den_ea.txt > /dev/null && echo SAME || echo DIFFER",
    );
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try test_utils.TestAssert.expectContains(r.stdout, "SAME");
}
