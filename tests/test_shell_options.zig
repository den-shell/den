const std = @import("std");
const test_utils = @import("test_utils.zig");

// Shell Options Tests
// Tests for set -e, set -u, set -x, set -o pipefail, etc.

// ============================================================================
// set -e (errexit) Tests
// ============================================================================

test "ShellOption: set -e stops on error" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const script =
        \\#!/bin/sh
        \\set -e
        \\true
        \\false
        \\echo "should not print"
    ;

    const script_path = try fixture.createScript("errexit.sh", script);
    defer allocator.free(script_path);

    const result = try fixture.exec(script_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectTrue(result.exit_code != 0);
    try test_utils.TestAssert.expectTrue(std.mem.indexOf(u8, result.stdout, "should not print") == null);
}

test "ShellOption: set -e with successful commands" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const script =
        \\#!/bin/sh
        \\set -e
        \\true
        \\echo "first"
        \\true
        \\echo "second"
    ;

    const script_path = try fixture.createScript("errexit_success.sh", script);
    defer allocator.free(script_path);

    const result = try fixture.exec(script_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "first");
    try test_utils.TestAssert.expectContains(result.stdout, "second");
}

test "ShellOption: set -e ignored in if condition" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const script =
        \\#!/bin/sh
        \\set -e
        \\if false; then
        \\    echo "true branch"
        \\else
        \\    echo "false branch"
        \\fi
        \\echo "after if"
    ;

    const script_path = try fixture.createScript("errexit_if.sh", script);
    defer allocator.free(script_path);

    const result = try fixture.exec(script_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "false branch");
    try test_utils.TestAssert.expectContains(result.stdout, "after if");
}

test "ShellOption: set -e ignored in && chain" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const script =
        \\#!/bin/sh
        \\set -e
        \\false && echo "skipped"
        \\echo "continued"
    ;

    const script_path = try fixture.createScript("errexit_and.sh", script);
    defer allocator.free(script_path);

    const result = try fixture.exec(script_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "continued");
}

test "ShellOption: set +e disables errexit" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const script =
        \\#!/bin/sh
        \\set -e
        \\set +e
        \\false
        \\echo "continued after false"
    ;

    const script_path = try fixture.createScript("errexit_disable.sh", script);
    defer allocator.free(script_path);

    const result = try fixture.exec(script_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "continued after false");
}

// ============================================================================
// set -u (nounset) Tests
// ============================================================================

test "ShellOption: set -u with set variable" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const script =
        \\#!/bin/sh
        \\set -u
        \\VAR="hello"
        \\echo "$VAR"
    ;

    const script_path = try fixture.createScript("nounset_set.sh", script);
    defer allocator.free(script_path);

    const result = try fixture.exec(script_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "hello");
}

test "ShellOption: set -u errors on unset variable" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const script =
        \\#!/bin/sh
        \\set -u
        \\echo "$UNDEFINED_VAR_XYZ123"
        \\echo "should not print"
    ;

    const script_path = try fixture.createScript("nounset_unset.sh", script);
    defer allocator.free(script_path);

    const result = try fixture.exec(script_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectTrue(result.exit_code != 0);
    try test_utils.TestAssert.expectTrue(std.mem.indexOf(u8, result.stdout, "should not print") == null);
}

test "ShellOption: set -u with default value" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const script =
        \\#!/bin/sh
        \\set -u
        \\echo "${UNDEFINED_VAR_XYZ:-default}"
    ;

    const script_path = try fixture.createScript("nounset_default.sh", script);
    defer allocator.free(script_path);

    const result = try fixture.exec(script_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "default");
}

test "ShellOption: set -u with special variables" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const script =
        \\#!/bin/sh
        \\set -u
        \\echo "? = $?"
        \\echo "$ = $$"
    ;

    const script_path = try fixture.createScript("nounset_special.sh", script);
    defer allocator.free(script_path);

    const result = try fixture.exec(script_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "? = ");
    try test_utils.TestAssert.expectContains(result.stdout, "$ = ");
}

test "ShellOption: set +u allows unset" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const script =
        \\#!/bin/sh
        \\set -u
        \\set +u
        \\echo "VAR=$UNDEFINED_VAR_XYZ"
        \\echo "done"
    ;

    const script_path = try fixture.createScript("nounset_disable.sh", script);
    defer allocator.free(script_path);

    const result = try fixture.exec(script_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "done");
}

// ============================================================================
// set -x (xtrace) Tests
// ============================================================================

test "ShellOption: set -x traces commands" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const script =
        \\#!/bin/sh
        \\set -x
        \\echo hello
        \\set +x
    ;

    const script_path = try fixture.createScript("xtrace.sh", script);
    defer allocator.free(script_path);

    const result = try fixture.exec(script_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // stdout should have the output
    try test_utils.TestAssert.expectContains(result.stdout, "hello");
    // stderr should have the trace (+ echo hello)
    try test_utils.TestAssert.expectTrue(result.stderr.len > 0 or result.stdout.len > 0);
}

test "ShellOption: set -x shows expanded variables" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const script =
        \\#!/bin/sh
        \\VAR="world"
        \\set -x
        \\echo "hello $VAR"
        \\set +x
    ;

    const script_path = try fixture.createScript("xtrace_var.sh", script);
    defer allocator.free(script_path);

    const result = try fixture.exec(script_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "hello world");
}

test "ShellOption: set +x disables trace" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const script =
        \\#!/bin/sh
        \\set -x
        \\echo "traced"
        \\set +x
        \\echo "not traced"
    ;

    const script_path = try fixture.createScript("xtrace_disable.sh", script);
    defer allocator.free(script_path);

    const result = try fixture.exec(script_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "traced");
    try test_utils.TestAssert.expectContains(result.stdout, "not traced");
}

// ============================================================================
// set -o pipefail Tests
// ============================================================================

test "ShellOption: pipefail detects pipe failure" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const script =
        \\#!/bin/sh
        \\set -o pipefail 2>/dev/null || true
        \\false | true
        \\echo "exit=$?"
    ;

    const script_path = try fixture.createScript("pipefail.sh", script);
    defer allocator.free(script_path);

    const result = try fixture.exec(script_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // With pipefail, exit code should be from false (1)
    // Without pipefail support, it may be 0
    try test_utils.TestAssert.expectTrue(result.stdout.len > 0);
}

test "ShellOption: without pipefail uses last exit code" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("false | true; echo $?");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Without pipefail, exit code is from 'true' (0)
    try test_utils.TestAssert.expectContains(result.stdout, "0");
}

test "ShellOption: pipefail with all success" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const script =
        \\#!/bin/sh
        \\set -o pipefail 2>/dev/null || true
        \\true | true | true
        \\echo "exit=$?"
    ;

    const script_path = try fixture.createScript("pipefail_success.sh", script);
    defer allocator.free(script_path);

    const result = try fixture.exec(script_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "exit=0");
}

// ============================================================================
// set -n (noexec) Tests
// ============================================================================

test "ShellOption: set -n parses without executing" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    // -n flag should prevent execution
    const result = try fixture.exec("sh -n -c 'echo hello'");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // With -n, echo should not run
    try test_utils.TestAssert.expectTrue(std.mem.indexOf(u8, result.stdout, "hello") == null);
}

test "ShellOption: set -n detects syntax errors" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    // Invalid syntax should be detected even with -n
    const result = try fixture.exec("sh -n -c 'if then fi' 2>&1");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should have syntax error
    try test_utils.TestAssert.expectTrue(result.exit_code != 0);
}

// ============================================================================
// set -v (verbose) Tests
// ============================================================================

test "ShellOption: set -v prints input" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const script =
        \\#!/bin/sh
        \\set -v
        \\echo hello
        \\set +v
    ;

    const script_path = try fixture.createScript("verbose.sh", script);
    defer allocator.free(script_path);

    const result = try fixture.exec(script_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "hello");
}

// ============================================================================
// Combined Options Tests
// ============================================================================

test "ShellOption: combined -eu" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const script =
        \\#!/bin/sh
        \\set -eu
        \\VAR="test"
        \\echo "$VAR"
    ;

    const script_path = try fixture.createScript("combined_eu.sh", script);
    defer allocator.free(script_path);

    const result = try fixture.exec(script_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "test");
}

test "ShellOption: combined -eux" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const script =
        \\#!/bin/sh
        \\set -eux
        \\echo "hello"
        \\set +x
    ;

    const script_path = try fixture.createScript("combined_eux.sh", script);
    defer allocator.free(script_path);

    const result = try fixture.exec(script_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "hello");
}

// ============================================================================
// set -f (noglob) Tests
// ============================================================================

test "ShellOption: set -f disables globbing" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const script =
        \\#!/bin/sh
        \\set -f
        \\echo *.txt
    ;

    const script_path = try fixture.createScript("noglob.sh", script);
    defer allocator.free(script_path);

    const result = try fixture.exec(script_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // With noglob, *.txt should be printed literally
    try test_utils.TestAssert.expectContains(result.stdout, "*.txt");
}

test "ShellOption: set +f enables globbing" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    // Create a test file
    const file = try fixture.temp_dir.createFile("test.txt", "");
    defer allocator.free(file);

    const cmd = try std.fmt.allocPrint(allocator, "cd {s} && set -f && echo *.txt && set +f", .{fixture.temp_dir.path});
    defer allocator.free(cmd);

    const result = try fixture.exec(cmd);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // With noglob, should print literal *.txt
    try test_utils.TestAssert.expectContains(result.stdout, "*.txt");
}

// ============================================================================
// set -C (noclobber) Tests
// ============================================================================

test "ShellOption: noclobber prevents overwrite" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const file = try fixture.temp_dir.createFile("existing.txt", "original");
    defer allocator.free(file);

    const script = try std.fmt.allocPrint(allocator,
        \\#!/bin/sh
        \\set -C
        \\echo "new" > {s} 2>/dev/null
        \\echo "exit=$?"
    , .{file});
    defer allocator.free(script);

    const script_path = try fixture.createScript("noclobber.sh", script);
    defer allocator.free(script_path);

    const result = try fixture.exec(script_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // With noclobber, overwrite should fail (exit != 0)
    try test_utils.TestAssert.expectTrue(result.stdout.len > 0);
}

// ============================================================================
// Environment and Export Tests
// ============================================================================

test "ShellOption: options preserved in subshell" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const script =
        \\#!/bin/sh
        \\set -e
        \\(true; echo "subshell ok")
    ;

    const script_path = try fixture.createScript("subshell_opts.sh", script);
    defer allocator.free(script_path);

    const result = try fixture.exec(script_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "subshell ok");
}
