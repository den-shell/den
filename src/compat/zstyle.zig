//! zsh's `zstyle` database: values keyed by a context pattern and a style name.
//!
//! A context is a colon-separated string such as `:completion:::::`, and a
//! pattern is a context with `*` and `?` in it. Looking a style up finds every
//! pattern that matches the context and takes the most specific one, which is
//! how `:completion:*` is overridden by `:completion:*:git:*`.
//!
//! Pure data: imports only std, so it unit-tests without a Shell.

const std = @import("std");

/// One `zstyle <pattern> <name> <values...>` entry.
pub const Entry = struct {
    pattern: []u8,
    name: []u8,
    values: [][]u8,

    fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.pattern);
        allocator.free(self.name);
        for (self.values) |v| allocator.free(v);
        allocator.free(self.values);
    }
};

/// Whether `pattern` matches `text`, with `*` for any run and `?` for one
/// character.
///
/// zsh patterns also have grouping and alternation; those are not supported, and
/// a pattern using them simply will not match. Real-world zstyle patterns are
/// colons, literals and `*`.
pub fn matchesPattern(pattern: []const u8, text: []const u8) bool {
    var p: usize = 0;
    var t: usize = 0;
    // Where to resume from if a later mismatch means the last `*` should have
    // swallowed one more character.
    var star: ?usize = null;
    var star_t: usize = 0;

    while (t < text.len) {
        if (p < pattern.len and (pattern[p] == '?' or pattern[p] == text[t])) {
            p += 1;
            t += 1;
        } else if (p < pattern.len and pattern[p] == '*') {
            star = p;
            p += 1;
            star_t = t;
        } else if (star) |s| {
            p = s + 1;
            star_t += 1;
            t = star_t;
        } else {
            return false;
        }
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

/// How specific a pattern is: the number of characters it matches literally.
///
/// zsh's own rule is more involved, but "most literal characters wins" picks the
/// same entry for the patterns people actually write, where one is a narrowing of
/// another.
pub fn specificity(pattern: []const u8) usize {
    var n: usize = 0;
    for (pattern) |c| {
        if (c != '*' and c != '?') n += 1;
    }
    return n;
}

/// Whether a style's value reads as true, following zsh: `true`, `yes`, `on` and
/// `1` are true, and a style set with no value at all is true as well.
pub fn isTrue(values: []const []const u8) bool {
    if (values.len == 0) return true;
    const v = values[0];
    return std.ascii.eqlIgnoreCase(v, "true") or
        std.ascii.eqlIgnoreCase(v, "yes") or
        std.ascii.eqlIgnoreCase(v, "on") or
        std.mem.eql(u8, v, "1");
}

pub const Store = struct {
    entries: std.ArrayList(Entry) = .empty,

    pub fn deinit(self: *Store, allocator: std.mem.Allocator) void {
        for (self.entries.items) |*e| e.deinit(allocator);
        self.entries.deinit(allocator);
        self.entries = .empty;
    }

    /// Set a style, replacing any existing one for the same pattern and name.
    pub fn set(
        self: *Store,
        allocator: std.mem.Allocator,
        pattern: []const u8,
        name: []const u8,
        values: []const []const u8,
    ) !void {
        var owned = try allocator.alloc([]u8, values.len);
        var filled: usize = 0;
        errdefer {
            for (owned[0..filled]) |v| allocator.free(v);
            allocator.free(owned);
        }
        for (values, 0..) |v, i| {
            owned[i] = try allocator.dupe(u8, v);
            filled = i + 1;
        }

        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.pattern, pattern) and std.mem.eql(u8, e.name, name)) {
                for (e.values) |v| allocator.free(v);
                allocator.free(e.values);
                e.values = owned;
                return;
            }
        }

        const pat = try allocator.dupe(u8, pattern);
        errdefer allocator.free(pat);
        const nm = try allocator.dupe(u8, name);
        errdefer allocator.free(nm);
        try self.entries.append(allocator, .{ .pattern = pat, .name = nm, .values = owned });
    }

    /// The values of `name` for `context`, from the most specific pattern that
    /// matches, or null if none does.
    pub fn get(self: *const Store, context: []const u8, name: []const u8) ?[]const []const u8 {
        var best: ?usize = null;
        var best_score: usize = 0;
        for (self.entries.items, 0..) |e, i| {
            if (!std.mem.eql(u8, e.name, name)) continue;
            if (!matchesPattern(e.pattern, context)) continue;
            const score = specificity(e.pattern);
            // Ties go to whichever was set first, as zsh does.
            if (best == null or score > best_score) {
                best = i;
                best_score = score;
            }
        }
        const idx = best orelse return null;
        return self.entries.items[idx].values;
    }

    /// A style read as a boolean, or `fallback` when it is not set at all.
    pub fn boolean(self: *const Store, context: []const u8, name: []const u8, fallback: bool) bool {
        const values = self.get(context, name) orelse return fallback;
        return isTrue(values);
    }

    /// The first value of a style, or null when it is unset or valueless.
    pub fn first(self: *const Store, context: []const u8, name: []const u8) ?[]const u8 {
        const values = self.get(context, name) orelse return null;
        if (values.len == 0) return null;
        return values[0];
    }

    /// Remove every style set on `pattern`. Returns how many went.
    pub fn deletePattern(self: *Store, allocator: std.mem.Allocator, pattern: []const u8) usize {
        var removed: usize = 0;
        var i: usize = 0;
        while (i < self.entries.items.len) {
            if (std.mem.eql(u8, self.entries.items[i].pattern, pattern)) {
                var e = self.entries.orderedRemove(i);
                e.deinit(allocator);
                removed += 1;
            } else {
                i += 1;
            }
        }
        return removed;
    }

    /// Remove one style from one pattern.
    pub fn deleteStyle(
        self: *Store,
        allocator: std.mem.Allocator,
        pattern: []const u8,
        name: []const u8,
    ) bool {
        for (self.entries.items, 0..) |e, i| {
            if (std.mem.eql(u8, e.pattern, pattern) and std.mem.eql(u8, e.name, name)) {
                var removed = self.entries.orderedRemove(i);
                removed.deinit(allocator);
                return true;
            }
        }
        return false;
    }

    pub fn clear(self: *Store, allocator: std.mem.Allocator) void {
        for (self.entries.items) |*e| e.deinit(allocator);
        self.entries.clearRetainingCapacity();
    }

    /// Every entry, in the order they were set, which is the order `zstyle -L`
    /// prints them.
    pub fn items(self: *const Store) []const Entry {
        return self.entries.items;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "matchesPattern handles star and question mark" {
    try testing.expect(matchesPattern("*", ":completion:::::"));
    try testing.expect(matchesPattern(":completion:*", ":completion:::::"));
    try testing.expect(matchesPattern(":completion:*:git:*", ":completion::complete:git:argument-1:"));
    try testing.expect(matchesPattern(":completion:::::", ":completion:::::"));
    try testing.expect(matchesPattern("a?c", "abc"));

    try testing.expect(!matchesPattern(":completion:*", ":other:thing"));
    try testing.expect(!matchesPattern("a?c", "ac"));
    try testing.expect(!matchesPattern("abc", "abcd"));
    // Backtracking: the star must give a character back for the suffix to fit.
    try testing.expect(matchesPattern("*:git:*", ":completion::complete:git:arg:"));
    try testing.expect(!matchesPattern("*:svn:*", ":completion::complete:git:arg:"));
}

test "specificity counts the literal characters" {
    try testing.expectEqual(@as(usize, 0), specificity("*"));
    try testing.expectEqual(@as(usize, 11), specificity(":completion"));
    try testing.expect(specificity(":completion:*:git:*") > specificity(":completion:*"));
}

test "isTrue follows zsh's spellings" {
    try testing.expect(isTrue(&.{}));
    try testing.expect(isTrue(&.{"true"}));
    try testing.expect(isTrue(&.{"YES"}));
    try testing.expect(isTrue(&.{"on"}));
    try testing.expect(isTrue(&.{"1"}));
    try testing.expect(!isTrue(&.{"false"}));
    try testing.expect(!isTrue(&.{"no"}));
    try testing.expect(!isTrue(&.{"off"}));
    try testing.expect(!isTrue(&.{"0"}));
    try testing.expect(!isTrue(&.{"anything else"}));
}

test "set and get a style" {
    var store = Store{};
    defer store.deinit(testing.allocator);

    try store.set(testing.allocator, ":completion:*", "verbose", &.{"yes"});
    const values = store.get(":completion:::::", "verbose").?;
    try testing.expectEqual(@as(usize, 1), values.len);
    try testing.expectEqualStrings("yes", values[0]);

    // A context the pattern does not match has nothing.
    try testing.expectEqual(@as(?[]const []const u8, null), store.get(":other", "verbose"));
    // A style that was never set has nothing.
    try testing.expectEqual(@as(?[]const []const u8, null), store.get(":completion:x", "menu"));
}

test "setting the same pattern and style again replaces it" {
    var store = Store{};
    defer store.deinit(testing.allocator);

    try store.set(testing.allocator, ":completion:*", "verbose", &.{"yes"});
    try store.set(testing.allocator, ":completion:*", "verbose", &.{"no"});
    try testing.expectEqual(@as(usize, 1), store.items().len);
    try testing.expectEqualStrings("no", store.first(":completion:x", "verbose").?);
}

test "the most specific matching pattern wins" {
    var store = Store{};
    defer store.deinit(testing.allocator);

    try store.set(testing.allocator, "*", "verbose", &.{"everywhere"});
    try store.set(testing.allocator, ":completion:*", "verbose", &.{"completion"});
    try store.set(testing.allocator, ":completion:*:git:*", "verbose", &.{"git"});

    try testing.expectEqualStrings("git", store.first(":completion::complete:git:arg:", "verbose").?);
    try testing.expectEqualStrings("completion", store.first(":completion::complete:ls:arg:", "verbose").?);
    try testing.expectEqualStrings("everywhere", store.first(":zle:something", "verbose").?);
}

test "several values are kept in order" {
    var store = Store{};
    defer store.deinit(testing.allocator);

    try store.set(testing.allocator, ":completion:*", "matcher-list", &.{ "", "m:{a-z}={A-Z}" });
    const values = store.get(":completion:x", "matcher-list").?;
    try testing.expectEqual(@as(usize, 2), values.len);
    try testing.expectEqualStrings("", values[0]);
    try testing.expectEqualStrings("m:{a-z}={A-Z}", values[1]);
}

test "boolean reads a style with a fallback" {
    var store = Store{};
    defer store.deinit(testing.allocator);

    try testing.expect(store.boolean(":completion:x", "verbose", true));
    try testing.expect(!store.boolean(":completion:x", "verbose", false));

    try store.set(testing.allocator, ":completion:*", "verbose", &.{"no"});
    try testing.expect(!store.boolean(":completion:x", "verbose", true));

    // A style set with no value is true.
    try store.set(testing.allocator, ":completion:*", "menu", &.{});
    try testing.expect(store.boolean(":completion:x", "menu", false));
}

test "deleting a whole pattern and a single style" {
    var store = Store{};
    defer store.deinit(testing.allocator);

    try store.set(testing.allocator, ":completion:*", "verbose", &.{"yes"});
    try store.set(testing.allocator, ":completion:*", "menu", &.{"select"});
    try store.set(testing.allocator, ":other:*", "verbose", &.{"yes"});

    try testing.expect(store.deleteStyle(testing.allocator, ":completion:*", "menu"));
    try testing.expect(!store.deleteStyle(testing.allocator, ":completion:*", "menu"));
    try testing.expectEqual(@as(usize, 2), store.items().len);

    try testing.expectEqual(@as(usize, 1), store.deletePattern(testing.allocator, ":completion:*"));
    try testing.expectEqual(@as(usize, 1), store.items().len);
    try testing.expectEqualStrings(":other:*", store.items()[0].pattern);

    store.clear(testing.allocator);
    try testing.expectEqual(@as(usize, 0), store.items().len);
}

test "an untouched store allocates nothing" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var store = Store{};
    _ = store.get(":completion:x", "verbose");
    _ = store.boolean(":completion:x", "verbose", true);
    store.deinit(failing.allocator());
    try testing.expectEqual(@as(usize, 0), failing.allocations);
}
