const std = @import("std");
const builtin = @import("builtin");
const types = @import("../../types/mod.zig");
const IO = @import("../../utils/io.zig").IO;
const BuiltinContext = @import("context.zig").BuiltinContext;
const common = @import("common.zig");

fn getenvFromSlice(key: []const u8) ?[]const u8 {
    var env_buf: [512]u8 = undefined;
    if (key.len >= env_buf.len) return null;
    @memcpy(env_buf[0..key.len], key);
    env_buf[key.len] = 0;
    const value = std.c.getenv(env_buf[0..key.len :0]) orelse return null;
    return std.mem.span(@as([*:0]const u8, @ptrCast(value)));
}

// C library extern declarations for environment manipulation (POSIX only)
const libc_env = if (builtin.os.tag != .windows) struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: [*:0]const u8) c_int;
} else struct {};

/// Environment builtins: env, export, set, unset, envCmd
pub fn env(ctx: *BuiltinContext) !i32 {
    var iter = ctx.envIterator();
    while (iter.next()) |entry| {
        try IO.print("{s}={s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
    }
    return 0;
}

pub fn exportBuiltin(ctx: *BuiltinContext, command: *types.ParsedCommand) !i32 {
    if (command.args.len == 0) {
        return try env(ctx);
    }

    // Check for --help
    for (command.args) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            try IO.print("Usage: export [-fnp] [name[=value] ...]\n", .{});
            try IO.print("Set export attribute for shell variables.\n\n", .{});
            try IO.print("Options:\n", .{});
            try IO.print("  -f    treat each NAME as a shell function\n", .{});
            try IO.print("  -n    remove the export property from NAME\n", .{});
            try IO.print("  -p    display all exported variables and functions\n", .{});
            try IO.print("  -pf   display all exported functions\n", .{});
            try IO.print("\nWith no NAME, display all exported variables.\n", .{});
            return 0;
        }
    }

    // Check for -pf flag (print exported functions)
    if (command.args.len >= 1 and (std.mem.eql(u8, command.args[0], "-pf") or
        (command.args.len >= 2 and std.mem.eql(u8, command.args[0], "-p") and std.mem.eql(u8, command.args[1], "-f"))))
    {
        if (ctx.hasShell()) {
            const shell_ref = try ctx.getShell();
            var iter = shell_ref.function_manager.functions.iterator();
            while (iter.next()) |entry| {
                const func = entry.value_ptr;
                if (func.is_exported) {
                    try IO.print("export -f {s}\n", .{func.name});
                }
            }
        }
        return 0;
    }

    // Check for -p flag (print in reusable format)
    if (command.args.len == 1 and std.mem.eql(u8, command.args[0], "-p")) {
        var iter = ctx.envIterator();
        while (iter.next()) |entry| {
            try IO.print("export {s}=\"", .{entry.key_ptr.*});
            for (entry.value_ptr.*) |c| {
                switch (c) {
                    '"' => try IO.print("\\\"", .{}),
                    '\\' => try IO.print("\\\\", .{}),
                    '$' => try IO.print("\\$", .{}),
                    '`' => try IO.print("\\`", .{}),
                    '\n' => try IO.print("\\n", .{}),
                    else => try IO.print("{c}", .{c}),
                }
            }
            try IO.print("\"\n", .{});
        }
        return 0;
    }

    // Parse flags
    var arg_start: usize = 0;
    var unexport_mode = false;
    var function_mode = false;

    while (arg_start < command.args.len) {
        const arg = command.args[arg_start];
        if (arg.len > 0 and arg[0] == '-') {
            if (std.mem.eql(u8, arg, "-n")) {
                unexport_mode = true;
                arg_start += 1;
            } else if (std.mem.eql(u8, arg, "-f")) {
                function_mode = true;
                arg_start += 1;
            } else if (std.mem.eql(u8, arg, "-nf") or std.mem.eql(u8, arg, "-fn")) {
                unexport_mode = true;
                function_mode = true;
                arg_start += 1;
            } else if (std.mem.eql(u8, arg, "--")) {
                arg_start += 1;
                break;
            } else {
                break;
            }
        } else {
            break;
        }
    }

    // Handle function export mode
    if (function_mode) {
        if (ctx.hasShell()) {
            const shell_ref = try ctx.getShell();
            for (command.args[arg_start..]) |func_name| {
                if (unexport_mode) {
                    if (shell_ref.function_manager.getFunction(func_name)) |func| {
                        func.is_exported = false;
                    } else {
                        try IO.eprint("den: export: {s}: not a function\n", .{func_name});
                    }
                } else {
                    if (shell_ref.function_manager.getFunction(func_name)) |func| {
                        func.is_exported = true;
                    } else {
                        try IO.eprint("den: export: {s}: not a function\n", .{func_name});
                    }
                }
            }
        }
        return 0;
    }

    if (unexport_mode) {
        for (command.args[arg_start..]) |arg| {
            // Remove the export attribute but keep the variable value
            if (ctx.getVarAttributes(arg)) |attrs| {
                var new_attrs = attrs;
                new_attrs.exported = false;
                try ctx.setVarAttributes(arg, new_attrs);
            }
            // Remove from process environment so child processes don't inherit it
            if (comptime builtin.os.tag != .windows) {
                if (arg.len < 512) {
                    var name_buf: [512]u8 = undefined;
                    @memcpy(name_buf[0..arg.len], arg);
                    name_buf[arg.len] = 0;
                    _ = libc_env.unsetenv(name_buf[0..arg.len :0]);
                }
            }
        }
        return 0;
    }

    for (command.args[arg_start..]) |arg| {
        if (std.mem.indexOf(u8, arg, "=")) |eq_pos| {
            const var_name = arg[0..eq_pos];
            const var_value = arg[eq_pos + 1 ..];
            // Restricted mode: block modifications to PATH, SHELL, ENV, BASH_ENV
            if (ctx.hasShell()) {
                const s = try ctx.getShell();
                if (s.option_restricted) {
                    if (std.mem.eql(u8, var_name, "PATH") or
                        std.mem.eql(u8, var_name, "SHELL") or
                        std.mem.eql(u8, var_name, "ENV") or
                        std.mem.eql(u8, var_name, "BASH_ENV"))
                    {
                        try IO.eprint("den: export: {s}: restricted: cannot modify in restricted mode\n", .{var_name});
                        return 1;
                    }
                }
            }
            try ctx.setEnv(var_name, var_value);
            // Also set in process environment so child processes (including $()) inherit it
            if (comptime builtin.os.tag != .windows) {
                if (var_name.len < 512 and var_value.len < 4096) {
                    var name_buf: [512]u8 = undefined;
                    var val_buf: [4096]u8 = undefined;
                    @memcpy(name_buf[0..var_name.len], var_name);
                    name_buf[var_name.len] = 0;
                    @memcpy(val_buf[0..var_value.len], var_value);
                    val_buf[var_value.len] = 0;
                    _ = libc_env.setenv(name_buf[0..var_name.len :0], val_buf[0..var_value.len :0], 1);
                } else {
                    try IO.eprint("den: export: variable name or value too long for process environment\n", .{});
                }
            }
        } else {
            // Just variable name - export existing value (or empty if unset)
            const existing = ctx.getEnv(arg);
            if (existing == null) {
                try ctx.setEnv(arg, "");
            }
            // Set in process environment with existing or empty value
            if (comptime builtin.os.tag != .windows) {
                const val = existing orelse "";
                if (arg.len < 512 and val.len < 4096) {
                    var name_buf: [512]u8 = undefined;
                    var val_buf: [4096]u8 = undefined;
                    @memcpy(name_buf[0..arg.len], arg);
                    name_buf[arg.len] = 0;
                    @memcpy(val_buf[0..val.len], val);
                    val_buf[val.len] = 0;
                    _ = libc_env.setenv(name_buf[0..arg.len :0], val_buf[0..val.len :0], 1);
                } else {
                    try IO.eprint("den: export: variable name or value too long for process environment\n", .{});
                }
            }
        }
    }

    return 0;
}

pub fn set(ctx: *BuiltinContext, command: *types.ParsedCommand) !i32 {
    if (command.args.len == 0) {
        return try env(ctx);
    }

    var arg_idx: usize = 0;
    while (arg_idx < command.args.len) {
        const arg = command.args[arg_idx];

        // Handle set -- args... (set positional parameters)
        if (std.mem.eql(u8, arg, "--")) {
            if (ctx.hasShell()) {
                const shell_ref = try ctx.getShell();
                // Clear existing positional parameters
                var pi: usize = 0;
                while (pi < shell_ref.positional_params.len) : (pi += 1) {
                    if (shell_ref.positional_params[pi]) |param| {
                        shell_ref.allocator.free(param);
                        shell_ref.positional_params[pi] = null;
                    }
                }
                // Set new positional parameters from remaining args
                shell_ref.positional_params_count = 0;
                var new_idx: usize = 0;
                var rest_idx = arg_idx + 1;
                while (rest_idx < command.args.len and new_idx < shell_ref.positional_params.len) : (rest_idx += 1) {
                    shell_ref.positional_params[new_idx] = shell_ref.allocator.dupe(u8, command.args[rest_idx]) catch null;
                    new_idx += 1;
                }
                shell_ref.positional_params_count = new_idx;
            }
            return 0;
        }

        // Handle shell options (-e, -E, +e, +E, -exu, +exu, -o name, +o name, etc.)
        if (arg.len > 0 and (arg[0] == '-' or arg[0] == '+')) {
            const enable = arg[0] == '-';
            const option = arg[1..];

            if (ctx.hasShell()) {
                const shell_ref = try ctx.getShell();

                // Special case: -o / +o takes a separate argument or prints options
                if (std.mem.eql(u8, option, "o")) {
                    if (arg_idx + 1 < command.args.len) {
                        const opt_name = command.args[arg_idx + 1];
                        if (std.mem.eql(u8, opt_name, "errexit")) {
                            shell_ref.option_errexit = enable;
                        } else if (std.mem.eql(u8, opt_name, "errtrace")) {
                            shell_ref.option_errtrace = enable;
                        } else if (std.mem.eql(u8, opt_name, "xtrace")) {
                            shell_ref.option_xtrace = enable;
                        } else if (std.mem.eql(u8, opt_name, "nounset")) {
                            shell_ref.option_nounset = enable;
                        } else if (std.mem.eql(u8, opt_name, "pipefail")) {
                            shell_ref.option_pipefail = enable;
                        } else if (std.mem.eql(u8, opt_name, "noexec")) {
                            shell_ref.option_noexec = enable;
                        } else if (std.mem.eql(u8, opt_name, "verbose")) {
                            shell_ref.option_verbose = enable;
                        } else if (std.mem.eql(u8, opt_name, "noglob")) {
                            shell_ref.option_noglob = enable;
                        } else if (std.mem.eql(u8, opt_name, "noclobber")) {
                            shell_ref.option_noclobber = enable;
                        } else if (std.mem.eql(u8, opt_name, "restricted")) {
                            if (enable) {
                                shell_ref.option_restricted = true;
                            } else {
                                if (shell_ref.option_restricted) {
                                    try IO.eprint("den: set: cannot unset restricted mode\n", .{});
                                    return 1;
                                }
                            }
                        } else {
                            try IO.eprint("den: set: {s}: invalid option name\n", .{opt_name});
                            return 1;
                        }
                        arg_idx += 1;
                    } else {
                        try IO.print("Current option settings:\n", .{});
                        try IO.print("errexit        {s}\n", .{if (shell_ref.option_errexit) "on" else "off"});
                        try IO.print("errtrace       {s}\n", .{if (shell_ref.option_errtrace) "on" else "off"});
                        try IO.print("xtrace         {s}\n", .{if (shell_ref.option_xtrace) "on" else "off"});
                        try IO.print("nounset        {s}\n", .{if (shell_ref.option_nounset) "on" else "off"});
                        try IO.print("pipefail       {s}\n", .{if (shell_ref.option_pipefail) "on" else "off"});
                        try IO.print("noexec         {s}\n", .{if (shell_ref.option_noexec) "on" else "off"});
                        try IO.print("verbose        {s}\n", .{if (shell_ref.option_verbose) "on" else "off"});
                        try IO.print("noglob         {s}\n", .{if (shell_ref.option_noglob) "on" else "off"});
                        try IO.print("noclobber      {s}\n", .{if (shell_ref.option_noclobber) "on" else "off"});
                        try IO.print("restricted     {s}\n", .{if (shell_ref.option_restricted) "on" else "off"});
                    }
                } else {
                    // Iterate through each character in the option string to support
                    // combined flags like -exu (enables errexit, xtrace, nounset).
                    for (option) |ch| {
                        switch (ch) {
                            'e' => shell_ref.option_errexit = enable,
                            'E' => shell_ref.option_errtrace = enable,
                            'x' => shell_ref.option_xtrace = enable,
                            'u' => shell_ref.option_nounset = enable,
                            'n' => shell_ref.option_noexec = enable,
                            'v' => shell_ref.option_verbose = enable,
                            'f' => shell_ref.option_noglob = enable,
                            'C' => shell_ref.option_noclobber = enable,
                            'r' => {
                                if (enable) {
                                    shell_ref.option_restricted = true;
                                } else {
                                    // Restricted mode cannot be unset once enabled
                                    if (shell_ref.option_restricted) {
                                        try IO.eprint("den: set: cannot unset restricted mode\n", .{});
                                        return 1;
                                    }
                                }
                            },
                            else => {
                                try IO.eprint("den: set: unknown option: {s}\n", .{arg});
                                return 1;
                            },
                        }
                    }
                }
            } else {
                try IO.eprint("den: set: shell options not available in this context\n", .{});
                return 1;
            }
        } else if (std.mem.indexOf(u8, arg, "=")) |eq_pos| {
            const var_name = arg[0..eq_pos];
            const var_value = arg[eq_pos + 1 ..];
            // Restricted mode: block modifications to PATH, SHELL, ENV, BASH_ENV
            if (ctx.hasShell()) {
                const s = try ctx.getShell();
                if (s.option_restricted) {
                    if (std.mem.eql(u8, var_name, "PATH") or
                        std.mem.eql(u8, var_name, "SHELL") or
                        std.mem.eql(u8, var_name, "ENV") or
                        std.mem.eql(u8, var_name, "BASH_ENV"))
                    {
                        try IO.eprint("den: set: {s}: restricted: cannot modify in restricted mode\n", .{var_name});
                        return 1;
                    }
                }
            }
            try ctx.setEnv(var_name, var_value);
        } else {
            try IO.eprint("den: set: {s}: not a valid identifier\n", .{arg});
            return 1;
        }
        arg_idx += 1;
    }

    return 0;
}

pub fn unset(ctx: *BuiltinContext, command: *types.ParsedCommand) !i32 {
    if (command.args.len == 0) {
        try IO.eprint("den: unset: not enough arguments\n", .{});
        return 1;
    }

    var unset_functions = false;
    var unset_variables = true;
    var arg_start: usize = 0;

    // Parse flags
    for (command.args, 0..) |arg, i| {
        if (arg.len > 0 and arg[0] == '-') {
            if (std.mem.eql(u8, arg, "-f")) {
                unset_functions = true;
                unset_variables = false;
                arg_start = i + 1;
            } else if (std.mem.eql(u8, arg, "-v")) {
                unset_variables = true;
                unset_functions = false;
                arg_start = i + 1;
            } else if (std.mem.eql(u8, arg, "-fv") or std.mem.eql(u8, arg, "-vf")) {
                unset_variables = true;
                unset_functions = true;
                arg_start = i + 1;
            } else if (std.mem.eql(u8, arg, "--help")) {
                try IO.print("Usage: unset [-fv] name [...]\n", .{});
                try IO.print("Remove NAME from the shell environment.\n\n", .{});
                try IO.print("Options:\n", .{});
                try IO.print("  -f    treat each NAME as a shell function\n", .{});
                try IO.print("  -v    treat each NAME as a shell variable (default)\n", .{});
                return 0;
            } else if (std.mem.eql(u8, arg, "--")) {
                arg_start = i + 1;
                break;
            } else {
                try IO.eprint("den: unset: invalid option -- '{s}'\n", .{arg});
                return 1;
            }
        } else {
            break;
        }
    }

    if (arg_start >= command.args.len) {
        try IO.eprint("den: unset: not enough arguments\n", .{});
        return 1;
    }

    if (unset_variables) {
        // Restricted mode: block unsetting PATH, SHELL, ENV, BASH_ENV
        if (ctx.hasShell()) {
            const s = try ctx.getShell();
            if (s.option_restricted) {
                for (command.args[arg_start..]) |vn| {
                    if (std.mem.eql(u8, vn, "PATH") or
                        std.mem.eql(u8, vn, "SHELL") or
                        std.mem.eql(u8, vn, "ENV") or
                        std.mem.eql(u8, vn, "BASH_ENV"))
                    {
                        try IO.eprint("den: unset: {s}: restricted: cannot modify in restricted mode\n", .{vn});
                        return 1;
                    }
                }
            }
        }

        for (command.args[arg_start..]) |var_name| {
            // Check readonly attribute
            if (ctx.getVarAttributes(var_name)) |attrs| {
                if (attrs.readonly) {
                    try IO.eprint("den: unset: {s}: cannot unset: readonly variable\n", .{var_name});
                    return 1;
                }
            }
            // Check for array element syntax: arr[index]
            if (std.mem.indexOfScalar(u8, var_name, '[')) |bracket_pos| {
                if (bracket_pos > 0 and std.mem.indexOfScalar(u8, var_name[bracket_pos..], ']') != null) {
                    const arr_name = var_name[0..bracket_pos];
                    const close_pos = bracket_pos + (std.mem.indexOfScalar(u8, var_name[bracket_pos..], ']') orelse 0);
                    const index_str = var_name[bracket_pos + 1 .. close_pos];
                    if (ctx.hasShell()) {
                        const shell_ref = try ctx.getShell();
                        // Handle indexed array element unset (leaves a gap, like bash)
                        if (shell_ref.arrays.getPtr(arr_name)) |array_ptr| {
                            if (std.fmt.parseInt(usize, index_str, 10)) |index| {
                                array_ptr.removeIndex(shell_ref.allocator, index) catch {};
                            } else |_| {}
                        }
                        // Handle assoc array element unset
                        if (shell_ref.assoc_arrays.getPtr(arr_name)) |assoc| {
                            if (assoc.fetchRemove(index_str)) |kv| {
                                shell_ref.allocator.free(kv.key);
                                shell_ref.allocator.free(kv.value);
                            }
                        }
                    }
                    continue;
                }
            }
            ctx.unsetEnv(var_name);
            // Also remove from arrays and associative arrays hashmaps
            if (ctx.hasShell()) {
                const shell_ref = try ctx.getShell();
                // Remove indexed array
                if (shell_ref.arrays.fetchRemove(var_name)) |kv| {
                    kv.value.deinit(shell_ref.allocator);
                    shell_ref.allocator.free(kv.key);
                }
                // Remove associative array
                if (shell_ref.assoc_arrays.fetchRemove(var_name)) |kv| {
                    var assoc = kv.value;
                    var iter = assoc.iterator();
                    while (iter.next()) |entry| {
                        shell_ref.allocator.free(entry.key_ptr.*);
                        shell_ref.allocator.free(entry.value_ptr.*);
                    }
                    assoc.deinit();
                    shell_ref.allocator.free(kv.key);
                }
            }
        }
    }

    if (unset_functions) {
        if (ctx.hasShell()) {
            const shell_ref = try ctx.getShell();
            for (command.args[arg_start..]) |func_name| {
                shell_ref.function_manager.removeFunction(func_name);
            }
        }
    }

    return 0;
}

/// env command with VAR=value support
/// Usage: env [-i] [-u name] [name=value]... [command [args]...]
pub fn envCmd(ctx: *BuiltinContext, command: *types.ParsedCommand) !i32 {
    // No args - just print environment
    if (command.args.len == 0) {
        return try env(ctx);
    }

    // Parse flags and VAR=value assignments
    var ignore_env = false;
    var unset_vars: std.ArrayList([]const u8) = .empty;
    defer unset_vars.deinit(ctx.allocator);
    var env_overrides: std.ArrayList(struct { key: []const u8, value: []const u8 }) = .empty;
    defer env_overrides.deinit(ctx.allocator);

    var cmd_start: ?usize = null;
    var i: usize = 0;

    while (i < command.args.len) : (i += 1) {
        const arg = command.args[i];

        if (arg.len > 0 and arg[0] == '-') {
            // Parse flags
            if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--ignore-environment")) {
                ignore_env = true;
            } else if (std.mem.eql(u8, arg, "-u") or std.mem.eql(u8, arg, "--unset")) {
                // Next arg is the var name to unset
                if (i + 1 < command.args.len) {
                    i += 1;
                    try unset_vars.append(ctx.allocator, command.args[i]);
                } else {
                    try IO.eprint("den: env: option requires an argument -- 'u'\n", .{});
                    return 1;
                }
            } else if (std.mem.eql(u8, arg, "--")) {
                // End of options
                cmd_start = i + 1;
                break;
            } else if (std.mem.eql(u8, arg, "--help")) {
                try IO.print("Usage: env [-i] [-u name] [name=value]... [command [args]...]\n", .{});
                try IO.print("  -i, --ignore-environment  Start with empty environment\n", .{});
                try IO.print("  -u, --unset=NAME          Unset variable NAME\n", .{});
                return 0;
            } else {
                try IO.eprint("den: env: invalid option -- '{s}'\n", .{arg});
                return 1;
            }
        } else if (std.mem.indexOfScalar(u8, arg, '=')) |eq_pos| {
            // VAR=value assignment (but only if key is valid - starts with letter/underscore)
            if (eq_pos > 0 and (std.ascii.isAlphabetic(arg[0]) or arg[0] == '_')) {
                const key = arg[0..eq_pos];
                const value = arg[eq_pos + 1 ..];
                try env_overrides.append(ctx.allocator, .{ .key = key, .value = value });
            } else {
                // Looks like a command (e.g., "/usr/bin/foo=bar" or "=foo")
                cmd_start = i;
                break;
            }
        } else {
            // This is the command to execute
            cmd_start = i;
            break;
        }
    }

    // If no command specified, just print modified environment
    if (cmd_start == null) {
        if (ignore_env) {
            // Only print overrides
            for (env_overrides.items) |override| {
                try IO.print("{s}={s}\n", .{ override.key, override.value });
            }
        } else {
            // Print modified environment
            var iter = ctx.environment.iterator();
            while (iter.next()) |entry| {
                // Skip if unset
                var is_unset = false;
                for (unset_vars.items) |unset_var| {
                    if (std.mem.eql(u8, entry.key_ptr.*, unset_var)) {
                        is_unset = true;
                        break;
                    }
                }
                if (is_unset) continue;

                // Check if overridden
                var is_overridden = false;
                for (env_overrides.items) |override| {
                    if (std.mem.eql(u8, entry.key_ptr.*, override.key)) {
                        is_overridden = true;
                        break;
                    }
                }
                if (!is_overridden) {
                    try IO.print("{s}={s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
                }
            }
            // Print overrides
            for (env_overrides.items) |override| {
                try IO.print("{s}={s}\n", .{ override.key, override.value });
            }
        }
        return 0;
    }

    // Execute command with modified environment
    // Save original OS env values to restore later
    var saved_os_env = std.StringHashMap(?[]const u8).init(ctx.allocator);
    defer {
        // Free any allocated values
        var iter = saved_os_env.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.*) |v| {
                ctx.allocator.free(v);
            }
        }
        saved_os_env.deinit();
    }

    // Apply unsets to OS environment
    for (unset_vars.items) |unset_var| {
        // Save original OS env value
        const original = getenvFromSlice(unset_var);
        if (original) |orig| {
            const saved = try ctx.allocator.dupe(u8, orig);
            errdefer ctx.allocator.free(saved);
            try saved_os_env.put(unset_var, saved);
        } else {
            try saved_os_env.put(unset_var, null);
        }
        // Unset in OS environment
        if (builtin.os.tag != .windows) {
            const unset_var_z = try ctx.allocator.dupeSentinel(u8, unset_var, 0);
            defer ctx.allocator.free(unset_var_z);
            _ = libc_env.unsetenv(unset_var_z.ptr);
        }
    }

    // Apply overrides to OS environment
    for (env_overrides.items) |override| {
        // Save original OS env value
        if (!saved_os_env.contains(override.key)) {
            const original = getenvFromSlice(override.key);
            if (original) |orig| {
                const saved = try ctx.allocator.dupe(u8, orig);
                errdefer ctx.allocator.free(saved);
                try saved_os_env.put(override.key, saved);
            } else {
                try saved_os_env.put(override.key, null);
            }
        }
        // Set in OS environment
        if (builtin.os.tag != .windows) {
            const key_z = try ctx.allocator.dupeSentinel(u8, override.key, 0);
            defer ctx.allocator.free(key_z);
            const value_z = try ctx.allocator.dupeSentinel(u8, override.value, 0);
            defer ctx.allocator.free(value_z);
            _ = libc_env.setenv(key_z.ptr, value_z.ptr, 1);
        }
    }

    // Build new command from remaining args
    const start = cmd_start.?; // We know it's set if we got here

    // Reconstruct the full command string
    var cmd_buf: std.ArrayList(u8) = .empty;
    defer cmd_buf.deinit(ctx.allocator);

    for (command.args[start..]) |arg| {
        if (cmd_buf.items.len > 0) {
            try cmd_buf.append(ctx.allocator, ' ');
        }
        // Quote args with spaces
        if (std.mem.indexOfScalar(u8, arg, ' ') != null) {
            try cmd_buf.append(ctx.allocator, '"');
            try cmd_buf.appendSlice(ctx.allocator, arg);
            try cmd_buf.append(ctx.allocator, '"');
        } else {
            try cmd_buf.appendSlice(ctx.allocator, arg);
        }
    }

    // Execute the command using shell's executeCommand
    ctx.executeShellCommand(cmd_buf.items);
    const result = ctx.getShellExitCode();

    // Restore OS environment
    restoreOsEnv(ctx.allocator, &saved_os_env);

    return result;
}

// ============================================================================
// Tests
// ============================================================================

test "getenvFromSlice returns null for missing key" {
    // Use a key that's unlikely to be in the environment
    const result = getenvFromSlice("__DEN_TEST_NONEXISTENT_VAR_XYZ__");
    try std.testing.expect(result == null);
}

test "getenvFromSlice returns null for oversized key" {
    // Key longer than 512 bytes should return null
    const long_key_buf: [513]u8 = @splat('A');
    const long_key: []const u8 = &long_key_buf;
    const result = getenvFromSlice(long_key);
    try std.testing.expect(result == null);
}

test "getenvFromSlice finds PATH" {
    // PATH should exist in any normal environment
    if (comptime builtin.os.tag == .windows) return;
    const result = getenvFromSlice("PATH");
    try std.testing.expect(result != null);
    try std.testing.expect(result.?.len > 0);
}

test "env builtin returns zero" {
    // Create a minimal context to test env()
    var environment = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer environment.deinit();

    var ctx = BuiltinContext.init(std.testing.allocator, &environment, null);
    const result = try env(&ctx);
    try std.testing.expectEqual(@as(i32, 0), result);
}

fn restoreOsEnv(allocator: std.mem.Allocator, saved_os_env: *std.StringHashMap(?[]const u8)) void {
    if (builtin.os.tag == .windows) return;
    var iter = saved_os_env.iterator();
    while (iter.next()) |entry| {
        const key = entry.key_ptr.*;
        const key_z = allocator.dupeSentinel(u8, key, 0) catch continue;
        defer allocator.free(key_z);

        if (entry.value_ptr.*) |original_value| {
            // Restore original value
            const value_z = allocator.dupeSentinel(u8, original_value, 0) catch continue;
            defer allocator.free(value_z);
            _ = libc_env.setenv(key_z.ptr, value_z.ptr, 1);
        } else {
            // Was not set originally, unset it
            _ = libc_env.unsetenv(key_z.ptr);
        }
    }
}
