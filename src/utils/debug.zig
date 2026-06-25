const std = @import("std");
const builtin = @import("builtin");

/// Debug configuration
pub var enabled: bool = builtin.mode == .Debug;

/// Print debug information
pub fn print(comptime fmt: []const u8, args: anytype) void {
    if (!enabled) return;

    var buf: [4096]u8 = undefined;
    const output = std.fmt.bufPrint(&buf, "[DEBUG] " ++ fmt ++ "\n", args) catch return;

    const stderr = std.Io.File{ .handle = if (builtin.os.tag == .windows)
        (std.os.windows.kernel32.GetStdHandle(std.os.windows.STD_ERROR_HANDLE) orelse return)
    else
        std.posix.STDERR_FILENO, .flags = .{ .nonblocking = false } };
    stderr.writeStreamingAll(std.Options.debug_io, output) catch {};
}

/// Dump memory contents in hex format
pub fn hexDump(label: []const u8, data: []const u8) void {
    if (!enabled) return;

    print("=== {s} ({d} bytes) ===", .{ label, data.len });

    var i: usize = 0;
    while (i < data.len) : (i += 16) {
        var buf: [128]u8 = undefined;
        var pos: usize = 0;

        // Print offset
        pos += (std.fmt.bufPrint(buf[pos..], "{x:0>8}: ", .{i}) catch continue).len;

        // Print hex values
        var j: usize = 0;
        while (j < 16) : (j += 1) {
            if (i + j < data.len) {
                pos += (std.fmt.bufPrint(buf[pos..], "{x:0>2} ", .{data[i + j]}) catch continue).len;
            } else {
                if (pos + 3 <= buf.len) {
                    buf[pos] = ' ';
                    buf[pos + 1] = ' ';
                    buf[pos + 2] = ' ';
                    pos += 3;
                }
            }
        }

        if (pos + 3 <= buf.len) {
            buf[pos] = ' ';
            buf[pos + 1] = '|';
            buf[pos + 2] = ' ';
            pos += 3;
        }

        // Print ASCII values
        j = 0;
        while (j < 16) : (j += 1) {
            if (i + j < data.len) {
                const c = data[i + j];
                if (pos < buf.len) {
                    buf[pos] = if (c >= 32 and c <= 126) c else '.';
                    pos += 1;
                }
            }
        }

        const output = buf[0..pos];
        const stderr = std.Io.File{ .handle = if (builtin.os.tag == .windows)
            (std.os.windows.kernel32.GetStdHandle(std.os.windows.STD_ERROR_HANDLE) orelse continue)
        else
            std.posix.STDERR_FILENO, .flags = .{ .nonblocking = false } };
        stderr.writeStreamingAll(std.Options.debug_io, output) catch {};
        stderr.writeStreamingAll(std.Options.debug_io, "\n") catch {};
    }
}

/// Print a value with its type information
pub fn inspect(comptime name: []const u8, value: anytype) void {
    if (!enabled) return;

    const T = @TypeOf(value);
    const type_info = @typeInfo(T);

    print("{s}: {s} = {any}", .{ name, @typeName(T), value });

    // Print additional type information
    switch (type_info) {
        .pointer => |ptr| {
            // Newer zig moved pointer constness from `is_const` into `attrs`.
            const is_const = if (@hasField(@TypeOf(ptr), "is_const"))
                ptr.is_const
            else
                ptr.attrs.@"const";
            print("  -> Pointer (size: {s}, is_const: {})", .{
                @tagName(ptr.size),
                is_const,
            });
        },
        .array => |arr| {
            print("  -> Array (len: {d}, child: {s})", .{
                arr.len,
                @typeName(arr.child),
            });
        },
        .@"struct" => |s| {
            // Newer zig replaced `fields` with parallel `field_names`/`field_types`.
            const field_count = if (@hasField(@TypeOf(s), "fields"))
                s.fields.len
            else
                s.field_names.len;
            print("  -> Struct (fields: {d})", .{field_count});
        },
        .optional => |opt| {
            print("  -> Optional (child: {s})", .{@typeName(opt.child)});
        },
        .error_union => |eu| {
            print("  -> ErrorUnion (error: {s}, payload: {s})", .{
                @typeName(eu.error_set),
                @typeName(eu.payload),
            });
        },
        else => {},
    }
}

/// Trace a function call
pub fn trace(comptime src: std.builtin.SourceLocation, comptime name: []const u8) void {
    if (!enabled) return;
    print("TRACE: {s} called from {s}:{d}", .{ name, src.file, src.line });
}

/// Print call stack
pub fn printStackTrace() void {
    if (!enabled) return;

    print("=== Stack Trace ===", .{});

    var stack_trace = std.builtin.StackTrace{
        .instruction_addresses = &[_]usize{},
        .index = 0,
    };

    // Try to capture stack trace
    std.debug.captureStackTrace(@returnAddress(), &stack_trace);

    // Print stack trace
    var i: usize = 0;
    while (i < stack_trace.index) : (i += 1) {
        print("  [{d}] 0x{x}", .{ i, stack_trace.instruction_addresses[i] });
    }
}

/// Assert that prints debug info on failure
pub fn assertEquals(comptime T: type, expected: T, actual: T, comptime msg: []const u8) void {
    if (!enabled) return;

    if (!std.meta.eql(expected, actual)) {
        print("ASSERTION FAILED: {s}", .{msg});
        print("  Expected: {any}", .{expected});
        print("  Actual:   {any}", .{actual});
        printStackTrace();
    }
}

/// Memory usage tracking
pub const MemoryTracker = struct {
    allocations: usize = 0,
    deallocations: usize = 0,
    bytes_allocated: usize = 0,
    bytes_freed: usize = 0,
    peak_memory: usize = 0,
    current_memory: usize = 0,

    pub fn track_alloc(self: *MemoryTracker, size: usize) void {
        self.allocations += 1;
        self.bytes_allocated += size;
        self.current_memory += size;
        if (self.current_memory > self.peak_memory) {
            self.peak_memory = self.current_memory;
        }
    }

    pub fn track_free(self: *MemoryTracker, size: usize) void {
        self.deallocations += 1;
        self.bytes_freed += size;
        if (self.current_memory >= size) {
            self.current_memory -= size;
        }
    }

    pub fn printStats(self: *const MemoryTracker) void {
        if (!enabled) return;

        print("=== Memory Statistics ===", .{});
        print("Allocations:     {d}", .{self.allocations});
        print("Deallocations:   {d}", .{self.deallocations});
        print("Bytes allocated: {d}", .{self.bytes_allocated});
        print("Bytes freed:     {d}", .{self.bytes_freed});
        print("Current memory:  {d}", .{self.current_memory});
        print("Peak memory:     {d}", .{self.peak_memory});
        print("Leaked memory:   {d}", .{self.bytes_allocated - self.bytes_freed});
    }
};

/// Debug allocator that tracks allocations
pub const DebugAllocator = struct {
    parent_allocator: std.mem.Allocator,
    tracker: MemoryTracker = .{},

    pub fn init(parent: std.mem.Allocator) DebugAllocator {
        return .{ .parent_allocator = parent };
    }

    pub fn allocator(self: *DebugAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .free = free,
                .remap = remap,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *DebugAllocator = @ptrCast(@alignCast(ctx));
        const result = self.parent_allocator.rawAlloc(len, ptr_align, ret_addr);
        if (result) |ptr| {
            self.tracker.track_alloc(len);
            if (enabled) {
                print("ALLOC: {d} bytes at 0x{x}", .{ len, @intFromPtr(ptr) });
            }
        }
        return result;
    }

    fn resize(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *DebugAllocator = @ptrCast(@alignCast(ctx));
        const result = self.parent_allocator.rawResize(buf, buf_align, new_len, ret_addr);
        if (result) {
            if (new_len > buf.len) {
                self.tracker.track_alloc(new_len - buf.len);
            } else {
                self.tracker.track_free(buf.len - new_len);
            }
            if (enabled) {
                print("RESIZE: 0x{x} from {d} to {d} bytes", .{
                    @intFromPtr(buf.ptr),
                    buf.len,
                    new_len,
                });
            }
        }
        return result;
    }

    fn free(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
        const self: *DebugAllocator = @ptrCast(@alignCast(ctx));
        self.tracker.track_free(buf.len);
        if (enabled) {
            print("FREE: {d} bytes at 0x{x}", .{ buf.len, @intFromPtr(buf.ptr) });
        }
        self.parent_allocator.rawFree(buf, buf_align, ret_addr);
    }

    fn remap(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *DebugAllocator = @ptrCast(@alignCast(ctx));
        return self.parent_allocator.vtable.remap(self.parent_allocator.ptr, buf, buf_align, new_len, ret_addr);
    }
};
