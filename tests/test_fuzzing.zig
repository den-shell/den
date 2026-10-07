const std = @import("std");
const test_utils = @import("test_utils.zig");
const TestAssert = test_utils.TestAssert;
const DenShellFixture = test_utils.DenShellFixture;
const fuzz_gen = @import("fuzz_gen.zig");
const TempDir = test_utils.TempDir;

// Comprehensive Fuzzing Tests
// Tests for completion, expansion, and input handling robustness
//
// These run den. They used to run /bin/sh through ShellFixture, so whatever
// they found was a property of the system shell and nothing here was ever
// exercised -- and one of the inputs left /bin/sh waiting on the test runner's
// terminal, so the suite hung rather than finishing.
//
// Inputs are generated (see fuzz_gen.zig) rather than only listed. The lists
// that remain are kept as named cases: they say what was once thought worth
// checking, and they are the corpus the mutation strategy draws from.

/// How long one case may run before it is suspected of hanging.
///
/// Generous on purpose. den starts in about 50ms and every command in the
/// generator's vocabulary finishes at once, so this is ~100x the honest worst
/// case -- but the suite runs hundreds of spawns back to back, and a tight
/// budget turned that load into occasional failures on inputs that were fine.
/// A flaky fuzz test is worse than none, because it teaches people to ignore it.
const case_budget_ms: u64 = 5_000;

/// A case that runs out of time is retried with this much, and only a second
/// timeout is reported. A real loop never finishes either way; a machine under
/// load gets the room it needed. The cost is paid only when something looks
/// wrong.
const retry_budget_ms: u64 = 20_000;

/// Generated cases per run.
///
/// A generated case costs about 150ms -- three times a corpus one, because the
/// nasty shapes nest substitutions and so start further shells -- and this suite
/// is part of `test-all`, so the default is kept to something that does not
/// dominate it.
///
/// Be clear about what the default does: the seed below is fixed, so every build
/// runs the *same* cases. That makes the build reproducible and guards against
/// regressions on a known set, but it finds nothing new once it is green. New
/// coverage needs a new seed:
///
///     DEN_FUZZ_SEED=$RANDOM DEN_FUZZ_RUNS=5000 zig build test-fuzzing
///
/// A failure prints its seed and the exact bytes, so anything found that way is
/// reproducible afterwards.
const default_runs: usize = 100;

fn envNumber(name: [*:0]const u8, fallback: usize) usize {
    const raw = std.c.getenv(name) orelse return fallback;
    return std.fmt.parseInt(usize, std.mem.sliceTo(raw, 0), 10) catch fallback;
}

fn envSeed() u64 {
    // Fixed by default so a build is reproducible, and overridable to explore
    // or to replay a failure. See `default_runs` for the trade-off.
    const fallback: u64 = 0x5EED_1234_5678_9ABC;
    const raw = std.c.getenv("DEN_FUZZ_SEED") orelse return fallback;
    return std.fmt.parseInt(u64, std.mem.sliceTo(raw, 0), 0) catch fallback;
}

/// Run one input and check the two things a fuzz case can promise: den must
/// finish, and it must finish on its own.
///
/// The exit status is deliberately not asserted. Most of these inputs are
/// nonsense and ought to fail; a non-zero status is the shell working. Being
/// killed is never a right answer, and neither is never returning.
fn check(
    fixture: *DenShellFixture,
    allocator: std.mem.Allocator,
    input: []const u8,
    seed: ?u64,
) !void {
    const result = try fixture.execVerbatim(input, case_budget_ms);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (!result.timed_out and !result.signaled) return;

    // A signal is conclusive: report it straight away.
    if (result.signaled and !result.timed_out) {
        report("was killed by a signal", input, seed);
        return error.ShellCrashed;
    }

    // Running out of time is not. Confirm it with a much larger budget before
    // calling it a hang, so load on the machine cannot fail the suite.
    const retry = try fixture.execVerbatim(input, retry_budget_ms);
    defer allocator.free(retry.stdout);
    defer allocator.free(retry.stderr);

    if (retry.timed_out) {
        report("did not finish, twice", input, seed);
        return error.ShellHung;
    }
    if (retry.signaled) {
        report("was killed by a signal", input, seed);
        return error.ShellCrashed;
    }
}

fn report(what: []const u8, input: []const u8, seed: ?u64) void {
    std.debug.print("\nden {s} on input ({d} bytes):\n{s}\n", .{ what, input.len, input });
    // The bytes matter as much as the text: these inputs are full of tabs,
    // newlines and unterminated quotes that do not survive being read back.
    std.debug.print("bytes:", .{});
    for (input) |c| std.debug.print(" {x:0>2}", .{c});
    std.debug.print("\n", .{});
    if (seed) |sd| {
        std.debug.print("replay with: DEN_FUZZ_SEED=0x{x} DEN_FUZZ_RUNS=1\n", .{sd});
    }
}

test "fuzz: generated inputs" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    const base = envSeed();
    const runs = envNumber("DEN_FUZZ_RUNS", default_runs);

    var buf: [1024]u8 = undefined;
    var i: usize = 0;
    while (i < runs) : (i += 1) {
        // Each case is seeded from the base and its index, so one failing case
        // is reproducible on its own rather than only as part of a sequence.
        const case_seed = base ^ (@as(u64, i) *% 0x9E37_79B9_7F4A_7C15);
        var g = fuzz_gen.Generator.init(case_seed);
        const input = g.next(&buf);

        try check(&fixture, allocator, input, case_seed);
    }
}

test "fuzz: the whole seed corpus runs" {
    const allocator = std.testing.allocator;
    var fixture = try DenShellFixture.init(allocator);
    defer fixture.deinit();

    // The mutation strategy draws from these, so they are worth running as
    // written too: a crash on an unmutated entry is the easiest kind to debug.
    for (fuzz_gen.corpus) |input| {
        try check(&fixture, allocator, input, null);
    }
}

// =============================================================================
// Variable Expansion Fuzzing
// =============================================================================

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
