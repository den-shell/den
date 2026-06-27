const std = @import("std");
const test_utils = @import("test_utils.zig");

// Shell Integration Tests
// Tests that verify integration between different shell components

// ============================================================================
// Environment Integration Tests
// ============================================================================

test "Integration: export variable to subshell" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("export MY_VAR=hello && sh -c 'echo $MY_VAR'");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "hello");
}

test "Integration: PATH manipulation" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("OLD_PATH=$PATH && PATH=/tmp:$PATH && echo $PATH | grep /tmp");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
}

test "Integration: HOME variable" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo $HOME");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectTrue(result.stdout.len > 0);
}

test "Integration: env command" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("TEST_VAR=value env | grep TEST_VAR");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "TEST_VAR=value");
}

// ============================================================================
// Signal Handling Integration Tests
// ============================================================================

test "Integration: trap EXIT handler" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const script =
        \\#!/bin/sh
        \\trap 'echo exit_handler' EXIT
        \\echo "main"
    ;

    const script_path = try fixture.createScript("trap_exit.sh", script);
    defer allocator.free(script_path);

    const result = try fixture.exec(script_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "main");
    try test_utils.TestAssert.expectContains(result.stdout, "exit_handler");
}

test "Integration: trap ERR handler" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const script =
        \\#!/bin/sh
        \\trap 'echo error_caught' ERR 2>/dev/null || true
        \\echo "done"
    ;

    const script_path = try fixture.createScript("trap_err.sh", script);
    defer allocator.free(script_path);

    const result = try fixture.exec(script_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "done");
}

test "Integration: ignore INT signal" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const script =
        \\#!/bin/sh
        \\trap '' INT
        \\echo "ignoring INT"
    ;

    const script_path = try fixture.createScript("trap_int.sh", script);
    defer allocator.free(script_path);

    const result = try fixture.exec(script_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "ignoring INT");
}

// ============================================================================
// Process Group Integration Tests
// ============================================================================

test "Integration: pipeline process group" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo 'data' | cat | cat | head -1");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "data");
}

test "Integration: subshell process" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("(echo 'subshell' && exit 0)");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "subshell");
}

test "Integration: command substitution process" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo \"Value is $(echo test)\"");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "Value is test");
}

// ============================================================================
// File Descriptor Integration Tests
// ============================================================================

test "Integration: file descriptor redirection" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const out_file = try std.fs.path.join(allocator, &[_][]const u8{ fixture.temp_dir.path, "fd_out.txt" });
    defer allocator.free(out_file);

    const cmd = try std.fmt.allocPrint(allocator, "echo 'stdout' > {s} 2>&1", .{out_file});
    defer allocator.free(cmd);

    const result = try fixture.exec(cmd);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const content = try fixture.temp_dir.readFile("fd_out.txt");
    defer allocator.free(content);

    try test_utils.TestAssert.expectContains(content, "stdout");
}

test "Integration: here document with variable expansion" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const script =
        \\#!/bin/sh
        \\NAME="World"
        \\cat << EOF
        \\Hello, $NAME!
        \\EOF
    ;

    const script_path = try fixture.createScript("heredoc.sh", script);
    defer allocator.free(script_path);

    const result = try fixture.exec(script_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "Hello, World!");
}

test "Integration: here document without expansion" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const script =
        \\#!/bin/sh
        \\cat << 'EOF'
        \\$NOT_EXPANDED
        \\EOF
    ;

    const script_path = try fixture.createScript("heredoc_raw.sh", script);
    defer allocator.free(script_path);

    const result = try fixture.exec(script_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "$NOT_EXPANDED");
}

// ============================================================================
// Working Directory Integration Tests
// ============================================================================

test "Integration: cd and pwd" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const subdir = try fixture.temp_dir.createDir("testdir");
    defer allocator.free(subdir);

    const cmd = try std.fmt.allocPrint(allocator, "cd {s} && pwd", .{subdir});
    defer allocator.free(cmd);

    const result = try fixture.exec(cmd);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "testdir");
}

test "Integration: cd with OLDPWD" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const dir1 = try fixture.temp_dir.createDir("dir1");
    defer allocator.free(dir1);

    const dir2 = try fixture.temp_dir.createDir("dir2");
    defer allocator.free(dir2);

    const cmd = try std.fmt.allocPrint(allocator, "cd {s} && cd {s} && echo $OLDPWD | grep dir1", .{ dir1, dir2 });
    defer allocator.free(cmd);

    const result = try fixture.exec(cmd);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
}

test "Integration: cd -" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const dir1 = try fixture.temp_dir.createDir("first");
    defer allocator.free(dir1);

    const dir2 = try fixture.temp_dir.createDir("second");
    defer allocator.free(dir2);

    const cmd = try std.fmt.allocPrint(allocator, "cd {s} && cd {s} && cd - && pwd | grep first", .{ dir1, dir2 });
    defer allocator.free(cmd);

    const result = try fixture.exec(cmd);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
}

// ============================================================================
// Exit Code Integration Tests
// ============================================================================

test "Integration: exit code from last command" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("false; echo $?");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "1");
}

test "Integration: exit code from pipeline" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("true | false; echo $?");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "1");
}

test "Integration: PIPESTATUS simulation" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("true | false | true; echo $?");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Last command in pipeline was true
    try test_utils.TestAssert.expectContains(result.stdout, "0");
}

test "Integration: PIPESTATUS records each stage of a pipeline" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.execDirect("true | false | true; echo \"${PIPESTATUS[@]}\"");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "0 1 0");
}

test "Integration: PIPESTATUS is set after a single (non-pipeline) command" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    // Regression (PIPESTATUS set after every command, not just pipelines):
    // a bare `false` must leave PIPESTATUS=(1), not a stale pipeline value.
    const result = try fixture.execDirect("true | true; false; echo \"${PIPESTATUS[@]}\"");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    // A lone command resets PIPESTATUS to its single exit status.
    try test_utils.TestAssert.expectContains(result.stdout, "1");
    try test_utils.TestAssert.expectTrue(std.mem.indexOf(u8, result.stdout, "0 0") == null);
}

// ============================================================================
// Script Mode Integration Tests
// ============================================================================

test "Integration: script with functions and variables" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const script =
        \\#!/bin/sh
        \\CONFIG_FILE="/etc/config"
        \\LOG_LEVEL="info"
        \\
        \\log() {
        \\    echo "[$LOG_LEVEL] $1"
        \\}
        \\
        \\log "Starting with config: $CONFIG_FILE"
    ;

    const script_path = try fixture.createScript("integrated.sh", script);
    defer allocator.free(script_path);

    const result = try fixture.exec(script_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "[info] Starting with config: /etc/config");
}

test "Integration: script with loops and conditionals" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const script =
        \\#!/bin/sh
        \\total=0
        \\for i in 1 2 3 4 5; do
        \\    total=$((total + i))
        \\done
        \\
        \\if [ $total -eq 15 ]; then
        \\    echo "Sum is correct: $total"
        \\else
        \\    echo "Sum is wrong"
        \\fi
    ;

    const script_path = try fixture.createScript("loop_cond.sh", script);
    defer allocator.free(script_path);

    const result = try fixture.exec(script_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "Sum is correct: 15");
}

test "Integration: script with case statement" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const script =
        \\#!/bin/sh
        \\value="test"
        \\case $value in
        \\    prod) echo "production" ;;
        \\    test) echo "testing" ;;
        \\    *) echo "unknown" ;;
        \\esac
    ;

    const script_path = try fixture.createScript("case.sh", script);
    defer allocator.free(script_path);

    const result = try fixture.exec(script_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "testing");
}

// ============================================================================
// Quoting Integration Tests
// ============================================================================

test "Integration: single vs double quotes" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("VAR=world && echo '$VAR' && echo \"$VAR\"");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "$VAR");
    try test_utils.TestAssert.expectContains(result.stdout, "world");
}

test "Integration: nested quotes" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo \"It's a 'test'\"");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "It's a 'test'");
}

test "Integration: escaped characters in double quotes" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo \"line1\\nline2\"");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
}

// ============================================================================
// Command Chaining Integration Tests
// ============================================================================

test "Integration: complex chaining" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("true && echo 'success' || echo 'fail'");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "success");
    try test_utils.TestAssert.expectTrue(std.mem.indexOf(u8, result.stdout, "fail") == null);
}

test "Integration: chaining with false" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("false && echo 'success' || echo 'fail'");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "fail");
    try test_utils.TestAssert.expectTrue(std.mem.indexOf(u8, result.stdout, "success") == null);
}

test "Integration: mixed operators" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo a; echo b && echo c; echo d || echo e");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "a");
    try test_utils.TestAssert.expectContains(result.stdout, "b");
    try test_utils.TestAssert.expectContains(result.stdout, "c");
    try test_utils.TestAssert.expectContains(result.stdout, "d");
}

// ============================================================================
// Glob and Expansion Integration Tests
// ============================================================================

test "Integration: glob in command argument" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const f1 = try fixture.temp_dir.createFile("glob1.txt", "");
    defer allocator.free(f1);
    const f2 = try fixture.temp_dir.createFile("glob2.txt", "");
    defer allocator.free(f2);

    const cmd = try std.fmt.allocPrint(allocator, "ls {s}/glob*.txt | wc -l", .{fixture.temp_dir.path});
    defer allocator.free(cmd);

    const result = try fixture.exec(cmd);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "2");
}

test "Integration: brace expansion" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo file{1,2,3}.txt");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "file1.txt");
    try test_utils.TestAssert.expectContains(result.stdout, "file2.txt");
    try test_utils.TestAssert.expectContains(result.stdout, "file3.txt");
}

test "Integration: tilde expansion" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo ~");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Tilde should expand to home directory
    try test_utils.TestAssert.expectTrue(result.stdout.len > 0);
    try test_utils.TestAssert.expectTrue(result.stdout[0] == '/');
}

// ============================================================================
// Builtin Command Integration Tests
// ============================================================================

test "Integration: test command" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("test 1 -eq 1 && echo 'equal'");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "equal");
}

test "Integration: bracket test syntax" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("[ -z '' ] && echo 'empty'");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "empty");
}

test "Integration: printf vs echo" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("printf 'hello\\n' && printf 'world\\n'");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "hello");
    try test_utils.TestAssert.expectContains(result.stdout, "world");
}

// ============================================================================
// Error Handling Integration Tests
// ============================================================================

test "Integration: command not found handling" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("nonexistent_command_xyz123 2>/dev/null; echo $?");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Exit code should be 127 for command not found
    try test_utils.TestAssert.expectContains(result.stdout, "127");
}

test "Integration: permission denied handling" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const noexec_file = try fixture.temp_dir.createFile("noexec.sh", "#!/bin/sh\necho test");
    defer allocator.free(noexec_file);

    // File is not executable
    const cmd = try std.fmt.allocPrint(allocator, "{s} 2>/dev/null; echo $?", .{noexec_file});
    defer allocator.free(cmd);

    const result = try fixture.exec(cmd);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Exit code should be 126 for permission denied
    try test_utils.TestAssert.expectContains(result.stdout, "126");
}

// ============================================================================
// IPC Integration Tests
// ============================================================================

test "Integration: process substitution simulation" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    // Simulate process substitution with temporary files
    const file1 = try fixture.temp_dir.createFile("list1.txt", "a\nb\nc");
    defer allocator.free(file1);
    const file2 = try fixture.temp_dir.createFile("list2.txt", "b\nc\nd");
    defer allocator.free(file2);

    const cmd = try std.fmt.allocPrint(allocator, "comm -12 {s} {s}", .{ file1, file2 });
    defer allocator.free(cmd);

    const result = try fixture.exec(cmd);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "b");
    try test_utils.TestAssert.expectContains(result.stdout, "c");
}

test "Integration: named pipe communication" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    // Simple pipe test
    const result = try fixture.exec("echo 'piped data' | cat");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "piped data");
}

// ============================================================================
// Timing and Async Integration Tests
// ============================================================================

test "Integration: wait for background job" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("sleep 0.1 & pid=$!; wait $pid; echo 'waited'");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "waited");
}

test "Integration: multiple wait" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.ShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("sleep 0.05 & sleep 0.05 & wait; echo 'all waited'");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "all waited");
}
