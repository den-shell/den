const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat");
const env_utils = @import("env.zig");
const cpu_opt = @import("cpu_opt.zig");

const is_windows = builtin.os.tag == .windows;

/// Completion cache with TTL support
pub const CompletionCache = struct {
    const CacheEntry = struct {
        results: [][]const u8,
        timestamp: i64, // milliseconds since epoch
    };

    allocator: std.mem.Allocator,
    entries: std.StringHashMap(CacheEntry),
    ttl_ms: u32,
    max_entries: u32,

    pub fn init(allocator: std.mem.Allocator, ttl_ms: u32, max_entries: u32) CompletionCache {
        return .{
            .allocator = allocator,
            .entries = std.StringHashMap(CacheEntry).init(allocator),
            .ttl_ms = ttl_ms,
            .max_entries = max_entries,
        };
    }

    pub fn deinit(self: *CompletionCache) void {
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            // Free cached results
            for (entry.value_ptr.results) |result| {
                self.allocator.free(result);
            }
            self.allocator.free(entry.value_ptr.results);
            // Free the key
            self.allocator.free(entry.key_ptr.*);
        }
        self.entries.deinit();
    }

    fn getCurrentTimeMs() i64 {
        // Use Instant for timestamp since milliTimestamp was removed in Zig 0.16
        const instant = compat.Instant.now() catch return 0;
        // Convert seconds to milliseconds
        if (is_windows) {
            return @as(i64, @intCast(instant.timestamp / 10_000_000)) * 1000;
        }
        return @as(i64, instant.timestamp.sec) * 1000;
    }

    pub fn get(self: *CompletionCache, key: []const u8) ?[][]const u8 {
        if (self.entries.get(key)) |entry| {
            const now = getCurrentTimeMs();
            const age = now - entry.timestamp;

            // Check if entry has expired
            if (age > self.ttl_ms) {
                // Entry expired, remove it
                if (self.entries.fetchRemove(key)) |removed| {
                    for (removed.value.results) |result| {
                        self.allocator.free(result);
                    }
                    self.allocator.free(removed.value.results);
                    self.allocator.free(removed.key);
                }
                return null;
            }

            return entry.results;
        }
        return null;
    }

    pub fn put(self: *CompletionCache, key: []const u8, results: [][]const u8) !void {
        // Check if we need to evict entries
        if (self.entries.count() >= self.max_entries) {
            self.evictOldest();
        }

        // Remove existing entry if present
        if (self.entries.fetchRemove(key)) |old| {
            for (old.value.results) |result| {
                self.allocator.free(result);
            }
            self.allocator.free(old.value.results);
            self.allocator.free(old.key);
        }

        // Duplicate key and results
        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);

        const results_copy = try self.allocator.alloc([]const u8, results.len);
        errdefer self.allocator.free(results_copy);

        for (results, 0..) |result, i| {
            results_copy[i] = try self.allocator.dupe(u8, result);
        }

        try self.entries.put(key_copy, .{
            .results = results_copy,
            .timestamp = getCurrentTimeMs(),
        });
    }

    fn evictOldest(self: *CompletionCache) void {
        var oldest_key: ?[]const u8 = null;
        var oldest_time: i64 = std.math.maxInt(i64);

        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.timestamp < oldest_time) {
                oldest_time = entry.value_ptr.timestamp;
                oldest_key = entry.key_ptr.*;
            }
        }

        if (oldest_key) |key| {
            if (self.entries.fetchRemove(key)) |removed| {
                for (removed.value.results) |result| {
                    self.allocator.free(result);
                }
                self.allocator.free(removed.value.results);
                self.allocator.free(removed.key);
            }
        }
    }

    pub fn clear(self: *CompletionCache) void {
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            for (entry.value_ptr.results) |result| {
                self.allocator.free(result);
            }
            self.allocator.free(entry.value_ptr.results);
            self.allocator.free(entry.key_ptr.*);
        }
        self.entries.clearRetainingCapacity();
    }

    pub fn count(self: *CompletionCache) usize {
        return self.entries.count();
    }
};

/// Tab completion utilities
pub const Completion = struct {
    allocator: std.mem.Allocator,
    cache: ?*CompletionCache,

    pub fn init(allocator: std.mem.Allocator) Completion {
        return .{ .allocator = allocator, .cache = null };
    }

    pub fn initWithCache(allocator: std.mem.Allocator, cache: *CompletionCache) Completion {
        return .{ .allocator = allocator, .cache = cache };
    }

    /// Context struct for sorting by fuzzy score
    const SortContext = struct {
        query: []const u8,
    };

    /// Comparison function for fuzzy score sorting (higher scores first)
    fn fuzzyCompare(context: SortContext, a: []const u8, b: []const u8) bool {
        const score_a = cpu_opt.fuzzyScore(a, context.query);
        const score_b = cpu_opt.fuzzyScore(b, context.query);
        // Higher score should come first
        return score_a > score_b;
    }

    /// Rank completions by fuzzy score against the query.
    /// Higher-scoring matches appear first. Prefix matches get highest scores.
    pub fn rankByFuzzyScore(self: *Completion, completions: [][]const u8, query: []const u8) void {
        _ = self;
        if (completions.len <= 1) return;

        if (query.len == 0) {
            // No query — sort alphabetically
            std.mem.sort([]const u8, completions, {}, struct {
                fn cmp(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.order(u8, a, b) == .lt;
                }
            }.cmp);
            return;
        }

        std.mem.sort([]const u8, completions, SortContext{ .query = query }, fuzzyCompare);
    }

    /// Escape special characters in a filename for shell use
    fn escapeFilename(self: *Completion, filename: []const u8) ![]const u8 {
        // Count how many characters need escaping
        var escape_count: usize = 0;
        for (filename) |c| {
            switch (c) {
                ' ', '\t', '\n', '\'', '"', '\\', '&', '|', ';', '<', '>', '(', ')', '$', '`', '*', '?', '[', ']', '{', '}', '!' => {
                    escape_count += 1;
                },
                else => {},
            }
        }

        // If no escaping needed, return as-is
        if (escape_count == 0) {
            return try self.allocator.dupe(u8, filename);
        }

        // Allocate buffer with space for backslashes
        const result = try self.allocator.alloc(u8, filename.len + escape_count);
        var i: usize = 0;
        for (filename) |c| {
            switch (c) {
                ' ', '\t', '\n', '\'', '"', '\\', '&', '|', ';', '<', '>', '(', ')', '$', '`', '*', '?', '[', ']', '{', '}', '!' => {
                    result[i] = '\\';
                    i += 1;
                    result[i] = c;
                    i += 1;
                },
                else => {
                    result[i] = c;
                    i += 1;
                },
            }
        }

        return result;
    }

    /// Find command completions from PATH (with caching)
    pub fn completeCommand(self: *Completion, prefix: []const u8) ![][]const u8 {
        // Check cache first
        const cache_key = blk: {
            var key_buf: [512]u8 = undefined;
            break :blk try std.fmt.bufPrint(&key_buf, "cmd:{s}", .{prefix});
        };

        if (self.cache) |cache| {
            if (cache.get(cache_key)) |cached_results| {
                // Return a copy of cached results
                const result = try self.allocator.alloc([]const u8, cached_results.len);
                for (cached_results, 0..) |r, i| {
                    result[i] = try self.allocator.dupe(u8, r);
                }
                return result;
            }
        }

        var matches_buffer: [256][]const u8 = undefined;
        var match_count: usize = 0;

        // Get PATH environment variable
        const path = env_utils.getEnv("PATH") orelse return &[_][]const u8{};

        // Split PATH by ':'
        var path_iter = std.mem.splitScalar(u8, path, ':');
        while (path_iter.next()) |dir_path| {
            if (dir_path.len == 0) continue;

            // Open directory
            var dir = std.Io.Dir.cwd().openDir(std.Options.debug_io, dir_path, .{ .iterate = true }) catch continue;
            defer dir.close(std.Options.debug_io);

            // Iterate files in directory
            var iter = dir.iterate();
            while (iter.next(std.Options.debug_io) catch continue) |entry| {
                // Check if file starts with prefix
                if (entry.kind == .file and std.mem.startsWith(u8, entry.name, prefix)) {
                    // Check if executable
                    const stat = dir.statFile(std.Options.debug_io, entry.name, .{}) catch continue;
                    const is_executable = if (is_windows) true else (stat.permissions.toMode() & 0o111) != 0;

                    if (is_executable) {
                        if (match_count >= matches_buffer.len) break;

                        // Check for duplicates
                        var is_dup = false;
                        for (matches_buffer[0..match_count]) |existing| {
                            if (std.mem.eql(u8, existing, entry.name)) {
                                is_dup = true;
                                break;
                            }
                        }

                        if (!is_dup) {
                            matches_buffer[match_count] = try self.allocator.dupe(u8, entry.name);
                            match_count += 1;
                        }
                    }
                }
            }
        }

        // Rank matches by fuzzy score (prefix matches score highest)
        self.rankByFuzzyScore(matches_buffer[0..match_count], prefix);

        // Allocate and return results
        const result = try self.allocator.alloc([]const u8, match_count);
        @memcpy(result, matches_buffer[0..match_count]);

        // Store in cache
        if (self.cache) |cache| {
            cache.put(cache_key, result) catch {};
        }

        return result;
    }

    /// Find directory-only completions
    pub fn completeDirectory(self: *Completion, prefix: []const u8) ![][]const u8 {
        // First, try mid-word path expansion (e.g., /u/l/b -> /usr/local/bin)
        const expanded_prefix = try self.expandMidWordPath(prefix);
        const use_prefix = if (expanded_prefix) |exp| blk: {
            defer self.allocator.free(exp);
            break :blk try self.allocator.dupe(u8, exp);
        } else blk: {
            break :blk try self.allocator.dupe(u8, prefix);
        };
        defer self.allocator.free(use_prefix);

        var matches_buffer: [256][]const u8 = undefined;
        var match_count: usize = 0;

        // Parse directory and filename parts
        // If prefix ends with '/', we want to list contents of that directory
        const dir_path = if (use_prefix.len > 0 and use_prefix[use_prefix.len - 1] == '/') blk: {
            // Remove trailing slash for dirname
            const without_slash = use_prefix[0 .. use_prefix.len - 1];
            break :blk if (without_slash.len > 0) without_slash else ".";
        } else blk: {
            break :blk std.fs.path.dirname(use_prefix) orelse ".";
        };

        const file_prefix = if (use_prefix.len > 0 and use_prefix[use_prefix.len - 1] == '/') blk: {
            // If ends with slash, we're completing everything in that dir
            break :blk "";
        } else blk: {
            break :blk std.fs.path.basename(use_prefix);
        };

        // Safety check: ensure dir_path doesn't contain null bytes
        if (std.mem.indexOfScalar(u8, dir_path, 0) != null) {
            return &[_][]const u8{};
        }

        // Should we show hidden files?
        const show_hidden = file_prefix.len > 0 and file_prefix[0] == '.';

        // Open directory
        var dir = std.Io.Dir.cwd().openDir(std.Options.debug_io, dir_path, .{ .iterate = true }) catch {
            return &[_][]const u8{};
        };
        defer dir.close(std.Options.debug_io);

        // Iterate directory
        var iter = dir.iterate();
        while (iter.next(std.Options.debug_io) catch null) |entry| {
            // Only show directories
            if (entry.kind != .directory) continue;

            // Skip hidden files unless explicitly requested
            if (!show_hidden and entry.name.len > 0 and entry.name[0] == '.') continue;

            if (std.mem.startsWith(u8, entry.name, file_prefix)) {
                if (match_count >= matches_buffer.len) break;

                // If the original prefix ended with '/', return just the basename
                // Otherwise, return the full path
                const completion_text = blk: {
                    var slash_buf: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;

                    if (use_prefix.len > 0 and use_prefix[use_prefix.len - 1] == '/') {
                        // Prefix ended with slash: return just basename with trailing slash
                        const with_slash = try std.fmt.bufPrint(&slash_buf, "{s}/", .{entry.name});
                        break :blk with_slash;
                    } else {
                        // Prefix didn't end with slash: return full path with trailing slash
                        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
                        const full_path = if (std.mem.eql(u8, dir_path, ".")) blk2: {
                            break :blk2 try std.fmt.bufPrint(&path_buf, "{s}", .{entry.name});
                        } else blk2: {
                            break :blk2 try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, entry.name });
                        };
                        const with_slash = try std.fmt.bufPrint(&slash_buf, "{s}/", .{full_path});
                        break :blk with_slash;
                    }
                };

                // Escape special characters (spaces, etc.)
                const escaped = try self.escapeFilename(completion_text);
                matches_buffer[match_count] = escaped;
                match_count += 1;
            }
        }

        // Rank matches by fuzzy score
        self.rankByFuzzyScore(matches_buffer[0..match_count], file_prefix);

        // Allocate and return results
        const result = try self.allocator.alloc([]const u8, match_count);
        @memcpy(result, matches_buffer[0..match_count]);
        return result;
    }

    /// Find file/directory completions
    pub fn completeFile(self: *Completion, prefix: []const u8) ![][]const u8 {
        // First, try mid-word path expansion (e.g., /u/l/b -> /usr/local/bin)
        // This attempts to expand abbreviated path components
        const expanded_prefix = try self.expandMidWordPath(prefix);
        const use_prefix = if (expanded_prefix) |exp| blk: {
            defer self.allocator.free(exp);
            // Reject an expansion that drops a leading "./" or "../" the user
            // typed: expandMidWordPath treats "." as a segment, so "./sub" can
            // come back as "subdir", which would complete to "subdir/" and lose
            // the "./". Keep the original prefix in that case.
            const drops_dot = (std.mem.startsWith(u8, prefix, "./") and !std.mem.startsWith(u8, exp, "./")) or
                (std.mem.startsWith(u8, prefix, "../") and !std.mem.startsWith(u8, exp, "../"));
            if (drops_dot) break :blk try self.allocator.dupe(u8, prefix);
            break :blk try self.allocator.dupe(u8, exp);
        } else blk: {
            // Use original prefix if expansion failed or wasn't needed
            break :blk try self.allocator.dupe(u8, prefix);
        };
        defer self.allocator.free(use_prefix);

        // Now do regular file completion on the (possibly expanded) prefix
        var matches_buffer: [256][]const u8 = undefined;
        var match_count: usize = 0;

        // Parse directory and filename parts
        // If prefix ends with '/', we want to list contents of that directory
        const dir_path = if (use_prefix.len > 0 and use_prefix[use_prefix.len - 1] == '/') blk: {
            // Remove trailing slash for dirname
            const without_slash = use_prefix[0 .. use_prefix.len - 1];
            break :blk if (without_slash.len > 0) without_slash else ".";
        } else blk: {
            break :blk std.fs.path.dirname(use_prefix) orelse ".";
        };

        const file_prefix = if (use_prefix.len > 0 and use_prefix[use_prefix.len - 1] == '/') blk: {
            // If ends with slash, we're completing everything in that dir
            break :blk "";
        } else blk: {
            break :blk std.fs.path.basename(use_prefix);
        };

        // Safety check: ensure dir_path doesn't contain null bytes
        if (std.mem.indexOfScalar(u8, dir_path, 0) != null) {
            return &[_][]const u8{};
        }

        // Should we show hidden files?
        const show_hidden = file_prefix.len > 0 and file_prefix[0] == '.';

        // Open directory
        var dir = std.Io.Dir.cwd().openDir(std.Options.debug_io, dir_path, .{ .iterate = true }) catch {
            return &[_][]const u8{};
        };
        defer dir.close(std.Options.debug_io);

        // Iterate directory
        var iter = dir.iterate();
        while (iter.next(std.Options.debug_io) catch null) |entry| {
            // Skip hidden files unless explicitly requested
            if (!show_hidden and entry.name.len > 0 and entry.name[0] == '.') continue;

            if (std.mem.startsWith(u8, entry.name, file_prefix)) {
                if (match_count >= matches_buffer.len) break;

                // If the original prefix ended with '/', return just the basename
                // Otherwise, return the full path
                const completion_text = blk: {
                    if (use_prefix.len > 0 and use_prefix[use_prefix.len - 1] == '/') {
                        // Prefix ended with slash: return just basename (with slash if directory)
                        if (entry.kind == .directory) {
                            var slash_buf: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
                            const with_slash = try std.fmt.bufPrint(&slash_buf, "{s}/", .{entry.name});
                            break :blk with_slash;
                        } else {
                            break :blk entry.name;
                        }
                    } else {
                        // Prefix didn't end with slash: rebuild the path by keeping
                        // exactly the directory text the user typed before the
                        // basename. Using dir_path (from dirname) would normalize
                        // "./lan" to "langfile" — dropping the "./" the user typed —
                        // and likewise collapse "../" etc. file_prefix is the
                        // basename of use_prefix, so the slice before it is the
                        // literal prefix ("", "./", "../", "/usr/", "sub/", …).
                        const dir_prefix = use_prefix[0 .. use_prefix.len - file_prefix.len];
                        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
                        if (entry.kind == .directory) {
                            break :blk try std.fmt.bufPrint(&path_buf, "{s}{s}/", .{ dir_prefix, entry.name });
                        } else {
                            break :blk try std.fmt.bufPrint(&path_buf, "{s}{s}", .{ dir_prefix, entry.name });
                        }
                    }
                };

                // Escape special characters (spaces, etc.)
                const escaped = try self.escapeFilename(completion_text);
                matches_buffer[match_count] = escaped;
                match_count += 1;
            }
        }

        // Rank matches by fuzzy score
        self.rankByFuzzyScore(matches_buffer[0..match_count], file_prefix);

        // Allocate and return results
        const result = try self.allocator.alloc([]const u8, match_count);
        @memcpy(result, matches_buffer[0..match_count]);
        return result;
    }

    /// Regular file completion (without mid-word expansion)
    fn completeFileRegular(self: *Completion, prefix: []const u8) ![][]const u8 {
        var matches_buffer: [256][]const u8 = undefined;
        var match_count: usize = 0;

        // Parse directory and filename parts
        const dir_path = std.fs.path.dirname(prefix) orelse ".";
        const file_prefix = std.fs.path.basename(prefix);

        // Should we show hidden files?
        const show_hidden = file_prefix.len > 0 and file_prefix[0] == '.';

        // Open directory
        var dir = std.Io.Dir.cwd().openDir(std.Options.debug_io, dir_path, .{ .iterate = true }) catch {
            return &[_][]const u8{};
        };
        defer dir.close(std.Options.debug_io);

        // Iterate directory
        var iter = dir.iterate();
        while (iter.next(std.Options.debug_io) catch null) |entry| {
            // Skip hidden files unless explicitly requested
            if (!show_hidden and entry.name.len > 0 and entry.name[0] == '.') continue;

            if (std.mem.startsWith(u8, entry.name, file_prefix)) {
                if (match_count >= matches_buffer.len) break;

                // Build full path
                var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
                const full_path = if (std.mem.eql(u8, dir_path, ".")) blk: {
                    break :blk try std.fmt.bufPrint(&path_buf, "{s}", .{entry.name});
                } else blk: {
                    break :blk try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, entry.name });
                };

                // Add trailing slash for directories
                const with_slash = if (entry.kind == .directory) blk: {
                    var slash_buf: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
                    break :blk try std.fmt.bufPrint(&slash_buf, "{s}/", .{full_path});
                } else full_path;

                matches_buffer[match_count] = try self.allocator.dupe(u8, with_slash);
                match_count += 1;
            }
        }

        // Rank matches by fuzzy score
        self.rankByFuzzyScore(matches_buffer[0..match_count], file_prefix);

        // Allocate and return results
        const result = try self.allocator.alloc([]const u8, match_count);
        @memcpy(result, matches_buffer[0..match_count]);
        return result;
    }

    /// Sort matches alphabetically (kept for fallback when no prefix)
    fn sortMatches(self: *Completion, matches: [][]const u8) void {
        _ = self;
        if (matches.len <= 1) return;

        var i: usize = 0;
        while (i < matches.len - 1) : (i += 1) {
            var j: usize = 0;
            while (j < matches.len - 1 - i) : (j += 1) {
                if (std.mem.lessThan(u8, matches[j + 1], matches[j])) {
                    const temp = matches[j];
                    matches[j] = matches[j + 1];
                    matches[j + 1] = temp;
                }
            }
        }
    }

    /// Expand mid-word path components (zsh-style with multi-segment lookahead)
    /// Example: /u/l/b -> /usr/local/bin (even though 'l' is ambiguous, we look ahead to 'b')
    /// Returns the fully expanded path, or null if expansion fails
    pub fn expandMidWordPath(self: *Completion, path: []const u8) !?[]const u8 {
        // Skip if path doesn't look like it needs expansion
        if (path.len == 0) return null;

        // Check if this looks like a path that might need expansion
        const has_slash = std.mem.indexOfScalar(u8, path, '/') != null;
        if (!has_slash) return null;

        // Don't try to expand complete-looking paths
        if (std.mem.endsWith(u8, path, "/")) return null;

        // Parse into segments
        const is_absolute = path[0] == '/';
        const path_to_split = if (is_absolute) path[1..] else path;

        var segments_list: [32][]const u8 = undefined;
        var segment_count: usize = 0;

        var iter = std.mem.splitScalar(u8, path_to_split, '/');
        while (iter.next()) |seg| {
            if (seg.len > 0 and segment_count < segments_list.len) {
                segments_list[segment_count] = seg;
                segment_count += 1;
            }
        }

        if (segment_count == 0) return null;

        const segments = segments_list[0..segment_count];

        // Try to find a unique path through all segments using lookahead
        const start_dir = if (is_absolute) "/" else ".";
        if (try self.expandPathWithLookahead(start_dir, segments, 0)) |expanded| {
            // Check if we actually changed anything
            var test_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const reconstructed = if (is_absolute) blk: {
                var pos: usize = 0;
                test_buf[pos] = '/';
                pos += 1;
                for (segments, 0..) |seg, i| {
                    if (i > 0) {
                        test_buf[pos] = '/';
                        pos += 1;
                    }
                    @memcpy(test_buf[pos .. pos + seg.len], seg);
                    pos += seg.len;
                }
                break :blk test_buf[0..pos];
            } else blk: {
                var pos: usize = 0;
                for (segments, 0..) |seg, i| {
                    if (i > 0) {
                        test_buf[pos] = '/';
                        pos += 1;
                    }
                    @memcpy(test_buf[pos .. pos + seg.len], seg);
                    pos += seg.len;
                }
                break :blk test_buf[0..pos];
            };

            if (std.mem.eql(u8, expanded, reconstructed)) {
                self.allocator.free(expanded);
                return null;
            }

            return expanded;
        }

        return null;
    }

    /// Recursively expand path with lookahead (explores all possibilities)
    fn expandPathWithLookahead(self: *Completion, current_dir: []const u8, remaining_segments: []const []const u8, depth: usize) !?[]const u8 {
        if (remaining_segments.len == 0) {
            return try self.allocator.dupe(u8, current_dir);
        }

        // Prevent infinite recursion
        if (depth > 20) return null;

        const segment = remaining_segments[0];
        const rest = remaining_segments[1..];

        // Skip special directories
        if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) {
            var new_dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const new_dir = if (std.mem.eql(u8, current_dir, "/"))
                try std.fmt.bufPrint(&new_dir_buf, "/{s}", .{segment})
            else if (std.mem.eql(u8, current_dir, "."))
                try std.fmt.bufPrint(&new_dir_buf, "{s}", .{segment})
            else
                try std.fmt.bufPrint(&new_dir_buf, "{s}/{s}", .{ current_dir, segment });

            return try self.expandPathWithLookahead(new_dir, rest, depth + 1);
        }

        // Find all matching directories
        var matches: [64][]const u8 = undefined;
        var match_count: usize = 0;

        var dir = std.Io.Dir.cwd().openDir(std.Options.debug_io, current_dir, .{ .iterate = true }) catch return null;
        defer dir.close(std.Options.debug_io);

        var dir_iter = dir.iterate();
        while (dir_iter.next(std.Options.debug_io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            if (segment[0] != '.' and entry.name.len > 0 and entry.name[0] == '.') continue;

            if (std.mem.startsWith(u8, entry.name, segment)) {
                if (match_count >= matches.len) break;
                matches[match_count] = entry.name;
                match_count += 1;
            }
        }

        if (match_count == 0) return null;

        // If only one match, expand and continue
        if (match_count == 1) {
            var new_dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const new_dir = if (std.mem.eql(u8, current_dir, "/"))
                try std.fmt.bufPrint(&new_dir_buf, "/{s}", .{matches[0]})
            else if (std.mem.eql(u8, current_dir, "."))
                try std.fmt.bufPrint(&new_dir_buf, "{s}", .{matches[0]})
            else
                try std.fmt.bufPrint(&new_dir_buf, "{s}/{s}", .{ current_dir, matches[0] });

            return try self.expandPathWithLookahead(new_dir, rest, depth + 1);
        }

        // Multiple matches - try lookahead if we have more segments
        if (rest.len > 0) {
            var successful_path: ?[]const u8 = null;
            var success_count: usize = 0;

            for (matches[0..match_count]) |match| {
                var test_dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
                const test_dir = if (std.mem.eql(u8, current_dir, "/"))
                    try std.fmt.bufPrint(&test_dir_buf, "/{s}", .{match})
                else if (std.mem.eql(u8, current_dir, "."))
                    try std.fmt.bufPrint(&test_dir_buf, "{s}", .{match})
                else
                    try std.fmt.bufPrint(&test_dir_buf, "{s}/{s}", .{ current_dir, match });

                if (try self.expandPathWithLookahead(test_dir, rest, depth + 1)) |expanded_path| {
                    if (successful_path) |old_path| {
                        self.allocator.free(old_path);
                    }
                    successful_path = expanded_path;
                    success_count += 1;

                    if (success_count > 1) {
                        // Multiple valid paths, ambiguous
                        self.allocator.free(successful_path.?);
                        return null;
                    }
                }
            }

            return successful_path;
        }

        // Multiple matches and no lookahead - ambiguous
        return null;
    }

    /// Complete usernames for ~username expansion
    /// Returns list of usernames matching the prefix
    pub fn completeUsername(self: *Completion, prefix: []const u8) ![][]const u8 {
        var matches_buffer: [128][]const u8 = undefined;
        var match_count: usize = 0;

        // The prefix should start with ~ and optionally have partial username
        const username_prefix = if (prefix.len > 0 and prefix[0] == '~')
            prefix[1..]
        else if (prefix.len == 0)
            ""
        else
            return &[_][]const u8{};

        // Read /etc/passwd on Unix-like systems
        if (@import("builtin").os.tag != .windows) {
            const passwd_file = std.Io.Dir.openFileAbsolute(std.Options.debug_io, "/etc/passwd", .{}) catch {
                // Fall back to just current user
                return try self.completeCurrentUserOnly(username_prefix);
            };
            defer passwd_file.close(std.Options.debug_io);

            // Read passwd file content
            var content = std.ArrayList(u8).empty;
            defer content.deinit(self.allocator);

            var buf: [4096]u8 = undefined;
            while (true) {
                const n = passwd_file.readStreaming(std.Options.debug_io, &.{&buf}) catch break;
                if (n == 0) break;
                content.appendSlice(self.allocator, buf[0..n]) catch break;
            }

            // Parse lines
            var lines_iter = std.mem.splitScalar(u8, content.items, '\n');
            while (lines_iter.next()) |line| {
                // passwd format: username:password:uid:gid:gecos:home:shell
                var fields = std.mem.splitScalar(u8, line, ':');
                const username = fields.next() orelse continue;

                if (username.len == 0) continue;

                // Skip system users (typically uid < 1000 on Linux, < 500 on macOS)
                // But include root for convenience
                const uid_str = blk: {
                    _ = fields.next(); // skip password
                    break :blk fields.next() orelse continue;
                };
                const uid = std.fmt.parseInt(u32, uid_str, 10) catch continue;

                // Include users with uid >= 500 (macOS) or named "root"
                const is_normal_user = uid >= 500 or std.mem.eql(u8, username, "root");
                if (!is_normal_user) continue;

                // Check if username matches prefix
                if (std.mem.startsWith(u8, username, username_prefix)) {
                    if (match_count >= matches_buffer.len) break;

                    // Check for duplicates
                    var is_dup = false;
                    for (matches_buffer[0..match_count]) |existing| {
                        if (std.mem.eql(u8, existing, username)) {
                            is_dup = true;
                            break;
                        }
                    }

                    if (!is_dup) {
                        // Return with ~ prefix
                        var name_buf: [256]u8 = undefined;
                        const with_tilde = std.fmt.bufPrint(&name_buf, "~{s}", .{username}) catch continue;
                        matches_buffer[match_count] = try self.allocator.dupe(u8, with_tilde);
                        match_count += 1;
                    }
                }
            }
        } else {
            // Windows: just return current user
            return try self.completeCurrentUserOnly(username_prefix);
        }

        // Sort matches by fuzzy score relevance
        self.rankByFuzzyScore(matches_buffer[0..match_count], username_prefix);

        // Allocate and return results
        const result = try self.allocator.alloc([]const u8, match_count);
        @memcpy(result, matches_buffer[0..match_count]);
        return result;
    }

    /// Helper to get just the current user for systems without /etc/passwd
    fn completeCurrentUserOnly(self: *Completion, prefix: []const u8) ![][]const u8 {
        // Get current username from environment
        const username = env_utils.getEnv("USER") orelse env_utils.getEnv("USERNAME") orelse return &[_][]const u8{};

        if (std.mem.startsWith(u8, username, prefix)) {
            var name_buf: [256]u8 = undefined;
            const with_tilde = try std.fmt.bufPrint(&name_buf, "~{s}", .{username});

            const result = try self.allocator.alloc([]const u8, 1);
            result[0] = try self.allocator.dupe(u8, with_tilde);
            return result;
        }

        return &[_][]const u8{};
    }

    /// Expand ~username to home directory path
    pub fn expandUsername(self: *Completion, username_with_tilde: []const u8) !?[]const u8 {
        if (username_with_tilde.len == 0 or username_with_tilde[0] != '~') {
            return null;
        }

        // Just ~ means current user
        if (username_with_tilde.len == 1) {
            const home = env_utils.getEnv("HOME") orelse return null;
            return try self.allocator.dupe(u8, home);
        }

        const username = username_with_tilde[1..];

        // Check if current user
        const current_user = env_utils.getEnv("USER") orelse "";
        if (std.mem.eql(u8, username, current_user)) {
            const home = env_utils.getEnv("HOME") orelse return null;
            return try self.allocator.dupe(u8, home);
        }

        // Look up in /etc/passwd
        if (@import("builtin").os.tag != .windows) {
            const passwd_file = std.Io.Dir.openFileAbsolute(std.Options.debug_io, "/etc/passwd", .{}) catch return null;
            defer passwd_file.close(std.Options.debug_io);

            // Read passwd file content
            var content = std.ArrayList(u8).empty;
            defer content.deinit(self.allocator);

            var buf: [4096]u8 = undefined;
            while (true) {
                const n = passwd_file.readStreaming(std.Options.debug_io, &.{&buf}) catch break;
                if (n == 0) break;
                content.appendSlice(self.allocator, buf[0..n]) catch break;
            }

            // Parse lines
            var lines_iter = std.mem.splitScalar(u8, content.items, '\n');
            while (lines_iter.next()) |line| {
                var fields = std.mem.splitScalar(u8, line, ':');
                const entry_username = fields.next() orelse continue;

                if (std.mem.eql(u8, entry_username, username)) {
                    // Skip password, uid, gid, gecos
                    _ = fields.next();
                    _ = fields.next();
                    _ = fields.next();
                    _ = fields.next();

                    const home_dir = fields.next() orelse continue;
                    return try self.allocator.dupe(u8, home_dir);
                }
            }
        }

        return null;
    }

    /// Try to expand a single path segment
    /// Returns the expanded segment if unique, null otherwise
    fn expandSegment(self: *Completion, dir_path: []const u8, segment: []const u8) !?[]const u8 {
        // If segment is complete (doesn't look partial), return as-is
        if (segment.len == 0) return null;

        // Validate dir_path doesn't contain null bytes
        if (std.mem.indexOfScalar(u8, dir_path, 0) != null) {
            return null;
        }

        // Open directory
        var dir = std.Io.Dir.cwd().openDir(std.Options.debug_io, dir_path, .{ .iterate = true }) catch {
            return null;
        };
        defer dir.close(std.Options.debug_io);

        // Find entries that start with this segment
        var matches_buffer: [16][]const u8 = undefined;
        var match_count: usize = 0;

        var iter = dir.iterate();
        while (iter.next(std.Options.debug_io) catch null) |entry| {
            // Skip hidden files unless segment starts with '.'
            if (segment[0] != '.' and entry.name.len > 0 and entry.name[0] == '.') continue;

            if (std.mem.startsWith(u8, entry.name, segment)) {
                if (match_count >= matches_buffer.len) {
                    // Too many matches, ambiguous
                    return null;
                }
                matches_buffer[match_count] = entry.name;
                match_count += 1;
            }
        }

        // Only expand if exactly one match
        if (match_count == 1) {
            return try self.allocator.dupe(u8, matches_buffer[0]);
        }

        return null;
    }
};

test "completion init" {
    const allocator = std.testing.allocator;
    const comp = Completion.init(allocator);
    _ = comp;
}

test "mid-word path expansion - simple case" {
    const allocator = std.testing.allocator;
    var comp = Completion.init(allocator);

    // Test with common system paths
    // Note: This test assumes you're on a Unix-like system with /usr/local/bin
    const test_path = "/u/l/b";
    const expanded = try comp.expandMidWordPath(test_path);

    if (expanded) |path| {
        defer allocator.free(path);
        // Should expand to /usr/local/bin if it exists — no assertion since
        // the result depends on filesystem state (test output removed for
        // consistency with other tests).
    }
}

test "mid-word path expansion - relative path" {
    const allocator = std.testing.allocator;
    var comp = Completion.init(allocator);

    // Create test directory structure
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create: testdir/subdir/file
    try tmp.dir.createDir(std.Options.debug_io, "testdir", .default_dir);
    try tmp.dir.createDir(std.Options.debug_io, "testdir/subdir", .default_dir);

    // Change to temp directory for testing
    var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const original_cwd_len = try std.Io.Dir.cwd().realPathFile(std.Options.debug_io, ".", &cwd_buf);
    const original_cwd = cwd_buf[0..original_cwd_len];
    const original_cwd_owned = try allocator.dupe(u8, original_cwd);
    defer allocator.free(original_cwd_owned);

    var tmp_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp.dir.realPathFile(std.Options.debug_io, ".", &tmp_path_buf);
    const tmp_path = tmp_path_buf[0..tmp_path_len];
    {
        var chdir_buf: [std.fs.max_path_bytes]u8 = undefined;
        @memcpy(chdir_buf[0..tmp_path.len], tmp_path);
        chdir_buf[tmp_path.len] = 0;
        if (std.c.chdir(chdir_buf[0..tmp_path.len :0]) != 0) return error.ChdirFailed;
    }
    defer {
        var chdir_buf: [std.fs.max_path_bytes]u8 = undefined;
        @memcpy(chdir_buf[0..original_cwd_owned.len], original_cwd_owned);
        chdir_buf[original_cwd_owned.len] = 0;
        _ = std.c.chdir(chdir_buf[0..original_cwd_owned.len :0]);
    }

    // Test expansion of t/s (should expand to testdir/subdir)
    const test_path = "t/s";
    const expanded = try comp.expandMidWordPath(test_path);

    if (expanded) |path| {
        defer allocator.free(path);
        try std.testing.expect(std.mem.indexOf(u8, path, "testdir") != null);
        try std.testing.expect(std.mem.indexOf(u8, path, "subdir") != null);
    }
}

test "username completion - current user" {
    const allocator = std.testing.allocator;
    var comp = Completion.init(allocator);

    // Complete ~
    const results = try comp.completeUsername("~");
    defer {
        for (results) |r| allocator.free(r);
        if (results.len > 0) allocator.free(results);
    }

    // Should find at least the current user
    try std.testing.expect(results.len > 0);
    // All results should start with ~
    for (results) |r| {
        try std.testing.expect(r.len > 0 and r[0] == '~');
    }
}

test "username completion - with prefix" {
    const allocator = std.testing.allocator;
    var comp = Completion.init(allocator);

    // Complete ~ro (should match root on most Unix systems)
    const results = try comp.completeUsername("~ro");
    defer {
        for (results) |r| allocator.free(r);
        if (results.len > 0) allocator.free(results);
    }

    // Check if root is in results (it should be on most systems)
    var found_root = false;
    for (results) |r| {
        if (std.mem.eql(u8, r, "~root")) {
            found_root = true;
            break;
        }
    }
    // root should be available on Unix systems
    if (@import("builtin").os.tag != .windows) {
        try std.testing.expect(found_root);
    }
}

test "username expansion - tilde only" {
    const allocator = std.testing.allocator;
    var comp = Completion.init(allocator);

    // Just ~ should expand to HOME
    const expanded = try comp.expandUsername("~");
    if (expanded) |home| {
        defer allocator.free(home);
        try std.testing.expect(home.len > 0);
        // Home should be an absolute path
        try std.testing.expect(home[0] == '/');
    }
}

test "username expansion - current user" {
    const allocator = std.testing.allocator;
    var comp = Completion.init(allocator);

    // Get current username
    const username = env_utils.getEnv("USER") orelse return;

    // ~username should expand to HOME
    var buf: [256]u8 = undefined;
    const with_tilde = try std.fmt.bufPrint(&buf, "~{s}", .{username});

    const expanded = try comp.expandUsername(with_tilde);
    if (expanded) |home| {
        defer allocator.free(home);
        try std.testing.expect(home.len > 0);
        try std.testing.expect(home[0] == '/');
    }
}

test "username expansion - root user" {
    const allocator = std.testing.allocator;
    var comp = Completion.init(allocator);

    // ~root should expand to /root or /var/root on most Unix systems
    const expanded = try comp.expandUsername("~root");

    if (@import("builtin").os.tag != .windows) {
        if (expanded) |home| {
            defer allocator.free(home);
            try std.testing.expect(home.len > 0);
            // Should contain "root"
            try std.testing.expect(std.mem.indexOf(u8, home, "root") != null);
        }
    }
}
