const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat");
const posix = std.posix;
const common = @import("common.zig");
const types = @import("../../types/mod.zig");
const Value = types.Value;
const IO = @import("../../utils/io.zig").IO;

fn getTimestamp() !i64 {
    if (builtin.os.tag == .windows) {
        const instant = compat.Instant.now() catch return error.TimeUnavailable;
        return @intCast(instant.timestamp / 10_000_000);
    }
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.REALTIME, &ts) != 0) return error.TimeUnavailable;
    return ts.sec;
}

/// Main date subcommand dispatcher (enhanced version)
pub fn dateCmd(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    // If no args or first arg is not a subcommand, delegate to existing date
    if (command.args.len == 0) {
        return dateNow(allocator);
    }
    const subcmd = command.args[0];

    if (std.mem.eql(u8, subcmd, "now")) return dateNow(allocator);
    if (std.mem.eql(u8, subcmd, "format")) return dateFormat(allocator, command);
    if (std.mem.eql(u8, subcmd, "to-record")) return dateToRecord(allocator);
    if (std.mem.eql(u8, subcmd, "humanize")) return dateHumanize(allocator);
    if (std.mem.eql(u8, subcmd, "to-table")) return dateToRecord(allocator);

    // If not a known subcommand, treat as format string for backwards compat
    return dateNow(allocator);
}

fn dateNow(allocator: std.mem.Allocator) !i32 {
    const ts = try getTimestamp();
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(ts) };
    const day = epoch.getDaySeconds();
    const yd = epoch.getEpochDay().calculateYearDay();

    const hours = day.getHoursIntoDay();
    const minutes = day.getMinutesIntoHour();
    const seconds = day.getSecondsIntoMinute();
    const month = yd.calculateMonthDay().month;
    const day_of_month = yd.calculateMonthDay().day_index + 1;

    const result = try std.fmt.allocPrint(allocator, "{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        yd.year,
        @backingInt(month),
        day_of_month,
        hours,
        minutes,
        seconds,
    });
    defer allocator.free(result);
    try IO.print("{s}\n", .{result});
    return 0;
}

fn dateFormat(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    if (command.args.len < 2) {
        try IO.eprint("Usage: date format <format_string>\n  Format: %%Y=year %%m=month %%d=day %%H=hour %%M=min %%S=sec\n", .{});
        return 1;
    }
    const fmt = command.args[1];
    const ts = try getTimestamp();
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(ts) };
    const day = epoch.getDaySeconds();
    const yd = epoch.getEpochDay().calculateYearDay();

    const hours = day.getHoursIntoDay();
    const minutes = day.getMinutesIntoHour();
    const seconds = day.getSecondsIntoMinute();
    const month = yd.calculateMonthDay().month;
    const day_of_month = yd.calculateMonthDay().day_index + 1;

    var result = std.ArrayList(u8).empty;
    defer result.deinit(allocator);

    var i: usize = 0;
    while (i < fmt.len) {
        if (fmt[i] == '%' and i + 1 < fmt.len) {
            switch (fmt[i + 1]) {
                'Y' => {
                    const s = try std.fmt.allocPrint(allocator, "{d}", .{yd.year});
                    defer allocator.free(s);
                    try result.appendSlice(allocator, s);
                },
                'm' => {
                    const s = try std.fmt.allocPrint(allocator, "{d:0>2}", .{@backingInt(month)});
                    defer allocator.free(s);
                    try result.appendSlice(allocator, s);
                },
                'd' => {
                    const s = try std.fmt.allocPrint(allocator, "{d:0>2}", .{day_of_month});
                    defer allocator.free(s);
                    try result.appendSlice(allocator, s);
                },
                'H' => {
                    const s = try std.fmt.allocPrint(allocator, "{d:0>2}", .{hours});
                    defer allocator.free(s);
                    try result.appendSlice(allocator, s);
                },
                'M' => {
                    const s = try std.fmt.allocPrint(allocator, "{d:0>2}", .{minutes});
                    defer allocator.free(s);
                    try result.appendSlice(allocator, s);
                },
                'S' => {
                    const s = try std.fmt.allocPrint(allocator, "{d:0>2}", .{seconds});
                    defer allocator.free(s);
                    try result.appendSlice(allocator, s);
                },
                '%' => try result.append(allocator, '%'),
                else => {
                    try result.append(allocator, fmt[i]);
                    try result.append(allocator, fmt[i + 1]);
                },
            }
            i += 2;
        } else {
            try result.append(allocator, fmt[i]);
            i += 1;
        }
    }

    const output = try result.toOwnedSlice(allocator);
    defer allocator.free(output);
    try IO.print("{s}\n", .{output});
    return 0;
}

fn dateToRecord(allocator: std.mem.Allocator) !i32 {
    const ts = try getTimestamp();
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(ts) };
    const day = epoch.getDaySeconds();
    const yd = epoch.getEpochDay().calculateYearDay();

    const month = yd.calculateMonthDay().month;
    const day_of_month = yd.calculateMonthDay().day_index + 1;

    const keys = try allocator.alloc([]const u8, 6);
    keys[0] = try allocator.dupe(u8, "year");
    keys[1] = try allocator.dupe(u8, "month");
    keys[2] = try allocator.dupe(u8, "day");
    keys[3] = try allocator.dupe(u8, "hour");
    keys[4] = try allocator.dupe(u8, "minute");
    keys[5] = try allocator.dupe(u8, "second");

    const values = try allocator.alloc(Value, 6);
    values[0] = .{ .int = @intCast(yd.year) };
    values[1] = .{ .int = @backingInt(month) };
    values[2] = .{ .int = @intCast(day_of_month) };
    values[3] = .{ .int = @intCast(day.getHoursIntoDay()) };
    values[4] = .{ .int = @intCast(day.getMinutesIntoHour()) };
    values[5] = .{ .int = @intCast(day.getSecondsIntoMinute()) };

    var record = Value{ .record = .{ .keys = keys, .values = values } };
    defer record.deinit(allocator);

    const output = try record.asString(allocator);
    defer allocator.free(output);
    try IO.print("{s}\n", .{output});
    return 0;
}

fn dateHumanize(allocator: std.mem.Allocator) !i32 {
    // Read a timestamp from stdin and humanize it
    const input = common.readAllStdin(allocator) catch {
        try IO.print("now\n", .{});
        return 0;
    };
    defer allocator.free(input);
    const trimmed = std.mem.trim(u8, input, &std.ascii.whitespace);
    const input_ts = std.fmt.parseInt(i64, trimmed, 10) catch {
        try IO.print("now\n", .{});
        return 0;
    };
    const now = try getTimestamp();
    const diff = now - input_ts;

    if (diff < 0) {
        try IO.print("in the future\n", .{});
    } else if (diff < 60) {
        try IO.print("{d} seconds ago\n", .{diff});
    } else if (diff < 3600) {
        try IO.print("{d} minutes ago\n", .{@divTrunc(diff, 60)});
    } else if (diff < 86400) {
        try IO.print("{d} hours ago\n", .{@divTrunc(diff, 3600)});
    } else if (diff < 2592000) {
        try IO.print("{d} days ago\n", .{@divTrunc(diff, 86400)});
    } else {
        try IO.print("{d} months ago\n", .{@divTrunc(diff, 2592000)});
    }
    return 0;
}
