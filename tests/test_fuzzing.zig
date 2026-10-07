const std = @import("std");
const test_utils = @import("test_utils.zig");
const TestAssert = test_utils.TestAssert;
const DenShellFixture = test_utils.DenShellFixture;
const TempDir = test_utils.TempDir;

// Comprehensive Fuzzing Tests
// Tests for completion, expansion, and input handling robustness
//
// These run den. They used to run /bin/sh through ShellFixture, so whatever
// they found was a property of the system shell and nothing here was ever
// exercised -- and one of the inputs left /bin/sh waiting on the test runner's
// terminal, so the suite hung rather than finishing.

/// Run one fuzz input and check the one thing a fuzz case can promise.
///
/// The exit status is deliberately not asserted: many of these inputs are
/// errors and ought to fail. What is never a correct answer is den being killed
/// by a signal, or hanging -- the fixture points stdin at /dev/null so a command
/// that reads it cannot block.
fn fuzz(fixture: *DenShellFixture, allocator: std.mem.Allocator, input: []const u8) !void {
    const result = try fixture.exec(input);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.signaled) {
        std.debug.print("den was killed by a signal on input: {s}\n", .{input});
        return error.ShellCrashed;
    }
}

// =============================================================================
// Variable Expansion Fuzzing
// =============================================================================

test "fuzz: variable expansion with special chars" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const test_vars = [_][]const u8{
        "FUZZ_EMPTY=",
        "FUZZ_SPACE=hello world",
        "FUZZ_SPECIAL=!@#$%^&*()",
        "FUZZ_NEWLINE=hello\nworld",
        "FUZZ_TAB=hello\tworld",
        "FUZZ_QUOTE=it's",
        "FUZZ_DQUOTE=he said \"hi\"",
    };

    for (test_vars) |var_def| {
        var cmd_buf: [256]u8 = undefined;
        const cmd = std.fmt.bufPrint(&cmd_buf, "export {s} && echo done", .{var_def}) catch continue;

        try fuzz(&fixture, allocator, cmd);

        // Should not crash
    }
}

test "fuzz: nested variable expansion" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const inputs = [_][]const u8{
        "echo ${UNDEFINED:-default}",
        "echo ${UNDEFINED:+alternate}",
        "echo ${VAR:-${FALLBACK:-final}}",
        "echo ${#PATH}",
        "echo ${VAR:0:5}",
    };

    for (inputs) |input| {
        try fuzz(&fixture, allocator, input);
    }
}

test "fuzz: arithmetic expansion edge cases" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const inputs = [_][]const u8{
        "echo $((0))",
        "echo $((1+1))",
        "echo $((2*3))",
        "echo $((10/2))",
        "echo $((10%3))",
        "echo $((-5))",
        "echo $((2147483647))",
        "echo $((-2147483648))",
        "echo $((1<<2))",
        "echo $((8>>1))",
        "echo $((5&3))",
        "echo $((5|3))",
        "echo $((5^3))",
    };

    for (inputs) |input| {
        try fuzz(&fixture, allocator, input);
    }
}

test "fuzz: command substitution nesting" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const inputs = [_][]const u8{
        "echo $(echo a)",
        "echo $(echo $(echo b))",
        "echo $(echo $(echo $(echo c)))",
        "echo `echo d`",
        "echo $(echo `echo e`)",
    };

    for (inputs) |input| {
        try fuzz(&fixture, allocator, input);
    }
}

// =============================================================================
// Glob/Pathname Expansion Fuzzing
// =============================================================================

test "fuzz: glob patterns" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const inputs = [_][]const u8{
        "echo *",
        "echo ?",
        "echo [abc]",
        "echo [a-z]",
        "echo [!a-z]",
        "echo **",
        "echo ***",
        "echo .[!.]*",
        "echo */",
        "echo *.{txt,md}",
    };

    for (inputs) |input| {
        try fuzz(&fixture, allocator, input);
    }
}

test "fuzz: brace expansion" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const inputs = [_][]const u8{
        "echo {a,b,c}",
        "echo {1..5}",
        "echo {a..e}",
        "echo {1..10..2}",
        "echo {a,b}{1,2}",
        "echo {{a,b},{c,d}}",
        "echo {01..10}",
    };

    for (inputs) |input| {
        try fuzz(&fixture, allocator, input);
    }
}

test "fuzz: tilde expansion" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const inputs = [_][]const u8{
        "echo ~",
        "echo ~/",
        "echo ~/test",
        "echo ~root",
        "echo ~nobody",
        "echo ~+",
        "echo ~-",
    };

    for (inputs) |input| {
        try fuzz(&fixture, allocator, input);
    }
}

// =============================================================================
// Input Handling Fuzzing
// =============================================================================

test "fuzz: control characters" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    // Test printable commands (control chars in strings would be problematic)
    const inputs = [_][]const u8{
        "echo test",
        "echo 'test'",
        "echo \"test\"",
    };

    for (inputs) |input| {
        try fuzz(&fixture, allocator, input);
    }
}

test "fuzz: escape sequences" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const inputs = [_][]const u8{
        "echo \\n",
        "echo \\t",
        "echo \\r",
        "echo \\\\",
        "echo \\'",
        "echo \\\"",
        "echo \\$",
        "echo \\`",
    };

    for (inputs) |input| {
        try fuzz(&fixture, allocator, input);
    }
}

test "fuzz: line continuations" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    // Line continuation with backslash-newline
    const inputs = [_][]const u8{
        "echo hello\\\nworld",
        "echo hel\\\nlo",
    };

    for (inputs) |input| {
        try fuzz(&fixture, allocator, input);
    }
}

test "fuzz: long lines" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    // Test long command lines
    var long_cmd: [4096]u8 = undefined;
    var pos: usize = 0;

    // Build "echo aaa...aaa"
    const echo_prefix = "echo ";
    @memcpy(long_cmd[0..echo_prefix.len], echo_prefix);
    pos = echo_prefix.len;

    while (pos < 2000) {
        long_cmd[pos] = 'a';
        pos += 1;
    }

    const result = try fixture.exec(long_cmd[0..pos]);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expect(!result.signaled);
    // A 2000-character echo is long but perfectly valid, so this one does have
    // a right answer.
    try TestAssert.expectEqual(@as(u8, 0), result.exit_code);
}

test "fuzz: unicode input" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const inputs = [_][]const u8{
        "echo 'hello 世界'",
        "echo 'مرحبا'",
        "echo '🎉🎊🎈'",
        "echo 'Привет'",
        "echo 'こんにちは'",
        "echo '한글'",
    };

    for (inputs) |input| {
        const result = try fixture.exec(input);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        try std.testing.expect(!result.signaled);
        // Echoing text is valid whatever script it is written in.
        try TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    }
}

// =============================================================================
// Completion Fuzzing
// =============================================================================

test "fuzz: path completion patterns" {
    const allocator = std.testing.allocator;
    var temp_dir = try TempDir.init(allocator);
    defer temp_dir.deinit();

    // Create some test files. createFile/createDir return owned paths, so
    // free them to avoid leaking under the testing allocator.
    inline for (.{ "test1.txt", "test2.txt", "README.md" }) |name| {
        allocator.free(try temp_dir.createFile(name, ""));
    }
    allocator.free(try temp_dir.createDir("subdir"));

    // Verify directory exists
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, temp_dir.path, .{});
    dir.close(std.testing.io);
}

test "fuzz: command name patterns" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    // Test various command patterns
    const cmds = [_][]const u8{
        "echo",
        "cat",
        "ls",
        "pwd",
        "true",
        "false",
    };

    for (cmds) |cmd| {
        try fuzz(&fixture, allocator, cmd);
    }
}

// =============================================================================
// Redirection Fuzzing
// =============================================================================

test "fuzz: redirection patterns" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const inputs = [_][]const u8{
        "echo test > /dev/null",
        "echo test >> /dev/null",
        "cat < /dev/null",
        "echo test 2> /dev/null",
        "echo test &> /dev/null",
        "echo test 2>&1",
        "echo test 1>&2",
    };

    for (inputs) |input| {
        try fuzz(&fixture, allocator, input);
    }
}

test "fuzz: here-doc patterns" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const inputs = [_][]const u8{
        "cat << EOF\nhello\nEOF",
        "cat <<- EOF\n\thello\n\tEOF",
        "cat << 'EOF'\n$HOME\nEOF",
    };

    for (inputs) |input| {
        try fuzz(&fixture, allocator, input);
    }
}

test "fuzz: here-string" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const inputs = [_][]const u8{
        "cat <<< 'hello'",
        "cat <<< \"hello world\"",
        "cat <<< $HOME",
    };

    for (inputs) |input| {
        try fuzz(&fixture, allocator, input);
    }
}

// =============================================================================
// Pipeline Fuzzing
// =============================================================================

test "fuzz: deep pipelines" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const inputs = [_][]const u8{
        "echo a | cat",
        "echo a | cat | cat",
        "echo a | cat | cat | cat",
        "echo a | cat | cat | cat | cat",
        "echo a | cat | cat | cat | cat | cat",
    };

    for (inputs) |input| {
        const result = try fixture.exec(input);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        try std.testing.expect(!result.signaled);
        // However deep the pipeline, `a` has to come out the far end.
        try TestAssert.expectEqual(@as(u8, 0), result.exit_code);
        try TestAssert.expectContains(result.stdout, "a");
    }
}

test "fuzz: pipeline with redirections" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const inputs = [_][]const u8{
        "echo test | cat > /dev/null && echo done",
        "echo test 2>&1 | cat",
        "cat /dev/null | echo test",
    };

    for (inputs) |input| {
        try fuzz(&fixture, allocator, input);
    }
}

// =============================================================================
// Operator Combination Fuzzing
// =============================================================================

test "fuzz: operator combinations" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const inputs = [_][]const u8{
        "true && echo success",
        "false || echo fallback",
        "true && false || echo recovered",
        "false || true && echo chain",
        "true; false; true",
        "echo a; echo b; echo c",
        "true && true && true && echo all",
        "false || false || false || echo none",
    };

    for (inputs) |input| {
        try fuzz(&fixture, allocator, input);
    }
}

test "fuzz: negation operator" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const inputs = [_][]const u8{
        "! true",
        "! false",
        "! ! true",
        "! true && echo fail || echo success",
    };

    for (inputs) |input| {
        try fuzz(&fixture, allocator, input);
    }
}

// =============================================================================
// Subshell and Grouping Fuzzing
// =============================================================================

test "fuzz: subshell patterns" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const inputs = [_][]const u8{
        "(echo hello)",
        "(echo a; echo b)",
        "(cd /tmp && pwd)",
        "(true && echo yes)",
        "( ( echo nested ) )",
    };

    for (inputs) |input| {
        try fuzz(&fixture, allocator, input);
    }
}

test "fuzz: brace grouping patterns" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const inputs = [_][]const u8{
        "{ echo hello; }",
        "{ echo a; echo b; }",
        "{ true && echo yes; }",
    };

    for (inputs) |input| {
        try fuzz(&fixture, allocator, input);
    }
}

// =============================================================================
// Edge Case Fuzzing
// =============================================================================

test "fuzz: empty and whitespace" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const inputs = [_][]const u8{
        "",
        " ",
        "  ",
        "\t",
        "\n",
        "   \t\n   ",
    };

    for (inputs) |input| {
        try fuzz(&fixture, allocator, input);
    }
}

test "fuzz: special shell variables" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const inputs = [_][]const u8{
        "echo $?",
        "echo $$",
        "echo $!",
        "echo $0",
        "echo $#",
        "echo $@",
        "echo $*",
    };

    for (inputs) |input| {
        try fuzz(&fixture, allocator, input);
    }
}

test "fuzz: word splitting edge cases" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const inputs = [_][]const u8{
        "echo \"hello world\"",
        "echo 'hello world'",
        "echo hello\\ world",
        "echo \"$HOME\"",
        "echo '$HOME'",
    };

    for (inputs) |input| {
        try fuzz(&fixture, allocator, input);
    }
}

// =============================================================================
// The guard itself
// =============================================================================

test "fuzz: a crash is actually detected" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    // Every test above rests on `signaled`, so it is worth proving it reports
    // what it claims. Without this, breaking the fixture would quietly turn the
    // whole suite vacuous again -- which is the state it was in when it ran
    // /bin/sh and asserted nothing.
    const result = try fixture.exec("kill -SEGV $$");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expect(result.signaled);
}
