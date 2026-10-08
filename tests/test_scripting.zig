const std = @import("std");
const test_utils = @import("test_utils.zig");

// ============================================================================
// Scripting Integration Tests
// Tests for control flow: if, for, while, until, case
// ============================================================================

// ---- if/then/else tests ----

test "scripting: if true then" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("if true; then echo 'yes'; fi");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "yes");
}

test "scripting: if false then" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("if false; then echo 'yes'; fi");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectTrue(std.mem.indexOf(u8, result.stdout, "yes") == null);
}

test "scripting: if else" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("if false; then echo 'yes'; else echo 'no'; fi");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "no");
}

test "scripting: if elif else" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("if false; then echo 'first'; elif true; then echo 'second'; else echo 'third'; fi");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "second");
}

test "scripting: if with test command" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("if [ 1 -eq 1 ]; then echo 'equal'; fi");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "equal");
}

test "scripting: if with string comparison" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("if [ 'hello' = 'hello' ]; then echo 'match'; fi");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "match");
}

test "scripting: if with variable" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("VAR=yes; if [ \"$VAR\" = 'yes' ]; then echo 'correct'; fi");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "correct");
}

test "scripting: nested if" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
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

    var fixture = try test_utils.DenShellFixture.init(allocator);
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

    var fixture = try test_utils.DenShellFixture.init(allocator);
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

    var fixture = try test_utils.DenShellFixture.init(allocator);
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

    var fixture = try test_utils.DenShellFixture.init(allocator);
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

    var fixture = try test_utils.DenShellFixture.init(allocator);
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

    var fixture = try test_utils.DenShellFixture.init(allocator);
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

    var fixture = try test_utils.DenShellFixture.init(allocator);
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

    var fixture = try test_utils.DenShellFixture.init(allocator);
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

    var fixture = try test_utils.DenShellFixture.init(allocator);
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

    var fixture = try test_utils.DenShellFixture.init(allocator);
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

    var fixture = try test_utils.DenShellFixture.init(allocator);
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

    var fixture = try test_utils.DenShellFixture.init(allocator);
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

    var fixture = try test_utils.DenShellFixture.init(allocator);
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

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("case 'hello' in hello) echo 'matched';; esac");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "matched");
}

test "scripting: case no match" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("case 'hello' in world) echo 'matched';; esac");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectTrue(std.mem.indexOf(u8, result.stdout, "matched") == null);
}

test "scripting: case with wildcard" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("case 'hello' in h*) echo 'matched';; esac");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "matched");
}

test "scripting: case with default" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("case 'unknown' in hello) echo 'hello';; *) echo 'default';; esac");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "default");
}

test "scripting: case multiple patterns" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("case 'yes' in yes|y) echo 'affirmative';; no|n) echo 'negative';; esac");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "affirmative");
}

test "scripting: case with variable" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
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

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("for i in 1 2 3 4 5; do if [ $i -eq 3 ]; then echo 'three'; fi; done");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "three");
}

test "scripting: for inside if" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
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

    var fixture = try test_utils.DenShellFixture.init(allocator);
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

    var fixture = try test_utils.DenShellFixture.init(allocator);
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

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("greet() { echo 'hello'; }; greet");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "hello");
}

test "scripting: function with arguments" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("greet() { echo \"hello $1\"; }; greet world");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "hello world");
}

test "scripting: function with return" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("check() { return 42; }; check; echo $?");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "42");
}

// ---- Arithmetic tests ----

test "scripting: arithmetic expansion in condition" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("if [ $((2+2)) -eq 4 ]; then echo 'math works'; fi");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "math works");
}

test "scripting: arithmetic in for loop" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
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

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("eval 'echo hello'");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "hello");
}

test "scripting: eval with variable expansion" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("CMD='echo test'; eval $CMD");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "test");
}

test "scripting: eval nested" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("eval 'eval \"echo nested\"'");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "nested");
}

test "scripting: eval with special characters" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("eval 'echo \"hello world\"'");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "hello world");
}

test "scripting: errexit basic" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
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

    var fixture = try test_utils.DenShellFixture.init(allocator);
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

    var fixture = try test_utils.DenShellFixture.init(allocator);
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

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    // Without pipefail, exit code should be from last command
    const result = try fixture.exec("false | true; echo $?");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "0");
}

test "scripting: pipefail enabled" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    // With pipefail, exit code should be from first failing command
    const result = try fixture.exec("set -o pipefail; false | true; echo $?");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "1");
}

test "scripting: errexit with pipefail" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    // With both errexit and pipefail, pipeline with failing command should exit
    const result = try fixture.exec("set -eo pipefail; false | cat; echo 'should not print'");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectTrue(result.exit_code != 0);
}

test "scripting: subshell inherits options" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("(echo 'subshell')");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "subshell");
}

test "scripting: command substitution error handling" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo $(echo inner)");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "inner");
}

test "scripting: nested command substitution" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo $(echo $(echo deep))");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "deep");
}

test "scripting: trap basic" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("trap 'echo trapped' EXIT; echo 'before'");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "before");
}

test "scripting: function local variables" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
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

    var fixture = try test_utils.DenShellFixture.init(allocator);
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

    var fixture = try test_utils.DenShellFixture.init(allocator);
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

    var fixture = try test_utils.DenShellFixture.init(allocator);
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

// ----------------------------------------------------------------------------
// Deferred per-segment expansion in command chains
//
// Variable/brace/glob expansion is applied to each segment of a chain
// (&&, ||, ;) at execution time, not up-front for the whole chain. This makes
// a variable set in an earlier segment visible to a later one. These tests run
// the real den binary (DenShellFixture) because they verify den-specific
// timing — DenShellFixture.exec would run system /bin/sh and always pass.
// ----------------------------------------------------------------------------

test "scripting: variable set in earlier && segment is visible to later segment" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.execDirect("export FOO=bar && echo GOT=$FOO");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "GOT=bar");
}

test "scripting: variable set in earlier ; segment is visible to later segment" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.execDirect("BAZ=qux; echo VAL=$BAZ");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "VAL=qux");
}

test "scripting: env accumulates across three chained segments" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.execDirect("export A=1 && export B=2 && echo RES=$A$B");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "RES=12");
}

test "scripting: source with multi-line quoted value works inside a chain" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    // The quoted value spans two physical lines. A naive split-on-\n would
    // execute the second line ("line2\"") as a bogus command. This runs through
    // the executor → script_manager path (vs. the shell builtinSource path that
    // the single-command source tests above exercise).
    const script_path = try fixture.createFile("multi.sh", "export MULTI=\"line1\nline2\"\necho DONE=$MULTI\n");
    defer allocator.free(script_path);

    // fixture.exec prefixes `cd <tmpdir> &&`, so `source` runs as the second
    // segment of a chain (executor path → script_manager.executeScript).
    const result = try fixture.exec("source multi.sh");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "DONE=line1 line2");
    try test_utils.TestAssert.expectTrue(std.mem.indexOf(u8, result.stderr, "command not found") == null);
}

// ----------------------------------------------------------------------------
// Single-line function definitions
//
// Regression: `f(){ echo hi; }; f` was split at the body semicolon because the
// top-level separator scanner didn't treat `{` right after `)` as a brace-group
// opener, so the body's `;` counted as a top-level split and `}` ran as a
// command ("den: }: command not found").
// ----------------------------------------------------------------------------

test "scripting: single-line function definition with body semicolon" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.execDirect("f(){ echo hi; }; f");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "hi");
    try test_utils.TestAssert.expectTrue(std.mem.indexOf(u8, result.stderr, "command not found") == null);
}

test "scripting: single-line function with local and multiple statements" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.execDirect("g(){ local x=5; echo a; echo $x; }; g");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "a");
    try test_utils.TestAssert.expectContains(result.stdout, "5");
}

// ----------------------------------------------------------------------------
// case statement fall-through terminators (bash 4): ;& and ;;&
//
// ;&  runs the NEXT clause's body unconditionally (fall through).
// ;;& continues testing subsequent patterns after a match.
// Regression: the one-liner splitter only understood ;; — ;& and ;;& were
// mis-split, producing an "empty command" error. These run the real den binary
// (DenShellFixture) because system /bin/sh also supports the syntax and would
// mask a den-side regression.
// ----------------------------------------------------------------------------

test "scripting: case ;& falls through to next clause body" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.execDirect("case x in x) echo a;& *) echo b;; esac");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    // Both bodies run, in order: matched clause then the fall-through clause.
    try test_utils.TestAssert.expectContains(result.stdout, "a");
    try test_utils.TestAssert.expectContains(result.stdout, "b");
    const a_pos = std.mem.indexOf(u8, result.stdout, "a").?;
    const b_pos = std.mem.indexOf(u8, result.stdout, "b").?;
    try test_utils.TestAssert.expectTrue(a_pos < b_pos);
}

test "scripting: case ;;& keeps testing later patterns" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.execDirect("case x in x) echo one;;& x) echo two;; esac");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "one");
    try test_utils.TestAssert.expectContains(result.stdout, "two");
    const one_pos = std.mem.indexOf(u8, result.stdout, "one").?;
    const two_pos = std.mem.indexOf(u8, result.stdout, "two").?;
    try test_utils.TestAssert.expectTrue(one_pos < two_pos);
}

test "scripting: plain case ;; still stops after the first match" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.execDirect("case x in x) echo a;; *) echo b;; esac");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "a");
    try test_utils.TestAssert.expectTrue(std.mem.indexOf(u8, result.stdout, "b") == null);
}

test "scripting: multi-line case ;& and ;;& terminators" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.execDirect(
        \\case x in
        \\  x) echo one;;&
        \\  x) echo two;&
        \\  *) echo three;;
        \\esac
    );
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // ;;& re-tests (matches the second x), then ;& falls through to the wildcard.
    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "one");
    try test_utils.TestAssert.expectContains(result.stdout, "two");
    try test_utils.TestAssert.expectContains(result.stdout, "three");
}

// ----------------------------------------------------------------------------
// for loop with no `in` list iterates the positional parameters ("$@")
// ----------------------------------------------------------------------------

test "scripting: for without in iterates positional parameters" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.execDirect("set -- p q r; for w; do echo \"i=$w\"; done");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "i=p");
    try test_utils.TestAssert.expectContains(result.stdout, "i=q");
    try test_utils.TestAssert.expectContains(result.stdout, "i=r");
}

// ----------------------------------------------------------------------------
// ${#} expands to the positional-parameter count (same as $#)
// ----------------------------------------------------------------------------

test "scripting: ${#} expands to the positional-parameter count" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.execDirect("set -- a b c d; echo \"count=${#}\"");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "count=4");
}

// ----------------------------------------------------------------------------
// "$*" joins the positional parameters with the first character of IFS
// ----------------------------------------------------------------------------

test "scripting: double-quoted $* joins on first IFS char" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.execDirect("set -- a b c; IFS=-; echo \"$*\"");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "a-b-c");
}

// ----------------------------------------------------------------------------
// Multi-segment glob: wildcards in intermediate path components
// ----------------------------------------------------------------------------

test "scripting: glob expands wildcards across multiple path segments" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    // exec() prefixes `cd <tmpdir> &&`, so the tree and the relative glob both
    // resolve inside the isolated temp dir.
    const result = try fixture.exec("mkdir -p a/b c/b && touch a/b/x.txt c/b/y.txt && echo */b/*.txt");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "a/b/x.txt");
    try test_utils.TestAssert.expectContains(result.stdout, "c/b/y.txt");
    // The literal pattern must not survive (i.e. it actually matched).
    try test_utils.TestAssert.expectTrue(std.mem.indexOf(u8, result.stdout, "*/b") == null);
}

// ----------------------------------------------------------------------------
// Parameter expansion: non-colon operators, nested defaults, negative length
// ----------------------------------------------------------------------------

test "scripting: non-colon ${var-word} treats empty as set" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    // unset -> substitutes; set-but-empty -> keeps the empty value.
    const result = try fixture.execDirect("unset u; e=; echo \"[${u-DEF}][${e-X}]\"");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "[DEF][]");
}

test "scripting: nested default ${a:-${b:-fallback}} resolves inner word" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.execDirect("unset a b; echo \"[${a:-${b:-fallback}}]\"");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "[fallback]");
}

test "scripting: negative substring length counts from the end" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    // ${v:2:-1} -> from index 2, drop the last char: "cdef" -> "cde".
    const result = try fixture.execDirect("v=abcdef; echo \"[${v:2:-1}]\"");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "[cde]");
}

// A control-flow operand inside a function body is expanded by a different
// path than a plain command's arguments, and that path only ever saw the
// environment. `$1` had nothing to resolve to, so the subject of a `case`
// became the empty string and matched nothing but `*` - the construct whose
// entire job is picking a branch, picking the wrong one and saying nothing.
test "scripting: case matches on a function's positional parameter" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.execDirect(
        \\pick() {
        \\  case "$1" in
        \\    a)
        \\      echo "got a"
        \\      ;;
        \\    *)
        \\      echo "got other"
        \\      ;;
        \\  esac
        \\}
        \\pick a
    );
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "got a");
}

test "scripting: case in a function still falls through when nothing matches" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.execDirect(
        \\pick() {
        \\  case "$1" in
        \\    a)
        \\      echo "got a"
        \\      ;;
        \\    *)
        \\      echo "got other"
        \\      ;;
        \\  esac
        \\}
        \\pick zzz
    );
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "got other");
}

// `eval` used to parse its argument as a single command chain, which has no
// representation for a function definition - and it never even got that far,
// because a line merely *containing* `()` was taken for a function definition
// itself, so `eval "hi() { ... }"` was read as defining `eval "hi`. Between
// them that is `eval "$(tool init)"`, which is how essentially every shell
// integration is loaded, doing nothing and saying nothing.
test "scripting: eval defines a function its caller can then run" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.execDirect(
        \\eval "hi() { echo EVAL_FN_RAN; }"
        \\hi
    );
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "EVAL_FN_RAN");
}

test "scripting: eval still runs a plain command and keeps its exit code" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.execDirect(
        \\eval "echo EVAL_CMD_RAN"
        \\eval "false"
        \\echo "code=$?"
    );
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "EVAL_CMD_RAN");
    try test_utils.TestAssert.expectContains(result.stdout, "code=1");
}

test "scripting: an assignment made inside eval survives it" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.execDirect(
        \\eval "V=42"
        \\echo "V=[$V]"
    );
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "V=[42]");
}

// A definition that opens and closes on one line defined the function with an
// empty body: the parser excludes the line carrying `{` from the body, and for
// a one-liner that is the only line there is. The function was defined and
// callable and did nothing, which is why it went unnoticed - `type` confirmed
// it existed. `source` sidestepped the parser; `-c` and a script file went
// straight through it.
test "scripting: a one-line function definition keeps its body" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.execDirect(
        \\hi() { echo ONE_LINE_BODY_RAN; }
        \\hi
    );
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "ONE_LINE_BODY_RAN");
}

test "scripting: a one-line function keeps every statement in its body" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.execDirect(
        \\two() { echo FIRST; echo SECOND; }
        \\two
    );
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "FIRST");
    try test_utils.TestAssert.expectContains(result.stdout, "SECOND");
}

// The body is split on its top-level semicolons, so a brace or a semicolon
// inside a string must not be mistaken for structure.
test "scripting: a one-line body is split quote-aware" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.execDirect(
        \\s() { echo "x; y"; }
        \\s
    );
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "x; y");
}

test "scripting: a one-line body keeps a whole control-flow construct together" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.execDirect(
        \\c() { for i in 1 2; do echo "n=$i"; done; }
        \\c
    );
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "n=1");
    try test_utils.TestAssert.expectContains(result.stdout, "n=2");
}

// =============================================================================
// Parameter Operators Whose Word Contains a Colon
// =============================================================================
//
// `${VAR<op>word}` was decided by looking for a colon and assuming substring
// extraction unless the character after it was one of `- = ? +`. The text before
// the colon was only checked for `#` and `%`, so every other operator became part
// of a variable name that does not exist, and the whole expansion came out empty.
//
// The case that matters is `eval "$(brew shellenv)"`, which emits
// `export PATH="/opt/homebrew/bin:...${PATH+:$PATH}"`. den read that as a
// variable named `PATH+` with an offset of `$PATH`, so PATH ended up holding
// only the Homebrew directories and every command in /bin stopped resolving.

test "expansion: plus operator with a colon in the word" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("X=abc; echo \"pre${X+:$X}post\"");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "pre:abcpost");
}

test "expansion: brew shellenv keeps the rest of PATH" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    // The exact shape `brew shellenv` emits. Without the fix PATH came out as
    // just "/opt/homebrew/bin", dropping everything it was meant to prepend to.
    const result = try fixture.exec(
        "P=/usr/bin:/bin; export PATH=\"/opt/homebrew/bin${P+:$P}\"; echo \"$PATH\"",
    );
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "/opt/homebrew/bin:/usr/bin:/bin");
}

test "expansion: dash and equals operators with a colon in the word" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const dash = try fixture.exec("echo \"${UNSET_ONE-:lit}\"");
    defer allocator.free(dash.stdout);
    defer allocator.free(dash.stderr);
    try test_utils.TestAssert.expectContains(dash.stdout, ":lit");

    const eq = try fixture.exec("echo \"${UNSET_TWO=:v}\"");
    defer allocator.free(eq.stdout);
    defer allocator.free(eq.stderr);
    try test_utils.TestAssert.expectContains(eq.stdout, ":v");
}

test "expansion: pattern replacement with a colon in the replacement" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("X=abc; echo \"${X/a/:b}\"");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, ":bbc");
}

test "expansion: substring extraction still works" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    // The forms the narrowed guard must keep claiming.
    const result = try fixture.exec(
        "X=abcdef; echo \"${X:1}|${X:1:2}|${X: -2}\"; arr=(a b c); echo \"${arr[@]:1}\"",
    );
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "bcdef|bc|ef");
    try test_utils.TestAssert.expectContains(result.stdout, "b c");
}

// =============================================================================
// Positional Parameter Slicing
// =============================================================================
//
// ${@:2} and every related form expanded to nothing. The substring branch was
// reached -- `@` does look like a parameter name -- but it then asked
// getVariableValue("@"), which knows nothing about positional parameters, so the
// whole expansion came out empty. Offsets here are one-based, since $@ begins at
// $1, and bash treats an offset of 0 the same as 1 because $0 is not among them.
//
// Known gap, deliberately not asserted below: inside double quotes these produce
// one word rather than one per parameter, so `for w in "${@:2}"` iterates once.
// That needs expansion to return multiple fields, which it cannot yet -- `for`
// only manages `"$@"` by matching the literal text. The same gap is why
// `f "$@"` passes a single argument.

test "expansion: positional slicing from an offset" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("set -- a b c d; echo \"[${@:2}]\"; echo \"[${*:3}]\"");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "[b c d]");
    try test_utils.TestAssert.expectContains(result.stdout, "[c d]");
}

test "expansion: positional slicing with a length" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("set -- a b c d; echo \"[${@:2:2}]\"; echo \"[${@:2:0}]\"");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "[b c]");
    try test_utils.TestAssert.expectContains(result.stdout, "[]");
}

test "expansion: positional slicing offsets 0 and 1 agree" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    // $0 is not a positional parameter, so bash starts both at $1.
    const result = try fixture.exec("set -- a b c; echo \"[${@:0}]\"; echo \"[${@:1}]\"");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "[a b c]");
}

test "expansion: positional slicing from the end" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("set -- a b c d; echo \"[${@: -2}]\"; echo \"[${@:(-3)}]\"");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "[c d]");
    try test_utils.TestAssert.expectContains(result.stdout, "[b c d]");
}

test "expansion: positional slicing out of range is empty" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("set -- a b c; echo \"[${@:9}]\"; echo \"[${@:1}]\" ; set --; echo \"[${@:1}]\"");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "[]");
    try test_utils.TestAssert.expectContains(result.stdout, "[a b c]");
}

test "expansion: positional slicing inside a function and after shift" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const in_fn = try fixture.exec("f() { echo \"[${@:2}]\"; }; f x y z");
    defer allocator.free(in_fn.stdout);
    defer allocator.free(in_fn.stderr);
    try test_utils.TestAssert.expectContains(in_fn.stdout, "[y z]");

    const shifted = try fixture.exec("set -- a b c d; shift; echo \"[${@:2}]\"");
    defer allocator.free(shifted.stdout);
    defer allocator.free(shifted.stderr);
    try test_utils.TestAssert.expectContains(shifted.stdout, "[c d]");
}

test "expansion: positional count via hash" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    // ${#@} and ${#*} both mean $#. They used to look up variables named `@` and
    // `*`, find nothing, and report 0.
    const result = try fixture.exec("set -- a b c; echo \"[$#][${#@}][${#*}]\"");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "[3][3][3]");
}

test "expansion: string substring extraction is unaffected" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    // The slice arithmetic is shared with positional slicing now, so these pin it.
    const result = try fixture.exec(
        "x=abcdef; echo \"[${x:1}][${x:1:2}][${x: -2}][${x:(-3)}][${x:9}]\"",
    );
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "[bcdef][bc][ef][def][]");
}

// =============================================================================
// "$@" Produces One Field Per Positional Parameter
// =============================================================================
//
// `"$@"` is the only expansion that yields several fields from a *quoted* word.
// den joined them into one string, so `f "$@"` passed a single argument -- $# read
// 1 where it should read 3 -- and any parameter containing a space lost its
// boundary irrecoverably. `for` papered over its own case by matching the literal
// text `"$@"`, which is why `for w in "$@"` looked fine while everything else did
// not.
//
// The surrounding text joins onto the first and last field, a word may hold more
// than one reference, and an empty `"$@"` contributes no field at all -- which is
// what lets `f "$@"` with nothing set call f with no arguments.

test "dollar-at: quoted forwarding passes separate arguments" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec(
        "f() { echo \"n=$# 1=$1 2=$2 3=$3\"; }; set -- p q r; f \"$@\"",
    );
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "n=3 1=p 2=q 3=r");
}

test "dollar-at: a parameter containing a space keeps its boundary" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    // The reason you quote "$@" in the first place. Joining produced <a b c>.
    const result = try fixture.exec("set -- \"a b\" c; printf '<%s>\\n' \"$@\"");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "<a b>");
    try test_utils.TestAssert.expectContains(result.stdout, "<c>");
}

test "dollar-at: surrounding text joins the first and last field" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("set -- a b c; printf '<%s>\\n' \"pre$@post\"");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "<prea>");
    try test_utils.TestAssert.expectContains(result.stdout, "<b>");
    try test_utils.TestAssert.expectContains(result.stdout, "<cpost>");
}

test "dollar-at: more than one reference in a word" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    // a, then b joined to the second reference's a, then its b.
    const result = try fixture.exec("set -- a b; printf '<%s>\\n' \"$@-$@\"");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "<a>");
    try test_utils.TestAssert.expectContains(result.stdout, "<b-a>");
}

test "dollar-at: no parameters means no argument at all" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const bare = try fixture.exec("f() { echo \"n=$#\"; }; set --; f \"$@\"");
    defer allocator.free(bare.stdout);
    defer allocator.free(bare.stderr);
    try test_utils.TestAssert.expectContains(bare.stdout, "n=0");

    // With text around it the word survives as one field, so it is still an
    // argument -- `selected_any` in appendAtFields is what separates these.
    const padded = try fixture.exec("f() { echo \"n=$# 1=[$1]\"; }; set --; f \"pre$@post\"");
    defer allocator.free(padded.stdout);
    defer allocator.free(padded.stderr);
    try test_utils.TestAssert.expectContains(padded.stdout, "n=1 1=[prepost]");
}

test "dollar-at: an empty parameter is still a field" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("f() { echo \"n=$#\"; }; set -- a \"\" c; f \"$@\"");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "n=3");
}

test "dollar-at: braced and sliced forms split too" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const braced = try fixture.exec("f() { echo \"n=$#\"; }; set -- a b c; f \"${@}\"");
    defer allocator.free(braced.stdout);
    defer allocator.free(braced.stderr);
    try test_utils.TestAssert.expectContains(braced.stdout, "n=3");

    const sliced = try fixture.exec("f() { echo \"n=$# 1=$1\"; }; set -- a b c d; f \"${@:2}\"");
    defer allocator.free(sliced.stdout);
    defer allocator.free(sliced.stderr);
    try test_utils.TestAssert.expectContains(sliced.stdout, "n=3 1=b");
}

test "dollar-at: star stays a single field" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    // "$*" joins; only @ splits. Getting this wrong would make the two identical.
    const result = try fixture.exec("f() { echo \"n=$# 1=[$1]\"; }; set -- a b c; f \"$*\"");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "n=1 1=[a b c]");
}

test "dollar-at: for loops see one item per parameter" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    // All four used to collapse to one item except the literal "$@".
    const scripts = [_][]const u8{
        "set -- a b c; for w in \"$@\"; do echo \"<$w>\"; done",
        "set -- a b c; for w in \"${@}\"; do echo \"<$w>\"; done",
        "set -- a b c d; shift; for w in \"${@:2}\"; do echo \"<$w>\"; done",
        "set -- b c; for w in \"pre$@\"; do echo \"<$w>\"; done",
    };
    for (scripts) |script| {
        const result = try fixture.exec(script);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
        try test_utils.TestAssert.expectContains(result.stdout, "<c>");
    }
}

test "dollar-at: unquoted still splits on IFS" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    // Unquoted $@ is subject to field splitting, so "a b" becomes two words. I
    // broke this once by routing unquoted items through the quoted path.
    const result = try fixture.exec("set -- \"a b\" c; for w in $@; do echo \"<$w>\"; done");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "<a>");
    try test_utils.TestAssert.expectContains(result.stdout, "<b>");
    try test_utils.TestAssert.expectContains(result.stdout, "<c>");
}

test "dollar-at: colon operators are not slices" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    // ${@:-word} is a default, not an offset of `-word`. Reading it as a slice
    // made it expand to nothing, which I did briefly.
    const result = try fixture.exec("set --; echo \"[${@:-fallback}]\"; echo \"[${@:+alt}]\"");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "[fallback]");
    try test_utils.TestAssert.expectContains(result.stdout, "[]");
}

// =============================================================================
// $@ and $* With the Default and Alternative Operators
// =============================================================================
//
// getVariableValue looks `@` up as an ordinary variable and finds nothing, so
// every operator concluded the parameters were unset however many there were:
// `${@:-x}` gave x with arguments present, and `${@:+y}` gave nothing.
//
// Two answers are needed, not one. A quoted `"${@:-x}"` wants one field per
// parameter, which positionalFields provides; `$*`, and anything unquoted, wants
// them joined, which positionalScalar provides. `:+` is different again -- it
// yields its own word, so it only needs to know whether anything is set.

test "dollar-at default operator yields the parameters when set" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    // Both the colon and the bare form, for @ and for *.
    const result = try fixture.exec(
        "set -- a b; echo \"[${@:-x}][${@-x}][${*:-x}][${*-x}][${@:=x}][${@:?m}]\"",
    );
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    // All six operator forms, for @ and for *. bash refuses to assign to $@, but
    // with parameters set := and :? never reach the point of trying.
    try test_utils.TestAssert.expectContains(result.stdout, "[a b][a b][a b][a b][a b][a b]");
}

test "dollar-at default operator still falls back when unset" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("set --; echo \"[${@:-x}][${@-x}][${*:-x}]\"");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "[x][x][x]");
}

test "dollar-at alternative operator yields its word when set" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const set = try fixture.exec("set -- a b; echo \"[${@:+y}][${@+y}][${*:+y}]\"");
    defer allocator.free(set.stdout);
    defer allocator.free(set.stderr);
    try test_utils.TestAssert.expectContains(set.stdout, "[y][y][y]");

    const unset = try fixture.exec("set --; echo \"[${@:+y}][${@+y}]\"");
    defer allocator.free(unset.stdout);
    defer allocator.free(unset.stderr);
    try test_utils.TestAssert.expectContains(unset.stdout, "[][]");
}

test "dollar-at default operator splits into fields when quoted" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    // The whole point of having two paths: a parameter with a space stays one
    // field, which a joined string could not express.
    const result = try fixture.exec("set -- \"a b\" c; printf '<%s>\\n' \"${@:-x}\"");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "<a b>");
    try test_utils.TestAssert.expectContains(result.stdout, "<c>");

    const forwarded = try fixture.exec("f() { echo \"n=$#\"; }; set -- a b; f \"${@:-x}\"");
    defer allocator.free(forwarded.stdout);
    defer allocator.free(forwarded.stderr);
    try test_utils.TestAssert.expectContains(forwarded.stdout, "n=2");
}

test "dollar-at operators leave ordinary variables alone" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    // The helpers answer only for @ and *, so every other name keeps the
    // behaviour it had: unset takes the default, empty is set for `-` but not
    // for `:-`, and a positional digit is unaffected.
    const result = try fixture.exec(
        "unset V; A=s; E=; set --; echo \"[${V:-d}][${A:+alt}][${E-d}][${E:-d}][${1:-first}]\"",
    );
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "[d][alt][][d][first]");
}

test "dollar-at pattern operators are not slices or defaults" {
    const allocator = std.testing.allocator;
    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    // `${@#p}` and `${@/a/b}` must not be mistaken for an offset or a default;
    // positionalFields declines anything but a colon-slice or `-`.
    const result = try fixture.exec("set -- a b c; echo \"[${@:1}][${#@}]\"");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "[a b c][3]");
}
