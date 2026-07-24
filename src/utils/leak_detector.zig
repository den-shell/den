// Memory leak detection utilities for Den Shell
// Debug-only allocator wrappers that track allocations
const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat");

/// Memory leak detection allocator for debug builds
/// Wraps another allocator and tracks all allocations
pub const LeakDetector = struct {
    const AllocationInfo = struct {
        size: usize,
        stack_trace: ?std.builtin.StackTrace,
        timestamp: i64,
    };

    backing_allocator: std.mem.Allocator,
    allocations: std.AutoHashMap(usize, AllocationInfo),
    total_allocated: usize,
    total_freed: usize,
    peak_usage: usize,
    allocation_count: usize,
    free_count: usize,
    mutex: compat.Mutex,

    pub fn init(backing_allocator: std.mem.Allocator) LeakDetector {
        return .{
            .backing_allocator = backing_allocator,
            .allocations = std.AutoHashMap(usize, AllocationInfo).init(backing_allocator),
            .total_allocated = 0,
            .total_freed = 0,
            .peak_usage = 0,
            .allocation_count = 0,
            .free_count = 0,
            .mutex = .{},
        };
    }

    pub fn deinit(self: *LeakDetector) void {
        self.allocations.deinit();
    }

    pub fn allocator(self: *LeakDetector) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, ptr_align: u8, ret_addr: usize) ?[*]u8 {
        const self: *LeakDetector = @ptrCast(@alignCast(ctx));

        const result = self.backing_allocator.rawAlloc(len, ptr_align, ret_addr);
        if (result) |ptr| {
            self.mutex.lock();
            defer self.mutex.unlock();

            const addr = @intFromPtr(ptr);
            self.allocations.put(addr, .{
                .size = len,
                .stack_trace = if (builtin.mode == .Debug) std.debug.getSelfDebugInfo() catch null else null,
                .timestamp = std.time.milliTimestamp(),
            }) catch {};

            self.total_allocated += len;
            self.allocation_count += 1;
            const current_usage = self.total_allocated - self.total_freed;
            if (current_usage > self.peak_usage) {
                self.peak_usage = current_usage;
            }
        }
        return result;
    }

    fn resize(ctx: *anyopaque, buf: []u8, buf_align: u8, new_len: usize, ret_addr: usize) bool {
        const self: *LeakDetector = @ptrCast(@alignCast(ctx));

        const old_len = buf.len;
        const result = self.backing_allocator.rawResize(buf, buf_align, new_len, ret_addr);

        if (result) {
            self.mutex.lock();
            defer self.mutex.unlock();

            const addr = @intFromPtr(buf.ptr);
            if (self.allocations.getPtr(addr)) |info| {
                self.total_allocated += new_len;
                self.total_freed += old_len;
                info.size = new_len;
                info.timestamp = std.time.milliTimestamp();
            }
        }
        return result;
    }

    fn free(ctx: *anyopaque, buf: []u8, buf_align: u8, ret_addr: usize) void {
        const self: *LeakDetector = @ptrCast(@alignCast(ctx));

        self.mutex.lock();
        defer self.mutex.unlock();

        const addr = @intFromPtr(buf.ptr);
        if (self.allocations.fetchRemove(addr)) |_| {
            self.total_freed += buf.len;
            self.free_count += 1;
        }

        self.backing_allocator.rawFree(buf, buf_align, ret_addr);
    }

    /// Check for memory leaks and return a report
    pub fn checkLeaks(self: *LeakDetector) LeakReport {
        self.mutex.lock();
        defer self.mutex.unlock();

        var leaked_bytes: usize = 0;
        var leak_count: usize = 0;

        var iter = self.allocations.iterator();
        while (iter.next()) |entry| {
            leaked_bytes += entry.value_ptr.size;
            leak_count += 1;
        }

        return .{
            .leaked_bytes = leaked_bytes,
            .leak_count = leak_count,
            .total_allocated = self.total_allocated,
            .total_freed = self.total_freed,
            .peak_usage = self.peak_usage,
            .allocation_count = self.allocation_count,
            .free_count = self.free_count,
        };
    }

    /// Print leak report to stderr
    pub fn printLeakReport(self: *LeakDetector) void {
        const report = self.checkLeaks();
        const stderr = (std.Io.File{ .handle = if (builtin.os.tag == .windows)
            (@import("windows_compat").GetStdHandle(@import("windows_compat").STD_ERROR_HANDLE) orelse return)
        else
            std.posix.STDERR_FILENO, .flags = .{ .nonblocking = false } }).writer(std.Options.debug_io);

        stderr.print("\n=== Memory Leak Report ===\n", .{}) catch {};
        stderr.print("Total allocated: {} bytes ({} allocations)\n", .{ report.total_allocated, report.allocation_count }) catch {};
        stderr.print("Total freed: {} bytes ({} frees)\n", .{ report.total_freed, report.free_count }) catch {};
        stderr.print("Peak usage: {} bytes\n", .{report.peak_usage}) catch {};

        if (report.leak_count > 0) {
            stderr.print("\n!!! LEAKS DETECTED !!!\n", .{}) catch {};
            stderr.print("Leaked: {} bytes in {} allocation(s)\n", .{ report.leaked_bytes, report.leak_count }) catch {};

            // Print individual leaks
            self.mutex.lock();
            defer self.mutex.unlock();

            var count: usize = 0;
            var iter = self.allocations.iterator();
            while (iter.next()) |entry| {
                if (count >= 10) {
                    stderr.print("  ... and {} more\n", .{report.leak_count - 10}) catch {};
                    break;
                }
                stderr.print("  Leak at 0x{x}: {} bytes\n", .{ entry.key_ptr.*, entry.value_ptr.size }) catch {};
                count += 1;
            }
        } else {
            stderr.print("\nNo leaks detected.\n", .{}) catch {};
        }
        stderr.print("===========================\n", .{}) catch {};
    }

    /// Assert no leaks (for tests)
    pub fn assertNoLeaks(self: *LeakDetector) !void {
        const report = self.checkLeaks();
        if (report.leak_count > 0) {
            self.printLeakReport();
            return error.MemoryLeak;
        }
    }
};

pub const LeakReport = struct {
    leaked_bytes: usize,
    leak_count: usize,
    total_allocated: usize,
    total_freed: usize,
    peak_usage: usize,
    allocation_count: usize,
    free_count: usize,

    pub fn hasLeaks(self: LeakReport) bool {
        return self.leak_count > 0;
    }
};

/// Debug allocator that can be enabled/disabled at runtime
pub const DebugAllocator = struct {
    inner: union {
        leak_detector: LeakDetector,
        passthrough: std.mem.Allocator,
    },
    enabled: bool,

    pub fn init(backing_allocator: std.mem.Allocator, enable_tracking: bool) DebugAllocator {
        if (enable_tracking and builtin.mode == .Debug) {
            return .{
                .inner = .{ .leak_detector = LeakDetector.init(backing_allocator) },
                .enabled = true,
            };
        }
        return .{
            .inner = .{ .passthrough = backing_allocator },
            .enabled = false,
        };
    }

    pub fn deinit(self: *DebugAllocator) void {
        if (self.enabled) {
            self.inner.leak_detector.deinit();
        }
    }

    pub fn allocator(self: *DebugAllocator) std.mem.Allocator {
        if (self.enabled) {
            return self.inner.leak_detector.allocator();
        }
        return self.inner.passthrough;
    }

    pub fn checkLeaks(self: *DebugAllocator) ?LeakReport {
        if (self.enabled) {
            return self.inner.leak_detector.checkLeaks();
        }
        return null;
    }

    pub fn printLeakReport(self: *DebugAllocator) void {
        if (self.enabled) {
            self.inner.leak_detector.printLeakReport();
        }
    }
};

// Tests
test "LeakDetector basic operations" {
    var debug_allocator = std.heap.DebugAllocator(.{}).init;
    defer _ = debug_allocator.deinit();

    var detector = LeakDetector.init(debug_allocator.allocator());
    defer detector.deinit();

    const alloc = detector.allocator();

    // Allocate and free properly
    const ptr1 = try alloc.alloc(u8, 100);
    const ptr2 = try alloc.alloc(u8, 200);

    alloc.free(ptr1);
    alloc.free(ptr2);

    const report = detector.checkLeaks();
    try std.testing.expectEqual(@as(usize, 0), report.leak_count);
    try std.testing.expectEqual(@as(usize, 300), report.total_allocated);
    try std.testing.expectEqual(@as(usize, 300), report.total_freed);
}

test "LeakDetector detects leaks" {
    var debug_allocator = std.heap.DebugAllocator(.{}).init;
    defer _ = debug_allocator.deinit();

    var detector = LeakDetector.init(debug_allocator.allocator());
    defer detector.deinit();

    const alloc = detector.allocator();

    // Allocate but don't free one
    const ptr1 = try alloc.alloc(u8, 100);
    const ptr2 = try alloc.alloc(u8, 200);

    alloc.free(ptr1);
    // ptr2 is leaked!

    const report = detector.checkLeaks();
    try std.testing.expectEqual(@as(usize, 1), report.leak_count);
    try std.testing.expectEqual(@as(usize, 200), report.leaked_bytes);

    // Clean up the leak manually for test
    alloc.free(ptr2);
}

test "LeakReport hasLeaks" {
    const report_clean = LeakReport{
        .leaked_bytes = 0,
        .leak_count = 0,
        .total_allocated = 100,
        .total_freed = 100,
        .peak_usage = 100,
        .allocation_count = 1,
        .free_count = 1,
    };
    try std.testing.expect(!report_clean.hasLeaks());

    const report_leaky = LeakReport{
        .leaked_bytes = 50,
        .leak_count = 1,
        .total_allocated = 100,
        .total_freed = 50,
        .peak_usage = 100,
        .allocation_count = 2,
        .free_count = 1,
    };
    try std.testing.expect(report_leaky.hasLeaks());
}
