const std = @import("std");
const types = @import("../../types/mod.zig");
const IO = @import("../../utils/io.zig").IO;

/// I/O builtins: echo, printf
/// Extracted from executor/mod.zig for better modularity
pub fn echo(command: *types.ParsedCommand) !i32 {
    var no_newline = false;
    var interpret_escapes = false;
    var arg_start: usize = 0;

    // Parse flags (only at the beginning)
    for (command.args, 0..) |arg, i| {
        if (arg.len > 0 and arg[0] == '-' and arg.len > 1) {
            var valid_flag = true;
            var temp_no_newline = no_newline;
            var temp_interpret = interpret_escapes;

            for (arg[1..]) |c| {
                switch (c) {
                    'n' => temp_no_newline = true,
                    'e' => temp_interpret = true,
                    'E' => temp_interpret = false,
                    else => {
                        valid_flag = false;
                        break;
                    },
                }
            }

            if (valid_flag) {
                no_newline = temp_no_newline;
                interpret_escapes = temp_interpret;
                arg_start = i + 1;
            } else {
                break;
            }
        } else {
            break;
        }
    }

    // Print arguments
    for (command.args[arg_start..], 0..) |arg, i| {
        if (interpret_escapes) {
            try printWithEscapes(arg);
        } else {
            try IO.print("{s}", .{arg});
        }
        if (i < command.args[arg_start..].len - 1) {
            try IO.print(" ", .{});
        }
    }

    if (!no_newline) {
        try IO.print("\n", .{});
    }
    return 0;
}

/// Helper function to print string with escape sequence interpretation
fn printWithEscapes(s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\\' and i + 1 < s.len) {
            switch (s[i + 1]) {
                'n' => {
                    try IO.print("\n", .{});
                    i += 2;
                },
                't' => {
                    try IO.print("\t", .{});
                    i += 2;
                },
                'r' => {
                    try IO.print("\r", .{});
                    i += 2;
                },
                '\\' => {
                    try IO.print("\\", .{});
                    i += 2;
                },
                'a' => {
                    try IO.print("\x07", .{});
                    i += 2;
                },
                'b' => {
                    try IO.print("\x08", .{});
                    i += 2;
                },
                'f' => {
                    try IO.print("\x0c", .{});
                    i += 2;
                },
                'v' => {
                    try IO.print("\x0b", .{});
                    i += 2;
                },
                'e' => {
                    try IO.print("\x1b", .{});
                    i += 2;
                },
                '0' => {
                    var val: u8 = 0;
                    var j: usize = i + 2;
                    var count: usize = 0;
                    while (j < s.len and count < 3) : (j += 1) {
                        if (s[j] >= '0' and s[j] <= '7') {
                            val = val * 8 + (s[j] - '0');
                            count += 1;
                        } else {
                            break;
                        }
                    }
                    if (count > 0) {
                        try IO.print("{c}", .{val});
                        i = j;
                    } else {
                        try IO.print("{c}", .{s[i]});
                        i += 1;
                    }
                },
                'x' => {
                    var hex_val: u8 = 0;
                    var hex_count: usize = 0;
                    var k: usize = i + 2;
                    while (k < s.len and hex_count < 2) : (k += 1) {
                        const c = s[k];
                        const digit: u8 = if (c >= '0' and c <= '9')
                            c - '0'
                        else if (c >= 'a' and c <= 'f')
                            c - 'a' + 10
                        else if (c >= 'A' and c <= 'F')
                            c - 'A' + 10
                        else
                            break;
                        hex_val = hex_val * 16 + digit;
                        hex_count += 1;
                    }
                    if (hex_count > 0) {
                        try IO.print("{c}", .{hex_val});
                        i = k;
                    } else {
                        try IO.print("\\x", .{});
                        i += 2;
                    }
                    continue;
                },
                'u' => {
                    var codepoint: u21 = 0;
                    var hex_count: usize = 0;
                    var k: usize = i + 2;
                    while (k < s.len and hex_count < 4) : (k += 1) {
                        const c = s[k];
                        const digit: u21 = if (c >= '0' and c <= '9')
                            c - '0'
                        else if (c >= 'a' and c <= 'f')
                            c - 'a' + 10
                        else if (c >= 'A' and c <= 'F')
                            c - 'A' + 10
                        else
                            break;
                        codepoint = codepoint * 16 + digit;
                        hex_count += 1;
                    }
                    if (hex_count > 0) {
                        var utf8_buf: [4]u8 = undefined;
                        const utf8_len = std.unicode.utf8Encode(codepoint, &utf8_buf) catch {
                            // Output U+FFFD replacement character for invalid codepoints
                            try IO.print("\xEF\xBF\xBD", .{});
                            i = k;
                            continue;
                        };
                        var ui: usize = 0;
                        while (ui < utf8_len) : (ui += 1) {
                            try IO.print("{c}", .{utf8_buf[ui]});
                        }
                        i = k;
                        continue;
                    } else {
                        try IO.print("{c}", .{s[i]});
                        i += 1;
                        continue;
                    }
                },
                'U' => {
                    var codepoint: u21 = 0;
                    var hex_count: usize = 0;
                    var k: usize = i + 2;
                    while (k < s.len and hex_count < 8) : (k += 1) {
                        const c = s[k];
                        const digit: u21 = if (c >= '0' and c <= '9')
                            c - '0'
                        else if (c >= 'a' and c <= 'f')
                            c - 'a' + 10
                        else if (c >= 'A' and c <= 'F')
                            c - 'A' + 10
                        else
                            break;
                        codepoint = codepoint * 16 + digit;
                        hex_count += 1;
                    }
                    if (hex_count > 0) {
                        var utf8_buf: [4]u8 = undefined;
                        const utf8_len = std.unicode.utf8Encode(codepoint, &utf8_buf) catch {
                            // Output U+FFFD replacement character for invalid codepoints
                            try IO.print("\xEF\xBF\xBD", .{});
                            i = k;
                            continue;
                        };
                        var ui: usize = 0;
                        while (ui < utf8_len) : (ui += 1) {
                            try IO.print("{c}", .{utf8_buf[ui]});
                        }
                        i = k;
                        continue;
                    } else {
                        try IO.print("{c}", .{s[i]});
                        i += 1;
                        continue;
                    }
                },
                else => {
                    try IO.print("{c}", .{s[i]});
                    i += 1;
                },
            }
        } else {
            try IO.print("{c}", .{s[i]});
            i += 1;
        }
    }
}

pub fn printf(command: *types.ParsedCommand) !i32 {
    if (command.args.len == 0) {
        try IO.eprint("den: printf: missing format string\n", .{});
        return 1;
    }

    const format = command.args[0];
    var arg_idx: usize = 1;

    // Bash behavior: reuse format string while there are remaining arguments
    while (true) {
        var i: usize = 0;
        const start_arg_idx = arg_idx;

        while (i < format.len) {
            if (format[i] == '%' and i + 1 < format.len) {
                var j = i + 1;
                var left_justify = false;
                var zero_pad = false;
                var force_sign = false;
                var space_sign = false;
                var width: usize = 0;
                var precision: usize = 6;
                var has_precision = false;

                // Parse flags
                while (j < format.len) {
                    if (format[j] == '-') {
                        left_justify = true;
                        j += 1;
                    } else if (format[j] == '0') {
                        zero_pad = true;
                        j += 1;
                    } else if (format[j] == '+') {
                        force_sign = true;
                        j += 1;
                    } else if (format[j] == ' ') {
                        space_sign = true;
                        j += 1;
                    } else if (format[j] == '#') {
                        j += 1;
                    } else {
                        break;
                    }
                }
                // '+' takes precedence over ' ' (C printf semantics).
                const sign_prefix: u8 = if (force_sign) '+' else if (space_sign) ' ' else 0;

                // Parse width
                while (j < format.len and format[j] >= '0' and format[j] <= '9') {
                    width = width * 10 + (format[j] - '0');
                    j += 1;
                }

                // Parse precision
                if (j < format.len and format[j] == '.') {
                    j += 1;
                    precision = 0;
                    has_precision = true;
                    while (j < format.len and format[j] >= '0' and format[j] <= '9') {
                        precision = precision * 10 + (format[j] - '0');
                        j += 1;
                    }
                }

                if (j >= format.len) {
                    try IO.print("{c}", .{format[i]});
                    i += 1;
                    continue;
                }

                const spec = format[j];
                if (spec == 's') {
                    if (arg_idx < command.args.len) {
                        var str = command.args[arg_idx];
                        if (has_precision and str.len > precision) {
                            str = str[0..precision];
                        }
                        if (width > 0 and str.len < width) {
                            const pad = width - str.len;
                            if (left_justify) {
                                try IO.print("{s}", .{str});
                                var p: usize = 0;
                                while (p < pad) : (p += 1) try IO.print(" ", .{});
                            } else {
                                var p: usize = 0;
                                while (p < pad) : (p += 1) try IO.print(" ", .{});
                                try IO.print("{s}", .{str});
                            }
                        } else {
                            try IO.print("{s}", .{str});
                        }
                        arg_idx += 1;
                    }
                    i = j + 1;
                } else if (spec == 'd' or spec == 'i') {
                    if (arg_idx < command.args.len) {
                        const arg = command.args[arg_idx];
                        const num = if (arg.len >= 2 and (arg[0] == '\'' or arg[0] == '"'))
                            @as(i64, arg[1])
                        else
                            std.fmt.parseInt(i64, arg, 10) catch 0;
                        try printfInt(num, width, zero_pad, left_justify, sign_prefix);
                        arg_idx += 1;
                    }
                    i = j + 1;
                } else if (spec == 'u') {
                    if (arg_idx < command.args.len) {
                        const arg = command.args[arg_idx];
                        const num = if (arg.len >= 2 and (arg[0] == '\'' or arg[0] == '"'))
                            @as(u64, arg[1])
                        else
                            std.fmt.parseInt(u64, arg, 10) catch 0;
                        try printfUint(num, width, zero_pad, left_justify, 10, false);
                        arg_idx += 1;
                    }
                    i = j + 1;
                } else if (spec == 'x') {
                    if (arg_idx < command.args.len) {
                        const arg = command.args[arg_idx];
                        const num = if (arg.len >= 2 and (arg[0] == '\'' or arg[0] == '"'))
                            @as(u64, arg[1])
                        else
                            std.fmt.parseInt(u64, arg, 10) catch 0;
                        try printfUint(num, width, zero_pad, left_justify, 16, false);
                        arg_idx += 1;
                    }
                    i = j + 1;
                } else if (spec == 'X') {
                    if (arg_idx < command.args.len) {
                        const arg = command.args[arg_idx];
                        const num = if (arg.len >= 2 and (arg[0] == '\'' or arg[0] == '"'))
                            @as(u64, arg[1])
                        else
                            std.fmt.parseInt(u64, arg, 10) catch 0;
                        try printfUint(num, width, zero_pad, left_justify, 16, true);
                        arg_idx += 1;
                    }
                    i = j + 1;
                } else if (spec == 'o') {
                    if (arg_idx < command.args.len) {
                        const arg = command.args[arg_idx];
                        const num = if (arg.len >= 2 and (arg[0] == '\'' or arg[0] == '"'))
                            @as(u64, arg[1])
                        else
                            std.fmt.parseInt(u64, arg, 10) catch 0;
                        try printfUint(num, width, zero_pad, left_justify, 8, false);
                        arg_idx += 1;
                    }
                    i = j + 1;
                } else if (spec == 'c') {
                    if (arg_idx < command.args.len) {
                        const arg = command.args[arg_idx];
                        if (arg.len > 0) {
                            try IO.print("{c}", .{arg[0]});
                        }
                        arg_idx += 1;
                    }
                    i = j + 1;
                } else if (spec == 'f' or spec == 'F') {
                    if (arg_idx < command.args.len) {
                        const num = std.fmt.parseFloat(f64, command.args[arg_idx]) catch 0.0;
                        try printfFloat(num, width, precision, left_justify, sign_prefix);
                        arg_idx += 1;
                    }
                    i = j + 1;
                } else if (spec == '%') {
                    try IO.print("%", .{});
                    i = j + 1;
                } else if (spec == 'b') {
                    if (arg_idx < command.args.len) {
                        try printWithEscapes(command.args[arg_idx]);
                        arg_idx += 1;
                    }
                    i = j + 1;
                } else if (spec == 'q') {
                    if (arg_idx < command.args.len) {
                        const arg = command.args[arg_idx];
                        // Shell-safe quoting: wrap in single quotes, escape embedded single quotes as '\''
                        try IO.print("'", .{});
                        for (arg) |ch| {
                            if (ch == 0x27) { // single quote
                                try IO.print("'\\''", .{});
                            } else {
                                try IO.print("{c}", .{ch});
                            }
                        }
                        try IO.print("'", .{});
                        arg_idx += 1;
                    }
                    i = j + 1;
                } else {
                    try IO.print("{c}", .{format[i]});
                    i += 1;
                }
            } else if (format[i] == '\\' and i + 1 < format.len) {
                const esc = format[i + 1];
                switch (esc) {
                    'n' => try IO.print("\n", .{}),
                    't' => try IO.print("\t", .{}),
                    'r' => try IO.print("\r", .{}),
                    '\\' => try IO.print("\\", .{}),
                    'a' => try IO.print("\x07", .{}),
                    'b' => try IO.print("\x08", .{}),
                    'f' => try IO.print("\x0c", .{}),
                    'v' => try IO.print("\x0b", .{}),
                    'e' => try IO.print("\x1b", .{}),
                    '0' => {
                        var val: u8 = 0;
                        var k: usize = i + 2;
                        var count: usize = 0;
                        while (k < format.len and count < 3) : (k += 1) {
                            if (format[k] >= '0' and format[k] <= '7') {
                                val = val * 8 + (format[k] - '0');
                                count += 1;
                            } else break;
                        }
                        try IO.print("{c}", .{val});
                        i = k;
                        continue;
                    },
                    'x' => {
                        var hex_val: u8 = 0;
                        var hex_count: usize = 0;
                        var k: usize = i + 2;
                        while (k < format.len and hex_count < 2) : (k += 1) {
                            const c = format[k];
                            const digit: u8 = if (c >= '0' and c <= '9')
                                c - '0'
                            else if (c >= 'a' and c <= 'f')
                                c - 'a' + 10
                            else if (c >= 'A' and c <= 'F')
                                c - 'A' + 10
                            else
                                break;
                            hex_val = hex_val * 16 + digit;
                            hex_count += 1;
                        }
                        if (hex_count > 0) {
                            try IO.print("{c}", .{hex_val});
                            i = k;
                            continue;
                        } else {
                            try IO.print("{c}", .{format[i]});
                            i += 1;
                            continue;
                        }
                    },
                    else => try IO.print("{c}", .{format[i]}),
                }
                i += 2;
            } else {
                try IO.print("{c}", .{format[i]});
                i += 1;
            }
        }

        // Stop if no arguments were consumed in this pass, or no more args remain
        if (arg_idx == start_arg_idx or arg_idx >= command.args.len) break;
    }

    return 0;
}

fn printfInt(num: i64, width: usize, zero_pad: bool, left_justify: bool, sign_prefix: u8) !void {
    var buf: [32]u8 = undefined;
    const raw = std.fmt.bufPrint(&buf, "{d}", .{num}) catch return;
    // Split off the sign so width/zero-pad operate on the digits. For
    // non-negative values, `sign_prefix` ('+' or ' ') applies the +/space flag.
    var sign: u8 = 0;
    var digits: []const u8 = raw;
    if (num < 0) {
        sign = '-';
        digits = raw[1..];
    } else if (sign_prefix != 0) {
        sign = sign_prefix;
    }
    const total_len = digits.len + @as(usize, if (sign != 0) 1 else 0);
    if (width > 0 and total_len < width) {
        const pad = width - total_len;
        if (left_justify) {
            if (sign != 0) try IO.print("{c}", .{sign});
            try IO.print("{s}", .{digits});
            var p: usize = 0;
            while (p < pad) : (p += 1) try IO.print(" ", .{});
        } else if (zero_pad) {
            if (sign != 0) try IO.print("{c}", .{sign});
            var p: usize = 0;
            while (p < pad) : (p += 1) try IO.print("0", .{});
            try IO.print("{s}", .{digits});
        } else {
            var p: usize = 0;
            while (p < pad) : (p += 1) try IO.print(" ", .{});
            if (sign != 0) try IO.print("{c}", .{sign});
            try IO.print("{s}", .{digits});
        }
    } else {
        if (sign != 0) try IO.print("{c}", .{sign});
        try IO.print("{s}", .{digits});
    }
}

fn printfUint(num: u64, width: usize, zero_pad: bool, left_justify: bool, base: u8, uppercase: bool) !void {
    var buf: [32]u8 = undefined;
    const str = if (base == 16)
        if (uppercase)
            std.fmt.bufPrint(&buf, "{X}", .{num}) catch return
        else
            std.fmt.bufPrint(&buf, "{x}", .{num}) catch return
    else if (base == 8)
        std.fmt.bufPrint(&buf, "{o}", .{num}) catch return
    else
        std.fmt.bufPrint(&buf, "{d}", .{num}) catch return;

    if (width > 0 and str.len < width) {
        const pad = width - str.len;
        const pad_char: u8 = if (zero_pad and !left_justify) '0' else ' ';
        if (left_justify) {
            try IO.print("{s}", .{str});
            var p: usize = 0;
            while (p < pad) : (p += 1) try IO.print(" ", .{});
        } else {
            var p: usize = 0;
            while (p < pad) : (p += 1) try IO.print("{c}", .{pad_char});
            try IO.print("{s}", .{str});
        }
    } else {
        try IO.print("{s}", .{str});
    }
}

// ============================================================================
// Tests
// ============================================================================

test "printfInt formatting" {
    // Just verify the function compiles and doesn't crash with edge cases
    // These write to stdout which we can't capture easily, but we verify no panic
    try printfInt(0, 0, false, false, 0);
    try printfInt(-42, 0, false, false, 0);
    try printfInt(999999, 10, true, false, 0);
    try printfInt(5, 5, false, true, 0);
    try printfInt(5, 0, false, false, '+');
    try printfInt(7, 6, true, false, '+');
}

test "printfUint formatting" {
    // Verify no panics with edge cases
    try printfUint(0, 0, false, false, 10, false);
    try printfUint(255, 0, false, false, 16, false);
    try printfUint(255, 0, false, false, 16, true);
    try printfUint(8, 0, false, false, 8, false);
    try printfUint(42, 10, true, false, 10, false);
}

fn printfFloat(num: f64, width: usize, precision: usize, left_justify: bool, sign_prefix: u8) !void {
    var buf: [64]u8 = undefined;
    const raw = switch (precision) {
        0 => std.fmt.bufPrint(&buf, "{d:.0}", .{num}) catch return,
        1 => std.fmt.bufPrint(&buf, "{d:.1}", .{num}) catch return,
        2 => std.fmt.bufPrint(&buf, "{d:.2}", .{num}) catch return,
        3 => std.fmt.bufPrint(&buf, "{d:.3}", .{num}) catch return,
        4 => std.fmt.bufPrint(&buf, "{d:.4}", .{num}) catch return,
        5 => std.fmt.bufPrint(&buf, "{d:.5}", .{num}) catch return,
        else => std.fmt.bufPrint(&buf, "{d:.6}", .{num}) catch return,
    };

    var sign: u8 = 0;
    var digits: []const u8 = raw;
    if (raw.len > 0 and raw[0] == '-') {
        sign = '-';
        digits = raw[1..];
    } else if (sign_prefix != 0) {
        sign = sign_prefix;
    }
    const total_len = digits.len + @as(usize, if (sign != 0) 1 else 0);
    if (width > 0 and total_len < width) {
        const pad = width - total_len;
        if (left_justify) {
            if (sign != 0) try IO.print("{c}", .{sign});
            try IO.print("{s}", .{digits});
            var p: usize = 0;
            while (p < pad) : (p += 1) try IO.print(" ", .{});
        } else {
            var p: usize = 0;
            while (p < pad) : (p += 1) try IO.print(" ", .{});
            if (sign != 0) try IO.print("{c}", .{sign});
            try IO.print("{s}", .{digits});
        }
    } else {
        if (sign != 0) try IO.print("{c}", .{sign});
        try IO.print("{s}", .{digits});
    }
}
