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
// Bare variable assignment as a segment of an AND-OR list
// Regression: a bare assignment (no command word) as the first segment of an
// && / || list was misparsed as an empty command ("error: empty command"),
// and even when it parsed the value was expanded before the assignment ran.
// ============================================================================

test "Operator: bare assignment as first segment of &&" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("V=x && echo $V");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "x");
    // The bug surfaced as a parse error printed to stderr.
    try test_utils.TestAssert.expectTrue(std.mem.indexOf(u8, result.stderr, "empty command") == null);
}

test "Operator: assignment visible across && segments" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    // The whole chain must NOT be expanded up front: $V has to reflect the
    // assignment from the earlier segment.
    const result = try fixture.exec("true && V=a && echo got=$V");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "got=a");
}

test "Operator: bare assignment as first segment of ||" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    // `V=y` succeeds, so the || short-circuits and `echo wrong` is skipped,
    // but V must still be set for the trailing command.
    const result = try fixture.exec("V=y || echo wrong; echo got=$V");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "got=y");
    try test_utils.TestAssert.expectTrue(std.mem.indexOf(u8, result.stdout, "wrong") == null);
}

test "Operator: multiple leading assignments before &&" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("A=1 B=2 && echo $A $B");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "1 2");
}

test "Operator: && / || not split inside backticks" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    // The || lives inside backtick command substitution, so it must not be a
    // split point — the whole thing is one command whose output is `recovered`.
    const result = try fixture.exec("echo `false || echo recovered`");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "recovered");
    // The bug split on `||`, leaving a stray backtick in the output.
    try test_utils.TestAssert.expectTrue(std.mem.indexOf(u8, result.stdout, "`") == null);
}

test "Operator: && not split inside quotes" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo 'a && b'");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "a && b");
}

test "Operator: mixed semicolon and && list" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    // `;` separates two AND-OR lists; assignments stay visible across both.
    const result = try fixture.exec("A=1 && echo a$A; B=2 && echo b$B");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "a1");
    try test_utils.TestAssert.expectContains(result.stdout, "b2");
}

test "Operator: && left-associative with ||" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    // false && X || Y  ->  X skipped, Y runs (matches bash).
    const result = try fixture.exec("false && echo X || echo Y");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "Y");
    try test_utils.TestAssert.expectTrue(std.mem.indexOf(u8, result.stdout, "X") == null);
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

// ----------------------------------------------------------------------------
// **= power compound assignment in arithmetic.
//
// Regression: `*=` matched the second '*' of `**=`, so the operator was unread.
// Both the $((...)) expansion path and the ((...)) statement path must apply it.
// ----------------------------------------------------------------------------

test "Operator: arithmetic expansion x**=3 raises x to the power" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.execDirect("x=2; echo $((x**=3)); echo x=$x");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "8");
    try test_utils.TestAssert.expectContains(result.stdout, "x=8");
}

test "Operator: ((x **= 3)) statement form raises x to the power" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.execDirect("x=2; ((x**=3)); echo x=$x");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "x=8");
}

test "Operator: ((x *= 4)) still multiplies (no **= regression)" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.execDirect("x=5; ((x*=4)); echo x=$x");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "x=20");
}

// ----------------------------------------------------------------------------
// Sparse indexed arrays (bash semantics): a high subscript materialises only
// the elements actually assigned — not every index in between.
// ----------------------------------------------------------------------------

test "Operator: arr[5]=x is sparse (length 1, key 5)" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.execDirect("arr[5]=x; echo \"len=${#arr[@]} keys=${!arr[@]} val=${arr[5]}\"");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "len=1");
    try test_utils.TestAssert.expectContains(result.stdout, "keys=5");
    try test_utils.TestAssert.expectContains(result.stdout, "val=x");
}

test "Operator: dense array plus high subscript keeps real keys" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.execDirect("a=(1 2 3); a[10]=z; echo \"len=${#a[@]} keys=${!a[@]}\"");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "len=4");
    try test_utils.TestAssert.expectContains(result.stdout, "keys=0 1 2 10");
}

test "Operator: sparse array values expand in ascending-subscript order" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.execDirect("a[5]=x; a[2]=y; a[9]=z; echo \"${a[@]}\"");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "y x z");
}

test "Operator: negative subscript indexes from the array end" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.execDirect("a=(p q r s); echo \"${a[-1]} ${a[-2]}\"");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "s r");
}
