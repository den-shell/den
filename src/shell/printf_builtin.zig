//! Printf Builtin Implementation
//!
//! This module implements the printf builtin command with full format string support.

const std = @import("std");
const builtin = @import("builtin");
const IO = @import("../utils/io.zig").IO;
const types = @import("../types/mod.zig");

const is_windows = builtin.os.tag == .windows;

// Forward declaration for Shell type
const Shell = @import("../shell.zig").Shell;

/// Parse an integer argument with auto-detection of base.
/// Handles 0x/0X prefix for hex, 0 prefix for octal, and plain decimal.
/// Also handles character constants like 'A' or "A".
fn parseIntArg(comptime T: type, arg: []const u8) T {
    if (arg.len >= 2 and (arg[0] == '\'' or arg[0] == '"')) {
        return @as(T, arg[1]);
    }
    if (arg.len >= 2 and arg[0] == '0' and (arg[1] == 'x' or arg[1] == 'X')) {
        return std.fmt.parseInt(T, arg[2..], 16) catch 0;
    } else if (arg.len >= 2 and arg[0] == '0' and std.ascii.isDigit(arg[1])) {
        return std.fmt.parseInt(T, arg[1..], 8) catch 0;
    }
    return std.fmt.parseInt(T, arg, 10) catch 0;
}

/// Builtin: printf - formatted output with full format string support
pub fn builtinPrintf(shell: *Shell, cmd: *types.ParsedCommand) !void {
    if (cmd.args.len == 0) {
        return;
    }

    // Handle -v flag: printf -v varname format args...
    var var_name: ?[]const u8 = null;
    var format_idx: usize = 0;
    if (cmd.args.len >= 3 and std.mem.eql(u8, cmd.args[0], "-v")) {
        var_name = cmd.args[1];
        format_idx = 2;
    }

    const format = cmd.args[format_idx];
    var arg_idx: usize = format_idx + 1;

    // For -v flag: redirect stdout to a pipe to capture output
    var saved_stdout: c_int = -1;
    var pipe_fds: [2]c_int = .{ -1, -1 };
    if (!is_windows) {
        if (var_name != null) {
            if (std.c.pipe(&pipe_fds) == 0) {
                saved_stdout = std.c.dup(std.posix.STDOUT_FILENO);
                _ = std.c.dup2(pipe_fds[1], std.posix.STDOUT_FILENO);
                _ = std.c.close(pipe_fds[1]);
                pipe_fds[1] = -1;
            }
        }
    }

    // In bash, printf reuses the format string for remaining arguments
    // e.g., printf "%s\n" a b c prints a\nb\nc
    var did_consume_arg = true;
    while (did_consume_arg) {
        did_consume_arg = false;
        if (arg_idx >= cmd.args.len and arg_idx > 1) break;

        var i: usize = 0;
        while (i < format.len) {
            if (format[i] == '%' and i + 1 < format.len) {
                // Parse optional flags, width, and precision
                var j = i + 1;
                var left_justify = false;
                var zero_pad = false;
                var force_sign = false;
                var space_sign = false;
                var width: usize = 0;
                var precision: usize = 6; // Default precision for floats
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
                        j += 1; // '#' alt-form not supported
                    } else {
                        break;
                    }
                }
                // '+' takes precedence over ' ' (C printf semantics).
                const sign_prefix: u8 = if (force_sign) '+' else if (space_sign) ' ' else 0;

                // Parse width - support * (take from next argument)
                if (j < format.len and format[j] == '*') {
                    if (arg_idx < cmd.args.len) {
                        width = @intCast(@max(std.fmt.parseInt(i64, cmd.args[arg_idx], 10) catch 0, 0));
                        arg_idx += 1;
                        did_consume_arg = true;
                    }
                    j += 1;
                } else {
                    while (j < format.len and format[j] >= '0' and format[j] <= '9') {
                        width = width * 10 + (format[j] - '0');
                        j += 1;
                    }
                }

                // Parse precision - support .* (take from next argument)
                if (j < format.len and format[j] == '.') {
                    j += 1;
                    precision = 0;
                    has_precision = true;
                    if (j < format.len and format[j] == '*') {
                        if (arg_idx < cmd.args.len) {
                            precision = @intCast(@max(std.fmt.parseInt(i64, cmd.args[arg_idx], 10) catch 0, 0));
                            arg_idx += 1;
                            did_consume_arg = true;
                        }
                        j += 1;
                    } else {
                        while (j < format.len and format[j] >= '0' and format[j] <= '9') {
                            precision = precision * 10 + (format[j] - '0');
                            j += 1;
                        }
                    }
                }

                if (j >= format.len) {
                    try IO.print("{c}", .{format[i]});
                    i += 1;
                    continue;
                }

                const spec = format[j];
                if (spec == 's') {
                    // String format
                    if (arg_idx < cmd.args.len) {
                        var str = cmd.args[arg_idx];
                        // Apply precision (truncate)
                        if (has_precision and str.len > precision) {
                            str = str[0..precision];
                        }
                        // Apply width (padding)
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
                        did_consume_arg = true;
                    }
                    i = j + 1;
                } else if (spec == 'd' or spec == 'i') {
                    // Integer format
                    if (arg_idx < cmd.args.len) {
                        const arg = cmd.args[arg_idx];
                        const num = parseIntArg(i64, arg);
                        try printfInt(num, width, zero_pad, left_justify, sign_prefix, if (has_precision) precision else null);
                        arg_idx += 1;
                        did_consume_arg = true;
                    }
                    i = j + 1;
                } else if (spec == 'u') {
                    // Unsigned integer format
                    if (arg_idx < cmd.args.len) {
                        const arg = cmd.args[arg_idx];
                        const num = parseIntArg(u64, arg);
                        try printfUint(num, width, zero_pad, left_justify, 10, false);
                        arg_idx += 1;
                        did_consume_arg = true;
                    }
                    i = j + 1;
                } else if (spec == 'x') {
                    // Hex lowercase
                    if (arg_idx < cmd.args.len) {
                        const arg = cmd.args[arg_idx];
                        const num = parseIntArg(u64, arg);
                        try printfUint(num, width, zero_pad, left_justify, 16, false);
                        arg_idx += 1;
                        did_consume_arg = true;
                    }
                    i = j + 1;
                } else if (spec == 'X') {
                    // Hex uppercase
                    if (arg_idx < cmd.args.len) {
                        const arg = cmd.args[arg_idx];
                        const num = parseIntArg(u64, arg);
                        try printfUint(num, width, zero_pad, left_justify, 16, true);
                        arg_idx += 1;
                        did_consume_arg = true;
                    }
                    i = j + 1;
                } else if (spec == 'o') {
                    // Octal format
                    if (arg_idx < cmd.args.len) {
                        const arg = cmd.args[arg_idx];
                        const num = parseIntArg(u64, arg);
                        try printfUint(num, width, zero_pad, left_justify, 8, false);
                        arg_idx += 1;
                        did_consume_arg = true;
                    }
                    i = j + 1;
                } else if (spec == 'c') {
                    // Character format
                    if (arg_idx < cmd.args.len) {
                        const arg = cmd.args[arg_idx];
                        if (arg.len > 0) {
                            try IO.print("{c}", .{arg[0]});
                        }
                        arg_idx += 1;
                        did_consume_arg = true;
                    }
                    i = j + 1;
                } else if (spec == 'f' or spec == 'F') {
                    // Float format
                    if (arg_idx < cmd.args.len) {
                        const num = std.fmt.parseFloat(f64, cmd.args[arg_idx]) catch 0.0;
                        try printfFloat(num, width, precision, left_justify, sign_prefix);
                        arg_idx += 1;
                        did_consume_arg = true;
                    }
                    i = j + 1;
                } else if (spec == 'e' or spec == 'E') {
                    // Scientific notation
                    if (arg_idx < cmd.args.len) {
                        const num = std.fmt.parseFloat(f64, cmd.args[arg_idx]) catch 0.0;
                        try printfScientific(num, width, precision, left_justify, spec == 'E');
                        arg_idx += 1;
                        did_consume_arg = true;
                    }
                    i = j + 1;
                } else if (spec == 'g' or spec == 'G') {
                    // Shortest representation (float or scientific)
                    if (arg_idx < cmd.args.len) {
                        const num = std.fmt.parseFloat(f64, cmd.args[arg_idx]) catch 0.0;
                        // Use scientific if exponent < -4 or >= precision
                        const abs_num = @abs(num);
                        if (abs_num != 0 and (abs_num < 0.0001 or abs_num >= std.math.pow(f64, 10.0, @floatFromInt(precision)))) {
                            try printfScientific(num, width, if (precision > 0) precision - 1 else 0, left_justify, spec == 'G');
                        } else {
                            try printfFloat(num, width, precision, left_justify, sign_prefix);
                        }
                        arg_idx += 1;
                        did_consume_arg = true;
                    }
                    i = j + 1;
                } else if (spec == '%') {
                    // Escaped %
                    try IO.print("%", .{});
                    i = j + 1;
                } else if (spec == 'b') {
                    // String with escape interpretation (bash extension)
                    if (arg_idx < cmd.args.len) {
                        try printWithEscapes(cmd.args[arg_idx]);
                        arg_idx += 1;
                        did_consume_arg = true;
                    }
                    i = j + 1;
                } else if (spec == 'q') {
                    // Shell-quoted string (bash extension)
                    // Escape embedded single quotes as '\'' for safe re-evaluation
                    if (arg_idx < cmd.args.len) {
                        const arg = cmd.args[arg_idx];
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
                        did_consume_arg = true;
                    }
                    i = j + 1;
                } else {
                    // Unknown format, just print it
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
                        // Octal escape
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
                        // Hex escape \xN or \xNN (1-2 hex digits)
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
                    'u' => {
                        // Unicode escape \uHHHH (1-4 hex digits) -> UTF-8
                        var codepoint: u21 = 0;
                        var hex_count: usize = 0;
                        var k: usize = i + 2;
                        while (k < format.len and hex_count < 4) : (k += 1) {
                            const c = format[k];
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
                            const utf8_len = std.unicode.utf8Encode(codepoint, &utf8_buf) catch 0;
                            if (utf8_len > 0) {
                                try IO.print("{s}", .{utf8_buf[0..utf8_len]});
                            }
                            i = k;
                            continue;
                        } else {
                            try IO.print("{c}", .{format[i]});
                            i += 1;
                            continue;
                        }
                    },
                    'U' => {
                        // Unicode escape \UHHHHHHHH (1-8 hex digits) -> UTF-8
                        var codepoint: u21 = 0;
                        var hex_count: usize = 0;
                        var k: usize = i + 2;
                        while (k < format.len and hex_count < 8) : (k += 1) {
                            const c = format[k];
                            const digit: u32 = if (c >= '0' and c <= '9')
                                c - '0'
                            else if (c >= 'a' and c <= 'f')
                                c - 'a' + 10
                            else if (c >= 'A' and c <= 'F')
                                c - 'A' + 10
                            else
                                break;
                            const new_cp = @as(u32, codepoint) * 16 + digit;
                            if (new_cp > 0x10FFFF) break; // Max Unicode codepoint
                            codepoint = @intCast(new_cp);
                            hex_count += 1;
                        }
                        if (hex_count > 0) {
                            var utf8_buf: [4]u8 = undefined;
                            const utf8_len = std.unicode.utf8Encode(codepoint, &utf8_buf) catch 0;
                            if (utf8_len > 0) {
                                try IO.print("{s}", .{utf8_buf[0..utf8_len]});
                            }
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
    } // end outer while (did_consume_arg) loop for format reuse

    // For -v flag: read captured output and store in variable
    if (var_name) |vname| {
        if (!is_windows and saved_stdout >= 0) {
            // Restore stdout
            _ = std.c.dup2(saved_stdout, std.posix.STDOUT_FILENO);
            _ = std.c.close(saved_stdout);

            // Read captured output from pipe
            if (pipe_fds[0] >= 0) {
                var result_buf: [4096]u8 = undefined;
                const n = std.c.read(pipe_fds[0], &result_buf, result_buf.len);
                _ = std.c.close(pipe_fds[0]);
                if (n > 0) {
                    const output = result_buf[0..@intCast(n)];
                    // Store in shell variable
                    const val = shell.allocator.dupe(u8, output) catch return;
                    const gop = shell.environment.getOrPut(vname) catch {
                        shell.allocator.free(val);
                        return;
                    };
                    if (gop.found_existing) {
                        shell.allocator.free(gop.value_ptr.*);
                    } else {
                        gop.key_ptr.* = shell.allocator.dupe(u8, vname) catch {
                            shell.allocator.free(val);
                            return;
                        };
                    }
                    gop.value_ptr.* = val;
                }
            }
        }
    }
}

/// Helper for printf - format signed integer with width/padding
pub fn printfInt(num: i64, width: usize, zero_pad: bool, left_justify: bool, sign_prefix: u8, precision: ?usize) !void {
    var buf: [32]u8 = undefined;
    const raw = std.fmt.bufPrint(&buf, "{d}", .{num}) catch return;
    // Split off the sign so width/zero-pad logic operates on the digits.
    // For non-negative values, `sign_prefix` ('+' or ' ') applies the +/space flag.
    var sign: u8 = 0;
    var digits: []const u8 = raw;
    if (num < 0) {
        sign = '-';
        digits = raw[1..];
    } else if (sign_prefix != 0) {
        sign = sign_prefix;
    }
    // Precision for integers is the *minimum* digit count (zero-filled); when
    // present, the '0' width flag is ignored (POSIX). `%.0d` of 0 prints nothing.
    var prec_buf: [64]u8 = undefined;
    var use_zero_pad = zero_pad;
    if (precision) |prec| {
        use_zero_pad = false;
        if (prec == 0 and num == 0) {
            digits = "";
        } else if (digits.len < prec and prec <= prec_buf.len) {
            const zeros = prec - digits.len;
            var z: usize = 0;
            while (z < zeros) : (z += 1) prec_buf[z] = '0';
            @memcpy(prec_buf[zeros..][0..digits.len], digits);
            digits = prec_buf[0 .. zeros + digits.len];
        }
    }
    const total_len = digits.len + @as(usize, if (sign != 0) 1 else 0);
    if (width > 0 and total_len < width) {
        const pad = width - total_len;
        if (left_justify) {
            if (sign != 0) try IO.print("{c}", .{sign});
            try IO.print("{s}", .{digits});
            var p: usize = 0;
            while (p < pad) : (p += 1) try IO.print(" ", .{});
        } else if (use_zero_pad) {
            // Zero-pad: place zeros after the sign but before the digits
            // e.g., printf "%05d" -1 -> "-0001", printf "%+05d" 1 -> "+0001"
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

/// Helper for printf - format unsigned integer with base and width
pub fn printfUint(num: u64, width: usize, zero_pad: bool, left_justify: bool, base: u8, uppercase: bool) !void {
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

/// Helper for printf - format float with precision and width
pub fn printfFloat(num: f64, width: usize, precision: usize, left_justify: bool, sign_prefix: u8) !void {
    var buf: [64]u8 = undefined;
    // Zig doesn't support runtime precision, so use fixed cases
    const raw = switch (precision) {
        0 => std.fmt.bufPrint(&buf, "{d:.0}", .{num}) catch return,
        1 => std.fmt.bufPrint(&buf, "{d:.1}", .{num}) catch return,
        2 => std.fmt.bufPrint(&buf, "{d:.2}", .{num}) catch return,
        3 => std.fmt.bufPrint(&buf, "{d:.3}", .{num}) catch return,
        4 => std.fmt.bufPrint(&buf, "{d:.4}", .{num}) catch return,
        5 => std.fmt.bufPrint(&buf, "{d:.5}", .{num}) catch return,
        else => std.fmt.bufPrint(&buf, "{d:.6}", .{num}) catch return,
    };

    // Apply the +/space flag to non-negative values, keeping the sign attached
    // to the digits so width padding stays correct.
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

/// Helper for printf - format float in scientific notation (%e / %E)
pub fn printfScientific(num: f64, width: usize, precision: usize, left_justify: bool, uppercase: bool) !void {
    // Compute mantissa and exponent manually
    var buf: [128]u8 = undefined;
    const abs_num = @abs(num);
    var exp_val: i32 = 0;
    var mantissa = abs_num;

    if (abs_num != 0.0 and !std.math.isNan(abs_num) and !std.math.isInf(abs_num)) {
        exp_val = @intFromFloat(@floor(std.math.log10(abs_num)));
        mantissa = abs_num / std.math.pow(f64, 10.0, @floatFromInt(exp_val));
        // Normalize: ensure 1.0 <= mantissa < 10.0
        if (mantissa >= 10.0) {
            mantissa /= 10.0;
            exp_val += 1;
        } else if (mantissa < 1.0 and mantissa > 0.0) {
            mantissa *= 10.0;
            exp_val -= 1;
        }
    }

    if (num < 0) mantissa = -mantissa;

    // Format mantissa with precision
    const mant_str = switch (precision) {
        0 => std.fmt.bufPrint(&buf, "{d:.0}", .{mantissa}) catch return,
        1 => std.fmt.bufPrint(&buf, "{d:.1}", .{mantissa}) catch return,
        2 => std.fmt.bufPrint(&buf, "{d:.2}", .{mantissa}) catch return,
        3 => std.fmt.bufPrint(&buf, "{d:.3}", .{mantissa}) catch return,
        4 => std.fmt.bufPrint(&buf, "{d:.4}", .{mantissa}) catch return,
        5 => std.fmt.bufPrint(&buf, "{d:.5}", .{mantissa}) catch return,
        else => std.fmt.bufPrint(&buf, "{d:.6}", .{mantissa}) catch return,
    };

    // Format exponent
    var exp_buf: [16]u8 = undefined;
    const e_char: u8 = if (uppercase) 'E' else 'e';
    const exp_str = if (exp_val >= 0)
        std.fmt.bufPrint(&exp_buf, "{c}+{d:0>2}", .{ e_char, exp_val }) catch return
    else
        std.fmt.bufPrint(&exp_buf, "{c}-{d:0>2}", .{ e_char, -exp_val }) catch return;

    // Combine and apply width
    var full_buf: [160]u8 = undefined;
    const full = std.fmt.bufPrint(&full_buf, "{s}{s}", .{ mant_str, exp_str }) catch return;

    if (width > 0 and full.len < width) {
        const pad = width - full.len;
        if (left_justify) {
            try IO.print("{s}", .{full});
            var p: usize = 0;
            while (p < pad) : (p += 1) try IO.print(" ", .{});
        } else {
            var p: usize = 0;
            while (p < pad) : (p += 1) try IO.print(" ", .{});
            try IO.print("{s}", .{full});
        }
    } else {
        try IO.print("{s}", .{full});
    }
}

/// Helper for printf %b - print string with escape interpretation
pub fn printWithEscapes(str: []const u8) !void {
    var i: usize = 0;
    while (i < str.len) {
        if (str[i] == '\\' and i + 1 < str.len) {
            switch (str[i + 1]) {
                'n' => try IO.print("\n", .{}),
                't' => try IO.print("\t", .{}),
                'r' => try IO.print("\r", .{}),
                '\\' => try IO.print("\\", .{}),
                'a' => try IO.print("\x07", .{}),
                'b' => try IO.print("\x08", .{}),
                'f' => try IO.print("\x0c", .{}),
                'v' => try IO.print("\x0b", .{}),
                'e' => try IO.print("\x1b", .{}),
                'c' => return,
                '0' => {
                    // Octal escape \0NNN (up to 3 octal digits)
                    var val: u8 = 0;
                    var k: usize = i + 2;
                    var count: usize = 0;
                    while (k < str.len and count < 3) : (k += 1) {
                        if (str[k] >= '0' and str[k] <= '7') {
                            val = val * 8 + (str[k] - '0');
                            count += 1;
                        } else break;
                    }
                    try IO.print("{c}", .{val});
                    i = k;
                    continue;
                },
                'x' => {
                    // Hex escape \xH or \xHH (1 or 2 hex digits)
                    var val: u8 = 0;
                    var k: usize = i + 2;
                    var count: usize = 0;
                    while (k < str.len and count < 2) : (k += 1) {
                        const c = str[k];
                        if (c >= '0' and c <= '9') {
                            val = val * 16 + (c - '0');
                            count += 1;
                        } else if (c >= 'a' and c <= 'f') {
                            val = val * 16 + (c - 'a' + 10);
                            count += 1;
                        } else if (c >= 'A' and c <= 'F') {
                            val = val * 16 + (c - 'A' + 10);
                            count += 1;
                        } else break;
                    }
                    if (count > 0) {
                        try IO.print("{c}", .{val});
                        i = k;
                        continue;
                    } else {
                        // No valid hex digits after \x, print literally
                        try IO.print("{c}", .{str[i]});
                        i += 1;
                        continue;
                    }
                },
                else => {
                    try IO.print("{c}", .{str[i]});
                    i += 1;
                    continue;
                },
            }
            i += 2;
        } else {
            try IO.print("{c}", .{str[i]});
            i += 1;
        }
    }
}
