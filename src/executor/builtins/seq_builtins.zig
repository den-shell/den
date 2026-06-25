const std = @import("std");
const types = @import("../../types/mod.zig");
const IO = @import("../../utils/io.zig").IO;
const common = @import("common.zig");

/// True if `s` parses as a number (so a leading '-' is a negative value, not a flag).
fn isNumeric(s: []const u8) bool {
    _ = std.fmt.parseFloat(f64, s) catch return false;
    return true;
}

/// Generate a sequence of numbers.
///
/// Usage:
///   seq <end>                 - Print numbers 1 to end
///   seq <start> <end>         - Print numbers from start to end
///   seq <start> <step> <end>  - Print numbers from start to end with step
///
/// Options:
///   -s, --separator <sep>     - Use <sep> as separator (default: newline)
pub fn seqCmd(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    _ = allocator;

    var separator: []const u8 = "\n";
    var positional_buf: [3][]const u8 = undefined;
    var positional_len: usize = 0;

    // Parse flags and positional arguments
    var i: usize = 0;
    while (i < command.args.len) : (i += 1) {
        const arg = command.args[i];
        if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--separator")) {
            if (i + 1 < command.args.len) {
                i += 1;
                separator = command.args[i];
            } else {
                try IO.eprint("seq: option '{s}' requires an argument\n", .{arg});
                return 1;
            }
        } else if (std.mem.startsWith(u8, arg, "-s") and arg.len > 2) {
            // GNU attached form: -s,  (separator with no space)
            separator = arg[2..];
        } else if (std.mem.startsWith(u8, arg, "--separator=")) {
            separator = arg["--separator=".len..];
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try IO.print("Usage: seq [options] [start [step]] end\n", .{});
            try IO.print("Print a sequence of numbers.\n\n", .{});
            try IO.print("Options:\n", .{});
            try IO.print("  -s, --separator <sep>  Use <sep> as separator (default: newline)\n", .{});
            try IO.print("  -h, --help             Show this help message\n", .{});
            return 0;
        } else if (arg.len > 1 and arg[0] == '-' and !isNumeric(arg)) {
            // An unrecognized flag (-w, -f, -t, …) — not a negative number. The
            // builtin doesn't implement it, so defer to the real seq.
            return error.FallbackToExternal;
        } else {
            if (positional_len >= 3) {
                try IO.eprint("seq: too many arguments\n", .{});
                return 1;
            }
            positional_buf[positional_len] = arg;
            positional_len += 1;
        }
    }

    if (positional_len == 0) {
        try IO.eprint("Usage: seq [options] [start [step]] end\n", .{});
        return 1;
    }

    var start: f64 = 1;
    var step: f64 = 1;
    var end: f64 = undefined;

    switch (positional_len) {
        1 => {
            // seq <end>
            end = std.fmt.parseFloat(f64, positional_buf[0]) catch {
                try IO.eprint("seq: invalid number: {s}\n", .{positional_buf[0]});
                return 1;
            };
        },
        2 => {
            // seq <start> <end>
            start = std.fmt.parseFloat(f64, positional_buf[0]) catch {
                try IO.eprint("seq: invalid number: {s}\n", .{positional_buf[0]});
                return 1;
            };
            end = std.fmt.parseFloat(f64, positional_buf[1]) catch {
                try IO.eprint("seq: invalid number: {s}\n", .{positional_buf[1]});
                return 1;
            };
        },
        3 => {
            // seq <start> <step> <end>
            start = std.fmt.parseFloat(f64, positional_buf[0]) catch {
                try IO.eprint("seq: invalid number: {s}\n", .{positional_buf[0]});
                return 1;
            };
            step = std.fmt.parseFloat(f64, positional_buf[1]) catch {
                try IO.eprint("seq: invalid number: {s}\n", .{positional_buf[1]});
                return 1;
            };
            end = std.fmt.parseFloat(f64, positional_buf[2]) catch {
                try IO.eprint("seq: invalid number: {s}\n", .{positional_buf[2]});
                return 1;
            };
        },
        else => unreachable,
    }

    // Validate step
    if (step == 0) {
        try IO.eprint("seq: step cannot be zero\n", .{});
        return 1;
    }

    // Auto-negate step if going in the wrong direction
    if (start < end and step < 0) {
        step = -step;
    } else if (start > end and step > 0) {
        step = -step;
    }

    // Use newline as the final terminator if separator is not newline
    const use_custom_sep = !std.mem.eql(u8, separator, "\n");

    var first = true;
    var current = start;

    if (step > 0) {
        while (current <= end + step * 0.5e-10) {
            if (use_custom_sep) {
                if (!first) {
                    try IO.print("{s}", .{separator});
                }
                if (current == @floor(current) and @abs(current) < 1e15) {
                    try IO.print("{d}", .{@as(i64, @intFromFloat(current))});
                } else {
                    try IO.print("{d}", .{current});
                }
            } else {
                try common.printNumber(current);
            }
            first = false;
            current += step;
        }
    } else {
        while (current >= end + step * 0.5e-10) {
            if (use_custom_sep) {
                if (!first) {
                    try IO.print("{s}", .{separator});
                }
                if (current == @floor(current) and @abs(current) < 1e15) {
                    try IO.print("{d}", .{@as(i64, @intFromFloat(current))});
                } else {
                    try IO.print("{d}", .{current});
                }
            } else {
                try common.printNumber(current);
            }
            first = false;
            current += step;
        }
    }

    // Print final newline when using custom separator
    if (use_custom_sep and !first) {
        try IO.print("\n", .{});
    }

    return 0;
}

/// Generate a sequence of characters.
///
/// Usage:
///   seq-char <start> <end>  - Print characters from start to end
///
/// Supports both ascending (a..z) and descending (z..a) sequences.
pub fn seqCharCmd(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    _ = allocator;

    if (command.args.len >= 1 and (std.mem.eql(u8, command.args[0], "--help") or std.mem.eql(u8, command.args[0], "-h"))) {
        try IO.print("Usage: seq-char <start> <end>\n", .{});
        try IO.print("Print a sequence of characters.\n\n", .{});
        try IO.print("Examples:\n", .{});
        try IO.print("  seq-char a z    # prints a through z\n", .{});
        try IO.print("  seq-char Z A    # prints Z through A (descending)\n", .{});
        try IO.print("  seq-char 0 9    # prints 0 through 9\n", .{});
        return 0;
    }

    if (command.args.len < 2) {
        try IO.eprint("Usage: seq-char <start> <end>\n", .{});
        return 1;
    }

    const start_arg = command.args[0];
    const end_arg = command.args[1];

    if (start_arg.len != 1) {
        try IO.eprint("seq-char: start must be a single character, got: {s}\n", .{start_arg});
        return 1;
    }
    if (end_arg.len != 1) {
        try IO.eprint("seq-char: end must be a single character, got: {s}\n", .{end_arg});
        return 1;
    }

    const start_char = start_arg[0];
    const end_char = end_arg[0];

    if (start_char <= end_char) {
        // Ascending
        var c: u8 = start_char;
        while (c <= end_char) : (c += 1) {
            try IO.print("{c}\n", .{c});
            if (c == end_char) break; // Prevent overflow on u8 boundary
        }
    } else {
        // Descending
        var c: u8 = start_char;
        while (c >= end_char) : (c -= 1) {
            try IO.print("{c}\n", .{c});
            if (c == end_char) break; // Prevent underflow on u8 boundary
        }
    }

    return 0;
}
