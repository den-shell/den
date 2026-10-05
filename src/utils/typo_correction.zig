const std = @import("std");
const builtin = @import("builtin");
const env_utils = @import("env.zig");
const compound = @import("../parser/compound.zig");

/// Typo correction utilities using fuzzy matching (Levenshtein distance)
pub const TypoCorrection = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TypoCorrection {
        return .{ .allocator = allocator };
    }

    /// Compute Damerau-Levenshtein distance between two strings
    /// This handles transpositions as a single edit (e.g., "gti" -> "git" = 1)
    pub fn levenshteinDistance(self: *TypoCorrection, a: []const u8, b: []const u8) !usize {
        if (a.len == 0) return b.len;
        if (b.len == 0) return a.len;

        // Full matrix needed for Damerau-Levenshtein (transposition detection)
        const rows = a.len + 1;
        const cols = b.len + 1;
        var matrix = try self.allocator.alloc(usize, rows * cols);
        defer self.allocator.free(matrix);

        // Initialize first row and column
        for (0..cols) |j| {
            matrix[j] = j;
        }
        for (0..rows) |i| {
            matrix[i * cols] = i;
        }

        // Fill the matrix
        for (a, 0..) |char_a, i| {
            for (b, 0..) |char_b, j| {
                const cost: usize = if (char_a == char_b) 0 else 1;

                const idx = (i + 1) * cols + (j + 1);
                matrix[idx] = @min(
                    @min(
                        matrix[idx - 1] + 1, // insertion
                        matrix[idx - cols] + 1, // deletion
                    ),
                    matrix[idx - cols - 1] + cost, // substitution
                );

                // Check for transposition (Damerau extension)
                if (i > 0 and j > 0 and char_a == b[j - 1] and a[i - 1] == char_b) {
                    matrix[idx] = @min(matrix[idx], matrix[(i - 1) * cols + (j - 1)] + 1);
                }
            }
        }

        return matrix[rows * cols - 1];
    }

    /// Calculate similarity score (0.0 to 1.0) between two strings
    pub fn similarity(self: *TypoCorrection, a: []const u8, b: []const u8) !f32 {
        const max_len = @max(a.len, b.len);
        if (max_len == 0) return 1.0;

        const distance = try self.levenshteinDistance(a, b);
        return 1.0 - (@as(f32, @floatFromInt(distance)) / @as(f32, @floatFromInt(max_len)));
    }

    /// Suggestion for a typo correction
    pub const Suggestion = struct {
        command: []const u8,
        distance: usize,
        similarity: f32,
    };

    /// Find similar commands to the given typo
    /// Returns suggestions sorted by similarity (best matches first)
    pub fn findSuggestions(self: *TypoCorrection, typo: []const u8, max_suggestions: usize) ![]Suggestion {
        var suggestions = std.ArrayList(Suggestion).empty;
        defer suggestions.deinit(self.allocator);

        // Maximum distance to consider (too different = not helpful)
        // Generally, suggestions should be within 2-3 edits for short commands,
        // and proportionally more for longer commands
        const max_distance: usize = @max(2, typo.len / 2);

        // Search through PATH for commands
        const path = env_utils.getEnv("PATH") orelse return &[_]Suggestion{};

        var path_iter = std.mem.splitScalar(u8, path, ':');
        while (path_iter.next()) |dir_path| {
            if (dir_path.len == 0) continue;

            var dir = std.Io.Dir.cwd().openDir(std.Options.debug_io, dir_path, .{ .iterate = true }) catch continue;
            defer dir.close(std.Options.debug_io);

            var iter = dir.iterate();
            while (iter.next(std.Options.debug_io) catch continue) |entry| {
                // Include files and symlinks (many commands are symlinks)
                if (entry.kind != .file and entry.kind != .sym_link) continue;

                // Check if executable
                const stat = dir.statFile(std.Options.debug_io, entry.name, .{}) catch continue;
                const is_executable = if (builtin.os.tag == .windows) true else (stat.permissions.toMode() & 0o111) != 0;
                if (!is_executable) continue;

                // Calculate distance
                const distance = try self.levenshteinDistance(typo, entry.name);

                // Only consider if within max distance, and only once: the
                // same name in two PATH directories is one suggestion.
                if (distance <= max_distance and !containsCommand(suggestions.items, entry.name)) {
                    const sim = try self.similarity(typo, entry.name);
                    try suggestions.append(self.allocator, .{
                        .command = try self.allocator.dupe(u8, entry.name),
                        .distance = distance,
                        .similarity = sim,
                    });
                }
            }
        }

        // Also check shell builtins
        const builtins = [_][]const u8{
            "cd",      "pwd",     "echo",      "exit",     "export",
            "unset",   "set",     "alias",     "unalias",  "source",
            "history", "jobs",    "fg",        "bg",       "kill",
            "wait",    "true",    "false",     "test",     "type",
            "which",   "read",    "printf",    "time",     "times",
            "ulimit",  "umask",   "trap",      "eval",     "exec",
            "command", "local",   "declare",   "typeset",  "let",
            "shift",   "getopts", "return",    "break",    "continue",
            "logout",  "dirs",    "pushd",     "popd",     "suspend",
            "help",    "enable",  "shopt",     "complete", "compgen",
            "compopt", "mapfile", "readarray",
        };

        for (builtins) |builtin_cmd| {
            const distance = try self.levenshteinDistance(typo, builtin_cmd);
            if (distance <= max_distance and !containsCommand(suggestions.items, builtin_cmd)) {
                const sim = try self.similarity(typo, builtin_cmd);
                try suggestions.append(self.allocator, .{
                    .command = try self.allocator.dupe(u8, builtin_cmd),
                    .distance = distance,
                    .similarity = sim,
                });
            }
        }

        // Sort by similarity (descending) then by distance (ascending)
        const items = try suggestions.toOwnedSlice(self.allocator);
        std.mem.sort(Suggestion, items, {}, struct {
            fn lessThan(_: void, a: Suggestion, b: Suggestion) bool {
                // Higher similarity first
                if (a.similarity != b.similarity) {
                    return a.similarity > b.similarity;
                }
                // Lower distance if similarity is equal
                return a.distance < b.distance;
            }
        }.lessThan);

        // Return only the top suggestions, freeing excess items
        const result_count = @min(max_suggestions, items.len);

        // Free the command strings for items we won't return
        for (items[result_count..]) |item| {
            self.allocator.free(item.command);
        }

        // Reallocate to exact size needed (so caller can free correctly)
        if (result_count == 0) {
            self.allocator.free(items);
            return &[_]Suggestion{};
        }

        const result = try self.allocator.realloc(items, result_count);
        return result;
    }

    /// Get the best suggestion for a typo (or null if none found)
    pub fn getBestSuggestion(self: *TypoCorrection, typo: []const u8) !?[]const u8 {
        const suggestions = try self.findSuggestions(typo, 1);
        defer self.allocator.free(suggestions);
        if (suggestions.len > 0 and suggestions[0].similarity >= 0.5) {
            // Caller doesn't own this, so dupe it and free the original
            const result = try self.allocator.dupe(u8, suggestions[0].command);
            for (suggestions) |s| self.allocator.free(s.command);
            return result;
        }
        for (suggestions) |s| self.allocator.free(s.command);
        return null;
    }

    fn containsCommand(suggestions: []const Suggestion, name: []const u8) bool {
        for (suggestions) |s| {
            if (std.mem.eql(u8, s.command, name)) return true;
        }
        return false;
    }

    /// Format a "did you mean" message
    pub fn formatSuggestionMessage(self: *TypoCorrection, typo: []const u8) !?[]const u8 {
        // `for`, `do`, `done` and the like are shell syntax, not misspelled
        // programs; offering `sort` or `du` for them only misleads.
        if (compound.isReservedWord(typo)) return null;

        const suggestions = try self.findSuggestions(typo, 3);
        defer {
            for (suggestions) |s| self.allocator.free(s.command);
            self.allocator.free(suggestions);
        }
        if (suggestions.len == 0) return null;

        // Only show suggestions if the best one is reasonably similar
        if (suggestions[0].similarity < 0.4) return null;

        var msg = std.ArrayList(u8).empty;
        errdefer msg.deinit(self.allocator);

        if (suggestions.len == 1) {
            try msg.appendSlice(self.allocator, "Did you mean '");
            try msg.appendSlice(self.allocator, suggestions[0].command);
            try msg.appendSlice(self.allocator, "'?");
        } else {
            try msg.appendSlice(self.allocator, "Did you mean one of these?\n");
            for (suggestions) |suggestion| {
                try msg.appendSlice(self.allocator, "    ");
                try msg.appendSlice(self.allocator, suggestion.command);
                try msg.append(self.allocator, '\n');
            }
        }

        return try msg.toOwnedSlice(self.allocator);
    }
};

// Tests
test "levenshtein distance" {
    const allocator = std.testing.allocator;
    var tc = TypoCorrection.init(allocator);

    // Same string
    try std.testing.expectEqual(@as(usize, 0), try tc.levenshteinDistance("hello", "hello"));

    // One insertion
    try std.testing.expectEqual(@as(usize, 1), try tc.levenshteinDistance("hello", "helo"));

    // One substitution
    try std.testing.expectEqual(@as(usize, 1), try tc.levenshteinDistance("hello", "hallo"));

    // One transposition (Damerau-Levenshtein counts this as 1)
    try std.testing.expectEqual(@as(usize, 1), try tc.levenshteinDistance("gti", "git"));

    // Complete different
    try std.testing.expectEqual(@as(usize, 3), try tc.levenshteinDistance("cat", "dog"));

    // Empty strings
    try std.testing.expectEqual(@as(usize, 5), try tc.levenshteinDistance("", "hello"));
    try std.testing.expectEqual(@as(usize, 5), try tc.levenshteinDistance("hello", ""));
}

test "similarity calculation" {
    const allocator = std.testing.allocator;
    var tc = TypoCorrection.init(allocator);

    // Same string = 100% similar
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), try tc.similarity("git", "git"), 0.01);

    // One character off
    const sim = try tc.similarity("gti", "git");
    try std.testing.expect(sim > 0.5);
}

test "find suggestions for common typos" {
    const allocator = std.testing.allocator;
    var tc = TypoCorrection.init(allocator);

    // Note: This test depends on having 'cd' as a builtin
    // Use a higher max to ensure we capture cd among potentially many 2-char matches
    const suggestions = try tc.findSuggestions("dc", 20);
    defer {
        for (suggestions) |s| {
            allocator.free(s.command);
        }
        if (suggestions.len > 0) {
            allocator.free(suggestions);
        }
    }

    // Should find 'cd' as a suggestion for 'dc'
    var found_cd = false;
    for (suggestions) |s| {
        if (std.mem.eql(u8, s.command, "cd")) {
            found_cd = true;
            break;
        }
    }
    try std.testing.expect(found_cd);
}

test "reserved words get no suggestions" {
    var tc = TypoCorrection.init(std.testing.allocator);
    for ([_][]const u8{ "for", "do", "done", "then", "fi", "esac", "}" }) |word| {
        try std.testing.expect((try tc.formatSuggestionMessage(word)) == null);
    }
}

test "suggestions are unique" {
    var tc = TypoCorrection.init(std.testing.allocator);
    const suggestions = try tc.findSuggestions("sortt", 10);
    defer {
        for (suggestions) |s| std.testing.allocator.free(s.command);
        std.testing.allocator.free(suggestions);
    }
    for (suggestions, 0..) |a, i| {
        for (suggestions[i + 1 ..]) |b| {
            try std.testing.expect(!std.mem.eql(u8, a.command, b.command));
        }
    }
}
