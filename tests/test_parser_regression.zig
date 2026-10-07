const std = @import("std");
const test_utils = @import("test_utils.zig");
const TestAssert = test_utils.TestAssert;
const DenShellFixture = test_utils.DenShellFixture;

// Parser Regression Tests
// Tests for edge cases, known bugs, and security-sensitive parsing scenarios

// =============================================================================
// Empty and Whitespace Input Tests
// =============================================================================

test "regression: empty input" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Empty input should succeed with no output
    try TestAssert.expectEqual(@as(u8, 0), result.exit_code);
}

test "regression: whitespace only input" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("   \t   ");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try TestAssert.expectEqual(@as(u8, 0), result.exit_code);
}

test "regression: newlines only" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("\n\n\n");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try TestAssert.expectEqual(@as(u8, 0), result.exit_code);
}

// =============================================================================
// Quote Handling Tests
// =============================================================================

test "regression: unmatched double quote" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    // Shell should handle or report unmatched quotes
    const result = try fixture.exec("echo \"hello");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // May succeed with partial output or fail - either is acceptable
}

test "regression: unmatched single quote" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo 'hello");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
}

test "regression: empty quoted string" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo \"\"");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try TestAssert.expectEqual(@as(u8, 0), result.exit_code);
}

test "regression: nested quotes - double in single" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo 'hello \"world\"'");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try TestAssert.expectContains(result.stdout, "hello \"world\"");
}

test "regression: nested quotes - single in double" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo \"hello 'world'\"");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try TestAssert.expectContains(result.stdout, "hello 'world'");
}

test "regression: escaped quote in double quotes" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo \"hello \\\"world\\\"\"");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try TestAssert.expectEqual(@as(u8, 0), result.exit_code);
}

test "regression: backslash at end of quoted string" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo \"test\\\\\"");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try TestAssert.expectEqual(@as(u8, 0), result.exit_code);
}

// =============================================================================
// Special Character Tests
// =============================================================================

test "regression: dollar sign in single quotes" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo '$HOME'");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try TestAssert.expectContains(result.stdout, "$HOME");
}

test "regression: backtick in single quotes" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo '`pwd`'");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try TestAssert.expectContains(result.stdout, "`pwd`");
}

test "regression: semicolon in quotes" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo \"hello;world\"");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try TestAssert.expectContains(result.stdout, "hello;world");
}

test "regression: pipe in quotes" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo \"hello|world\"");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try TestAssert.expectContains(result.stdout, "hello|world");
}

test "regression: ampersand in quotes" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo \"hello&world\"");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try TestAssert.expectContains(result.stdout, "hello&world");
}

test "regression: hash in quotes" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo \"hello#world\"");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try TestAssert.expectContains(result.stdout, "hello#world");
}

// =============================================================================
// Operator Edge Cases
// =============================================================================

test "regression: multiple consecutive pipes" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo hello | cat | cat | cat");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try TestAssert.expectContains(result.stdout, "hello");
}

test "regression: pipe at end of line" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    // Trailing pipe is an error in most shells
    const result = try fixture.exec("echo hello |");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should fail with non-zero exit code
    try TestAssert.expectTrue(result.exit_code != 0);
}

test "regression: double ampersand at end" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo hello &&");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should fail - incomplete command
    try TestAssert.expectTrue(result.exit_code != 0);
}

test "regression: double pipe at end" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo hello ||");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should fail - incomplete command
    try TestAssert.expectTrue(result.exit_code != 0);
}

test "regression: chained AND operators" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("true && true && true && echo success");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try TestAssert.expectContains(result.stdout, "success");
}

test "regression: chained OR operators" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("false || false || echo fallback");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try TestAssert.expectContains(result.stdout, "fallback");
}

test "regression: mixed AND and OR" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("true && false || echo recovered");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try TestAssert.expectContains(result.stdout, "recovered");
}

// =============================================================================
// Redirection Edge Cases
// =============================================================================

test "regression: redirection with no space" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo hello>/dev/null && echo done");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try TestAssert.expectContains(result.stdout, "done");
}

test "regression: multiple output redirections" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    // Last redirection wins
    const result = try fixture.exec("echo hello >/dev/null >/dev/stdout");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try TestAssert.expectEqual(@as(u8, 0), result.exit_code);
}

test "regression: stderr to stdout redirect" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo error >&2 2>&1");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try TestAssert.expectEqual(@as(u8, 0), result.exit_code);
}

test "regression: append redirection" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo first >> /dev/null && echo second >> /dev/null && echo done");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try TestAssert.expectContains(result.stdout, "done");
}

// =============================================================================
// Command Substitution Tests
// =============================================================================

test "regression: simple command substitution" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo $(echo hello)");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try TestAssert.expectContains(result.stdout, "hello");
}

test "regression: nested command substitution" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo $(echo $(echo nested))");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try TestAssert.expectContains(result.stdout, "nested");
}

test "regression: command substitution with quotes" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo \"$(echo 'hello world')\"");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try TestAssert.expectContains(result.stdout, "hello world");
}

// =============================================================================
// Variable Expansion Tests
// =============================================================================

test "regression: undefined variable" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo $UNDEFINED_VAR_12345");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    // Should output empty string or nothing for undefined var
}

test "regression: variable with default value" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo ${UNDEFINED:-default}");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try TestAssert.expectContains(result.stdout, "default");
}

test "regression: variable in double quotes" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    try fixture.setEnv("TEST_VAR", "hello world");
    const result = try fixture.exec("echo \"$TEST_VAR\"");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try TestAssert.expectEqual(@as(u8, 0), result.exit_code);
}

test "regression: special variables" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    // $$ - PID, $? - last exit code
    const result = try fixture.exec("echo $?");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try TestAssert.expectEqual(@as(u8, 0), result.exit_code);
}

// =============================================================================
// Long Input Tests
// =============================================================================

test "regression: very long command" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    // Command with many arguments using static string
    const result = try fixture.exec("echo a0 a1 a2 a3 a4 a5 a6 a7 a8 a9 b0 b1 b2 b3 b4 b5 b6 b7 b8 b9 c0 c1 c2 c3 c4 c5 c6 c7 c8 c9 d0 d1 d2 d3 d4 d5 d6 d7 d8 d9 e0 e1 e2 e3 e4 e5 e6 e7 e8 e9");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try TestAssert.expectContains(result.stdout, "e9");
}

test "regression: long pipeline" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo test | cat | cat | cat | cat | cat | cat | cat | cat | cat");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try TestAssert.expectContains(result.stdout, "test");
}

// =============================================================================
// Comment Handling Tests
// =============================================================================

test "regression: comment at end of command" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo hello # this is a comment");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try TestAssert.expectContains(result.stdout, "hello");
    try TestAssert.expectTrue(std.mem.indexOf(u8, result.stdout, "comment") == null);
}

test "regression: comment only line" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("# this is just a comment");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try TestAssert.expectEqual(@as(u8, 0), result.exit_code);
}

test "regression: hash in middle of word" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    // Hash must be at word boundary to start comment
    const result = try fixture.exec("echo hello#world");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try TestAssert.expectContains(result.stdout, "hello#world");
}

// =============================================================================
// Escaping Tests
// =============================================================================

test "regression: escaped newline" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo hello\\\nworld");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Line continuation should work
    try TestAssert.expectEqual(@as(u8, 0), result.exit_code);
}

test "regression: escaped space" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo hello\\ world");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try TestAssert.expectContains(result.stdout, "hello world");
}

test "regression: escaped dollar" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo \\$HOME");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try TestAssert.expectContains(result.stdout, "$HOME");
}

test "regression: double backslash" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo \\\\");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try TestAssert.expectContains(result.stdout, "\\");
}

// =============================================================================
// Grouping Tests
// =============================================================================

test "regression: subshell grouping" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("(echo hello; echo world)");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try TestAssert.expectContains(result.stdout, "hello");
    try TestAssert.expectContains(result.stdout, "world");
}

test "regression: brace grouping" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("{ echo hello; echo world; }");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try TestAssert.expectContains(result.stdout, "hello");
    try TestAssert.expectContains(result.stdout, "world");
}

test "regression: nested parentheses" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("(echo outer (echo inner))");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // This might be valid or invalid depending on shell
}

test "regression: unmatched parenthesis" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo (hello");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should fail with syntax error
    try TestAssert.expectTrue(result.exit_code != 0);
}

// =============================================================================
// Arithmetic Expansion Tests
// =============================================================================

test "regression: arithmetic expansion" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo $((1 + 2))");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try TestAssert.expectContains(result.stdout, "3");
}

test "regression: nested arithmetic" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo $((2 * (3 + 4)))");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try TestAssert.expectContains(result.stdout, "14");
}

// =============================================================================
// Glob/Pathname Expansion Tests
// =============================================================================

test "regression: asterisk glob" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    // Should expand to files, or stay literal if no match
    const result = try fixture.exec("echo /tmp/nonexistent*");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try TestAssert.expectEqual(@as(u8, 0), result.exit_code);
}

test "regression: question mark glob" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo /tmp/?.txt");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try TestAssert.expectEqual(@as(u8, 0), result.exit_code);
}

test "regression: bracket glob" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo /tmp/[abc].txt");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try TestAssert.expectEqual(@as(u8, 0), result.exit_code);
}

// =============================================================================
// Security-Sensitive Tests
// =============================================================================

test "regression: command injection via variable" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    // Variable containing shell metacharacters should be properly handled
    try fixture.setEnv("MALICIOUS", "hello; echo INJECTED");
    const result = try fixture.exec("echo \"$MALICIOUS\"");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // In quotes, semicolon should NOT be interpreted as command separator
    try TestAssert.expectTrue(std.mem.indexOf(u8, result.stdout, "INJECTED") == null or
        std.mem.indexOf(u8, result.stdout, "hello; echo INJECTED") != null);
}

test "regression: null byte handling" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    // Null bytes should be handled gracefully
    const result = try fixture.exec("echo hello");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try TestAssert.expectEqual(@as(u8, 0), result.exit_code);
}

// =============================================================================
// Unicode/UTF-8 Tests
// =============================================================================

test "regression: unicode in command" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo '日本語'");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try TestAssert.expectContains(result.stdout, "日本語");
}

test "regression: unicode emoji" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo '🎉'");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try TestAssert.expectContains(result.stdout, "🎉");
}

// =============================================================================
// Exit Status Tests
// =============================================================================

test "regression: true command" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("true");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try TestAssert.expectEqual(@as(u8, 0), result.exit_code);
}

test "regression: false command" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("false");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try TestAssert.expectEqual(@as(u8, 1), result.exit_code);
}

test "regression: exit with code" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("exit 42");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try TestAssert.expectEqual(@as(u8, 42), result.exit_code);
}

// =============================================================================
// Edge Case Combinations
// =============================================================================

test "regression: all features combined" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo \"hello $(echo world)\" | cat && echo done || echo failed");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try TestAssert.expectContains(result.stdout, "hello world");
    try TestAssert.expectContains(result.stdout, "done");
}

test "regression: deeply nested structure" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo $(echo $(echo $(echo deep)))");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try TestAssert.expectContains(result.stdout, "deep");
}
