const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const types = @import("../../types/mod.zig");
const IO = @import("../../utils/io.zig").IO;
const BufferedStdoutWriter = @import("../../utils/io.zig").BufferedStdoutWriter;
const common = @import("common.zig");

/// Phase 4.2: Interactive TUI data explorer
///
/// The `explore` command reads stdin data and presents it in an interactive,
/// navigable terminal UI. It auto-detects JSON (structured data) vs plain text
/// and selects the most appropriate display mode.
///
/// Usage:
///   cat data.json | explore
///   ls -la | explore
///   echo '{"name":"den","version":"0.1"}' | explore

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const MAX_STDIN_SIZE: usize = 64 * 1024 * 1024; // 64 MB
const MAX_TRUNCATED_VALUE: usize = 120;
const SEARCH_BUF_SIZE: usize = 256;

// ANSI escape helpers
const ESC = "\x1b";
const CSI = ESC ++ "[";

// Colors
const COLOR_RESET = CSI ++ "0m";
const COLOR_DIM = CSI ++ "2m";
const COLOR_KEY = CSI ++ "1;36m"; // bold cyan
const COLOR_STRING = CSI ++ "0;32m"; // green
const COLOR_NUMBER = CSI ++ "0;33m"; // yellow
const COLOR_BOOL = CSI ++ "0;35m"; // magenta
const COLOR_NULL = CSI ++ "2;37m"; // dim white
const COLOR_HEADER = CSI ++ "1;97;44m"; // bold white on blue
const COLOR_STATUS = CSI ++ "30;47m"; // black on white
const COLOR_MATCH = CSI ++ "1;30;43m"; // bold black on yellow
const COLOR_LINE_NR = CSI ++ "2;33m"; // dim yellow
const COLOR_BORDER = CSI ++ "2;37m"; // dim white
const COLOR_CURSOR_ROW = CSI ++ "7m"; // reverse video

// ---------------------------------------------------------------------------
// View mode
// ---------------------------------------------------------------------------

const ViewMode = enum {
    table,
    record,
    text,
};

// ---------------------------------------------------------------------------
// Parsed data representation
// ---------------------------------------------------------------------------

const DataKind = enum {
    json_array_of_objects,
    json_object,
    json_other,
    plain_text,
};

const ExploreData = struct {
    kind: DataKind,
    raw: []const u8,

    // For table view (json_array_of_objects)
    columns: [][]const u8,
    col_widths: []usize,
    rows: [][]CellValue,

    // For record view (json_object)
    keys: [][]const u8,
    values: []CellValue,

    // For text view
    lines: [][]const u8,

    fn totalRows(self: *const ExploreData) usize {
        return switch (self.kind) {
            .json_array_of_objects => self.rows.len,
            .json_object => self.keys.len,
            .json_other, .plain_text => self.lines.len,
        };
    }

    fn deinit(self: *ExploreData, allocator: std.mem.Allocator) void {
        switch (self.kind) {
            .json_array_of_objects => {
                for (self.rows) |row| {
                    for (row) |cell| {
                        if (cell.text.len > 0) allocator.free(cell.text);
                    }
                    allocator.free(row);
                }
                if (self.rows.len > 0) allocator.free(self.rows);
                if (self.col_widths.len > 0) allocator.free(self.col_widths);
                for (self.columns) |col| allocator.free(col);
                if (self.columns.len > 0) allocator.free(self.columns);
            },
            .json_object => {
                for (self.keys) |k| allocator.free(k);
                if (self.keys.len > 0) allocator.free(self.keys);
                for (self.values) |v| {
                    if (v.text.len > 0) allocator.free(v.text);
                }
                if (self.values.len > 0) allocator.free(self.values);
            },
            .json_other, .plain_text => {
                for (self.lines) |line| allocator.free(line);
                if (self.lines.len > 0) allocator.free(self.lines);
            },
        }
    }
};

const CellKind = enum {
    string,
    number,
    boolean,
    null_val,
    other,
};

const CellValue = struct {
    text: []const u8,
    kind: CellKind,
};

// ---------------------------------------------------------------------------
// TUI State
// ---------------------------------------------------------------------------

const ExploreState = struct {
    data: ExploreData,
    view: ViewMode,
    // Viewport
    cursor_row: usize = 0,
    scroll_row: usize = 0,
    scroll_col: usize = 0,
    // Terminal dimensions
    term_rows: u16 = 24,
    term_cols: u16 = 80,
    // Search
    search_active: bool = false,
    search_buf: [SEARCH_BUF_SIZE]u8 = @splat(0),
    search_len: usize = 0,
    search_match_row: ?usize = null,
    // Status message
    status_msg: ?[]const u8 = null,

    fn visibleRows(self: *const ExploreState) usize {
        // Reserve 2 rows: 1 header + 1 status bar
        if (self.term_rows < 3) return 1;
        return self.term_rows - 2;
    }

    fn clampScroll(self: *ExploreState) void {
        const total = self.data.totalRows();
        const visible = self.visibleRows();

        if (total == 0) {
            self.cursor_row = 0;
            self.scroll_row = 0;
            return;
        }

        if (self.cursor_row >= total) {
            self.cursor_row = total - 1;
        }

        // Ensure cursor is visible
        if (self.cursor_row < self.scroll_row) {
            self.scroll_row = self.cursor_row;
        }
        if (self.cursor_row >= self.scroll_row + visible) {
            self.scroll_row = self.cursor_row - visible + 1;
        }

        if (total <= visible) {
            self.scroll_row = 0;
        } else if (self.scroll_row + visible > total) {
            self.scroll_row = total - visible;
        }
    }
};

// ---------------------------------------------------------------------------
// Key input
// ---------------------------------------------------------------------------

const Key = enum {
    up,
    down,
    left,
    right,
    home,
    end,
    page_up,
    page_down,
    enter,
    escape,
    backspace,
    slash,
    char_q,
    char_j,
    char_k,
    char_n,
    char_N,
    char_g,
    char_G,
    other_char,
    none,
};

const KeyResult = struct {
    key: Key,
    ch: u8 = 0,
};

fn readStdin(buf: []u8) !usize {
    if (builtin.os.tag == .windows) {
        const handle = @import("windows_compat").GetStdHandle(@import("windows_compat").STD_INPUT_HANDLE) orelse return error.Unexpected;
        var bytes_read: u32 = 0;
        const success = @import("windows_compat").ReadFile(handle, buf.ptr, @intCast(buf.len), &bytes_read, null);
        if (success == 0) return error.Unexpected;
        return @intCast(bytes_read);
    } else {
        return std.posix.read(std.posix.STDIN_FILENO, buf);
    }
}

fn readKey() !KeyResult {
    var buf: [1]u8 = undefined;
    const n = readStdin(&buf) catch |err| {
        if (err == error.WouldBlock) return .{ .key = .none };
        return err;
    };
    if (n == 0) return .{ .key = .none };

    const c = buf[0];

    if (c == 0x1b) {
        // Possible escape sequence
        var seq: [5]u8 = undefined;
        const n2 = readStdin(seq[0..1]) catch return .{ .key = .escape };
        if (n2 == 0) return .{ .key = .escape };

        if (seq[0] == '[') {
            const n3 = readStdin(seq[1..2]) catch return .{ .key = .escape };
            if (n3 == 0) return .{ .key = .escape };

            // Check for extended sequences like [1;5A, [H, [F, [5~, [6~
            if (seq[1] >= '0' and seq[1] <= '9') {
                const n4 = readStdin(seq[2..3]) catch return .{ .key = .escape };
                if (n4 > 0 and seq[2] == '~') {
                    return switch (seq[1]) {
                        '1' => .{ .key = .home },
                        '4' => .{ .key = .end },
                        '5' => .{ .key = .page_up },
                        '6' => .{ .key = .page_down },
                        '7' => .{ .key = .home },
                        '8' => .{ .key = .end },
                        else => .{ .key = .none },
                    };
                }
                // Might be longer sequence; consume remainder
                return .{ .key = .none };
            }

            return switch (seq[1]) {
                'A' => .{ .key = .up },
                'B' => .{ .key = .down },
                'C' => .{ .key = .right },
                'D' => .{ .key = .left },
                'H' => .{ .key = .home },
                'F' => .{ .key = .end },
                else => .{ .key = .none },
            };
        } else if (seq[0] == 'O') {
            const n3 = readStdin(seq[1..2]) catch return .{ .key = .escape };
            if (n3 == 0) return .{ .key = .escape };
            return switch (seq[1]) {
                'H' => .{ .key = .home },
                'F' => .{ .key = .end },
                else => .{ .key = .none },
            };
        }

        return .{ .key = .escape };
    }

    // Non-escape characters
    return switch (c) {
        'q' => .{ .key = .char_q, .ch = c },
        'j' => .{ .key = .char_j, .ch = c },
        'k' => .{ .key = .char_k, .ch = c },
        'n' => .{ .key = .char_n, .ch = c },
        'N' => .{ .key = .char_N, .ch = c },
        'g' => .{ .key = .char_g, .ch = c },
        'G' => .{ .key = .char_G, .ch = c },
        '/' => .{ .key = .slash, .ch = c },
        '\r', '\n' => .{ .key = .enter, .ch = c },
        127, 8 => .{ .key = .backspace, .ch = c },
        else => .{ .key = .other_char, .ch = c },
    };
}

// ---------------------------------------------------------------------------
// Terminal size
// ---------------------------------------------------------------------------

fn getTerminalSize() struct { rows: u16, cols: u16 } {
    if (builtin.os.tag == .windows) {
        var info: @import("windows_compat").CONSOLE_SCREEN_BUFFER_INFO = undefined;
        const handle = @import("windows_compat").GetStdHandle(@import("windows_compat").STD_OUTPUT_HANDLE) orelse return .{ .rows = 24, .cols = 80 };
        if (@import("windows_compat").GetConsoleScreenBufferInfo(handle, &info) != 0) {
            return .{
                .rows = @intCast(info.srWindow.Bottom - info.srWindow.Top + 1),
                .cols = @intCast(info.srWindow.Right - info.srWindow.Left + 1),
            };
        }
        return .{ .rows = 24, .cols = 80 };
    }
    var ws: posix.winsize = undefined;
    const rc = posix.system.ioctl(posix.STDOUT_FILENO, posix.T.IOCGWINSZ, @intFromPtr(&ws));
    if (rc < 0 or ws.row == 0 or ws.col == 0) {
        return .{ .rows = 24, .cols = 80 };
    }
    return .{ .rows = ws.row, .cols = ws.col };
}

// ---------------------------------------------------------------------------
// Data parsing
// ---------------------------------------------------------------------------

fn parseInputData(allocator: std.mem.Allocator, raw: []const u8) !ExploreData {
    const trimmed = std.mem.trim(u8, raw, &std.ascii.whitespace);
    if (trimmed.len == 0) {
        return makeTextData(allocator, raw);
    }

    // Attempt JSON parse
    if (std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{})) |parsed| {
        defer parsed.deinit();
        return buildJsonData(allocator, parsed.value, raw);
    } else |_| {}

    return makeTextData(allocator, raw);
}

fn buildJsonData(allocator: std.mem.Allocator, jval: std.json.Value, raw: []const u8) !ExploreData {
    switch (jval) {
        .array => |arr| {
            // Check if it is an array of objects (table-friendly)
            if (arr.items.len > 0) {
                var all_objects = true;
                for (arr.items) |item| {
                    if (item != .object) {
                        all_objects = false;
                        break;
                    }
                }
                if (all_objects) {
                    return buildTableData(allocator, arr.items, raw);
                }
            }
            // Non-table array: show as text lines of JSON values
            return buildJsonLinesData(allocator, arr.items, raw);
        },
        .object => |obj| {
            return buildRecordData(allocator, obj, raw);
        },
        else => {
            // Single primitive value - display as text
            return makeTextData(allocator, raw);
        },
    }
}

fn buildTableData(allocator: std.mem.Allocator, items: []const std.json.Value, raw: []const u8) !ExploreData {
    // Collect unique column names preserving insertion order
    var col_set: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer col_set.deinit(allocator);

    for (items) |item| {
        if (item == .object) {
            var it = item.object.iterator();
            while (it.next()) |entry| {
                try col_set.put(allocator, entry.key_ptr.*, {});
            }
        }
    }

    const num_cols = col_set.count();
    const columns = try allocator.alloc([]const u8, num_cols);
    const col_widths = try allocator.alloc(usize, num_cols);

    var kit = col_set.iterator();
    var ci: usize = 0;
    while (kit.next()) |entry| {
        const name = try allocator.dupe(u8, entry.key_ptr.*);
        columns[ci] = name;
        col_widths[ci] = name.len;
        ci += 1;
    }

    // Build rows
    const rows = try allocator.alloc([]CellValue, items.len);
    for (items, 0..) |item, ri| {
        const row = try allocator.alloc(CellValue, num_cols);
        for (columns, 0..) |col, cj| {
            if (item == .object) {
                if (item.object.get(col)) |val| {
                    const cell = jsonValueToCell(allocator, val) catch CellValue{ .text = "<error>", .kind = .other };
                    row[cj] = cell;
                    if (cell.text.len > col_widths[cj]) {
                        col_widths[cj] = @min(cell.text.len, MAX_TRUNCATED_VALUE);
                    }
                } else {
                    row[cj] = CellValue{ .text = "", .kind = .null_val };
                }
            } else {
                row[cj] = CellValue{ .text = "", .kind = .null_val };
            }
        }
        rows[ri] = row;
    }

    return ExploreData{
        .kind = .json_array_of_objects,
        .raw = raw,
        .columns = columns,
        .col_widths = col_widths,
        .rows = rows,
        .keys = &[_][]const u8{},
        .values = &[_]CellValue{},
        .lines = &[_][]const u8{},
    };
}

fn buildRecordData(allocator: std.mem.Allocator, obj: std.json.ObjectMap, raw: []const u8) !ExploreData {
    const count = obj.count();
    const keys = try allocator.alloc([]const u8, count);
    errdefer allocator.free(keys);
    const values = try allocator.alloc(CellValue, count);
    errdefer allocator.free(values);

    var keys_filled: usize = 0;
    errdefer for (keys[0..keys_filled]) |k| allocator.free(k);

    var it = obj.iterator();
    var i: usize = 0;
    while (it.next()) |entry| {
        keys[i] = try allocator.dupe(u8, entry.key_ptr.*);
        keys_filled = i + 1;
        values[i] = jsonValueToCell(allocator, entry.value_ptr.*) catch CellValue{ .text = "<error>", .kind = .other };
        i += 1;
    }

    return ExploreData{
        .kind = .json_object,
        .raw = raw,
        .columns = &[_][]const u8{},
        .col_widths = &[_]usize{},
        .rows = &[_][]CellValue{},
        .keys = keys,
        .values = values,
        .lines = &[_][]const u8{},
    };
}

fn buildJsonLinesData(allocator: std.mem.Allocator, items: []const std.json.Value, raw: []const u8) !ExploreData {
    const lines = try allocator.alloc([]const u8, items.len);
    for (items, 0..) |item, i| {
        lines[i] = jsonValueToString(allocator, item) catch "<error>";
    }

    return ExploreData{
        .kind = .json_other,
        .raw = raw,
        .columns = &[_][]const u8{},
        .col_widths = &[_]usize{},
        .rows = &[_][]CellValue{},
        .keys = &[_][]const u8{},
        .values = &[_]CellValue{},
        .lines = lines,
    };
}

fn makeTextData(allocator: std.mem.Allocator, raw: []const u8) !ExploreData {
    // Split raw text into lines
    var line_list = std.ArrayList([]const u8).empty;
    errdefer {
        for (line_list.items) |l| allocator.free(l);
        line_list.deinit(allocator);
    }

    var start: usize = 0;
    for (raw, 0..) |c, i| {
        if (c == '\n') {
            const dup = try allocator.dupe(u8, raw[start..i]);
            errdefer allocator.free(dup);
            try line_list.append(allocator, dup);
            start = i + 1;
        }
    }
    if (start <= raw.len) {
        const remainder = raw[start..];
        if (remainder.len > 0) {
            const dup = try allocator.dupe(u8, remainder);
            errdefer allocator.free(dup);
            try line_list.append(allocator, dup);
        }
    }

    // If no lines at all, add one empty line
    if (line_list.items.len == 0) {
        const dup = try allocator.dupe(u8, "");
        errdefer allocator.free(dup);
        try line_list.append(allocator, dup);
    }

    const lines = try allocator.dupe([]const u8, line_list.items);
    // Items now also referenced by `lines`; only free the backing storage.
    line_list.deinit(allocator);

    return ExploreData{
        .kind = .plain_text,
        .raw = raw,
        .columns = &[_][]const u8{},
        .col_widths = &[_]usize{},
        .rows = &[_][]CellValue{},
        .keys = &[_][]const u8{},
        .values = &[_]CellValue{},
        .lines = lines,
    };
}

fn jsonValueToCell(allocator: std.mem.Allocator, val: std.json.Value) !CellValue {
    return switch (val) {
        .null => CellValue{ .text = "null", .kind = .null_val },
        .bool => |b| CellValue{
            .text = if (b) "true" else "false",
            .kind = .boolean,
        },
        .integer => |i| CellValue{
            .text = try std.fmt.allocPrint(allocator, "{d}", .{i}),
            .kind = .number,
        },
        .float => |f| CellValue{
            .text = try std.fmt.allocPrint(allocator, "{d}", .{f}),
            .kind = .number,
        },
        .string => |s| CellValue{
            .text = try allocator.dupe(u8, s),
            .kind = .string,
        },
        .number_string => |s| CellValue{
            .text = try allocator.dupe(u8, s),
            .kind = .number,
        },
        .array => |arr| CellValue{
            .text = try std.fmt.allocPrint(allocator, "[{d} items]", .{arr.items.len}),
            .kind = .other,
        },
        .object => |obj| CellValue{
            .text = try std.fmt.allocPrint(allocator, "{{{d} fields}}", .{obj.count()}),
            .kind = .other,
        },
    };
}

fn jsonValueToString(allocator: std.mem.Allocator, val: std.json.Value) ![]const u8 {
    return switch (val) {
        .null => try allocator.dupe(u8, "null"),
        .bool => |b| try allocator.dupe(u8, if (b) "true" else "false"),
        .integer => |i| try std.fmt.allocPrint(allocator, "{d}", .{i}),
        .float => |f| try std.fmt.allocPrint(allocator, "{d}", .{f}),
        .string => |s| try std.fmt.allocPrint(allocator, "\"{s}\"", .{s}),
        .number_string => |s| try allocator.dupe(u8, s),
        .array => |arr| try std.fmt.allocPrint(allocator, "[{d} items]", .{arr.items.len}),
        .object => |obj| try std.fmt.allocPrint(allocator, "{{{d} fields}}", .{obj.count()}),
    };
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

fn render(writer: *BufferedStdoutWriter, state: *const ExploreState) !void {
    // Hide cursor and move to top-left
    try writer.write(CSI ++ "?25l");
    try writer.write(CSI ++ "H");

    switch (state.data.kind) {
        .json_array_of_objects => try renderTable(writer, state),
        .json_object => try renderRecord(writer, state),
        .json_other, .plain_text => try renderText(writer, state),
    }

    try renderStatusBar(writer, state);

    // Show cursor only during search input
    if (state.search_active) {
        try writer.write(CSI ++ "?25h");
    }

    try writer.flush();
}

fn renderTable(writer: *BufferedStdoutWriter, state: *const ExploreState) !void {
    const cols: usize = @intCast(state.term_cols);
    const visible = state.visibleRows();
    const data = &state.data;

    // --- Header row ---
    try writer.write(COLOR_HEADER);
    var col_pos: usize = 0;
    const row_nr_width: usize = digitCount(data.rows.len) + 1;

    // Row number gutter
    try writeRepeat(writer, ' ', row_nr_width);
    col_pos += row_nr_width;

    var first_visible_col: usize = state.scroll_col;
    if (first_visible_col > data.columns.len) first_visible_col = 0;

    for (first_visible_col..data.columns.len) |ci| {
        if (col_pos >= cols) break;
        const w = @min(data.col_widths[ci] + 2, cols - col_pos);
        try writer.print(" {s}", .{truncate(data.columns[ci], w -| 2)});
        const printed = 1 + @min(data.columns[ci].len, w -| 2);
        if (printed < w) {
            try writeRepeat(writer, ' ', w - printed);
        }
        col_pos += w;
    }
    // Fill rest of header
    if (col_pos < cols) {
        try writeRepeat(writer, ' ', cols - col_pos);
    }
    try writer.write(COLOR_RESET);
    try writer.write(CSI ++ "K\n");

    // --- Data rows ---
    var rows_drawn: usize = 0;
    while (rows_drawn < visible) : (rows_drawn += 1) {
        const ri = state.scroll_row + rows_drawn;
        if (ri >= data.rows.len) {
            // Empty line
            try writer.write(CSI ++ "K\n");
            continue;
        }

        const is_cursor = ri == state.cursor_row;
        if (is_cursor) try writer.write(COLOR_CURSOR_ROW);

        // Row number
        try writer.write(COLOR_LINE_NR);
        var nr_buf: [16]u8 = undefined;
        const nr_str = std.fmt.bufPrint(&nr_buf, "{d}", .{ri + 1}) catch "?";
        if (nr_str.len < row_nr_width) {
            try writeRepeat(writer, ' ', row_nr_width - nr_str.len);
        }
        try writer.write(nr_str);
        if (is_cursor) try writer.write(COLOR_CURSOR_ROW) else try writer.write(COLOR_RESET);

        col_pos = row_nr_width;
        const row = data.rows[ri];

        for (first_visible_col..data.columns.len) |ci| {
            if (col_pos >= cols) break;
            const w = @min(data.col_widths[ci] + 2, cols - col_pos);
            if (ci < row.len) {
                const cell = row[ci];
                if (!is_cursor) try writer.write(cellColor(cell.kind));
                try writer.print(" {s}", .{truncate(cell.text, w -| 2)});
                const printed = 1 + @min(cell.text.len, w -| 2);
                if (printed < w) {
                    try writeRepeat(writer, ' ', w - printed);
                }
                if (!is_cursor) try writer.write(COLOR_RESET);
            } else {
                try writeRepeat(writer, ' ', w);
            }
            col_pos += w;
        }

        if (is_cursor) {
            if (col_pos < cols) try writeRepeat(writer, ' ', cols - col_pos);
            try writer.write(COLOR_RESET);
        }

        try writer.write(CSI ++ "K\n");
    }
}

fn renderRecord(writer: *BufferedStdoutWriter, state: *const ExploreState) !void {
    const cols: usize = @intCast(state.term_cols);
    const visible = state.visibleRows();
    const data = &state.data;

    // Find max key width for alignment
    var max_key_width: usize = 0;
    for (data.keys) |key| {
        if (key.len > max_key_width) max_key_width = key.len;
    }
    max_key_width = @min(max_key_width, cols / 3);

    // Header
    try writer.write(COLOR_HEADER);
    try writer.print(" Record ({d} fields)", .{data.keys.len});
    const header_len = 11 + digitCount(data.keys.len);
    if (header_len < cols) {
        try writeRepeat(writer, ' ', cols - header_len);
    }
    try writer.write(COLOR_RESET);
    try writer.write(CSI ++ "K\n");

    // Key-value rows
    var rows_drawn: usize = 0;
    while (rows_drawn < visible) : (rows_drawn += 1) {
        const ri = state.scroll_row + rows_drawn;
        if (ri >= data.keys.len) {
            try writer.write(CSI ++ "K\n");
            continue;
        }

        const is_cursor = ri == state.cursor_row;
        if (is_cursor) try writer.write(COLOR_CURSOR_ROW);

        // Key
        if (!is_cursor) try writer.write(COLOR_KEY);
        const key_display = truncate(data.keys[ri], max_key_width);
        try writer.print("  {s}", .{key_display});
        if (key_display.len < max_key_width) {
            try writeRepeat(writer, ' ', max_key_width - key_display.len);
        }
        if (!is_cursor) try writer.write(COLOR_RESET);

        // Separator
        if (!is_cursor) try writer.write(COLOR_BORDER);
        try writer.write(" : ");
        if (!is_cursor) try writer.write(COLOR_RESET);

        // Value
        const val_space = cols -| (max_key_width + 5);
        const cell = data.values[ri];
        if (!is_cursor) try writer.write(cellColor(cell.kind));
        try writer.write(truncate(cell.text, val_space));
        if (!is_cursor) try writer.write(COLOR_RESET);

        if (is_cursor) try writer.write(COLOR_RESET);
        try writer.write(CSI ++ "K\n");
    }
}

fn renderText(writer: *BufferedStdoutWriter, state: *const ExploreState) !void {
    const cols: usize = @intCast(state.term_cols);
    const visible = state.visibleRows();
    const data = &state.data;
    const nr_width = digitCount(data.lines.len) + 1;

    // Header
    try writer.write(COLOR_HEADER);
    const kind_label: []const u8 = if (data.kind == .json_other) " JSON" else " Text";
    try writer.print("{s} ({d} lines)", .{ kind_label, data.lines.len });
    const header_text_len = kind_label.len + 3 + digitCount(data.lines.len) + 7;
    if (header_text_len < cols) {
        try writeRepeat(writer, ' ', cols - header_text_len);
    }
    try writer.write(COLOR_RESET);
    try writer.write(CSI ++ "K\n");

    // Lines
    var rows_drawn: usize = 0;
    while (rows_drawn < visible) : (rows_drawn += 1) {
        const ri = state.scroll_row + rows_drawn;
        if (ri >= data.lines.len) {
            try writer.write(CSI ++ "K\n");
            continue;
        }

        const is_cursor = ri == state.cursor_row;
        if (is_cursor) try writer.write(COLOR_CURSOR_ROW);

        // Line number
        if (!is_cursor) try writer.write(COLOR_LINE_NR);
        var nr_buf: [16]u8 = undefined;
        const nr_str = std.fmt.bufPrint(&nr_buf, "{d}", .{ri + 1}) catch "?";
        if (nr_str.len < nr_width) {
            try writeRepeat(writer, ' ', nr_width - nr_str.len);
        }
        try writer.write(nr_str);
        if (!is_cursor) try writer.write(COLOR_RESET);

        try writer.write(" ");

        // Line content, apply horizontal scroll
        const line = data.lines[ri];
        const display_start = @min(state.scroll_col, line.len);
        const available = cols -| (nr_width + 1);
        const line_slice = line[display_start..];
        const display_text = truncate(line_slice, available);

        // Highlight search match if present
        if (state.search_len > 0 and !state.search_active) {
            try writeWithHighlight(writer, display_text, state.search_buf[0..state.search_len], is_cursor);
        } else {
            try writer.write(display_text);
        }

        if (is_cursor) try writer.write(COLOR_RESET);
        try writer.write(CSI ++ "K\n");
    }
}

fn renderStatusBar(writer: *BufferedStdoutWriter, state: *const ExploreState) !void {
    const cols: usize = @intCast(state.term_cols);

    // Move to last row
    try writer.print(CSI ++ "{d};1H", .{state.term_rows});
    try writer.write(COLOR_STATUS);

    if (state.search_active) {
        // Search prompt
        try writer.write(" /");
        if (state.search_len > 0) {
            try writer.write(state.search_buf[0..state.search_len]);
        }
        const used = 2 + state.search_len;
        if (used < cols) {
            try writeRepeat(writer, ' ', cols - used);
        }
    } else {
        // Normal status
        const mode_label: []const u8 = switch (state.data.kind) {
            .json_array_of_objects => "TABLE",
            .json_object => "RECORD",
            .json_other => "JSON",
            .plain_text => "TEXT",
        };

        const total = state.data.totalRows();
        const pct: usize = if (total == 0) 100 else (state.cursor_row + 1) * 100 / total;

        // Left side: mode + position
        try writer.print(" {s}  row {d}/{d} ({d}%%)", .{
            mode_label,
            state.cursor_row + 1,
            total,
            pct,
        });

        // Show status message or help hint
        if (state.status_msg) |msg| {
            try writer.print("  {s}", .{msg});
        }

        // Right side: key hints
        const hints = " q:quit  /search  arrows:navigate ";
        // Calculate left side length (approximate)
        var left_buf: [128]u8 = undefined;
        const left_str = std.fmt.bufPrint(&left_buf, " {s}  row {d}/{d} ({d}%%)", .{
            mode_label,
            state.cursor_row + 1,
            total,
            pct,
        }) catch "";
        var left_len = left_str.len;
        if (state.status_msg) |msg| {
            left_len += 2 + msg.len;
        }

        if (left_len + hints.len < cols) {
            try writeRepeat(writer, ' ', cols - left_len - hints.len);
            try writer.write(hints);
        } else if (left_len < cols) {
            try writeRepeat(writer, ' ', cols - left_len);
        }
    }

    try writer.write(COLOR_RESET);
}

fn writeWithHighlight(writer: *BufferedStdoutWriter, text: []const u8, pattern: []const u8, is_cursor: bool) !void {
    if (pattern.len == 0 or text.len < pattern.len) {
        try writer.write(text);
        return;
    }

    var i: usize = 0;
    while (i <= text.len - pattern.len) {
        if (caseInsensitiveMatch(text[i..], pattern)) {
            try writer.write(COLOR_MATCH);
            try writer.write(text[i .. i + pattern.len]);
            if (is_cursor) {
                try writer.write(COLOR_CURSOR_ROW);
            } else {
                try writer.write(COLOR_RESET);
            }
            i += pattern.len;
        } else {
            try writer.write(text[i .. i + 1]);
            i += 1;
        }
    }
    if (i < text.len) {
        try writer.write(text[i..]);
    }
}

fn caseInsensitiveMatch(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    for (needle, 0..) |nc, i| {
        const hc = haystack[i];
        const h_lower: u8 = if (hc >= 'A' and hc <= 'Z') hc + 32 else hc;
        const n_lower: u8 = if (nc >= 'A' and nc <= 'Z') nc + 32 else nc;
        if (h_lower != n_lower) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Search
// ---------------------------------------------------------------------------

fn containsCaseInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
        if (caseInsensitiveMatch(haystack[i..], needle)) return true;
    }
    return false;
}

fn searchAllColumns(state: *const ExploreState, row: usize, pattern: []const u8) bool {
    const data = &state.data;
    switch (data.kind) {
        .json_array_of_objects => {
            if (row < data.rows.len) {
                for (data.rows[row]) |cell| {
                    if (containsCaseInsensitive(cell.text, pattern)) return true;
                }
            }
            return false;
        },
        .json_object => {
            if (row < data.keys.len) {
                if (containsCaseInsensitive(data.keys[row], pattern)) return true;
                if (containsCaseInsensitive(data.values[row].text, pattern)) return true;
            }
            return false;
        },
        .json_other, .plain_text => {
            if (row < data.lines.len) {
                return containsCaseInsensitive(data.lines[row], pattern);
            }
            return false;
        },
    }
}

fn searchForwardAllColumns(state: *ExploreState, from_row: usize) ?usize {
    if (state.search_len == 0) return null;
    const pattern = state.search_buf[0..state.search_len];
    const total = state.data.totalRows();

    var row = from_row;
    var checked: usize = 0;
    while (checked < total) : (checked += 1) {
        if (searchAllColumns(state, row, pattern)) {
            return row;
        }
        row = (row + 1) % total;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Utility helpers
// ---------------------------------------------------------------------------

fn cellColor(kind: CellKind) []const u8 {
    return switch (kind) {
        .string => COLOR_STRING,
        .number => COLOR_NUMBER,
        .boolean => COLOR_BOOL,
        .null_val => COLOR_NULL,
        .other => COLOR_DIM,
    };
}

fn truncate(s: []const u8, max_len: usize) []const u8 {
    if (max_len == 0) return "";
    if (s.len <= max_len) return s;
    if (max_len <= 3) return s[0..max_len];
    return s[0 .. max_len - 3];
    // Note: the caller should append "..." if needed for display;
    // for simplicity we just truncate here.
}

fn digitCount(n: usize) usize {
    if (n == 0) return 1;
    var count: usize = 0;
    var v = n;
    while (v > 0) : (v /= 10) {
        count += 1;
    }
    return count;
}

fn writeRepeat(writer: *BufferedStdoutWriter, ch: u8, count: usize) !void {
    var buf: [128]u8 = undefined;
    const fill_len = @min(count, buf.len);
    @memset(buf[0..fill_len], ch);

    var remaining = count;
    while (remaining > 0) {
        const batch = @min(remaining, buf.len);
        try writer.write(buf[0..batch]);
        remaining -= batch;
    }
}

// ---------------------------------------------------------------------------
// Raw terminal mode (self-contained, no external dependency)
// ---------------------------------------------------------------------------

const RawTerminal = struct {
    original: if (builtin.os.tag == .windows) ?u32 else ?std.posix.termios = null,

    fn enable(self: *RawTerminal) !void {
        if (builtin.os.tag == .windows) return;

        const fd = posix.STDIN_FILENO;
        var termios = try std.posix.tcgetattr(fd);
        self.original = termios;

        termios.lflag.ECHO = false;
        termios.lflag.ICANON = false;
        termios.lflag.ISIG = false;
        termios.lflag.IEXTEN = false;

        termios.iflag.IXON = false;
        termios.iflag.ICRNL = false;
        termios.iflag.BRKINT = false;
        termios.iflag.INPCK = false;
        termios.iflag.ISTRIP = false;

        termios.oflag.OPOST = false;

        termios.cflag.CSIZE = .CS8;

        termios.cc[@intFromEnum(std.posix.V.MIN)] = 0;
        termios.cc[@intFromEnum(std.posix.V.TIME)] = 1; // 100ms timeout

        try std.posix.tcsetattr(fd, .FLUSH, termios);
    }

    fn disable(self: *RawTerminal) void {
        if (builtin.os.tag == .windows) return;
        if (self.original) |orig| {
            std.posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, orig) catch {};
        }
    }
};

// ---------------------------------------------------------------------------
// Main entry point
// ---------------------------------------------------------------------------

/// explore - Interactive TUI data explorer
///
/// Reads stdin and presents it in an interactive, navigable TUI.
/// Auto-detects JSON data and selects the best display mode.
///
/// Usage:
///   cat data.json | explore
///   ls -la | explore
///   echo '[{"a":1},{"a":2}]' | explore
pub fn exploreCmd(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    // Handle --help
    for (command.args) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try IO.print(
                \\Usage: explore [OPTIONS]
                \\
                \\Interactive TUI data explorer. Reads data from stdin and
                \\displays it in a navigable terminal interface.
                \\
                \\Modes:
                \\  TABLE   Arrays of JSON objects shown as a table with columns
                \\  RECORD  JSON objects shown as key-value pairs
                \\  TEXT    Plain text shown with line numbers
                \\
                \\Navigation:
                \\  Up/Down, j/k    Move cursor
                \\  Left/Right      Scroll horizontally (table/text)
                \\  PgUp/PgDn       Page up/down
                \\  Home/End, g/G   Jump to beginning/end
                \\  /               Start search
                \\  n               Find next match
                \\  Enter           Confirm search
                \\  q, Escape       Quit
                \\
                \\Examples:
                \\  cat data.json | explore
                \\  ls -la | explore
                \\  echo '[{{"name":"a","val":1}},{{"name":"b","val":2}}]' | explore
                \\
            , .{});
            return 0;
        }
    }

    // Read all stdin
    const input = common.readAllStdin(allocator) catch |err| {
        try IO.eprint("explore: failed to read stdin: {any}\n", .{err});
        return 1;
    };
    defer allocator.free(input);

    if (input.len == 0) {
        try IO.eprint("explore: no input data\n", .{});
        return 1;
    }

    // Parse input data
    var data = parseInputData(allocator, input) catch |err| {
        try IO.eprint("explore: failed to parse data: {any}\n", .{err});
        return 1;
    };
    defer data.deinit(allocator);

    // Determine initial view mode
    const view = switch (data.kind) {
        .json_array_of_objects => ViewMode.table,
        .json_object => ViewMode.record,
        .json_other, .plain_text => ViewMode.text,
    };

    // Get terminal size
    const size = getTerminalSize();

    var state = ExploreState{
        .data = data,
        .view = view,
        .term_rows = size.rows,
        .term_cols = size.cols,
    };

    // Enter raw mode
    var raw = RawTerminal{};
    raw.enable() catch |err| {
        try IO.eprint("explore: failed to enable raw mode: {any}\n", .{err});
        return 1;
    };
    defer raw.disable();

    // Enter alternate screen buffer
    var writer = BufferedStdoutWriter{};
    try writer.write(CSI ++ "?1049h"); // enter alternate screen
    try writer.write(CSI ++ "2J"); // clear screen
    try writer.flush();

    // Ensure we leave alternate screen on exit
    defer {
        writer.write(CSI ++ "?25h") catch {}; // show cursor
        writer.write(CSI ++ "?1049l") catch {}; // leave alternate screen
        writer.flush() catch {};
    }

    // Initial render
    state.clampScroll();
    render(&writer, &state) catch {};

    // Main event loop
    while (true) {
        const kr = readKey() catch break;

        // Refresh terminal size on each iteration (cheap syscall)
        const new_size = getTerminalSize();
        state.term_rows = new_size.rows;
        state.term_cols = new_size.cols;

        if (state.search_active) {
            // Search input mode
            switch (kr.key) {
                .escape => {
                    state.search_active = false;
                    state.search_len = 0;
                    state.status_msg = null;
                },
                .enter => {
                    state.search_active = false;
                    if (state.search_len > 0) {
                        if (searchForwardAllColumns(&state, state.cursor_row)) |found| {
                            state.cursor_row = found;
                            state.search_match_row = found;
                            state.status_msg = "Search: match found";
                        } else {
                            state.status_msg = "Search: no match";
                        }
                    }
                },
                .backspace => {
                    if (state.search_len > 0) {
                        state.search_len -= 1;
                    }
                },
                .other_char => {
                    if (kr.ch >= 32 and kr.ch < 127 and state.search_len < SEARCH_BUF_SIZE - 1) {
                        state.search_buf[state.search_len] = kr.ch;
                        state.search_len += 1;
                    }
                },
                .none => continue,
                else => {},
            }
        } else {
            // Normal navigation mode
            switch (kr.key) {
                .char_q, .escape => break,

                .up, .char_k => {
                    if (state.cursor_row > 0) state.cursor_row -= 1;
                    state.status_msg = null;
                },
                .down, .char_j => {
                    if (state.cursor_row + 1 < state.data.totalRows()) state.cursor_row += 1;
                    state.status_msg = null;
                },
                .left => {
                    if (state.scroll_col > 0) state.scroll_col -= 1;
                },
                .right => {
                    state.scroll_col += 1;
                },
                .page_up => {
                    const jump = state.visibleRows();
                    if (state.cursor_row >= jump) {
                        state.cursor_row -= jump;
                    } else {
                        state.cursor_row = 0;
                    }
                    state.status_msg = null;
                },
                .page_down => {
                    const jump = state.visibleRows();
                    const total = state.data.totalRows();
                    state.cursor_row += jump;
                    if (state.cursor_row >= total and total > 0) {
                        state.cursor_row = total - 1;
                    }
                    state.status_msg = null;
                },
                .home, .char_g => {
                    state.cursor_row = 0;
                    state.scroll_col = 0;
                    state.status_msg = null;
                },
                .end, .char_G => {
                    const total = state.data.totalRows();
                    if (total > 0) state.cursor_row = total - 1;
                    state.status_msg = null;
                },
                .slash => {
                    state.search_active = true;
                    state.search_len = 0;
                    state.status_msg = null;
                },
                .char_n => {
                    // Find next match
                    if (state.search_len > 0) {
                        const start = (state.cursor_row + 1) % state.data.totalRows();
                        if (searchForwardAllColumns(&state, start)) |found| {
                            state.cursor_row = found;
                            state.search_match_row = found;
                            state.status_msg = "Search: next match";
                        } else {
                            state.status_msg = "Search: no more matches";
                        }
                    }
                },
                .char_N => {
                    // Find previous match (search backwards by wrapping forward)
                    if (state.search_len > 0) {
                        const total = state.data.totalRows();
                        if (total > 0) {
                            const pattern = state.search_buf[0..state.search_len];
                            var found: ?usize = null;
                            // Search backwards from cursor
                            var ri: usize = 0;
                            while (ri < total) : (ri += 1) {
                                const check = if (state.cursor_row >= ri + 1) state.cursor_row - ri - 1 else total - (ri + 1 - state.cursor_row);
                                if (searchAllColumns(&state, check, pattern)) {
                                    found = check;
                                    break;
                                }
                            }
                            if (found) |f| {
                                state.cursor_row = f;
                                state.search_match_row = f;
                                state.status_msg = "Search: prev match";
                            } else {
                                state.status_msg = "Search: no more matches";
                            }
                        }
                    }
                },
                .enter => {
                    // Could expand/collapse in future; for now no-op
                },
                .none => continue,
                else => {},
            }
        }

        state.clampScroll();
        render(&writer, &state) catch {};
    }

    return 0;
}
