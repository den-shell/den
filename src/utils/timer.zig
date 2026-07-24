const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat");

/// High-precision timer for performance measurement
pub const Timer = struct {
    start_time: compat.Instant,
    name: []const u8,

    /// Start a new timer
    pub fn start(name: []const u8) Timer {
        return .{
            .start_time = compat.Instant.now() catch std.mem.zeroes(compat.Instant),
            .name = name,
        };
    }

    /// Get elapsed time in nanoseconds
    pub fn elapsed(self: *const Timer) u64 {
        const now = compat.Instant.now() catch return 0;
        return now.since(self.start_time);
    }

    /// Get elapsed time in microseconds
    pub fn elapsedMicros(self: *const Timer) u64 {
        return self.elapsed() / 1000;
    }

    /// Get elapsed time in milliseconds
    pub fn elapsedMillis(self: *const Timer) u64 {
        return self.elapsed() / 1_000_000;
    }

    /// Get elapsed time in seconds
    pub fn elapsedSecs(self: *const Timer) f64 {
        return @as(f64, @floatFromInt(self.elapsed())) / 1_000_000_000.0;
    }

    /// Print elapsed time
    pub fn print(self: *const Timer) void {
        const ns = self.elapsed();
        var buf: [256]u8 = undefined;
        var pos: usize = 0;

        // Format "[TIMER] {name}: "
        const prefix = "[TIMER] ";
        const prefix_len = @min(prefix.len, buf.len - pos);
        @memcpy(buf[pos..][0..prefix_len], prefix[0..prefix_len]);
        pos += prefix_len;

        const name_len = @min(self.name.len, buf.len - pos);
        @memcpy(buf[pos..][0..name_len], self.name[0..name_len]);
        pos += name_len;

        const colon = ": ";
        const colon_len = @min(colon.len, buf.len - pos);
        @memcpy(buf[pos..][0..colon_len], colon[0..colon_len]);
        pos += colon_len;

        // Format the time value
        if (ns < 1000) {
            pos += (std.fmt.bufPrint(buf[pos..], "{d}ns\n", .{ns}) catch return).len;
        } else if (ns < 1_000_000) {
            pos += (std.fmt.bufPrint(buf[pos..], "{d:.2}us\n", .{@as(f64, @floatFromInt(ns)) / 1000.0}) catch return).len;
        } else if (ns < 1_000_000_000) {
            pos += (std.fmt.bufPrint(buf[pos..], "{d:.2}ms\n", .{@as(f64, @floatFromInt(ns)) / 1_000_000.0}) catch return).len;
        } else {
            pos += (std.fmt.bufPrint(buf[pos..], "{d:.2}s\n", .{@as(f64, @floatFromInt(ns)) / 1_000_000_000.0}) catch return).len;
        }

        writeStderr(buf[0..pos]);
    }

    /// Reset the timer
    pub fn reset(self: *Timer) void {
        self.start_time = compat.Instant.now() catch std.mem.zeroes(compat.Instant);
    }

    /// Lap time - returns elapsed time and resets
    pub fn lap(self: *Timer) u64 {
        const elapsed_ns = self.elapsed();
        self.reset();
        return elapsed_ns;
    }
};

/// Scoped timer - automatically prints elapsed time when it goes out of scope
pub const ScopedTimer = struct {
    timer: Timer,
    enabled: bool,

    pub fn init(name: []const u8) ScopedTimer {
        return .{
            .timer = Timer.start(name),
            .enabled = builtin.mode == .Debug,
        };
    }

    pub fn deinit(self: *ScopedTimer) void {
        if (self.enabled) {
            self.timer.print();
        }
    }
};

/// Profile a function call
pub fn profile(comptime name: []const u8, func: anytype, args: anytype) @TypeOf(@call(.auto, func, args)) {
    var timer = Timer.start(name);
    defer timer.print();
    return @call(.auto, func, args);
}

/// Timing statistics for multiple measurements
pub const TimingStats = struct {
    name: []const u8,
    samples: std.ArrayList(u64),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8) TimingStats {
        return .{
            .name = name,
            .samples = std.ArrayList(u64).empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TimingStats) void {
        self.samples.deinit(self.allocator);
    }

    pub fn addSample(self: *TimingStats, ns: u64) !void {
        try self.samples.append(self.allocator, ns);
    }

    pub fn mean(self: *const TimingStats) f64 {
        if (self.samples.items.len == 0) return 0.0;
        var sum: u128 = 0;
        for (self.samples.items) |sample| {
            sum += sample;
        }
        return @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(self.samples.items.len));
    }

    pub fn median(self: *TimingStats) u64 {
        if (self.samples.items.len == 0) return 0;

        // Create a copy and sort it
        const copy = self.allocator.dupe(u64, self.samples.items) catch return 0;
        defer self.allocator.free(copy);

        std.mem.sort(u64, copy, {}, std.sort.asc(u64));

        const mid = copy.len / 2;
        if (copy.len % 2 == 0) {
            return (copy[mid - 1] + copy[mid]) / 2;
        } else {
            return copy[mid];
        }
    }

    pub fn min(self: *const TimingStats) u64 {
        if (self.samples.items.len == 0) return 0;
        var min_val = self.samples.items[0];
        for (self.samples.items[1..]) |sample| {
            if (sample < min_val) min_val = sample;
        }
        return min_val;
    }

    pub fn max(self: *const TimingStats) u64 {
        if (self.samples.items.len == 0) return 0;
        var max_val = self.samples.items[0];
        for (self.samples.items[1..]) |sample| {
            if (sample > max_val) max_val = sample;
        }
        return max_val;
    }

    pub fn stddev(self: *const TimingStats) f64 {
        if (self.samples.items.len < 2) return 0.0;

        const mean_val = self.mean();
        var variance: f64 = 0.0;

        for (self.samples.items) |sample| {
            const diff = @as(f64, @floatFromInt(sample)) - mean_val;
            variance += diff * diff;
        }

        variance /= @as(f64, @floatFromInt(self.samples.items.len - 1));
        return @sqrt(variance);
    }

    pub fn print(self: *TimingStats) void {
        if (self.samples.items.len == 0) {
            printStderr("No timing data collected\n");
            return;
        }

        var buf: [1024]u8 = undefined;
        var pos: usize = 0;

        pos += (std.fmt.bufPrint(buf[pos..], "\n=== Timing Statistics: {s} ===\n", .{self.name}) catch return).len;
        pos += (std.fmt.bufPrint(buf[pos..], "Samples:  {d}\n", .{self.samples.items.len}) catch return).len;
        pos += (std.fmt.bufPrint(buf[pos..], "Mean:     {d:.2}ms\n", .{self.mean() / 1_000_000.0}) catch return).len;
        pos += (std.fmt.bufPrint(buf[pos..], "Median:   {d:.2}ms\n", .{@as(f64, @floatFromInt(self.median())) / 1_000_000.0}) catch return).len;
        pos += (std.fmt.bufPrint(buf[pos..], "Min:      {d:.2}ms\n", .{@as(f64, @floatFromInt(self.min())) / 1_000_000.0}) catch return).len;
        pos += (std.fmt.bufPrint(buf[pos..], "Max:      {d:.2}ms\n", .{@as(f64, @floatFromInt(self.max())) / 1_000_000.0}) catch return).len;
        pos += (std.fmt.bufPrint(buf[pos..], "Std Dev:  {d:.2}ms\n", .{self.stddev() / 1_000_000.0}) catch return).len;

        writeStderr(buf[0..pos]);
    }
};

/// Performance profiler for tracking multiple operations
pub const Profiler = struct {
    allocator: std.mem.Allocator,
    timers: std.StringHashMap(*TimingStats),

    pub fn init(allocator: std.mem.Allocator) Profiler {
        return .{
            .allocator = allocator,
            .timers = std.StringHashMap(*TimingStats).init(allocator),
        };
    }

    pub fn deinit(self: *Profiler) void {
        var it = self.timers.valueIterator();
        while (it.next()) |stats| {
            stats.*.deinit();
            self.allocator.destroy(stats.*);
        }
        self.timers.deinit();
    }

    pub fn startTimer(_: *Profiler, name: []const u8) Timer {
        return Timer.start(name);
    }

    pub fn recordTiming(self: *Profiler, name: []const u8, ns: u64) !void {
        var stats = self.timers.get(name);
        if (stats == null) {
            const new_stats = try self.allocator.create(TimingStats);
            new_stats.* = TimingStats.init(self.allocator, name);
            try self.timers.put(name, new_stats);
            stats = new_stats;
        }
        try stats.?.addSample(ns);
    }

    pub fn printAll(self: *Profiler) void {
        var it = self.timers.valueIterator();
        while (it.next()) |stats| {
            stats.*.print();
        }
    }

    pub fn getStats(self: *Profiler, name: []const u8) ?*TimingStats {
        return self.timers.get(name);
    }
};

/// Helper to write to stderr
fn writeStderr(msg: []const u8) void {
    const stderr = std.Io.File{ .handle = if (builtin.os.tag == .windows)
        (@import("windows_compat").GetStdHandle(@import("windows_compat").STD_ERROR_HANDLE) orelse return)
    else
        std.posix.STDERR_FILENO, .flags = .{ .nonblocking = false } };
    stderr.writeStreamingAll(std.Options.debug_io, msg) catch {};
}

fn printStderr(msg: []const u8) void {
    writeStderr(msg);
}

/// Macro to time a block of code
pub fn timed(comptime name: []const u8, comptime block: anytype) void {
    var timer = Timer.start(name);
    defer timer.print();
    block();
}
