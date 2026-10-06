//! zsh's `autoload`: mark a name to be defined from `$fpath` on first use.
//!
//! This is the line above `compinit` in most configs, and it is also the only
//! thing that ever gave `fpath` a meaning -- den accepted `fpath=(...)` as an
//! array but nothing read it, so a directory of shell functions was unreachable.
//!
//! Laziness is the point. zsh defers the file read until the function is
//! actually called, which is why a config can autoload dozens of names without
//! paying for them at startup; den, whose whole claim is a fast start, should
//! not be the shell that reads them all eagerly. So `autoload` records the name
//! and `resolve` does the work later, from the executor's function lookup.
//!
//! The file holds a function *body*, not a `name() { ... }` wrapper. That is
//! zsh's convention and what the files in a real `fpath` directory contain.

const std = @import("std");
const builtin = @import("builtin");
const IO = @import("../utils/io.zig").IO;
const types = @import("../types/mod.zig");

const Shell = @import("../shell.zig").Shell;
const Executor = @import("../executor/mod.zig").Executor;

/// What a lookup of a possibly-autoloaded name found.
pub const Outcome = enum {
    /// Not marked for autoloading; carry on down the normal search.
    not_autoloaded,
    /// A function of that name now exists and can be called.
    defined,
    /// Marked, but no file for it anywhere in `fpath`. zsh reports this as its
    /// own error rather than `command not found`, which is the more useful
    /// failure: it says the name was known and the search path is wrong.
    missing_file,
};

/// Directories to search, in order: the `fpath` array first, then `FPATH`.
///
/// zsh keeps the two tied together. Den has no such tie, so both are read, and
/// a config that sets either works.
fn forEachDir(
    self: *Shell,
    context: anytype,
    comptime visit: fn (@TypeOf(context), []const u8) ?[]u8,
) ?[]u8 {
    if (self.arrays.get("fpath")) |arr| {
        for (arr.values) |dir| {
            if (dir.len == 0) continue;
            if (visit(context, dir)) |found| return found;
        }
    }
    if (self.environment.get("FPATH")) |fpath| {
        var it = std.mem.splitScalar(u8, fpath, ':');
        while (it.next()) |dir| {
            if (dir.len == 0) continue;
            if (visit(context, dir)) |found| return found;
        }
    }
    return null;
}

/// One chunked read, the same shape the config loader uses: this Zig has no
/// single-call read-to-end on `std.Io.File`.
fn readChunk(file: std.Io.File, buf: []u8) !usize {
    if (builtin.os.tag == .windows) {
        var bytes_read: u32 = 0;
        const ok = @import("windows_compat").ReadFile(file.handle, buf.ptr, @intCast(buf.len), &bytes_read, null);
        if (ok == 0) return error.ReadFailed;
        return bytes_read;
    }
    return std.posix.read(file.handle, buf);
}

const Search = struct {
    allocator: std.mem.Allocator,
    name: []const u8,

    /// The file is read whole: these are function bodies, a few hundred bytes
    /// at most, and the alternative is a stat followed by an open that can
    /// still fail.
    fn visit(self: Search, dir: []const u8) ?[]u8 {
        const path = std.fs.path.join(self.allocator, &.{ dir, self.name }) catch return null;
        defer self.allocator.free(path);

        const file = std.Io.Dir.cwd().openFile(std.Options.debug_io, path, .{}) catch return null;
        defer file.close(std.Options.debug_io);

        var content: std.ArrayList(u8) = .empty;
        errdefer content.deinit(self.allocator);
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = readChunk(file, &buf) catch break;
            if (n == 0) break;
            content.appendSlice(self.allocator, buf[0..n]) catch return null;
        }
        return content.toOwnedSlice(self.allocator) catch null;
    }
};

fn searchVisit(context: Search, dir: []const u8) ?[]u8 {
    return context.visit(dir);
}

/// Define `name` from its `fpath` file, if it is marked and not yet defined.
///
/// Costs one `count()` on a shell that never autoloads anything, which is the
/// common case and why this can sit in the executor's hot path.
pub fn resolve(self: *Shell, name: []const u8) Outcome {
    if (self.autoloads.count() == 0) return .not_autoloaded;
    if (!self.autoloads.contains(name)) return .not_autoloaded;

    const body = forEachDir(self, Search{ .allocator = self.allocator, .name = name }, searchVisit) orelse {
        return .missing_file;
    };
    defer self.allocator.free(body);

    // Split into lines the way a function body is stored. A trailing newline
    // would otherwise add an empty final line.
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(self.allocator);
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, body, "\n"), '\n');
    while (it.next()) |line| lines.append(self.allocator, line) catch return .missing_file;

    self.function_manager.defineFunction(name, lines.items, false) catch return .missing_file;

    // Marked names are consumed once defined: zsh replaces the placeholder with
    // the real function, and leaving it marked would re-read the file if the
    // function were later removed and the name called again.
    if (self.autoloads.fetchRemove(name)) |kv| self.allocator.free(kv.key);

    return .defined;
}

/// Report a name whose definition file could not be found, as zsh words it.
pub fn reportMissing(name: []const u8) void {
    IO.eprint("den: {s}: function definition file not found\n", .{name}) catch {};
}

fn mark(self: *Shell, name: []const u8) !void {
    if (self.autoloads.contains(name)) return;
    const key = try self.allocator.dupe(u8, name);
    errdefer self.allocator.free(key);
    try self.autoloads.put(key, {});
}

pub fn builtinAutoload(self: *Shell, cmd: *types.ParsedCommand) !void {
    var load_now = false;
    var names: usize = 0;

    // Flags first, so `autoload +X -Uz foo` and `autoload -Uz +X foo` agree.
    for (cmd.args) |arg| {
        if (arg.len >= 2 and (arg[0] == '-' or arg[0] == '+')) {
            for (arg[1..]) |c| switch (c) {
                // +X loads immediately instead of on first call; -R is the same
                // with an error when the file is missing, which is what this
                // does in either spelling.
                'X', 'R' => load_now = true,
                // -U suppresses alias expansion in the body, -z and -k pick zsh
                // or ksh style, -r resolves the path early, -w, -t, -m, -d and
                // -s concern the dump files and tracing. None of them changes
                // what den does with the name.
                'U', 'z', 'k', 'r', 'w', 't', 'm', 'd', 's' => {},
                else => {
                    try IO.eprint("den: autoload: bad option: {c}{c}\n", .{ arg[0], c });
                    try IO.eprint("usage: autoload [-UXzkrRw] name ...\n", .{});
                    self.last_exit_code = 2;
                    return;
                },
            };
            continue;
        }
        names += 1;
    }

    if (names == 0) {
        // zsh prints each marked name as a placeholder function definition.
        // Den prints the names, which is what a reader or a script wants from
        // this, and says so in the docs rather than imitating the stub.
        var it = self.autoloads.keyIterator();
        while (it.next()) |key| try IO.print("{s}\n", .{key.*});
        self.last_exit_code = 0;
        return;
    }

    var failed = false;
    for (cmd.args) |arg| {
        if (arg.len >= 2 and (arg[0] == '-' or arg[0] == '+')) continue;

        // A name that is already a function is left alone: a config that
        // defines a function and then autoloads the name should keep the
        // definition it just made.
        if (self.function_manager.hasFunction(arg)) continue;

        // Nor is anything den already provides marked. The zsh functions a
        // config autoloads -- compinit, add-zsh-hook, bashcompinit,
        // is-at-least -- are builtins here, and `autoload -Uz compinit;
        // compinit` is the most common pair of lines in a .zshrc. zsh lets the
        // placeholder shadow even a builtin, so `autoload -Uz echo` breaks
        // `echo` there; refusing to shadow is the deliberate divergence that
        // makes those configs work, and it costs nothing, since a name den
        // implements needs no definition file.
        if (Executor.isBuiltinName(arg) or Shell.isShellBuiltinName(arg)) continue;

        try mark(self, arg);
        if (!load_now) continue;

        switch (resolve(self, arg)) {
            .defined => {},
            .missing_file => {
                reportMissing(arg);
                failed = true;
            },
            // Just marked, so this cannot happen.
            .not_autoloaded => {},
        }
    }

    self.last_exit_code = if (failed) 1 else 0;
}
