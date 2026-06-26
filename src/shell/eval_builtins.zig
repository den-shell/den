//! Eval-related Builtins Implementation
//!
//! This module implements command evaluation builtins:
//! - read: read line from stdin into variable
//! - command: execute command bypassing functions
//! - eval: execute arguments as shell command
//! - shift: shift positional parameters
//! - builtin: execute builtin command

const std = @import("std");
const builtin = @import("builtin");
const IO = @import("../utils/io.zig").IO;
const types = @import("../types/mod.zig");
const parser_mod = @import("../parser/mod.zig");
const executor_mod = @import("../executor/mod.zig");

// Forward declaration for Shell type
const Shell = @import("../shell.zig").Shell;

// Format parse error for display
fn formatParseError(err: anyerror) []const u8 {
    return switch (err) {
        error.OutOfMemory => "out of memory",
        error.UnexpectedToken => "unexpected token",
        error.UnterminatedString => "unterminated string",
        error.EmptyCommand => "empty command",
        error.InvalidSyntax => "invalid syntax",
        error.MissingOperand => "missing operand",
        error.InvalidRedirection => "invalid redirection",
        error.UnmatchedParenthesis => "unmatched parenthesis",
        else => "parse error",
    };
}

/// Builtin: read - read line from stdin into variable(s)
pub fn builtinRead(self: *Shell, cmd: *types.ParsedCommand) !void {
    // Parse flags: -r (raw), -p (prompt), -a (array), -n (nchars), -s (silent), -d (delim)
    var var_start: usize = 0;
    var prompt: ?[]const u8 = null;
    var array_mode = false;
    var raw_mode = false;
    var nchars: ?usize = null;
    var delimiter: ?u8 = null;

    while (var_start < cmd.args.len) {
        const arg = cmd.args[var_start];
        if (arg.len > 1 and arg[0] == '-') {
            var_start += 1;
            var ci: usize = 1;
            while (ci < arg.len) : (ci += 1) {
                switch (arg[ci]) {
                    'r' => raw_mode = true,
                    's' => {},
                    'a' => array_mode = true,
                    'p' => {
                        // -p can have inline value (-pPrompt) or next arg
                        if (ci + 1 < arg.len) {
                            prompt = arg[ci + 1 ..];
                            ci = arg.len; // consumed rest
                        } else if (var_start < cmd.args.len) {
                            prompt = cmd.args[var_start];
                            var_start += 1;
                        }
                    },
                    'n' => {
                        // -n can have inline value (-n3) or next arg. Report a
                        // clear error on invalid numbers rather than silently
                        // dropping to null.
                        if (ci + 1 < arg.len) {
                            const n_str = arg[ci + 1 ..];
                            nchars = std.fmt.parseInt(usize, n_str, 10) catch {
                                try IO.eprint("den: read: {s}: invalid number for -n\n", .{n_str});
                                self.last_exit_code = 1;
                                return;
                            };
                            ci = arg.len;
                        } else if (var_start < cmd.args.len) {
                            const n_str = cmd.args[var_start];
                            nchars = std.fmt.parseInt(usize, n_str, 10) catch {
                                try IO.eprint("den: read: {s}: invalid number for -n\n", .{n_str});
                                self.last_exit_code = 1;
                                return;
                            };
                            var_start += 1;
                        }
                    },
                    'd' => {
                        // -d can have inline value (-d|) or next arg
                        if (ci + 1 < arg.len) {
                            delimiter = arg[ci + 1];
                            ci = arg.len;
                        } else if (var_start < cmd.args.len) {
                            if (cmd.args[var_start].len > 0) {
                                delimiter = cmd.args[var_start][0];
                            } else {
                                delimiter = 0; // empty string means NUL delimiter (bash behavior)
                            }
                            var_start += 1;
                        }
                    },
                    else => {},
                }
            }
        } else {
            break;
        }
    }

    if (var_start >= cmd.args.len) {
        // No variable names - use REPLY
        var_start = cmd.args.len; // will be handled below
    }

    const var_names = cmd.args[var_start..];

    // Validate variable names are valid identifiers
    for (var_names) |vname| {
        if (vname.len == 0) continue;
        if (vname[0] != '_' and !std.ascii.isAlphabetic(vname[0])) {
            try IO.eprint("den: read: `{s}': not a valid identifier\n", .{vname});
            self.last_exit_code = 1;
            return;
        }
        for (vname[1..]) |c| {
            if (c != '_' and !std.ascii.isAlphanumeric(c)) {
                try IO.eprint("den: read: `{s}': not a valid identifier\n", .{vname});
                self.last_exit_code = 1;
                return;
            }
        }
    }

    // Print prompt to stderr if -p was specified (bash behavior)
    if (prompt) |p| {
        try IO.eprint("{s}", .{p});
    }

    // Read from stdin: handle -n (nchars) and -d (delimiter)
    const line = if (nchars) |n| blk: {
        // Read exactly N characters
        const buf = try self.allocator.alloc(u8, n);
        var count: usize = 0;
        while (count < n) {
            var byte: [1]u8 = undefined;
            const bytes_read: isize = if (comptime builtin.os.tag == .windows) win_blk: {
                const handle = std.os.windows.kernel32.GetStdHandle(std.os.windows.STD_INPUT_HANDLE) orelse break :win_blk @as(isize, -1);
                var br: u32 = 0;
                const ok = std.os.windows.kernel32.ReadFile(handle, &byte, 1, &br, null);
                break :win_blk if (ok != 0) @as(isize, @intCast(br)) else @as(isize, -1);
            } else std.c.read(std.posix.STDIN_FILENO, &byte, 1);
            if (bytes_read <= 0) break;
            buf[count] = byte[0];
            count += 1;
        }
        if (count == 0) {
            self.allocator.free(buf);
            break :blk @as(?[]u8, null);
        }
        defer self.allocator.free(buf);
        break :blk @as(?[]u8, try self.allocator.dupe(u8, buf[0..count]));
    } else if (delimiter) |d| blk: {
        // Read until delimiter character (dynamic buffer)
        var dyn_buf: std.ArrayList(u8) = .empty;
        defer dyn_buf.deinit(self.allocator);
        while (true) {
            var byte: [1]u8 = undefined;
            const bytes_read: isize = if (comptime builtin.os.tag == .windows) win_blk: {
                const handle = std.os.windows.kernel32.GetStdHandle(std.os.windows.STD_INPUT_HANDLE) orelse break :win_blk @as(isize, -1);
                var br: u32 = 0;
                const ok = std.os.windows.kernel32.ReadFile(handle, &byte, 1, &br, null);
                break :win_blk if (ok != 0) @as(isize, @intCast(br)) else @as(isize, -1);
            } else std.c.read(std.posix.STDIN_FILENO, &byte, 1);
            if (bytes_read <= 0) break;
            if (byte[0] == d) break;
            dyn_buf.append(self.allocator, byte[0]) catch break;
        }
        if (dyn_buf.items.len == 0) {
            break :blk @as(?[]u8, null);
        }
        break :blk @as(?[]u8, try self.allocator.dupe(u8, dyn_buf.items));
    } else try IO.readLine(self.allocator);
    if (line) |raw_value| {
        defer self.allocator.free(raw_value);
        self.last_exit_code = 0;

        // Process backslash escapes unless -r (raw mode) is set
        var proc_buf: std.ArrayList(u8) = .empty;
        defer proc_buf.deinit(self.allocator);
        const value = if (!raw_mode) blk: {
            var j: usize = 0;
            while (j < raw_value.len) {
                if (raw_value[j] == '\\' and j + 1 < raw_value.len) {
                    j += 1; // Skip backslash, take next char literally
                    proc_buf.append(self.allocator, raw_value[j]) catch break;
                } else {
                    proc_buf.append(self.allocator, raw_value[j]) catch break;
                }
                j += 1;
            }
            break :blk proc_buf.items;
        } else raw_value;

        // Get IFS (default: space, tab, newline)
        const ifs = self.environment.get("IFS") orelse " \t\n";

        // Handle -a flag: read into array
        if (array_mode) {
            const arr_name = if (var_names.len >= 1) var_names[0] else "REPLY";
            // Split by IFS into words (dynamic list)
            var words_list: std.ArrayList([]const u8) = .empty;
            defer words_list.deinit(self.allocator);
            var pos: usize = 0;
            while (pos < value.len) {
                // Skip IFS chars
                while (pos < value.len) {
                    var is_delim = false;
                    for (ifs) |ic| {
                        if (value[pos] == ic) {
                            is_delim = true;
                            break;
                        }
                    }
                    if (!is_delim) break;
                    pos += 1;
                }
                if (pos >= value.len) break;
                const wstart = pos;
                while (pos < value.len) {
                    var is_delim = false;
                    for (ifs) |ic| {
                        if (value[pos] == ic) {
                            is_delim = true;
                            break;
                        }
                    }
                    if (is_delim) break;
                    pos += 1;
                }
                words_list.append(self.allocator, value[wstart..pos]) catch break;
            }
            // Create the array
            const word_count = words_list.items.len;
            const arr = try self.allocator.alloc([]const u8, word_count);
            for (0..word_count) |i| {
                arr[i] = try self.allocator.dupe(u8, words_list.items[i]);
            }
            // Free old array if exists
            if (self.arrays.fetchRemove(arr_name)) |old| {
                old.value.deinit(self.allocator);
                self.allocator.free(old.key);
            }
            const key = try self.allocator.dupe(u8, arr_name);
            try self.arrays.put(key, try types.IndexedArray.fromOwnedDense(self.allocator, arr));
            return;
        }

        if (var_names.len <= 1) {
            // Single variable (or REPLY): assign entire line, stripped of leading/trailing IFS whitespace
            const target = if (var_names.len == 1) var_names[0] else "REPLY";
            // Strip leading IFS whitespace characters
            var strip_start: usize = 0;
            while (strip_start < value.len) {
                var is_ifs_ws = false;
                for (ifs) |ic| {
                    if (value[strip_start] == ic and (ic == ' ' or ic == '\t' or ic == '\n')) {
                        is_ifs_ws = true;
                        break;
                    }
                }
                if (!is_ifs_ws) break;
                strip_start += 1;
            }
            // Strip trailing IFS whitespace characters
            var strip_end: usize = value.len;
            while (strip_end > strip_start) {
                var is_ifs_ws = false;
                for (ifs) |ic| {
                    if (value[strip_end - 1] == ic and (ic == ' ' or ic == '\t' or ic == '\n')) {
                        is_ifs_ws = true;
                        break;
                    }
                }
                if (!is_ifs_ws) break;
                strip_end -= 1;
            }
            const value_copy = try self.allocator.dupe(u8, value[strip_start..strip_end]);
            const gop = try self.environment.getOrPut(target);
            if (gop.found_existing) {
                self.allocator.free(gop.value_ptr.*);
                gop.value_ptr.* = value_copy;
            } else {
                gop.key_ptr.* = try self.allocator.dupe(u8, target);
                gop.value_ptr.* = value_copy;
            }
        } else {
            // Multiple variables: split by IFS
            var var_idx: usize = 0;
            var pos: usize = 0;

            // Check if IFS contains whitespace chars
            var has_ifs_ws = false;
            for (ifs) |ic| {
                if (ic == ' ' or ic == '\t' or ic == '\n') {
                    has_ifs_ws = true;
                    break;
                }
            }

            // Skip leading IFS whitespace
            if (has_ifs_ws) {
                while (pos < value.len) {
                    var is_ws = false;
                    for (ifs) |ic| {
                        if (value[pos] == ic and (ic == ' ' or ic == '\t' or ic == '\n')) {
                            is_ws = true;
                            break;
                        }
                    }
                    if (!is_ws) break;
                    pos += 1;
                }
            }

            while (var_idx < var_names.len) : (var_idx += 1) {
                const varname = var_names[var_idx];
                var word_value: []const u8 = "";

                if (var_idx == var_names.len - 1) {
                    // Last variable gets remaining text, with trailing IFS whitespace stripped
                    if (pos < value.len) {
                        var end_pos: usize = value.len;
                        while (end_pos > pos) {
                            var is_ifs_ws = false;
                            for (ifs) |ic| {
                                if (value[end_pos - 1] == ic and (ic == ' ' or ic == '\t' or ic == '\n')) {
                                    is_ifs_ws = true;
                                    break;
                                }
                            }
                            if (!is_ifs_ws) break;
                            end_pos -= 1;
                        }
                        word_value = value[pos..end_pos];
                    }
                } else {
                    // Find next word by splitting on IFS
                    const word_start = pos;
                    while (pos < value.len) {
                        var is_delim = false;
                        for (ifs) |ic| {
                            if (value[pos] == ic) {
                                is_delim = true;
                                break;
                            }
                        }
                        if (is_delim) break;
                        pos += 1;
                    }
                    if (pos > word_start) {
                        word_value = value[word_start..pos];
                    }
                    // Skip delimiter(s)
                    if (pos < value.len) {
                        // Skip one non-whitespace IFS delimiter
                        if (!has_ifs_ws or (value[pos] != ' ' and value[pos] != '\t' and value[pos] != '\n')) {
                            pos += 1;
                        }
                        // Skip any IFS whitespace
                        while (pos < value.len) {
                            var is_ws = false;
                            for (ifs) |ic| {
                                if (value[pos] == ic and (ic == ' ' or ic == '\t' or ic == '\n')) {
                                    is_ws = true;
                                    break;
                                }
                            }
                            if (!is_ws) break;
                            pos += 1;
                        }
                    }
                }

                const val_copy = try self.allocator.dupe(u8, word_value);
                const gop = try self.environment.getOrPut(varname);
                if (gop.found_existing) {
                    self.allocator.free(gop.value_ptr.*);
                    gop.value_ptr.* = val_copy;
                } else {
                    gop.key_ptr.* = try self.allocator.dupe(u8, varname);
                    gop.value_ptr.* = val_copy;
                }
            }
        }
    } else {
        // EOF: return 1 (like bash)
        self.last_exit_code = 1;
    }
}

/// Builtin: command - execute command bypassing functions
pub fn builtinCommand(self: *Shell, cmd: *types.ParsedCommand) !void {
    if (cmd.args.len == 0) {
        try IO.eprint("den: command: missing command argument\n", .{});
        self.last_exit_code = 1;
        return;
    }

    // Handle -v, -V, -p flags
    var verbose = false;
    var short_output = false;
    var start_idx: usize = 0;

    for (cmd.args, 0..) |arg, i| {
        if (arg.len > 0 and arg[0] == '-') {
            for (arg[1..]) |c| {
                if (c == 'V') {
                    verbose = true;
                } else if (c == 'v') {
                    short_output = true;
                } else if (c == 'p') {
                    // use default PATH - ignored for -v/-V
                } else {
                    try IO.eprint("den: command: invalid option: -{c}\n", .{c});
                    self.last_exit_code = 1;
                    return;
                }
            }
            start_idx = i + 1;
        } else {
            break;
        }
    }

    if (start_idx >= cmd.args.len) {
        if (verbose or short_output) {
            // No command name after flags
            self.last_exit_code = 1;
            return;
        }
        try IO.eprint("den: command: missing command argument\n", .{});
        self.last_exit_code = 1;
        return;
    }

    const cmd_name = cmd.args[start_idx];

    if (verbose or short_output) {
        // command -v / command -V: locate command

        // If the command contains a slash, it's a direct path — check if executable
        if (std.mem.indexOfScalar(u8, cmd_name, '/') != null) {
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            if (cmd_name.len < path_buf.len) {
                @memcpy(path_buf[0..cmd_name.len], cmd_name);
                path_buf[cmd_name.len] = 0;
                const c_path: [*:0]const u8 = path_buf[0..cmd_name.len :0];
                if (comptime builtin.os.tag != .windows) {
                    if (std.c.access(c_path, std.posix.X_OK) == 0) {
                        if (verbose) {
                            try IO.print("{s} is {s}\n", .{ cmd_name, cmd_name });
                        } else {
                            try IO.print("{s}\n", .{cmd_name});
                        }
                        self.last_exit_code = 0;
                        return;
                    }
                }
            }
            self.last_exit_code = 1;
            return;
        }

        const builtins = [_][]const u8{
            "cd",      "echo",     "exit",   "export",  "set",     "unset",
            "alias",   "unalias",  "source", ".",       "eval",    "exec",
            "command", "builtin",  "type",   "which",   "test",    "[",
            "[[",      "true",     "false",  "read",    "printf",  "pwd",
            "pushd",   "popd",     "dirs",   "history", "jobs",    "fg",
            "bg",      "kill",     "wait",   "trap",    "shift",   "return",
            "break",   "continue", "local",  "declare", "typeset", "readonly",
            "let",     "hash",     "umask",  "ulimit",  "getopts", ":",
        };
        for (builtins) |b| {
            if (std.mem.eql(u8, cmd_name, b)) {
                if (verbose) {
                    try IO.print("{s} is a shell builtin\n", .{cmd_name});
                } else {
                    try IO.print("{s}\n", .{cmd_name});
                }
                self.last_exit_code = 0;
                return;
            }
        }

        // Check functions
        if (self.function_manager.hasFunction(cmd_name)) {
            if (verbose) {
                try IO.print("{s} is a function\n", .{cmd_name});
            } else {
                try IO.print("{s}\n", .{cmd_name});
            }
            self.last_exit_code = 0;
            return;
        }

        // Check aliases
        if (self.aliases.contains(cmd_name)) {
            if (self.aliases.get(cmd_name)) |val| {
                if (verbose) {
                    try IO.print("{s} is aliased to `{s}'\n", .{ cmd_name, val });
                } else {
                    try IO.print("alias {s}='{s}'\n", .{ cmd_name, val });
                }
            }
            self.last_exit_code = 0;
            return;
        }

        // Search PATH
        if (self.environment.get("PATH")) |path_val| {
            const eval_path_sep = if (comptime builtin.os.tag == .windows) ';' else ':';
            const eval_dir_sep = if (comptime builtin.os.tag == .windows) "\\" else "/";
            var iter = std.mem.splitScalar(u8, path_val, eval_path_sep);
            while (iter.next()) |dir| {
                if (dir.len == 0) continue;
                const full_path = std.fmt.allocPrint(self.allocator, "{s}" ++ eval_dir_sep ++ "{s}", .{ dir, cmd_name }) catch continue;
                defer self.allocator.free(full_path);
                if (comptime builtin.os.tag == .windows) {
                    // On Windows, check if file exists (no X_OK equivalent)
                    if (std.Io.Dir.cwd().access(std.Options.debug_io, full_path, .{})) {
                        if (verbose) {
                            try IO.print("{s} is {s}\n", .{ cmd_name, full_path });
                        } else {
                            try IO.print("{s}\n", .{full_path});
                        }
                        self.last_exit_code = 0;
                        return;
                    } else |_| {}
                } else {
                    // Check if file exists and is executable
                    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
                    @memcpy(path_buf[0..full_path.len], full_path);
                    path_buf[full_path.len] = 0;
                    const c_path: [*:0]const u8 = path_buf[0..full_path.len :0];
                    if (std.c.access(c_path, std.posix.X_OK) == 0) {
                        if (verbose) {
                            try IO.print("{s} is {s}\n", .{ cmd_name, full_path });
                        } else {
                            try IO.print("{s}\n", .{full_path});
                        }
                        self.last_exit_code = 0;
                        return;
                    }
                }
            }
        }

        // Not found
        if (verbose) {
            try IO.eprint("den: command not found: {s}\n", .{cmd_name});
        }
        self.last_exit_code = 1;
        return;
    }

    // No flags: execute as a single-command chain (bypass functions/aliases)
    const single_cmd = types.ParsedCommand{
        .name = cmd_name,
        .args = if (start_idx + 1 < cmd.args.len) cmd.args[start_idx + 1 ..] else &[_][]const u8{},
        .redirections = &[_]types.Redirection{},
        .type = .external,
    };

    const cmds = [_]types.ParsedCommand{single_cmd};
    const ops: []types.Operator = &[_]types.Operator{};

    var chain = types.CommandChain{
        .commands = @constCast(&cmds),
        .operators = ops,
    };

    var executor = executor_mod.Executor.init(self.allocator, &self.environment);
    const exit_code = executor.executeChain(&chain) catch |err| {
        try IO.eprint("den: command: {}\n", .{err});
        self.last_exit_code = 127;
        return;
    };

    self.last_exit_code = exit_code;
}

/// Builtin: eval - execute arguments as shell command
pub fn builtinEval(self: *Shell, cmd: *types.ParsedCommand) !void {
    if (cmd.args.len == 0) {
        self.last_exit_code = 0;
        return;
    }

    // Join all arguments into a single command string using dynamic allocation
    var eval_str: std.ArrayList(u8) = .empty;
    defer eval_str.deinit(self.allocator);

    for (cmd.args, 0..) |arg, i| {
        eval_str.appendSlice(self.allocator, arg) catch |err| {
            try IO.eprint("den: eval: allocation error: {}\n", .{err});
            self.last_exit_code = 1;
            return;
        };
        if (i < cmd.args.len - 1) {
            eval_str.append(self.allocator, ' ') catch |err| {
                try IO.eprint("den: eval: allocation error: {}\n", .{err});
                self.last_exit_code = 1;
                return;
            };
        }
    }

    const command_str = eval_str.items;

    // Execute as if typed at prompt
    // Tokenize
    var tokenizer = parser_mod.Tokenizer.init(self.allocator, command_str);
    const tokens = tokenizer.tokenize() catch |err| {
        try IO.eprint("den: eval: parse error: {}\n", .{err});
        self.last_exit_code = 1;
        return;
    };
    defer self.allocator.free(tokens);

    if (tokens.len == 0) {
        self.last_exit_code = 0;
        return;
    }

    // Parse
    var parser = parser_mod.Parser.init(self.allocator, tokens);
    var chain = parser.parse() catch |err| {
        try IO.eprint("den: eval: {s}\n", .{formatParseError(err)});
        self.last_exit_code = 2;
        return;
    };
    defer chain.deinit(self.allocator);

    // Expand variables and aliases
    try self.expandCommandChain(&chain);
    try self.expandAliases(&chain);

    // Execute - use initWithShell so variable assignments persist to the shell
    var executor = executor_mod.Executor.initWithShell(self.allocator, &self.environment, self);
    const exit_code = executor.executeChain(&chain) catch |err| {
        try IO.eprint("den: eval: execution error: {}\n", .{err});
        self.last_exit_code = 1;
        return;
    };

    self.last_exit_code = exit_code;
}

/// Builtin: shift - shift positional parameters
pub fn builtinShift(self: *Shell, cmd: *types.ParsedCommand) !void {
    // Parse shift count (default 1)
    const n: usize = if (cmd.args.len > 0)
        std.fmt.parseInt(usize, cmd.args[0], 10) catch 1
    else
        1;

    // If inside a function, shift the function frame's positional params
    if (self.function_manager.currentFrame()) |frame| {
        if (n > frame.positional_params_count) {
            try IO.eprint("den: shift: shift count too large\n", .{});
            self.last_exit_code = 1;
            return;
        }

        // Free first n params
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (frame.positional_params[i]) |param| {
                self.allocator.free(param);
                frame.positional_params[i] = null;
            }
        }

        // Move remaining parameters down
        var dest: usize = 0;
        var src: usize = n;
        while (src < frame.positional_params.len) : (src += 1) {
            frame.positional_params[dest] = frame.positional_params[src];
            if (dest != src) {
                frame.positional_params[src] = null;
            }
            dest += 1;
        }

        frame.positional_params_count -= n;
        self.last_exit_code = 0;
        return;
    }

    // Not in a function - shift shell's positional params
    if (n > self.positional_params_count) {
        try IO.eprint("den: shift: shift count too large\n", .{});
        self.last_exit_code = 1;
        return;
    }

    // Shift parameters by freeing first n and moving rest
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (self.positional_params[i]) |param| {
            self.allocator.free(param);
            self.positional_params[i] = null;
        }
    }

    // Move remaining parameters down
    var dest: usize = 0;
    var src: usize = n;
    while (src < self.positional_params.len) : (src += 1) {
        self.positional_params[dest] = self.positional_params[src];
        if (dest != src) {
            self.positional_params[src] = null;
        }
        dest += 1;
    }

    self.positional_params_count -= n;
    self.last_exit_code = 0;
}

/// Builtin: builtin - execute builtin command
pub fn builtinBuiltin(self: *Shell, cmd: *types.ParsedCommand) !void {
    if (cmd.args.len == 0) {
        try IO.eprint("den: builtin: usage: builtin [shell-builtin [arg ...]]\n", .{});
        self.last_exit_code = 1;
        return;
    }

    // Execute the specified builtin, bypassing any functions with the same name
    const builtin_name = cmd.args[0];
    const new_cmd = types.ParsedCommand{
        .name = builtin_name,
        .args = if (cmd.args.len > 1) cmd.args[1..] else &[_][]const u8{},
        .redirections = &[_]types.Redirection{},
    };

    // Create a simple chain with just this command
    const cmds = [_]types.ParsedCommand{new_cmd};
    const ops = [_]types.Operator{};
    var chain = types.CommandChain{
        .commands = @constCast(&cmds),
        .operators = @constCast(&ops),
    };

    // Execute using executor (builtins will be dispatched there)
    var executor = executor_mod.Executor.init(self.allocator, &self.environment);
    const exit_code = try executor.executeChain(&chain);
    self.last_exit_code = exit_code;
}
