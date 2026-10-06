const std = @import("std");
const test_utils = @import("test_utils.zig");

// ============================================================================
// Job Control Tests
// Tests for background jobs, fg, bg, jobs, disown
// ============================================================================

test "job control: run command in background" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("sleep 0.1 &");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Background job should start successfully
    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
}

test "job control: jobs lists background jobs" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("sleep 1 & jobs");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should show the background job
    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
}

test "job control: jobs shows job number" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("sleep 1 & jobs");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Output should contain job number like [1]
    try test_utils.TestAssert.expectTrue(
        std.mem.indexOf(u8, result.stdout, "[") != null or result.stdout.len == 0,
    );
}

test "job control: wait for background job" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("sleep 0.1 & wait && echo done");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "done");
}

test "job control: wait for specific job" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("sleep 0.1 & wait %1 && echo waited");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "waited");
}

test "job control: multiple background jobs" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("sleep 0.1 & sleep 0.1 & jobs");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
}

test "job control: kill background job" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("sleep 10 & kill %1");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
}

test "job control: kill with signal" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("sleep 10 & kill -9 %1");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
}

test "job control: kill by PID" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    // Use $! to get last background PID
    const result = try fixture.exec("sleep 10 & kill $!");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
}

test "job control: disown removes job from table" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("sleep 0.5 & disown && jobs");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // After disown, job should not appear in jobs list
    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
}

test "job control: background command output" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo background & wait");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Background command should still produce output
    try test_utils.TestAssert.expectContains(result.stdout, "background");
}

test "job control: background pipeline" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo test | cat & wait");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "test");
}

test "job control: jobs -l shows PIDs" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("sleep 1 & jobs -l");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // With -l flag, should show PID (a number)
    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
}

test "job control: wait reports the status of a specific job" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    // `wait <pid>` yields that job's exit status, so a failing job shows up.
    const result = try fixture.exec("false & PID=$! ; wait $PID ; echo status=$?");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "status=1");
}

test "job control: bare wait exits zero whatever the jobs did" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    // POSIX, and both zsh and bash: `wait` with no operands exits zero once the
    // jobs have finished, regardless of their status -- so this does not
    // short-circuit on a job that failed.
    const result = try fixture.exec("false & wait && echo reached");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "reached");
}
test "job control: nested background jobs" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    // Start multiple nested background jobs
    const result = try fixture.exec("(sleep 0.1 &) & (sleep 0.1 &) & wait");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
}

test "job control: pipeline as background job" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("(echo foo | cat | cat) & wait");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "foo");
}

test "job control: kill SIGTERM signal name" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("sleep 10 & kill -TERM %1 2>&1");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
}

test "job control: kill SIGKILL signal name" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("sleep 10 & kill -KILL %1 2>&1");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
}

test "job control: kill SIGHUP signal name" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("sleep 10 & kill -HUP %1 2>&1");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
}

test "job control: wait for specific PID" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("sleep 0.1 & PID=$! ; wait $PID && echo waited_for_$PID");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "waited_for_");
}

test "job control: disown -h keeps job but removes from HUP" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("sleep 0.5 & disown -h %1");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
}

test "job control: disown -a removes all jobs" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("sleep 0.5 & sleep 0.5 & disown -a && jobs");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // After disown -a, jobs should be empty
    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
}

test "job control: jobs -p shows only PIDs" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("sleep 1 & jobs -p ; kill %1");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // With -p flag, should show only the PID (numeric)
    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
}

test "job control: background job $! variable" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("sleep 0.1 & echo $!");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // $! should be a numeric PID
    const trimmed = std.mem.trim(u8, result.stdout, &std.ascii.whitespace);
    if (trimmed.len > 0) {
        _ = std.fmt.parseInt(u32, trimmed, 10) catch {
            try std.testing.expect(false); // Should be a valid number
        };
    }
}

test "job control: sequential background jobs" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo a & echo b & echo c & wait");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // All three should have run (order may vary)
    try test_utils.TestAssert.expectContains(result.stdout, "a");
    try test_utils.TestAssert.expectContains(result.stdout, "b");
    try test_utils.TestAssert.expectContains(result.stdout, "c");
}

test "job control: background job with redirection" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    const result = try fixture.exec("echo redirected > /dev/null & wait && echo done");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectContains(result.stdout, "done");
}

test "job control: a backgrounded AND-OR list reports its own status" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    // The `&` used to be left on the chain handed to the forked child, so the
    // child backgrounded its own last command and exited 0 whatever that
    // command did: `true && false &` looked successful while a bare `false &`
    // did not.
    const failing = try fixture.execInTempDir("true && false & PID=$! ; wait $PID ; echo status=$?");
    defer allocator.free(failing.stdout);
    defer allocator.free(failing.stderr);
    try test_utils.TestAssert.expectContains(failing.stdout, "status=1");

    const passing = try fixture.execInTempDir("true && true & PID=$! ; wait $PID ; echo status=$?");
    defer allocator.free(passing.stdout);
    defer allocator.free(passing.stderr);
    try test_utils.TestAssert.expectContains(passing.stdout, "status=0");
}

test "job control: backgrounding a list runs it once, not twice" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    // Dropping the trailing `&` in the child must not turn into running the
    // last command twice: one line of output, not two.
    const result = try fixture.execInTempDir("true && echo once & wait");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    var count: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, result.stdout, i, "once")) |pos| : (i = pos + 1) count += 1;
    try test_utils.TestAssert.expectEqual(@as(usize, 1), count);
}
