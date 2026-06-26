const std = @import("std");
const test_utils = @import("test_utils.zig");

// Operator Regression Tests
// Tests for shell operators: &&, ||, |, ;, &, etc.

// ============================================================================
// Logical AND Operator (&&)
// ============================================================================

test "Operator: && with both success" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("true && echo success");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "success");
}

test "Operator: && with first failure" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("false && echo success");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectTrue(result.exit_code != 0);
    try test_utils.TestAssert.expectTrue(std.mem.indexOf(u8, result.stdout, "success") == null);
}

test "Operator: && chain multiple success" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("true && true && true && echo done");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "done");
}

test "Operator: && chain stops at failure" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("true && false && echo never");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectTrue(result.exit_code != 0);
    try test_utils.TestAssert.expectTrue(std.mem.indexOf(u8, result.stdout, "never") == null);
}

// ============================================================================
// Logical OR Operator (||)
// ============================================================================

test "Operator: || with first success" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("true || echo fallback");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectTrue(std.mem.indexOf(u8, result.stdout, "fallback") == null);
}

test "Operator: || with first failure" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("false || echo fallback");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "fallback");
}

test "Operator: || chain" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("false || false || echo third");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "third");
}

test "Operator: || stops at first success" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("false || true || echo never");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectTrue(std.mem.indexOf(u8, result.stdout, "never") == null);
}

// ============================================================================
// Mixed && and ||
// ============================================================================

test "Operator: && then ||" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("true && echo yes || echo no");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "yes");
    try test_utils.TestAssert.expectTrue(std.mem.indexOf(u8, result.stdout, "no") == null);
}

test "Operator: || then &&" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("false || true && echo both");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "both");
}

test "Operator: complex chain" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("true && false || echo recovered && echo continued");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "recovered");
    try test_utils.TestAssert.expectContains(result.stdout, "continued");
}

// ============================================================================
// Pipe Operator (|)
// ============================================================================

test "Operator: simple pipe" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo hello | cat");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "hello");
}

test "Operator: multi-stage pipe" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo 'hello world' | tr ' ' '\\n' | sort");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
}

test "Operator: pipe with grep" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("printf 'apple\\nbanana\\ncherry' | grep an");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "banana");
}

test "Operator: pipe exit code from last command" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo hello | false; echo $?");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "1");
}

// ============================================================================
// Semicolon Operator (;)
// ============================================================================

test "Operator: semicolon sequential" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo first; echo second");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "first");
    try test_utils.TestAssert.expectContains(result.stdout, "second");
}

test "Operator: semicolon continues after failure" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("false; echo continued");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "continued");
}

test "Operator: multiple semicolons" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo a; echo b; echo c; echo d");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "a");
    try test_utils.TestAssert.expectContains(result.stdout, "b");
    try test_utils.TestAssert.expectContains(result.stdout, "c");
    try test_utils.TestAssert.expectContains(result.stdout, "d");
}

// ============================================================================
// Background Operator (&)
// ============================================================================

test "Operator: background job" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("sleep 0.01 & wait; echo done");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "done");
}

test "Operator: multiple background jobs" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("sleep 0.01 & sleep 0.01 & wait; echo finished");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "finished");
}

// ============================================================================
// Redirection Operators
// ============================================================================

test "Operator: output redirection >" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const file_path = try std.fs.path.join(allocator, &[_][]const u8{ fixture.temp_dir.path, "output.txt" });
    defer allocator.free(file_path);

    const cmd = try std.fmt.allocPrint(allocator, "echo hello > {s} && cat {s}", .{ file_path, file_path });
    defer allocator.free(cmd);

    const result = try fixture.exec(cmd);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "hello");
}

test "Operator: append redirection >>" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const file_path = try std.fs.path.join(allocator, &[_][]const u8{ fixture.temp_dir.path, "append.txt" });
    defer allocator.free(file_path);

    const cmd = try std.fmt.allocPrint(allocator, "echo first > {s} && echo second >> {s} && cat {s}", .{ file_path, file_path, file_path });
    defer allocator.free(cmd);

    const result = try fixture.exec(cmd);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "first");
    try test_utils.TestAssert.expectContains(result.stdout, "second");
}

test "Operator: input redirection <" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const file_path = try fixture.temp_dir.createFile("input.txt", "content from file");
    defer allocator.free(file_path);

    const cmd = try std.fmt.allocPrint(allocator, "cat < {s}", .{file_path});
    defer allocator.free(cmd);

    const result = try fixture.exec(cmd);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "content from file");
}

test "Operator: stderr redirection 2>" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const file_path = try std.fs.path.join(allocator, &[_][]const u8{ fixture.temp_dir.path, "stderr.txt" });
    defer allocator.free(file_path);

    const cmd = try std.fmt.allocPrint(allocator, "ls /nonexistent 2> {s}; cat {s}", .{ file_path, file_path });
    defer allocator.free(cmd);

    const result = try fixture.exec(cmd);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // stderr file should contain error message
    try test_utils.TestAssert.expectTrue(result.stdout.len > 0 or result.stderr.len > 0);
}

test "Operator: stderr to stdout 2>&1" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("ls /nonexistent 2>&1 | cat");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Error should be captured in stdout due to redirect
    try test_utils.TestAssert.expectTrue(result.stdout.len > 0);
}

// ============================================================================
// Grouping Operators
// ============================================================================

test "Operator: subshell grouping ()" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("(echo grouped)");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "grouped");
}

test "Operator: subshell variable isolation" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("X=outer; (X=inner; echo $X); echo $X");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "inner");
    try test_utils.TestAssert.expectContains(result.stdout, "outer");
}

test "Operator: brace grouping {}" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("{ echo brace; echo group; }");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "brace");
    try test_utils.TestAssert.expectContains(result.stdout, "group");
}

// ============================================================================
// Negation Operator (!)
// ============================================================================

test "Operator: negation of success" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("! true; echo $?");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "1");
}

test "Operator: negation of failure" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("! false; echo $?");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "0");
}

// ============================================================================
// Complex Operator Combinations
// ============================================================================

test "Operator: pipe with && chain" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo test | grep test && echo found");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "found");
}

test "Operator: semicolon with redirect" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const file_path = try std.fs.path.join(allocator, &[_][]const u8{ fixture.temp_dir.path, "multi.txt" });
    defer allocator.free(file_path);

    const cmd = try std.fmt.allocPrint(allocator, "echo a > {s}; echo b >> {s}; cat {s}", .{ file_path, file_path, file_path });
    defer allocator.free(cmd);

    const result = try fixture.exec(cmd);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "a");
    try test_utils.TestAssert.expectContains(result.stdout, "b");
}

test "Operator: background in pipeline" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("(sleep 0.01; echo bg) & wait; echo fg");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "fg");
}

test "Operator: all operators combined" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo start; true && echo middle || echo fail; echo end");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "start");
    try test_utils.TestAssert.expectContains(result.stdout, "middle");
    try test_utils.TestAssert.expectContains(result.stdout, "end");
    try test_utils.TestAssert.expectTrue(std.mem.indexOf(u8, result.stdout, "fail") == null);
}

// ============================================================================
// Bare variable assignment as a chain segment
//
// A bare assignment (`V=x`) followed directly by a control operator is a
// standalone command in the chain — not a temporary-assignment prefix to the
// operator. These used to fail to parse with "empty command". They run the
// real den binary (DenShellFixture) because they exercise den's own
// command-chain handling, not system /bin/sh.
// ============================================================================

test "Operator: bare assignment then && runs next segment" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.execDirect("V=x && echo GOT=$V");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "GOT=x");
    try test_utils.TestAssert.expectTrue(std.mem.indexOf(u8, result.stderr, "empty command") == null);
}

test "Operator: bare assignment succeeds so || skips next segment" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.execDirect("V=x || echo SHOULD_NOT_PRINT");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectTrue(std.mem.indexOf(u8, result.stdout, "SHOULD_NOT_PRINT") == null);
    try test_utils.TestAssert.expectTrue(std.mem.indexOf(u8, result.stderr, "empty command") == null);
}

test "Operator: bare assignment persists across the && chain" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.execDirect("V=x && true; echo VAL=[$V]");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "VAL=[x]");
}

test "Operator: multiple bare assignments before && set all variables" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.execDirect("A=1 B=2 C=3 && echo RES=$A$B$C");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "RES=123");
}

test "Operator: temporary assignment prefix before && is unaffected" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    // FOO applies to printenv; the && chains to the next command.
    const result = try fixture.execDirect("FOO=bar printenv FOO && echo done");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "bar");
    try test_utils.TestAssert.expectContains(result.stdout, "done");
}
