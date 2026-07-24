const std = @import("std");
const builtin = @import("builtin");
const Shell = @import("../shell.zig").Shell;
const Terminal = @import("../utils/terminal.zig");
const LineEditor = Terminal.LineEditor;
const IO = @import("../utils/io.zig").IO;

/// REPL (Read-Eval-Print-Loop) coordinator
/// Manages the interactive shell loop, input handling, and prompt rendering
pub const Repl = struct {
    allocator: std.mem.Allocator,
    shell: *Shell,
    line_editor: ?*LineEditor,
    running: bool,

    pub fn init(allocator: std.mem.Allocator, shell: *Shell) Repl {
        return .{
            .allocator = allocator,
            .shell = shell,
            .line_editor = null,
            .running = false,
        };
    }

    pub fn deinit(self: *Repl) void {
        if (self.line_editor) |editor| {
            editor.deinit();
            self.allocator.destroy(editor);
        }
    }

    /// Start the REPL loop
    pub fn run(self: *Repl) !void {
        self.running = true;

        while (self.running) {
            // Render prompt
            try self.shell.renderPrompt();

            // Read input
            const input = self.readLine() catch |err| {
                switch (err) {
                    error.EndOfStream => {
                        self.running = false;
                        break;
                    },
                    error.Interrupted => continue,
                    else => return err,
                }
            } orelse {
                // EOF
                self.running = false;
                break;
            };
            defer self.allocator.free(input);

            // Skip empty input
            const trimmed = std.mem.trim(u8, input, &std.ascii.whitespace);
            if (trimmed.len == 0) continue;

            // Execute command
            self.shell.executeCommand(input) catch |err| {
                try IO.eprint("den: error: {}\n", .{err});
            };
        }
    }

    /// Read a line of input
    fn readLine(self: *Repl) !?[]const u8 {
        if (self.line_editor) |editor| {
            return editor.run();
        }

        // Fallback to simple stdin reading
        var buf: [4096]u8 = undefined;
        var total: usize = 0;
        while (total < buf.len) {
            const n = if (comptime builtin.os.tag == .windows) blk: {
                const handle = @import("windows_compat").GetStdHandle(@import("windows_compat").STD_INPUT_HANDLE) orelse {
                    if (total > 0) return try self.allocator.dupe(u8, buf[0..total]);
                    return error.Unexpected;
                };
                var bytes_read: u32 = 0;
                const success = @import("windows_compat").ReadFile(handle, buf[total..].ptr, @intCast(buf[total..].len), &bytes_read, null);
                if (success == 0) {
                    if (total > 0) break :blk @as(usize, total);
                    return error.Unexpected;
                }
                break :blk @as(usize, @intCast(bytes_read));
            } else std.posix.read(std.posix.STDIN_FILENO, buf[total..]) catch |err| {
                if (total > 0) return try self.allocator.dupe(u8, buf[0..total]);
                return err;
            };
            if (n == 0) {
                if (total > 0) return try self.allocator.dupe(u8, buf[0..total]);
                return null;
            }
            // Check for newline in what we just read
            for (buf[total .. total + n]) |c| {
                if (c == '\n') {
                    const end = total + (std.mem.indexOfScalar(u8, buf[total .. total + n], '\n') orelse 0);
                    return try self.allocator.dupe(u8, buf[0..end]);
                }
            }
            total += n;
        }
        return try self.allocator.dupe(u8, buf[0..total]);
    }

    /// Stop the REPL
    pub fn stop(self: *Repl) void {
        self.running = false;
    }

    /// Check if REPL is running
    pub fn isRunning(self: *const Repl) bool {
        return self.running;
    }
};

/// Input mode for the REPL
pub const InputMode = enum {
    normal,
    multiline,
    reverse_search,
    completion,
};

/// REPL event types for hooks/plugins
pub const ReplEvent = enum {
    before_prompt,
    after_prompt,
    before_execute,
    after_execute,
    line_accepted,
    line_rejected,
};
