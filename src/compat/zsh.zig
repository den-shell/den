//! zsh compatibility layer for Den.
//!
//! This module groups together zsh-flavored behaviors that are not part of the
//! POSIX core: glob qualifiers (`*(.)`, `*(/)`, ...), `%`-style prompt escapes,
//! and the `setopt`/`unsetopt` option-name vocabulary. Each piece is written so
//! it can be unit-tested in isolation and wired into the existing glob, prompt,
//! and option-handling code paths.

const std = @import("std");
const PromptContext = @import("../prompt/types.zig").PromptContext;

// ---------------------------------------------------------------------------
// Glob qualifiers: a trailing `(...)` group on a glob pattern that filters the
// matched paths by file type / permission, e.g. `*(/)` -> directories only.
// ---------------------------------------------------------------------------

/// Split a glob word into the bare pattern and its qualifier (without parens).
/// Returns null qualifier when the word does not end in a `(...)` group.
pub const SplitPattern = struct {
    pattern: []const u8,
    qualifier: ?[]const u8,
};

pub fn splitQualifier(word: []const u8) SplitPattern {
    if (word.len < 3) return .{ .pattern = word, .qualifier = null };
    if (word[word.len - 1] != ')') return .{ .pattern = word, .qualifier = null };

    // Find the matching '(' for the trailing ')'. The qualifier group is the
    // last balanced parenthesized run at the very end of the word.
    var depth: usize = 0;
    var i: usize = word.len;
    while (i > 0) {
        i -= 1;
        switch (word[i]) {
            ')' => depth += 1,
            '(' => {
                depth -= 1;
                if (depth == 0) {
                    // Require the group to be at the end and the pattern to
                    // contain at least one glob metacharacter, otherwise this
                    // is just a normal parenthesized word, not a qualifier.
                    const pattern = word[0..i];
                    const qualifier = word[i + 1 .. word.len - 1];
                    if (qualifier.len == 0) return .{ .pattern = word, .qualifier = null };
                    if (!looksLikeQualifier(qualifier)) return .{ .pattern = word, .qualifier = null };
                    return .{ .pattern = pattern, .qualifier = qualifier };
                }
            },
            else => {},
        }
    }
    return .{ .pattern = word, .qualifier = null };
}

/// A qualifier is only a handful of known characters; if the group contains
/// anything else we assume it is ordinary shell text (e.g. a subshell).
fn looksLikeQualifier(q: []const u8) bool {
    for (q) |c| {
        switch (c) {
            '/', '.', '@', '*', 'x', 'r', 'w', 'X', 'R', 'W', 'L', 'p', 's', 'd', 'f' => {},
            else => return false,
        }
    }
    return true;
}

/// Does a path satisfy every predicate in the qualifier string?
/// `dir` is the directory the paths are relative to.
pub fn matchesQualifier(io: std.Io, dir: std.Io.Dir, path: []const u8, qualifier: []const u8) bool {
    for (qualifier) |q| {
        if (!matchesSingle(io, dir, path, q)) return false;
    }
    return true;
}

fn matchesSingle(io: std.Io, dir: std.Io.Dir, path: []const u8, q: u8) bool {
    switch (q) {
        '/', 'd' => return kindOf(io, dir, path, true) == .directory,
        '.', 'f' => return kindOf(io, dir, path, true) == .file,
        '@' => return kindOf(io, dir, path, false) == .sym_link,
        'p' => return kindOf(io, dir, path, true) == .named_pipe,
        's' => return kindOf(io, dir, path, true) == .unix_domain_socket,
        '*', 'x', 'X' => return hasMode(io, dir, path, 0o111),
        'r', 'R' => return hasMode(io, dir, path, 0o444),
        'w', 'W' => return hasMode(io, dir, path, 0o222),
        'L' => return true, // size qualifier without comparator: accept all
        else => return true,
    }
}

fn kindOf(io: std.Io, dir: std.Io.Dir, path: []const u8, follow: bool) std.Io.File.Kind {
    const st = dir.statFile(io, path, .{ .follow_symlinks = follow }) catch return .unknown;
    return st.kind;
}

fn hasMode(io: std.Io, dir: std.Io.Dir, path: []const u8, bits: std.posix.mode_t) bool {
    const st = dir.statFile(io, path, .{}) catch return false;
    return (st.permissions.toMode() & bits) != 0;
}

/// Filter `paths` against the qualifier, returning the kept subset.
/// Does not free the dropped slices (caller owns the backing memory).
pub fn filterByQualifier(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    paths: []const []const u8,
    qualifier: []const u8,
) ![][]const u8 {
    var kept: std.ArrayList([]const u8) = .empty;
    errdefer kept.deinit(allocator);
    for (paths) |p| {
        if (matchesQualifier(io, dir, p, qualifier)) {
            try kept.append(allocator, p);
        }
    }
    return kept.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// zsh `%`-style prompt escapes.
// ---------------------------------------------------------------------------

/// Expand zsh-style `%` escapes in `fmt` using values from `ctx`.
/// Supported: %n %m %M %~ %d %/ %c %C %# %% %B %b %U %u %F{c} %f %K{c} %k
/// %T (HH:MM) %* (HH:MM:SS) %D (yy-mm-dd) %? (last exit code).
pub fn expandPromptEscapes(
    allocator: std.mem.Allocator,
    fmt: []const u8,
    ctx: *const PromptContext,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < fmt.len) {
        const c = fmt[i];
        if (c != '%') {
            try out.append(allocator, c);
            i += 1;
            continue;
        }
        i += 1;
        if (i >= fmt.len) {
            try out.append(allocator, '%');
            break;
        }
        const spec = fmt[i];
        i += 1;
        switch (spec) {
            '%' => try out.append(allocator, '%'),
            'n' => try out.appendSlice(allocator, ctx.username),
            'm' => try out.appendSlice(allocator, shortHost(ctx.hostname)),
            'M' => try out.appendSlice(allocator, ctx.hostname),
            'd', '/' => try out.appendSlice(allocator, ctx.current_dir),
            '~' => try appendTildeDir(allocator, &out, ctx),
            'c', 'C' => try out.appendSlice(allocator, lastComponent(ctx.current_dir)),
            '#' => try out.append(allocator, if (ctx.is_root) '#' else '%'),
            '?' => try out.print(allocator, "{d}", .{ctx.last_exit_code}),
            'B' => try out.appendSlice(allocator, "\x1b[1m"),
            'b' => try out.appendSlice(allocator, "\x1b[22m"),
            'U' => try out.appendSlice(allocator, "\x1b[4m"),
            'u' => try out.appendSlice(allocator, "\x1b[24m"),
            'f' => try out.appendSlice(allocator, "\x1b[39m"),
            'k' => try out.appendSlice(allocator, "\x1b[49m"),
            'F', 'K' => {
                // %F{color} / %K{color}. Parse an optional {name} argument.
                const is_bg = spec == 'K';
                if (i < fmt.len and fmt[i] == '{') {
                    const close = std.mem.indexOfScalarPos(u8, fmt, i + 1, '}') orelse fmt.len;
                    const name = fmt[i + 1 .. @min(close, fmt.len)];
                    i = if (close < fmt.len) close + 1 else fmt.len;
                    try appendColor(allocator, &out, name, is_bg);
                }
            },
            'T' => try appendTime(allocator, &out, ctx.current_time, false),
            '*' => try appendTime(allocator, &out, ctx.current_time, true),
            'D' => try appendDate(allocator, &out, ctx.current_time),
            else => {
                // Unknown escape: emit verbatim so nothing is silently dropped.
                try out.append(allocator, '%');
                try out.append(allocator, spec);
            },
        }
    }
    return out.toOwnedSlice(allocator);
}

fn shortHost(host: []const u8) []const u8 {
    const dot = std.mem.indexOfScalar(u8, host, '.') orelse return host;
    return host[0..dot];
}

fn lastComponent(path: []const u8) []const u8 {
    if (path.len == 0) return path;
    var end = path.len;
    if (path[end - 1] == '/' and end > 1) end -= 1;
    const slash = std.mem.lastIndexOfScalar(u8, path[0..end], '/') orelse return path[0..end];
    return path[slash + 1 .. end];
}

fn appendTildeDir(allocator: std.mem.Allocator, out: *std.ArrayList(u8), ctx: *const PromptContext) !void {
    if (ctx.home_dir) |home| {
        if (home.len > 0 and std.mem.startsWith(u8, ctx.current_dir, home)) {
            try out.append(allocator, '~');
            try out.appendSlice(allocator, ctx.current_dir[home.len..]);
            return;
        }
    }
    try out.appendSlice(allocator, ctx.current_dir);
}

fn appendColor(allocator: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, bg: bool) !void {
    const code: u8 = blk: {
        if (std.fmt.parseInt(u8, name, 10)) |n| {
            // Numeric 256-color code.
            try out.print(allocator, "\x1b[{d};5;{d}m", .{ @as(u8, if (bg) 48 else 38), n });
            return;
        } else |_| {}
        break :blk namedColorCode(name) orelse 9; // 9 = default
    };
    const base: u8 = if (bg) 40 else 30;
    try out.print(allocator, "\x1b[{d}m", .{base + code});
}

fn namedColorCode(name: []const u8) ?u8 {
    const map = .{
        .{ "black", 0 },   .{ "red", 1 },     .{ "green", 2 }, .{ "yellow", 3 },
        .{ "blue", 4 },    .{ "magenta", 5 }, .{ "cyan", 6 },  .{ "white", 7 },
        .{ "default", 9 },
    };
    inline for (map) |entry| {
        if (std.ascii.eqlIgnoreCase(name, entry[0])) return entry[1];
    }
    return null;
}

fn appendTime(allocator: std.mem.Allocator, out: *std.ArrayList(u8), epoch: i64, with_secs: bool) !void {
    if (epoch <= 0) return;
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(epoch) };
    const ds = es.getDaySeconds();
    const h = ds.getHoursIntoDay();
    const m = ds.getMinutesIntoHour();
    if (with_secs) {
        try out.print(allocator, "{d:0>2}:{d:0>2}:{d:0>2}", .{ h, m, ds.getSecondsIntoMinute() });
    } else {
        try out.print(allocator, "{d:0>2}:{d:0>2}", .{ h, m });
    }
}

fn appendDate(allocator: std.mem.Allocator, out: *std.ArrayList(u8), epoch: i64) !void {
    if (epoch <= 0) return;
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(epoch) };
    const ed = es.getEpochDay();
    const yd = ed.calculateYearDay();
    const md = yd.calculateMonthDay();
    try out.print(allocator, "{d:0>2}-{d:0>2}-{d:0>2}", .{
        @as(u16, @intCast(yd.year % 100)),
        md.month.numeric(),
        md.day_index + 1,
    });
}

// ---------------------------------------------------------------------------
// setopt / unsetopt option vocabulary.
//
// zsh exposes a large set of named options. We map the ones that have a direct
// Den equivalent onto the shell's existing `shopt_*` / `option_*` flags. The
// mapping is expressed as data so it can be tested without a live Shell.
// ---------------------------------------------------------------------------

/// Which Den flag a zsh option name controls.
pub const OptionTarget = enum {
    extglob,
    nullglob,
    dotglob,
    nocaseglob,
    globstar,
    failglob,
    autocd,
    histappend,
    expand_aliases,
    errexit,
    nounset,
    xtrace,
    noglob,
    pipefail,
    verbose,
    unknown,
};

/// Resolve a zsh option name to a Den flag target. Some zsh names invert the
/// boolean (e.g. `noglob` enables noglob, while `glob` disables it); the second
/// tuple element is the value to store when the option is *set*.
pub const Resolved = struct {
    target: OptionTarget,
    /// Value written to the target when the option is being enabled (setopt).
    /// For `unsetopt`, callers store the negation of this.
    on_value: bool,
};

pub fn resolveOption(name: []const u8) Resolved {
    const Entry = struct { []const u8, OptionTarget, bool };
    const table = [_]Entry{
        .{ "extendedglob", .extglob, true },
        .{ "extended_glob", .extglob, true },
        .{ "nullglob", .nullglob, true },
        .{ "null_glob", .nullglob, true },
        .{ "globdots", .dotglob, true },
        .{ "glob_dots", .dotglob, true },
        .{ "nocaseglob", .nocaseglob, true },
        .{ "no_case_glob", .nocaseglob, true },
        .{ "globstarshort", .globstar, true },
        .{ "globstar", .globstar, true },
        .{ "nomatch", .failglob, true }, // setopt nomatch => error on failed glob
        .{ "failglob", .failglob, true },
        .{ "autocd", .autocd, true },
        .{ "auto_cd", .autocd, true },
        .{ "appendhistory", .histappend, true },
        .{ "append_history", .histappend, true },
        .{ "aliases", .expand_aliases, true },
        .{ "errexit", .errexit, true },
        .{ "err_exit", .errexit, true },
        .{ "nounset", .nounset, true },
        .{ "no_unset", .nounset, true },
        .{ "xtrace", .xtrace, true },
        .{ "noglob", .noglob, true },
        .{ "no_glob", .noglob, true },
        .{ "pipefail", .pipefail, true },
        .{ "pipe_fail", .pipefail, true },
        .{ "verbose", .verbose, true },
    };
    for (table) |e| {
        if (std.ascii.eqlIgnoreCase(name, e[0])) {
            return .{ .target = e[1], .on_value = e[2] };
        }
    }
    return .{ .target = .unknown, .on_value = true };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "splitQualifier extracts trailing qualifier" {
    const r = splitQualifier("*(/)");
    try testing.expect(r.qualifier != null);
    try testing.expectEqualStrings("*", r.pattern);
    try testing.expectEqualStrings("/", r.qualifier.?);
}

test "splitQualifier ignores ordinary words" {
    try testing.expect(splitQualifier("foo").qualifier == null);
    try testing.expect(splitQualifier("$(date)").qualifier == null);
    // Non-qualifier characters inside the group => not a qualifier.
    try testing.expect(splitQualifier("*(hello)").qualifier == null);
}

test "splitQualifier handles multi-char qualifiers" {
    const r = splitQualifier("**/*(.x)");
    try testing.expect(r.qualifier != null);
    try testing.expectEqualStrings("**/*", r.pattern);
    try testing.expectEqualStrings(".x", r.qualifier.?);
}

test "resolveOption maps zsh names" {
    try testing.expectEqual(OptionTarget.extglob, resolveOption("extendedglob").target);
    try testing.expectEqual(OptionTarget.nullglob, resolveOption("NULL_GLOB").target);
    try testing.expectEqual(OptionTarget.autocd, resolveOption("autocd").target);
    try testing.expectEqual(OptionTarget.unknown, resolveOption("bogusoption").target);
}

fn testCtx() PromptContext {
    var ctx = PromptContext.init(testing.allocator);
    ctx.current_dir = "/home/alice/projects/den";
    ctx.home_dir = "/home/alice";
    ctx.username = "alice";
    ctx.hostname = "host.example.com";
    return ctx;
}

test "expandPromptEscapes basic specs" {
    var ctx = testCtx();
    defer ctx.custom_data.deinit();

    const s1 = try expandPromptEscapes(testing.allocator, "%n@%m %~ %#", &ctx);
    defer testing.allocator.free(s1);
    try testing.expectEqualStrings("alice@host ~/projects/den %", s1);

    const s2 = try expandPromptEscapes(testing.allocator, "%c", &ctx);
    defer testing.allocator.free(s2);
    try testing.expectEqualStrings("den", s2);

    const s3 = try expandPromptEscapes(testing.allocator, "100%%", &ctx);
    defer testing.allocator.free(s3);
    try testing.expectEqualStrings("100%", s3);
}

test "expandPromptEscapes root marker and unknown escape" {
    var ctx = testCtx();
    ctx.is_root = true;
    defer ctx.custom_data.deinit();
    const s = try expandPromptEscapes(testing.allocator, "%# %z", &ctx);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("# %z", s);
}
