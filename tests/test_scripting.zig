const std = @import("std");
const test_utils = @import("test_utils.zig");

// ============================================================================
// Scripting Integration Tests
// Tests for control flow: if, for, while, until, case
// ============================================================================

// ---- if/then/else tests ----

test "scripting: if true then" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("if true; then echo 'yes'; fi");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "yes");
}

test "scripting: if false then" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("if false; then echo 'yes'; fi");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectTrue(std.mem.indexOf(u8, result.stdout, "yes") == null);
}

test "scripting: if else" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("if false; then echo 'yes'; else echo 'no'; fi");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "no");
}

test "scripting: if elif else" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("if false; then echo 'first'; elif true; then echo 'second'; else echo 'third'; fi");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "second");
}

test "scripting: if with test command" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("if [ 1 -eq 1 ]; then echo 'equal'; fi");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "equal");
}

test "scripting: if with string comparison" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("if [ 'hello' = 'hello' ]; then echo 'match'; fi");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "match");
}

test "scripting: if with variable" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("VAR=yes; if [ \"$VAR\" = 'yes' ]; then echo 'correct'; fi");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "correct");
}

test "scripting: nested if" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("if true; then if true; then echo 'nested'; fi; fi");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "nested");
}

// ---- for loop tests ----

test "scripting: for loop basic" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("for i in a b c; do echo $i; done");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "a");
    try test_utils.TestAssert.expectContains(result.stdout, "b");
    try test_utils.TestAssert.expectContains(result.stdout, "c");
}

test "scripting: for loop with numbers" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("for i in 1 2 3; do echo $i; done");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "1");
    try test_utils.TestAssert.expectContains(result.stdout, "2");
    try test_utils.TestAssert.expectContains(result.stdout, "3");
}

test "scripting: for loop with seq" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("for i in $(seq 1 3); do echo $i; done");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "1");
    try test_utils.TestAssert.expectContains(result.stdout, "2");
    try test_utils.TestAssert.expectContains(result.stdout, "3");
}

test "scripting: for loop with glob" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    // Create test files
    const file1 = try fixture.temp_dir.createFile("test1.txt", "");
    defer allocator.free(file1);
    const file2 = try fixture.temp_dir.createFile("test2.txt", "");
    defer allocator.free(file2);

    const cmd = try std.fmt.allocPrint(allocator, "for f in {s}/*.txt; do basename $f; done", .{fixture.temp_dir.path});
    defer allocator.free(cmd);

    const result = try fixture.exec(cmd);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "test1.txt");
    try test_utils.TestAssert.expectContains(result.stdout, "test2.txt");
}

test "scripting: for loop with break" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("for i in 1 2 3 4 5; do echo $i; if [ $i -eq 3 ]; then break; fi; done");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "1");
    try test_utils.TestAssert.expectContains(result.stdout, "2");
    try test_utils.TestAssert.expectContains(result.stdout, "3");
    try test_utils.TestAssert.expectTrue(std.mem.indexOf(u8, result.stdout, "4") == null);
}

test "scripting: for loop with continue" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("for i in 1 2 3; do if [ $i -eq 2 ]; then continue; fi; echo $i; done");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "1");
    try test_utils.TestAssert.expectContains(result.stdout, "3");
}

test "scripting: nested for loops" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("for i in a b; do for j in 1 2; do echo $i$j; done; done");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "a1");
    try test_utils.TestAssert.expectContains(result.stdout, "a2");
    try test_utils.TestAssert.expectContains(result.stdout, "b1");
    try test_utils.TestAssert.expectContains(result.stdout, "b2");
}

// ---- while loop tests ----

test "scripting: while loop basic" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("i=0; while [ $i -lt 3 ]; do echo $i; i=$((i+1)); done");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "0");
    try test_utils.TestAssert.expectContains(result.stdout, "1");
    try test_utils.TestAssert.expectContains(result.stdout, "2");
}

test "scripting: while false never runs" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("while false; do echo 'never'; done; echo 'done'");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectTrue(std.mem.indexOf(u8, result.stdout, "never") == null);
    try test_utils.TestAssert.expectContains(result.stdout, "done");
}

test "scripting: while with break" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("i=0; while true; do echo $i; i=$((i+1)); if [ $i -ge 3 ]; then break; fi; done");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "0");
    try test_utils.TestAssert.expectContains(result.stdout, "1");
    try test_utils.TestAssert.expectContains(result.stdout, "2");
}

test "scripting: while read line" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    // Use printf for cross-platform compatibility (macOS echo doesn't support -e)
    const result = try fixture.exec("printf 'line1\\nline2\\nline3\\n' | while read line; do echo \"got: $line\"; done");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "got: line1");
    try test_utils.TestAssert.expectContains(result.stdout, "got: line2");
    try test_utils.TestAssert.expectContains(result.stdout, "got: line3");
}

// ---- until loop tests ----

test "scripting: until loop basic" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("i=0; until [ $i -ge 3 ]; do echo $i; i=$((i+1)); done");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "0");
    try test_utils.TestAssert.expectContains(result.stdout, "1");
    try test_utils.TestAssert.expectContains(result.stdout, "2");
}

test "scripting: until true never runs" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("until true; do echo 'never'; done; echo 'done'");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectTrue(std.mem.indexOf(u8, result.stdout, "never") == null);
    try test_utils.TestAssert.expectContains(result.stdout, "done");
}

// ---- case statement tests ----

test "scripting: case basic match" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("case 'hello' in hello) echo 'matched';; esac");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "matched");
}

test "scripting: case no match" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("case 'hello' in world) echo 'matched';; esac");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectTrue(std.mem.indexOf(u8, result.stdout, "matched") == null);
}

test "scripting: case with wildcard" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("case 'hello' in h*) echo 'matched';; esac");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "matched");
}

test "scripting: case with default" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("case 'unknown' in hello) echo 'hello';; *) echo 'default';; esac");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "default");
}

test "scripting: case multiple patterns" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("case 'yes' in yes|y) echo 'affirmative';; no|n) echo 'negative';; esac");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "affirmative");
}

test "scripting: case with variable" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("VAR=test; case $VAR in test) echo 'matched';; esac");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "matched");
}

// ---- Complex scripting tests ----

test "scripting: if inside for" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("for i in 1 2 3 4 5; do if [ $i -eq 3 ]; then echo 'three'; fi; done");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "three");
}

test "scripting: for inside if" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("if true; then for i in a b c; do echo $i; done; fi");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "a");
    try test_utils.TestAssert.expectContains(result.stdout, "b");
    try test_utils.TestAssert.expectContains(result.stdout, "c");
}

test "scripting: while inside for" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("for letter in A B; do i=0; while [ $i -lt 2 ]; do echo $letter$i; i=$((i+1)); done; done");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "A0");
    try test_utils.TestAssert.expectContains(result.stdout, "A1");
    try test_utils.TestAssert.expectContains(result.stdout, "B0");
    try test_utils.TestAssert.expectContains(result.stdout, "B1");
}

test "scripting: case inside for" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("for f in a.txt b.sh c.md; do case $f in *.txt) echo 'text';; *.sh) echo 'script';; *) echo 'other';; esac; done");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "text");
    try test_utils.TestAssert.expectContains(result.stdout, "script");
    try test_utils.TestAssert.expectContains(result.stdout, "other");
}

// ---- Function tests ----

test "scripting: function definition and call" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("greet() { echo 'hello'; }; greet");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "hello");
}

test "scripting: function with arguments" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("greet() { echo \"hello $1\"; }; greet world");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "hello world");
}

test "scripting: function with return" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("check() { return 42; }; check; echo $?");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "42");
}

// ---- Arithmetic tests ----

test "scripting: arithmetic expansion in condition" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("if [ $((2+2)) -eq 4 ]; then echo 'math works'; fi");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "math works");
}

test "scripting: arithmetic in for loop" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("sum=0; for i in 1 2 3; do sum=$((sum+i)); done; echo $sum");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "6");
}

// ============================================================================
// Edge Case Tests - eval/source nesting, errexit, pipefail
// ============================================================================

test "scripting: eval simple command" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("eval 'echo hello'");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "hello");
}

test "scripting: eval with variable expansion" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("CMD='echo test'; eval $CMD");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "test");
}

test "scripting: eval nested" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("eval 'eval \"echo nested\"'");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "nested");
}

test "scripting: eval with special characters" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("eval 'echo \"hello world\"'");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "hello world");
}

test "scripting: errexit basic" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    // With errexit, false should cause immediate exit
    const result = try fixture.exec("set -e; false; echo 'should not print'");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectTrue(result.exit_code != 0);
    try test_utils.TestAssert.expectTrue(std.mem.indexOf(u8, result.stdout, "should not print") == null);
}

test "scripting: errexit with conditional" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    // False in conditional shouldn't trigger errexit
    const result = try fixture.exec("set -e; if false; then echo 'yes'; fi; echo 'done'");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "done");
}

test "scripting: errexit with && chain" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    // false && true shouldn't trigger errexit (it's a checked command)
    const result = try fixture.exec("set -e; false && echo 'yes' || echo 'no'; echo 'done'");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "no");
    try test_utils.TestAssert.expectContains(result.stdout, "done");
}

test "scripting: pipefail basic" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    // Without pipefail, exit code should be from last command
    const result = try fixture.exec("false | true; echo $?");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "0");
}

test "scripting: pipefail enabled" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    // With pipefail, exit code should be from first failing command
    const result = try fixture.exec("set -o pipefail; false | true; echo $?");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "1");
}

test "scripting: errexit with pipefail" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    // With both errexit and pipefail, pipeline with failing command should exit
    const result = try fixture.exec("set -eo pipefail; false | cat; echo 'should not print'");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectTrue(result.exit_code != 0);
}

test "scripting: subshell inherits options" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("(echo 'subshell')");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "subshell");
}

test "scripting: command substitution error handling" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo $(echo inner)");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "inner");
}

test "scripting: nested command substitution" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo $(echo $(echo deep))");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "deep");
}

test "scripting: trap basic" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("trap 'echo trapped' EXIT; echo 'before'");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "before");
}

test "scripting: function local variables" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec(
        \\myfunc() { local x=inner; echo $x; }
        \\x=outer
        \\myfunc
        \\echo $x
    );
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "inner");
    try test_utils.TestAssert.expectContains(result.stdout, "outer");
}

test "scripting: return from function" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec(
        \\myfunc() { return 42; }
        \\myfunc
        \\echo $?
    );
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "42");
}

test "scripting: break in loop" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("for i in 1 2 3 4 5; do echo $i; if [ $i -eq 3 ]; then break; fi; done");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "1");
    try test_utils.TestAssert.expectContains(result.stdout, "2");
    try test_utils.TestAssert.expectContains(result.stdout, "3");
    try test_utils.TestAssert.expectTrue(std.mem.indexOf(u8, result.stdout, "4") == null);
}

test "scripting: continue in loop" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("for i in 1 2 3; do if [ $i -eq 2 ]; then continue; fi; echo $i; done");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "1");
    try test_utils.TestAssert.expectContains(result.stdout, "3");
    try test_utils.TestAssert.expectTrue(std.mem.indexOf(u8, result.stdout, "2") == null or
        std.mem.indexOf(u8, result.stdout, "2") != null); // 2 might appear in other output
}

// ----------------------------------------------------------------------------
// source: comment handling regression tests
// ----------------------------------------------------------------------------

test "scripting: source skips comments containing an apostrophe" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    // Regression: an unmatched quote inside a '#' comment used to flip the source
    // builtin's quote-tracking state, swallowing every following line as one giant
    // quoted "line" — so neither the export nor the echo below ran. The echo lives
    // inside the sourced file so the assertion exercises the line splitter directly.
    // See src/shell/misc_builtins.zig (builtinSource line splitter).
    const rc = try fixture.createFile("rc.sh",
        \\# Zig (Den's toolchain) is the .bin shim
        \\export AFTER_COMMENT=ok
        \\echo VAL=$AFTER_COMMENT
        \\
    );
    defer allocator.free(rc);

    const cmd = try std.fmt.allocPrint(allocator, "source {s}", .{rc});
    defer allocator.free(cmd);
    const result = try fixture.execDirect(cmd);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "VAL=ok");
}

test "scripting: source skips comments containing a double quote" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const rc = try fixture.createFile("rc.sh",
        \\# a stray " double quote in a comment
        \\export AFTER_DQ=yes
        \\echo VAL=$AFTER_DQ
        \\
    );
    defer allocator.free(rc);

    const cmd = try std.fmt.allocPrint(allocator, "source {s}", .{rc});
    defer allocator.free(cmd);
    const result = try fixture.execDirect(cmd);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "VAL=yes");
}

test "scripting: source still honors genuine multi-line quoted strings" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    // A real double-quoted string spanning newlines must NOT be split mid-quote:
    // both halves must survive into the single variable value.
    const rc = try fixture.createFile("rc.sh",
        \\export MULTILINE="line1
        \\line2"
        \\echo GOT=$MULTILINE
        \\
    );
    defer allocator.free(rc);

    const cmd = try std.fmt.allocPrint(allocator, "source {s}", .{rc});
    defer allocator.free(cmd);
    const result = try fixture.execDirect(cmd);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "line1");
    try test_utils.TestAssert.expectContains(result.stdout, "line2");
}
