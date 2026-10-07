const std = @import("std");
const test_utils = @import("test_utils.zig");

// Integration Tests
// Tests that verify multiple components working together

test "Integration: parse and execute simple command" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo hello");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "hello");
}

test "Integration: pipe between commands" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo hello | cat");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "hello");
}

test "Integration: AND operator with successful commands" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo first && echo second");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "first");
    try test_utils.TestAssert.expectContains(result.stdout, "second");
}

test "Integration: OR operator with failed command" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("false || echo fallback");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "fallback");
}

test "Integration: semicolon command separator" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo first; echo second; echo third");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "first");
    try test_utils.TestAssert.expectContains(result.stdout, "second");
    try test_utils.TestAssert.expectContains(result.stdout, "third");
}

test "Integration: output redirection" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const output_file = try std.fs.path.join(allocator, &[_][]const u8{ fixture.temp_dir.path, "output.txt" });
    defer allocator.free(output_file);

    const cmd = try std.fmt.allocPrint(allocator, "echo hello > {s}", .{output_file});
    defer allocator.free(cmd);

    const result = try fixture.exec(cmd);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);

    // Verify file was created
    const file_content = try fixture.temp_dir.readFile("output.txt");
    defer allocator.free(file_content);

    try test_utils.TestAssert.expectContains(file_content, "hello");
}

test "Integration: input redirection" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    // Create input file
    const input_file = try fixture.temp_dir.createFile("input.txt", "test content");
    defer allocator.free(input_file);

    const cmd = try std.fmt.allocPrint(allocator, "cat < {s}", .{input_file});
    defer allocator.free(cmd);

    const result = try fixture.exec(cmd);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "test content");
}

test "Integration: complex pipeline" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo 'line1\nline2\nline3' | grep line2");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "line2");
}

test "Integration: command substitution" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo $(echo nested)");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "nested");
}

test "Integration: variable expansion" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("TEST=hello && echo $TEST");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "hello");
}

test "Integration: mixed operators" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo a && echo b || echo c; echo d | cat");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "a");
    try test_utils.TestAssert.expectContains(result.stdout, "b");
    try test_utils.TestAssert.expectContains(result.stdout, "d");
}

test "Integration: script execution" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const script_content =
        \\#!/bin/sh
        \\echo "Script started"
        \\echo "Line 2"
        \\echo "Script finished"
    ;

    const script_path = try fixture.createScript("test.sh", script_content);
    defer allocator.free(script_path);

    const result = try fixture.exec(script_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "Script started");
    try test_utils.TestAssert.expectContains(result.stdout, "Script finished");
}

test "Integration: conditional execution" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("true && echo yes || echo no");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "yes");
}

test "Integration: multiple redirections" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const input_file = try fixture.temp_dir.createFile("input.txt", "input data");
    defer allocator.free(input_file);

    const output_file = try std.fs.path.join(allocator, &[_][]const u8{ fixture.temp_dir.path, "output.txt" });
    defer allocator.free(output_file);

    const cmd = try std.fmt.allocPrint(allocator, "cat < {s} > {s}", .{ input_file, output_file });
    defer allocator.free(cmd);

    const result = try fixture.exec(cmd);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);

    const file_content = try fixture.temp_dir.readFile("output.txt");
    defer allocator.free(file_content);

    try test_utils.TestAssert.expectContains(file_content, "input data");
}

test "Integration: error handling" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("nonexistent-command");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should fail with non-zero exit code
    try test_utils.TestAssert.expectTrue(result.exit_code != 0);
}

test "Integration: long pipeline" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo hello | cat | cat | cat");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "hello");
}

test "Integration: subshell execution" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("(echo nested && echo commands)");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "nested");
    try test_utils.TestAssert.expectContains(result.stdout, "commands");
}

test "Integration: glob expansion" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    // Create test files
    const file1 = try fixture.temp_dir.createFile("test1.txt", "content1");
    defer allocator.free(file1);
    const file2 = try fixture.temp_dir.createFile("test2.txt", "content2");
    defer allocator.free(file2);

    const cmd = try std.fmt.allocPrint(allocator, "ls {s}/*.txt", .{fixture.temp_dir.path});
    defer allocator.free(cmd);

    const result = try fixture.exec(cmd);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "test1.txt");
    try test_utils.TestAssert.expectContains(result.stdout, "test2.txt");
}
