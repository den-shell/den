//! Enable Builtin Implementation
//!
//! This module implements the enable builtin command
//! for managing loadable shell builtins.

const std = @import("std");
const all_builtin_names = @import("../utils/builtin_names.zig");
const IO = @import("../utils/io.zig").IO;
const types = @import("../types/mod.zig");

// Forward declaration for Shell type
const Shell = @import("../shell.zig").Shell;

/// Builtin: enable - enable and disable shell builtins
///   enable              - list all loadable builtins
///   enable -a           - list all builtins (built-in and loadable)
///   enable -f file name - load builtin from shared object file
///   enable -d name      - delete (unload) a loadable builtin
///   enable -n name      - disable a loadable builtin
///   enable name         - enable a loadable builtin
pub fn builtinEnable(self: *Shell, cmd: *types.ParsedCommand) !void {
    var load_file: ?[]const u8 = null;
    var delete_mode = false;
    var disable_mode = false;
    var list_all = false;
    var names_start: usize = 0;

    // Parse options
    var i: usize = 0;
    while (i < cmd.args.len) : (i += 1) {
        const arg = cmd.args[i];
        if (arg.len > 0 and arg[0] == '-') {
            for (arg[1..]) |c| {
                switch (c) {
                    'f' => {
                        // -f file: load from file
                        i += 1;
                        if (i >= cmd.args.len) {
                            try IO.eprint("den: enable: -f: option requires an argument\n", .{});
                            self.last_exit_code = 1;
                            return;
                        }
                        load_file = cmd.args[i];
                    },
                    'd' => {
                        delete_mode = true;
                    },
                    'n' => {
                        disable_mode = true;
                    },
                    'a' => {
                        list_all = true;
                    },
                    'p', 's' => {
                        // -p: print, -s: special builtins (ignored for now)
                    },
                    else => {
                        try IO.eprint("den: enable: -{c}: invalid option\n", .{c});
                        self.last_exit_code = 1;
                        return;
                    },
                }
            }
            names_start = i + 1;
        } else {
            break;
        }
    }

    // If no arguments after options, list builtins
    if (names_start >= cmd.args.len and !list_all and load_file == null) {
        // List loaded builtins
        var iter = self.loadable_builtins.list();
        var count: usize = 0;
        while (iter.next()) |entry| {
            const info = entry.value_ptr.*;
            const status = if (info.enabled) "enabled" else "disabled";
            try IO.print("enable {s} ({s})\n", .{ info.name, status });
            count += 1;
        }
        if (count == 0) {
            try IO.print("No loadable builtins currently loaded.\n", .{});
            try IO.print("Use 'enable -f <library.so> <name>' to load a builtin.\n", .{});
        }
        self.last_exit_code = 0;
        return;
    }

    // If -a specified, list all builtins
    if (list_all) {
        // List built-in commands
        // The canonical list rather than another copy, which held 67 of the
        // 163 names.
        const names = all_builtin_names.all;
        try IO.print("Built-in commands:\n", .{});
        for (names) |name| {
            try IO.print("  {s}\n", .{name});
        }

        // List loadable builtins
        var iter = self.loadable_builtins.list();
        var has_loadable = false;
        while (iter.next()) |entry| {
            if (!has_loadable) {
                try IO.print("\nLoadable builtins:\n", .{});
                has_loadable = true;
            }
            const info = entry.value_ptr.*;
            const status = if (info.enabled) "enabled" else "disabled";
            try IO.print("  {s} ({s}) [{s}]\n", .{ info.name, status, info.path });
        }
        self.last_exit_code = 0;
        return;
    }

    // Process remaining arguments as builtin names
    const names = cmd.args[names_start..];
    if (names.len == 0 and load_file != null) {
        try IO.eprint("den: enable: -f: builtin name required\n", .{});
        self.last_exit_code = 1;
        return;
    }

    for (names) |name| {
        if (load_file) |file| {
            // Load builtin from file
            self.loadable_builtins.load(name, file) catch |err| {
                switch (err) {
                    error.AlreadyLoaded => try IO.eprint("den: enable: {s}: already loaded\n", .{name}),
                    error.LoadFailed => try IO.eprint("den: enable: {s}: cannot open shared object: {s}\n", .{ name, file }),
                    error.SymbolNotFound => try IO.eprint("den: enable: {s}: function '{s}_builtin' not found in {s}\n", .{ name, name, file }),
                    error.InitFailed => try IO.eprint("den: enable: {s}: initialization failed\n", .{name}),
                    else => try IO.eprint("den: enable: {s}: load error\n", .{name}),
                }
                self.last_exit_code = 1;
                return;
            };
            try IO.print("enable: loaded '{s}' from {s}\n", .{ name, file });
        } else if (delete_mode) {
            // Delete (unload) builtin
            self.loadable_builtins.unload(name) catch {
                try IO.eprint("den: enable: {s}: not a loadable builtin\n", .{name});
                self.last_exit_code = 1;
                return;
            };
            try IO.print("enable: unloaded '{s}'\n", .{name});
        } else if (disable_mode) {
            // Disable builtin
            self.loadable_builtins.disable(name) catch {
                try IO.eprint("den: enable: {s}: not a loadable builtin\n", .{name});
                self.last_exit_code = 1;
                return;
            };
        } else {
            // Enable builtin
            self.loadable_builtins.enable(name) catch {
                try IO.eprint("den: enable: {s}: not a loadable builtin\n", .{name});
                self.last_exit_code = 1;
                return;
            };
        }
    }

    self.last_exit_code = 0;
}
