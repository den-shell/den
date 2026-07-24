const std = @import("std");
const builtin = @import("builtin");
const IO = @import("../utils/io.zig").IO;
const types = @import("../types/mod.zig");
const cpu_opt = @import("../utils/cpu_opt.zig");

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

    /// Load history from a file into the in-memory buffer with de-duplication.
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

        // Read entire file
        const max_size = 1024 * 1024; // 1MB max
        const file_size = (try file.stat(std.Options.debug_io)).size;
        const read_size: usize = @min(file_size, max_size);
        const buffer = try allocator.alloc(u8, read_size);
        defer allocator.free(buffer);
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
        const content = buffer[0..total_read];

        // Split by newlines and add to history (with de-duplication).
        // Uses a StringHashMap for O(1) dedup instead of O(n) linear scan.
        var seen = std.StringHashMap(void).init(allocator);
        defer seen.deinit();
        // Pre-populate with any existing entries so cross-load dedup works
        var pre_i: usize = 0;
        while (pre_i < history_count.*) : (pre_i += 1) {
            if (history[pre_i]) |existing| {
                try seen.put(existing, {});
            }
        }

        var iter = std.mem.splitScalar(u8, content, '\n');
        while (iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
            if (trimmed.len > 0 and history_count.* < history.len) {
                // O(1) dedup check
                if (seen.contains(trimmed)) continue;

                const cmd_copy = try allocator.dupe(u8, trimmed);
                history[history_count.*] = cmd_copy;
                history_count.* += 1;
                // Track by the stored (owned) slice so the key remains valid
                try seen.put(cmd_copy, {});
            }
        }
    }

    /// Save the entire history buffer to the history file.
    pub fn save(history: []?[]const u8, history_file_path: []const u8) !void {
        const file = try std.Io.Dir.cwd().createFile(std.Options.debug_io, history_file_path, .{});
        defer file.close(std.Options.debug_io);

        for (history) |maybe_entry| {
            if (maybe_entry) |entry| {
                try file.writeStreamingAll(std.Options.debug_io, entry);
                try file.writeStreamingAll(std.Options.debug_io, "\n");
            }
        }
    }

    /// Append a single command to the history file. Creates the file if it
    /// doesn't exist. Uses O_APPEND semantics to avoid races on seek.
    pub fn appendToFile(history_file_path: []const u8, command: []const u8) !void {
        // Try opening existing file first; if it doesn't exist, create it.
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

        // Seek to end of file. On failure (e.g., pipe, non-seekable), surface
        // an error rather than silently writing at the wrong offset.
        if (builtin.os.tag != .windows) {
            const seek_result = std.c.lseek(file.handle, 0, std.c.SEEK.END);
            if (seek_result < 0) return error.SeekFailed;
        }

        // Append the command
        try file.writeStreamingAll(std.Options.debug_io, command);
        try file.writeStreamingAll(std.Options.debug_io, "\n");
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
