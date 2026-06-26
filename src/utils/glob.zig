const std = @import("std");
const builtin = @import("builtin");
const zsh = @import("../compat/zsh.zig");

/// Platform-specific path separator
const path_sep = if (builtin.os.tag == .windows) '\\' else '/';
const path_sep_str = if (builtin.os.tag == .windows) "\\" else "/";

/// LRU cache for glob expansion results
pub const GlobCache = struct {
    const CacheEntry = struct {
        results: [][]const u8,
        age: u64,
    };

    allocator: std.mem.Allocator,
    entries: std.StringHashMap(CacheEntry),
    max_entries: u32,
    access_counter: u64,

    pub fn init(allocator: std.mem.Allocator, max_entries: u32) GlobCache {
        return .{
            .allocator = allocator,
            .entries = std.StringHashMap(CacheEntry).init(allocator),
            .max_entries = max_entries,
            .access_counter = 0,
        };
    }

    pub fn deinit(self: *GlobCache) void {
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            for (entry.value_ptr.results) |result| {
                self.allocator.free(result);
            }
            self.allocator.free(entry.value_ptr.results);
            self.allocator.free(entry.key_ptr.*);
        }
        self.entries.deinit();
    }

    pub fn get(self: *GlobCache, key: []const u8) ?[][]const u8 {
        if (self.entries.getPtr(key)) |entry| {
            // Update access time
            self.access_counter += 1;
            entry.age = self.access_counter;
            return entry.results;
        }
        return null;
    }

    pub fn put(self: *GlobCache, key: []const u8, results: [][]const u8) !void {
        // Check if we need to evict
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

        var copied: usize = 0;
        errdefer for (results_copy[0..copied]) |r| self.allocator.free(r);

        for (results, 0..) |result, i| {
            results_copy[i] = try self.allocator.dupe(u8, result);
            copied = i + 1;
        }

        self.access_counter += 1;
        try self.entries.put(key_copy, .{
            .results = results_copy,
            .age = self.access_counter,
        });
    }

    fn evictOldest(self: *GlobCache) void {
        var oldest_key: ?[]const u8 = null;
        var oldest_age: u64 = std.math.maxInt(u64);

        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.age < oldest_age) {
                oldest_age = entry.value_ptr.age;
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

    pub fn clear(self: *GlobCache) void {
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

    pub fn count(self: *GlobCache) usize {
        return self.entries.count();
    }
};

/// Glob pattern matching and expansion
pub const Glob = struct {
    allocator: std.mem.Allocator,
    cache: ?*GlobCache,
    /// Honor zsh glob qualifiers like `*(.)`, `*(/)`, `*(x)` (set from config).
    qualifiers_enabled: bool = false,

    pub fn init(allocator: std.mem.Allocator) Glob {
        return .{ .allocator = allocator, .cache = null };
    }

    pub fn initWithCache(allocator: std.mem.Allocator, cache: *GlobCache) Glob {
        return .{ .allocator = allocator, .cache = cache };
    }

    /// Expand glob pattern into list of matching files
    /// Returns allocated array of file paths
    pub fn expand(self: *Glob, pattern: []const u8, cwd: []const u8) ![][]const u8 {
        // zsh glob qualifiers: split a trailing `(...)` group, expand the bare
        // pattern, then filter the matches by file type / permission.
        if (self.qualifiers_enabled) {
            const sp = zsh.splitQualifier(pattern);
            if (sp.qualifier) |qual| {
                const matches = try self.expand(sp.pattern, cwd);
                const io = std.Options.debug_io;
                var dir = std.Io.Dir.cwd().openDir(io, cwd, .{}) catch return matches;
                defer dir.close(io);
                const filtered = try zsh.filterByQualifier(self.allocator, io, dir, matches, qual);
                // Free the dropped entries and the outer slice of `matches`.
                outer: for (matches) |m| {
                    for (filtered) |f| {
                        if (f.ptr == m.ptr) continue :outer;
                    }
                    self.allocator.free(m);
                }
                self.allocator.free(matches);
                return filtered;
            }
        }

        // Check if pattern contains glob characters
        if (!self.hasGlobChars(pattern)) {
            // No glob characters - return pattern as-is
            const result = try self.allocator.alloc([]const u8, 1);
            errdefer self.allocator.free(result);
            result[0] = try self.allocator.dupe(u8, pattern);
            return result;
        }

        // Build cache key from pattern + cwd. If the combined length exceeds
        // the stack buffer, skip caching entirely rather than silently collide
        // on a pattern-only key (which would cause different cwds to share
        // bogus cached results).
        var cache_key_buf: [1024]u8 = undefined;
        const cache_key_opt: ?[]const u8 = blk: {
            const needed = cwd.len + 1 + pattern.len;
            if (needed > cache_key_buf.len) break :blk null;
            break :blk std.fmt.bufPrint(&cache_key_buf, "{s}:{s}", .{ cwd, pattern }) catch null;
        };

        // Check cache first (only when a valid cache key was produced)
        if (self.cache) |cache| {
            if (cache_key_opt) |cache_key| {
                if (cache.get(cache_key)) |cached_results| {
                    // Return a copy of cached results
                    const result = try self.allocator.alloc([]const u8, cached_results.len);
                    for (cached_results, 0..) |r, i| {
                        result[i] = try self.allocator.dupe(u8, r);
                    }
                    return result;
                }
            }
        }

        // Simple implementation: expand basic wildcards in current directory
        var matches_buffer: [256][]const u8 = undefined;
        var match_count: usize = 0;

        // Open directory. Distinguish the directory we *open* (needs a real path,
        // falling back to cwd) from the prefix we *prepend* to each match: bash
        // keeps results relative to the pattern, so a bare `*.txt` yields plain
        // names while `sub/*.txt` and `./*.txt` keep their directory part.
        const pattern_dir = std.fs.path.dirname(pattern);
        const dir_path = pattern_dir orelse cwd;
        const base_pattern = std.fs.path.basename(pattern);

        // Parse extended glob features
        const parsed = self.parseExtendedGlob(base_pattern);

        var dir = std.Io.Dir.cwd().openDir(std.Options.debug_io, dir_path, .{ .iterate = true }) catch |err| {
            // Can't open directory - return pattern as-is
            if (err == error.FileNotFound or err == error.AccessDenied) {
                const result = try self.allocator.alloc([]const u8, 1);
                result[0] = try self.allocator.dupe(u8, pattern);
                return result;
            }
            return err;
        };
        defer dir.close(std.Options.debug_io);

        // Iterate directory and match pattern
        var iter = dir.iterate();
        while (try iter.next(std.Options.debug_io)) |entry| {
            // Match base pattern
            if (!self.matchPattern(parsed.base, entry.name)) {
                continue;
            }

            // Check exclusion pattern
            if (parsed.exclusion) |exclusion| {
                if (self.matchPattern(exclusion, entry.name)) {
                    continue; // Excluded
                }
            }

            // Check file type qualifier
            if (parsed.qualifier) |qualifier| {
                if (!self.matchesQualifier(dir, entry.name, qualifier)) {
                    continue;
                }
            }

            // Match found
            if (match_count >= matches_buffer.len) {
                break; // Too many matches
            }

            // Prepend only the pattern's own directory part (if any), so matches
            // stay relative like bash; a directory-less pattern yields bare names.
            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const full_path = if (pattern_dir) |pd| blk: {
                break :blk try std.fmt.bufPrint(&path_buf, "{s}" ++ path_sep_str ++ "{s}", .{ pd, entry.name });
            } else blk: {
                break :blk try std.fmt.bufPrint(&path_buf, "{s}", .{entry.name});
            };

            matches_buffer[match_count] = try self.allocator.dupe(u8, full_path);
            match_count += 1;
        }

        // If no matches, return pattern as-is (bash behavior)
        if (match_count == 0) {
            const result = try self.allocator.alloc([]const u8, 1);
            result[0] = try self.allocator.dupe(u8, pattern);
            return result;
        }

        // Sort matches (alphabetically)
        self.sortMatches(matches_buffer[0..match_count]);

        // Allocate and return results
        const result = try self.allocator.alloc([]const u8, match_count);
        @memcpy(result, matches_buffer[0..match_count]);

        // Store in cache only when we computed a valid key (no silent collisions)
        if (self.cache) |cache| {
            if (cache_key_opt) |cache_key| {
                cache.put(cache_key, result) catch {};
            }
        }

        return result;
    }

    /// Check if string contains glob characters
    pub fn hasGlobChars(self: *Glob, pattern: []const u8) bool {
        _ = self;
        var i: usize = 0;
        while (i < pattern.len) : (i += 1) {
            if (pattern[i] == '\\' and i + 1 < pattern.len) {
                i += 1; // Skip escaped character
                continue;
            }
            if (pattern[i] == '*' or pattern[i] == '?' or pattern[i] == '[' or pattern[i] == '~' or pattern[i] == '(' or pattern[i] == '|') {
                return true;
            }
        }
        return false;
    }

    /// Parse extended glob pattern into base pattern, exclusions, and qualifiers
    /// Returns: .{ base_pattern, exclusion_pattern, file_qualifier }
    fn parseExtendedGlob(self: *Glob, pattern: []const u8) struct {
        base: []const u8,
        exclusion: ?[]const u8,
        qualifier: ?u8,
    } {
        _ = self;

        // Check for exclusion pattern: *.txt~*.log
        if (std.mem.indexOfScalar(u8, pattern, '~')) |tilde_pos| {
            const base = pattern[0..tilde_pos];
            const exclusion = pattern[tilde_pos + 1 ..];

            // Check for qualifier after exclusion
            if (std.mem.lastIndexOfScalar(u8, exclusion, '(')) |qual_pos| {
                if (qual_pos + 2 < exclusion.len and exclusion[qual_pos + 2] == ')') {
                    // Check if it's a qualifier (single char, no |)
                    const inside = exclusion[qual_pos + 1 .. qual_pos + 2];
                    if (inside[0] == '.' or inside[0] == '@' or inside[0] == '/' or inside[0] == '*') {
                        return .{
                            .base = base,
                            .exclusion = exclusion[0..qual_pos],
                            .qualifier = exclusion[qual_pos + 1],
                        };
                    }
                }
            }

            return .{
                .base = base,
                .exclusion = exclusion,
                .qualifier = null,
            };
        }

        // Check for qualifier: *.txt(.)
        // Qualifier is at the END and contains a single special char
        if (std.mem.lastIndexOfScalar(u8, pattern, '(')) |qual_pos| {
            if (qual_pos + 2 < pattern.len and pattern[qual_pos + 2] == ')' and qual_pos + 3 == pattern.len) {
                // Check if it's a qualifier (single char, no |)
                const inside = pattern[qual_pos + 1];
                if (inside == '.' or inside == '@' or inside == '/' or inside == '*') {
                    return .{
                        .base = pattern[0..qual_pos],
                        .exclusion = null,
                        .qualifier = inside,
                    };
                }
            }
        }

        return .{
            .base = pattern,
            .exclusion = null,
            .qualifier = null,
        };
    }

    /// Check if file matches the qualifier
    /// . = regular file, @ = symlink, / = directory, * = executable
    fn matchesQualifier(self: *Glob, dir: std.Io.Dir, name: []const u8, qualifier: u8) bool {
        _ = self;

        const stat = dir.statFile(std.Options.debug_io, name, .{}) catch return false;

        return switch (qualifier) {
            '.' => stat.kind == .file,
            '@' => stat.kind == .sym_link,
            '/' => stat.kind == .directory,
            '*' => blk: {
                // Check if executable (Unix permissions)
                if (stat.kind != .file) break :blk false;
                // On Unix, check execute bits
                break :blk if (builtin.os.tag == .windows) true else (stat.permissions.toMode() & 0o111) != 0;
            },
            else => true, // Unknown qualifier - match everything
        };
    }

    /// Match a single filename against a glob pattern
    /// Supports: * (any chars), ? (single char), [abc] (char class), (a|b) (alternation)
    /// Extended glob (extglob): ?(pat), *(pat), +(pat), @(pat), !(pat)
    fn matchPattern(self: *Glob, pattern: []const u8, name: []const u8) bool {
        _ = self;
        return matchPatternExtended(pattern, name, 0, 0);
    }

    /// Extended pattern matching with extglob support
    fn matchPatternExtended(pattern: []const u8, name: []const u8, p_idx: usize, n_idx: usize) bool {
        // End of pattern
        if (p_idx >= pattern.len) {
            return n_idx >= name.len;
        }

        // End of name but not pattern
        if (n_idx >= name.len) {
            // Only valid if rest of pattern is all * or nullable extglob
            var i = p_idx;
            while (i < pattern.len) : (i += 1) {
                const c = pattern[i];
                if (c == '*') continue;
                // Check for ?(pattern) or *(pattern) which can match zero
                if ((c == '?' or c == '*') and i + 1 < pattern.len and pattern[i + 1] == '(') {
                    // Find closing paren
                    if (findClosingParen(pattern, i + 1)) |close_pos| {
                        i = close_pos;
                        continue;
                    }
                }
                return false;
            }
            return true;
        }

        const p_char = pattern[p_idx];

        // Check for extglob patterns: ?(pattern), *(pattern), +(pattern), @(pattern), !(pattern)
        if (p_idx + 1 < pattern.len and pattern[p_idx + 1] == '(' and
            (p_char == '?' or p_char == '*' or p_char == '+' or p_char == '@' or p_char == '!'))
        {
            return matchExtglob(pattern, name, p_idx, n_idx);
        }

        // Check for alternation pattern: (a|b)
        if (p_char == '(') {
            if (findClosingParen(pattern, p_idx)) |close_pos| {
                const alternatives = pattern[p_idx + 1 .. close_pos];
                const suffix = if (close_pos + 1 < pattern.len) pattern[close_pos + 1 ..] else "";

                // Split alternatives by |
                var iter = std.mem.splitScalar(u8, alternatives, '|');
                while (iter.next()) |alt| {
                    // Try matching alt + suffix
                    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
                    const combined = std.fmt.bufPrint(&buf, "{s}{s}", .{ alt, suffix }) catch continue;
                    if (matchPatternExtended(combined, name, 0, n_idx)) {
                        return true;
                    }
                }
                return false;
            }
        }

        switch (p_char) {
            '*' => {
                // Try matching zero or more characters
                // First try zero chars (skip the *)
                if (matchPatternExtended(pattern, name, p_idx + 1, n_idx)) {
                    return true;
                }
                // Try matching one or more chars
                return matchPatternExtended(pattern, name, p_idx, n_idx + 1);
            },
            '?' => {
                // Match any single character
                return matchPatternExtended(pattern, name, p_idx + 1, n_idx + 1);
            },
            '[' => {
                // Character class
                return matchCharClass(pattern, name, p_idx, n_idx);
            },
            else => {
                // Literal character match
                if (p_char != name[n_idx]) {
                    return false;
                }
                return matchPatternExtended(pattern, name, p_idx + 1, n_idx + 1);
            },
        }
    }

    /// Match extended glob patterns: ?(pat), *(pat), +(pat), @(pat), !(pat)
    fn matchExtglob(pattern: []const u8, name: []const u8, p_idx: usize, n_idx: usize) bool {
        const op = pattern[p_idx];
        const open_paren = p_idx + 1;

        // Find matching close paren
        const close_pos = findClosingParen(pattern, open_paren) orelse return false;
        const alternatives = pattern[open_paren + 1 .. close_pos];
        const suffix = if (close_pos + 1 < pattern.len) pattern[close_pos + 1 ..] else "";

        // Split alternatives by |
        var alts: [32][]const u8 = undefined;
        var alt_count: usize = 0;
        var iter = std.mem.splitScalar(u8, alternatives, '|');
        while (iter.next()) |alt| {
            if (alt_count < 32) {
                alts[alt_count] = alt;
                alt_count += 1;
            }
        }

        switch (op) {
            '?' => {
                // ?(pattern) - zero or one occurrence
                // Try zero occurrences (skip extglob, match suffix)
                if (matchPatternExtended(suffix, name, 0, n_idx)) {
                    return true;
                }
                // Try one occurrence of each alternative
                for (alts[0..alt_count]) |alt| {
                    const alt_len = alt.len;
                    if (n_idx + alt_len <= name.len) {
                        // Check if alt matches at current position
                        if (matchPatternExtended(alt, name[n_idx .. n_idx + alt_len], 0, 0)) {
                            // If alt matched, check if suffix matches rest
                            if (matchPatternExtended(suffix, name, 0, n_idx + alt_len)) {
                                return true;
                            }
                        }
                    }
                }
                return false;
            },
            '*' => {
                // *(pattern) - zero or more occurrences
                return matchExtglobStar(alts[0..alt_count], suffix, name, n_idx);
            },
            '+' => {
                // +(pattern) - one or more occurrences
                // Must match at least one occurrence
                for (alts[0..alt_count]) |alt| {
                    const alt_len = alt.len;
                    if (n_idx + alt_len <= name.len) {
                        if (matchPatternExtended(alt, name[n_idx .. n_idx + alt_len], 0, 0)) {
                            // After matching one, try zero or more additional
                            if (matchExtglobStar(alts[0..alt_count], suffix, name, n_idx + alt_len)) {
                                return true;
                            }
                        }
                    }
                }
                return false;
            },
            '@' => {
                // @(pattern) - exactly one occurrence
                for (alts[0..alt_count]) |alt| {
                    const alt_len = alt.len;
                    if (n_idx + alt_len <= name.len) {
                        if (matchPatternExtended(alt, name[n_idx .. n_idx + alt_len], 0, 0)) {
                            if (matchPatternExtended(suffix, name, 0, n_idx + alt_len)) {
                                return true;
                            }
                        }
                    }
                }
                return false;
            },
            '!' => {
                // !(pattern) - anything except the pattern
                // Must not match any of the alternatives followed by suffix
                for (alts[0..alt_count]) |alt| {
                    const alt_len = alt.len;
                    if (n_idx + alt_len <= name.len) {
                        if (matchPatternExtended(alt, name[n_idx .. n_idx + alt_len], 0, 0)) {
                            if (matchPatternExtended(suffix, name, 0, n_idx + alt_len)) {
                                // This alternative matches - fail
                                return false;
                            }
                        }
                    }
                }
                // None of the alternatives matched at this position
                // Match any single character and continue
                if (n_idx < name.len) {
                    // Try matching more characters with !(pattern) or just the suffix
                    // Rebuild the extglob pattern for continued matching
                    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
                    const extglob_pattern = std.fmt.bufPrint(&buf, "{s}{s}", .{ pattern[p_idx .. close_pos + 1], suffix }) catch return false;

                    // Try: skip one char and continue with !(pattern)
                    if (matchPatternExtended(extglob_pattern, name, 0, n_idx + 1)) {
                        return true;
                    }
                    // Also try: current char is start of suffix match
                    if (matchPatternExtended(suffix, name, 0, n_idx)) {
                        return true;
                    }
                }
                // Only suffix remains
                return matchPatternExtended(suffix, name, 0, n_idx);
            },
            else => return false,
        }
    }

    /// Match zero or more occurrences for *(pattern)
    fn matchExtglobStar(alts: []const []const u8, suffix: []const u8, name: []const u8, n_idx: usize) bool {
        // Base case: try matching suffix directly
        if (matchPatternExtended(suffix, name, 0, n_idx)) {
            return true;
        }

        // Try each alternative
        for (alts) |alt| {
            const alt_len = alt.len;
            if (n_idx + alt_len <= name.len) {
                if (matchPatternExtended(alt, name[n_idx .. n_idx + alt_len], 0, 0)) {
                    // Recursively try more occurrences
                    if (matchExtglobStar(alts, suffix, name, n_idx + alt_len)) {
                        return true;
                    }
                }
            }
        }
        return false;
    }

    /// Find closing paren, handling nested parens
    fn findClosingParen(pattern: []const u8, open_pos: usize) ?usize {
        var depth: u32 = 1;
        var i = open_pos + 1;
        while (i < pattern.len) : (i += 1) {
            if (pattern[i] == '(') {
                depth += 1;
            } else if (pattern[i] == ')') {
                depth -= 1;
                if (depth == 0) return i;
            }
        }
        return null;
    }

    /// Match character class [abc] or [a-z] or [[:alpha:]]
    fn matchCharClass(pattern: []const u8, name: []const u8, p_idx: usize, n_idx: usize) bool {
        if (n_idx >= name.len) return false;

        // Find closing bracket
        var end: usize = p_idx + 1;
        var negated = false;

        // Check for negation
        if (end < pattern.len and (pattern[end] == '!' or pattern[end] == '^')) {
            negated = true;
            end += 1;
        }

        // POSIX: ] as the first character in a class (or after ! / ^) is a literal ]
        // e.g., []abc] matches ], a, b, or c; [!]] matches anything except ]
        if (end < pattern.len and pattern[end] == ']') {
            end += 1;
        }

        while (end < pattern.len and pattern[end] != ']') {
            end += 1;
        }
        if (end >= pattern.len) {
            // No closing bracket - treat [ as literal
            if (name[n_idx] == '[') {
                return matchPatternExtended(pattern, name, p_idx + 1, n_idx + 1);
            }
            return false;
        }

        const class_start = if (negated) p_idx + 2 else p_idx + 1;
        const char_class = pattern[class_start..end];
        const n_char = name[n_idx];

        // Check if char is in class
        var matched = matchCharInClass(char_class, n_char);

        if (negated) matched = !matched;
        if (!matched) return false;

        return matchPatternExtended(pattern, name, end + 1, n_idx + 1);
    }

    /// Check if a character matches a character class definition
    fn matchCharInClass(char_class: []const u8, c: u8) bool {
        var i: usize = 0;
        while (i < char_class.len) {
            // Check for POSIX character class [[:alpha:]]
            if (i + 1 < char_class.len and char_class[i] == '[' and char_class[i + 1] == ':') {
                // Find closing :]]
                if (std.mem.indexOf(u8, char_class[i + 2 ..], ":]]")) |end_offset| {
                    const class_name = char_class[i + 2 .. i + 2 + end_offset];
                    if (matchPosixClass(class_name, c)) return true;
                    i += end_offset + 5; // Skip past :]]
                    continue;
                }
            }

            // Check for range a-z
            if (i + 2 < char_class.len and char_class[i + 1] == '-' and char_class[i + 2] != ']') {
                const start = char_class[i];
                const end_char = char_class[i + 2];
                if (c >= start and c <= end_char) return true;
                i += 3;
                continue;
            }

            // Single character
            if (char_class[i] == c) return true;
            i += 1;
        }
        return false;
    }

    /// Match POSIX character classes
    fn matchPosixClass(class_name: []const u8, c: u8) bool {
        if (std.mem.eql(u8, class_name, "alpha")) {
            return std.ascii.isAlphabetic(c);
        } else if (std.mem.eql(u8, class_name, "digit")) {
            return std.ascii.isDigit(c);
        } else if (std.mem.eql(u8, class_name, "alnum")) {
            return std.ascii.isAlphanumeric(c);
        } else if (std.mem.eql(u8, class_name, "space")) {
            return std.ascii.isWhitespace(c);
        } else if (std.mem.eql(u8, class_name, "upper")) {
            return std.ascii.isUpper(c);
        } else if (std.mem.eql(u8, class_name, "lower")) {
            return std.ascii.isLower(c);
        } else if (std.mem.eql(u8, class_name, "punct")) {
            return (c >= '!' and c <= '/') or (c >= ':' and c <= '@') or
                (c >= '[' and c <= '`') or (c >= '{' and c <= '~');
        } else if (std.mem.eql(u8, class_name, "xdigit")) {
            return std.ascii.isHex(c);
        } else if (std.mem.eql(u8, class_name, "blank")) {
            return c == ' ' or c == '\t';
        } else if (std.mem.eql(u8, class_name, "cntrl")) {
            return std.ascii.isControl(c);
        } else if (std.mem.eql(u8, class_name, "graph")) {
            return c > 0x20 and c < 0x7f;
        } else if (std.mem.eql(u8, class_name, "print")) {
            return c >= 0x20 and c < 0x7f;
        }
        return false;
    }

    /// Simple bubble sort for alphabetical ordering
    fn sortMatches(self: *Glob, matches: [][]const u8) void {
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
};

test "glob pattern matching" {
    const allocator = std.testing.allocator;
    var glob = Glob.init(allocator);

    try std.testing.expect(glob.matchPattern("*.txt", "file.txt"));
    try std.testing.expect(glob.matchPattern("*.txt", "test.txt"));
    try std.testing.expect(!glob.matchPattern("*.txt", "file.rs"));

    try std.testing.expect(glob.matchPattern("test?.txt", "test1.txt"));
    try std.testing.expect(glob.matchPattern("test?.txt", "testa.txt"));
    try std.testing.expect(!glob.matchPattern("test?.txt", "test12.txt"));

    try std.testing.expect(glob.matchPattern("file[123].txt", "file1.txt"));
    try std.testing.expect(glob.matchPattern("file[123].txt", "file2.txt"));
    try std.testing.expect(!glob.matchPattern("file[123].txt", "file4.txt"));
}

test "glob has glob chars" {
    const allocator = std.testing.allocator;
    var glob = Glob.init(allocator);

    try std.testing.expect(glob.hasGlobChars("*.txt"));
    try std.testing.expect(glob.hasGlobChars("test?.rs"));
    try std.testing.expect(glob.hasGlobChars("file[123].txt"));
    try std.testing.expect(!glob.hasGlobChars("regular.txt"));
}

test "extglob ?(pattern) - zero or one" {
    const allocator = std.testing.allocator;
    var glob = Glob.init(allocator);

    // ?(foo) matches "" or "foo"
    try std.testing.expect(glob.matchPattern("?(foo)bar", "bar"));
    try std.testing.expect(glob.matchPattern("?(foo)bar", "foobar"));
    try std.testing.expect(!glob.matchPattern("?(foo)bar", "foofoobar"));

    // With alternatives
    try std.testing.expect(glob.matchPattern("?(foo|bar)baz", "baz"));
    try std.testing.expect(glob.matchPattern("?(foo|bar)baz", "foobaz"));
    try std.testing.expect(glob.matchPattern("?(foo|bar)baz", "barbaz"));
}

test "extglob *(pattern) - zero or more" {
    const allocator = std.testing.allocator;
    var glob = Glob.init(allocator);

    // *(foo) matches "", "foo", "foofoo", etc.
    try std.testing.expect(glob.matchPattern("*(foo)bar", "bar"));
    try std.testing.expect(glob.matchPattern("*(foo)bar", "foobar"));
    try std.testing.expect(glob.matchPattern("*(foo)bar", "foofoobar"));
    try std.testing.expect(glob.matchPattern("*(foo)bar", "foofoofoobar"));
}

test "extglob +(pattern) - one or more" {
    const allocator = std.testing.allocator;
    var glob = Glob.init(allocator);

    // +(foo) matches "foo", "foofoo", etc. but not ""
    try std.testing.expect(!glob.matchPattern("+(foo)bar", "bar"));
    try std.testing.expect(glob.matchPattern("+(foo)bar", "foobar"));
    try std.testing.expect(glob.matchPattern("+(foo)bar", "foofoobar"));
}

test "extglob @(pattern) - exactly one" {
    const allocator = std.testing.allocator;
    var glob = Glob.init(allocator);

    // @(foo|bar) matches exactly "foo" or "bar"
    try std.testing.expect(glob.matchPattern("@(foo|bar).txt", "foo.txt"));
    try std.testing.expect(glob.matchPattern("@(foo|bar).txt", "bar.txt"));
    try std.testing.expect(!glob.matchPattern("@(foo|bar).txt", "baz.txt"));
    try std.testing.expect(!glob.matchPattern("@(foo|bar).txt", "foobar.txt"));
}

test "extglob !(pattern) - negation" {
    const allocator = std.testing.allocator;
    var glob = Glob.init(allocator);

    // !(foo) matches anything except "foo"
    try std.testing.expect(glob.matchPattern("!(foo).txt", "bar.txt"));
    try std.testing.expect(glob.matchPattern("!(foo).txt", "baz.txt"));
    try std.testing.expect(!glob.matchPattern("!(foo).txt", "foo.txt"));
}

test "character class with ranges" {
    const allocator = std.testing.allocator;
    var glob = Glob.init(allocator);

    try std.testing.expect(glob.matchPattern("file[a-z].txt", "filea.txt"));
    try std.testing.expect(glob.matchPattern("file[a-z].txt", "filez.txt"));
    try std.testing.expect(!glob.matchPattern("file[a-z].txt", "file1.txt"));

    try std.testing.expect(glob.matchPattern("file[0-9].txt", "file5.txt"));
    try std.testing.expect(!glob.matchPattern("file[0-9].txt", "filea.txt"));
}

test "character class negation" {
    const allocator = std.testing.allocator;
    var glob = Glob.init(allocator);

    try std.testing.expect(glob.matchPattern("file[!0-9].txt", "filea.txt"));
    try std.testing.expect(!glob.matchPattern("file[!0-9].txt", "file1.txt"));

    try std.testing.expect(glob.matchPattern("file[^abc].txt", "filed.txt"));
    try std.testing.expect(!glob.matchPattern("file[^abc].txt", "filea.txt"));
}

test "character class with ] as first char (POSIX)" {
    const allocator = std.testing.allocator;
    var glob = Glob.init(allocator);

    // POSIX: ] as first character in class is literal
    // []abc] should match ], a, b, or c
    try std.testing.expect(glob.matchPattern("[]abc]", "]"));
    try std.testing.expect(glob.matchPattern("[]abc]", "a"));
    try std.testing.expect(glob.matchPattern("[]abc]", "b"));
    try std.testing.expect(!glob.matchPattern("[]abc]", "d"));

    // [!]] should match anything except ]
    try std.testing.expect(!glob.matchPattern("[!]]", "]"));
    try std.testing.expect(glob.matchPattern("[!]]", "a"));
}

test "glob edge cases" {
    const allocator = std.testing.allocator;
    var glob = Glob.init(allocator);

    // Empty pattern matches empty string
    try std.testing.expect(glob.matchPattern("", ""));
    try std.testing.expect(!glob.matchPattern("", "a"));

    // * matches empty string
    try std.testing.expect(glob.matchPattern("*", ""));
    try std.testing.expect(glob.matchPattern("*", "anything"));

    // ? must match exactly one character
    try std.testing.expect(!glob.matchPattern("?", ""));
    try std.testing.expect(glob.matchPattern("?", "x"));
    try std.testing.expect(!glob.matchPattern("?", "xy"));

    // Multiple wildcards
    try std.testing.expect(glob.matchPattern("*.*", "file.txt"));
    try std.testing.expect(glob.matchPattern("*.*", ".hidden"));
    try std.testing.expect(!glob.matchPattern("*.*", "nodot"));

    // Pattern with only wildcards
    try std.testing.expect(glob.matchPattern("???", "abc"));
    try std.testing.expect(!glob.matchPattern("???", "ab"));
    try std.testing.expect(!glob.matchPattern("???", "abcd"));
}

test "POSIX character classes" {
    // Test the matchPosixClass function directly
    try std.testing.expect(Glob.matchPosixClass("alpha", 'a'));
    try std.testing.expect(Glob.matchPosixClass("alpha", 'Z'));
    try std.testing.expect(!Glob.matchPosixClass("alpha", '5'));

    try std.testing.expect(Glob.matchPosixClass("digit", '0'));
    try std.testing.expect(Glob.matchPosixClass("digit", '9'));
    try std.testing.expect(!Glob.matchPosixClass("digit", 'a'));

    try std.testing.expect(Glob.matchPosixClass("alnum", 'a'));
    try std.testing.expect(Glob.matchPosixClass("alnum", '5'));

    try std.testing.expect(Glob.matchPosixClass("upper", 'A'));
    try std.testing.expect(!Glob.matchPosixClass("upper", 'a'));

    try std.testing.expect(Glob.matchPosixClass("lower", 'a'));
    try std.testing.expect(!Glob.matchPosixClass("lower", 'A'));

    try std.testing.expect(Glob.matchPosixClass("space", ' '));
    try std.testing.expect(Glob.matchPosixClass("space", '\t'));

    try std.testing.expect(Glob.matchPosixClass("xdigit", 'a'));
    try std.testing.expect(Glob.matchPosixClass("xdigit", 'F'));
    try std.testing.expect(Glob.matchPosixClass("xdigit", '5'));
    try std.testing.expect(!Glob.matchPosixClass("xdigit", 'g'));
}

test "Glob hasGlobChars detects wildcards" {
    var glob = Glob.init(std.testing.allocator);
    try std.testing.expect(glob.hasGlobChars("*.zig"));
    try std.testing.expect(glob.hasGlobChars("file?"));
    try std.testing.expect(glob.hasGlobChars("[abc]"));
    try std.testing.expect(!glob.hasGlobChars("plain.txt"));
    try std.testing.expect(!glob.hasGlobChars(""));
}
