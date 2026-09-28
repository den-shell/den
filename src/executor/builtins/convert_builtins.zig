const std = @import("std");
const posix = std.posix;
const types = @import("../../types/mod.zig");
const IO = @import("../../utils/io.zig").IO;
const value_mod = @import("../../types/value.zig");
const common = @import("common.zig");

/// Main into subcommand dispatcher
pub fn intoCmd(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    if (command.args.len == 0) {
        try IO.eprint("Usage: into <type> [input]\n  Types: int, string, float, bool, datetime, duration, filesize, binary\n", .{});
        return 1;
    }
    const target_type = command.args[0];
    const input_arg = if (command.args.len > 1) command.args[1] else null;

    const input = if (input_arg) |arg|
        try allocator.dupe(u8, arg)
    else blk: {
        const raw = try common.readAllStdin(allocator);
        const trimmed = std.mem.trimEnd(u8, raw, "\n");
        if (trimmed.len < raw.len) {
            const result = try allocator.dupe(u8, trimmed);
            allocator.free(raw);
            break :blk result;
        }
        break :blk raw;
    };
    defer allocator.free(input);

    if (std.mem.eql(u8, target_type, "int")) return intoInt(input);
    if (std.mem.eql(u8, target_type, "string")) return intoString(input);
    if (std.mem.eql(u8, target_type, "float")) return intoFloat(input);
    if (std.mem.eql(u8, target_type, "bool")) return intoBool(input);
    if (std.mem.eql(u8, target_type, "datetime")) return intoDatetime(allocator, input);
    if (std.mem.eql(u8, target_type, "duration")) return intoDuration(allocator, input);
    if (std.mem.eql(u8, target_type, "filesize")) return intoFilesize(allocator, input);
    if (std.mem.eql(u8, target_type, "binary")) return intoBinary(allocator, input);

    try IO.eprint("Unknown type: {s}\n", .{target_type});
    return 1;
}

fn intoInt(input: []const u8) !i32 {
    // Try direct integer parse
    if (std.fmt.parseInt(i64, input, 10)) |i| {
        try IO.print("{d}\n", .{i});
        return 0;
    } else |_| {}
    // Try float -> int
    if (std.fmt.parseFloat(f64, input)) |f| {
        if (std.math.isNan(f) or std.math.isInf(f) or f > @as(f64, @floatFromInt(std.math.maxInt(i64))) or f < @as(f64, @floatFromInt(std.math.minInt(i64)))) {
            try IO.eprint("Error: cannot convert '{s}' to int (out of range)\n", .{input});
            return 1;
        }
        try IO.print("{d}\n", .{@as(i64, @intFromFloat(f))});
        return 0;
    } else |_| {}
    // Bool
    if (std.mem.eql(u8, input, "true")) {
        try IO.print("1\n", .{});
        return 0;
    }
    if (std.mem.eql(u8, input, "false")) {
        try IO.print("0\n", .{});
        return 0;
    }
    // Hex
    if (std.mem.startsWith(u8, input, "0x")) {
        if (std.fmt.parseInt(i64, input[2..], 16)) |i| {
            try IO.print("{d}\n", .{i});
            return 0;
        } else |_| {}
    }
    try IO.eprint("Error: cannot convert '{s}' to int\n", .{input});
    return 1;
}

fn intoString(input: []const u8) !i32 {
    try IO.print("{s}\n", .{input});
    return 0;
}

fn intoFloat(input: []const u8) !i32 {
    if (std.fmt.parseFloat(f64, input)) |f| {
        try IO.print("{d}\n", .{f});
        return 0;
    } else |_| {}
    if (std.mem.eql(u8, input, "true")) {
        try IO.print("1.0\n", .{});
        return 0;
    }
    if (std.mem.eql(u8, input, "false")) {
        try IO.print("0.0\n", .{});
        return 0;
    }
    try IO.eprint("Error: cannot convert '{s}' to float\n", .{input});
    return 1;
}

fn intoBool(input: []const u8) !i32 {
    if (std.mem.eql(u8, input, "true") or std.mem.eql(u8, input, "1") or
        std.mem.eql(u8, input, "yes"))
    {
        try IO.print("true\n", .{});
        return 0;
    }
    if (std.mem.eql(u8, input, "false") or std.mem.eql(u8, input, "0") or
        std.mem.eql(u8, input, "no") or input.len == 0)
    {
        try IO.print("false\n", .{});
        return 0;
    }
    try IO.eprint("Error: cannot convert '{s}' to bool\n", .{input});
    return 1;
}

fn intoDatetime(allocator: std.mem.Allocator, input: []const u8) !i32 {
    // Try parsing as unix timestamp
    if (std.fmt.parseInt(i64, input, 10)) |ts| {
        if (ts < 0) {
            try IO.eprint("Error: negative timestamps (before 1970) not supported\n", .{});
            return 1;
        }
        const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(ts) };
        const day = epoch.getDaySeconds();
        const yd = epoch.getEpochDay().calculateYearDay();
        const month = yd.calculateMonthDay().month;
        const day_of_month = yd.calculateMonthDay().day_index + 1;

        const result = try std.fmt.allocPrint(allocator, "{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
            yd.year,
            @backingInt(month),
            day_of_month,
            day.getHoursIntoDay(),
            day.getMinutesIntoHour(),
            day.getSecondsIntoMinute(),
        });
        defer allocator.free(result);
        try IO.print("{s}\n", .{result});
        return 0;
    } else |_| {}
    try IO.eprint("Error: cannot convert '{s}' to datetime\n", .{input});
    return 1;
}

fn intoDuration(allocator: std.mem.Allocator, input: []const u8) !i32 {
    if (value_mod.parseDuration(input)) |nanos| {
        const formatted = try std.fmt.allocPrint(allocator, "{d}ns", .{nanos});
        defer allocator.free(formatted);
        try IO.print("{s}\n", .{formatted});
        return 0;
    }
    // Try as plain number (assume seconds)
    if (std.fmt.parseInt(i64, input, 10)) |secs| {
        const nanos = secs * 1_000_000_000;
        const formatted = try std.fmt.allocPrint(allocator, "{d}ns ({d}sec)", .{ nanos, secs });
        defer allocator.free(formatted);
        try IO.print("{s}\n", .{formatted});
        return 0;
    } else |_| {}
    try IO.eprint("Error: cannot convert '{s}' to duration\n", .{input});
    return 1;
}

fn intoFilesize(allocator: std.mem.Allocator, input: []const u8) !i32 {
    if (value_mod.parseFilesize(input)) |bytes| {
        var val = types.Value{ .filesize = bytes };
        const formatted = try val.asString(allocator);
        defer allocator.free(formatted);
        try IO.print("{s}\n", .{formatted});
        return 0;
    }
    // Try as plain number (assume bytes)
    if (std.fmt.parseInt(u64, input, 10)) |bytes| {
        var val = types.Value{ .filesize = bytes };
        const formatted = try val.asString(allocator);
        defer allocator.free(formatted);
        try IO.print("{s}\n", .{formatted});
        return 0;
    } else |_| {}
    try IO.eprint("Error: cannot convert '{s}' to filesize\n", .{input});
    return 1;
}

fn intoBinary(allocator: std.mem.Allocator, input: []const u8) !i32 {
    // Show hex representation
    const result = try allocator.alloc(u8, input.len * 3);
    defer allocator.free(result);
    for (input, 0..) |byte, i| {
        const hex = "0123456789ABCDEF";
        result[i * 3] = hex[byte >> 4];
        result[i * 3 + 1] = hex[byte & 0x0f];
        result[i * 3 + 2] = if (i < input.len - 1) ' ' else '\n';
    }
    try IO.print("{s}", .{result});
    return 0;
}
