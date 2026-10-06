//! zsh's `add-zsh-hook`: register a function on one of the shell's hook arrays.
//!
//! This is a real binding rather than a compatibility stub. Den already walks
//! `chpwd_functions`, `precmd_functions` and `preexec_functions` (see
//! `dir_hooks.zig`), so `add-zsh-hook precmd foo` genuinely arranges for `foo`
//! to run -- which is how most prompt frameworks and shell integrations install
//! themselves, by writing exactly that line into an rc file.
//!
//! zsh ships this as an autoloaded function, not a builtin. Den has no `fpath`
//! loading, so it is a builtin here; the surface is the same to a caller.

const std = @import("std");
const IO = @import("../utils/io.zig").IO;
const types = @import("../types/mod.zig");
const zstyle = @import("../compat/zstyle.zig");

const Shell = @import("../shell.zig").Shell;

/// The hooks den actually fires. A name outside this list is refused rather
/// than silently accepted: a function added to an array nothing walks would
/// never run, and the user would have no way to tell.
const known_hooks = [_][]const u8{
    "chpwd",
    "precmd",
    "preexec",
    "zshexit",
};

/// Hooks zsh fires and den does not. zsh accepts these, so refusing them is a
/// deliberate divergence: each needs machinery den has no part of -- a timer
/// for `periodic`, a history filter for `zshaddhistory`, a name resolver for
/// `zsh_directory_name` -- and a function registered on one would simply never
/// run. An error at the rc line beats a hook that silently does nothing.
const zsh_only_hooks = [_][]const u8{
    "periodic",
    "zshaddhistory",
    "zsh_directory_name",
};

fn isKnown(name: []const u8) bool {
    for (known_hooks) |h| {
        if (std.mem.eql(u8, h, name)) return true;
    }
    return false;
}

fn isZshOnly(name: []const u8) bool {
    for (zsh_only_hooks) |h| {
        if (std.mem.eql(u8, h, name)) return true;
    }
    return false;
}

fn errorUnknownHook(self: *Shell, name: []const u8) !void {
    if (isZshOnly(name)) {
        try IO.eprint(
            "den: add-zsh-hook: den does not fire {s}, so the function would never run\n",
            .{name},
        );
    } else {
        try IO.eprint("Usage: add-zsh-hook hook function\n", .{});
    }
    try IO.eprint("Valid hooks are:\n", .{});
    try IO.eprint(" ", .{});
    for (known_hooks) |h| try IO.eprint(" {s}", .{h});
    try IO.eprint("\n", .{});
    self.last_exit_code = 1;
}

/// The array a hook's functions are listed in, e.g. `precmd_functions`.
fn arrayName(allocator: std.mem.Allocator, hook: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}_functions", .{hook});
}

/// Index of `want` in the hook array, or null. Used so adding twice is a no-op
/// and deleting knows whether there is anything to do.
fn indexOf(self: *Shell, array: []const u8, want: []const u8) ?usize {
    const arr = self.arrays.get(array) orelse return null;
    for (arr.values, 0..) |v, i| {
        if (std.mem.eql(u8, v, want)) return i;
    }
    return null;
}

/// Append one function name to a hook array, creating the array if needed.
///
/// Order matters -- hooks run in the order they were added -- so this appends
/// rather than inserting, and a name already present is left where it is.
fn appendToArray(self: *Shell, array: []const u8, func: []const u8) !void {
    if (self.arrays.getPtr(array)) |existing| {
        const old_len = existing.values.len;
        const vals = try self.allocator.alloc([]const u8, old_len + 1);
        errdefer self.allocator.free(vals);
        const idx = try self.allocator.alloc(usize, old_len + 1);
        errdefer self.allocator.free(idx);

        @memcpy(vals[0..old_len], existing.values);
        vals[old_len] = try self.allocator.dupe(u8, func);
        for (idx, 0..) |*p, i| p.* = i;

        // The element strings moved into `vals`, so only the old backing
        // slices are released.
        existing.deinitShallow(self.allocator);
        existing.* = .{ .values = vals, .indices = idx };
        return;
    }

    const vals = try self.allocator.alloc([]const u8, 1);
    errdefer self.allocator.free(vals);
    vals[0] = try self.allocator.dupe(u8, func);
    const key = try self.allocator.dupe(u8, array);
    errdefer self.allocator.free(key);
    try self.arrays.put(key, try types.IndexedArray.fromOwnedDense(self.allocator, vals));
}

/// Remove function names from a hook array. Absent is not an error: an rc file
/// that removes a hook it never added must not start failing.
///
/// `as_pattern` is zsh's `-D`, where the operand is a glob rather than a name,
/// so one line can drop a whole family of hooks. The matcher is the one the
/// style store uses, which already implements `*` and `?` with backtracking.
fn removeFromArray(self: *Shell, array: []const u8, func: []const u8, as_pattern: bool) !void {
    const existing = self.arrays.getPtr(array) orelse return;

    var keep: usize = 0;
    for (existing.values) |v| {
        const hit = if (as_pattern) zstyle.matchesPattern(func, v) else std.mem.eql(u8, v, func);
        if (!hit) keep += 1;
    }
    if (keep == existing.values.len) return;

    const vals = try self.allocator.alloc([]const u8, keep);
    errdefer self.allocator.free(vals);
    const idx = try self.allocator.alloc(usize, keep);
    errdefer self.allocator.free(idx);

    var at: usize = 0;
    for (existing.values) |v| {
        const hit = if (as_pattern) zstyle.matchesPattern(func, v) else std.mem.eql(u8, v, func);
        if (hit) {
            self.allocator.free(v);
            continue;
        }
        vals[at] = v;
        idx[at] = at;
        at += 1;
    }

    // Surviving element strings moved into `vals`; only the backing slices go.
    existing.deinitShallow(self.allocator);
    existing.* = .{ .values = vals, .indices = idx };
}

pub fn builtinAddZshHook(self: *Shell, cmd: *types.ParsedCommand) !void {
    var delete = false;
    var by_pattern = false;
    var list = false;
    var operands: [2][]const u8 = .{ "", "" };
    var operand_count: usize = 0;

    for (cmd.args) |arg| {
        if (arg.len >= 2 and arg[0] == '-') {
            for (arg[1..]) |c| switch (c) {
                'd' => delete = true,
                'L' => list = true,
                // zsh's -D deletes by pattern rather than by name, so one
                // line can drop a family of hooks.
                'D' => {
                    delete = true;
                    by_pattern = true;
                },
                // -U skips zsh's duplicate check. Adding twice is already a
                // no-op here, so there is nothing to skip.
                'U' => {},
                else => {
                    try IO.eprint("den: add-zsh-hook: bad option: -{c}\n", .{c});
                    try IO.eprint("usage: add-zsh-hook [-dDUL] hook function\n", .{});
                    self.last_exit_code = 2;
                    return;
                },
            };
            continue;
        }
        if (operand_count < operands.len) {
            operands[operand_count] = arg;
            operand_count += 1;
        }
    }

    if (operand_count == 0) {
        try IO.eprint("usage: add-zsh-hook [-dDUL] hook function\n", .{});
        self.last_exit_code = 2;
        return;
    }

    const hook = operands[0];
    if (!isKnown(hook)) {
        try errorUnknownHook(self, hook);
        return;
    }

    const array = try arrayName(self.allocator, hook);
    defer self.allocator.free(array);

    if (list) {
        // zsh prints a re-runnable declaration rather than bare names, the same
        // convention as `bindkey -L` and `zstyle -L`. Nothing is printed for a
        // hook with no functions, which is also what zsh does.
        if (self.arrays.get(array)) |arr| {
            if (arr.values.len > 0) {
                try IO.print("typeset -g -a {s}=(", .{array});
                for (arr.values) |v| try IO.print(" {s}", .{v});
                try IO.print(" )\n", .{});
            }
        }
        self.last_exit_code = 0;
        return;
    }

    if (operand_count < 2) {
        try IO.eprint("den: add-zsh-hook: {s} needs a function name\n", .{hook});
        self.last_exit_code = 2;
        return;
    }
    const func = operands[1];

    if (delete) {
        try removeFromArray(self, array, func, by_pattern);
        self.last_exit_code = 0;
        return;
    }

    // Adding the same function twice would run it twice per prompt, and an rc
    // file sourced a second time is the common way that happens.
    if (indexOf(self, array, func) != null) {
        self.last_exit_code = 0;
        return;
    }

    try appendToArray(self, array, func);
    self.last_exit_code = 0;
}
