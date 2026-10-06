const std = @import("std");
const test_utils = @import("test_utils.zig");

// ============================================================================
// History Tests
//
// These drive the den binary, with den started in the fixture's temp directory
// so the `den.jsonc` written there redirects the history file into the temp
// directory too. Without that, a history test reads the developer's own
// ~/.den_history and asserts against whatever happens to be in it.
//
// A non-interactive shell does not record what it runs -- den, zsh and bash all
// behave that way -- so what is testable here is loading an existing history
// and the `history` builtin's own behaviour, not capture. Capture is covered by
// driving a pty, which this harness cannot do.
// ============================================================================

/// Write a file into the temp directory, freeing the path it hands back.
fn put(fixture: *test_utils.DenShellFixture, name: []const u8, content: []const u8) !void {
    const path = try fixture.createFile(name, content);
    std.testing.allocator.free(path);
}

/// Point den's history at a file inside the temp directory and seed it.
fn seedHistory(fixture: *test_utils.DenShellFixture, entries: []const u8) !void {
    try put(fixture, "den.jsonc",
        \\{
        \\  "history": { "file": "hist" }
        \\}
    );
    try put(fixture, "hist", entries);
}

test "history: lists the loaded entries, numbered from one" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    try seedHistory(&fixture, "echo alpha\necho beta\necho gamma\n");

    const result = try fixture.execInTempDir("history");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "1  echo alpha");
    try test_utils.TestAssert.expectContains(result.stdout, "2  echo beta");
    try test_utils.TestAssert.expectContains(result.stdout, "3  echo gamma");
}

test "history: a count shows the most recent entries, keeping their numbers" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    try seedHistory(&fixture, "echo one\necho two\necho three\necho four\n");

    const result = try fixture.execInTempDir("history 2");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "3  echo three");
    try test_utils.TestAssert.expectContains(result.stdout, "4  echo four");
    // The earlier two are left out rather than renumbered.
    try test_utils.TestAssert.expectEqual(@as(?usize, null), std.mem.indexOf(u8, result.stdout, "echo one"));
    try test_utils.TestAssert.expectEqual(@as(?usize, null), std.mem.indexOf(u8, result.stdout, "echo two"));
}

test "history: a count larger than the history shows all of it" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    try seedHistory(&fixture, "echo only\n");

    const result = try fixture.execInTempDir("history 50");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "echo only");
}

test "history: a repeated command is kept once, at its most recent position" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    try seedHistory(&fixture, "echo dup\necho middle\necho dup\n");

    const result = try fixture.execInTempDir("history");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);

    // One occurrence, and it sorts after the entry that came between the two.
    var count: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, result.stdout, i, "echo dup")) |pos| : (i = pos + 1) count += 1;
    try test_utils.TestAssert.expectEqual(@as(usize, 1), count);

    const dup_at = std.mem.indexOf(u8, result.stdout, "echo dup").?;
    const mid_at = std.mem.indexOf(u8, result.stdout, "echo middle").?;
    try test_utils.TestAssert.expectTrue(mid_at < dup_at);
}

test "history: an empty history lists nothing and still succeeds" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    try seedHistory(&fixture, "");

    const result = try fixture.execInTempDir("history");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectEqual(@as(usize, 0), std.mem.trim(u8, result.stdout, " \n\t\r").len);
}

test "history: a non-interactive shell does not record what it runs" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();
    try seedHistory(&fixture, "echo seeded\n");

    // zsh and bash behave the same way: `-c` runs commands without adding them
    // to the history. Only the seeded entry is listed.
    const result = try fixture.execInTempDir("echo not_recorded; history");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "not_recorded");
    try test_utils.TestAssert.expectContains(result.stdout, "echo seeded");
    try test_utils.TestAssert.expectEqual(
        @as(?usize, null),
        std.mem.indexOf(u8, result.stdout, "1  echo not_recorded"),
    );
}

test "history: the file den reads comes from config, not a fixed path" {
    const allocator = std.testing.allocator;

    var fixture = try test_utils.DenShellFixture.init(allocator);
    defer fixture.deinit();

    // Guards the hermeticity the rest of this file depends on: with the config
    // pointing elsewhere, the seeded file is the one that is read.
    try put(&fixture, "den.jsonc",
        \\{
        \\  "history": { "file": "custom_history" }
        \\}
    );
    try put(&fixture, "custom_history", "echo from_custom_file\n");
    try put(&fixture, "hist", "echo wrong_file\n");

    const result = try fixture.execInTempDir("history");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try test_utils.TestAssert.expectEqual(@as(u8, 0), result.exit_code);
    try test_utils.TestAssert.expectContains(result.stdout, "from_custom_file");
    try test_utils.TestAssert.expectEqual(@as(?usize, null), std.mem.indexOf(u8, result.stdout, "wrong_file"));
}
