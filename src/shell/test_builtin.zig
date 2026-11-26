//! Test Builtin Implementation
//!
//! This module implements the test, [, and [[ builtin commands
//! for shell conditional expressions.

const std = @import("std");
const IO = @import("../utils/io.zig").IO;
const types = @import("../types/mod.zig");
const regex = @import("../utils/regex.zig");
const matchRegexAt = regex.matchRegexAt;

// Forward declaration for Shell type
const Shell = @import("../shell.zig").Shell;

/// Builtin: test / [ / [[ - evaluate conditional expressions
pub fn builtinTest(shell: *Shell, cmd: *types.ParsedCommand) !void {
    // Simple test implementation supporting basic conditions
    if (cmd.args.len == 0) {
        shell.last_exit_code = 1;
        return;
    }

    // Handle [ command - must end with ]
    var args = cmd.args;
    if (std.mem.eql(u8, cmd.name, "[")) {
        if (args.len == 0 or !std.mem.eql(u8, args[args.len - 1], "]")) {
            try IO.eprint("den: [: missing ]\n", .{});
            shell.last_exit_code = 2;
            return;
        }
        args = args[0 .. args.len - 1]; // Remove trailing ]
    } else if (std.mem.eql(u8, cmd.name, "[[")) {
        if (args.len == 0 or !std.mem.eql(u8, args[args.len - 1], "]]")) {
            try IO.eprint("den: [[: missing ]]\n", .{});
            shell.last_exit_code = 2;
            return;
        }
        args = args[0 .. args.len - 1]; // Remove trailing ]]
    }

    if (args.len == 0) {
        shell.last_exit_code = 1;
        return;
    }

    // Handle negation: [ ! expr ]
    if (args.len >= 2 and std.mem.eql(u8, args[0], "!")) {
        // The outer command already validated and stripped its closing bracket.
        var negated_cmd = cmd.*;
        negated_cmd.name = "test";
        negated_cmd.args = args[1..];
        try builtinTest(shell, &negated_cmd);
        if (shell.last_exit_code == 0 or shell.last_exit_code == 1)
            shell.last_exit_code = 1 - shell.last_exit_code;
        return;
    }

    // Unary operators
    if (args.len == 2) {
        const op = args[0];
        const arg = args[1];

        if (std.mem.eql(u8, op, "-z")) {
            // String is empty
            shell.last_exit_code = if (arg.len == 0) 0 else 1;
            return;
        } else if (std.mem.eql(u8, op, "-n")) {
            // String is not empty
            shell.last_exit_code = if (arg.len > 0) 0 else 1;
            return;
        } else if (std.mem.eql(u8, op, "-f")) {
            // File exists and is regular file
            const stat = std.Io.Dir.cwd().statFile(std.Options.debug_io, arg, .{}) catch {
                shell.last_exit_code = 1;
                return;
            };
            shell.last_exit_code = if (stat.kind == .file) 0 else 1;
            return;
        } else if (std.mem.eql(u8, op, "-d")) {
            // Directory exists
            const stat = std.Io.Dir.cwd().statFile(std.Options.debug_io, arg, .{}) catch {
                shell.last_exit_code = 1;
                return;
            };
            shell.last_exit_code = if (stat.kind == .directory) 0 else 1;
            return;
        } else if (std.mem.eql(u8, op, "-e")) {
            // File exists
            std.Io.Dir.cwd().access(std.Options.debug_io, arg, .{}) catch {
                shell.last_exit_code = 1;
                return;
            };
            shell.last_exit_code = 0;
            return;
        } else if (std.mem.eql(u8, op, "-v")) {
            // Variable is set - check environment, local vars, and arrays
            var is_set = shell.environment.get(arg) != null;
            if (!is_set) {
                // Check if it's an array
                is_set = shell.arrays.contains(arg) or shell.assoc_arrays.contains(arg);
            }
            if (!is_set) {
                // Check local vars in function scope
                if (shell.function_manager.currentFrame()) |frame| {
                    is_set = frame.local_vars.contains(arg);
                }
            }
            shell.last_exit_code = if (is_set) 0 else 1;
            return;
        } else if (std.mem.eql(u8, op, "-s")) {
            // File exists and is not empty
            const stat = std.Io.Dir.cwd().statFile(std.Options.debug_io, arg, .{}) catch {
                shell.last_exit_code = 1;
                return;
            };
            shell.last_exit_code = if (stat.size > 0) 0 else 1;
            return;
        } else if (std.mem.eql(u8, op, "-r")) {
            // File exists and is readable
            std.Io.Dir.cwd().access(std.Options.debug_io, arg, .{ .read = true }) catch {
                shell.last_exit_code = 1;
                return;
            };
            shell.last_exit_code = 0;
            return;
        } else if (std.mem.eql(u8, op, "-w")) {
            // File exists and is writable
            std.Io.Dir.cwd().access(std.Options.debug_io, arg, .{ .write = true }) catch {
                shell.last_exit_code = 1;
                return;
            };
            shell.last_exit_code = 0;
            return;
        } else if (std.mem.eql(u8, op, "-x")) {
            // File exists and is executable
            std.Io.Dir.cwd().access(std.Options.debug_io, arg, .{ .execute = true }) catch {
                shell.last_exit_code = 1;
                return;
            };
            shell.last_exit_code = 0;
            return;
        } else if (std.mem.eql(u8, op, "-L") or std.mem.eql(u8, op, "-h")) {
            // File exists and is a symbolic link
            const stat = std.Io.Dir.cwd().statFile(std.Options.debug_io, arg, .{ .follow_symlinks = false }) catch {
                shell.last_exit_code = 1;
                return;
            };
            shell.last_exit_code = if (stat.kind == .sym_link) 0 else 1;
            return;
        } else if (std.mem.eql(u8, op, "-p")) {
            // File exists and is a named pipe (FIFO)
            const stat = std.Io.Dir.cwd().statFile(std.Options.debug_io, arg, .{}) catch {
                shell.last_exit_code = 1;
                return;
            };
            shell.last_exit_code = if (stat.kind == .named_pipe) 0 else 1;
            return;
        } else if (std.mem.eql(u8, op, "-b")) {
            // File exists and is a block device
            const stat = std.Io.Dir.cwd().statFile(std.Options.debug_io, arg, .{}) catch {
                shell.last_exit_code = 1;
                return;
            };
            shell.last_exit_code = if (stat.kind == .block_device) 0 else 1;
            return;
        } else if (std.mem.eql(u8, op, "-c")) {
            // File exists and is a character device
            const stat = std.Io.Dir.cwd().statFile(std.Options.debug_io, arg, .{}) catch {
                shell.last_exit_code = 1;
                return;
            };
            shell.last_exit_code = if (stat.kind == .character_device) 0 else 1;
            return;
        } else if (std.mem.eql(u8, op, "-t")) {
            // File descriptor is a terminal
            const fd_num = std.fmt.parseInt(i32, arg, 10) catch {
                shell.last_exit_code = 1;
                return;
            };
            if (comptime @import("builtin").os.tag == .windows) {
                shell.last_exit_code = 1; // Simplified for Windows
            } else {
                shell.last_exit_code = if (std.c.isatty(@intCast(fd_num)) != 0) 0 else 1;
            }
            return;
        }
    }

    // Compound expressions with -a (and) and -o (or)
    // e.g., [ -f file -a -r file ] or [ -n "$x" -o -n "$y" ]
    if (args.len >= 5) {
        // Find -a or -o operator
        var op_idx: usize = 1;
        while (op_idx < args.len) : (op_idx += 1) {
            if (std.mem.eql(u8, args[op_idx], "-o")) {
                // OR: evaluate left side first
                var left_cmd = cmd.*;
                left_cmd.args = args[0..op_idx];
                builtinTest(shell, &left_cmd) catch {};
                const left_result = shell.last_exit_code;
                if (left_result == 0) {
                    shell.last_exit_code = 0;
                    return;
                }
                var right_cmd = cmd.*;
                right_cmd.args = args[op_idx + 1 ..];
                builtinTest(shell, &right_cmd) catch {};
                return;
            }
        }
        op_idx = 1;
        while (op_idx < args.len) : (op_idx += 1) {
            if (std.mem.eql(u8, args[op_idx], "-a")) {
                // AND: evaluate both sides
                var left_cmd = cmd.*;
                left_cmd.args = args[0..op_idx];
                builtinTest(shell, &left_cmd) catch {};
                const left_result = shell.last_exit_code;
                if (left_result != 0) {
                    shell.last_exit_code = left_result;
                    return;
                }
                var right_cmd = cmd.*;
                right_cmd.args = args[op_idx + 1 ..];
                builtinTest(shell, &right_cmd) catch {};
                return;
            }
        }
    }

    // Binary operators
    if (args.len == 3) {
        const left = args[0];
        const op = args[1];
        const right = args[2];

        if (std.mem.eql(u8, op, "=") or std.mem.eql(u8, op, "==")) {
            // String equality
            shell.last_exit_code = if (std.mem.eql(u8, left, right)) 0 else 1;
            return;
        } else if (std.mem.eql(u8, op, "!=")) {
            // String inequality
            shell.last_exit_code = if (!std.mem.eql(u8, left, right)) 0 else 1;
            return;
        } else if (std.mem.eql(u8, op, "-eq")) {
            // Numeric equality
            const left_num = std.fmt.parseInt(i32, left, 10) catch {
                shell.last_exit_code = 2;
                return;
            };
            const right_num = std.fmt.parseInt(i32, right, 10) catch {
                shell.last_exit_code = 2;
                return;
            };
            shell.last_exit_code = if (left_num == right_num) 0 else 1;
            return;
        } else if (std.mem.eql(u8, op, "-ne")) {
            // Numeric inequality
            const left_num = std.fmt.parseInt(i32, left, 10) catch {
                shell.last_exit_code = 2;
                return;
            };
            const right_num = std.fmt.parseInt(i32, right, 10) catch {
                shell.last_exit_code = 2;
                return;
            };
            shell.last_exit_code = if (left_num != right_num) 0 else 1;
            return;
        } else if (std.mem.eql(u8, op, "-lt")) {
            // Less than
            const left_num = std.fmt.parseInt(i32, left, 10) catch {
                shell.last_exit_code = 2;
                return;
            };
            const right_num = std.fmt.parseInt(i32, right, 10) catch {
                shell.last_exit_code = 2;
                return;
            };
            shell.last_exit_code = if (left_num < right_num) 0 else 1;
            return;
        } else if (std.mem.eql(u8, op, "-gt")) {
            // Greater than
            const left_num = std.fmt.parseInt(i32, left, 10) catch {
                shell.last_exit_code = 2;
                return;
            };
            const right_num = std.fmt.parseInt(i32, right, 10) catch {
                shell.last_exit_code = 2;
                return;
            };
            shell.last_exit_code = if (left_num > right_num) 0 else 1;
            return;
        } else if (std.mem.eql(u8, op, "-le")) {
            // Less than or equal
            const left_num = std.fmt.parseInt(i32, left, 10) catch {
                shell.last_exit_code = 2;
                return;
            };
            const right_num = std.fmt.parseInt(i32, right, 10) catch {
                shell.last_exit_code = 2;
                return;
            };
            shell.last_exit_code = if (left_num <= right_num) 0 else 1;
            return;
        } else if (std.mem.eql(u8, op, "-ge")) {
            // Greater than or equal
            const left_num = std.fmt.parseInt(i32, left, 10) catch {
                shell.last_exit_code = 2;
                return;
            };
            const right_num = std.fmt.parseInt(i32, right, 10) catch {
                shell.last_exit_code = 2;
                return;
            };
            shell.last_exit_code = if (left_num >= right_num) 0 else 1;
            return;
        } else if (std.mem.eql(u8, op, "=~")) {
            // Regex match (using basic pattern matching)
            const matches = matchRegex(left, right);
            shell.last_exit_code = if (matches) 0 else 1;
            return;
        } else if (std.mem.eql(u8, op, "<")) {
            // String less than (lexicographic)
            shell.last_exit_code = if (std.mem.lessThan(u8, left, right)) 0 else 1;
            return;
        } else if (std.mem.eql(u8, op, ">")) {
            // String greater than (lexicographic)
            shell.last_exit_code = if (std.mem.lessThan(u8, right, left)) 0 else 1;
            return;
        } else if (std.mem.eql(u8, op, "-nt")) {
            // Newer than (compare modification times)
            const left_stat = std.Io.Dir.cwd().statFile(std.Options.debug_io, left, .{}) catch {
                shell.last_exit_code = 1;
                return;
            };
            const right_stat = std.Io.Dir.cwd().statFile(std.Options.debug_io, right, .{}) catch {
                shell.last_exit_code = 0;
                return;
            };
            shell.last_exit_code = if (left_stat.mtime.nanoseconds > right_stat.mtime.nanoseconds) 0 else 1;
            return;
        } else if (std.mem.eql(u8, op, "-ot")) {
            // Older than (compare modification times)
            const left_stat = std.Io.Dir.cwd().statFile(std.Options.debug_io, left, .{}) catch {
                shell.last_exit_code = 0;
                return;
            };
            const right_stat = std.Io.Dir.cwd().statFile(std.Options.debug_io, right, .{}) catch {
                shell.last_exit_code = 1;
                return;
            };
            shell.last_exit_code = if (left_stat.mtime.nanoseconds < right_stat.mtime.nanoseconds) 0 else 1;
            return;
        } else if (std.mem.eql(u8, op, "-ef")) {
            // Same file (compare inode)
            const left_stat = std.Io.Dir.cwd().statFile(std.Options.debug_io, left, .{}) catch {
                shell.last_exit_code = 1;
                return;
            };
            const right_stat = std.Io.Dir.cwd().statFile(std.Options.debug_io, right, .{}) catch {
                shell.last_exit_code = 1;
                return;
            };
            shell.last_exit_code = if (left_stat.inode == right_stat.inode) 0 else 1;
            return;
        }
    }

    // Default: non-empty string test
    if (args.len == 1) {
        shell.last_exit_code = if (args[0].len > 0) 0 else 1;
        return;
    }

    // Unknown test
    try IO.eprint("den: test: unknown condition\n", .{});
    shell.last_exit_code = 2;
}

/// Match string against a regex pattern (basic POSIX ERE)
/// Supports: . (any char), * (zero or more), + (one or more), ? (zero or one),
/// ^ (start anchor), $ (end anchor), [...] (character class), | (alternation)
pub fn matchRegex(string: []const u8, pattern: []const u8) bool {
    // Handle anchors
    var pat = pattern;
    const str = string;
    var anchored_start = false;
    var anchored_end = false;

    if (pat.len > 0 and pat[0] == '^') {
        anchored_start = true;
        pat = pat[1..];
    }
    if (pat.len > 0 and pat[pat.len - 1] == '$') {
        anchored_end = true;
        pat = pat[0 .. pat.len - 1];
    }

    // If anchored at start, try match from beginning
    if (anchored_start) {
        return matchRegexAt(str, pat, 0, anchored_end);
    }

    // Otherwise try match at each position
    var i: usize = 0;
    while (i <= str.len) : (i += 1) {
        if (matchRegexAt(str, pat, i, anchored_end)) {
            return true;
        }
    }
    return false;
}
