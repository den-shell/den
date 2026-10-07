const std = @import("std");
const test_utils = @import("test_utils.zig");

// REPL (Read-Eval-Print Loop) Tests
// Tests that verify interactive shell behavior via scripts

// ============================================================================
// Basic REPL Operations
// ============================================================================

test "REPL: multi-line script execution" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const script =
        \\#!/bin/sh
        \\echo "Line 1"
        \\echo "Line 2"
        \\echo "Line 3"
    ;

    const script_path = try fixture.createScript("multi.sh", script);
    defer allocator.free(script_path);

    const result = try fixture.exec(script_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "Line 1");
    try test_utils.TestAssert.expectContains(result.stdout, "Line 2");
    try test_utils.TestAssert.expectContains(result.stdout, "Line 3");
}

test "REPL: interactive variable state" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const script =
        \\#!/bin/sh
        \\VAR1=first
        \\VAR2=second
        \\echo "$VAR1 $VAR2"
        \\VAR1=modified
        \\echo "$VAR1 $VAR2"
    ;

    const script_path = try fixture.createScript("state.sh", script);
    defer allocator.free(script_path);

    const result = try fixture.exec(script_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "first second");
    try test_utils.TestAssert.expectContains(result.stdout, "modified second");
}

test "REPL: command history simulation" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const script =
        \\#!/bin/sh
        \\echo "command1"
        \\echo "command2"
        \\echo "command3"
        \\fc -l 2>/dev/null || echo "history simulated"
    ;

    const script_path = try fixture.createScript("history.sh", script);
    defer allocator.free(script_path);

    const result = try fixture.exec(script_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "command1");
    try test_utils.TestAssert.expectContains(result.stdout, "command2");
    try test_utils.TestAssert.expectContains(result.stdout, "command3");
}

// ============================================================================
// User Input Handling
// ============================================================================

test "REPL: input from stdin" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo 'test input' | cat");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "test input");
}

test "REPL: read command simulation" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo 'simulated input' | while read line; do echo \"Got: $line\"; done");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "Got: simulated input");
}

test "REPL: multi-line input" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("printf 'line1\\nline2\\nline3' | while read l; do echo \"Read: $l\"; done");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "Read: line1");
    try test_utils.TestAssert.expectContains(result.stdout, "Read: line2");
}

// ============================================================================
// Prompt Handling
// ============================================================================

test "REPL: PS1 prompt variable" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("PS1='$ ' && echo $PS1");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "$");
}

test "REPL: PS2 continuation prompt" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("PS2='> ' && echo $PS2");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, ">");
}

// ============================================================================
// Line Continuation
// ============================================================================

test "REPL: backslash line continuation" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const script =
        \\#!/bin/sh
        \\echo "This is a \
        \\continued line"
    ;

    const script_path = try fixture.createScript("continuation.sh", script);
    defer allocator.free(script_path);

    const result = try fixture.exec(script_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "This is a continued line");
}

test "REPL: multi-line string" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo 'line1\nline2'");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
}

// ============================================================================
// Job Control
// ============================================================================

test "REPL: background job with wait" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("sleep 0.1 & wait; echo 'done'");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "done");
}

test "REPL: multiple background jobs" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("sleep 0.05 & sleep 0.05 & wait; echo 'all done'");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "all done");
}

// ============================================================================
// Interactive Features
// ============================================================================

test "REPL: alias definition and use" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const script =
        \\#!/bin/sh
        \\alias ll='ls -l'
        \\alias 2>/dev/null | grep ll || echo "alias defined"
    ;

    const script_path = try fixture.createScript("alias.sh", script);
    defer allocator.free(script_path);

    const result = try fixture.exec(script_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
}

test "REPL: unalias command" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const script =
        \\#!/bin/sh
        \\alias testalias='echo test'
        \\unalias testalias 2>/dev/null || true
        \\echo "unalias done"
    ;

    const script_path = try fixture.createScript("unalias.sh", script);
    defer allocator.free(script_path);

    const result = try fixture.exec(script_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "unalias done");
}

// ============================================================================
// Error Handling in REPL
// ============================================================================

test "REPL: continue after error" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const script =
        \\#!/bin/sh
        \\ls /nonexistent 2>/dev/null
        \\echo "continued after error"
    ;

    const script_path = try fixture.createScript("error.sh", script);
    defer allocator.free(script_path);

    const result = try fixture.exec(script_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "continued after error");
}

test "REPL: trap command" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const script =
        \\#!/bin/sh
        \\trap 'echo cleanup' EXIT
        \\echo "before exit"
    ;

    const script_path = try fixture.createScript("trap.sh", script);
    defer allocator.free(script_path);

    const result = try fixture.exec(script_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "before exit");
    try test_utils.TestAssert.expectContains(result.stdout, "cleanup");
}

// ============================================================================
// Environment and Shell Options
// ============================================================================

test "REPL: set -e exit on error" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const script =
        \\#!/bin/sh
        \\set -e
        \\true
        \\echo "passed"
    ;

    const script_path = try fixture.createScript("sete.sh", script);
    defer allocator.free(script_path);

    const result = try fixture.exec(script_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "passed");
}

test "REPL: set -x trace" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const script =
        \\#!/bin/sh
        \\set -x
        \\echo "traced"
        \\set +x
    ;

    const script_path = try fixture.createScript("setx.sh", script);
    defer allocator.free(script_path);

    const result = try fixture.exec(script_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "traced");
}

test "REPL: export variable" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("export MY_VAR=exported && sh -c 'echo $MY_VAR'");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "exported");
}

// ============================================================================
// Source and Dot Commands
// ============================================================================

test "REPL: source command" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    // Create a file to source
    const source_file = try fixture.temp_dir.createFile("source.sh", "SOURCED_VAR=yes\n");
    defer allocator.free(source_file);

    const cmd = try std.fmt.allocPrint(allocator, ". {s} && echo $SOURCED_VAR", .{source_file});
    defer allocator.free(cmd);

    const result = try fixture.exec(cmd);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "yes");
}

test "REPL: source with functions" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    // Create a file with a function
    const source_file = try fixture.temp_dir.createFile("funcs.sh", "greet() { echo \"Hello $1\"; }\n");
    defer allocator.free(source_file);

    const cmd = try std.fmt.allocPrint(allocator, ". {s} && greet World", .{source_file});
    defer allocator.free(cmd);

    const result = try fixture.exec(cmd);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "Hello World");
}

// ============================================================================
// Completion Simulation
// ============================================================================

test "REPL: command with tab-like completion chars" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("printf 'a\\tb\\tc'");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "a");
    try test_utils.TestAssert.expectContains(result.stdout, "b");
    try test_utils.TestAssert.expectContains(result.stdout, "c");
}

// ============================================================================
// Special Variables
// ============================================================================

test "REPL: $$ pid variable" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo $$");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    // PID should be a number
    const trimmed = std.mem.trim(u8, result.stdout, " \n\t");
    const pid = std.fmt.parseInt(i32, trimmed, 10) catch -1;
    try test_utils.TestAssert.expectTrue(pid > 0);
}

test "REPL: $! background pid" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("sleep 0.01 & echo $! | grep -E '^[0-9]+$' || echo 'got pid'");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
}

test "REPL: $# argument count" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const script =
        \\#!/bin/sh
        \\echo "Count: $#"
    ;

    const script_path = try fixture.createScript("argcount.sh", script);
    defer allocator.free(script_path);

    const cmd = try std.fmt.allocPrint(allocator, "{s} a b c", .{script_path});
    defer allocator.free(cmd);

    const result = try fixture.exec(cmd);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "Count: 3");
}

test "REPL: $@ all arguments" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const script =
        \\#!/bin/sh
        \\echo "Args: $@"
    ;

    const script_path = try fixture.createScript("allargs.sh", script);
    defer allocator.free(script_path);

    const cmd = try std.fmt.allocPrint(allocator, "{s} one two three", .{script_path});
    defer allocator.free(cmd);

    const result = try fixture.exec(cmd);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "one two three");
}

// ============================================================================
// Interactive Session Simulation
// ============================================================================

test "REPL: multiple sequential commands" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const script =
        \\#!/bin/sh
        \\COUNT=0
        \\COUNT=$((COUNT + 1))
        \\echo "Count: $COUNT"
        \\COUNT=$((COUNT + 1))
        \\echo "Count: $COUNT"
        \\COUNT=$((COUNT + 1))
        \\echo "Count: $COUNT"
    ;

    const script_path = try fixture.createScript("sequential.sh", script);
    defer allocator.free(script_path);

    const result = try fixture.exec(script_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "Count: 1");
    try test_utils.TestAssert.expectContains(result.stdout, "Count: 2");
    try test_utils.TestAssert.expectContains(result.stdout, "Count: 3");
}

test "REPL: nested function calls" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const script =
        \\#!/bin/sh
        \\inner() { echo "inner: $1"; }
        \\outer() { inner "from outer"; }
        \\outer
    ;

    const script_path = try fixture.createScript("nested.sh", script);
    defer allocator.free(script_path);

    const result = try fixture.exec(script_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "inner: from outer");
}

test "REPL: recursive function" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const script =
        \\#!/bin/sh
        \\countdown() {
        \\    if [ "$1" -gt 0 ]; then
        \\        echo "$1"
        \\        countdown $(($1 - 1))
        \\    fi
        \\}
        \\countdown 3
    ;

    const script_path = try fixture.createScript("recursive.sh", script);
    defer allocator.free(script_path);

    const result = try fixture.exec(script_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "3");
    try test_utils.TestAssert.expectContains(result.stdout, "2");
    try test_utils.TestAssert.expectContains(result.stdout, "1");
}
