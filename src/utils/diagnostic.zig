const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

/// Severity level for diagnostics
pub const Severity = enum {
    @"error",
    warning,
    hint,
    info,

    pub fn color(self: Severity) []const u8 {
        return switch (self) {
            .@"error" => "\x1b[1;31m", // bold red
            .warning => "\x1b[1;33m", // bold yellow
            .hint => "\x1b[1;36m", // bold cyan
            .info => "\x1b[1;34m", // bold blue
        };
    }

    pub fn label(self: Severity) []const u8 {
        return switch (self) {
            .@"error" => "error",
            .warning => "warning",
            .hint => "hint",
            .info => "info",
        };
    }
};

/// A labeled span within the source line
pub const Label = struct {
    start: usize,
    end: usize,
    message: []const u8,
    style: LabelStyle = .primary,

    pub const LabelStyle = enum {
        primary, // ^^^^ with message
        secondary, // ---- with message
    };
};

/// A rich diagnostic message with source context
pub const Diagnostic = struct {
    severity: Severity,
    message: []const u8,
    source_line: ?[]const u8 = null,
    line: u32 = 0,
    column: u32 = 0,
    labels: []const Label = &.{},
    help: ?[]const u8 = null,
    notes: []const []const u8 = &.{},

    /// Render the diagnostic to a colored string
    pub fn render(self: Diagnostic, allocator: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);
        const reset = "\x1b[0m";
        const dim = "\x1b[2m";
        const cyan = "\x1b[36m";

        // Header: error[E001]: message
        try buf.appendSlice(allocator, self.severity.color());
        try buf.appendSlice(allocator, self.severity.label());
        try buf.appendSlice(allocator, reset);
        try buf.appendSlice(allocator, ": ");
        try buf.appendSlice(allocator, self.message);
        try buf.append(allocator, '\n');

        // Source location
        if (self.line > 0) {
            try buf.appendSlice(allocator, "  ");
            try buf.appendSlice(allocator, cyan);
            try buf.appendSlice(allocator, "-->");
            try buf.appendSlice(allocator, reset);
            try buf.append(allocator, ' ');
            const loc = try std.fmt.allocPrint(allocator, "line {d}:{d}", .{ self.line, self.column });
            defer allocator.free(loc);
            try buf.appendSlice(allocator, loc);
            try buf.append(allocator, '\n');
        }

        // Source line with underlines
        if (self.source_line) |src| {
            // Line number gutter
            const line_num_str = try std.fmt.allocPrint(allocator, "{d}", .{self.line});
            defer allocator.free(line_num_str);
            const gutter_width = line_num_str.len + 1;

            // Empty gutter line
            try buf.appendSlice(allocator, dim);
            for (0..gutter_width) |_| try buf.append(allocator, ' ');
            try buf.appendSlice(allocator, "\xe2\x94\x82"); // |
            try buf.appendSlice(allocator, reset);
            try buf.append(allocator, '\n');

            // Source line
            try buf.appendSlice(allocator, dim);
            try buf.appendSlice(allocator, line_num_str);
            try buf.append(allocator, ' ');
            try buf.appendSlice(allocator, "\xe2\x94\x82"); // |
            try buf.appendSlice(allocator, reset);
            try buf.append(allocator, ' ');
            try buf.appendSlice(allocator, src);
            try buf.append(allocator, '\n');

            // Underline labels
            if (self.labels.len > 0) {
                for (self.labels) |lbl| {
                    try buf.appendSlice(allocator, dim);
                    for (0..gutter_width) |_| try buf.append(allocator, ' ');
                    try buf.appendSlice(allocator, "\xe2\x94\x82"); // |
                    try buf.appendSlice(allocator, reset);
                    try buf.append(allocator, ' ');

                    // Spaces before underline
                    for (0..lbl.start) |_| try buf.append(allocator, ' ');

                    // Underline characters
                    const underline_char: u8 = if (lbl.style == .primary) '^' else '-';
                    const underline_color = if (lbl.style == .primary) self.severity.color() else dim;
                    try buf.appendSlice(allocator, underline_color);
                    const span_len = if (lbl.end > lbl.start) lbl.end - lbl.start else 1;
                    for (0..span_len) |_| try buf.append(allocator, underline_char);

                    // Label message
                    if (lbl.message.len > 0) {
                        try buf.append(allocator, ' ');
                        try buf.appendSlice(allocator, lbl.message);
                    }
                    try buf.appendSlice(allocator, reset);
                    try buf.append(allocator, '\n');
                }
            } else if (self.column > 0) {
                // Default: underline at column position
                try buf.appendSlice(allocator, dim);
                for (0..gutter_width) |_| try buf.append(allocator, ' ');
                try buf.appendSlice(allocator, "\xe2\x94\x82"); // |
                try buf.appendSlice(allocator, reset);
                try buf.append(allocator, ' ');
                for (0..self.column - 1) |_| try buf.append(allocator, ' ');
                try buf.appendSlice(allocator, self.severity.color());
                try buf.append(allocator, '^');
                try buf.appendSlice(allocator, reset);
                try buf.append(allocator, '\n');
            }
        }

        // Help message
        if (self.help) |help| {
            try buf.appendSlice(allocator, "  \x1b[1;32mhelp\x1b[0m: ");
            try buf.appendSlice(allocator, help);
            try buf.append(allocator, '\n');
        }

        // Notes
        for (self.notes) |note| {
            try buf.appendSlice(allocator, "  \x1b[1mnote\x1b[0m: ");
            try buf.appendSlice(allocator, note);
            try buf.append(allocator, '\n');
        }

        return try buf.toOwnedSlice(allocator);
    }

    /// Print the diagnostic to stderr
    pub fn emit(self: Diagnostic) void {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const rendered = self.render(arena.allocator()) catch return;
        const stderr_file = std.Io.File{ .handle = if (builtin.os.tag == .windows)
            (@import("windows_compat").GetStdHandle(@import("windows_compat").STD_ERROR_HANDLE) orelse return)
        else
            posix.STDERR_FILENO, .flags = .{ .nonblocking = false } };
        stderr_file.writeStreamingAll(std.Options.debug_io, rendered) catch {};
    }
};

/// Create an error diagnostic
pub fn err(message: []const u8) Diagnostic {
    return .{ .severity = .@"error", .message = message };
}

/// Create a warning diagnostic
pub fn warn(message: []const u8) Diagnostic {
    return .{ .severity = .warning, .message = message };
}

/// Create an error diagnostic with source context
pub fn errWithSource(
    message: []const u8,
    source_line: []const u8,
    line: u32,
    column: u32,
) Diagnostic {
    return .{
        .severity = .@"error",
        .message = message,
        .source_line = source_line,
        .line = line,
        .column = column,
    };
}
