const std = @import("std");
const builtin = @import("builtin");
const IO = @import("../utils/io.zig").IO;
const types = @import("../types/mod.zig");
const cpu_opt = @import("../utils/cpu_opt.zig");

/// Most bytes of the history file read at startup. Only the tail is read: the
/// newest commands are the ones worth keeping when a file outgrows this.
const MAX_READ_SIZE: u64 = 1024 * 1024;

/// Trim a raw history line and reject the ones that aren't usable commands.
///
/// A crashed or concurrently-truncated write can leave a run of NUL bytes in the
/// file; those survive `std.mem.trim` (NUL is not ASCII whitespace) and would
/// otherwise be loaded as a giant unusable "command".
fn sanitizeEntry(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
    if (trimmed.len == 0) return null;
    for (trimmed) |c| {
        if (c < 0x20 and c != '\t') return null; // NUL padding or binary junk
    }
    return trimmed;
}

/// Read up to `max_size` bytes from the end of `file`, returning whole lines.
/// A partial first line (from landing mid-command) is dropped. Caller owns the
/// returned slice.
fn readTail(allocator: std.mem.Allocator, file: std.Io.File, max_size: u64) ![]u8 {
    const file_size = (try file.stat(std.Options.debug_io)).size;
    if (file_size == 0) return allocator.alloc(u8, 0);

    const start_offset: u64 = if (file_size > max_size) file_size - max_size else 0;
    if (start_offset > 0) {
        if (builtin.os.tag == .windows) {
            // No seek helper on the Windows path; read and discard the head.
            var discard: [4096]u8 = undefined;
            var skipped: u64 = 0;
            while (skipped < start_offset) {
                const want: usize = @intCast(@min(discard.len, start_offset - skipped));
                var n: u32 = 0;
                const ok = @import("windows_compat").ReadFile(file.handle, &discard, @intCast(want), &n, null);
                if (ok == 0 or n == 0) break;
                skipped += n;
            }
        } else if (std.c.lseek(file.handle, @intCast(start_offset), std.c.SEEK.SET) < 0) {
            return error.SeekFailed;
        }
    }

    const read_size: usize = @intCast(file_size - start_offset);
    const buffer = try allocator.alloc(u8, read_size);
    errdefer allocator.free(buffer);

    var total_read: usize = 0;
    while (total_read < read_size) {
        const bytes_read = if (builtin.os.tag == .windows) blk: {
            var n: u32 = 0;
            const remaining = buffer[total_read..];
            const success = @import("windows_compat").ReadFile(file.handle, remaining.ptr, @intCast(remaining.len), &n, null);
            break :blk if (success == 0) @as(usize, 0) else @as(usize, n);
        } else try std.posix.read(file.handle, buffer[total_read..]);
        if (bytes_read == 0) break;
        total_read += bytes_read;
    }

    // Starting mid-file almost certainly split a command in half; drop it.
    var content: []u8 = buffer[0..total_read];
    if (start_offset > 0) {
        content = if (std.mem.indexOfScalar(u8, content, '\n')) |nl|
            content[nl + 1 ..]
        else
            content[0..0];
    }
    if (content.len == buffer.len) return buffer;

    // Hand back an exactly-sized allocation so the caller's free() matches.
    const exact = try allocator.dupe(u8, content);
    allocator.free(buffer);
    return exact;
}

/// Build a sibling temp path for an atomic replace. The pid keeps two shells
/// exiting at the same moment from fighting over the same scratch file.
fn tempPath(buf: []u8, path: []const u8) ![]const u8 {
    const pid = if (builtin.os.tag == .windows) 0 else std.c.getpid();
    return std.fmt.bufPrint(buf, "{s}.tmp.{d}", .{ path, pid });
}

/// History utilities extracted from the shell core.
///
/// This module centralizes history storage, persistence, and builtin
/// behavior so that the shell can delegate to it.
pub const History = struct {
    /// Add command to history with de-duplication and optional incremental
    /// append to the history file.
    pub fn add(
        allocator: std.mem.Allocator,
        history: []?[]const u8,
        history_count: *usize,
        history_file_path: []const u8,
        command: []const u8,
    ) !void {
        // Don't add empty commands or duplicate of last command
        if (command.len == 0) return;

        // Skip if same as last command (consecutive deduplication)
        if (history_count.* > 0) {
            if (history[history_count.* - 1]) |last_cmd| {
                if (std.mem.eql(u8, last_cmd, command)) {
                    return; // Skip consecutive duplicate
                }
            }
        }

        // Optional: Also check for duplicates in recent history (more aggressive)
        // This prevents duplicate commands even if they're not consecutive
        const check_last_n = @min(history_count.*, @min(history.len, 50));
        var i: usize = 0;
        while (i < check_last_n) : (i += 1) {
            const idx = history_count.* - 1 - i;
            if (history[idx]) |cmd_entry| {
                if (std.mem.eql(u8, cmd_entry, command)) {
                    // Found duplicate in recent history - remove old one and add at end
                    allocator.free(cmd_entry);

                    // Shift entries to remove the duplicate
                    var j = idx;
                    while (j < history_count.* - 1) : (j += 1) {
                        history[j] = history[j + 1];
                    }
                    history[history_count.* - 1] = null;
                    history_count.* -= 1;
                    break;
                }
            }
        }

        // If history is full, shift everything left
        if (history_count.* >= history.len) {
            // Free oldest entry
            if (history[0]) |oldest| {
                allocator.free(oldest);
            }

            // Shift all entries left
            var m: usize = 0;
            while (m < history.len - 1) : (m += 1) {
                history[m] = history[m + 1];
            }
            history[history.len - 1] = null;
            history_count.* -= 1;
        }

        // Add new entry
        const cmd_copy = try allocator.dupe(u8, command);
        history[history_count.*] = cmd_copy;
        history_count.* += 1;

        // Incremental append to history file (zsh-style)
        appendToFile(history_file_path, command) catch {
            // Ignore errors when appending to history file
        };
    }

    /// Whether a raw input line asks to be kept out of history by starting with
    /// whitespace — the usual way to run a command with a secret in it.
    ///
    /// Takes the line *before* trimming, which is the whole point: once the
    /// leading space is trimmed away the request is gone.
    pub fn isPrivate(raw_line: []const u8) bool {
        if (raw_line.len == 0) return false;
        return raw_line[0] == ' ' or raw_line[0] == '\t';
    }

    /// Load history from a file into the in-memory buffer with de-duplication.
    ///
    /// Recency is the whole point of this ordering: the inline autosuggestion and
    /// Up-arrow both walk the buffer backwards, so an entry's slot has to reflect
    /// the *last* time it ran, not the first. De-duplication therefore keeps the
    /// newest occurrence of a repeated command and the buffer is filled from the
    /// end of the file backwards, so an oversized file drops its oldest entries
    /// rather than its newest.
    pub fn load(
        allocator: std.mem.Allocator,
        history: []?[]const u8,
        history_count: *usize,
        history_file_path: []const u8,
    ) !void {
        const file = std.Io.Dir.cwd().openFile(std.Options.debug_io, history_file_path, .{}) catch |err| {
            if (err == error.FileNotFound) return; // File doesn't exist yet
            return err;
        };
        defer file.close(std.Options.debug_io);

        if (history_count.* >= history.len) return; // No room for anything

        const buffer = try readTail(allocator, file, MAX_READ_SIZE);
        defer allocator.free(buffer);
        const content = buffer;

        // De-duplicate newest-first so a repeated command lands at the position of
        // its most recent run. Uses a StringHashMap for O(1) dedup instead of an
        // O(n) linear scan.
        var seen = std.StringHashMap(void).init(allocator);
        defer seen.deinit();
        // Pre-populate with any existing entries so cross-load dedup works
        var pre_i: usize = 0;
        while (pre_i < history_count.*) : (pre_i += 1) {
            if (history[pre_i]) |existing| {
                try seen.put(existing, {});
            }
        }

        // Collect the entries to keep, newest first, stopping once the buffer's
        // remaining capacity is full. Keys borrow `buffer`, which outlives `seen`.
        const capacity = history.len - history_count.*;
        var newest_first = std.array_list.Managed([]const u8).init(allocator);
        defer newest_first.deinit();

        var iter = std.mem.splitBackwardsScalar(u8, content, '\n');
        while (iter.next()) |line| {
            if (newest_first.items.len >= capacity) break;
            const entry = sanitizeEntry(line) orelse continue;
            if (seen.contains(entry)) continue;
            try seen.put(entry, {});
            try newest_first.append(entry);
        }

        // Write them back out oldest-first so the buffer stays chronological.
        var idx = newest_first.items.len;
        while (idx > 0) {
            idx -= 1;
            const cmd_copy = try allocator.dupe(u8, newest_first.items[idx]);
            history[history_count.*] = cmd_copy;
            history_count.* += 1;
        }
    }

    /// Save the entire history buffer to the history file.
    ///
    /// Written to a sibling temp file and renamed into place: a half-written
    /// history file is worse than a stale one, and an in-place truncate races
    /// every other shell appending to the same path.
    pub fn save(history: []?[]const u8, history_file_path: []const u8) !void {
        var tmp_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const tmp_path = tempPath(&tmp_buf, history_file_path) catch {
            // Path too long to build a temp name — fall back to writing in place.
            return saveInPlace(history, history_file_path);
        };

        {
            const file = try std.Io.Dir.cwd().createFile(std.Options.debug_io, tmp_path, .{});
            defer file.close(std.Options.debug_io);
            errdefer std.Io.Dir.cwd().deleteFile(std.Options.debug_io, tmp_path) catch {};

            for (history) |maybe_entry| {
                if (maybe_entry) |entry| {
                    try file.writeStreamingAll(std.Options.debug_io, entry);
                    try file.writeStreamingAll(std.Options.debug_io, "\n");
                }
            }
        }

        errdefer std.Io.Dir.cwd().deleteFile(std.Options.debug_io, tmp_path) catch {};
        try std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), history_file_path, std.Options.debug_io);
    }

    fn saveInPlace(history: []?[]const u8, history_file_path: []const u8) !void {
        const file = try std.Io.Dir.cwd().createFile(std.Options.debug_io, history_file_path, .{});
        defer file.close(std.Options.debug_io);

        for (history) |maybe_entry| {
            if (maybe_entry) |entry| {
                try file.writeStreamingAll(std.Options.debug_io, entry);
                try file.writeStreamingAll(std.Options.debug_io, "\n");
            }
        }
    }

    /// Append a single command to the history file, creating it if needed.
    ///
    /// Opened O_APPEND and written with a single writev so that shells running
    /// side by side can't overwrite each other's commands or split one command
    /// across two lines. The previous open+lseek+two-writes sequence could do
    /// both, and writing at a stale offset into a file another shell had just
    /// truncated is what left runs of NUL bytes in the file.
    pub fn appendToFile(history_file_path: []const u8, command: []const u8) !void {
        if (builtin.os.tag != .windows) {
            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            if (history_file_path.len >= path_buf.len) return error.NameTooLong;
            @memcpy(path_buf[0..history_file_path.len], history_file_path);
            path_buf[history_file_path.len] = 0;
            const path_z: [*:0]const u8 = @ptrCast(&path_buf);

            const fd = std.c.open(
                path_z,
                .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true },
                @as(std.c.mode_t, 0o600),
            );
            if (fd < 0) return error.OpenFailed;
            defer _ = std.c.close(fd);

            var iov = [_]std.posix.iovec_const{
                .{ .base = command.ptr, .len = command.len },
                .{ .base = "\n", .len = 1 },
            };
            const want: isize = @intCast(command.len + 1);
            if (std.c.writev(fd, &iov, 2) != want) return error.WriteFailed;
            return;
        }

        // Windows: no O_APPEND equivalent here, so keep the seek-to-end path.
        const file = std.Io.Dir.cwd().openFile(
            std.Options.debug_io,
            history_file_path,
            .{ .mode = .write_only },
        ) catch |err| switch (err) {
            error.FileNotFound => try std.Io.Dir.cwd().createFile(
                std.Options.debug_io,
                history_file_path,
                .{},
            ),
            else => return err,
        };
        defer file.close(std.Options.debug_io);

        // Append the command
        try file.writeStreamingAll(std.Options.debug_io, command);
        try file.writeStreamingAll(std.Options.debug_io, "\n");
    }

    /// Rewrite the history file from its own contents: newest occurrence of each
    /// command wins, capped at `max_entries`, written atomically.
    ///
    /// Deliberately does *not* dump the calling shell's in-memory buffer. Every
    /// command is already appended as it runs, so a shell that has been open for
    /// hours holds a stale snapshot; writing that back on exit silently deleted
    /// everything the user's other shells had run in the meantime.
    pub fn compactFile(
        allocator: std.mem.Allocator,
        history_file_path: []const u8,
        max_entries: usize,
    ) !void {
        if (max_entries == 0) return;

        const entries = try allocator.alloc(?[]const u8, max_entries);
        defer allocator.free(entries);
        @memset(entries, null);
        var count: usize = 0;
        defer {
            var i: usize = 0;
            while (i < count) : (i += 1) {
                if (entries[i]) |entry| allocator.free(entry);
            }
        }

        try load(allocator, entries, &count, history_file_path);
        if (count == 0) return;
        try save(entries[0..count], history_file_path);
    }

    /// Whether the file has grown enough to be worth compacting. Rewriting on
    /// every exit is pure churn (and a chance to lose data) when it's already
    /// close to the size the shell keeps in memory.
    pub fn needsCompaction(history_file_path: []const u8, max_entries: usize) bool {
        const file = std.Io.Dir.cwd().openFile(std.Options.debug_io, history_file_path, .{}) catch return false;
        defer file.close(std.Options.debug_io);
        const size = (file.stat(std.Options.debug_io) catch return false).size;

        // ~40 bytes is a generous average command length; compact once the file
        // holds roughly twice what the shell can keep in memory.
        const budget: u64 = @as(u64, max_entries) * 40 * 2;
        return size > budget;
    }

    /// Print history in the same format as the builtin `history` command.
    pub fn printBuiltin(
        history: []?[]const u8,
        history_count: usize,
        cmd: *types.ParsedCommand,
    ) !void {
        var num_entries: usize = history_count;
        if (cmd.args.len > 0) {
            num_entries = std.fmt.parseInt(usize, cmd.args[0], 10) catch {
                try IO.eprint("den: history: {s}: numeric argument required\n", .{cmd.args[0]});
                return;
            };
            if (num_entries > history_count) {
                num_entries = history_count;
            }
        }

        const start_idx = if (num_entries >= history_count) 0 else history_count - num_entries;

        var idx = start_idx;
        while (idx < history_count) : (idx += 1) {
            if (history[idx]) |entry| {
                try IO.print("{d:5}  {s}\n", .{ idx + 1, entry });
            }
        }
    }

    /// Free all history entries and the history file path buffer.
    pub fn deinit(allocator: std.mem.Allocator, history: []?[]const u8, history_file_path: []const u8) void {
        for (history) |maybe_entry| {
            if (maybe_entry) |entry| {
                allocator.free(entry);
            }
        }
        allocator.free(history_file_path);
    }

    /// Fast hash-based exact match search - O(1) average case
    /// Returns the index of the entry if found, null otherwise.
    pub fn fastExactSearch(history: []?[]const u8, history_count: usize, query: []const u8) ?usize {
        if (query.len == 0 or history_count == 0) return null;

        // Compute hash for O(1) lookup hint
        var h: u32 = 5381;
        for (query) |c| {
            h = ((h << 5) +% h) +% c;
        }
        const hash_idx = h % @min(history_count, 256);

        // Check hash position first (likely match)
        if (hash_idx < history_count) {
            if (history[hash_idx]) |entry| {
                if (std.mem.eql(u8, entry, query)) {
                    return hash_idx;
                }
            }
        }

        // Fall back to linear search from end (most recent first)
        var i = history_count;
        while (i > 0) {
            i -= 1;
            if (history[i]) |entry| {
                if (std.mem.eql(u8, entry, query)) {
                    return i;
                }
            }
        }

        return null;
    }

    /// Fuzzy search with scoring - returns best matches sorted by relevance
    /// Returns up to max_results entries with their scores.
    pub fn fuzzySearch(
        allocator: std.mem.Allocator,
        history: []?[]const u8,
        history_count: usize,
        query: []const u8,
        max_results: usize,
    ) ![]FuzzyMatch {
        if (query.len == 0 or history_count == 0) {
            return &[_]FuzzyMatch{};
        }

        var matches = std.array_list.Managed(FuzzyMatch).init(allocator);
        defer matches.deinit();

        // Score all history entries
        var i: usize = 0;
        while (i < history_count) : (i += 1) {
            if (history[i]) |entry| {
                const score = cpu_opt.fuzzyScore(entry, query);
                if (score > 0) {
                    try matches.append(.{ .entry = entry, .index = i, .score = score });
                }
            }
        }

        // Sort by score (descending), then by recency (more recent first)
        const items = matches.items;
        std.mem.sort(FuzzyMatch, items, {}, struct {
            fn lessThan(_: void, a: FuzzyMatch, b: FuzzyMatch) bool {
                if (a.score != b.score) return a.score > b.score;
                return a.index > b.index; // More recent entries first
            }
        }.lessThan);

        // Return top results
        const result_count = @min(items.len, max_results);
        const result = try allocator.alloc(FuzzyMatch, result_count);
        @memcpy(result, items[0..result_count]);
        return result;
    }

    /// Prefix search - find entries starting with query
    /// Returns the most recent match first.
    pub fn prefixSearch(history: []?[]const u8, history_count: usize, prefix: []const u8) ?[]const u8 {
        if (prefix.len == 0 or history_count == 0) return null;

        // Search from most recent
        var i = history_count;
        while (i > 0) {
            i -= 1;
            if (history[i]) |entry| {
                if (cpu_opt.hasPrefix(entry, prefix)) {
                    return entry;
                }
            }
        }
        return null;
    }

    /// Substring search - find entries containing query
    /// Starts from start_idx and searches backwards.
    pub fn substringSearch(
        history: []?[]const u8,
        history_count: usize,
        query: []const u8,
        start_idx: usize,
    ) ?SubstringMatch {
        if (query.len == 0 or history_count == 0) return null;

        var i = @min(start_idx, history_count);
        while (i > 0) {
            i -= 1;
            if (history[i]) |entry| {
                if (std.mem.indexOf(u8, entry, query) != null) {
                    return .{ .entry = entry, .index = i };
                }
            }
        }
        return null;
    }
};

/// Result of a fuzzy search
pub const FuzzyMatch = struct {
    entry: []const u8,
    index: usize,
    score: u8,
};

/// Result of a substring search
pub const SubstringMatch = struct {
    entry: []const u8,
    index: usize,
};

// ============================================================================
// Tests
// ============================================================================

test "appendToFile creates file if missing" {
    const allocator = std.testing.allocator;

    // Use a path in a temp dir so we can clean up
    const tmp_name = "den_test_history_append.tmp";

    // Ensure it doesn't exist first
    std.Io.Dir.cwd().deleteFile(std.Options.debug_io, tmp_name) catch {};

    // Call appendToFile — should create the file
    try History.appendToFile(tmp_name, "echo hello");

    // Verify file exists and contains the command
    const file = try std.Io.Dir.cwd().openFile(std.Options.debug_io, tmp_name, .{});
    defer file.close(std.Options.debug_io);
    defer std.Io.Dir.cwd().deleteFile(std.Options.debug_io, tmp_name) catch {};

    var buf: [256]u8 = undefined;
    const n = try file.readStreaming(std.Options.debug_io, &.{&buf});
    const content = buf[0..n];
    try std.testing.expectEqualStrings("echo hello\n", content);

    _ = allocator; // Unused but reserved for future
}

test "appendToFile appends to existing file" {
    const tmp_name = "den_test_history_append2.tmp";

    // Create file with initial content
    {
        const file = try std.Io.Dir.cwd().createFile(std.Options.debug_io, tmp_name, .{});
        defer file.close(std.Options.debug_io);
        try file.writeStreamingAll(std.Options.debug_io, "first\n");
    }
    defer std.Io.Dir.cwd().deleteFile(std.Options.debug_io, tmp_name) catch {};

    try History.appendToFile(tmp_name, "second");

    // Read and verify
    const file = try std.Io.Dir.cwd().openFile(std.Options.debug_io, tmp_name, .{});
    defer file.close(std.Options.debug_io);

    var buf: [256]u8 = undefined;
    const n = try file.readStreaming(std.Options.debug_io, &.{&buf});
    const content = buf[0..n];
    try std.testing.expectEqualStrings("first\nsecond\n", content);
}

fn freeEntries(allocator: std.mem.Allocator, history: []?[]const u8) void {
    for (history) |maybe| if (maybe) |entry| allocator.free(entry);
}

/// Load a literal history file body and return the in-memory buffer.
fn loadFixture(
    allocator: std.mem.Allocator,
    tmp_name: []const u8,
    body: []const u8,
    history: []?[]const u8,
    history_count: *usize,
) !void {
    {
        const file = try std.Io.Dir.cwd().createFile(std.Options.debug_io, tmp_name, .{});
        defer file.close(std.Options.debug_io);
        try file.writeStreamingAll(std.Options.debug_io, body);
    }
    try History.load(allocator, history, history_count, tmp_name);
}

test "load keeps the most recent occurrence of a repeated command" {
    const allocator = std.testing.allocator;
    const tmp_name = "den_test_history_recency.tmp";
    defer std.Io.Dir.cwd().deleteFile(std.Options.debug_io, tmp_name) catch {};

    var history: [8]?[]const u8 = @splat(null);
    var count: usize = 0;
    defer freeEntries(allocator, &history);

    // `claude --dangerously-skip-permissions` ran long ago *and* most recently;
    // the prefix search must land on the recent run, not the stale one.
    try loadFixture(allocator, tmp_name,
        \\claude --dangerously-skip-permissions
        \\claude --skip-permissions
        \\web
        \\claude --dangerously-skip-permissions
        \\
    , &history, &count);

    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqualStrings("claude --skip-permissions", history[0].?);
    try std.testing.expectEqualStrings("web", history[1].?);
    try std.testing.expectEqualStrings("claude --dangerously-skip-permissions", history[2].?);

    // Which is what the autosuggestion's newest-first prefix walk relies on.
    try std.testing.expectEqualStrings(
        "claude --dangerously-skip-permissions",
        History.prefixSearch(&history, count, "cl").?,
    );
}

test "load keeps the newest entries when the file exceeds capacity" {
    const allocator = std.testing.allocator;
    const tmp_name = "den_test_history_capacity.tmp";
    defer std.Io.Dir.cwd().deleteFile(std.Options.debug_io, tmp_name) catch {};

    var history: [3]?[]const u8 = @splat(null);
    var count: usize = 0;
    defer freeEntries(allocator, &history);

    try loadFixture(allocator, tmp_name, "one\ntwo\nthree\nfour\nfive\n", &history, &count);

    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqualStrings("three", history[0].?);
    try std.testing.expectEqualStrings("four", history[1].?);
    try std.testing.expectEqualStrings("five", history[2].?);
}

test "load skips NUL-padded and blank lines" {
    const allocator = std.testing.allocator;
    const tmp_name = "den_test_history_corrupt.tmp";
    defer std.Io.Dir.cwd().deleteFile(std.Options.debug_io, tmp_name) catch {};

    var history: [8]?[]const u8 = @splat(null);
    var count: usize = 0;
    defer freeEntries(allocator, &history);

    try loadFixture(allocator, tmp_name, "echo one\n\x00\x00\x00\x00\n   \necho two\n", &history, &count);

    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqualStrings("echo one", history[0].?);
    try std.testing.expectEqualStrings("echo two", history[1].?);
}

test "load drops the partial first line of an oversized file" {
    const allocator = std.testing.allocator;
    const tmp_name = "den_test_history_tail.tmp";
    defer std.Io.Dir.cwd().deleteFile(std.Options.debug_io, tmp_name) catch {};

    var history: [8]?[]const u8 = @splat(null);
    var count: usize = 0;
    defer freeEntries(allocator, &history);

    // Write more than the tail window so the read starts mid-file.
    var body = std.array_list.Managed(u8).init(allocator);
    defer body.deinit();
    while (body.items.len < MAX_READ_SIZE) {
        try body.appendSlice("echo padding-that-is-long-enough-to-fill-the-window\n");
    }
    try body.appendSlice("echo newest\n");

    {
        const file = try std.Io.Dir.cwd().createFile(std.Options.debug_io, tmp_name, .{});
        defer file.close(std.Options.debug_io);
        try file.writeStreamingAll(std.Options.debug_io, body.items);
    }
    try History.load(allocator, &history, &count, tmp_name);

    // Only whole lines survive, and the newest command is present.
    try std.testing.expect(count >= 1);
    try std.testing.expectEqualStrings("echo newest", history[count - 1].?);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const entry = history[i].?;
        try std.testing.expect(std.mem.startsWith(u8, entry, "echo "));
    }
}

test "isPrivate detects the leading-whitespace opt-out" {
    try std.testing.expect(History.isPrivate(" echo secret"));
    try std.testing.expect(History.isPrivate("\techo secret"));
    try std.testing.expect(!History.isPrivate("echo public"));
    try std.testing.expect(!History.isPrivate("echo trailing space "));
    try std.testing.expect(!History.isPrivate(""));
}

test "compactFile keeps newest duplicates and drops corrupt lines" {
    const allocator = std.testing.allocator;
    const tmp_name = "den_test_history_compact.tmp";
    defer std.Io.Dir.cwd().deleteFile(std.Options.debug_io, tmp_name) catch {};

    {
        const file = try std.Io.Dir.cwd().createFile(std.Options.debug_io, tmp_name, .{});
        defer file.close(std.Options.debug_io);
        try file.writeStreamingAll(std.Options.debug_io, "ls\n\x00\x00\x00\nls\necho hi\nls\n");
    }

    try History.compactFile(allocator, tmp_name, 100);

    const file = try std.Io.Dir.cwd().openFile(std.Options.debug_io, tmp_name, .{});
    defer file.close(std.Options.debug_io);
    var buf: [256]u8 = undefined;
    const n = try file.readStreaming(std.Options.debug_io, &.{&buf});
    try std.testing.expectEqualStrings("echo hi\nls\n", buf[0..n]);
}

test "compactFile does not roll back commands appended by another shell" {
    const allocator = std.testing.allocator;
    const tmp_name = "den_test_history_concurrent.tmp";
    defer std.Io.Dir.cwd().deleteFile(std.Options.debug_io, tmp_name) catch {};

    // A shell that started long ago holds this snapshot.
    var stale: [8]?[]const u8 = @splat(null);
    var stale_count: usize = 0;
    defer freeEntries(allocator, &stale);
    try History.add(allocator, &stale, &stale_count, tmp_name, "echo old");

    // Meanwhile another shell records a command.
    try History.appendToFile(tmp_name, "echo from other shell");

    // The long-lived shell exits.
    try History.compactFile(allocator, tmp_name, 100);

    var reloaded: [8]?[]const u8 = @splat(null);
    var reloaded_count: usize = 0;
    defer freeEntries(allocator, &reloaded);
    try History.load(allocator, &reloaded, &reloaded_count, tmp_name);

    try std.testing.expectEqual(@as(usize, 2), reloaded_count);
    try std.testing.expectEqualStrings("echo old", reloaded[0].?);
    try std.testing.expectEqualStrings("echo from other shell", reloaded[1].?);
}

test "appendToFile writes each command as one whole line" {
    const tmp_name = "den_test_history_atomic.tmp";
    std.Io.Dir.cwd().deleteFile(std.Options.debug_io, tmp_name) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.Options.debug_io, tmp_name) catch {};

    try History.appendToFile(tmp_name, "echo one");
    try History.appendToFile(tmp_name, "echo two");

    const file = try std.Io.Dir.cwd().openFile(std.Options.debug_io, tmp_name, .{});
    defer file.close(std.Options.debug_io);
    var buf: [256]u8 = undefined;
    const n = try file.readStreaming(std.Options.debug_io, &.{&buf});
    try std.testing.expectEqualStrings("echo one\necho two\n", buf[0..n]);
}

test "fastExactSearch finds exact match" {
    const allocator = std.testing.allocator;

    var history = [_]?[]const u8{ null, null, null };
    history[0] = try allocator.dupe(u8, "echo one");
    history[1] = try allocator.dupe(u8, "ls -la");
    history[2] = try allocator.dupe(u8, "echo two");
    defer {
        for (history) |maybe| if (maybe) |e| allocator.free(e);
    }

    try std.testing.expect(History.fastExactSearch(&history, 3, "ls -la") != null);
    try std.testing.expect(History.fastExactSearch(&history, 3, "nonexistent") == null);
    try std.testing.expect(History.fastExactSearch(&history, 3, "") == null);
    try std.testing.expect(History.fastExactSearch(&history, 0, "anything") == null);
}

test "prefixSearch finds by prefix" {
    const allocator = std.testing.allocator;

    var history = [_]?[]const u8{ null, null, null };
    history[0] = try allocator.dupe(u8, "git status");
    history[1] = try allocator.dupe(u8, "git push");
    history[2] = try allocator.dupe(u8, "ls -la");
    defer {
        for (history) |maybe| if (maybe) |e| allocator.free(e);
    }

    const found = History.prefixSearch(&history, 3, "git");
    try std.testing.expect(found != null);
    // Should find most recent (git push)
    try std.testing.expectEqualStrings("git push", found.?);

    try std.testing.expect(History.prefixSearch(&history, 3, "nonmatch") == null);
    try std.testing.expect(History.prefixSearch(&history, 3, "") == null);
}

test "substringSearch finds by substring" {
    const allocator = std.testing.allocator;

    var history = [_]?[]const u8{ null, null, null };
    history[0] = try allocator.dupe(u8, "echo hello world");
    history[1] = try allocator.dupe(u8, "ls -la");
    history[2] = try allocator.dupe(u8, "echo hello again");
    defer {
        for (history) |maybe| if (maybe) |e| allocator.free(e);
    }

    const found = History.substringSearch(&history, 3, "hello", 3);
    try std.testing.expect(found != null);
    // Should find most recent "hello"
    try std.testing.expectEqualStrings("echo hello again", found.?.entry);

    try std.testing.expect(History.substringSearch(&history, 3, "", 3) == null);
    try std.testing.expect(History.substringSearch(&history, 0, "anything", 0) == null);
}
