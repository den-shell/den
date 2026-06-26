/// Escape sequence parser for arrow keys, function keys, etc.
pub const EscapeSequence = enum {
    up_arrow,
    down_arrow,
    left_arrow,
    right_arrow,
    ctrl_left, // Ctrl+Left arrow (word back)
    ctrl_right, // Ctrl+Right arrow (word forward)
    alt_b, // Alt+B (word back)
    alt_f, // Alt+F (word forward)
    alt_d, // Alt+D (delete word forward)
    home,
    end_key,
    delete,
    page_up,
    page_down,
    back_tab, // Shift+Tab (ESC[Z) — reverse completion cycling
    paste_start, // ESC[200~ (bracketed paste begin)
    paste_end, // ESC[201~ (bracketed paste end)
    unknown,

    /// Parse escape sequence from input
    /// Returns null if not a complete sequence yet
    pub fn parse(bytes: []const u8) ?EscapeSequence {
        if (bytes.len < 2) return null;

        // Check for CSI sequence (ESC [)
        if (bytes[0] == 0x1B and bytes[1] == '[') {
            if (bytes.len < 3) return null;

            // Single character sequences
            switch (bytes[2]) {
                'A' => return .up_arrow,
                'B' => return .down_arrow,
                'C' => return .right_arrow,
                'D' => return .left_arrow,
                'H' => return .home,
                'F' => return .end_key,
                'Z' => return .back_tab,
                else => {},
            }

            // Numeric-parameter sequences: ESC[<digits>~ (delete, paste, ...) and
            // ESC[1;5C/D (ctrl arrows). bytes[2] is the first parameter digit.
            // Return null while the parameter is still arriving so multi-digit
            // codes like 200/201 (bracketed paste) are never truncated to .unknown.
            if (bytes[2] >= '0' and bytes[2] <= '9') {
                var idx: usize = 2;
                while (idx < bytes.len and bytes[idx] >= '0' and bytes[idx] <= '9') : (idx += 1) {}
                if (idx >= bytes.len) return null; // still reading digits

                // ESC[<num>~
                if (bytes[idx] == '~') {
                    var num: u32 = 0;
                    for (bytes[2..idx]) |d| num = num * 10 + (d - '0');
                    return switch (num) {
                        1 => .home,
                        3 => .delete,
                        4 => .end_key,
                        5 => .page_up,
                        6 => .page_down,
                        200 => .paste_start,
                        201 => .paste_end,
                        else => .unknown,
                    };
                }

                // ESC[1;5C / ESC[1;5D (ctrl arrows)
                if (bytes[idx] == ';') {
                    if (bytes.len < idx + 3) return null; // need ";5C"/";5D"
                    return switch (bytes[idx + 2]) {
                        'C' => .ctrl_right,
                        'D' => .ctrl_left,
                        else => .unknown,
                    };
                }

                return .unknown;
            }
        }

        // Alt+key sequences (ESC followed by character)
        if (bytes[0] == 0x1B and bytes.len >= 2 and bytes[1] != '[') {
            switch (bytes[1]) {
                'b', 'B' => return .alt_b, // Alt+B (word back)
                'f', 'F' => return .alt_f, // Alt+F (word forward)
                'd', 'D' => return .alt_d, // Alt+D (delete word forward)
                else => return .unknown,
            }
        }

        return .unknown;
    }
};

test "EscapeSequence.parse recognizes arrows and back-tab" {
    const std = @import("std");
    try std.testing.expectEqual(EscapeSequence.up_arrow, EscapeSequence.parse("\x1b[A").?);
    try std.testing.expectEqual(EscapeSequence.down_arrow, EscapeSequence.parse("\x1b[B").?);
    try std.testing.expectEqual(EscapeSequence.back_tab, EscapeSequence.parse("\x1b[Z").?);
    try std.testing.expectEqual(EscapeSequence.ctrl_right, EscapeSequence.parse("\x1b[1;5C").?);
    // Incomplete sequences return null until fully read.
    try std.testing.expectEqual(@as(?EscapeSequence, null), EscapeSequence.parse("\x1b["));
}
