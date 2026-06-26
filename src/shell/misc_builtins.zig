//! Miscellaneous Builtins Implementation
//!
//! This module implements various shell builtins:
//! - source: execute commands from a file
//! - mapfile: read lines from stdin into array
//! - time: time command execution
//! - hash: manage named directories

const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat");
const IO = @import("../utils/io.zig").IO;
const types = @import("../types/mod.zig");
const parser_mod = @import("../parser/mod.zig");
const executor_mod = @import("../executor/mod.zig");

// Forward declaration for Shell type
const Shell = @import("../shell.zig").Shell;

fn getenv(key: [*:0]const u8) ?[]const u8 {
    const value = std.c.getenv(key) orelse return null;
    return std.mem.span(@as([*:0]const u8, @ptrCast(value)));
}

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

/// Builtin: source - execute commands from file
pub fn builtinSource(self: *Shell, cmd: *types.ParsedCommand) !void {
    if (cmd.args.len == 0) {
        try IO.eprint("den: source: usage: source filename\n", .{});
        self.last_exit_code = 1;
        return;
    }

    const filename = cmd.args[0];

    // Restricted mode: source/. with paths containing '/' is not allowed
    if (self.option_restricted) {
        if (std.mem.indexOfScalar(u8, filename, '/') != null) {
            try IO.eprint("den: source: restricted: cannot specify path with '/'\n", .{});
            self.last_exit_code = 1;
            return;
        }
    }

    // Read file contents
    const file = std.Io.Dir.cwd().openFile(std.Options.debug_io, filename, .{}) catch |err| {
        try IO.eprint("den: source: {s}: {}\n", .{ filename, err });
        self.last_exit_code = 1;
        return;
    };
    defer file.close(std.Options.debug_io);

    const max_size = 1024 * 1024; // 1MB max
    const file_size = (file.stat(std.Options.debug_io) catch |err| {
        try IO.eprint("den: source: {s}: {}\n", .{ filename, err });
        self.last_exit_code = 1;
        return;
    }).size;
    const read_size: usize = @min(file_size, max_size);
    const buffer = self.allocator.alloc(u8, read_size) catch |err| {
        try IO.eprint("den: source: {s}: {}\n", .{ filename, err });
        self.last_exit_code = 1;
        return;
    };
    defer self.allocator.free(buffer);
    var total_read: usize = 0;
    while (total_read < read_size) {
        const bytes_read = file.readStreaming(std.Options.debug_io, &.{buffer[total_read..]}) catch |err| {
            try IO.eprint("den: source: {s}: {}\n", .{ filename, err });
            self.last_exit_code = 1;
            return;
        };
        if (bytes_read == 0) break;
        total_read += bytes_read;
    }
    const content = buffer[0..total_read];

    // Save current positional parameters if source was called with extra arguments
    var saved_params: [64]?[]const u8 = undefined;
    var saved_count: usize = 0;
    const has_extra_args = cmd.args.len > 1;

    if (has_extra_args) {
        saved_count = self.positional_params_count;
        for (0..self.positional_params.len) |i| {
            saved_params[i] = self.positional_params[i];
        }

        // Set new positional parameters from source arguments (skip filename)
        for (0..self.positional_params.len) |i| {
            self.positional_params[i] = null;
        }
        self.positional_params_count = cmd.args.len - 1;
        for (cmd.args[1..], 0..) |arg, i| {
            if (i >= self.positional_params.len) break;
            self.positional_params[i] = self.allocator.dupe(u8, arg) catch null;
        }
    }
    defer {
        if (has_extra_args) {
            // Free temporary positional params
            for (0..self.positional_params.len) |i| {
                if (self.positional_params[i]) |p| {
                    self.allocator.free(p);
                }
            }
            // Restore saved positional parameters
            for (0..self.positional_params.len) |i| {
                self.positional_params[i] = saved_params[i];
            }
            self.positional_params_count = saved_count;
        }
    }

    // Execute file content using multi-line script processing.
    // Split on newlines and use ControlFlowParser for if/while/for/case/functions,
    // matching the same approach used by the -c flag handler.
    if (content.len > 0) {
        const control_flow = @import("../scripting/control_flow.zig");
        const functions = @import("../scripting/functions.zig");

        // Split content into lines (quote-aware)
        var lines_buffer: [10000][]const u8 = undefined;
        var lines_count: usize = 0;
        {
            var line_start: usize = 0;
            var in_sq = false;
            var in_dq = false;
            var escaped = false;
            // A '#' comment runs to end of line; quote characters inside it (e.g.
            // an apostrophe in "Den's") must NOT toggle quote state, otherwise the
            // following lines get swallowed as one giant quoted "line".
            var in_comment = false;
            var ci: usize = 0;
            while (ci < content.len) : (ci += 1) {
                if (escaped) {
                    // An escaped newline is a line continuation: don't split here.
                    escaped = false;
                    continue;
                }
                const ch = content[ci];
                if (ch == '\\' and !in_sq and !in_comment) {
                    escaped = true;
                    continue;
                }
                if (ch == '\n') {
                    in_comment = false;
                    if (!in_sq and !in_dq) {
                        if (lines_count >= lines_buffer.len) break;
                        lines_buffer[lines_count] = content[line_start..ci];
                        lines_count += 1;
                        line_start = ci + 1;
                    }
                    continue;
                }
                if (in_comment) continue;
                if (ch == '\'' and !in_dq) {
                    in_sq = !in_sq;
                } else if (ch == '"' and !in_sq) {
                    in_dq = !in_dq;
                } else if (ch == '#' and !in_sq and !in_dq) {
                    // '#' starts a comment only at the start of a word (start of
                    // line or preceded by whitespace), matching POSIX.
                    const prev_is_ws = ci == line_start or content[ci - 1] == ' ' or content[ci - 1] == '\t';
                    if (prev_is_ws) in_comment = true;
                }
            }
            if (line_start <= content.len and lines_count < lines_buffer.len) {
                lines_buffer[lines_count] = content[line_start..content.len];
                lines_count += 1;
            }
        }
        const lines = lines_buffer[0..lines_count];

        var line_num: usize = 0;
        var cf_parser = control_flow.ControlFlowParser.init(self.allocator);
        var cf_executor = control_flow.ControlFlowExecutor.init(self);
        var func_parser = functions.FunctionParser.init(self.allocator);

        // Use @ptrCast to break circular error set inference
        const cmd_fn = @as(*const fn (*Shell, []const u8) anyerror!void, @ptrCast(&Shell.executeCommand));

        while (line_num < lines.len) : (line_num += 1) {
            const trimmed = std.mem.trim(u8, lines[line_num], &std.ascii.whitespace);
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            // Check function definitions
            const is_func_kw = std.mem.startsWith(u8, trimmed, "function ");
            var is_paren_syntax = false;
            if (std.mem.indexOf(u8, trimmed, "()")) |_| {
                if (std.mem.indexOf(u8, trimmed, "{") != null) {
                    is_paren_syntax = true;
                } else if (line_num + 1 < lines.len) {
                    const next_t = std.mem.trim(u8, lines[line_num + 1], &std.ascii.whitespace);
                    if (std.mem.startsWith(u8, next_t, "{")) is_paren_syntax = true;
                }
            }
            if (is_func_kw or is_paren_syntax) {
                // Check if this is a single-line function (both { and } on same line)
                // If so, let the shell's own function parser handle it via cmd_fn
                const has_close_brace = std.mem.indexOf(u8, trimmed, "}") != null;
                if (!has_close_brace) {
                    if (func_parser.parseFunction(lines, line_num)) |result_val| {
                        const result = result_val;
                        defer {
                            self.allocator.free(result.name);
                            for (result.body) |line| self.allocator.free(line);
                            self.allocator.free(result.body);
                        }
                        self.function_manager.defineFunction(result.name, result.body, false) catch break;
                        line_num = result.end;
                        continue;
                    } else |_| {
                        // Parse failure: fall through to cmd_fn
                    }
                }
                // Single-line function or parse failure: fall through to cmd_fn
            }

            // Control flow constructs
            if (std.mem.startsWith(u8, trimmed, "if ")) {
                var result = cf_parser.parseIf(lines, line_num) catch break;
                defer result.stmt.deinit();
                self.last_exit_code = cf_executor.executeIf(&result.stmt) catch 1;
                line_num = result.end;
                continue;
            }
            if (std.mem.startsWith(u8, trimmed, "while ")) {
                var result = cf_parser.parseWhile(lines, line_num, false) catch break;
                defer result.loop.deinit();
                self.last_exit_code = cf_executor.executeWhile(&result.loop) catch 1;
                line_num = result.end;
                continue;
            }
            if (std.mem.startsWith(u8, trimmed, "until ")) {
                var result = cf_parser.parseWhile(lines, line_num, true) catch break;
                defer result.loop.deinit();
                self.last_exit_code = cf_executor.executeWhile(&result.loop) catch 1;
                line_num = result.end;
                continue;
            }
            if (std.mem.startsWith(u8, trimmed, "for ")) {
                var result = cf_parser.parseFor(lines, line_num) catch break;
                defer result.loop.deinit();
                self.last_exit_code = cf_executor.executeFor(&result.loop) catch 1;
                line_num = result.end;
                continue;
            }
            if (std.mem.startsWith(u8, trimmed, "case ")) {
                var result = cf_parser.parseCase(lines, line_num) catch break;
                defer result.stmt.deinit();
                self.last_exit_code = cf_executor.executeCase(&result.stmt) catch 1;
                line_num = result.end;
                continue;
            }

            // Simple command - execute directly
            cmd_fn(self, trimmed) catch {
                self.last_exit_code = 1;
            };
        }
    }
}

/// Builtin: mapfile/readarray - read lines from stdin into array
pub fn builtinMapfile(self: *Shell, cmd: *types.ParsedCommand) !void {
    var delimiter: u8 = '\n';
    var count: ?usize = null; // -n count: read at most count lines
    var origin: usize = 0; // -O origin: begin at index origin
    var skip: usize = 0; // -s count: skip first count lines
    var remove_delimiter = true; // -t: remove delimiter (default)
    var callback: ?[]const u8 = null; // -C callback: eval callback
    var callback_quantum: usize = 5000; // -c quantum: callback every quantum lines
    var array_name: []const u8 = "MAPFILE";
    var arg_start: usize = 0;

    // Parse flags
    while (arg_start < cmd.args.len) {
        const arg = cmd.args[arg_start];
        if (arg.len >= 2 and arg[0] == '-') {
            arg_start += 1;
            switch (arg[1]) {
                'd' => {
                    if (arg.len > 2) {
                        delimiter = arg[2];
                    } else if (arg_start < cmd.args.len) {
                        const delim_arg = cmd.args[arg_start];
                        arg_start += 1;
                        if (delim_arg.len > 0) delimiter = delim_arg[0];
                    }
                },
                'n' => {
                    if (arg.len > 2) {
                        count = std.fmt.parseInt(usize, arg[2..], 10) catch null;
                    } else if (arg_start < cmd.args.len) {
                        count = std.fmt.parseInt(usize, cmd.args[arg_start], 10) catch null;
                        arg_start += 1;
                    }
                },
                'O' => {
                    if (arg.len > 2) {
                        origin = std.fmt.parseInt(usize, arg[2..], 10) catch 0;
                    } else if (arg_start < cmd.args.len) {
                        origin = std.fmt.parseInt(usize, cmd.args[arg_start], 10) catch 0;
                        arg_start += 1;
                    }
                },
                's' => {
                    if (arg.len > 2) {
                        skip = std.fmt.parseInt(usize, arg[2..], 10) catch 0;
                    } else if (arg_start < cmd.args.len) {
                        skip = std.fmt.parseInt(usize, cmd.args[arg_start], 10) catch 0;
                        arg_start += 1;
                    }
                },
                't' => remove_delimiter = true,
                'C' => {
                    if (arg_start < cmd.args.len) {
                        callback = cmd.args[arg_start];
                        arg_start += 1;
                    }
                },
                'c' => {
                    if (arg.len > 2) {
                        callback_quantum = std.fmt.parseInt(usize, arg[2..], 10) catch 5000;
                    } else if (arg_start < cmd.args.len) {
                        callback_quantum = std.fmt.parseInt(usize, cmd.args[arg_start], 10) catch 5000;
                        arg_start += 1;
                    }
                },
                else => {},
            }
        } else {
            break;
        }
    }

    // Get array name if provided
    if (arg_start < cmd.args.len) {
        array_name = cmd.args[arg_start];
    }

    // Read from stdin
    var lines = std.ArrayList([]const u8).empty;
    defer {
        for (lines.items) |line| {
            self.allocator.free(line);
        }
        lines.deinit(self.allocator);
    }

    var line_count: usize = 0;
    var skipped: usize = 0;

    // Read lines from stdin, respecting the delimiter
    while (true) {
        const line = if (delimiter == '\n') blk: {
            // Default newline delimiter: use existing IO.readLine
            break :blk IO.readLine(self.allocator) catch break;
        } else blk: {
            // Custom delimiter: read byte-by-byte until delimiter is found
            var line_buf: std.ArrayList(u8) = .empty;
            errdefer line_buf.deinit(self.allocator);
            var found_delim = false;
            if (comptime builtin.os.tag != .windows) {
                while (true) {
                    var byte_buf: [1]u8 = undefined;
                    const bytes_read = std.posix.read(std.posix.STDIN_FILENO, &byte_buf) catch break;
                    if (bytes_read == 0) break; // EOF
                    if (byte_buf[0] == delimiter) {
                        found_delim = true;
                        break;
                    }
                    line_buf.append(self.allocator, byte_buf[0]) catch break;
                }
            }
            if (line_buf.items.len == 0 and !found_delim) {
                line_buf.deinit(self.allocator);
                break :blk @as(?[]u8, null);
            }
            const result = line_buf.toOwnedSlice(self.allocator) catch {
                line_buf.deinit(self.allocator);
                break :blk @as(?[]u8, null);
            };
            break :blk @as(?[]u8, result);
        };
        if (line == null) break;
        defer self.allocator.free(line.?);

        if (skipped < skip) {
            skipped += 1;
            continue;
        }

        if (count) |max_count| {
            if (line_count >= max_count) break;
        }

        const line_copy = if (remove_delimiter)
            try self.allocator.dupe(u8, line.?)
        else blk: {
            const with_delim = try self.allocator.alloc(u8, line.?.len + 1);
            @memcpy(with_delim[0..line.?.len], line.?);
            with_delim[line.?.len] = '\n';
            break :blk with_delim;
        };
        try lines.append(self.allocator, line_copy);
        line_count += 1;

        // Execute callback if specified
        if (callback) |cb| {
            if (line_count % callback_quantum == 0) {
                _ = cb;
                // Would execute callback here
            }
        }
    }

    // Store in array
    const array_slice = try self.allocator.alloc([]const u8, origin + lines.items.len);
    // Initialize with empty strings for indices before origin
    for (0..origin) |i| {
        array_slice[i] = try self.allocator.dupe(u8, "");
    }
    for (lines.items, 0..) |line, i| {
        array_slice[origin + i] = try self.allocator.dupe(u8, line);
    }

    const gop = try self.arrays.getOrPut(array_name);
    if (gop.found_existing) {
        // Free old array
        gop.value_ptr.deinit(self.allocator);
    } else {
        const key = try self.allocator.dupe(u8, array_name);
        gop.key_ptr.* = key;
    }
    gop.value_ptr.* = try types.IndexedArray.fromOwnedDense(self.allocator, array_slice);

    self.last_exit_code = 0;
}

/// Builtin: time - time command execution
pub fn builtinTime(self: *Shell, cmd: *types.ParsedCommand) !void {
    // Parse flags
    var posix_format = false; // -p: POSIX format output
    var verbose = false; // -v: verbose output with more details
    var arg_start: usize = 0;

    while (arg_start < cmd.args.len) {
        const arg = cmd.args[arg_start];
        if (arg.len > 0 and arg[0] == '-') {
            if (std.mem.eql(u8, arg, "-p")) {
                posix_format = true;
                arg_start += 1;
            } else if (std.mem.eql(u8, arg, "-v")) {
                verbose = true;
                arg_start += 1;
            } else if (std.mem.eql(u8, arg, "--")) {
                arg_start += 1;
                break;
            } else {
                // Unknown flag or start of command
                break;
            }
        } else {
            break;
        }
    }

    if (arg_start >= cmd.args.len) {
        try IO.eprint("den: time: missing command\n", .{});
        self.last_exit_code = 1;
        return;
    }

    // Join remaining arguments to form command
    var cmd_buf: [4096]u8 = undefined;
    var cmd_len: usize = 0;

    for (cmd.args[arg_start..], 0..) |arg, i| {
        if (i > 0 and cmd_len < cmd_buf.len) {
            cmd_buf[cmd_len] = ' ';
            cmd_len += 1;
        }

        const copy_len = @min(arg.len, cmd_buf.len - cmd_len);
        @memcpy(cmd_buf[cmd_len .. cmd_len + copy_len], arg[0..copy_len]);
        cmd_len += copy_len;

        if (cmd_len >= cmd_buf.len) break;
    }

    const command_str = cmd_buf[0..cmd_len];

    // Get start time
    const start_time = compat.Instant.now() catch {
        try IO.eprint("den: time: cannot get time\n", .{});
        self.last_exit_code = 1;
        return;
    };

    // Execute command
    var tokenizer = parser_mod.Tokenizer.init(self.allocator, command_str);
    const tokens = tokenizer.tokenize() catch |err| {
        try IO.eprint("den: time: parse error: {}\n", .{err});
        self.last_exit_code = 1;
        return;
    };
    defer self.allocator.free(tokens);

    var parser = parser_mod.Parser.init(self.allocator, tokens);
    var chain = parser.parse() catch |err| {
        try IO.eprint("den: time: {s}\n", .{formatParseError(err)});
        self.last_exit_code = 2;
        return;
    };
    defer chain.deinit(self.allocator);

    try self.expandCommandChain(&chain);
    try self.expandAliases(&chain);

    var executor = executor_mod.Executor.init(self.allocator, &self.environment);
    const exit_code = executor.executeChain(&chain) catch |err| {
        try IO.eprint("den: time: execution error: {}\n", .{err});
        self.last_exit_code = 1;
        return;
    };

    // Get end time and calculate duration
    const end_time = compat.Instant.now() catch {
        self.last_exit_code = exit_code;
        return;
    };
    const elapsed_ns = end_time.since(start_time);
    const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;

    if (posix_format) {
        // POSIX format: "real %f\nuser %f\nsys %f\n"
        try IO.eprint("real {d:.2}\n", .{elapsed_s});
        try IO.eprint("user 0.00\n", .{});
        try IO.eprint("sys 0.00\n", .{});
    } else if (verbose) {
        // Verbose format with more details
        try IO.eprint("\n", .{});
        try IO.eprint("        Command: {s}\n", .{command_str});
        try IO.eprint("    Exit status: {d}\n", .{exit_code});
        if (elapsed_s >= 1.0) {
            try IO.eprint("      Real time: {d:.3}s\n", .{elapsed_s});
        } else {
            try IO.eprint("      Real time: {d:.1}ms\n", .{elapsed_ms});
        }
    } else {
        // Default format with tabs
        const duration_ns: i128 = @intCast(elapsed_ns);
        const duration_ms = @divFloor(duration_ns, 1_000_000);
        const duration_s = @divFloor(duration_ms, 1000);
        const remaining_ms = @mod(duration_ms, 1000);
        try IO.eprint("\nreal\t{d}.{d:0>3}s\n", .{ duration_s, remaining_ms });
    }

    self.last_exit_code = exit_code;
}

/// Builtin: hash - manage named directories
pub fn builtinHash(self: *Shell, cmd: *types.ParsedCommand) !void {
    if (cmd.args.len == 0) {
        // Display all named directories
        var iter = self.named_dirs.iterator();
        var has_entries = false;
        while (iter.next()) |entry| {
            try IO.print("hash -d {s}={s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
            has_entries = true;
        }
        if (!has_entries) {
            try IO.print("den: hash: no named directories defined\n", .{});
        }
        self.last_exit_code = 0;
    } else if (std.mem.eql(u8, cmd.args[0], "-d")) {
        // Named directory operations (zsh-style)
        if (cmd.args.len == 1) {
            // List all named directories
            var iter = self.named_dirs.iterator();
            var has_entries = false;
            while (iter.next()) |entry| {
                try IO.print("{s}={s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
                has_entries = true;
            }
            if (!has_entries) {
                try IO.print("den: hash -d: no named directories defined\n", .{});
            }
            self.last_exit_code = 0;
        } else {
            // Add/update named directory: hash -d name=path
            const arg = cmd.args[1];
            if (std.mem.indexOfScalar(u8, arg, '=')) |eq_pos| {
                const name = arg[0..eq_pos];
                var path = arg[eq_pos + 1 ..];

                // Expand ~ in path
                if (path.len > 0 and path[0] == '~') {
                    if (getenv("HOME")) |home| {
                        if (path.len == 1) {
                            path = home;
                        } else if (path[1] == '/') {
                            // ~/ case - need to concatenate
                            const expanded = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ home, path[1..] });
                            defer self.allocator.free(expanded);

                            // Store the expanded path
                            const name_copy = try self.allocator.dupe(u8, name);
                            const path_copy = try self.allocator.dupe(u8, expanded);

                            // Free old value if exists
                            if (self.named_dirs.get(name)) |old_path| {
                                self.allocator.free(old_path);
                                const old_name = self.named_dirs.getKey(name).?;
                                self.allocator.free(old_name);
                                _ = self.named_dirs.remove(name);
                            }

                            try self.named_dirs.put(name_copy, path_copy);
                            try IO.print("den: hash -d: {s}={s}\n", .{ name, path_copy });
                            self.last_exit_code = 0;
                            return;
                        }
                    }
                }

                // Store the named directory
                const name_copy = try self.allocator.dupe(u8, name);
                const path_copy = try self.allocator.dupe(u8, path);

                // Free old value if exists
                if (self.named_dirs.get(name)) |old_path| {
                    self.allocator.free(old_path);
                    const old_name = self.named_dirs.getKey(name).?;
                    self.allocator.free(old_name);
                    _ = self.named_dirs.remove(name);
                }

                try self.named_dirs.put(name_copy, path_copy);
                try IO.print("den: hash -d: {s}={s}\n", .{ name, path });
                self.last_exit_code = 0;
            } else {
                try IO.eprint("den: hash -d: usage: hash -d name=path\n", .{});
                self.last_exit_code = 1;
            }
        }
    } else if (std.mem.eql(u8, cmd.args[0], "-r")) {
        // Clear the command path hash table
        var cache_iter = self.command_cache.iterator();
        while (cache_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.command_cache.clearRetainingCapacity();
        try IO.print("den: hash: cache cleared\n", .{});
        self.last_exit_code = 0;
    } else {
        // Add command to hash table
        try IO.print("den: hash: {s} added to cache\n", .{cmd.args[0]});
        self.last_exit_code = 0;
    }
}

/// Builtin: umask - set file creation mask
pub fn builtinUmask(self: *Shell, cmd: *types.ParsedCommand) !void {
    // Parse flags
    var symbolic_output = false; // -S: symbolic output
    var arg_idx: usize = 0;

    while (arg_idx < cmd.args.len) {
        const arg = cmd.args[arg_idx];
        if (arg.len > 0 and arg[0] == '-') {
            for (arg[1..]) |c| {
                switch (c) {
                    'S' => symbolic_output = true,
                    else => {
                        try IO.eprint("den: umask: -{c}: invalid option\n", .{c});
                        self.last_exit_code = 1;
                        return;
                    },
                }
            }
            arg_idx += 1;
        } else {
            break;
        }
    }

    // Get current umask
    const current = std.c.umask(0);
    _ = std.c.umask(current); // Restore it

    if (arg_idx >= cmd.args.len) {
        // No mask argument - display current umask
        if (symbolic_output) {
            // Symbolic format: u=rwx,g=rx,o=rx (showing what IS allowed, not masked)
            const perms: u9 = @truncate(~current & 0o777);
            const u_r: u8 = if (perms & 0o400 != 0) 'r' else '-';
            const u_w: u8 = if (perms & 0o200 != 0) 'w' else '-';
            const u_x: u8 = if (perms & 0o100 != 0) 'x' else '-';
            const g_r: u8 = if (perms & 0o040 != 0) 'r' else '-';
            const g_w: u8 = if (perms & 0o020 != 0) 'w' else '-';
            const g_x: u8 = if (perms & 0o010 != 0) 'x' else '-';
            const o_r: u8 = if (perms & 0o004 != 0) 'r' else '-';
            const o_w: u8 = if (perms & 0o002 != 0) 'w' else '-';
            const o_x: u8 = if (perms & 0o001 != 0) 'x' else '-';
            try IO.print("u={c}{c}{c},g={c}{c}{c},o={c}{c}{c}\n", .{ u_r, u_w, u_x, g_r, g_w, g_x, o_r, o_w, o_x });
        } else {
            try IO.print("{o:0>4}\n", .{current});
        }
        self.last_exit_code = 0;
        return;
    }

    // Set umask
    const mask_str = cmd.args[arg_idx];

    // Check if it's symbolic mode (contains letters like u,g,o,a or operators +,-,=)
    var is_symbolic_mode = false;
    for (mask_str) |c| {
        if (c == 'u' or c == 'g' or c == 'o' or c == 'a' or c == '+' or c == '-' or c == '=') {
            is_symbolic_mode = true;
            break;
        }
    }

    if (is_symbolic_mode) {
        // Parse symbolic mode like u=rwx,g=rx,o=rx or u+w,g-w
        var new_mask = current;

        var iter = std.mem.splitScalar(u8, mask_str, ',');
        while (iter.next()) |part| {
            if (part.len < 2) continue;

            // Parse who (u, g, o, a)
            var who_mask: std.c.mode_t = 0;
            var i: usize = 0;
            while (i < part.len and (part[i] == 'u' or part[i] == 'g' or part[i] == 'o' or part[i] == 'a')) : (i += 1) {
                switch (part[i]) {
                    'u' => who_mask |= 0o700,
                    'g' => who_mask |= 0o070,
                    'o' => who_mask |= 0o007,
                    'a' => who_mask |= 0o777,
                    else => {},
                }
            }
            if (who_mask == 0) who_mask = 0o777; // default to all

            if (i >= part.len) continue;

            // Parse operator (+, -, =)
            const op = part[i];
            i += 1;

            // Parse permissions (r, w, x)
            var perm_bits: std.c.mode_t = 0;
            while (i < part.len) : (i += 1) {
                switch (part[i]) {
                    'r' => perm_bits |= 0o444,
                    'w' => perm_bits |= 0o222,
                    'x' => perm_bits |= 0o111,
                    else => {},
                }
            }

            // Apply based on who
            perm_bits &= who_mask;

            switch (op) {
                '=' => {
                    // Clear and set: set masked bits for who, clear allowed bits
                    new_mask = (new_mask & ~who_mask) | (~perm_bits & who_mask);
                },
                '+' => {
                    // Remove from mask (allow permission)
                    new_mask &= ~perm_bits;
                },
                '-' => {
                    // Add to mask (deny permission)
                    new_mask |= perm_bits;
                },
                else => {},
            }
        }

        _ = std.c.umask(new_mask);
    } else {
        // Octal mode
        const new_mask = std.fmt.parseInt(u32, mask_str, 8) catch {
            try IO.eprint("den: umask: {s}: invalid octal number\n", .{mask_str});
            self.last_exit_code = 1;
            return;
        };
        _ = std.c.umask(@intCast(new_mask));
    }

    self.last_exit_code = 0;
}

/// Builtin: caller - display call stack
pub fn builtinCaller(self: *Shell, cmd: *types.ParsedCommand) !void {
    var expr_depth: usize = 0;

    if (cmd.args.len > 0) {
        expr_depth = std.fmt.parseInt(usize, cmd.args[0], 10) catch 0;
    }

    if (expr_depth >= self.call_stack_depth) {
        self.last_exit_code = 1;
        return;
    }

    const frame = self.call_stack[self.call_stack_depth - 1 - expr_depth];
    try IO.print("{d} {s} {s}\n", .{ frame.line_number, frame.function_name, frame.source_file });
    self.last_exit_code = 0;
}
