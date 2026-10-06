//! zsh-style `zstyle` builtin: the pattern-keyed style database.
//!
//! The store lives on the Shell; this is the surface over it. Besides setting
//! styles, zsh scripts query them with `-b`, `-s`, `-t` and friends, so those are
//! here too -- a function that reads its own configuration through `zstyle -s`
//! works rather than silently seeing nothing.

const std = @import("std");
const IO = @import("../utils/io.zig").IO;
const types = @import("../types/mod.zig");
const zstyle = @import("../compat/zstyle.zig");

const Shell = @import("../shell.zig").Shell;

const usage_line =
    "usage: zstyle [-L] [pattern [style]] | zstyle pattern style value ... |\n" ++
    "       zstyle -d [pattern [style ...]] | zstyle -g array [pattern [style]] |\n" ++
    // The braces are doubled because this is used as a format string.
    "       zstyle -{{b,s,a,t,T,m}} context style [name|value]\n";

fn usageError(self: *Shell, comptime fmt: []const u8, args: anytype) !void {
    try IO.eprint("den: zstyle: " ++ fmt, args);
    try IO.eprint(usage_line, .{});
    self.last_exit_code = 2;
}

/// Whether a word survives being read back without quotes.
///
/// Deliberately strict: a style pattern has a `*` in it and a matcher-list has
/// braces, so anything but plain characters is quoted rather than left for the
/// shell to glob or brace-expand when the dump is re-run.
fn isBareWord(word: []const u8) bool {
    if (word.len == 0) return false;
    for (word) |c| {
        const plain = std.ascii.isAlphanumeric(c) or
            c == '_' or c == '.' or c == '/' or c == ':' or
            c == '=' or c == '+' or c == '-' or c == ',' or c == '@';
        if (!plain) return false;
    }
    return true;
}

fn printWord(word: []const u8) !void {
    if (isBareWord(word)) {
        try IO.print("{s}", .{word});
    } else {
        try IO.print("'{s}'", .{word});
    }
}

/// Print one entry the way `zstyle -L` does, so the output can be re-run.
fn printEntry(entry: zstyle.Entry) !void {
    try IO.print("zstyle ", .{});
    try printWord(entry.pattern);
    try IO.print(" ", .{});
    try printWord(entry.name);
    for (entry.values) |v| {
        try IO.print(" ", .{});
        try printWord(v);
    }
    try IO.print("\n", .{});
}

/// Join a style's values with spaces, for the scalar query forms.
fn joinValues(allocator: std.mem.Allocator, values: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (values, 0..) |v, i| {
        if (i > 0) try out.append(allocator, ' ');
        try out.appendSlice(allocator, v);
    }
    return out.toOwnedSlice(allocator);
}

pub fn builtinZstyle(self: *Shell, cmd: *types.ParsedCommand) !void {
    if (cmd.args.len == 0) {
        // Listing everything, as a bare `zstyle` does.
        for (self.zstyles.items()) |entry| try printEntry(entry);
        self.last_exit_code = 0;
        return;
    }

    const first = cmd.args[0];
    if (first.len >= 2 and first[0] == '-') {
        const rest = cmd.args[1..];
        switch (first[1]) {
            // Listing, optionally narrowed to a pattern and style.
            'L' => {
                for (self.zstyles.items()) |entry| {
                    if (rest.len >= 1 and !std.mem.eql(u8, entry.pattern, rest[0])) continue;
                    if (rest.len >= 2 and !std.mem.eql(u8, entry.name, rest[1])) continue;
                    try printEntry(entry);
                }
                self.last_exit_code = 0;
            },

            // Delete: everything, a pattern, or named styles of a pattern.
            'd' => {
                if (rest.len == 0) {
                    self.zstyles.clear(self.allocator);
                } else if (rest.len == 1) {
                    _ = self.zstyles.deletePattern(self.allocator, rest[0]);
                } else {
                    for (rest[1..]) |name| {
                        _ = self.zstyles.deleteStyle(self.allocator, rest[0], name);
                    }
                }
                self.last_exit_code = 0;
            },

            // Test whether a style is set and true.
            't', 'T' => {
                if (rest.len < 2) {
                    try usageError(self, "-{c} needs a context and a style\n", .{first[1]});
                    return;
                }
                const values = self.zstyles.get(rest[0], rest[1]);
                const result = if (values) |v| blk: {
                    if (rest.len > 2) {
                        // With values given, it is true when the style is one of them.
                        for (rest[2..]) |want| {
                            for (v) |have| {
                                if (std.mem.eql(u8, have, want)) break :blk true;
                            }
                        }
                        break :blk false;
                    }
                    break :blk zstyle.isTrue(v);
                } else
                    // -T treats an unset style as true, -t as false.
                    first[1] == 'T';
                self.last_exit_code = if (result) 0 else 1;
            },

            // Boolean into a variable.
            'b' => {
                if (rest.len < 3) {
                    try usageError(self, "-b needs a context, a style and a variable\n", .{});
                    return;
                }
                const set = self.zstyles.get(rest[0], rest[1]) != null;
                const value = self.zstyles.boolean(rest[0], rest[1], false);
                try self.setVariableValue(rest[2], if (value) "yes" else "no");
                self.last_exit_code = if (set) 0 else 1;
            },

            // Scalar into a variable, values joined by a separator.
            's' => {
                if (rest.len < 3) {
                    try usageError(self, "-s needs a context, a style and a variable\n", .{});
                    return;
                }
                const values = self.zstyles.get(rest[0], rest[1]);
                if (values) |v| {
                    const joined = try joinValues(self.allocator, v);
                    defer self.allocator.free(joined);
                    try self.setVariableValue(rest[2], joined);
                    self.last_exit_code = 0;
                } else {
                    try self.setVariableValue(rest[2], "");
                    self.last_exit_code = 1;
                }
            },

            // Array into a variable. Den has no array assignment from a builtin,
            // so this joins with spaces and says so once.
            'a', 'g' => {
                const want: usize = if (first[1] == 'a') 3 else 1;
                if (rest.len < want) {
                    try usageError(self, "-{c} needs a variable\n", .{first[1]});
                    return;
                }
                if (first[1] == 'a') {
                    const values = self.zstyles.get(rest[0], rest[1]);
                    if (values) |v| {
                        const joined = try joinValues(self.allocator, v);
                        defer self.allocator.free(joined);
                        try self.setVariableValue(rest[2], joined);
                        self.last_exit_code = 0;
                    } else {
                        try self.setVariableValue(rest[2], "");
                        self.last_exit_code = 1;
                    }
                } else {
                    // -g collects matching patterns, or styles, or values.
                    //
                    // With a pattern and a style given, one entry matches and its
                    // values are the answer. Narrowed less than that, the words
                    // repeat -- several styles share a pattern -- and zsh reports
                    // each once, so already-collected words are skipped. What is
                    // remembered is the store's own slice, never a formatted copy,
                    // which is freed before the next entry is looked at.
                    var out: std.ArrayList(u8) = .empty;
                    defer out.deinit(self.allocator);
                    var seen: std.ArrayList([]const u8) = .empty;
                    defer seen.deinit(self.allocator);
                    var found = false;

                    for (self.zstyles.items()) |entry| {
                        if (rest.len >= 2 and !std.mem.eql(u8, entry.pattern, rest[1])) continue;
                        if (rest.len >= 3 and !std.mem.eql(u8, entry.name, rest[2])) continue;

                        if (rest.len >= 3) {
                            const joined = try joinValues(self.allocator, entry.values);
                            defer self.allocator.free(joined);
                            if (out.items.len > 0) try out.append(self.allocator, ' ');
                            try out.appendSlice(self.allocator, joined);
                            found = true;
                            continue;
                        }

                        const word = if (rest.len == 2) entry.name else entry.pattern;
                        var already = false;
                        for (seen.items) |had| {
                            if (std.mem.eql(u8, had, word)) {
                                already = true;
                                break;
                            }
                        }
                        if (already) continue;
                        try seen.append(self.allocator, word);

                        if (out.items.len > 0) try out.append(self.allocator, ' ');
                        try out.appendSlice(self.allocator, word);
                    }
                    try self.setVariableValue(rest[0], out.items);
                    // Only the three-argument form is a lookup that can fail.
                    // Collecting patterns or style names succeeds even when the
                    // store has nothing to offer, which is what zsh reports.
                    self.last_exit_code = if (rest.len < 3 or found) 0 else 1;
                }
            },

            // Pattern-match a style's value.
            'm' => {
                if (rest.len < 3) {
                    try usageError(self, "-m needs a context, a style and a pattern\n", .{});
                    return;
                }
                const values = self.zstyles.get(rest[0], rest[1]) orelse {
                    self.last_exit_code = 1;
                    return;
                };
                var matched = false;
                for (values) |v| {
                    if (zstyle.matchesPattern(rest[2], v)) {
                        matched = true;
                        break;
                    }
                }
                self.last_exit_code = if (matched) 0 else 1;
            },

            // Styles whose value is code to evaluate on each lookup. The store
            // holds values, not deferred expressions, so this is refused rather
            // than quietly treated as a literal.
            'e' => {
                try IO.eprint(
                    "den: zstyle: -e is not supported: styles hold values, not code to evaluate\n",
                    .{},
                );
                self.last_exit_code = 2;
            },

            else => {
                try usageError(self, "bad option: -{c}\n", .{first[1]});
            },
        }
        return;
    }

    // Setting, or listing one pattern.
    if (cmd.args.len == 1) {
        for (self.zstyles.items()) |entry| {
            if (std.mem.eql(u8, entry.pattern, first)) try printEntry(entry);
        }
        self.last_exit_code = 0;
        return;
    }

    const name = cmd.args[1];
    const values = cmd.args[2..];
    self.zstyles.set(self.allocator, first, name, values) catch {
        try IO.eprint("den: zstyle: out of memory\n", .{});
        self.last_exit_code = 1;
        return;
    };
    // Styles den acts on take effect as soon as they are set.
    self.applyZstyles();
    self.last_exit_code = 0;
}
