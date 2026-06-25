//! Line Editor - Full-featured line editing with Vi/Emacs modes
//!
//! This module provides an interactive line editor with:
//! - Vi and Emacs editing modes
//! - History navigation with substring search
//! - Reverse incremental search (Ctrl+R)
//! - Tab completion with fuzzy matching
//! - Visual selection mode
//! - Kill ring (cut/paste history)
//! - Undo/redo support
//! - Multi-line input handling
//! - Macro recording/playback
//! - Inline suggestions from history

const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");

// Import from sibling modules
const Terminal = @import("terminal.zig").Terminal;
const windows = @import("terminal.zig").windows;
const EscapeSequence = @import("escape.zig").EscapeSequence;
const types = @import("types.zig");
const CompletionFn = types.CompletionFn;
const EditingMode = types.EditingMode;
const ViMode = types.ViMode;

// Import from parent utils directory
const SyntaxHighlighter = @import("../syntax_highlight.zig").SyntaxHighlighter;
const cpu_opt = @import("../cpu_opt.zig");
const signals = @import("../signals.zig");

/// Line editor with history support
pub const LineEditor = struct {
    allocator: std.mem.Allocator,
    buffer: [4096]u8 = undefined,
    cursor: usize = 0,
    length: usize = 0,
    terminal: Terminal = .{},
    prompt: []const u8 = "",
    ps2_prompt: []const u8 = "> ", // Continuation prompt for multi-line input
    history: ?*[1000]?[]const u8 = null,
    history_count: ?*usize = null,
    history_index: ?usize = null,
    saved_line: ?[]const u8 = null, // Save current line when browsing history
    history_search_query: ?[]const u8 = null, // Substring to filter history (for substring search)
    completion_fn: ?CompletionFn = null, // Callback for tab completion
    // Completion cycling state
    completion_list: ?[][]const u8 = null,
    completion_index: usize = 0,
    completion_word_start: usize = 0,
    completion_path_prefix: ?[]const u8 = null, // Save the path prefix (e.g., "Documents/Projects/")
    // Inline suggestion state
    suggestion: ?[]const u8 = null, // The suggested text from history
    // Syntax highlighting
    syntax_highlighting: bool = true, // Enable/disable syntax highlighting
    // Wrap-aware redraw: cursor's display row (0-based) within the wrapped line
    // at the last redrawLine(), so the next redraw can move back to the block top.
    rendered_cursor_row: usize = 0,
    // Inline autosuggestions (fish-style)
    autosuggestions: bool = true, // Enable/disable inline autosuggestions
    suggestion_min_chars: usize = 1, // Minimum chars typed before suggesting
    // Prompt refresh callback
    prompt_refresh_fn: ?*const fn (*LineEditor) anyerror!void = null,
    // User data for callbacks (e.g., pointer to Shell)
    user_data: ?*anyopaque = null,
    // Reverse search mode (Ctrl+R)
    reverse_search_mode: bool = false,
    reverse_search_query: [256]u8 = undefined,
    reverse_search_query_len: usize = 0,
    reverse_search_match: ?[]const u8 = null,
    reverse_search_history_index: usize = 0,
    // Undo/Redo support
    undo_stack: [50]UndoState = undefined,
    undo_stack_size: usize = 0,
    undo_index: usize = 0, // Current position in undo stack
    // Multi-line input support
    multiline_buffer: ?std.ArrayList(u8) = null, // Accumulated multi-line input
    in_multiline: bool = false, // Currently in multi-line mode
    // Editing mode (Emacs or Vi)
    editing_mode: EditingMode = .emacs,
    // Vi mode state
    vi_mode: ViMode = .insert,
    // Vi pending operator (for d, c, y commands)
    vi_pending_op: ?u8 = null,
    // Vi repeat count
    vi_count: usize = 0,
    // Vi last command for repeat with '.'
    vi_last_cmd: ?u8 = null,
    vi_last_count: usize = 1,
    // Emacs-style kill ring
    kill_ring: [16][4096]u8 = undefined,
    kill_ring_lens: [16]usize = @splat(0),
    kill_ring_count: usize = 0,
    kill_ring_index: usize = 0, // Current position for yank-pop
    // Fuzzy search mode (Ctrl+S to toggle during reverse search)
    fuzzy_search_mode: bool = false,
    // Visual selection mode (Ctrl+Space to start, movement keys to expand)
    visual_mode: bool = false,
    visual_start: usize = 0, // Start of selection
    // Macro recording/playback
    macro_recording: bool = false,
    macro_buffer: [1024]u8 = undefined,
    macro_len: usize = 0,
    macro_stored: [1024]u8 = undefined,
    macro_stored_len: usize = 0,
    // Transient prompt support
    transient_prompt: ?[]const u8 = null, // Minimal prompt to replace full prompt after Enter

    const UndoState = struct {
        buffer: [4096]u8,
        length: usize,
        cursor: usize,
    };

    pub fn init(allocator: std.mem.Allocator, prompt: []const u8) LineEditor {
        return .{
            .allocator = allocator,
            .prompt = prompt,
        };
    }

    pub fn setHistory(self: *LineEditor, history: *[1000]?[]const u8, count: *usize) void {
        self.history = history;
        self.history_count = count;
    }

    pub fn setCompletionFn(self: *LineEditor, completion_fn: CompletionFn) void {
        self.completion_fn = completion_fn;
    }

    pub fn setPromptRefreshFn(self: *LineEditor, refresh_fn: *const fn (*LineEditor) anyerror!void) void {
        self.prompt_refresh_fn = refresh_fn;
    }

    pub fn setPs2Prompt(self: *LineEditor, ps2: []const u8) void {
        self.ps2_prompt = ps2;
    }

    /// Set the transient prompt (minimal prompt shown after command execution)
    pub fn setTransientPrompt(self: *LineEditor, transient: []const u8) void {
        self.transient_prompt = transient;
    }

    /// Set the editing mode (Emacs or Vi)
    pub fn setEditingMode(self: *LineEditor, mode: EditingMode) void {
        self.editing_mode = mode;
        if (mode == .vi) {
            // Vi mode starts in insert mode
            self.vi_mode = .insert;
        }
    }

    /// Switch to Vi insert mode
    fn viEnterInsertMode(self: *LineEditor) void {
        self.vi_mode = .insert;
        self.vi_pending_op = null;
        self.vi_count = 0;
    }

    /// Switch to Vi normal mode
    fn viEnterNormalMode(self: *LineEditor) void {
        self.vi_mode = .normal;
        self.vi_pending_op = null;
        self.vi_count = 0;
        // Move cursor back one if not at start (vi convention)
        if (self.cursor > 0 and self.cursor == self.length) {
            self.cursor -= 1;
        }
    }

    /// Handle Vi normal mode key press
    fn handleViNormalKey(self: *LineEditor, char: u8) !bool {
        const count = if (self.vi_count == 0) 1 else self.vi_count;

        switch (char) {
            // Mode switching
            'i' => {
                self.viEnterInsertMode();
                return false;
            },
            'I' => {
                self.cursor = 0;
                self.viEnterInsertMode();
                return false;
            },
            'a' => {
                if (self.cursor < self.length) {
                    self.cursor += 1;
                }
                self.viEnterInsertMode();
                return false;
            },
            'A' => {
                self.cursor = self.length;
                self.viEnterInsertMode();
                return false;
            },
            'o', 'O' => {
                // In line editor, just go to end and insert
                self.cursor = self.length;
                self.viEnterInsertMode();
                return false;
            },
            's' => {
                // Substitute: delete char and enter insert mode
                if (self.cursor < self.length) {
                    try self.deleteChar();
                }
                self.viEnterInsertMode();
                return false;
            },
            'S', 'C' => {
                // Change line from cursor / substitute entire line
                self.length = if (char == 'S') 0 else self.cursor;
                if (char == 'S') self.cursor = 0;
                self.viEnterInsertMode();
                try self.redrawLine();
                return false;
            },
            'R' => {
                self.vi_mode = .replace;
                return false;
            },

            // Navigation
            'h' => {
                for (0..count) |_| {
                    try self.moveCursorLeft();
                }
                return false;
            },
            'l' => {
                for (0..count) |_| {
                    try self.moveCursorRight();
                }
                return false;
            },
            '0' => {
                if (self.vi_count == 0) {
                    // Go to beginning of line
                    self.cursor = 0;
                    try self.redrawLine();
                } else {
                    // It's a count digit
                    self.vi_count = self.vi_count * 10;
                }
                return false;
            },
            '$' => {
                self.cursor = if (self.length > 0) self.length - 1 else 0;
                try self.redrawLine();
                return false;
            },
            '^' => {
                // Go to first non-blank
                self.cursor = 0;
                while (self.cursor < self.length and (self.buffer[self.cursor] == ' ' or self.buffer[self.cursor] == '\t')) {
                    self.cursor += 1;
                }
                try self.redrawLine();
                return false;
            },
            'w' => {
                // Move forward word
                for (0..count) |_| {
                    self.moveForwardWord();
                }
                try self.redrawLine();
                return false;
            },
            'b' => {
                // Move backward word
                for (0..count) |_| {
                    self.moveBackwardWord();
                }
                try self.redrawLine();
                return false;
            },
            'e' => {
                // Move to end of word
                for (0..count) |_| {
                    self.moveToEndOfWord();
                }
                try self.redrawLine();
                return false;
            },

            // Editing
            'x' => {
                // Delete character under cursor
                for (0..count) |_| {
                    if (self.cursor < self.length) {
                        try self.deleteChar();
                    }
                }
                return false;
            },
            'X' => {
                // Delete character before cursor
                for (0..count) |_| {
                    if (self.cursor > 0) {
                        try self.backspace();
                    }
                }
                return false;
            },
            'D' => {
                // Delete to end of line
                self.length = self.cursor;
                try self.redrawLine();
                return false;
            },
            'd' => {
                if (self.vi_pending_op == 'd') {
                    // dd - delete entire line
                    self.length = 0;
                    self.cursor = 0;
                    self.vi_pending_op = null;
                    try self.redrawLine();
                } else {
                    self.vi_pending_op = 'd';
                }
                return false;
            },
            'c' => {
                if (self.vi_pending_op == 'c') {
                    // cc - change entire line
                    self.length = 0;
                    self.cursor = 0;
                    self.vi_pending_op = null;
                    self.viEnterInsertMode();
                    try self.redrawLine();
                } else {
                    self.vi_pending_op = 'c';
                }
                return false;
            },

            // History
            'j' => {
                try self.historyNext();
                return false;
            },
            'k' => {
                try self.historyPrevious();
                return false;
            },

            // Undo/Redo
            'u' => {
                try self.undo();
                return false;
            },

            // Search
            '/' => {
                try self.startReverseSearch();
                return false;
            },
            'n' => {
                try self.continueReverseSearch();
                return false;
            },

            // Count digits
            '1', '2', '3', '4', '5', '6', '7', '8', '9' => {
                self.vi_count = self.vi_count * 10 + (char - '0');
                return false;
            },

            // Execute line
            '\r', '\n' => {
                return true; // Signal to execute
            },

            else => {
                self.vi_pending_op = null;
                self.vi_count = 0;
                return false;
            },
        }
    }

    /// Move forward by one word (vi style)
    fn moveForwardWord(self: *LineEditor) void {
        // Skip current word
        while (self.cursor < self.length and !isWordChar(self.buffer[self.cursor])) {
            self.cursor += 1;
        }
        while (self.cursor < self.length and isWordChar(self.buffer[self.cursor])) {
            self.cursor += 1;
        }
    }

    /// Move backward by one word (vi style)
    fn moveBackwardWord(self: *LineEditor) void {
        if (self.cursor == 0) return;
        self.cursor -= 1;
        // Skip spaces
        while (self.cursor > 0 and !isWordChar(self.buffer[self.cursor])) {
            self.cursor -= 1;
        }
        // Find start of word
        while (self.cursor > 0 and isWordChar(self.buffer[self.cursor - 1])) {
            self.cursor -= 1;
        }
    }

    /// Move to end of current word
    fn moveToEndOfWord(self: *LineEditor) void {
        if (self.cursor >= self.length) return;
        self.cursor += 1;
        // Skip spaces
        while (self.cursor < self.length and !isWordChar(self.buffer[self.cursor])) {
            self.cursor += 1;
        }
        // Find end of word
        while (self.cursor < self.length - 1 and isWordChar(self.buffer[self.cursor + 1])) {
            self.cursor += 1;
        }
    }

    fn isWordChar(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_';
    }

    /// Check if input is incomplete and needs continuation
    /// Returns true if:
    /// - Line ends with backslash (line continuation)
    /// - Unclosed single or double quotes
    /// - Unclosed parentheses, brackets, or braces
    pub fn isIncomplete(input: []const u8) bool {
        if (input.len == 0) return false;

        // Check for backslash continuation at end of line
        // A trailing backslash (not escaped) indicates continuation
        var trailing_backslashes: usize = 0;
        var i: usize = input.len;
        while (i > 0) {
            i -= 1;
            if (input[i] == '\\') {
                trailing_backslashes += 1;
            } else {
                break;
            }
        }
        // Odd number of backslashes at end means continuation
        if (trailing_backslashes % 2 == 1) return true;

        // Check for unclosed quotes and brackets
        var in_single_quote = false;
        var in_double_quote = false;
        var paren_depth: i32 = 0;
        var brace_depth: i32 = 0;
        var bracket_depth: i32 = 0;

        i = 0;
        while (i < input.len) : (i += 1) {
            const c = input[i];

            // Handle escape sequences (only in double quotes or unquoted)
            if (c == '\\' and !in_single_quote and i + 1 < input.len) {
                i += 1; // Skip escaped character
                continue;
            }

            // Handle quotes
            if (c == '\'' and !in_double_quote) {
                in_single_quote = !in_single_quote;
                continue;
            }
            if (c == '"' and !in_single_quote) {
                in_double_quote = !in_double_quote;
                continue;
            }

            // Only count brackets outside quotes
            if (!in_single_quote and !in_double_quote) {
                switch (c) {
                    '(' => paren_depth += 1,
                    ')' => paren_depth -= 1,
                    '{' => brace_depth += 1,
                    '}' => brace_depth -= 1,
                    '[' => bracket_depth += 1,
                    ']' => bracket_depth -= 1,
                    else => {},
                }
            }
        }

        // Input is incomplete if any quotes are unclosed or brackets unbalanced
        return in_single_quote or in_double_quote or paren_depth > 0 or brace_depth > 0 or bracket_depth > 0;
    }

    /// Read a line with editing support
    pub fn readLine(self: *LineEditor) !?[]u8 {

        // Display prompt BEFORE entering raw mode so ANSI codes work
        try self.displayPrompt();

        // Enable raw mode after displaying prompt
        try self.terminal.enableRawMode();
        errdefer self.terminal.disableRawMode() catch {};

        // Enable bracketed paste so the terminal wraps pasted text in
        // ESC[200~ ... ESC[201~. The defer disables it on every exit path so we
        // never leave the user's terminal stuck in bracketed-paste mode after
        // Den hands control back. See handlePaste for how the text is consumed.
        self.writeBytes("\x1B[?2004h") catch {};
        defer self.writeBytes("\x1B[?2004l") catch {};

        // Reset state
        self.cursor = 0;
        self.length = 0;
        // Fresh line: the prompt was just printed at the current row, so the
        // cursor is on row 0 of this line's (not-yet-wrapped) block.
        self.rendered_cursor_row = 0;
        self.history_index = null;
        if (self.saved_line) |saved| {
            self.allocator.free(saved);
            self.saved_line = null;
        }

        var escape_buffer: [8]u8 = undefined;
        var escape_len: usize = 0;
        var in_escape: bool = false;

        while (true) {
            // Check for window resize (SIGWINCH)
            if (signals.checkWindowSizeChanged()) {
                // Terminal was resized - redraw the current line
                try self.handleWindowResize();
            }

            const byte = (try self.terminal.readByte()) orelse {
                // No data, sleep briefly (10ms)
                std.Io.sleep(std.Options.debug_io, std.Io.Duration.fromNanoseconds(@as(i96, 10_000_000)), .awake) catch {};
                continue;
            };

            // Handle escape sequences
            if (in_escape) {
                escape_buffer[escape_len] = byte;
                escape_len += 1;

                if (EscapeSequence.parse(escape_buffer[0..escape_len])) |seq| {
                    try self.handleEscapeSequence(seq);
                    in_escape = false;
                    escape_len = 0;
                } else if (escape_len >= escape_buffer.len) {
                    // Invalid sequence, ignore
                    in_escape = false;
                    escape_len = 0;
                }
                continue;
            }

            // Check for escape start
            if (byte == 0x1B) {
                // In Vi insert mode, ESC switches to normal mode
                if (self.editing_mode == .vi and (self.vi_mode == .insert or self.vi_mode == .replace)) {
                    // Wait briefly to see if this is an escape sequence
                    std.Io.sleep(std.Options.debug_io, std.Io.Duration.fromNanoseconds(@as(i96, 50_000_000)), .awake) catch {}; // 50ms
                    if (try self.terminal.readByte()) |next_byte| {
                        // There's a follow-up - it's an escape sequence, handle normally
                        escape_buffer[0] = byte;
                        escape_buffer[1] = next_byte;
                        escape_len = 2;
                        in_escape = true;
                        continue;
                    } else {
                        // No follow-up byte - this is just ESC, switch to normal mode
                        self.viEnterNormalMode();
                        try self.redrawLine();
                        continue;
                    }
                }
                // Cancel visual mode on ESC (if standalone)
                if (self.visual_mode) {
                    std.Io.sleep(std.Options.debug_io, std.Io.Duration.fromNanoseconds(@as(i96, 50_000_000)), .awake) catch {}; // 50ms
                    if (try self.terminal.readByte()) |next_byte| {
                        // There's a follow-up - it's an escape sequence, handle normally
                        escape_buffer[0] = byte;
                        escape_buffer[1] = next_byte;
                        escape_len = 2;
                        in_escape = true;
                        continue;
                    } else {
                        // No follow-up byte - cancel visual mode
                        try self.cancelVisualMode();
                        continue;
                    }
                }
                escape_buffer[0] = byte;
                escape_len = 1;
                in_escape = true;
                continue;
            }

            // Handle special characters
            switch (byte) {
                '\r', '\n' => {
                    // Enter key
                    // If in reverse search mode, accept the match
                    if (self.reverse_search_mode) {
                        try self.acceptReverseSearch();
                        if (self.length > 0) {
                            try self.writeBytes("\r\n");
                            try self.terminal.disableRawMode();
                            return try self.allocator.dupe(u8, self.buffer[0..self.length]);
                        }
                        continue;
                    }

                    // If we have an active completion list, accept it instead of submitting
                    if (self.completion_list != null) {
                        self.clearCompletionState();
                        continue;
                    }

                    // Get current line content
                    const current_line = self.buffer[0..self.length];

                    // Build complete input (accumulated + current line)
                    var complete_input: []const u8 = undefined;

                    if (self.multiline_buffer) |*mlb| {
                        // Add newline and current line to accumulated buffer
                        try mlb.append(self.allocator, '\n');
                        try mlb.appendSlice(self.allocator, current_line);
                        complete_input = mlb.items;
                    } else {
                        complete_input = current_line;
                    }

                    // Check if input is incomplete (needs continuation)
                    if (isIncomplete(complete_input)) {
                        // Initialize multiline buffer if not already done
                        if (self.multiline_buffer == null) {
                            self.multiline_buffer = .empty;
                            try self.multiline_buffer.?.appendSlice(self.allocator, current_line);
                        }
                        self.in_multiline = true;

                        // Move to next line and show PS2 prompt
                        try self.writeBytes("\r\n");
                        try self.writeBytes(self.ps2_prompt);

                        // Reset buffer for next line input
                        self.length = 0;
                        self.cursor = 0;
                        continue;
                    }

                    // Input is complete - redraw with transient prompt if enabled
                    if (self.transient_prompt) |transient| {
                        // Count newlines in the original prompt to handle multi-line prompts
                        var newline_count: usize = 0;
                        for (self.prompt) |ch| {
                            if (ch == '\n') newline_count += 1;
                        }
                        // Move cursor up for each newline in the prompt
                        if (newline_count > 0) {
                            var move_buf: [32]u8 = undefined;
                            const move_seq = std.fmt.bufPrint(&move_buf, "\x1b[{d}A", .{newline_count}) catch "\x1b[1A";
                            try self.writeBytes(move_seq);
                        }
                        // Move to start of line and clear from here to end of screen
                        try self.writeBytes("\r\x1b[J");
                        // Write the transient (minimal) prompt + the typed command
                        try self.writeBytes(transient);
                        try self.writeBytes(self.buffer[0..self.length]);
                    }

                    try self.writeBytes("\r\n");
                    try self.terminal.disableRawMode();

                    // Return the complete multi-line input or single line
                    if (self.multiline_buffer) |*mlb| {
                        const result = try self.allocator.dupe(u8, mlb.items);
                        mlb.deinit(self.allocator);
                        self.multiline_buffer = null;
                        self.in_multiline = false;
                        return result;
                    }

                    if (self.length == 0) return try self.allocator.dupe(u8, "");
                    return try self.allocator.dupe(u8, self.buffer[0..self.length]);
                },
                0x03 => {
                    // Ctrl+C
                    if (self.reverse_search_mode) {
                        // Cancel reverse search and clear line
                        try self.cancelReverseSearch();
                        try self.writeBytes("\r\n");
                        try self.writeBytes(self.prompt);
                        self.length = 0;
                        self.cursor = 0;
                        continue;
                    }

                    // If completion list is showing, just dismiss it and reset the line
                    if (self.completion_list != null) {
                        self.clearCompletionState();
                        // Clear current input and show fresh prompt
                        try self.writeBytes("^C\r\n");
                        try self.displayPrompt();
                        self.length = 0;
                        self.cursor = 0;
                        continue;
                    }

                    // Clear multi-line buffer if in multi-line mode
                    if (self.multiline_buffer) |*mlb| {
                        mlb.deinit(self.allocator);
                        self.multiline_buffer = null;
                        self.in_multiline = false;
                    }

                    // If no input was typed, just show a fresh prompt
                    // (avoids duplicate prompt after Ctrl+C'ing an external command)
                    if (self.length == 0) {
                        try self.writeBytes("\r\n");
                        try self.displayPrompt();
                        continue;
                    }

                    try self.writeBytes("^C\r\n");
                    try self.terminal.disableRawMode();
                    return error.Interrupted;
                },
                0x04 => {
                    // Ctrl+D (EOF)
                    if (self.length == 0) {
                        // Clear any visible completion list first
                        if (self.completion_list != null) {
                            try self.clearCompletionDisplay();
                        }
                        try self.writeBytes("\r\n");
                        try self.terminal.disableRawMode();
                        return null; // Signal EOF
                    }
                    // Otherwise, delete character under cursor
                    try self.deleteChar();
                },
                0x01 => {
                    self.clearCompletionState();
                    try self.moveCursorHome(); // Ctrl+A
                },
                0x05 => {
                    self.clearCompletionState();
                    try self.moveCursorEnd(); // Ctrl+E
                },
                0x02 => {
                    self.clearCompletionState();
                    try self.moveCursorLeft(); // Ctrl+B
                },
                0x06 => {
                    self.clearCompletionState();
                    try self.moveCursorRight(); // Ctrl+F
                },
                0x0B => {
                    self.clearCompletionState();
                    try self.killToEnd(); // Ctrl+K - kill to end of line (clear-screen is Ctrl+L)
                },
                0x0C => {
                    self.clearCompletionState();
                    try self.clearScreen(); // Ctrl+L
                },
                0x14 => {
                    self.clearCompletionState();
                    try self.transposeChars(); // Ctrl+T
                },
                0x00 => {
                    // Ctrl+Space - start visual selection mode
                    if (!self.visual_mode) {
                        try self.startVisualMode();
                    }
                },
                0x15 => {
                    self.clearCompletionState();
                    if (self.visual_mode) {
                        try self.cutSelection(); // Cut selection in visual mode
                    } else {
                        try self.killToStart(); // Ctrl+U
                    }
                },
                0x17 => {
                    self.clearCompletionState();
                    if (self.visual_mode) {
                        try self.copySelection(); // Copy selection in visual mode
                    } else {
                        try self.killWordBackward(); // Ctrl+W - kill word backward (saves to kill ring)
                    }
                },
                0x18 => {
                    // Ctrl+X prefix for extended commands
                    // Read next character for the command
                    const next_byte = (try self.terminal.readByte()) orelse continue;
                    switch (next_byte) {
                        '(' => try self.startMacroRecording(),
                        ')' => try self.stopMacroRecording(),
                        'e' => try self.playMacro(),
                        else => {},
                    }
                },
                0x19 => {
                    self.clearCompletionState();
                    try self.yank(); // Ctrl+Y - yank (paste from kill ring)
                },
                0x10 => {
                    self.clearCompletionState();
                    try self.historyPrevious(); // Ctrl+P - previous history (like Up arrow)
                },
                0x0E => {
                    self.clearCompletionState();
                    try self.historyNext(); // Ctrl+N - next history (like Down arrow)
                },
                0x1F => {
                    self.clearCompletionState();
                    try self.undo(); // Ctrl+_ (undo)
                },
                0x12 => {
                    // Ctrl+R - Reverse search
                    if (self.reverse_search_mode) {
                        // Already in search mode - find next match
                        try self.continueReverseSearch();
                    } else {
                        // Enter reverse search mode
                        try self.startReverseSearch();
                    }
                },
                0x13 => {
                    // Ctrl+S - toggle fuzzy search mode (during reverse search)
                    if (self.reverse_search_mode) {
                        try self.toggleFuzzySearch();
                    }
                },
                0x09 => {
                    // Tab - handle completion
                    if (!self.reverse_search_mode) {
                        try self.handleTabCompletion();
                    }
                },
                0x7F, 0x08 => {
                    // Backspace (DEL or BS)
                    if (self.reverse_search_mode) {
                        // Delete character from search query
                        if (self.reverse_search_query_len > 0) {
                            self.reverse_search_query_len -= 1;
                            if (self.history_count) |count| {
                                self.reverse_search_history_index = count.*;
                            }
                            try self.updateReverseSearch();
                        }
                    } else {
                        self.clearCompletionState();
                        try self.backspace();
                    }
                },
                0x20...0x7E => {
                    // Printable ASCII
                    if (self.reverse_search_mode) {
                        // Add character to search query
                        if (self.reverse_search_query_len < self.reverse_search_query.len) {
                            self.reverse_search_query[self.reverse_search_query_len] = byte;
                            self.reverse_search_query_len += 1;
                            if (self.history_count) |count| {
                                self.reverse_search_history_index = count.*;
                            }
                            try self.updateReverseSearch();
                        }
                    } else if (self.editing_mode == .vi and self.vi_mode == .normal) {
                        // Vi normal mode - handle navigation/commands
                        const should_execute = try self.handleViNormalKey(byte);
                        if (should_execute) {
                            // Check for multi-line
                            const current_input = self.buffer[0..self.length];
                            if (isIncomplete(current_input)) {
                                try self.writeBytes("\r\n");
                                try self.displayPrompt();
                                continue;
                            }
                            try self.writeBytes("\r\n");
                            try self.terminal.disableRawMode();
                            return try self.allocator.dupe(u8, self.buffer[0..self.length]);
                        }
                    } else if (self.editing_mode == .vi and self.vi_mode == .replace) {
                        // Vi replace mode - replace character under cursor
                        if (self.cursor < self.length) {
                            self.buffer[self.cursor] = byte;
                            if (self.cursor < self.length - 1) {
                                self.cursor += 1;
                            }
                            try self.redrawLine();
                        } else {
                            try self.insertChar(byte);
                        }
                    } else {
                        // Emacs mode or Vi insert mode
                        self.clearCompletionState();
                        try self.insertChar(byte);
                    }
                },
                0xC2...0xF4 => {
                    // UTF-8 lead byte — assemble and insert the full codepoint so
                    // accented/CJK/emoji input works. Ignored during reverse search.
                    if (!self.reverse_search_mode) {
                        self.clearCompletionState();
                        try self.insertUtf8(byte);
                    }
                },
                else => {
                    // Ignore other control / stray continuation bytes
                },
            }
        }
    }

    fn displayPrompt(self: *LineEditor) !void {
        try self.writeBytes(self.prompt);
        // Flush stdout to ensure prompt is displayed before entering raw mode
        if (comptime builtin.os.tag != .windows) {
            // Force flush by calling fsync on stdout
            _ = std.c.fsync(posix.STDOUT_FILENO);
        }
    }

    /// Clear history search state (called when user modifies the line during search)
    fn clearHistorySearch(self: *LineEditor) void {
        if (self.history_search_query) |query| {
            self.allocator.free(query);
            self.history_search_query = null;
        }
        self.history_index = null;
        if (self.saved_line) |saved| {
            self.allocator.free(saved);
            self.saved_line = null;
        }
    }

    /// Start reverse search mode (Ctrl+R)
    fn startReverseSearch(self: *LineEditor) !void {
        _ = self.history orelse return;
        const count = self.history_count orelse return;
        if (count.* == 0) return;

        self.reverse_search_mode = true;
        self.reverse_search_query_len = 0;
        self.reverse_search_history_index = count.*;
        try self.updateReverseSearch();
    }

    /// Update reverse search with current query
    /// Supports both substring match (default) and fuzzy match (toggle with Ctrl+S)
    fn updateReverseSearch(self: *LineEditor) !void {
        const history = self.history orelse return;
        _ = self.history_count orelse return;

        const query = self.reverse_search_query[0..self.reverse_search_query_len];

        if (self.fuzzy_search_mode) {
            // Fuzzy search: find best matching entry by score
            var best_match: ?[]const u8 = null;
            var best_score: u8 = 0;
            var best_index: usize = 0;

            var i = self.reverse_search_history_index;
            while (i > 0) {
                i -= 1;
                if (history[i]) |entry| {
                    if (query.len == 0) {
                        self.reverse_search_match = entry;
                        self.reverse_search_history_index = i;
                        try self.redrawReverseSearch();
                        return;
                    }
                    const score = cpu_opt.fuzzyScore(entry, query);
                    if (score > best_score) {
                        best_score = score;
                        best_match = entry;
                        best_index = i;
                    }
                }
            }

            if (best_match) |match| {
                self.reverse_search_match = match;
                self.reverse_search_history_index = best_index;
            }
        } else {
            // Substring search: find exact substring match
            var i = self.reverse_search_history_index;
            while (i > 0) {
                i -= 1;
                if (history[i]) |entry| {
                    // Check if entry contains the query
                    if (query.len == 0 or std.mem.indexOf(u8, entry, query) != null) {
                        self.reverse_search_match = entry;
                        self.reverse_search_history_index = i;
                        try self.redrawReverseSearch();
                        return;
                    }
                }
            }
        }

        // No match found - keep current match or show no results
        try self.redrawReverseSearch();
    }

    /// Toggle between fuzzy and substring search modes
    fn toggleFuzzySearch(self: *LineEditor) !void {
        self.fuzzy_search_mode = !self.fuzzy_search_mode;
        // Re-run search with new mode
        if (self.history_count) |count| {
            self.reverse_search_history_index = count.*;
        }
        try self.updateReverseSearch();
    }

    /// Continue reverse search (find next match) - called when user presses Ctrl+R again
    fn continueReverseSearch(self: *LineEditor) !void {
        if (!self.reverse_search_mode) return;
        if (self.reverse_search_history_index > 0) {
            self.reverse_search_history_index -= 1;
            try self.updateReverseSearch();
        }
    }

    /// Redraw the reverse search prompt and matched line
    fn redrawReverseSearch(self: *LineEditor) !void {
        // Clear current line
        try self.writeBytes("\r\x1B[K");

        // Show reverse search prompt (indicate fuzzy mode with 'f')
        const query = self.reverse_search_query[0..self.reverse_search_query_len];
        const mode_prefix = if (self.fuzzy_search_mode) "fuzzy-" else "";
        var prompt_buf: [512]u8 = undefined;
        const search_prompt = if (self.reverse_search_match) |match|
            try std.fmt.bufPrint(&prompt_buf, "({s}reverse-i-search)`{s}': {s}", .{ mode_prefix, query, match })
        else
            try std.fmt.bufPrint(&prompt_buf, "(failed {s}reverse-i-search)`{s}': ", .{ mode_prefix, query });

        try self.writeBytes(search_prompt);
    }

    /// Accept reverse search result
    fn acceptReverseSearch(self: *LineEditor) !void {
        if (self.reverse_search_match) |match| {
            // Copy match to buffer
            const len = @min(match.len, self.buffer.len);
            @memcpy(self.buffer[0..len], match[0..len]);
            self.length = len;
            self.cursor = len;
        }
        try self.cancelReverseSearch();
    }

    /// Cancel reverse search mode
    fn cancelReverseSearch(self: *LineEditor) !void {
        self.reverse_search_mode = false;
        self.reverse_search_match = null;
        self.reverse_search_query_len = 0;
        self.reverse_search_history_index = 0;

        // Redraw normal prompt and buffer
        try self.writeBytes("\r\x1B[K");
        try self.writeBytes(self.prompt);
        try self.writeBytes(self.buffer[0..self.length]);

        // Move cursor to end
        self.cursor = self.length;
    }

    /// Start visual selection mode (Ctrl+Space)
    fn startVisualMode(self: *LineEditor) !void {
        self.visual_mode = true;
        self.visual_start = self.cursor;
        try self.redrawWithSelection();
    }

    /// Cancel visual selection mode (Escape)
    fn cancelVisualMode(self: *LineEditor) !void {
        self.visual_mode = false;
        try self.redrawLine();
    }

    /// Get the selected text range (start, end)
    fn getSelectionRange(self: *LineEditor) struct { start: usize, end: usize } {
        if (self.cursor < self.visual_start) {
            return .{ .start = self.cursor, .end = self.visual_start };
        } else {
            return .{ .start = self.visual_start, .end = self.cursor };
        }
    }

    /// Copy selected text to kill ring
    fn copySelection(self: *LineEditor) !void {
        if (!self.visual_mode) return;

        const range = self.getSelectionRange();
        if (range.end > range.start) {
            self.pushToKillRing(self.buffer[range.start..range.end]);
        }
        try self.cancelVisualMode();
    }

    /// Cut selected text (copy to kill ring and delete)
    fn cutSelection(self: *LineEditor) !void {
        if (!self.visual_mode) return;

        self.saveUndoState();
        const range = self.getSelectionRange();

        if (range.end > range.start) {
            // Save to kill ring
            self.pushToKillRing(self.buffer[range.start..range.end]);

            // Delete the selection
            const deleted_len = range.end - range.start;
            const remaining = self.length - range.end;
            var i: usize = 0;
            while (i < remaining) : (i += 1) {
                self.buffer[range.start + i] = self.buffer[range.end + i];
            }
            self.length -= deleted_len;
            self.cursor = range.start;
        }

        self.visual_mode = false;
        try self.redrawLine();
    }

    /// Redraw line with selection highlighting
    fn redrawWithSelection(self: *LineEditor) !void {
        try self.writeBytes("\r\x1B[K");
        try self.writeBytes(self.prompt);

        const range = self.getSelectionRange();

        // Write text before selection
        if (range.start > 0) {
            try self.writeBytes(self.buffer[0..range.start]);
        }

        // Write selected text with inverted colors
        if (range.end > range.start) {
            try self.writeBytes("\x1B[7m"); // Inverse video (highlight)
            try self.writeBytes(self.buffer[range.start..range.end]);
            try self.writeBytes("\x1B[27m"); // Normal video
        }

        // Write text after selection
        if (range.end < self.length) {
            try self.writeBytes(self.buffer[range.end..self.length]);
        }

        // Move cursor to correct position
        const prompt_len = self.prompt.len;
        const cursor_col = prompt_len + self.cursor;
        var buf: [32]u8 = undefined;
        const pos_cmd = std.fmt.bufPrint(&buf, "\r\x1B[{d}C", .{cursor_col}) catch return;
        try self.writeBytes(pos_cmd);
    }

    /// Start macro recording (Ctrl+X ()
    fn startMacroRecording(self: *LineEditor) !void {
        self.macro_recording = true;
        self.macro_len = 0;
        // Could show indicator in prompt
    }

    /// Stop macro recording and save (Ctrl+X ))
    fn stopMacroRecording(self: *LineEditor) !void {
        if (self.macro_recording) {
            self.macro_recording = false;
            // Copy to stored macro
            @memcpy(self.macro_stored[0..self.macro_len], self.macro_buffer[0..self.macro_len]);
            self.macro_stored_len = self.macro_len;
        }
    }

    /// Record a key to the macro buffer
    fn recordKey(self: *LineEditor, key: u8) void {
        if (self.macro_recording and self.macro_len < self.macro_buffer.len) {
            self.macro_buffer[self.macro_len] = key;
            self.macro_len += 1;
        }
    }

    /// Play back the stored macro (Ctrl+X e)
    fn playMacro(self: *LineEditor) !void {
        if (self.macro_stored_len == 0) return;

        // Temporarily disable recording during playback
        const was_recording = self.macro_recording;
        self.macro_recording = false;

        // Replay each key
        for (self.macro_stored[0..self.macro_stored_len]) |key| {
            // For printable characters, insert them
            if (key >= 0x20 and key <= 0x7E) {
                try self.insertChar(key);
            }
            // Control characters could be handled here too
        }

        self.macro_recording = was_recording;
    }

    fn insertChar(self: *LineEditor, char: u8) !void {
        if (self.length >= self.buffer.len) return;

        // Save state for undo
        self.saveUndoState();

        // Clear history search when user types
        self.clearHistorySearch();

        // Clear old suggestion from screen if present
        if (self.suggestion != null) {
            try self.writeBytes("\x1b[0K"); // Clear from cursor to end of line
        }

        // Move characters after cursor to the right
        if (self.cursor < self.length) {
            var i = self.length;
            while (i > self.cursor) : (i -= 1) {
                self.buffer[i] = self.buffer[i - 1];
            }
        }

        self.buffer[self.cursor] = char;
        self.cursor += 1;
        self.length += 1;

        // Redraw from cursor to end
        try self.writeBytes(self.buffer[self.cursor - 1 .. self.length]);

        // Move cursor back to correct position
        if (self.cursor < self.length) {
            const back_count = self.length - self.cursor;
            var i: usize = 0;
            while (i < back_count) : (i += 1) {
                try self.writeBytes("\x1B[D"); // ESC [ D = cursor left
            }
        }

        // Update and display suggestion only if cursor is at end and threshold met
        if (self.autosuggestions and self.cursor == self.length and self.length >= self.suggestion_min_chars) {
            try self.updateSuggestion();
            try self.displaySuggestion();
        }
    }

    fn backspace(self: *LineEditor) !void {
        if (self.cursor == 0) return;

        // Save state for undo
        self.saveUndoState();

        // Clear history search when user types
        self.clearHistorySearch();

        // Clear old suggestion from screen if present
        if (self.suggestion != null) {
            try self.writeBytes("\x1b[0K"); // Clear from cursor to end of line
        }

        // Delete the whole codepoint before the cursor (1-4 bytes), not one byte,
        // so a multibyte character isn't left as a dangling continuation byte.
        const del = self.prevCodepointLen();
        const start = self.cursor - del;
        var i = start;
        while (i < self.length - del) : (i += 1) {
            self.buffer[i] = self.buffer[i + del];
        }

        self.cursor = start;
        self.length -= del;

        // Move cursor back one display column, reprint the tail, clear, reposition.
        try self.writeBytes("\x1B[D"); // Move cursor left one column
        try self.writeBytes(self.buffer[self.cursor..self.length]);
        try self.writeBytes(" "); // Clear the freed cell
        try self.writeBytes("\x1B[K"); // Clear to end of line

        // Move cursor back by display columns (codepoints) in the tail, +1 for
        // the space printed above.
        var back_count: usize = 1;
        var p = self.cursor;
        while (p < self.length) : (p += utf8SeqLen(self.buffer[p])) back_count += self.widthAt(p);
        var j: usize = 0;
        while (j < back_count) : (j += 1) {
            try self.writeBytes("\x1B[D");
        }

        // Update and display suggestion only if cursor is at end and threshold met
        if (self.autosuggestions and self.cursor == self.length and self.length >= self.suggestion_min_chars) {
            try self.updateSuggestion();
            try self.displaySuggestion();
        }
    }

    /// Insert a full multibyte UTF-8 codepoint given its lead byte. The
    /// continuation bytes are read from the terminal so the whole codepoint is
    /// placed atomically and the cursor advances one display column — this is
    /// what makes typing accented/CJK/emoji characters work.
    fn insertUtf8(self: *LineEditor, lead: u8) !void {
        var bytes: [4]u8 = undefined;
        bytes[0] = lead;
        const total = utf8SeqLen(lead);
        var got: usize = 1;
        while (got < total) : (got += 1) {
            const b = (try self.terminal.readByte()) orelse break;
            if (!isUtf8Continuation(b)) {
                // Malformed sequence — handle the stray byte as its own input.
                if (b < 0x80) try self.insertChar(b);
                break;
            }
            bytes[got] = b;
        }
        if (self.length + got > self.buffer.len) return;

        self.saveUndoState();
        self.clearHistorySearch();
        if (self.suggestion != null) {
            try self.writeBytes("\x1b[0K");
        }

        // Make room and copy the codepoint's bytes at the cursor.
        var i = self.length;
        while (i > self.cursor) : (i -= 1) {
            self.buffer[i + got - 1] = self.buffer[i - 1];
        }
        for (bytes[0..got], 0..) |b, k| self.buffer[self.cursor + k] = b;
        self.cursor += got;
        self.length += got;

        // Wrap-aware repaint (positions the cursor correctly across rows).
        try self.redrawLine();

        if (self.autosuggestions and self.cursor == self.length and self.length >= self.suggestion_min_chars) {
            try self.updateSuggestion();
            try self.displaySuggestion();
        }
    }

    /// Consume a bracketed paste: after ESC[200~ we read raw bytes until the
    /// ESC[201~ terminator and insert them as literal text. Embedded newlines are
    /// inserted (normalized to spaces) rather than submitting the line, so
    /// pasting a multi-line block never auto-executes — the footgun this prevents.
    fn handlePaste(self: *LineEditor) !void {
        self.saveUndoState();
        self.clearHistorySearch();

        // Terminator state machine for ESC [ 2 0 1 ~
        const term = [_]u8{ 0x1B, '[', '2', '0', '1', '~' };
        var matched: usize = 0;

        while (true) {
            const byte = (try self.terminal.readByte()) orelse {
                // No byte ready yet — wait briefly; a paste arrives as a burst,
                // so this only spins at the very end.
                std.Io.sleep(std.Options.debug_io, std.Io.Duration.fromNanoseconds(@as(i96, 1_000_000)), .awake) catch {};
                continue;
            };

            // Track progress toward the paste-end terminator.
            if (byte == term[matched]) {
                matched += 1;
                if (matched == term.len) break; // full terminator seen
                continue;
            }

            // Mismatch: bytes tentatively consumed as a partial terminator were
            // actually pasted content — flush them, then reconsider this byte.
            if (matched > 0) {
                for (term[0..matched]) |pending| {
                    self.insertPasteByte(pending);
                }
                matched = 0;
                if (byte == term[0]) {
                    matched = 1;
                    continue;
                }
            }

            self.insertPasteByte(byte);
        }

        try self.redrawLine();
    }

    /// Insert one pasted byte WITHOUT redrawing (handlePaste redraws once at the
    /// end). Newline/CR/tab become a space so the paste stays on one editable
    /// line and cannot submit itself.
    fn insertPasteByte(self: *LineEditor, byte: u8) void {
        if (self.length >= self.buffer.len) return;
        const ch: u8 = switch (byte) {
            '\n', '\r', '\t' => ' ',
            else => byte,
        };
        var i: usize = self.length;
        while (i > self.cursor) : (i -= 1) {
            self.buffer[i] = self.buffer[i - 1];
        }
        self.buffer[self.cursor] = ch;
        self.cursor += 1;
        self.length += 1;
    }

    fn deleteChar(self: *LineEditor) !void {
        // Delete the whole codepoint at the cursor (1-4 bytes), not one byte.
        const del = self.curCodepointLen();
        if (del == 0) return;

        // Save state for undo
        self.saveUndoState();

        // Clear history search when user deletes
        self.clearHistorySearch();

        // Shift the tail left by the codepoint's byte length
        var i = self.cursor;
        while (i < self.length - del) : (i += 1) {
            self.buffer[i] = self.buffer[i + del];
        }

        self.length -= del;

        // Wrap-aware repaint (positions the cursor correctly across rows).
        try self.redrawLine();
    }

    /// UTF-8: true if `b` is a continuation byte (10xxxxxx).
    fn isUtf8Continuation(b: u8) bool {
        return (b & 0xC0) == 0x80;
    }

    /// UTF-8: byte length of the codepoint whose lead byte is `b`. Invalid lead
    /// bytes count as one byte so editing never stalls on malformed input.
    fn utf8SeqLen(b: u8) usize {
        if (b < 0x80) return 1;
        if ((b & 0xE0) == 0xC0) return 2;
        if ((b & 0xF0) == 0xE0) return 3;
        if ((b & 0xF8) == 0xF0) return 4;
        return 1;
    }

    /// Byte length of the codepoint ending just before the cursor (0 at start).
    fn prevCodepointLen(self: *LineEditor) usize {
        if (self.cursor == 0) return 0;
        var i = self.cursor - 1;
        var n: usize = 1;
        while (i > 0 and isUtf8Continuation(self.buffer[i]) and n < 4) : (i -= 1) {
            n += 1;
        }
        return n;
    }

    /// Byte length of the codepoint at the cursor (0 at end), clamped to length.
    fn curCodepointLen(self: *LineEditor) usize {
        if (self.cursor >= self.length) return 0;
        var n = utf8SeqLen(self.buffer[self.cursor]);
        if (self.cursor + n > self.length) n = self.length - self.cursor;
        return n;
    }

    /// Decode the codepoint at `bytes[0..]` (whose length is `len`), best-effort.
    fn decodeCodepoint(bytes: []const u8, len: usize) u21 {
        if (len == 0 or bytes.len == 0) return 0;
        return switch (len) {
            1 => bytes[0],
            2 => (@as(u21, bytes[0] & 0x1F) << 6) | (bytes[1] & 0x3F),
            3 => (@as(u21, bytes[0] & 0x0F) << 12) | (@as(u21, bytes[1] & 0x3F) << 6) | (bytes[2] & 0x3F),
            4 => (@as(u21, bytes[0] & 0x07) << 18) | (@as(u21, bytes[1] & 0x3F) << 12) | (@as(u21, bytes[2] & 0x3F) << 6) | (bytes[3] & 0x3F),
            else => bytes[0],
        };
    }

    /// Number of terminal columns a codepoint occupies: 0 for combining marks,
    /// 2 for East-Asian wide / emoji, 1 otherwise. Covers the common wide ranges
    /// (it is not the full Unicode width database, but matches CJK + emoji which
    /// is what trips up cursor math in practice).
    fn codepointWidth(cp: u21) usize {
        if (cp == 0) return 0;
        // Zero-width: combining marks, ZWJ/ZWNJ, variation selectors.
        if ((cp >= 0x0300 and cp <= 0x036F) or
            (cp >= 0x200B and cp <= 0x200F) or
            (cp >= 0xFE00 and cp <= 0xFE0F) or
            (cp >= 0x1AB0 and cp <= 0x1AFF) or
            (cp >= 0x1DC0 and cp <= 0x1DFF)) return 0;
        // Wide (2-column) ranges: CJK, Hangul, Kana, fullwidth forms, emoji.
        if ((cp >= 0x1100 and cp <= 0x115F) or // Hangul Jamo
            (cp >= 0x2E80 and cp <= 0x303E) or // CJK radicals, Kangxi
            (cp >= 0x3041 and cp <= 0x33FF) or // Hiragana..CJK symbols
            (cp >= 0x3400 and cp <= 0x4DBF) or // CJK Ext A
            (cp >= 0x4E00 and cp <= 0x9FFF) or // CJK Unified
            (cp >= 0xA000 and cp <= 0xA4CF) or // Yi
            (cp >= 0xAC00 and cp <= 0xD7A3) or // Hangul syllables
            (cp >= 0xF900 and cp <= 0xFAFF) or // CJK compat
            (cp >= 0xFE30 and cp <= 0xFE4F) or // CJK compat forms
            (cp >= 0xFF00 and cp <= 0xFF60) or // Fullwidth forms
            (cp >= 0xFFE0 and cp <= 0xFFE6) or
            (cp >= 0x1F300 and cp <= 0x1FAFF) or // emoji & symbols
            (cp >= 0x20000 and cp <= 0x3FFFD)) return 2; // CJK Ext B+
        return 1;
    }

    /// Display-column width of the codepoint whose bytes start at buffer[idx].
    fn widthAt(self: *LineEditor, idx: usize) usize {
        const len = utf8SeqLen(self.buffer[idx]);
        const end = @min(idx + len, self.length);
        return codepointWidth(decodeCodepoint(self.buffer[idx..end], end - idx));
    }

    /// Total display columns of buffer[from..to].
    fn displayWidth(self: *LineEditor, from: usize, to: usize) usize {
        var cols: usize = 0;
        var p = from;
        while (p < to) : (p += utf8SeqLen(self.buffer[p])) {
            cols += self.widthAt(p);
        }
        return cols;
    }

    fn moveCursorLeft(self: *LineEditor) !void {
        const n = self.prevCodepointLen();
        if (n == 0) return;
        self.cursor -= n;
        // Wrap-aware repaint so the cursor can cross row boundaries (a relative
        // \x1B[D cannot move up a row when the cursor is at column 0).
        try self.redrawLine();
    }

    fn moveCursorRight(self: *LineEditor) !void {
        const n = self.curCodepointLen();
        if (n == 0) return;
        self.cursor += n;
        try self.redrawLine();
    }

    /// Find the start of the previous word
    fn findPreviousWord(self: *LineEditor) usize {
        if (self.cursor == 0) return 0;

        var pos = self.cursor;

        // Skip any whitespace immediately before cursor
        while (pos > 0 and std.ascii.isWhitespace(self.buffer[pos - 1])) {
            pos -= 1;
        }

        // Skip non-whitespace (the word)
        while (pos > 0 and !std.ascii.isWhitespace(self.buffer[pos - 1])) {
            pos -= 1;
        }

        return pos;
    }

    /// Find the start of the next word
    fn findNextWord(self: *LineEditor) usize {
        if (self.cursor >= self.length) return self.length;

        var pos = self.cursor;

        // Skip non-whitespace (current word)
        while (pos < self.length and !std.ascii.isWhitespace(self.buffer[pos])) {
            pos += 1;
        }

        // Skip whitespace to get to next word
        while (pos < self.length and std.ascii.isWhitespace(self.buffer[pos])) {
            pos += 1;
        }

        return pos;
    }

    /// Move cursor to the start of the previous word
    fn moveCursorWordLeft(self: *LineEditor) !void {
        const target = self.findPreviousWord();
        while (self.cursor > target) {
            try self.moveCursorLeft();
        }
    }

    /// Move cursor to the start of the next word
    fn moveCursorWordRight(self: *LineEditor) !void {
        const target = self.findNextWord();
        while (self.cursor < target) {
            try self.moveCursorRight();
        }
    }

    fn deleteWordForward(self: *LineEditor) !void {
        if (self.cursor >= self.length) return;

        // Save state for undo
        self.saveUndoState();

        // Clear history search when user deletes word
        self.clearHistorySearch();

        // Find end of next word
        const delete_to = self.findNextWord();
        const chars_to_delete = delete_to - self.cursor;

        if (chars_to_delete == 0) return;

        // Shift remaining characters left
        const remaining = self.length - delete_to;
        var i: usize = 0;
        while (i < remaining) : (i += 1) {
            self.buffer[self.cursor + i] = self.buffer[delete_to + i];
        }
        self.length -= chars_to_delete;

        // Redraw line from cursor position
        try self.writeBytes(self.buffer[self.cursor..self.length]);
        try self.writeBytes(" "); // Clear the last character
        try self.writeBytes("\x1B[K"); // Clear to end of line

        // Move cursor back to correct position
        const moves_needed = self.length - self.cursor + 1;
        i = 0;
        while (i < moves_needed) : (i += 1) {
            try self.writeBytes("\x1B[D");
        }
    }

    fn transposeChars(self: *LineEditor) !void {
        // Need at least 2 characters to transpose
        if (self.length < 2) return;
        if (self.cursor == 0) return;

        // Clear history search when user transposes
        self.clearHistorySearch();

        var pos1: usize = undefined;
        var pos2: usize = undefined;

        if (self.cursor == self.length) {
            // At end of line: swap last two characters
            pos1 = self.length - 2;
            pos2 = self.length - 1;
        } else {
            // Middle of line: swap char before cursor with char at cursor
            pos1 = self.cursor - 1;
            pos2 = self.cursor;
        }

        // Swap the characters
        const temp = self.buffer[pos1];
        self.buffer[pos1] = self.buffer[pos2];
        self.buffer[pos2] = temp;

        // Redraw the affected area
        // Move cursor to pos1
        while (self.cursor > pos1) {
            try self.writeBytes("\x1B[D");
            self.cursor -= 1;
        }
        while (self.cursor < pos1) {
            try self.writeBytes("\x1B[C");
            self.cursor += 1;
        }

        // Redraw from pos1 to end
        try self.writeBytes(self.buffer[pos1..self.length]);

        // Position cursor after the transposed pair
        const target_pos = pos2 + 1;
        while (self.cursor < target_pos and self.cursor < self.length) {
            try self.writeBytes("\x1B[C");
            self.cursor += 1;
        }

        // Move cursor back to where it should be
        while (self.cursor > target_pos) {
            try self.writeBytes("\x1B[D");
            self.cursor -= 1;
        }
    }

    fn moveCursorHome(self: *LineEditor) !void {
        while (self.cursor > 0) {
            try self.moveCursorLeft();
        }
    }

    fn moveCursorEnd(self: *LineEditor) !void {
        while (self.cursor < self.length) {
            try self.moveCursorRight();
        }
    }

    fn killToEnd(self: *LineEditor) !void {
        if (self.cursor >= self.length) return;

        // Save state for undo
        self.saveUndoState();

        // Clear history search when user kills text
        self.clearHistorySearch();

        // Save killed text to kill ring
        self.pushToKillRing(self.buffer[self.cursor..self.length]);

        try self.writeBytes("\x1B[K"); // Clear to end of line
        self.length = self.cursor;
    }

    fn killToStart(self: *LineEditor) !void {
        if (self.cursor == 0) return;

        // Save state for undo
        self.saveUndoState();

        // Clear history search when user kills text
        self.clearHistorySearch();

        // Save killed text to kill ring
        self.pushToKillRing(self.buffer[0..self.cursor]);

        // Move remaining characters to start
        const remaining = self.length - self.cursor;
        var i: usize = 0;
        while (i < remaining) : (i += 1) {
            self.buffer[i] = self.buffer[self.cursor + i];
        }
        self.length = remaining;

        // Move cursor to home
        while (self.cursor > 0) {
            try self.writeBytes("\x1B[D");
            self.cursor -= 1;
        }

        // Redraw line
        try self.writeBytes(self.buffer[0..self.length]);
        try self.writeBytes("\x1B[K");

        // Move cursor to home
        while (self.cursor < self.length) {
            try self.writeBytes("\x1B[D");
        }
        self.cursor = 0;
    }

    /// Push text to the kill ring
    fn pushToKillRing(self: *LineEditor, text: []const u8) void {
        if (text.len == 0 or text.len > 4096) return;

        // Rotate ring if full
        const idx = self.kill_ring_count % 16;
        @memcpy(self.kill_ring[idx][0..text.len], text);
        self.kill_ring_lens[idx] = text.len;

        if (self.kill_ring_count < 16) {
            self.kill_ring_count += 1;
        }
        // Reset yank-pop index to most recent
        self.kill_ring_index = idx;
    }

    /// Yank (paste) from kill ring (Ctrl+Y)
    fn yank(self: *LineEditor) !void {
        if (self.kill_ring_count == 0) return;

        const idx = self.kill_ring_index;
        const len = self.kill_ring_lens[idx];
        if (len == 0) return;

        // Save state for undo
        self.saveUndoState();

        // Check if there's room
        if (self.length + len > self.buffer.len) return;

        // Make room for yanked text
        var i = self.length;
        while (i > self.cursor) {
            i -= 1;
            self.buffer[i + len] = self.buffer[i];
        }

        // Insert yanked text
        @memcpy(self.buffer[self.cursor .. self.cursor + len], self.kill_ring[idx][0..len]);
        self.length += len;
        self.cursor += len;

        // Redraw line
        try self.redrawLine();
    }

    /// Kill word forward (Alt+D / Esc D)
    fn killWordForward(self: *LineEditor) !void {
        if (self.cursor >= self.length) return;

        // Save state for undo
        self.saveUndoState();

        // Find end of word
        var end = self.cursor;
        // Skip whitespace
        while (end < self.length and std.ascii.isWhitespace(self.buffer[end])) {
            end += 1;
        }
        // Skip word characters
        while (end < self.length and !std.ascii.isWhitespace(self.buffer[end])) {
            end += 1;
        }

        if (end == self.cursor) return;

        // Save to kill ring
        self.pushToKillRing(self.buffer[self.cursor..end]);

        // Remove the word
        const remaining = self.length - end;
        var i: usize = 0;
        while (i < remaining) : (i += 1) {
            self.buffer[self.cursor + i] = self.buffer[end + i];
        }
        self.length = self.cursor + remaining;

        // Redraw
        try self.redrawLine();
    }

    /// Kill word backward (Ctrl+W)
    fn killWordBackward(self: *LineEditor) !void {
        if (self.cursor == 0) return;

        // Save state for undo
        self.saveUndoState();

        // Find start of word
        var start = self.cursor;
        // Skip whitespace backward
        while (start > 0 and std.ascii.isWhitespace(self.buffer[start - 1])) {
            start -= 1;
        }
        // Skip word characters backward
        while (start > 0 and !std.ascii.isWhitespace(self.buffer[start - 1])) {
            start -= 1;
        }

        if (start == self.cursor) return;

        // Save to kill ring
        self.pushToKillRing(self.buffer[start..self.cursor]);

        // Remove the word
        const killed_len = self.cursor - start;
        const remaining = self.length - self.cursor;
        var i: usize = 0;
        while (i < remaining) : (i += 1) {
            self.buffer[start + i] = self.buffer[self.cursor + i];
        }
        self.length -= killed_len;
        self.cursor = start;

        // Redraw
        try self.redrawLine();
    }

    fn clearScreen(self: *LineEditor) !void {
        // Clear entire screen and move cursor to home
        try self.writeBytes("\x1B[2J\x1B[H");

        // Refresh prompt if callback is set (to update current directory, etc.)
        if (self.prompt_refresh_fn) |refresh_fn| {
            try refresh_fn(self);
        }

        // Redisplay prompt
        try self.displayPrompt();

        // Redraw current buffer
        if (self.length > 0) {
            try self.writeBytes(self.buffer[0..self.length]);

            // Move cursor back to correct position
            const moves_needed = self.length - self.cursor;
            var i: usize = 0;
            while (i < moves_needed) : (i += 1) {
                try self.writeBytes("\x1B[D");
            }
        }
    }

    fn handleEscapeSequence(self: *LineEditor, seq: EscapeSequence) !void {
        // If we have an active completion list, handle arrow keys for completion navigation
        if (self.completion_list != null) {
            switch (seq) {
                .down_arrow, .right_arrow => {
                    // Move to next completion
                    const list_len = self.completion_list.?.len;
                    self.completion_index = (self.completion_index + 1) % list_len;
                    try self.applyCurrentCompletion();
                    try self.updateCompletionListHighlight();
                    return;
                },
                .up_arrow, .left_arrow => {
                    // Move to previous completion
                    const list_len = self.completion_list.?.len;
                    if (self.completion_index == 0) {
                        self.completion_index = list_len - 1;
                    } else {
                        self.completion_index -= 1;
                    }
                    try self.applyCurrentCompletion();
                    try self.updateCompletionListHighlight();
                    return;
                },
                else => {
                    // Clear completion on other keys
                    self.clearCompletionState();
                },
            }
        }

        // Normal arrow key handling (no active completions)
        switch (seq) {
            .up_arrow => try self.historyPrevious(),
            .down_arrow => try self.historyNext(),
            .left_arrow => try self.moveCursorLeft(),
            .right_arrow => {
                // If there's a suggestion and cursor is at end, accept it
                if (self.suggestion != null and self.cursor == self.length) {
                    try self.acceptSuggestion();
                } else {
                    try self.moveCursorRight();
                }
            },
            .ctrl_left, .alt_b => try self.moveCursorWordLeft(),
            .ctrl_right, .alt_f => try self.moveCursorWordRight(),
            .alt_d => try self.killWordForward(),
            .home => try self.moveCursorHome(),
            .end_key => {
                // End key also accepts suggestion if present
                if (self.suggestion != null and self.cursor == self.length) {
                    try self.acceptSuggestion();
                } else {
                    try self.moveCursorEnd();
                }
            },
            .delete => try self.deleteChar(),
            .paste_start => try self.handlePaste(),
            .paste_end => {}, // stray paste-end without a start: ignore
            else => {},
        }
    }

    fn historyPrevious(self: *LineEditor) !void {
        const history = self.history orelse return;
        const count = self.history_count orelse return;

        // If first time browsing history, set up search query and save line
        if (self.history_index == null) {
            if (self.length > 0) {
                // Save current line
                self.saved_line = try self.allocator.dupe(u8, self.buffer[0..self.length]);
                // Set up substring search with current input
                self.history_search_query = try self.allocator.dupe(u8, self.buffer[0..self.length]);
            }
        }

        const current_index = self.history_index orelse count.*;
        const search_query = self.history_search_query;

        // Search backward through history for matching entry
        var i: usize = current_index;
        while (i > 0) {
            i -= 1;

            if (history[i]) |entry| {
                // If we have a search query, only match entries containing it
                if (search_query) |query| {
                    // Prefix match: typing part of a command and pressing Up/Down
                    // cycles only through history entries that start with it
                    // (zsh up-line-or-beginning-search / fish-style).
                    if (std.mem.startsWith(u8, entry, query)) {
                        // Found a match!
                        try self.replaceLine(entry);
                        self.history_index = i;
                        return;
                    }
                } else {
                    // No search query, show all history
                    try self.replaceLine(entry);
                    self.history_index = i;
                    return;
                }
            }
        }

        // No more matches found (stay at current position)
    }

    fn historyNext(self: *LineEditor) !void {
        const history = self.history orelse return;
        const count = self.history_count orelse return;

        const current_index = self.history_index orelse return; // Not browsing history
        const search_query = self.history_search_query;

        // Search forward through history for matching entry
        var i: usize = current_index + 1;
        while (i < count.*) : (i += 1) {
            if (history[i]) |entry| {
                // If we have a search query, only match entries containing it
                if (search_query) |query| {
                    // Prefix match: typing part of a command and pressing Up/Down
                    // cycles only through history entries that start with it
                    // (zsh up-line-or-beginning-search / fish-style).
                    if (std.mem.startsWith(u8, entry, query)) {
                        // Found a match!
                        try self.replaceLine(entry);
                        self.history_index = i;
                        return;
                    }
                } else {
                    // No search query, show all history
                    try self.replaceLine(entry);
                    self.history_index = i;
                    return;
                }
            }
        }

        // Reached end of history, restore saved line or search query
        if (self.saved_line) |saved| {
            try self.replaceLine(saved);
            self.allocator.free(saved);
            self.saved_line = null;
        } else {
            try self.replaceLine("");
        }

        // Clear search state
        if (self.history_search_query) |query| {
            self.allocator.free(query);
            self.history_search_query = null;
        }

        self.history_index = null;
    }

    fn replaceLine(self: *LineEditor, text: []const u8) !void {
        // Clear current line
        try self.moveCursorHome();
        try self.writeBytes("\x1B[K"); // Clear to end of line

        // Copy new text
        self.length = @min(text.len, self.buffer.len);
        @memcpy(self.buffer[0..self.length], text[0..self.length]);
        self.cursor = self.length;

        // Display new text
        try self.writeBytes(self.buffer[0..self.length]);
    }

    fn writeBytes(self: *LineEditor, bytes: []const u8) !void {
        _ = self;

        if (builtin.os.tag == .windows) {
            const handle = std.os.windows.kernel32.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) orelse return error.NoStdOut;
            const stdout = std.Io.File{ .handle = handle, .flags = .{ .nonblocking = false } };
            try stdout.writeStreamingAll(std.Options.debug_io, bytes);
        } else {
            const result = std.c.write(posix.STDERR_FILENO, bytes.ptr, bytes.len);
            if (result < 0) return error.WriteError;
        }
    }

    /// Sort completions by fuzzy match score (best matches first)
    fn sortCompletionsByFuzzyScore(self: *LineEditor, pattern: []const u8) !void {
        const completions = self.completion_list orelse return;
        if (completions.len <= 1) return;

        // Create array of (index, score) pairs
        const ScoredCompletion = struct {
            index: usize,
            score: u32,
        };

        var scored = try self.allocator.alloc(ScoredCompletion, completions.len);
        defer self.allocator.free(scored);

        for (completions, 0..) |completion, i| {
            // Strip marker if present
            const text = if (completion.len > 0 and (completion[0] == '\x02' or completion[0] == '\x03'))
                completion[1..]
            else
                completion;

            scored[i] = .{
                .index = i,
                .score = fuzzyMatchScore(pattern, text),
            };
        }

        // Sort by score (descending)
        std.mem.sort(ScoredCompletion, scored, {}, struct {
            fn lessThan(_: void, a: ScoredCompletion, b: ScoredCompletion) bool {
                return a.score > b.score; // Higher scores first
            }
        }.lessThan);

        // Reorder completions array based on scores
        var new_completions = try self.allocator.alloc([]const u8, completions.len);
        for (scored, 0..) |item, i| {
            new_completions[i] = completions[item.index];
        }

        // Free old array and replace with sorted one
        self.allocator.free(completions);
        self.completion_list = new_completions;
    }

    /// Fuzzy match score - returns 0 if no match, higher scores are better matches
    fn fuzzyMatchScore(pattern: []const u8, text: []const u8) u32 {
        if (pattern.len == 0) return 0;
        if (text.len == 0) return 0;

        var score: u32 = 0;
        var pattern_idx: usize = 0;
        var text_idx: usize = 0;
        var consecutive: u32 = 0;

        while (pattern_idx < pattern.len and text_idx < text.len) {
            const p_char = std.ascii.toLower(pattern[pattern_idx]);
            const t_char = std.ascii.toLower(text[text_idx]);

            if (p_char == t_char) {
                // Match found
                score += 1;
                consecutive += 1;

                // Bonus for consecutive matches
                if (consecutive > 1) {
                    score += consecutive * 2;
                }

                // Bonus for match at start
                if (pattern_idx == 0 and text_idx == 0) {
                    score += 10;
                }

                // Bonus for match after separator
                if (text_idx > 0 and (text[text_idx - 1] == '/' or text[text_idx - 1] == '_' or text[text_idx - 1] == '-')) {
                    score += 5;
                }

                pattern_idx += 1;
            } else {
                consecutive = 0;
            }

            text_idx += 1;
        }

        // Must match all pattern characters
        if (pattern_idx < pattern.len) {
            return 0;
        }

        return score;
    }

    /// Handle tab completion
    fn handleTabCompletion(self: *LineEditor) !void {
        const completion_fn = self.completion_fn orelse return;

        // Get current line up to cursor
        const input = self.buffer[0..self.cursor];

        // If input is empty or only whitespace, insert spaces like a normal tab
        const trimmed = std.mem.trim(u8, input, &std.ascii.whitespace);
        if (trimmed.len == 0) {
            try self.insertChar(' ');
            try self.insertChar(' ');
            try self.insertChar(' ');
            try self.insertChar(' ');
            return;
        }

        const word_start = self.findWordStart();

        // Check if we're cycling through existing completions
        const is_cycling = blk: {
            if (self.completion_list) |_| {
                // Check if the word start position is the same
                if (self.completion_word_start == word_start) {
                    break :blk true;
                }
            }
            break :blk false;
        };

        if (is_cycling) {
            // Cycle to next completion
            self.completion_index = (self.completion_index + 1) % self.completion_list.?.len;
            try self.applyCurrentCompletion();
            // Update the list to show new highlight
            try self.updateCompletionListHighlight();
        } else {
            // Clear old state
            self.clearCompletionState();

            // Get new completions
            const completions = try completion_fn(input, self.allocator);

            if (completions.len == 0) {
                // No completions, beep
                for (completions) |c| {
                    self.allocator.free(c);
                }
                self.allocator.free(completions);
                try self.writeBytes("\x07");
                return;
            }

            if (completions.len == 1) {
                // Single completion - replace the word with completion
                const completion = completions[0];
                const typed_word = self.buffer[word_start..self.cursor];

                // Strip marker if present (e.g., \x02 for scripts/commands)
                const actual_completion = if (completion.len > 0 and (completion[0] == '\x02' or completion[0] == '\x03'))
                    completion[1..]
                else
                    completion;

                // Check if completion is a full path (contains /) and typed_word also contains /
                const typed_ends_with_slash = typed_word.len > 0 and typed_word[typed_word.len - 1] == '/';
                const is_path_expansion = std.mem.indexOfScalar(u8, actual_completion, '/') != null and
                    std.mem.indexOfScalar(u8, typed_word, '/') != null and
                    !typed_ends_with_slash;

                if (is_path_expansion) {
                    // Replace the entire typed word with the completion
                    const text_after_cursor = self.buffer[self.cursor..self.length];
                    var saved_after: [4096]u8 = undefined;
                    const saved_len = text_after_cursor.len;
                    if (saved_len > 0) {
                        @memcpy(saved_after[0..saved_len], text_after_cursor);
                    }

                    // Replace buffer content from word_start
                    const new_len = word_start + actual_completion.len + saved_len;
                    if (new_len <= self.buffer.len) {
                        @memcpy(self.buffer[word_start .. word_start + actual_completion.len], actual_completion);
                        if (saved_len > 0) {
                            @memcpy(self.buffer[word_start + actual_completion.len .. new_len], saved_after[0..saved_len]);
                        }
                        self.length = new_len;

                        // Redraw from word_start
                        while (self.cursor > word_start) {
                            try self.writeBytes("\x1B[D");
                            self.cursor -= 1;
                        }

                        // Write the new content from word_start onward
                        const bytes_to_write = self.buffer[word_start..self.length];
                        try self.writeBytes(bytes_to_write);
                        try self.writeBytes("\x1B[K"); // Clear to end of line

                        // Move cursor back
                        const target_cursor = word_start + actual_completion.len;
                        const chars_to_go_back = self.length - target_cursor;
                        var i: usize = 0;
                        while (i < chars_to_go_back) : (i += 1) {
                            try self.writeBytes("\x1B[D");
                        }
                        self.cursor = target_cursor;
                    }
                } else {
                    // Traditional completion: just append the suffix
                    const typed_basename = blk: {
                        if (std.mem.lastIndexOfScalar(u8, typed_word, '/')) |last_slash| {
                            break :blk typed_word[last_slash + 1 ..];
                        } else {
                            break :blk typed_word;
                        }
                    };

                    // Insert the rest of the completion
                    if (actual_completion.len >= typed_basename.len) {
                        const to_insert = actual_completion[typed_basename.len..];
                        for (to_insert) |c| {
                            try self.insertChar(c);
                        }
                    }
                }

                // Clean up
                for (completions) |c| {
                    self.allocator.free(c);
                }
                self.allocator.free(completions);
            } else {
                // Multiple completions - save state and show list
                self.completion_list = completions;
                self.completion_index = 0;
                self.completion_word_start = word_start;

                // Save the path prefix from the original input
                const current_word = self.buffer[word_start..self.cursor];
                const path_prefix = blk: {
                    if (std.mem.lastIndexOfScalar(u8, current_word, '/')) |last_slash| {
                        break :blk current_word[0 .. last_slash + 1];
                    } else {
                        break :blk "";
                    }
                };
                self.completion_path_prefix = if (path_prefix.len > 0)
                    try self.allocator.dupe(u8, path_prefix)
                else
                    null;

                // Sort completions by fuzzy match score
                const typed_word = self.buffer[word_start..self.cursor];
                const stripped_word = if (path_prefix.len > 0) typed_word[path_prefix.len..] else typed_word;
                try self.sortCompletionsByFuzzyScore(stripped_word);

                // Show the list
                try self.displayCompletionList();
            }
        }
    }

    /// Apply the current completion from the cycling list
    fn applyCurrentCompletion(self: *LineEditor) !void {
        const completions = self.completion_list orelse return;
        const completion = completions[self.completion_index];

        // Strip marker if present
        const actual_completion = if (completion.len > 0 and (completion[0] == '\x02' or completion[0] == '\x03'))
            completion[1..]
        else
            completion;

        // Use the SAVED path prefix
        const path_prefix = self.completion_path_prefix orelse "";

        // Calculate how far back we need to go
        const old_word_len = self.cursor - self.completion_word_start;

        // Hide cursor to prevent flicker
        try self.writeBytes("\x1b[?25l");

        // Move cursor back to word start position
        if (old_word_len > 0) {
            var buf: [32]u8 = undefined;
            const move_back = try std.fmt.bufPrint(&buf, "\x1b[{d}D", .{old_word_len});
            try self.writeBytes(move_back);
        }

        // Clear from current position to end of line
        try self.writeBytes("\x1b[K");

        // Update buffer
        self.cursor = self.completion_word_start;
        self.length = self.completion_word_start;

        // Insert path prefix
        for (path_prefix) |c| {
            self.buffer[self.length] = c;
            self.length += 1;
        }

        // Insert the actual completion
        for (actual_completion) |c| {
            self.buffer[self.length] = c;
            self.length += 1;
        }

        self.cursor = self.length;

        // Write the new text
        try self.writeBytes(path_prefix);
        try self.writeBytes(actual_completion);

        // Show cursor again
        try self.writeBytes("\x1b[?25h");
    }

    /// Display completion list
    fn displayCompletionList(self: *LineEditor) !void {
        const completions = self.completion_list orelse return;

        // Hide cursor to prevent flicker during redraw
        try self.writeBytes("\x1b[?25l");
        // Save cursor, show list, restore cursor
        try self.writeBytes("\x1b[s");
        try self.writeBytes("\r\n");

        // Find the longest completion
        var max_len: usize = 0;
        for (completions) |completion| {
            const is_script = completion.len > 0 and (completion[0] == '\x02' or completion[0] == '\x03');
            const display_text = if (is_script) completion[1..] else completion;
            if (display_text.len > max_len) {
                max_len = display_text.len;
            }
        }

        // Get terminal width
        const term_width = if (signals.getWindowSize()) |ws| ws.cols else |_| 80;

        // Calculate column layout
        const col_width = max_len + 2;
        const num_cols = @max(1, term_width / col_width);
        const num_rows = (completions.len + num_cols - 1) / num_cols;

        // Print in column-major order
        var row: usize = 0;
        while (row < num_rows) : (row += 1) {
            var col: usize = 0;
            while (col < num_cols) : (col += 1) {
                const idx = col * num_rows + row;
                if (idx >= completions.len) break;

                const completion = completions[idx];
                const is_script = completion.len > 0 and completion[0] == '\x02';
                const is_branch = completion.len > 0 and completion[0] == '\x03';
                const display_text = if (is_script or is_branch) completion[1..] else completion;
                const is_dir = display_text.len > 0 and display_text[display_text.len - 1] == '/';
                const name_part = if (is_dir) display_text[0 .. display_text.len - 1] else display_text;

                // Highlight current selection
                if (idx == self.completion_index) {
                    try self.writeBytes("\x1b[30;47m");
                    try self.writeBytes(display_text);
                    try self.writeBytes("\x1b[0m");
                } else if (is_branch) {
                    try self.writeBytes("\x1b[1;35m");
                    try self.writeBytes(display_text);
                    try self.writeBytes("\x1b[0m");
                } else if (is_dir) {
                    try self.writeBytes("\x1b[1;36m");
                    try self.writeBytes(name_part);
                    try self.writeBytes("\x1b[0m/");
                } else {
                    try self.writeBytes(display_text);
                }

                // Add padding
                if (col < num_cols - 1 and idx < completions.len - 1) {
                    const padding = col_width - display_text.len;
                    var p: usize = 0;
                    while (p < padding) : (p += 1) {
                        try self.writeBytes(" ");
                    }
                }
            }
            if (row < num_rows - 1) {
                try self.writeBytes("\r\n");
            }
        }

        try self.writeBytes("\x1b[u");
        // Show cursor again
        try self.writeBytes("\x1b[?25h");
    }

    /// Update the completion list highlight
    fn updateCompletionListHighlight(self: *LineEditor) !void {
        const completions = self.completion_list orelse return;

        try self.writeBytes("\x1b[?25l");
        try self.writeBytes("\x1b[s");
        try self.writeBytes("\r\n");

        var max_len: usize = 0;
        for (completions) |completion| {
            const is_script = completion.len > 0 and (completion[0] == '\x02' or completion[0] == '\x03');
            const display_text = if (is_script) completion[1..] else completion;
            if (display_text.len > max_len) {
                max_len = display_text.len;
            }
        }

        const term_width = if (signals.getWindowSize()) |ws| ws.cols else |_| 80;
        const col_width = max_len + 2;
        const num_cols = @max(1, term_width / col_width);
        const num_rows = (completions.len + num_cols - 1) / num_cols;

        var row: usize = 0;
        while (row < num_rows) : (row += 1) {
            var col: usize = 0;
            while (col < num_cols) : (col += 1) {
                const idx = col * num_rows + row;
                if (idx >= completions.len) break;

                const completion = completions[idx];
                const is_script = completion.len > 0 and completion[0] == '\x02';
                const is_branch = completion.len > 0 and completion[0] == '\x03';
                const display_text = if (is_script or is_branch) completion[1..] else completion;
                const is_dir = display_text.len > 0 and display_text[display_text.len - 1] == '/';
                const name_part = if (is_dir) display_text[0 .. display_text.len - 1] else display_text;

                if (idx == self.completion_index) {
                    try self.writeBytes("\x1b[30;47m");
                    try self.writeBytes(display_text);
                    try self.writeBytes("\x1b[0m");
                } else if (is_branch) {
                    try self.writeBytes("\x1b[1;35m");
                    try self.writeBytes(display_text);
                    try self.writeBytes("\x1b[0m");
                } else if (is_dir) {
                    try self.writeBytes("\x1b[1;36m");
                    try self.writeBytes(name_part);
                    try self.writeBytes("\x1b[0m/");
                } else {
                    try self.writeBytes(display_text);
                }

                if (col < num_cols - 1 and idx < completions.len - 1) {
                    const padding = col_width - display_text.len;
                    var p: usize = 0;
                    while (p < padding) : (p += 1) {
                        try self.writeBytes(" ");
                    }
                }
            }
            if (row < num_rows - 1) {
                try self.writeBytes("\r\n");
            }
        }

        try self.writeBytes("\x1b[u");
        try self.writeBytes("\x1b[?25h");
    }

    /// Clear the completion list display
    fn clearCompletionDisplay(self: *LineEditor) !void {
        const completions = self.completion_list orelse return;

        // Calculate actual display rows (same logic as displayCompletionList)
        var max_len: usize = 0;
        for (completions) |completion| {
            const has_marker = completion.len > 0 and (completion[0] == '\x02' or completion[0] == '\x03');
            const display_text = if (has_marker) completion[1..] else completion;
            if (display_text.len > max_len) max_len = display_text.len;
        }
        const term_width = if (signals.getWindowSize()) |ws| ws.cols else |_| 80;
        const col_width = @max(max_len + 2, 1);
        const num_cols = @max(1, term_width / col_width);
        const num_rows = (completions.len + num_cols - 1) / num_cols;

        try self.writeBytes("\x1b[s");

        var i: usize = 0;
        while (i < num_rows) : (i += 1) {
            try self.writeBytes("\r\n");
            try self.writeBytes("\x1b[2K");
        }

        try self.writeBytes("\x1b[u");
    }

    /// Clear completion state
    fn clearCompletionState(self: *LineEditor) void {
        if (self.completion_list) |list| {
            self.clearCompletionDisplay() catch {};

            for (list) |item| {
                self.allocator.free(item);
            }
            self.allocator.free(list);
            self.completion_list = null;
        }
        if (self.completion_path_prefix) |prefix| {
            self.allocator.free(prefix);
            self.completion_path_prefix = null;
        }
        self.completion_index = 0;
        self.completion_word_start = 0;
    }

    /// Redraw the current line
    /// Visible width of the prompt in columns, ignoring ANSI/OSC escape
    /// sequences (which occupy zero columns) and counting wide codepoints as 2.
    fn promptVisibleWidth(self: *LineEditor) usize {
        var cols: usize = 0;
        var i: usize = 0;
        const p = self.prompt;
        while (i < p.len) {
            if (p[i] == 0x1B) {
                i += 1;
                if (i < p.len and p[i] == '[') {
                    i += 1;
                    while (i < p.len and !(p[i] >= 0x40 and p[i] <= 0x7E)) : (i += 1) {}
                    if (i < p.len) i += 1;
                } else if (i < p.len and p[i] == ']') {
                    i += 1;
                    while (i < p.len and p[i] != 0x07) : (i += 1) {}
                    if (i < p.len) i += 1;
                } else {
                    i += 1;
                }
                continue;
            }
            if (p[i] == '\n') {
                cols = 0;
                i += 1;
                continue;
            }
            const len = utf8SeqLen(p[i]);
            const end = @min(i + len, p.len);
            cols += codepointWidth(decodeCodepoint(p[i..end], end - i));
            i = end;
        }
        return cols;
    }

    /// Wrap-aware full-line repaint. Repaints the prompt + buffer and positions
    /// the cursor at its true (row, col), correctly handling lines that wrap
    /// across multiple terminal rows — replacing the old single-row scheme whose
    /// relative cursor moves corrupted the display on long input.
    fn redrawLine(self: *LineEditor) !void {
        const cols: usize = if (signals.getWindowSize()) |ws|
            (if (ws.cols == 0) 80 else ws.cols)
        else |_|
            80;

        const pwidth = self.promptVisibleWidth();
        const total_cols = pwidth + self.displayWidth(0, self.length);
        const cursor_cols = pwidth + self.displayWidth(0, self.cursor);

        const last_row = total_cols / cols;
        const cursor_row = cursor_cols / cols;
        const cursor_col = cursor_cols % cols;

        var buf: [32]u8 = undefined;

        // 1. Move up to the first row of the previously rendered block.
        if (self.rendered_cursor_row > 0) {
            const seq = std.fmt.bufPrint(&buf, "\x1B[{d}A", .{self.rendered_cursor_row}) catch "";
            try self.writeBytes(seq);
        }

        // 2. Column 0, clear everything below.
        try self.writeBytes("\r\x1B[0J");

        // 3. Prompt.
        try self.writeBytes(self.prompt);

        // 4. Buffer (optionally syntax-highlighted).
        if (self.syntax_highlighting and self.length > 0) {
            var highlighter = SyntaxHighlighter.init(self.allocator);
            const highlighted = highlighter.highlight(self.buffer[0..self.length]) catch null;
            if (highlighted) |h| {
                defer self.allocator.free(h);
                try self.writeBytes(h);
            } else {
                try self.writeBytes(self.buffer[0..self.length]);
            }
        } else if (self.length > 0) {
            try self.writeBytes(self.buffer[0..self.length]);
        }

        // 5. If content fills the last row exactly, force a wrap so row math holds.
        if (total_cols > 0 and total_cols % cols == 0) {
            try self.writeBytes("\r\n");
        }
        const end_row = if (total_cols > 0 and total_cols % cols == 0) last_row + 1 else last_row;

        // 6. Move up from the end row to the cursor's row.
        if (end_row > cursor_row) {
            const seq = std.fmt.bufPrint(&buf, "\x1B[{d}A", .{end_row - cursor_row}) catch "";
            try self.writeBytes(seq);
        }

        // 7. Absolute column within the row.
        try self.writeBytes("\r");
        if (cursor_col > 0) {
            const seq = std.fmt.bufPrint(&buf, "\x1B[{d}C", .{cursor_col}) catch "";
            try self.writeBytes(seq);
        }

        self.rendered_cursor_row = cursor_row;
    }

    /// Handle terminal window resize (SIGWINCH)
    fn handleWindowResize(self: *LineEditor) !void {
        if (self.completion_list != null) {
            try self.clearCompletionDisplay();
        }

        // Width changed, so the previously tracked wrap layout is invalid —
        // repaint from the current row. redrawLine positions the cursor itself.
        self.rendered_cursor_row = 0;
        try self.redrawLine();

        if (self.completion_list != null) {
            try self.displayCompletionList();
        }

        if (self.suggestion != null) {
            try self.displaySuggestion();
        }
    }

    /// Find the start of the current word (for completion)
    fn findWordStart(self: *LineEditor) usize {
        if (self.cursor == 0) return 0;

        var pos = self.cursor;
        while (pos > 0) {
            pos -= 1;
            const c = self.buffer[pos];
            if (c == ' ' or c == '\t' or c == '|' or c == '&' or c == ';' or c == '(' or c == ')') {
                return pos + 1;
            }
        }
        return 0;
    }

    /// Search history for a suggestion matching current input
    fn updateSuggestion(self: *LineEditor) !void {
        self.clearSuggestion();

        if (!self.autosuggestions) return;
        if (self.length == 0) return;
        if (self.history == null or self.history_count == null) return;

        const current_input = self.buffer[0..self.length];
        const history = self.history.?;
        const count = self.history_count.?.*;

        var i: usize = count;
        while (i > 0) {
            i -= 1;
            if (history[i]) |entry| {
                if (entry.len > current_input.len and std.mem.startsWith(u8, entry, current_input)) {
                    self.suggestion = try self.allocator.dupe(u8, entry[current_input.len..]);
                    return;
                }
            }
        }
    }

    /// Display the suggestion in gray text
    fn displaySuggestion(self: *LineEditor) !void {
        if (self.suggestion) |sugg| {
            try self.writeBytes("\x1b[90m");
            try self.writeBytes(sugg);
            try self.writeBytes("\x1b[0m");

            var i: usize = 0;
            while (i < sugg.len) : (i += 1) {
                try self.writeBytes("\x1b[D");
            }
        }
    }

    /// Clear the suggestion
    fn clearSuggestion(self: *LineEditor) void {
        if (self.suggestion) |sugg| {
            self.allocator.free(sugg);
            self.suggestion = null;
        }
    }

    /// Accept the current suggestion
    fn acceptSuggestion(self: *LineEditor) !void {
        if (self.suggestion) |sugg| {
            for (sugg) |char| {
                if (self.length >= self.buffer.len) break;
                self.buffer[self.length] = char;
                self.length += 1;
                self.cursor += 1;
            }

            try self.writeBytes(sugg);

            self.clearSuggestion();
        }
    }

    /// Save current state to undo stack
    fn saveUndoState(self: *LineEditor) void {
        if (self.undo_index < self.undo_stack_size) {
            self.undo_stack_size = self.undo_index;
        }

        if (self.undo_stack_size >= self.undo_stack.len) {
            var i: usize = 0;
            while (i < self.undo_stack.len - 1) : (i += 1) {
                self.undo_stack[i] = self.undo_stack[i + 1];
            }
            self.undo_stack_size = self.undo_stack.len - 1;
        }

        self.undo_stack[self.undo_stack_size] = .{
            .buffer = self.buffer,
            .length = self.length,
            .cursor = self.cursor,
        };
        self.undo_stack_size += 1;
        self.undo_index = self.undo_stack_size;
    }

    /// Undo last edit (Ctrl+_)
    fn undo(self: *LineEditor) !void {
        if (self.undo_index == 0 or self.undo_stack_size == 0) {
            try self.writeBytes("\x07");
            return;
        }

        if (self.undo_index == self.undo_stack_size) {
            self.saveUndoState();
            self.undo_index -= 1;
        }

        self.undo_index -= 1;

        const state = self.undo_stack[self.undo_index];
        self.buffer = state.buffer;
        self.length = state.length;
        self.cursor = state.cursor;

        try self.writeBytes("\r");
        try self.writeBytes("\x1B[K");
        try self.displayPrompt();
        if (self.length > 0) {
            try self.writeBytes(self.buffer[0..self.length]);
        }

        if (self.cursor < self.length) {
            const moves_back = self.length - self.cursor;
            var i: usize = 0;
            while (i < moves_back) : (i += 1) {
                try self.writeBytes("\x1B[D");
            }
        }
    }

    pub fn deinit(self: *LineEditor) void {
        self.terminal.disableRawMode() catch {};
        if (self.saved_line) |saved| {
            self.allocator.free(saved);
            self.saved_line = null;
        }
        if (self.history_search_query) |query| {
            self.allocator.free(query);
            self.history_search_query = null;
        }
        if (self.multiline_buffer) |*mlb| {
            mlb.deinit(self.allocator);
            self.multiline_buffer = null;
            self.in_multiline = false;
        }
        self.clearCompletionState();
        self.clearSuggestion();
    }
};

// Tests for isIncomplete
test "isIncomplete: trailing backslash" {
    try std.testing.expect(LineEditor.isIncomplete("echo hello \\"));
    try std.testing.expect(LineEditor.isIncomplete("ls -la \\"));
    try std.testing.expect(LineEditor.isIncomplete("\\"));
}

test "isIncomplete: escaped backslash" {
    try std.testing.expect(!LineEditor.isIncomplete("echo hello \\\\"));
    try std.testing.expect(!LineEditor.isIncomplete("path\\\\"));
}

test "isIncomplete: triple backslash" {
    try std.testing.expect(LineEditor.isIncomplete("echo \\\\\\"));
}

test "isIncomplete: unclosed single quote" {
    try std.testing.expect(LineEditor.isIncomplete("echo 'hello"));
    try std.testing.expect(LineEditor.isIncomplete("echo 'hello world"));
    try std.testing.expect(LineEditor.isIncomplete("'"));
}

test "isIncomplete: closed single quote" {
    try std.testing.expect(!LineEditor.isIncomplete("echo 'hello'"));
    try std.testing.expect(!LineEditor.isIncomplete("echo 'hello world'"));
    try std.testing.expect(!LineEditor.isIncomplete("''"));
}

test "isIncomplete: unclosed double quote" {
    try std.testing.expect(LineEditor.isIncomplete("echo \"hello"));
    try std.testing.expect(LineEditor.isIncomplete("echo \"hello world"));
    try std.testing.expect(LineEditor.isIncomplete("\""));
}

test "isIncomplete: closed double quote" {
    try std.testing.expect(!LineEditor.isIncomplete("echo \"hello\""));
    try std.testing.expect(!LineEditor.isIncomplete("echo \"hello world\""));
    try std.testing.expect(!LineEditor.isIncomplete("\"\""));
}

test "isIncomplete: escaped quote in double quotes" {
    try std.testing.expect(LineEditor.isIncomplete("echo \"hello \\\""));
    try std.testing.expect(!LineEditor.isIncomplete("echo \"hello \\\"\""));
}

test "isIncomplete: quote inside other quote type" {
    try std.testing.expect(!LineEditor.isIncomplete("echo \"it's good\""));
    try std.testing.expect(!LineEditor.isIncomplete("echo 'he said \"hi\"'"));
}

test "isIncomplete: unclosed parentheses" {
    try std.testing.expect(LineEditor.isIncomplete("(echo hello"));
    try std.testing.expect(LineEditor.isIncomplete("((echo hello)"));
    try std.testing.expect(LineEditor.isIncomplete("("));
}

test "isIncomplete: closed parentheses" {
    try std.testing.expect(!LineEditor.isIncomplete("(echo hello)"));
    try std.testing.expect(!LineEditor.isIncomplete("((echo hello))"));
    try std.testing.expect(!LineEditor.isIncomplete("()"));
}

test "isIncomplete: unclosed braces" {
    try std.testing.expect(LineEditor.isIncomplete("{echo hello"));
    try std.testing.expect(LineEditor.isIncomplete("{{echo hello}"));
    try std.testing.expect(LineEditor.isIncomplete("{"));
}

test "isIncomplete: closed braces" {
    try std.testing.expect(!LineEditor.isIncomplete("{echo hello}"));
    try std.testing.expect(!LineEditor.isIncomplete("{{echo hello}}"));
    try std.testing.expect(!LineEditor.isIncomplete("{}"));
}

test "isIncomplete: unclosed brackets" {
    try std.testing.expect(LineEditor.isIncomplete("[test -f file"));
    try std.testing.expect(LineEditor.isIncomplete("[[test -f file]"));
    try std.testing.expect(LineEditor.isIncomplete("["));
}

test "isIncomplete: closed brackets" {
    try std.testing.expect(!LineEditor.isIncomplete("[test -f file]"));
    try std.testing.expect(!LineEditor.isIncomplete("[[test -f file]]"));
    try std.testing.expect(!LineEditor.isIncomplete("[]"));
}

test "isIncomplete: brackets inside quotes" {
    try std.testing.expect(!LineEditor.isIncomplete("echo \"[not a bracket\""));
    try std.testing.expect(!LineEditor.isIncomplete("echo '(not a paren)'"));
    try std.testing.expect(!LineEditor.isIncomplete("echo \"{not a brace}\""));
}

test "isIncomplete: empty input" {
    try std.testing.expect(!LineEditor.isIncomplete(""));
}

test "isIncomplete: complete input" {
    try std.testing.expect(!LineEditor.isIncomplete("echo hello world"));
    try std.testing.expect(!LineEditor.isIncomplete("ls -la"));
    try std.testing.expect(!LineEditor.isIncomplete("git status"));
}

test "isIncomplete: nested structures" {
    try std.testing.expect(LineEditor.isIncomplete("echo \"$(cmd"));
    try std.testing.expect(!LineEditor.isIncomplete("echo \"$(cmd)\""));
}
