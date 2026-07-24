const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat");

/// Stack trace configuration
pub const Config = struct {
    max_depth: usize = 64,
    use_color: bool = true,
    show_addresses: bool = true,
    show_module: bool = true,
};

/// Captured stack trace
pub const StackTrace = struct {
    addresses: []usize,
    count: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, max_depth: usize) !StackTrace {
        const addresses = try allocator.alloc(usize, max_depth);
        return .{
            .addresses = addresses,
            .count = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *StackTrace) void {
        self.allocator.free(self.addresses);
    }

    /// Capture the current stack trace
    pub fn capture(self: *StackTrace, skip_frames: usize) void {
        _ = skip_frames;
        // Stack trace capture is not available in Zig 0.16
        // Just set count to 0 as a stub
        self.count = 0;
    }

    /// Format the stack trace
    pub fn format(
        self: StackTrace,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.writeAll("Stack trace:\n");
        for (self.addresses[0..self.count], 0..) |addr, i| {
            try writer.print("  [{d}] 0x{x:0>16}\n", .{ i, addr });
        }
    }

    /// Print the stack trace with detailed formatting
    pub fn print(self: *const StackTrace, config: Config) void {
        const Color = struct {
            const reset = "\x1b[0m";
            const bold = "\x1b[1m";
            const dim = "\x1b[2m";
            const cyan = "\x1b[36m";
            const yellow = "\x1b[33m";
        };

        var buf: [4096]u8 = undefined;
        var pos: usize = 0;

        // Header
        if (config.use_color) {
            if (std.fmt.bufPrint(buf[pos..], "{s}{s}Stack Trace:{s}\n", .{ Color.bold, Color.cyan, Color.reset })) |result| {
                pos += result.len;
            } else |_| return;
        } else {
            const header = "Stack Trace:\n";
            if (pos + header.len <= buf.len) {
                @memcpy(buf[pos..][0..header.len], header);
                pos += header.len;
            }
        }

        // Print each frame
        for (self.addresses[0..self.count], 0..) |addr, i| {
            if (config.use_color) {
                if (std.fmt.bufPrint(buf[pos..], "  {s}[{d}]{s} ", .{ Color.yellow, i, Color.reset })) |result| {
                    pos += result.len;
                } else |_| continue;
            } else {
                if (std.fmt.bufPrint(buf[pos..], "  [{d}] ", .{i})) |result| {
                    pos += result.len;
                } else |_| continue;
            }

            if (config.show_addresses) {
                if (std.fmt.bufPrint(buf[pos..], "0x{x:0>16}", .{addr})) |result| {
                    pos += result.len;
                } else |_| continue;
            }

            if (pos < buf.len) {
                buf[pos] = '\n';
                pos += 1;
            }
        }

        writeStderr(buf[0..pos]);
    }
};

/// Print current stack trace
pub fn printCurrentStackTrace(config: Config) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stack = StackTrace.init(allocator, config.max_depth) catch return;
    defer stack.deinit();

    stack.capture(1); // Skip this frame
    stack.print(config);
}

/// Panic handler that prints a formatted stack trace
pub fn panicWithStackTrace(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    _ = error_return_trace;
    _ = ret_addr;

    var buf: [4096]u8 = undefined;
    const output = std.fmt.bufPrint(&buf, "\n\x1b[1m\x1b[31mPANIC:\x1b[0m {s}\n\n", .{msg}) catch "";

    writeStderr(output);

    // Print stack trace
    printCurrentStackTrace(.{
        .use_color = true,
        .show_addresses = true,
        .show_module = true,
    });

    std.process.abort();
}

/// Helper to write to stderr
fn writeStderr(msg: []const u8) void {
    const stderr = std.Io.File{ .handle = if (builtin.os.tag == .windows)
        (@import("windows_compat").GetStdHandle(@import("windows_compat").STD_ERROR_HANDLE) orelse return)
    else
        std.posix.STDERR_FILENO, .flags = .{ .nonblocking = false } };
    stderr.writeStreamingAll(std.Options.debug_io, msg) catch {};
}

/// Helper to get milliseconds since some reference point
fn getMilliTimestamp() i64 {
    const now = compat.Instant.now() catch return 0;
    // sec * 1000 + nsec / 1_000_000 already yields milliseconds as the
    // arithmetic is performed on signed integer fields; the previous
    // @divFloor(x, 1) and @intCast were both no-ops.
    return now.timestamp.sec * 1000 + @divFloor(now.timestamp.nsec, 1_000_000);
}

/// Trace point for debugging execution flow
pub const TracePoint = struct {
    name: []const u8,
    file: []const u8,
    line: u32,
    time: i64,

    pub fn init(comptime src: std.builtin.SourceLocation, name: []const u8) TracePoint {
        return .{
            .name = name,
            .file = src.file,
            .line = src.line,
            .time = getMilliTimestamp(),
        };
    }

    pub fn print(self: TracePoint) void {
        var buf: [256]u8 = undefined;
        const output = std.fmt.bufPrint(&buf, "[TRACE] {s} at {s}:{d} (t={d}ms)\n", .{
            self.name,
            self.file,
            self.line,
            self.time,
        }) catch return;

        writeStderr(output);
    }
};

/// Execution trace - tracks a series of trace points
pub const ExecutionTrace = struct {
    allocator: std.mem.Allocator,
    points: std.array_list.Managed(TracePoint),
    start_time: i64,

    pub fn init(allocator: std.mem.Allocator) ExecutionTrace {
        return .{
            .allocator = allocator,
            .points = std.array_list.Managed(TracePoint).init(allocator),
            .start_time = getMilliTimestamp(),
        };
    }

    pub fn deinit(self: *ExecutionTrace) void {
        self.points.deinit();
    }

    pub fn addPoint(self: *ExecutionTrace, point: TracePoint) !void {
        try self.points.append(self.allocator, point);
    }

    pub fn print(self: *const ExecutionTrace) void {
        var buf: [4096]u8 = undefined;
        var pos: usize = 0;

        const header = "\n=== Execution Trace ===\n";
        if (pos + header.len <= buf.len) {
            @memcpy(buf[pos..][0..header.len], header);
            pos += header.len;
        }

        for (self.points.items, 0..) |point, i| {
            const elapsed = point.time - self.start_time;
            if (std.fmt.bufPrint(buf[pos..], "[{d}] +{d}ms: {s} at {s}:{d}\n", .{
                i,
                elapsed,
                point.name,
                point.file,
                point.line,
            })) |result| {
                pos += result.len;
            } else |_| continue;
        }

        const total = getMilliTimestamp() - self.start_time;
        if (std.fmt.bufPrint(buf[pos..], "\nTotal time: {d}ms\n", .{total})) |result| {
            pos += result.len;
        } else |_| {}

        writeStderr(buf[0..pos]);
    }
};

/// Macro to add a trace point
pub fn trace(comptime src: std.builtin.SourceLocation, name: []const u8) TracePoint {
    const point = TracePoint.init(src, name);
    if (builtin.mode == .Debug) {
        point.print();
    }
    return point;
}

// ============================================================================
// Tests
// ============================================================================

test "getMilliTimestamp returns non-negative value" {
    // The simplified version (no redundant @intCast/@divFloor) should still
    // produce a sensible millisecond value.
    const ms = getMilliTimestamp();
    // On platforms where Instant.now() works, this is non-zero; on unsupported
    // platforms it returns 0. Both are valid.
    try std.testing.expect(ms >= 0);
}

test "TracePoint creation" {
    const point = TracePoint.init(@src(), "test");
    try std.testing.expectEqualStrings("test", point.name);
    // Time should be non-negative (0 if Instant not supported)
    try std.testing.expect(point.time >= 0);
}
