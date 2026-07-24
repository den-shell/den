const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");

// ============================================================================
// Zig 0.16 IO compatibility
// ============================================================================

/// Get the runtime's Io instance for file operations.
/// This uses the debug_io which is initialized by the Zig runtime before main().
pub fn getIo() std.Io {
    return std.Options.debug_io;
}

/// Compatibility wrapper: open a file relative to cwd
pub fn cwdOpenFile(sub_path: []const u8, flags: std.Io.File.OpenFlags) std.Io.File.OpenError!std.Io.File {
    return std.Io.Dir.cwd().openFile(getIo(), sub_path, flags);
}

/// Compatibility wrapper: create a file relative to cwd
pub fn cwdCreateFile(sub_path: []const u8, flags: std.Io.File.CreateFlags) std.Io.File.OpenError!std.Io.File {
    return std.Io.Dir.cwd().createFile(getIo(), sub_path, flags);
}

/// Compatibility wrapper: check access relative to cwd
pub fn cwdAccess(sub_path: []const u8, flags: std.Io.Dir.AccessOptions) std.Io.Dir.AccessError!void {
    return std.Io.Dir.cwd().access(getIo(), sub_path, flags);
}

/// Compatibility wrapper: make directory path relative to cwd
pub fn cwdMakePath(sub_path: []const u8) std.Io.Dir.CreateDirPathError!void {
    return std.Io.Dir.cwd().createDirPath(getIo(), sub_path);
}

/// Write bytes directly to a file descriptor (low-level, no Io needed)
pub fn rawWrite(fd: if (builtin.os.tag == .windows) std.os.windows.HANDLE else posix.fd_t, bytes: []const u8) void {
    if (builtin.os.tag == .windows) {
        var written: u32 = 0;
        _ = @import("windows_compat").WriteFile(fd, bytes.ptr, @intCast(bytes.len), &written, null);
    } else if (builtin.link_libc) {
        _ = std.c.write(fd, bytes.ptr, bytes.len);
    } else {
        _ = std.os.linux.write(fd, bytes.ptr, bytes.len);
    }
}

// ============================================================================
// Buffered I/O for reduced syscall overhead
// ============================================================================

/// Buffered reader that minimizes syscalls by reading in chunks
/// Provides 50-100x improvement for reading large inputs
pub const BufferedStdinReader = struct {
    buffer: [BUFFER_SIZE]u8 = undefined,
    start: usize = 0,
    end: usize = 0,

    const BUFFER_SIZE = 8192; // 8KB buffer - good balance for most inputs

    /// Read a single byte, refilling buffer as needed
    pub fn readByte(self: *BufferedStdinReader) !?u8 {
        if (self.start >= self.end) {
            // Buffer empty, refill
            const bytes_read = try self.fillBuffer();
            if (bytes_read == 0) return null; // EOF
        }
        const byte = self.buffer[self.start];
        self.start += 1;
        return byte;
    }

    /// Read bytes into provided buffer, returns slice of bytes read
    pub fn read(self: *BufferedStdinReader, dest: []u8) !usize {
        var total: usize = 0;

        while (total < dest.len) {
            // First, drain any buffered data
            if (self.start < self.end) {
                const buffered = self.end - self.start;
                const to_copy = @min(buffered, dest.len - total);
                @memcpy(dest[total..][0..to_copy], self.buffer[self.start..][0..to_copy]);
                self.start += to_copy;
                total += to_copy;
            } else {
                // Buffer empty - if dest is large enough, read directly
                if (dest.len - total >= BUFFER_SIZE) {
                    const bytes = try readStdinRaw(dest[total..]);
                    if (bytes == 0) break;
                    total += bytes;
                } else {
                    // Refill buffer
                    const bytes = try self.fillBuffer();
                    if (bytes == 0) break;
                }
            }
        }
        return total;
    }

    /// Read a line (until newline or EOF)
    /// Returns null on EOF with no data
    pub fn readLine(self: *BufferedStdinReader, allocator: std.mem.Allocator) !?[]u8 {
        var line_buf: [4096]u8 = undefined;
        var pos: usize = 0;

        while (pos < line_buf.len) {
            const byte = try self.readByte() orelse {
                if (pos == 0) return null;
                return try allocator.dupe(u8, line_buf[0..pos]);
            };

            if (byte == '\n') {
                return try allocator.dupe(u8, line_buf[0..pos]);
            }

            line_buf[pos] = byte;
            pos += 1;
        }

        return try allocator.dupe(u8, line_buf[0..pos]);
    }

    /// Peek at buffered data without consuming
    pub fn peek(self: *BufferedStdinReader) []const u8 {
        return self.buffer[self.start..self.end];
    }

    /// Check if any data is buffered
    pub fn hasBufferedData(self: *const BufferedStdinReader) bool {
        return self.start < self.end;
    }

    fn fillBuffer(self: *BufferedStdinReader) !usize {
        self.start = 0;
        self.end = try readStdinRaw(&self.buffer);
        return self.end;
    }

    fn readStdinRaw(buffer: []u8) !usize {
        if (builtin.os.tag == .windows) {
            const handle = @import("windows_compat").GetStdHandle(@import("windows_compat").STD_INPUT_HANDLE) orelse return error.NoStdIn;
            const stdin = std.Io.File{ .handle = handle, .flags = .{ .nonblocking = false } };
            return stdin.readStreaming(std.Options.debug_io, &.{buffer}) catch |err| {
                if (err == error.EndOfStream) return 0;
                return err;
            };
        }
        return posix.read(posix.STDIN_FILENO, buffer) catch |err| {
            if (err == error.EOF or err == error.Unexpected) return 0;
            return err;
        };
    }
};

/// Global buffered stdin reader instance
var global_stdin_reader: ?BufferedStdinReader = null;

/// Get the global buffered stdin reader
pub fn getBufferedStdin() *BufferedStdinReader {
    if (global_stdin_reader == null) {
        global_stdin_reader = BufferedStdinReader{};
    }
    return &global_stdin_reader.?;
}

/// I/O utilities for Zig 0.15
pub const IO = struct {
    /// Write string to stdout (cross-platform)
    pub fn print(comptime fmt: []const u8, args: anytype) !void {
        const stdout_file = std.Io.File.stdout();

        // Format the string
        var buf: [4096]u8 = undefined;
        const formatted = try std.fmt.bufPrint(&buf, fmt, args);
        try stdout_file.writeStreamingAll(std.Options.debug_io, formatted);
    }

    /// Write string to stderr (cross-platform)
    pub fn eprint(comptime fmt: []const u8, args: anytype) !void {
        const stderr_file = std.Io.File.stderr();

        // Format the string
        var buf: [4096]u8 = undefined;
        const formatted = try std.fmt.bufPrint(&buf, fmt, args);
        try stderr_file.writeStreamingAll(std.Options.debug_io, formatted);
    }

    /// Read a line from stdin (blocking)
    /// Returns null on EOF
    /// Caller owns returned memory
    pub fn readLine(allocator: std.mem.Allocator) !?[]u8 {
        var buffer: [4096]u8 = undefined;
        var pos: usize = 0;

        if (builtin.os.tag == .windows) {
            // Use Windows stdin handle with read loop (similar to POSIX path)
            const handle = @import("windows_compat").GetStdHandle(@import("windows_compat").STD_INPUT_HANDLE) orelse return error.NoStdIn;
            const stdin = std.Io.File{ .handle = handle, .flags = .{ .nonblocking = false } };

            while (pos < buffer.len) {
                var char_buf: [1]u8 = undefined;

                const bytes_read = stdin.readStreaming(std.Options.debug_io, &.{&char_buf}) catch {
                    if (pos == 0) return null;
                    return try allocator.dupe(u8, buffer[0..pos]);
                };

                if (bytes_read == 0) {
                    // EOF
                    if (pos == 0) return null;
                    return try allocator.dupe(u8, buffer[0..pos]);
                }

                const char = char_buf[0];

                if (char == '\n') {
                    return try allocator.dupe(u8, buffer[0..pos]);
                }

                buffer[pos] = char;
                pos += 1;
            }

            return try allocator.dupe(u8, buffer[0..pos]);
        }

        // Unix-like systems: use posix.read
        while (pos < buffer.len) {
            var char_buf: [1]u8 = undefined;

            const bytes_read = posix.read(posix.STDIN_FILENO, &char_buf) catch |err| {
                if (err == error.EOF or err == error.Unexpected) {
                    if (pos == 0) return null;
                    return try allocator.dupe(u8, buffer[0..pos]);
                }
                return err;
            };

            if (bytes_read == 0) {
                // EOF
                if (pos == 0) return null;
                return try allocator.dupe(u8, buffer[0..pos]);
            }

            const char = char_buf[0];

            if (char == '\n') {
                return try allocator.dupe(u8, buffer[0..pos]);
            }

            buffer[pos] = char;
            pos += 1;
        }

        // Line too long, return what we have
        return try allocator.dupe(u8, buffer[0..pos]);
    }

    /// Read exactly N bytes from stdin
    pub fn readBytes(buffer: []u8) !usize {
        if (builtin.os.tag == .windows) {
            const stdin_file = std.Io.File.stdin();
            const reader = stdin_file.reader(std.Options.debug_io);
            return try reader.read(buffer);
        }
        return try posix.read(posix.STDIN_FILENO, buffer);
    }

    /// Write bytes to stdout
    pub fn writeBytes(bytes: []const u8) !void {
        const stdout_file = std.Io.File.stdout();
        try stdout_file.writeStreamingAll(std.Options.debug_io, bytes);
    }

    /// Flush stdout (no-op on Unix, as writes are unbuffered)
    pub fn flush() void {
        // POSIX write() is unbuffered, so no flush needed
    }

    /// Read entire file contents into allocated buffer (Zig 0.16 compatible)
    /// Replaces deprecated file.readToEndAlloc()
    pub fn readFileAlloc(allocator: std.mem.Allocator, file: std.Io.File, max_size: usize) ![]u8 {
        const file_size = (try file.stat(std.Options.debug_io)).size;
        const read_size: usize = @min(file_size, max_size);
        const buffer = try allocator.alloc(u8, read_size);
        errdefer allocator.free(buffer);

        // Read in a loop until buffer is full or EOF
        var total_read: usize = 0;
        while (total_read < read_size) {
            const bytes_read = try file.readStreaming(std.Options.debug_io, &.{buffer[total_read..]});
            if (bytes_read == 0) break; // EOF
            total_read += bytes_read;
        }

        if (total_read < read_size) {
            // Return only the bytes we read
            const result = try allocator.alloc(u8, total_read);
            @memcpy(result, buffer[0..total_read]);
            allocator.free(buffer);
            return result;
        }
        return buffer;
    }
};

/// Buffered stdout writer to batch terminal output and reduce syscalls
/// Reduces escape sequence overhead by batching writes
pub const BufferedStdoutWriter = struct {
    buffer: [BUFFER_SIZE]u8 = undefined,
    pos: usize = 0,

    const BUFFER_SIZE = 8192; // 8KB buffer

    /// Write bytes to buffer, flushing if full
    pub fn write(self: *BufferedStdoutWriter, bytes: []const u8) !void {
        var remaining = bytes;

        while (remaining.len > 0) {
            const space = BUFFER_SIZE - self.pos;
            const to_copy = @min(space, remaining.len);

            @memcpy(self.buffer[self.pos..][0..to_copy], remaining[0..to_copy]);
            self.pos += to_copy;
            remaining = remaining[to_copy..];

            if (self.pos >= BUFFER_SIZE) {
                try self.flush();
            }
        }
    }

    /// Write a single byte
    pub fn writeByte(self: *BufferedStdoutWriter, byte: u8) !void {
        if (self.pos >= BUFFER_SIZE) {
            try self.flush();
        }
        self.buffer[self.pos] = byte;
        self.pos += 1;
    }

    /// Write formatted string
    pub fn print(self: *BufferedStdoutWriter, comptime fmt: []const u8, args: anytype) !void {
        var format_buf: [4096]u8 = undefined;
        const formatted = try std.fmt.bufPrint(&format_buf, fmt, args);
        try self.write(formatted);
    }

    /// Flush buffer to stdout
    pub fn flush(self: *BufferedStdoutWriter) !void {
        if (self.pos == 0) return;

        const stdout = std.Io.File{ .handle = if (builtin.os.tag == .windows)
            (@import("windows_compat").GetStdHandle(@import("windows_compat").STD_OUTPUT_HANDLE) orelse return)
        else
            posix.STDOUT_FILENO, .flags = .{ .nonblocking = false } };
        try stdout.writeStreamingAll(std.Options.debug_io, self.buffer[0..self.pos]);
        self.pos = 0;
    }

    /// Get current buffer contents (for debugging/testing)
    pub fn getBuffer(self: *const BufferedStdoutWriter) []const u8 {
        return self.buffer[0..self.pos];
    }
};

/// Global buffered stdout writer instance
var global_stdout_writer: ?BufferedStdoutWriter = null;

/// Get the global buffered stdout writer
pub fn getBufferedStdout() *BufferedStdoutWriter {
    if (global_stdout_writer == null) {
        global_stdout_writer = BufferedStdoutWriter{};
    }
    return &global_stdout_writer.?;
}

// ============================================================================
// Tests
// ============================================================================

test "IO.print" {
    try IO.print("test: {s}\n", .{"hello"});
}

test "BufferedStdoutWriter basic" {
    var writer = BufferedStdoutWriter{};
    try writer.write("hello");
    try std.testing.expectEqualStrings("hello", writer.getBuffer());
    try writer.write(" world");
    try std.testing.expectEqualStrings("hello world", writer.getBuffer());
}

test "BufferedStdinReader struct" {
    // Just verify the struct compiles and initializes
    var reader = BufferedStdinReader{};
    try std.testing.expect(!reader.hasBufferedData());
    try std.testing.expectEqual(@as(usize, 0), reader.peek().len);
}
