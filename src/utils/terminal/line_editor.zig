//! Line Editor - Full-featured line editing with Vi/Emacs modes
//!
//! This module provides an interactive line editor with:
//! - Vi and Emacs editing modes
//! - History navigation with prefix search
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
const Flow = types.Flow;
const keymap = @import("keymap.zig");
const Widget = keymap.Widget;

// Import from parent utils directory
const SyntaxHighlighter = @import("../syntax_highlight.zig").SyntaxHighlighter;
const cpu_opt = @import("../cpu_opt.zig");
const signals = @import("../signals.zig");

fn historyEntryMatches(entry: []const u8, query: ?[]const u8, current_line: []const u8) bool {
    if (std.mem.eql(u8, entry, current_line)) return false;
    return if (query) |prefix| std.mem.startsWith(u8, entry, prefix) else true;
}

fn findPreviousHistoryMatch(
    history: []const ?[]const u8,
    from: usize,
    query: ?[]const u8,
    current_line: []const u8,
) ?usize {
    var i = @min(from, history.len);
    while (i > 0) {
        i -= 1;
        const entry = history[i] orelse continue;
        if (historyEntryMatches(entry, query, current_line)) return i;
    }
    return null;
}

fn findNextHistoryMatch(
    history: []const ?[]const u8,
    from: usize,
    query: ?[]const u8,
    current_line: []const u8,
) ?usize {
    if (from >= history.len) return null;
    var i = from + 1;
    while (i < history.len) : (i += 1) {
        const entry = history[i] orelse continue;
        if (historyEntryMatches(entry, query, current_line)) return i;
    }
    return null;
}

/// Whether `entry` is worth offering as the inline completion of `input`.
/// An entry that only adds whitespace has nothing to accept.
fn suggestionUsable(entry: []const u8, input: []const u8) bool {
    if (entry.len <= input.len) return false;
    return std.mem.trim(u8, entry[input.len..], &std.ascii.whitespace).len != 0;
}

/// Pick the ghost-text suggestion for `input` from `history` (oldest first).
///
/// Recency decides: the newest command starting with what the user typed is
/// what they're reaching for, which is why the scan runs backwards. A
/// case-insensitive pass only runs when nothing matched exactly, so a stray
/// Shift still suggests something instead of nothing.
fn findSuggestion(history: []const ?[]const u8, count: usize, input: []const u8) ?[]const u8 {
    if (input.len == 0) return null;
    const upto = @min(count, history.len);

    var i = upto;
    while (i > 0) {
        i -= 1;
        const entry = history[i] orelse continue;
        if (std.mem.startsWith(u8, entry, input) and suggestionUsable(entry, input)) return entry;
    }

    i = upto;
    while (i > 0) {
        i -= 1;
        const entry = history[i] orelse continue;
        if (entry.len <= input.len) continue;
        if (std.ascii.eqlIgnoreCase(entry[0..input.len], input) and suggestionUsable(entry, input)) {
            return entry;
        }
    }

    return null;
}

fn completionReplacement(path_prefix: []const u8, candidate: []const u8, scratch: []u8) ?[]const u8 {
    if (path_prefix.len == 0 or std.mem.startsWith(u8, candidate, path_prefix)) return candidate;

    // Older/custom completion callbacks may return a basename for `dir/<Tab>`.
    // Preserve compatibility with those while treating candidates containing
    // an internal slash as complete words (the native completion contract).
    const without_trailing_slash = std.mem.trimEnd(u8, candidate, "/");
    if (std.mem.indexOfScalar(u8, without_trailing_slash, '/') != null) return candidate;
    if (path_prefix.len + candidate.len > scratch.len) return null;

    @memcpy(scratch[0..path_prefix.len], path_prefix);
    @memcpy(scratch[path_prefix.len .. path_prefix.len + candidate.len], candidate);
    return scratch[0 .. path_prefix.len + candidate.len];
}

fn completionText(candidate: []const u8) []const u8 {
    return if (candidate.len > 0 and (candidate[0] == '\x02' or candidate[0] == '\x03'))
        candidate[1..]
    else
        candidate;
}

fn normalizedShellWord(word: []const u8, scratch: []u8) ?[]const u8 {
    if (word.len > scratch.len) return null;

    var out: usize = 0;
    var quote: ?u8 = null;
    var escaped = false;
    for (word) |c| {
        if (escaped) {
            scratch[out] = c;
            out += 1;
            escaped = false;
            continue;
        }
        if (c == '\\' and quote != '\'') {
            escaped = true;
            continue;
        }
        if (quote) |q| {
            if (c == q) {
                quote = null;
            } else {
                scratch[out] = c;
                out += 1;
            }
            continue;
        }
        if (c == '\'' or c == '"') {
            quote = c;
            continue;
        }
        scratch[out] = c;
        out += 1;
    }
    if (escaped) {
        scratch[out] = '\\';
        out += 1;
    }
    return scratch[0..out];
}

fn longestCommonCompletionPrefix(completions: []const []const u8) []const u8 {
    if (completions.len == 0) return "";

    const first = completionText(completions[0]);
    var common_len = first.len;
    for (completions[1..]) |candidate| {
        const text = completionText(candidate);
        common_len = @min(common_len, text.len);
        var i: usize = 0;
        while (i < common_len and first[i] == text[i]) : (i += 1) {}
        common_len = i;
        if (common_len == 0) break;
    }
    return first[0..common_len];
}

fn shellWordStart(input: []const u8, cursor: usize) usize {
    const end = @min(cursor, input.len);
    var word_start: usize = 0;
    var quote: ?u8 = null;
    var escaped = false;

    for (input[0..end], 0..) |c, i| {
        if (escaped) {
            escaped = false;
            continue;
        }
        if (c == '\\' and quote != '\'') {
            escaped = true;
            continue;
        }
        if (quote) |q| {
            if (c == q) quote = null;
            continue;
        }
        if (c == '\'' or c == '"') {
            quote = c;
            continue;
        }
        if (c == ' ' or c == '\t' or c == '|' or c == '&' or c == ';' or c == '(' or c == ')') {
            word_start = i + 1;
        }
    }
    return word_start;
}

fn replaceBufferRange(
    buffer: []u8,
    length: *usize,
    start: usize,
    end: usize,
    replacement: []const u8,
) bool {
    if (start > end or end > length.*) return false;

    const old_range_len = end - start;
    const tail_len = length.* - end;
    const new_len = length.* - old_range_len + replacement.len;
    if (new_len > buffer.len) return false;

    const new_tail_start = start + replacement.len;
    if (new_tail_start > end) {
        std.mem.copyBackwards(u8, buffer[new_tail_start .. new_tail_start + tail_len], buffer[end .. end + tail_len]);
    } else if (new_tail_start < end) {
        std.mem.copyForwards(u8, buffer[new_tail_start .. new_tail_start + tail_len], buffer[end .. end + tail_len]);
    }
    @memcpy(buffer[start .. start + replacement.len], replacement);
    length.* = new_len;
    return true;
}

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
    saved_history_cursor: usize = 0,
    history_search_query: ?[]const u8 = null, // Original input used to filter history by prefix
    completion_fn: ?CompletionFn = null, // Callback for tab completion
    // Completion cycling state
    completion_list: ?[][]const u8 = null,
    completion_index: usize = 0,
    completion_word_start: usize = 0,
    completion_path_prefix: ?[]const u8 = null, // Save the path prefix (e.g., "Documents/Projects/")
    // Inline suggestion state
    suggestion: ?[]const u8 = null, // Ghost text: slice of suggestion_entry past what's typed
    suggestion_entry: ?[]const u8 = null, // Owned copy of the history entry it came from
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

    // Test seams. Every existing test here is a pure function because output
    // goes straight to the tty and input straight from it; these two fields are
    // what let the editing actions themselves be asserted. Both are inert in
    // production.
    /// When set, writeBytes appends here instead of writing to the terminal.
    write_sink: ?*std.ArrayList(u8) = null,
    /// When true, input is never read from the terminal.
    no_terminal: bool = false,

    /// Bytes to consume before reading the terminal again.
    ///
    /// One queue serves three jobs: replaying a recorded macro as real input,
    /// re-dispatching the tail of a key sequence that turned out not to match,
    /// and feeding a byte script to a test with no tty attached.
    input_queue: [256]u8 = undefined,
    input_queue_head: usize = 0,
    input_queue_len: usize = 0,

    // --- key dispatch ---
    /// Keymaps to consult, owned by the shell. Null disables the keymap and
    /// leaves every key to the built-in handling below, which is the case
    /// before the shell has any (and in tests that do not set it).
    keymaps: ?*keymap.KeymapSet = null,
    /// Bytes of a key sequence read so far that is still ambiguous.
    pending: keymap.KeySeq = .{},
    /// Widget to run if `pending` stops growing: the sequence matched exactly,
    /// but a longer binding also starts with it, so the longer one gets first
    /// refusal. This is how `^X` coexists with `^X(`.
    pending_fallback: ?keymap.Binding = null,
    pending_fallback_len: u8 = 0,
    /// Empty reads since the last byte arrived.
    idle_polls: u8 = 0,
    /// Empty reads to wait through before an ambiguous sequence resolves. Each
    /// is roughly the terminal's read timeout (~100ms), and 1 reproduces the
    /// timing a lone Escape has always had. zsh spells this $KEYTIMEOUT.
    key_timeout_polls: u8 = 1,
    /// Bytes handed to the built-in escape parser, which keeps accumulating
    /// until the sequence is complete.
    escape_seq: keymap.KeySeq = .{},
    in_escape: bool = false,

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

    /// Next input byte: queued bytes first, then the terminal. Null means
    /// nothing is available right now (the terminal read times out ~100ms).
    fn nextByte(self: *LineEditor) !?u8 {
        if (self.input_queue_len > 0) {
            const b = self.input_queue[self.input_queue_head];
            self.input_queue_head = (self.input_queue_head + 1) % self.input_queue.len;
            self.input_queue_len -= 1;
            return b;
        }
        if (self.no_terminal) return null;
        return self.terminal.readByte();
    }

    /// Queue bytes to be consumed before any further terminal input. Silently
    /// drops anything past the queue's capacity: the alternative is failing a
    /// keystroke, and 256 bytes is far more than any key sequence or macro.
    fn pushBack(self: *LineEditor, bytes: []const u8) void {
        for (bytes) |b| {
            if (self.input_queue_len >= self.input_queue.len) return;
            const at = (self.input_queue_head + self.input_queue_len) % self.input_queue.len;
            self.input_queue[at] = b;
            self.input_queue_len += 1;
        }
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

    /// Handle one key in vi normal mode. Returns the same Flow as any other
    /// editing action, so accepting a line goes through acceptLine rather
    /// than a second, divergent copy of it.
    fn handleViNormalKey(self: *LineEditor, char: u8) !Flow {
        const count = if (self.vi_count == 0) 1 else self.vi_count;

        switch (char) {
            // Mode switching
            'i' => {
                self.viEnterInsertMode();
                return .cont;
            },
            'I' => {
                self.viInsertBol();
                return .cont;
            },
            'a' => {
                self.viAddNext();
                return .cont;
            },
            'A' => {
                self.viAddEol();
                return .cont;
            },
            'o', 'O' => {
                self.viOpenLine();
                return .cont;
            },
            's' => {
                try self.viSubstitute();
                return .cont;
            },
            'S' => {
                try self.viChangeWholeLine();
                return .cont;
            },
            'C' => {
                try self.viChangeEol();
                return .cont;
            },
            'R' => {
                self.vi_mode = .replace;
                return .cont;
            },

            // Navigation
            'h' => {
                for (0..count) |_| {
                    try self.moveCursorLeft();
                }
                return .cont;
            },
            'l' => {
                for (0..count) |_| {
                    try self.moveCursorRight();
                }
                return .cont;
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
                return .cont;
            },
            '$' => {
                self.cursor = if (self.length > 0) self.length - 1 else 0;
                try self.redrawLine();
                return .cont;
            },
            '^' => {
                // Go to first non-blank
                self.cursor = 0;
                while (self.cursor < self.length and (self.buffer[self.cursor] == ' ' or self.buffer[self.cursor] == '\t')) {
                    self.cursor += 1;
                }
                try self.redrawLine();
                return .cont;
            },
            'w' => {
                // Move forward word
                for (0..count) |_| {
                    self.moveForwardWord();
                }
                try self.redrawLine();
                return .cont;
            },
            'b' => {
                // Move backward word
                for (0..count) |_| {
                    self.moveBackwardWord();
                }
                try self.redrawLine();
                return .cont;
            },
            'e' => {
                // Move to end of word
                for (0..count) |_| {
                    self.moveToEndOfWord();
                }
                try self.redrawLine();
                return .cont;
            },

            // Editing
            'x' => {
                // Delete character under cursor
                for (0..count) |_| {
                    if (self.cursor < self.length) {
                        try self.deleteChar();
                    }
                }
                return .cont;
            },
            'X' => {
                // Delete character before cursor
                for (0..count) |_| {
                    if (self.cursor > 0) {
                        try self.backspace();
                    }
                }
                return .cont;
            },
            'D' => {
                // Delete to end of line
                self.length = self.cursor;
                try self.redrawLine();
                return .cont;
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
                return .cont;
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
                return .cont;
            },

            // History
            'j' => {
                try self.historyNext();
                return .cont;
            },
            'k' => {
                try self.historyPrevious();
                return .cont;
            },

            // Undo/Redo
            'u' => {
                try self.undo();
                return .cont;
            },

            // Search
            '/' => {
                try self.startReverseSearch();
                return .cont;
            },
            'n' => {
                try self.continueReverseSearch();
                return .cont;
            },

            // Count digits
            '1', '2', '3', '4', '5', '6', '7', '8', '9' => {
                self.vi_count = self.vi_count * 10 + (char - '0');
                return .cont;
            },

            // Execute line
            '\r', '\n' => {
                return try self.acceptLine();
            },

            else => {
                self.vi_pending_op = null;
                self.vi_count = 0;
                return .cont;
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
    // -----------------------------------------------------------------------
    // Widgets
    //
    // Named editing actions, so a key can be bound to one by name. Most are a
    // single call to a method that already existed; the ones defined here are
    // the actions that only existed as inline switch arms, plus the composites
    // where Den overloads a key by context.
    // -----------------------------------------------------------------------

    /// Ctrl+C: abandon whatever is in progress.
    fn sendBreak(self: *LineEditor) !Flow {
        if (self.reverse_search_mode) {
            try self.cancelReverseSearch();
            try self.writeBytes("\r\n");
            try self.writePromptCrlf();
            self.length = 0;
            self.cursor = 0;
            return .cont;
        }

        if (self.completion_list != null) {
            self.clearCompletionState();
            try self.writeBytes("^C\r\n");
            try self.displayPrompt();
            self.length = 0;
            self.cursor = 0;
            self.resetRenderedRowToPrompt();
            return .cont;
        }

        if (self.multiline_buffer) |*mlb| {
            mlb.deinit(self.allocator);
            self.multiline_buffer = null;
            self.in_multiline = false;
        }

        // Nothing typed: just a fresh prompt. Avoids a duplicate prompt after
        // Ctrl+C'ing an external command.
        if (self.length == 0) {
            try self.writeBytes("\r\n");
            try self.displayPrompt();
            self.resetRenderedRowToPrompt();
            return .cont;
        }

        try self.writeBytes("^C\r\n");
        return .interrupt;
    }

    /// Ctrl+D: end of input on an empty line, otherwise delete forward.
    fn deleteCharOrEof(self: *LineEditor) !Flow {
        if (self.length == 0) {
            if (self.completion_list != null) try self.clearCompletionDisplay();
            try self.writeBytes("\r\n");
            return .eof;
        }
        try self.deleteChar();
        return .cont;
    }

    /// Insert the key that was typed.
    fn selfInsert(self: *LineEditor, key: []const u8) !void {
        if (key.len == 0) return;
        const b = key[0];
        if (b >= 0xC2) try self.insertUtf8(b) else try self.insertChar(b);
    }

    /// Insert the next key literally, whatever it is.
    fn quotedInsert(self: *LineEditor) !void {
        const b = (try self.nextByte()) orelse return;
        try self.insertChar(b);
    }

    fn killWholeLine(self: *LineEditor) !void {
        if (self.length == 0) return;
        self.saveUndoState();
        self.pushToKillRing(self.buffer[0..self.length]);
        self.length = 0;
        self.cursor = 0;
        try self.redrawLine();
    }

    fn undefinedKey(self: *LineEditor) !void {
        try self.writeBytes("\x07");
    }

    /// Overwrite the character under the cursor (vi replace mode).
    fn viReplaceChar(self: *LineEditor, key: []const u8) !void {
        if (key.len == 0 or self.cursor >= self.length) return;
        self.saveUndoState();
        self.buffer[self.cursor] = key[0];
        if (self.cursor < self.length - 1) self.cursor += 1;
        try self.redrawLine();
    }

    /// Add a character to the incremental-search query.
    fn isearchInsert(self: *LineEditor, key: []const u8) !void {
        if (key.len == 0) return;
        if (self.reverse_search_query_len >= self.reverse_search_query.len) return;
        self.reverse_search_query[self.reverse_search_query_len] = key[0];
        self.reverse_search_query_len += 1;
        if (self.history_count) |count| self.reverse_search_history_index = count.*;
        try self.updateReverseSearch();
    }

    /// Remove the last character from the incremental-search query.
    fn isearchDeleteChar(self: *LineEditor) !void {
        if (self.reverse_search_query_len == 0) return;
        self.reverse_search_query_len -= 1;
        if (self.history_count) |count| self.reverse_search_history_index = count.*;
        try self.updateReverseSearch();
    }

    /// A key with no meaning during incremental search accepts the match and is
    /// then run as itself -- zsh's rule. Den used to drop it silently.
    fn isearchAcceptAndRedispatch(self: *LineEditor, key: []const u8) !void {
        try self.acceptReverseSearch();
        self.pushBack(key);
    }

    // Vi mode transitions, shared with handleViNormalKey so there is one
    // implementation of each.

    fn viAddNext(self: *LineEditor) void {
        if (self.cursor < self.length) self.cursor += 1;
        self.viEnterInsertMode();
    }

    fn viAddEol(self: *LineEditor) void {
        self.cursor = self.length;
        self.viEnterInsertMode();
    }

    fn viInsertBol(self: *LineEditor) void {
        self.cursor = 0;
        self.viEnterInsertMode();
    }

    /// There is only one line to open onto, so this goes to its end.
    fn viOpenLine(self: *LineEditor) void {
        self.cursor = self.length;
        self.viEnterInsertMode();
    }

    fn viSubstitute(self: *LineEditor) !void {
        if (self.cursor < self.length) try self.deleteChar();
        self.viEnterInsertMode();
    }

    fn viChangeWholeLine(self: *LineEditor) !void {
        self.length = 0;
        self.cursor = 0;
        self.viEnterInsertMode();
        try self.redrawLine();
    }

    fn viChangeEol(self: *LineEditor) !void {
        self.length = self.cursor;
        self.viEnterInsertMode();
        try self.redrawLine();
    }

    /// Drive the keymap over a script of bytes, the way readLine's loop does,
    /// and settle anything left pending as the read timeout would. This is the
    /// entry point for testing key dispatch without a terminal.
    fn feedKeys(self: *LineEditor, bytes: []const u8) !Flow {
        self.pushBack(bytes);
        while (try self.nextByte()) |b| {
            if (try self.keymapProbe(b)) |flow| {
                switch (flow) {
                    .cont => {},
                    else => return flow,
                }
            }
        }
        if (self.pending.len > 0) return try self.resolvePending();
        return .cont;
    }

    /// Which keymap is in force right now.
    fn activeKeymapId(self: *const LineEditor) keymap.KeymapId {
        if (self.reverse_search_mode) return .isearch;
        if (self.editing_mode == .vi) return switch (self.vi_mode) {
            .normal => .vicmd,
            .replace => .vireplace,
            .insert => .viins,
        };
        return .emacs;
    }

    /// Offer a byte to the keymap.
    ///
    /// Returns null when the keymap has nothing to say and the byte should take
    /// the built-in path below -- which is every byte that begins no binding, so
    /// ordinary typing costs one lookup and nothing else.
    fn keymapProbe(self: *LineEditor, byte: u8) !?Flow {
        const maps = self.keymaps orelse return null;
        const map = maps.getConst(self.activeKeymapId());

        var probe = self.pending;
        if (!probe.push(byte)) {
            // Longer than any bindable sequence; give up on it.
            self.clearPending();
            return null;
        }

        switch (map.lookup(probe.slice())) {
            .exact => |binding| {
                self.clearPending();
                return try self.invokeBinding(binding, probe.slice());
            },
            .exact_prefix => |binding| {
                // Wait for the longer binding, remembering this one.
                self.pending = probe;
                self.pending_fallback = binding;
                self.pending_fallback_len = probe.len;
                return .cont;
            },
            .prefix => {
                self.pending = probe;
                return .cont;
            },
            .none => {
                if (self.pending.len == 0) return null; // first byte: fall through
                // Mid-sequence and nothing matches. Hand what we have to the
                // built-in escape parser, which understands the sequences the
                // keymap does not enumerate, and let it keep accumulating.
                self.handOffToEscapeParser(probe);
                self.clearPending();
                return .cont;
            },
        }
    }

    fn clearPending(self: *LineEditor) void {
        self.pending.clear();
        self.pending_fallback = null;
        self.pending_fallback_len = 0;
    }

    /// Resume the built-in escape handling for a sequence the keymap rejected.
    fn handOffToEscapeParser(self: *LineEditor, seq: keymap.KeySeq) void {
        if (seq.len == 0 or seq.bytes[0] != 0x1B) return; // nothing else to try
        self.escape_seq = seq;
        self.in_escape = true;
    }

    /// Nothing more arrived: settle an ambiguous sequence.
    fn resolvePending(self: *LineEditor) !Flow {
        const seq = self.pending;
        const fallback = self.pending_fallback;
        const fallback_len = self.pending_fallback_len;
        self.clearPending();

        if (fallback) |binding| {
            // Run the shorter binding and re-dispatch whatever followed it.
            if (seq.len > fallback_len) self.pushBack(seq.slice()[fallback_len..]);
            return try self.invokeBinding(binding, seq.slice()[0..fallback_len]);
        }
        self.handOffToEscapeParser(seq);
        return .cont;
    }

    /// Run a binding. Macro bindings (`bindkey -s`) push their text into the
    /// input to be dispatched as if typed; everything else is a widget.
    pub fn invokeBinding(self: *LineEditor, binding: keymap.Binding, key: []const u8) !Flow {
        if (binding.widget == .push_input) {
            const maps = self.keymaps orelse return .cont;
            if (maps.getString(binding.index)) |text| self.pushBack(text);
            return .cont;
        }
        return self.invokeWidget(binding.widget, key);
    }

    /// Run a widget. `key` is the byte sequence that triggered it, which the
    /// inserting widgets need (zsh calls it $KEYS).
    pub fn invokeWidget(self: *LineEditor, widget: Widget, key: []const u8) !Flow {
        switch (widget) {
            .accept_line => return self.acceptLine(),
            .send_break => return self.sendBreak(),
            .delete_char_or_eof => return self.deleteCharOrEof(),
            .undefined_key => try self.undefinedKey(),
            .ignore => {},

            .beginning_of_line => try self.moveCursorHome(),
            .end_of_line => try self.moveCursorEnd(),
            .end_of_line_or_autosuggest => {
                if (self.suggestion != null and self.cursor == self.length) {
                    try self.acceptSuggestion();
                } else {
                    try self.moveCursorEnd();
                }
            },
            .backward_char => try self.moveCursorLeft(),
            .forward_char => try self.moveCursorRight(),
            .forward_char_or_autosuggest => {
                if (self.suggestion != null and self.cursor == self.length) {
                    try self.acceptSuggestion();
                } else {
                    try self.moveCursorRight();
                }
            },
            .backward_word => try self.moveCursorWordLeft(),
            .forward_word => try self.moveCursorWordRight(),
            .vi_forward_word => {
                self.moveForwardWord();
                try self.redrawLine();
            },
            .vi_backward_word => {
                self.moveBackwardWord();
                try self.redrawLine();
            },
            .vi_forward_word_end => {
                self.moveToEndOfWord();
                try self.redrawLine();
            },

            .self_insert => try self.selfInsert(key),
            .vi_replace_char => try self.viReplaceChar(key),
            .quoted_insert => try self.quotedInsert(),
            .backward_delete_char => try self.backspace(),
            .delete_char => try self.deleteChar(),
            .transpose_chars => try self.transposeChars(),

            .kill_line => try self.killToEnd(),
            .backward_kill_line => try self.killToStart(),
            .kill_whole_line => try self.killWholeLine(),
            .kill_word => try self.killWordForward(),
            .backward_kill_word => try self.killWordBackward(),
            .yank => try self.yank(),
            .kill_region_or_backward_kill_line => {
                if (self.visual_mode) try self.cutSelection() else try self.killToStart();
            },
            .copy_region_or_backward_kill_word => {
                if (self.visual_mode) try self.copySelection() else try self.killWordBackward();
            },

            .set_mark_command => try self.startVisualMode(),
            .copy_region_as_kill => try self.copySelection(),
            .kill_region => try self.cutSelection(),

            .up_line_or_history => try self.historyPrevious(),
            .down_line_or_history => try self.historyNext(),
            .history_incremental_search_backward => {
                if (self.reverse_search_mode) {
                    try self.continueReverseSearch();
                } else {
                    try self.startReverseSearch();
                }
            },
            .toggle_fuzzy_search => try self.toggleFuzzySearch(),
            .accept_search => try self.acceptReverseSearch(),
            .cancel_search => try self.cancelReverseSearch(),
            .isearch_insert => try self.isearchInsert(key),
            .isearch_delete_char => try self.isearchDeleteChar(),
            .isearch_accept_and_redispatch => try self.isearchAcceptAndRedispatch(key),

            .expand_or_complete => try self.handleTabCompletion(false),
            .reverse_menu_complete => try self.handleTabCompletion(true),
            .autosuggest_accept => try self.acceptSuggestion(),

            .undo => try self.undo(),

            .start_kbd_macro => try self.startMacroRecording(),
            .end_kbd_macro => try self.stopMacroRecording(),
            .call_last_kbd_macro => try self.playMacro(),

            .clear_screen => try self.clearScreen(),
            .redisplay => try self.redrawLine(),

            .vi_cmd_mode => {
                self.viEnterNormalMode();
                try self.redrawLine();
            },
            .vi_insert => self.viEnterInsertMode(),
            .vi_add_next => self.viAddNext(),
            .vi_add_eol => self.viAddEol(),
            .vi_insert_bol => self.viInsertBol(),
            .vi_open_line_below, .vi_open_line_above => self.viOpenLine(),
            .vi_substitute => try self.viSubstitute(),
            .vi_change_whole_line => try self.viChangeWholeLine(),
            .vi_change_eol => try self.viChangeEol(),
            .overwrite_mode => self.vi_mode = .replace,

            .den_escape => try self.handleStandaloneEscape(),
            .bracketed_paste => try self.handlePaste(),

            // Macro bindings are resolved by invokeBinding, which has the
            // index they need.
            .push_input => {},

            // `zle -N` is not implemented, so nothing ever binds these. The
            // builtin rejects the attempt with an explanation rather than
            // letting a key quietly do nothing.
            .user_widget, .unknown => {},
        }
        return .cont;
    }

    /// Accept the current line.
    ///
    /// Returns `.cont` when the key was absorbed -- an incremental-search or
    /// completion-menu accept, or a continuation line that still needs more
    /// input -- and `.accepted` with an owned slice when there is a complete
    /// command to run.
    ///
    /// Terminal writes stay here: the transient-prompt repaint has to happen
    /// before the final CRLF, and the PS2 path writes its own. Leaving raw mode
    /// stays in readLine, so it keeps its ordering against the bracketed-paste
    /// `defer` that disables paste mode on every exit path.
    fn acceptLine(self: *LineEditor) !Flow {
        // Erase any inline (ghost-text) suggestion before submitting. The cursor
        // sits at the end of the typed input with the dim suggestion drawn to
        // its right; without this the suggestion (e.g. "; exit") gets left on
        // the executed command line.
        if (self.suggestion != null) {
            try self.writeBytes("\x1b[0K");
            self.clearSuggestion();
        }

        // In reverse search, Enter accepts the match.
        if (self.reverse_search_mode) {
            try self.acceptReverseSearch();
            if (self.length > 0) {
                try self.writeBytes("\r\n");
                return .{ .accepted = try self.allocator.dupe(u8, self.buffer[0..self.length]) };
            }
            return .cont;
        }

        // If a completion grid is showing, Enter accepts the highlighted entry
        // and returns to editing. A second Enter submits it; selecting a
        // directory must never unexpectedly execute `cd` just because the
        // chooser was confirmed.
        if (self.completion_list != null) {
            try self.applyCurrentCompletion();
            self.clearCompletionState();
            return .cont;
        }

        const current_line = self.buffer[0..self.length];

        // Build complete input (accumulated + current line).
        var complete_input: []const u8 = undefined;
        if (self.multiline_buffer) |*mlb| {
            try mlb.append(self.allocator, '\n');
            try mlb.appendSlice(self.allocator, current_line);
            complete_input = mlb.items;
        } else {
            complete_input = current_line;
        }

        // Incomplete input continues on the next line.
        if (isIncomplete(complete_input)) {
            if (self.multiline_buffer == null) {
                self.multiline_buffer = .empty;
                try self.multiline_buffer.?.appendSlice(self.allocator, current_line);
            }
            self.in_multiline = true;

            try self.writeBytes("\r\n");
            try self.writeBytes(self.ps2_prompt);

            self.length = 0;
            self.cursor = 0;
            return .cont;
        }

        // Input is complete - redraw with the transient prompt if enabled.
        if (self.transient_prompt) |transient| {
            // Count newlines in the original prompt to handle multi-line prompts.
            var newline_count: usize = 0;
            for (self.prompt) |ch| {
                if (ch == '\n') newline_count += 1;
            }
            // Move the cursor up for each newline in the prompt.
            if (newline_count > 0) {
                var move_buf: [32]u8 = undefined;
                const move_seq = std.fmt.bufPrint(&move_buf, "\x1b[{d}A", .{newline_count}) catch "\x1b[1A";
                try self.writeBytes(move_seq);
            }
            // Move to start of line and clear from here to end of screen.
            try self.writeBytes("\r\x1b[J");
            // Write the transient (minimal) prompt plus the typed command.
            try self.writeBytes(transient);
            try self.writeBytes(self.buffer[0..self.length]);
        }

        try self.writeBytes("\r\n");

        // Return the complete multi-line input, or the single line.
        if (self.multiline_buffer) |*mlb| {
            const result = try self.allocator.dupe(u8, mlb.items);
            mlb.deinit(self.allocator);
            self.multiline_buffer = null;
            self.in_multiline = false;
            return .{ .accepted = result };
        }

        if (self.length == 0) return .{ .accepted = try self.allocator.dupe(u8, "") };
        return .{ .accepted = try self.allocator.dupe(u8, self.buffer[0..self.length]) };
    }

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
        // Fresh line: the prompt was just printed. For a multi-line prompt the
        // cursor sits on the prompt's last row, so seed the tracked row with how
        // many rows the prompt spans (0 for a single-line prompt) — otherwise the
        // first repaint moves up too little and duplicates the prompt.
        const init_cols: usize = if (signals.getWindowSize()) |ws|
            (if (ws.cols == 0) 80 else ws.cols)
        else |_|
            80;
        self.rendered_cursor_row = self.promptLayout(init_cols).rows;
        self.clearHistorySearch();
        // Every new line starts in insert mode, as zsh's viins does. Without
        // this, a line accepted from normal mode leaves the next line in normal
        // mode and the first characters typed are swallowed as vi commands.
        if (self.editing_mode == .vi) self.viEnterInsertMode();

        self.clearPending();
        self.escape_seq.clear();
        self.in_escape = false;
        self.idle_polls = 0;

        while (true) {
            // Check for window resize (SIGWINCH)
            if (signals.checkWindowSizeChanged()) {
                // Terminal was resized - redraw the current line
                try self.handleWindowResize();
            }

            const maybe_byte = try self.nextByte();
            if (maybe_byte == null) {
                // An ambiguous key sequence settles once input stops arriving:
                // `^X` on its own runs nothing because `^X(` might still be
                // coming, but a lone `^[` is Escape rather than the start of a
                // cursor-key sequence.
                if (self.pending.len > 0) {
                    self.idle_polls += 1;
                    if (self.idle_polls >= self.key_timeout_polls) {
                        self.idle_polls = 0;
                        switch (try self.resolvePending()) {
                            .cont => {},
                            .accepted => |line| {
                                try self.terminal.disableRawMode();
                                return line;
                            },
                            .eof => {
                                try self.terminal.disableRawMode();
                                return null;
                            },
                            .interrupt => {
                                try self.terminal.disableRawMode();
                                return error.Interrupted;
                            },
                        }
                        continue;
                    }
                }

                // A lone Escape has no parser terminator. Once the terminal's
                // read timeout expires, handle it as a standalone key instead
                // of leaving the editor stuck waiting for another byte.
                if (self.in_escape) {
                    if (self.escape_seq.len == 1) try self.handleStandaloneEscape();
                    self.in_escape = false;
                    self.escape_seq.clear();
                }

                // No data, sleep briefly (10ms)
                std.Io.sleep(std.Options.debug_io, std.Io.Duration.fromNanoseconds(@as(i96, 10_000_000)), .awake) catch {};
                continue;
            }
            const byte = maybe_byte.?;
            self.idle_polls = 0;

            // Keymap first, so a bound key wins over the built-in handling
            // below. Skipped while the escape parser is mid-sequence, and while
            // a completion menu is open: the menu owns the arrow keys and Enter,
            // so bindings do not fire until it is dismissed.
            if (!self.in_escape and self.completion_list == null) {
                if (try self.keymapProbe(byte)) |flow| switch (flow) {
                    .cont => continue,
                    .accepted => |line| {
                        try self.terminal.disableRawMode();
                        return line;
                    },
                    .eof => {
                        try self.terminal.disableRawMode();
                        return null;
                    },
                    .interrupt => {
                        try self.terminal.disableRawMode();
                        return error.Interrupted;
                    },
                };
            }

            // Handle escape sequences
            if (self.in_escape) {
                _ = self.escape_seq.push(byte);

                if (EscapeSequence.parse(self.escape_seq.slice())) |seq| {
                    try self.handleEscapeSequence(seq);
                    self.in_escape = false;
                    self.escape_seq.clear();
                } else if (self.escape_seq.len >= keymap.max_key_seq_len) {
                    // Invalid sequence, ignore
                    self.in_escape = false;
                    self.escape_seq.clear();
                }
                continue;
            }

            // Check for escape start
            if (byte == 0x1B) {
                self.escape_seq.clear();
                _ = self.escape_seq.push(byte);
                self.in_escape = true;
                continue;
            }

            // Handle special characters
            switch (byte) {
                '\r', '\n' => switch (try self.acceptLine()) {
                    .cont => continue,
                    .accepted => |line| {
                        try self.terminal.disableRawMode();
                        return line;
                    },
                    .eof => {
                        try self.terminal.disableRawMode();
                        return null;
                    },
                    .interrupt => {
                        try self.terminal.disableRawMode();
                        return error.Interrupted;
                    },
                },
                0x03 => {
                    // Ctrl+C
                    if (self.reverse_search_mode) {
                        // Cancel reverse search and clear line
                        try self.cancelReverseSearch();
                        try self.writeBytes("\r\n");
                        try self.writePromptCrlf();
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
                        self.resetRenderedRowToPrompt();
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
                        self.resetRenderedRowToPrompt();
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
                    const next_byte = (try self.nextByte()) orelse continue;
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
                    // Tab - handle completion (forward)
                    if (!self.reverse_search_mode) {
                        try self.handleTabCompletion(false);
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
                        // Vi normal mode - handle navigation/commands.
                        // Accepting goes through the same acceptLine as Enter in
                        // insert mode; the hand-rolled copy that used to live
                        // here ignored multiline_buffer, so a continuation
                        // accepted from normal mode returned only its last
                        // physical line and leaked the accumulated buffer.
                        switch (try self.handleViNormalKey(byte)) {
                            .cont => {},
                            .accepted => |line| {
                                try self.terminal.disableRawMode();
                                return line;
                            },
                            .eof => {
                                try self.terminal.disableRawMode();
                                return null;
                            },
                            .interrupt => {
                                try self.terminal.disableRawMode();
                                return error.Interrupted;
                            },
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
        // In raw mode ONLCR is off, so a bare '\n' in a multi-line prompt would
        // line-feed without returning to column 0 and the prompt would
        // stair-step to the right (e.g. after Ctrl+C). Translate newlines to
        // CRLF when raw; the initial prompt runs in cooked mode and doesn't need it.
        if (self.terminal.is_raw) {
            try self.writePromptCrlf();
        } else {
            try self.writeBytes(self.prompt);
        }
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
        self.saved_history_cursor = 0;
    }

    /// Start one history-navigation session. `history_index == count` is the
    /// explicit "original typed line" position, which also keeps a failed first
    /// search from allocating the saved line and query again on every Up press.
    fn beginHistorySearch(self: *LineEditor, count: usize) !void {
        if (self.history_index != null) return;

        // Defensive cleanup makes a new prompt independent from any prior
        // navigation session, including one that found no matching entries.
        self.clearHistorySearch();

        self.saved_line = try self.allocator.dupe(u8, self.buffer[0..self.length]);
        errdefer {
            self.allocator.free(self.saved_line.?);
            self.saved_line = null;
            self.saved_history_cursor = 0;
        }

        self.saved_history_cursor = self.cursor;
        if (self.cursor > 0) {
            self.history_search_query = try self.allocator.dupe(u8, self.buffer[0..self.cursor]);
        }
        self.history_index = count;
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
        try self.writePromptCrlf();
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
        try self.writePromptCrlf();

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
            const b = (try self.nextByte()) orelse break;
            if (!isUtf8Continuation(b)) {
                // Malformed sequence. Hand the stray byte back to the read loop
                // so it is dispatched as its own key: inserting it here typed a
                // raw control character into the buffer when something like
                // Ctrl+C or Tab arrived mid-codepoint.
                self.pushBack(&.{b});
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
            const byte = (try self.nextByte()) orelse {
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
        return textDisplayWidth(self.buffer[from..to]);
    }

    fn textDisplayWidth(text: []const u8) usize {
        var cols: usize = 0;
        var p: usize = 0;
        while (p < text.len) {
            const len = @min(utf8SeqLen(text[p]), text.len - p);
            cols += codepointWidth(decodeCodepoint(text[p .. p + len], len));
            p += len;
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

        // The remaining text was just rewritten from column 0, so the terminal
        // cursor sits at its end; walk it back to the start.
        //
        // This loop used to test `self.cursor < self.length` without ever
        // changing `self.cursor`, which is already 0 by this point -- so it
        // never terminated whenever any text followed the cursor. Ctrl+U with
        // the cursor mid-line hung the shell, spinning on cursor-left escapes.
        var back: usize = self.length;
        while (back > 0) : (back -= 1) {
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
        // Shift+Tab cycles completions in reverse (mirror of Tab).
        if (seq == .back_tab) {
            if (!self.reverse_search_mode) try self.handleTabCompletion(true);
            return;
        }

        // If we have an active completion list, arrow keys navigate the grid.
        // The list is laid out column-major (idx = col * rows + row), so down/up
        // step within a column and left/right step between columns — matching what
        // the user sees, instead of both axes moving linearly.
        if (self.completion_list != null) {
            const len = self.completion_list.?.len;
            const grid = self.completionGrid();
            const nr = @max(1, grid.rows);
            const col = self.completion_index / nr;
            const row = self.completion_index % nr;
            switch (seq) {
                .down_arrow => {
                    // Next row in this column; wrap to the column's top.
                    const ni = col * nr + (row + 1);
                    self.completion_index = if (row + 1 < nr and ni < len) ni else col * nr;
                    try self.applyCurrentCompletion();
                    try self.updateCompletionListHighlight();
                    return;
                },
                .up_arrow => {
                    if (row > 0) {
                        self.completion_index -= 1;
                    } else {
                        // Wrap to the bottom-most populated row of this column.
                        var r = nr - 1;
                        while (col * nr + r >= len) r -= 1;
                        self.completion_index = col * nr + r;
                    }
                    try self.applyCurrentCompletion();
                    try self.updateCompletionListHighlight();
                    return;
                },
                .right_arrow => {
                    // Next column, same row; wrap to the first column.
                    const ni = (col + 1) * nr + row;
                    self.completion_index = if (col + 1 < grid.cols and ni < len) ni else row;
                    try self.applyCurrentCompletion();
                    try self.updateCompletionListHighlight();
                    return;
                },
                .left_arrow => {
                    if (col > 0) {
                        self.completion_index = (col - 1) * nr + row;
                    } else {
                        // Wrap to the last column that has an item in this row.
                        var c = grid.cols - 1;
                        while (c * nr + row >= len) c -= 1;
                        self.completion_index = c * nr + row;
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
            .alt_backspace => try self.killWordBackward(),
            .modified_delete => try self.killWordForward(),
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

    fn handleStandaloneEscape(self: *LineEditor) !void {
        if (self.editing_mode == .vi and (self.vi_mode == .insert or self.vi_mode == .replace)) {
            self.viEnterNormalMode();
            try self.redrawLine();
        } else if (self.reverse_search_mode) {
            try self.cancelReverseSearch();
        } else if (self.visual_mode) {
            try self.cancelVisualMode();
        } else if (self.completion_list != null) {
            self.clearCompletionState();
        }
    }

    fn historyPrevious(self: *LineEditor) !void {
        const history = self.history orelse return;
        const count = self.history_count orelse return;
        if (count.* == 0) return;

        try self.beginHistorySearch(count.*);
        self.clearSuggestion();

        const current_index = self.history_index.?;
        const current_line = self.buffer[0..self.length];
        if (findPreviousHistoryMatch(history[0..count.*], current_index, self.history_search_query, current_line)) |i| {
            try self.replaceLine(history[i].?);
            self.history_index = i;
        }

        // At the oldest distinct match, keep the line and search position stable.
    }

    fn historyNext(self: *LineEditor) !void {
        const history = self.history orelse return;
        const count = self.history_count orelse return;

        const current_index = self.history_index orelse return; // Not browsing history
        self.clearSuggestion();

        const current_line = self.buffer[0..self.length];
        if (findNextHistoryMatch(history[0..count.*], current_index, self.history_search_query, current_line)) |i| {
            try self.replaceLine(history[i].?);
            self.history_index = i;
            return;
        }

        // Moving newer past the newest match restores the exact original line,
        // including an empty line, and ends the navigation session.
        if (self.saved_line) |saved| {
            try self.replaceLineAtCursor(saved, self.saved_history_cursor);
        } else {
            try self.replaceLine("");
        }
        self.clearHistorySearch();
    }

    fn replaceLine(self: *LineEditor, text: []const u8) !void {
        try self.replaceLineAtCursor(text, text.len);
    }

    fn replaceLineAtCursor(self: *LineEditor, text: []const u8, cursor: usize) !void {
        // Swap in the new buffer, then do a full wrap-/multi-line-aware repaint.
        // (The old manual "home + clear-to-EOL + write" overwrote the prompt's
        // last line — dropping the prompt symbol — and couldn't handle a prompt
        // that spans rows.)
        self.length = @min(text.len, self.buffer.len);
        @memcpy(self.buffer[0..self.length], text[0..self.length]);
        self.cursor = @min(cursor, self.length);
        try self.redrawLine();
    }

    fn writeBytes(self: *LineEditor, bytes: []const u8) !void {
        if (self.write_sink) |sink| {
            try sink.appendSlice(self.allocator, bytes);
            return;
        }

        if (builtin.os.tag == .windows) {
            const handle = @import("windows_compat").GetStdHandle(@import("windows_compat").STD_OUTPUT_HANDLE) orelse return error.NoStdOut;
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
            text: []const u8,
        };

        var scored = try self.allocator.alloc(ScoredCompletion, completions.len);
        defer self.allocator.free(scored);

        for (completions, 0..) |completion, i| {
            // Strip marker if present
            const text = if (completion.len > 0 and (completion[0] == '\x02' or completion[0] == '\x03'))
                completion[1..]
            else
                completion;
            const without_trailing_slash = std.mem.trimEnd(u8, text, "/");
            const match_text = std.fs.path.basename(without_trailing_slash);

            scored[i] = .{
                .index = i,
                .score = fuzzyMatchScore(pattern, match_text),
                .text = text,
            };
        }

        // Sort by score (descending), then by the order the completion provider
        // supplied. That order is already deterministic and carries ranking this
        // scorer can't see — which commands the user actually runs, for one — so
        // re-sorting equal scores lexically here would throw it away and put
        // `clang` ahead of the `claude` the provider deliberately promoted.
        std.mem.sort(ScoredCompletion, scored, {}, struct {
            fn lessThan(_: void, a: ScoredCompletion, b: ScoredCompletion) bool {
                if (a.score != b.score) return a.score > b.score;
                return a.index < b.index;
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
    fn handleTabCompletion(self: *LineEditor, reverse: bool) !void {
        const completion_fn = self.completion_fn orelse return;

        // Erase any inline (ghost-text) autosuggestion before completing. Leaving
        // it drawn lets it collide with the completion grid / applied word on
        // redraw, which can corrupt what's shown on the input line.
        if (self.suggestion != null) {
            try self.writeBytes("\x1b[0K");
            self.clearSuggestion();
        }

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
            // Cycle to the next (Tab) or previous (Shift+Tab) completion.
            const n = self.completion_list.?.len;
            self.completion_index = if (reverse)
                (self.completion_index + n - 1) % n
            else
                (self.completion_index + 1) % n;
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
                // A completion candidate represents the whole active word.
                // Replacing that range handles nested paths and also preserves
                // any command text to the right of the cursor.
                const completion = completions[0];
                const typed_word = self.buffer[word_start..self.cursor];

                // Strip marker if present (e.g., \x02 for scripts/commands)
                const actual_completion = completionText(completion);

                const path_prefix = if (std.mem.lastIndexOfScalar(u8, typed_word, '/')) |last_slash|
                    typed_word[0 .. last_slash + 1]
                else
                    "";
                var replacement_buf: [4096]u8 = undefined;
                if (completionReplacement(path_prefix, actual_completion, &replacement_buf)) |replacement| {
                    if (!try self.replaceCompletionWord(word_start, replacement)) {
                        try self.writeBytes("\x07");
                    }
                } else {
                    try self.writeBytes("\x07");
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

                // Extend to the unambiguous common prefix before presenting the
                // chooser. For `cd my/pa`, candidates `my/path-a/` and
                // `my/path-b/` immediately fill `my/path-` while still offering
                // both selectable destinations.
                const common_prefix = longestCommonCompletionPrefix(self.completion_list.?);
                var typed_normalized_buf: [4096]u8 = undefined;
                var common_normalized_buf: [4096]u8 = undefined;
                const typed_normalized = normalizedShellWord(typed_word, &typed_normalized_buf) orelse typed_word;
                const common_normalized = normalizedShellWord(common_prefix, &common_normalized_buf) orelse common_prefix;
                if (common_normalized.len > typed_normalized.len and
                    std.mem.startsWith(u8, common_normalized, typed_normalized))
                {
                    if (!try self.replaceCompletionWord(word_start, common_prefix)) {
                        try self.writeBytes("\x07");
                    }
                }

                // Show the list
                try self.displayCompletionList();
            }
        }
    }

    /// Replace the active word without disturbing text after the cursor. This is
    /// shared by single-match completion and the interactive chooser.
    fn replaceCompletionWord(self: *LineEditor, word_start: usize, replacement: []const u8) !bool {
        const old_cursor = self.cursor;
        const old_word_width = self.displayWidth(word_start, old_cursor);

        if (!replaceBufferRange(&self.buffer, &self.length, word_start, old_cursor, replacement)) {
            return false;
        }
        self.cursor = word_start + replacement.len;

        // Keep the chooser rendered below the input line: repaint only the
        // changed span and its preserved tail, then return to the new word end.
        try self.writeBytes("\x1b[?25l");
        if (old_word_width > 0) {
            var move_buf: [32]u8 = undefined;
            const move_back = try std.fmt.bufPrint(&move_buf, "\x1b[{d}D", .{old_word_width});
            try self.writeBytes(move_back);
        }
        try self.writeBytes("\x1b[K");
        try self.writeBytes(self.buffer[word_start..self.length]);

        const tail_width = self.displayWidth(self.cursor, self.length);
        if (tail_width > 0) {
            var move_buf: [32]u8 = undefined;
            const move_back = try std.fmt.bufPrint(&move_buf, "\x1b[{d}D", .{tail_width});
            try self.writeBytes(move_back);
        }
        try self.writeBytes("\x1b[?25h");
        return true;
    }

    /// Apply the current completion from the cycling list
    fn applyCurrentCompletion(self: *LineEditor) !void {
        const completions = self.completion_list orelse return;
        const completion = completions[self.completion_index];

        // Strip marker if present
        const actual_completion = completionText(completion);

        // Use the saved path prefix only for compatibility with custom
        // callbacks that return basenames. Native candidates are complete words.
        const path_prefix = self.completion_path_prefix orelse "";
        var replacement_buf: [4096]u8 = undefined;
        const replacement = completionReplacement(path_prefix, actual_completion, &replacement_buf) orelse {
            try self.writeBytes("\x07");
            return;
        };
        if (!try self.replaceCompletionWord(self.completion_word_start, replacement)) {
            try self.writeBytes("\x07");
        }
    }

    /// Display completion list
    /// The column-major grid dimensions the completion list is rendered with.
    /// Display, highlight, and arrow-key navigation all derive layout from this so
    /// they stay in sync (idx = col * rows + row).
    fn completionGrid(self: *LineEditor) struct { rows: usize, cols: usize, col_width: usize } {
        const completions = self.completion_list orelse return .{ .rows = 0, .cols = 0, .col_width = 1 };
        if (completions.len == 0) return .{ .rows = 0, .cols = 0, .col_width = 1 };
        var max_width: usize = 0;
        for (completions) |c| {
            const width = textDisplayWidth(completionText(c));
            if (width > max_width) max_width = width;
        }
        const term_width = if (signals.getWindowSize()) |ws| (if (ws.cols == 0) 80 else ws.cols) else |_| 80;
        const col_width = max_width + 2;
        const num_cols = @max(1, term_width / col_width);
        const num_rows = (completions.len + num_cols - 1) / num_cols;
        return .{ .rows = num_rows, .cols = num_cols, .col_width = col_width };
    }

    fn displayCompletionList(self: *LineEditor) !void {
        const completions = self.completion_list orelse return;

        // Hide cursor to prevent flicker during redraw
        try self.writeBytes("\x1b[?25l");
        // Save cursor, show list, restore cursor
        try self.writeBytes("\x1b[s");
        try self.writeBytes("\r\n");

        const grid = self.completionGrid();
        const col_width = grid.col_width;
        const num_cols = grid.cols;
        const num_rows = grid.rows;

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
                    const padding = col_width - textDisplayWidth(display_text);
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

        const grid = self.completionGrid();
        const col_width = grid.col_width;
        const num_cols = grid.cols;
        const num_rows = grid.rows;

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
                    const padding = col_width - textDisplayWidth(display_text);
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

        _ = completions;
        const num_rows = self.completionGrid().rows;

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

    /// How the prompt lays out across terminal rows: `rows` is how many rows it
    /// spans *below* its first row (0 for a single-line prompt), and `last_col`
    /// is the column where it ends — i.e. where the input buffer begins. Honors
    /// embedded newlines (multi-line prompts) and wrapping, skipping zero-width
    /// ANSI/OSC escapes. Without this the redraw assumed a single-row prompt and
    /// reprinted the whole prompt on every repaint when it contained a newline.
    fn promptLayout(self: *LineEditor, cols: usize) struct { rows: usize, last_col: usize } {
        const w = if (cols == 0) 80 else cols;
        var row: usize = 0;
        var col: usize = 0;
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
                row += 1;
                col = 0;
                i += 1;
                continue;
            }
            const len = utf8SeqLen(p[i]);
            const end = @min(i + len, p.len);
            const cw = codepointWidth(decodeCodepoint(p[i..end], end - i));
            if (col + cw > w) {
                row += 1;
                col = 0;
            }
            col += cw;
            i = end;
        }
        return .{ .rows = row, .last_col = col };
    }

    /// Write the prompt with each `\n` emitted as `\r\n`. In raw mode ONLCR is
    /// off, so a bare newline moves down without returning to column 0; a
    /// multi-line prompt repainted that way stair-steps. Used by repaint paths
    /// (the initial displayPrompt runs in cooked mode and doesn't need this).
    /// Reset the tracked cursor row to the freshly-drawn prompt's row span, so the
    /// next repaint moves up the right amount after an in-place prompt redraw.
    fn resetRenderedRowToPrompt(self: *LineEditor) void {
        const cols: usize = if (signals.getWindowSize()) |ws|
            (if (ws.cols == 0) 80 else ws.cols)
        else |_|
            80;
        self.rendered_cursor_row = self.promptLayout(cols).rows;
    }

    fn writePromptCrlf(self: *LineEditor) !void {
        var start: usize = 0;
        var i: usize = 0;
        while (i < self.prompt.len) : (i += 1) {
            if (self.prompt[i] == '\n') {
                try self.writeBytes(self.prompt[start..i]);
                try self.writeBytes("\r\n");
                start = i + 1;
            }
        }
        try self.writeBytes(self.prompt[start..]);
    }

    /// Wrap-aware full-line repaint. Repaints the prompt + buffer and positions
    /// the cursor at its true (row, col), correctly handling lines that wrap
    /// across multiple terminal rows AND prompts that span multiple rows (an
    /// embedded newline or a prompt wider than the terminal).
    fn redrawLine(self: *LineEditor) !void {
        const cols: usize = if (signals.getWindowSize()) |ws|
            (if (ws.cols == 0) 80 else ws.cols)
        else |_|
            80;

        // The prompt may span several rows (multi-line or wider than the
        // terminal); the buffer continues from where it ends.
        const layout = self.promptLayout(cols);
        const prow = layout.rows; // rows the prompt spans below its first row
        const pcol = layout.last_col; // column where the buffer begins

        const total_tail = pcol + self.displayWidth(0, self.length);
        const cursor_tail = pcol + self.displayWidth(0, self.cursor);

        const last_row = prow + total_tail / cols;
        const cursor_row = prow + cursor_tail / cols;
        const cursor_col = cursor_tail % cols;

        var buf: [32]u8 = undefined;

        // 1. Move up to the first row of the previously rendered block.
        if (self.rendered_cursor_row > 0) {
            const seq = std.fmt.bufPrint(&buf, "\x1B[{d}A", .{self.rendered_cursor_row}) catch "";
            try self.writeBytes(seq);
        }

        // 2. Column 0, clear everything below.
        try self.writeBytes("\r\x1B[0J");

        // 3. Prompt. Translate the prompt's own newlines to CRLF: redrawLine runs
        //    in raw mode (ONLCR off), so a bare \n line-feeds without returning to
        //    column 0 and a multi-line prompt would stair-step to the right.
        try self.writePromptCrlf();

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
        if (total_tail > 0 and total_tail % cols == 0) {
            try self.writeBytes("\r\n");
        }
        const end_row = if (total_tail > 0 and total_tail % cols == 0) last_row + 1 else last_row;

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

        // Repaint at the new width. Keep rendered_cursor_row as-is: redrawLine
        // moves up by it to reach the first row of the current block before
        // clearing. Zeroing it here made redrawLine clear from the *current* row
        // (the prompt's last line) downward, leaving the prompt's first line(s)
        // behind — e.g. an initial SIGWINCH duplicated a two-line prompt's first
        // row, showing "~\n~\n❯" on a fresh terminal.
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
        return shellWordStart(self.buffer[0..self.length], self.cursor);
    }

    /// Search history for a suggestion matching current input
    fn updateSuggestion(self: *LineEditor) !void {
        self.clearSuggestion();

        if (!self.autosuggestions) return;
        if (self.length == 0) return;
        const history = self.history orelse return;
        const count_ptr = self.history_count orelse return;

        const current_input = self.buffer[0..self.length];
        const match = findSuggestion(history, count_ptr.*, current_input) orelse return;

        const owned = try self.allocator.dupe(u8, match);
        self.suggestion_entry = owned;
        self.suggestion = owned[self.length..];
    }

    /// Display the suggestion in gray text.
    ///
    /// Clipped to what fits on the current row. Ghost text that wrapped would
    /// leave the cursor a row below where the caller left it (the relative
    /// cursor-left below can't climb rows) and could scroll the screen out from
    /// under the next redraw. The full entry is still what Right/End accepts.
    fn displaySuggestion(self: *LineEditor) !void {
        const sugg = self.suggestion orelse return;
        if (sugg.len == 0) return;

        const cols: usize = if (signals.getWindowSize()) |ws|
            (if (ws.cols == 0) 80 else ws.cols)
        else |_|
            80;

        const layout = self.promptLayout(cols);
        // Leave the final cell of the row empty: filling it puts the terminal in
        // a deferred-wrap state where the cursor's column is ambiguous.
        const used = (layout.last_col + self.displayWidth(0, self.length)) % cols;
        const room = cols - used - 1;
        if (room == 0) return;

        // Take whole codepoints only, up to the columns left on this row.
        var bytes: usize = 0;
        var width: usize = 0;
        while (bytes < sugg.len) {
            const len = @min(utf8SeqLen(sugg[bytes]), sugg.len - bytes);
            const w = codepointWidth(decodeCodepoint(sugg[bytes .. bytes + len], len));
            if (width + w > room) break;
            bytes += len;
            width += w;
        }
        if (width == 0) return;

        try self.writeBytes("\x1b[90m");
        try self.writeBytes(sugg[0..bytes]);
        try self.writeBytes("\x1b[0m");

        var buf: [16]u8 = undefined;
        const seq = std.fmt.bufPrint(&buf, "\x1b[{d}D", .{width}) catch return;
        try self.writeBytes(seq);
    }

    /// Clear the suggestion
    fn clearSuggestion(self: *LineEditor) void {
        if (self.suggestion_entry) |entry| {
            self.allocator.free(entry);
            self.suggestion_entry = null;
        }
        self.suggestion = null;
    }

    /// Accept the current suggestion
    fn acceptSuggestion(self: *LineEditor) !void {
        const entry = self.suggestion_entry orelse return;
        if (entry.len > self.buffer.len or entry.len <= self.length) {
            self.clearSuggestion();
            return;
        }

        // A case-insensitive match means what's on screen isn't a prefix of the
        // entry, so adopt the entry verbatim rather than splicing onto a
        // differently-cased stem.
        const typed_matches = std.mem.eql(u8, self.buffer[0..self.length], entry[0..self.length]);
        @memcpy(self.buffer[0..entry.len], entry);
        const tail = entry[self.length..];
        self.length = entry.len;
        self.cursor = entry.len;

        if (typed_matches) {
            try self.writeBytes(tail);
            self.clearSuggestion();
        } else {
            self.clearSuggestion();
            try self.redrawLine();
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

test "suggestion offers the most recently run match" {
    const history = [_]?[]const u8{
        "claude --dangerously-skip-permissions",
        "claude upgrade",
        "claude --skip-permissions",
        "web",
        "claude --dangerously-skip-permissions",
    };

    try std.testing.expectEqualStrings(
        "claude --dangerously-skip-permissions",
        findSuggestion(&history, history.len, "cl").?,
    );
    try std.testing.expectEqualStrings(
        "claude upgrade",
        findSuggestion(&history, history.len, "claude u").?,
    );
    try std.testing.expectEqual(@as(?[]const u8, null), findSuggestion(&history, history.len, "zzz"));
    try std.testing.expectEqual(@as(?[]const u8, null), findSuggestion(&history, history.len, ""));
}

test "suggestion honours the live history count and ignores holes" {
    const history = [_]?[]const u8{ "git status", null, "git push", null, null };

    // Entries past history_count are stale slots, not suggestions.
    try std.testing.expectEqualStrings("git push", findSuggestion(&history, 3, "git").?);
    try std.testing.expectEqualStrings("git status", findSuggestion(&history, 2, "git").?);
    try std.testing.expectEqual(@as(?[]const u8, null), findSuggestion(&history, 0, "git"));
}

test "suggestion skips entries that add nothing to accept" {
    const history = [_]?[]const u8{ "make build", "make   " };

    // "make " only pads with spaces, so it is not worth suggesting over the
    // command that actually does something.
    try std.testing.expectEqualStrings("make build", findSuggestion(&history, history.len, "make").?);
    try std.testing.expectEqual(@as(?[]const u8, null), findSuggestion(&history, history.len, "make build"));
}

test "suggestion falls back to a case-insensitive match" {
    const history = [_]?[]const u8{ "Docker compose up", "git status" };

    try std.testing.expectEqualStrings(
        "Docker compose up",
        findSuggestion(&history, history.len, "docker").?,
    );

    // An exact match always wins over a case-insensitive one, however recent.
    const both = [_]?[]const u8{ "docker ps", "Docker compose up" };
    try std.testing.expectEqualStrings("docker ps", findSuggestion(&both, both.len, "docker").?);
}

test "history prefix navigation visits distinct matches in both directions" {
    const history = [_]?[]const u8{
        "git status",
        "echo unrelated",
        "git log",
        "git log",
        "git diff",
    };

    const newest = findPreviousHistoryMatch(&history, history.len, "git", "git");
    try std.testing.expectEqual(@as(?usize, 4), newest);

    const older = findPreviousHistoryMatch(&history, newest.?, "git", history[newest.?].?);
    try std.testing.expectEqual(@as(?usize, 3), older);

    // The adjacent duplicate is skipped because another Up press must visibly
    // advance through the matching commands.
    const oldest = findPreviousHistoryMatch(&history, older.?, "git", history[older.?].?);
    try std.testing.expectEqual(@as(?usize, 0), oldest);
    try std.testing.expectEqual(@as(?usize, null), findPreviousHistoryMatch(&history, oldest.?, "git", history[oldest.?].?));

    const newer = findNextHistoryMatch(&history, oldest.?, "git", history[oldest.?].?);
    try std.testing.expectEqual(@as(?usize, 2), newer);
    const newest_again = findNextHistoryMatch(&history, newer.?, "git", history[newer.?].?);
    try std.testing.expectEqual(@as(?usize, 4), newest_again);
}

test "history navigation keeps prefix semantics and ignores holes" {
    const history = [_]?[]const u8{
        "cargo test",
        null,
        "git status",
        "cargo build",
    };

    try std.testing.expectEqual(
        @as(?usize, 3),
        findPreviousHistoryMatch(&history, history.len, "cargo ", "cargo "),
    );
    try std.testing.expectEqual(
        @as(?usize, null),
        findPreviousHistoryMatch(&history, history.len, "arg", "arg"),
    );
}

test "history search session saves empty input once and resets cleanly" {
    var editor = LineEditor.init(std.testing.allocator, "");
    defer editor.deinit();

    try editor.beginHistorySearch(7);
    const saved = editor.saved_line.?;
    try std.testing.expectEqualStrings("", saved);
    try std.testing.expectEqual(@as(?usize, 7), editor.history_index);
    try std.testing.expectEqual(@as(?[]const u8, null), editor.history_search_query);

    try editor.beginHistorySearch(7);
    try std.testing.expect(saved.ptr == editor.saved_line.?.ptr);

    editor.clearHistorySearch();
    try std.testing.expectEqual(@as(?usize, null), editor.history_index);
    try std.testing.expectEqual(@as(?[]const u8, null), editor.saved_line);
}

test "history search uses text before cursor and restores the draft cursor" {
    var editor = LineEditor.init(std.testing.allocator, "");
    defer editor.deinit();

    const draft = "git status --short";
    @memcpy(editor.buffer[0..draft.len], draft);
    editor.length = draft.len;
    editor.cursor = "git".len;

    try editor.beginHistorySearch(4);
    try std.testing.expectEqualStrings(draft, editor.saved_line.?);
    try std.testing.expectEqualStrings("git", editor.history_search_query.?);
    try std.testing.expectEqual(@as(usize, 3), editor.saved_history_cursor);
}

test "equally scored completions keep the order the provider supplied" {
    var editor = LineEditor.init(std.testing.allocator, "");
    defer editor.deinit();

    // The provider promoted `claude` because that is what the user runs; the
    // editor's re-sort must not reshuffle it back behind `clang` on a tie.
    const supplied = [_][]const u8{ "claude", "clang", "clang++" };
    const list = try std.testing.allocator.alloc([]const u8, supplied.len);
    for (supplied, 0..) |item, i| list[i] = item;
    editor.completion_list = list;

    try editor.sortCompletionsByFuzzyScore("cla");

    const sorted = editor.completion_list.?;
    defer {
        std.testing.allocator.free(sorted);
        editor.completion_list = null;
    }
    try std.testing.expectEqualStrings("claude", sorted[0]);
    try std.testing.expectEqualStrings("clang", sorted[1]);
    try std.testing.expectEqualStrings("clang++", sorted[2]);
}

test "completion replacement does not duplicate nested path prefixes" {
    var scratch: [64]u8 = undefined;

    try std.testing.expectEqualStrings(
        "my/path-alpha/",
        completionReplacement("my/", "my/path-alpha/", &scratch).?,
    );
    try std.testing.expectEqualStrings(
        "my/path-alpha/",
        completionReplacement("my/", "path-alpha/", &scratch).?,
    );
    try std.testing.expectEqualStrings(
        "expanded/path-alpha/",
        completionReplacement("my/", "expanded/path-alpha/", &scratch).?,
    );
}

test "completion chooser extends the common nested path prefix" {
    const candidates = [_][]const u8{
        "my/path-alpha/",
        "my/path-beta/",
        "my/path-build/",
    };
    try std.testing.expectEqualStrings(
        "my/path-",
        longestCommonCompletionPrefix(&candidates),
    );

    const marked = [_][]const u8{ "\x02status", "\x02stash" };
    try std.testing.expectEqualStrings("sta", longestCommonCompletionPrefix(&marked));

    var typed_buf: [64]u8 = undefined;
    var common_buf: [64]u8 = undefined;
    const typed = normalizedShellWord("\"my dir/pa", &typed_buf).?;
    const common = normalizedShellWord("my\\ dir/path-", &common_buf).?;
    try std.testing.expect(std.mem.startsWith(u8, common, typed));
}

test "completion word start respects escaped spaces and quotes" {
    try std.testing.expectEqual(@as(usize, 3), shellWordStart("cd my\\ dir/pa", "cd my\\ dir/pa".len));
    try std.testing.expectEqual(@as(usize, 3), shellWordStart("cd \"my dir/pa", "cd \"my dir/pa".len));
    try std.testing.expectEqual(@as(usize, 16), shellWordStart("printf 'a b' && my", "printf 'a b' && my".len));
}

test "completion grid width uses terminal columns for Unicode" {
    try std.testing.expectEqual(@as(usize, 3), LineEditor.textDisplayWidth("abc"));
    try std.testing.expectEqual(@as(usize, 2), LineEditor.textDisplayWidth("界"));
    try std.testing.expectEqual(@as(usize, 1), LineEditor.textDisplayWidth("e\u{301}"));
    try std.testing.expectEqual(@as(usize, 2), LineEditor.textDisplayWidth("🚀"));
}

test "completion word replacement preserves text after cursor" {
    var buffer: [64]u8 = undefined;
    const original = "cd my/pa --verbose";
    @memcpy(buffer[0..original.len], original);
    var length = original.len;

    const cursor = "cd my/pa".len;
    try std.testing.expect(replaceBufferRange(&buffer, &length, "cd ".len, cursor, "my/path-alpha/"));
    try std.testing.expectEqualStrings("cd my/path-alpha/ --verbose", buffer[0..length]);

    try std.testing.expect(replaceBufferRange(
        &buffer,
        &length,
        "cd ".len,
        "cd my/path-alpha/".len,
        "my/p/",
    ));
    try std.testing.expectEqualStrings("cd my/p/ --verbose", buffer[0..length]);
}

test "completion word replacement rejects overflow without mutation" {
    var buffer: [8]u8 = undefined;
    @memcpy(buffer[0..4], "cd x");
    var length: usize = 4;

    try std.testing.expect(!replaceBufferRange(&buffer, &length, 3, 4, "far-too-long"));
    try std.testing.expectEqual(@as(usize, 4), length);
    try std.testing.expectEqualStrings("cd x", buffer[0..length]);
}

test "setEditingMode selects vi and starts in insert mode" {
    var editor = LineEditor.init(std.testing.allocator, "");
    defer editor.deinit();

    try std.testing.expectEqual(EditingMode.emacs, editor.editing_mode);

    editor.setEditingMode(.vi);
    try std.testing.expectEqual(EditingMode.vi, editor.editing_mode);
    try std.testing.expectEqual(ViMode.insert, editor.vi_mode);

    editor.setEditingMode(.emacs);
    try std.testing.expectEqual(EditingMode.emacs, editor.editing_mode);
}

test "leaving vi normal mode is reset for the next line" {
    var editor = LineEditor.init(std.testing.allocator, "");
    defer editor.deinit();

    editor.setEditingMode(.vi);
    editor.viEnterNormalMode();
    try std.testing.expectEqual(ViMode.normal, editor.vi_mode);

    // readLine seeds each line with viEnterInsertMode; assert the reset it
    // performs, without needing a tty to run the loop itself.
    editor.viEnterInsertMode();
    try std.testing.expectEqual(ViMode.insert, editor.vi_mode);
    try std.testing.expectEqual(@as(?u8, null), editor.vi_pending_op);
    try std.testing.expectEqual(@as(usize, 0), editor.vi_count);
}

/// Build an editor wired to a capture buffer, with the typed text already in it.
fn testEditor(sink: *std.ArrayList(u8), text: []const u8) LineEditor {
    var editor = LineEditor.init(std.testing.allocator, "$ ");
    @memcpy(editor.buffer[0..text.len], text);
    editor.length = text.len;
    editor.cursor = text.len;
    editor.write_sink = sink;
    editor.no_terminal = true;
    // The highlighter and the history-backed suggestions are not under test
    // here, and both do real work on every repaint.
    editor.syntax_highlighting = false;
    editor.autosuggestions = false;
    return editor;
}

test "acceptLine returns the typed line" {
    var sink: std.ArrayList(u8) = .empty;
    defer sink.deinit(std.testing.allocator);
    var editor = testEditor(&sink, "echo hi");
    defer editor.deinit();

    switch (try editor.acceptLine()) {
        .accepted => |line| {
            defer std.testing.allocator.free(line);
            try std.testing.expectEqualStrings("echo hi", line);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqualStrings("\r\n", sink.items);
}

test "acceptLine returns an empty string for an empty line" {
    var sink: std.ArrayList(u8) = .empty;
    defer sink.deinit(std.testing.allocator);
    var editor = testEditor(&sink, "");
    defer editor.deinit();

    switch (try editor.acceptLine()) {
        .accepted => |line| {
            defer std.testing.allocator.free(line);
            try std.testing.expectEqualStrings("", line);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "acceptLine continues an incomplete line and shows the PS2 prompt" {
    var sink: std.ArrayList(u8) = .empty;
    defer sink.deinit(std.testing.allocator);
    var editor = testEditor(&sink, "echo \"foo");
    defer editor.deinit();

    try std.testing.expectEqual(Flow.cont, try editor.acceptLine());
    try std.testing.expect(editor.in_multiline);
    try std.testing.expect(editor.multiline_buffer != null);
    try std.testing.expectEqual(@as(usize, 0), editor.length);
    try std.testing.expectEqual(@as(usize, 0), editor.cursor);
    try std.testing.expect(std.mem.endsWith(u8, sink.items, editor.ps2_prompt));
}

test "acceptLine joins continuation lines" {
    var sink: std.ArrayList(u8) = .empty;
    defer sink.deinit(std.testing.allocator);
    var editor = testEditor(&sink, "echo \"foo");
    defer editor.deinit();

    try std.testing.expectEqual(Flow.cont, try editor.acceptLine());

    const second = "bar\"";
    @memcpy(editor.buffer[0..second.len], second);
    editor.length = second.len;
    editor.cursor = second.len;

    switch (try editor.acceptLine()) {
        .accepted => |line| {
            defer std.testing.allocator.free(line);
            try std.testing.expectEqualStrings("echo \"foo\nbar\"", line);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(!editor.in_multiline);
    try std.testing.expectEqual(@as(?std.ArrayList(u8), null), editor.multiline_buffer);
}

test "accepting from vi normal mode joins continuation lines too" {
    // Regression test: vi normal mode used to run its own copy of accept-line
    // that ignored multiline_buffer, so this returned only "bar\"" and leaked
    // the accumulated buffer.
    var sink: std.ArrayList(u8) = .empty;
    defer sink.deinit(std.testing.allocator);
    var editor = testEditor(&sink, "echo \"foo");
    defer editor.deinit();
    editor.setEditingMode(.vi);
    editor.vi_mode = .normal;

    try std.testing.expectEqual(Flow.cont, try editor.handleViNormalKey('\r'));
    try std.testing.expect(editor.multiline_buffer != null);

    const second = "bar\"";
    @memcpy(editor.buffer[0..second.len], second);
    editor.length = second.len;
    editor.cursor = second.len;

    switch (try editor.handleViNormalKey('\r')) {
        .accepted => |line| {
            defer std.testing.allocator.free(line);
            try std.testing.expectEqualStrings("echo \"foo\nbar\"", line);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "acceptLine repaints with the transient prompt" {
    var sink: std.ArrayList(u8) = .empty;
    defer sink.deinit(std.testing.allocator);
    var editor = testEditor(&sink, "ls");
    defer editor.deinit();
    editor.setTransientPrompt("> ");

    switch (try editor.acceptLine()) {
        .accepted => |line| {
            defer std.testing.allocator.free(line);
            try std.testing.expectEqualStrings("ls", line);
        },
        else => return error.TestUnexpectedResult,
    }
    // Clear to end of screen, the minimal prompt, then the command it replaces.
    try std.testing.expectEqualStrings("\r\x1b[J> ls\r\n", sink.items);
}

test "acceptLine erases a ghost suggestion before submitting" {
    var sink: std.ArrayList(u8) = .empty;
    defer sink.deinit(std.testing.allocator);
    var editor = testEditor(&sink, "ech");
    defer editor.deinit();
    // `suggestion` is a borrowed view; only `suggestion_entry` owns memory.
    editor.suggestion = "o hi";

    switch (try editor.acceptLine()) {
        .accepted => |line| std.testing.allocator.free(line),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqualStrings("\x1b[0K\r\n", sink.items);
    try std.testing.expectEqual(@as(?[]const u8, null), editor.suggestion);
}

test "nextByte drains the pushback queue before the terminal" {
    var editor = LineEditor.init(std.testing.allocator, "");
    defer editor.deinit();
    editor.no_terminal = true;

    editor.pushBack("abc");
    try std.testing.expectEqual(@as(?u8, 'a'), try editor.nextByte());
    try std.testing.expectEqual(@as(?u8, 'b'), try editor.nextByte());
    try std.testing.expectEqual(@as(?u8, 'c'), try editor.nextByte());
    // Empty queue and no terminal: nothing available.
    try std.testing.expectEqual(@as(?u8, null), try editor.nextByte());
}

test "pushBack wraps around the ring and drops the overflow" {
    var editor = LineEditor.init(std.testing.allocator, "");
    defer editor.deinit();
    editor.no_terminal = true;

    // Advance the head so the next fill has to wrap.
    editor.pushBack("xy");
    _ = try editor.nextByte();
    _ = try editor.nextByte();

    var full: [300]u8 = @splat('z');
    editor.pushBack(&full);
    try std.testing.expectEqual(editor.input_queue.len, editor.input_queue_len);

    var seen: usize = 0;
    while (try editor.nextByte()) |b| : (seen += 1) {
        try std.testing.expectEqual(@as(u8, 'z'), b);
    }
    try std.testing.expectEqual(editor.input_queue.len, seen);
}

test "insertUtf8 hands a stray byte back instead of inserting it" {
    // Regression test: a control byte arriving mid-codepoint used to be written
    // into the buffer as a literal character.
    var editor = LineEditor.init(std.testing.allocator, "");
    defer editor.deinit();
    editor.no_terminal = true;

    var sink: std.ArrayList(u8) = .empty;
    defer sink.deinit(std.testing.allocator);
    editor.write_sink = &sink;

    // 0xC3 starts a two-byte codepoint; 0x09 (Tab) is not a continuation byte.
    editor.pushBack(&.{0x09});
    try editor.insertUtf8(0xC3);

    // The stray byte goes back to the read loop to be dispatched as its own
    // key, rather than being typed into the line.
    try std.testing.expectEqual(@as(?u8, 0x09), try editor.nextByte());
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOfScalar(u8, editor.buffer[0..editor.length], 0x09));
    // The incomplete lead byte is still inserted. That is deliberate and
    // unchanged: `nextByte` also returns null when a slow terminal simply has
    // not delivered the continuation bytes yet, and dropping the character
    // there would silently swallow input.
    try std.testing.expectEqual(@as(usize, 1), editor.length);
    try std.testing.expectEqual(@as(u8, 0xC3), editor.buffer[0]);
}

test "invokeWidget moves the cursor" {
    var sink: std.ArrayList(u8) = .empty;
    defer sink.deinit(std.testing.allocator);
    var editor = testEditor(&sink, "echo hi");
    defer editor.deinit();

    _ = try editor.invokeWidget(.beginning_of_line, "\x01");
    try std.testing.expectEqual(@as(usize, 0), editor.cursor);
    _ = try editor.invokeWidget(.end_of_line, "\x05");
    try std.testing.expectEqual(@as(usize, 7), editor.cursor);
    _ = try editor.invokeWidget(.backward_char, "\x02");
    try std.testing.expectEqual(@as(usize, 6), editor.cursor);
    _ = try editor.invokeWidget(.forward_char, "\x06");
    try std.testing.expectEqual(@as(usize, 7), editor.cursor);
}

test "invokeWidget edits the line" {
    var sink: std.ArrayList(u8) = .empty;
    defer sink.deinit(std.testing.allocator);
    var editor = testEditor(&sink, "echo hi");
    defer editor.deinit();

    _ = try editor.invokeWidget(.backward_kill_word, "\x17");
    try std.testing.expectEqualStrings("echo ", editor.buffer[0..editor.length]);

    _ = try editor.invokeWidget(.self_insert, "y");
    try std.testing.expectEqualStrings("echo y", editor.buffer[0..editor.length]);

    _ = try editor.invokeWidget(.kill_whole_line, "");
    try std.testing.expectEqual(@as(usize, 0), editor.length);
    try std.testing.expectEqual(@as(usize, 0), editor.cursor);

    // kill_whole_line saved to the kill ring, so yank brings it back.
    _ = try editor.invokeWidget(.yank, "\x19");
    try std.testing.expectEqualStrings("echo y", editor.buffer[0..editor.length]);
}

test "invokeWidget kill_line and backward_kill_line split at the cursor" {
    var sink: std.ArrayList(u8) = .empty;
    defer sink.deinit(std.testing.allocator);
    var editor = testEditor(&sink, "echo hello");
    defer editor.deinit();

    editor.cursor = 5;
    _ = try editor.invokeWidget(.kill_line, "\x0b");
    try std.testing.expectEqualStrings("echo ", editor.buffer[0..editor.length]);

    _ = try editor.invokeWidget(.backward_kill_line, "\x15");
    try std.testing.expectEqual(@as(usize, 0), editor.length);
}

test "invokeWidget reports the flow for accept, break and eof" {
    var sink: std.ArrayList(u8) = .empty;
    defer sink.deinit(std.testing.allocator);

    {
        var editor = testEditor(&sink, "ls");
        defer editor.deinit();
        switch (try editor.invokeWidget(.accept_line, "\r")) {
            .accepted => |line| {
                defer std.testing.allocator.free(line);
                try std.testing.expectEqualStrings("ls", line);
            },
            else => return error.TestUnexpectedResult,
        }
    }
    {
        // Ctrl+C with text present interrupts.
        var editor = testEditor(&sink, "ls");
        defer editor.deinit();
        try std.testing.expectEqual(Flow.interrupt, try editor.invokeWidget(.send_break, "\x03"));
    }
    {
        // Ctrl+C on an empty line just reprompts.
        var editor = testEditor(&sink, "");
        defer editor.deinit();
        try std.testing.expectEqual(Flow.cont, try editor.invokeWidget(.send_break, "\x03"));
    }
    {
        // Ctrl+D on an empty line is end of input.
        var editor = testEditor(&sink, "");
        defer editor.deinit();
        try std.testing.expectEqual(Flow.eof, try editor.invokeWidget(.delete_char_or_eof, "\x04"));
    }
    {
        // With text, it deletes forward instead.
        var editor = testEditor(&sink, "ab");
        defer editor.deinit();
        editor.cursor = 0;
        try std.testing.expectEqual(Flow.cont, try editor.invokeWidget(.delete_char_or_eof, "\x04"));
        try std.testing.expectEqualStrings("b", editor.buffer[0..editor.length]);
    }
}

test "invokeWidget undefined_key beeps and ignore does nothing" {
    var sink: std.ArrayList(u8) = .empty;
    defer sink.deinit(std.testing.allocator);
    var editor = testEditor(&sink, "ab");
    defer editor.deinit();

    _ = try editor.invokeWidget(.undefined_key, "\x07");
    try std.testing.expectEqualStrings("\x07", sink.items);

    sink.clearRetainingCapacity();
    _ = try editor.invokeWidget(.ignore, "\x00");
    try std.testing.expectEqualStrings("", sink.items);
    try std.testing.expectEqualStrings("ab", editor.buffer[0..editor.length]);
}

test "invokeWidget quoted_insert takes the next byte literally" {
    var sink: std.ArrayList(u8) = .empty;
    defer sink.deinit(std.testing.allocator);
    var editor = testEditor(&sink, "");
    defer editor.deinit();
    editor.no_terminal = true;

    editor.pushBack(&.{0x1B});
    _ = try editor.invokeWidget(.quoted_insert, "\x16");
    try std.testing.expectEqual(@as(usize, 1), editor.length);
    try std.testing.expectEqual(@as(u8, 0x1B), editor.buffer[0]);
}

test "invokeWidget CtrlU outside visual mode kills to start" {
    // Regression test: with text after the cursor, killToStart used to spin
    // forever writing cursor-left escapes, hanging the shell.
    var sink: std.ArrayList(u8) = .empty;
    defer sink.deinit(std.testing.allocator);
    var editor = testEditor(&sink, "echo hello");
    defer editor.deinit();
    editor.cursor = 5;
    _ = try editor.invokeWidget(.kill_region_or_backward_kill_line, "\x15");
    try std.testing.expectEqualStrings("hello", editor.buffer[0..editor.length]);
    try std.testing.expectEqual(@as(usize, 0), editor.cursor);
}

test "invokeWidget CtrlU inside visual mode cuts the selection" {
    var sink: std.ArrayList(u8) = .empty;
    defer sink.deinit(std.testing.allocator);
    var editor = testEditor(&sink, "echo hello");
    defer editor.deinit();
    editor.visual_mode = true;
    editor.visual_start = 0;
    editor.cursor = 4;
    _ = try editor.invokeWidget(.kill_region_or_backward_kill_line, "\x15");
    try std.testing.expectEqualStrings(" hello", editor.buffer[0..editor.length]);
}

test "invokeWidget vi transitions match handleViNormalKey" {
    var sink: std.ArrayList(u8) = .empty;
    defer sink.deinit(std.testing.allocator);

    // Both paths share one implementation, so `A` and vi_add_eol must agree.
    var a = testEditor(&sink, "echo");
    defer a.deinit();
    a.setEditingMode(.vi);
    a.vi_mode = .normal;
    a.cursor = 0;
    _ = try a.handleViNormalKey('A');

    var b = testEditor(&sink, "echo");
    defer b.deinit();
    b.setEditingMode(.vi);
    b.vi_mode = .normal;
    b.cursor = 0;
    _ = try b.invokeWidget(.vi_add_eol, "A");

    try std.testing.expectEqual(a.cursor, b.cursor);
    try std.testing.expectEqual(a.vi_mode, b.vi_mode);
    try std.testing.expectEqual(ViMode.insert, b.vi_mode);
    try std.testing.expectEqual(@as(usize, 4), b.cursor);
}

test "invokeWidget isearch widgets drive the search query" {
    var sink: std.ArrayList(u8) = .empty;
    defer sink.deinit(std.testing.allocator);
    var editor = testEditor(&sink, "");
    defer editor.deinit();
    editor.reverse_search_mode = true;

    _ = try editor.invokeWidget(.isearch_insert, "g");
    _ = try editor.invokeWidget(.isearch_insert, "i");
    _ = try editor.invokeWidget(.isearch_insert, "t");
    try std.testing.expectEqualStrings("git", editor.reverse_search_query[0..editor.reverse_search_query_len]);

    _ = try editor.invokeWidget(.isearch_delete_char, "\x7f");
    try std.testing.expectEqualStrings("gi", editor.reverse_search_query[0..editor.reverse_search_query_len]);

    // An unbound key accepts the search and is then re-run as itself.
    editor.no_terminal = true;
    _ = try editor.invokeWidget(.isearch_accept_and_redispatch, "\x01");
    try std.testing.expect(!editor.reverse_search_mode);
    try std.testing.expectEqual(@as(?u8, 0x01), try editor.nextByte());
}

/// An editor wired to a capture buffer and its own keymaps, with text in place.
fn testKeyEditor(sink: *std.ArrayList(u8), maps: *keymap.KeymapSet, text: []const u8) LineEditor {
    var editor = testEditor(sink, text);
    editor.keymaps = maps;
    return editor;
}

test "keymap dispatches single-byte bindings" {
    var sink: std.ArrayList(u8) = .empty;
    defer sink.deinit(std.testing.allocator);
    var maps = keymap.KeymapSet.init();
    defer maps.deinit(std.testing.allocator);
    var editor = testKeyEditor(&sink, &maps, "echo hi");
    defer editor.deinit();

    _ = try editor.feedKeys("\x01"); // Ctrl+A
    try std.testing.expectEqual(@as(usize, 0), editor.cursor);
    _ = try editor.feedKeys("\x05"); // Ctrl+E
    try std.testing.expectEqual(@as(usize, 7), editor.cursor);
}

test "keymap dispatches a multi-byte sequence" {
    var sink: std.ArrayList(u8) = .empty;
    defer sink.deinit(std.testing.allocator);
    var maps = keymap.KeymapSet.init();
    defer maps.deinit(std.testing.allocator);
    var editor = testKeyEditor(&sink, &maps, "");
    defer editor.deinit();

    try std.testing.expect(!editor.macro_recording);
    _ = try editor.feedKeys("\x18("); // Ctrl+X (
    try std.testing.expect(editor.macro_recording);
    _ = try editor.feedKeys("\x18)"); // Ctrl+X )
    try std.testing.expect(!editor.macro_recording);
}

test "a lone Ctrl+X types nothing when its sequence never completes" {
    // Regression test. Ctrl+X used to read the second byte itself with a
    // non-blocking read and drop the prefix when it had not arrived yet; the
    // late byte was then reprocessed as ordinary input, so a slow `^X(` typed a
    // literal '(' into the line. Ctrl+X is a prefix with no exact binding, so
    // settling it must run nothing at all.
    var sink: std.ArrayList(u8) = .empty;
    defer sink.deinit(std.testing.allocator);
    var maps = keymap.KeymapSet.init();
    defer maps.deinit(std.testing.allocator);
    var editor = testKeyEditor(&sink, &maps, "");
    defer editor.deinit();

    _ = try editor.feedKeys("\x18");
    try std.testing.expectEqual(@as(usize, 0), editor.length);
    try std.testing.expect(!editor.macro_recording);
    try std.testing.expectEqual(@as(u8, 0), editor.pending.len);
}

test "a lone Escape settles as Escape, not as a cursor-key prefix" {
    var sink: std.ArrayList(u8) = .empty;
    defer sink.deinit(std.testing.allocator);
    var maps = keymap.KeymapSet.init();
    defer maps.deinit(std.testing.allocator);
    var editor = testKeyEditor(&sink, &maps, "abc");
    defer editor.deinit();

    // Escape cancels visual selection, which is what den-escape does in emacs.
    editor.visual_mode = true;
    _ = try editor.feedKeys("\x1b");
    try std.testing.expect(!editor.visual_mode);
    try std.testing.expectEqual(@as(u8, 0), editor.pending.len);
}

test "keymap dispatches an arrow key by its bytes" {
    var sink: std.ArrayList(u8) = .empty;
    defer sink.deinit(std.testing.allocator);
    var maps = keymap.KeymapSet.init();
    defer maps.deinit(std.testing.allocator);
    var editor = testKeyEditor(&sink, &maps, "abc");
    defer editor.deinit();

    editor.cursor = 2;
    _ = try editor.feedKeys("\x1b[D"); // Left
    try std.testing.expectEqual(@as(usize, 1), editor.cursor);
    _ = try editor.feedKeys("\x1b[C"); // Right
    try std.testing.expectEqual(@as(usize, 2), editor.cursor);
}

test "a user binding takes effect immediately" {
    var sink: std.ArrayList(u8) = .empty;
    defer sink.deinit(std.testing.allocator);
    var maps = keymap.KeymapSet.init();
    defer maps.deinit(std.testing.allocator);
    var editor = testKeyEditor(&sink, &maps, "echo hi");
    defer editor.deinit();

    // Rebind Ctrl+T, which defaults to transpose-chars.
    try maps.get(.emacs).bind(std.testing.allocator, "\x14", .kill_whole_line, 0);
    _ = try editor.feedKeys("\x14");
    try std.testing.expectEqual(@as(usize, 0), editor.length);
}

test "an unbound byte is left to the built-in handling" {
    var sink: std.ArrayList(u8) = .empty;
    defer sink.deinit(std.testing.allocator);
    var maps = keymap.KeymapSet.init();
    defer maps.deinit(std.testing.allocator);
    var editor = testKeyEditor(&sink, &maps, "");
    defer editor.deinit();

    // Printable characters are not in the table; the probe declines them so the
    // existing insert path (with its modal branches) still runs.
    try std.testing.expectEqual(@as(?Flow, null), try editor.keymapProbe('q'));
    try std.testing.expectEqual(@as(usize, 0), editor.length);
}

test "an unbound key consumes its byte instead of falling through" {
    // This is what makes `bindkey -r` honest while the built-in handling is
    // still in place: unbinding records "does nothing" rather than deleting the
    // row, so Ctrl+A stops moving the cursor instead of reverting to it.
    var sink: std.ArrayList(u8) = .empty;
    defer sink.deinit(std.testing.allocator);
    var maps = keymap.KeymapSet.init();
    defer maps.deinit(std.testing.allocator);
    var editor = testKeyEditor(&sink, &maps, "echo hi");
    defer editor.deinit();

    _ = try maps.get(.emacs).unbind(std.testing.allocator, "\x01");
    editor.cursor = 4;
    const flow = try editor.keymapProbe(0x01);
    try std.testing.expectEqual(@as(?Flow, Flow.cont), flow); // consumed
    try std.testing.expectEqual(@as(usize, 4), editor.cursor); // but did nothing
}

test "an unenumerated escape sequence is handed back to the escape parser" {
    var sink: std.ArrayList(u8) = .empty;
    defer sink.deinit(std.testing.allocator);
    var maps = keymap.KeymapSet.init();
    defer maps.deinit(std.testing.allocator);
    var editor = testKeyEditor(&sink, &maps, "abc");
    defer editor.deinit();

    // ESC [ 1 ; 2 diverges from every table entry at the "2".
    _ = try editor.feedKeys("\x1b[1;2");
    try std.testing.expect(editor.in_escape);
    try std.testing.expectEqualStrings("\x1b[1;2", editor.escape_seq.slice());
    try std.testing.expectEqual(@as(u8, 0), editor.pending.len);
}

test "the keymap is skipped entirely when it is not set" {
    var sink: std.ArrayList(u8) = .empty;
    defer sink.deinit(std.testing.allocator);
    var editor = testEditor(&sink, "echo hi");
    defer editor.deinit();

    try std.testing.expectEqual(@as(?Flow, null), try editor.keymapProbe(0x01));
}

test "activeKeymapId follows the editing and search modes" {
    var sink: std.ArrayList(u8) = .empty;
    defer sink.deinit(std.testing.allocator);
    var editor = testEditor(&sink, "");
    defer editor.deinit();

    try std.testing.expectEqual(keymap.KeymapId.emacs, editor.activeKeymapId());
    editor.setEditingMode(.vi);
    try std.testing.expectEqual(keymap.KeymapId.viins, editor.activeKeymapId());
    editor.vi_mode = .normal;
    try std.testing.expectEqual(keymap.KeymapId.vicmd, editor.activeKeymapId());
    editor.vi_mode = .replace;
    try std.testing.expectEqual(keymap.KeymapId.vireplace, editor.activeKeymapId());
    // Incremental search wins over the editing mode.
    editor.reverse_search_mode = true;
    try std.testing.expectEqual(keymap.KeymapId.isearch, editor.activeKeymapId());
}

test "a string binding pushes its text into the input" {
    var sink: std.ArrayList(u8) = .empty;
    defer sink.deinit(std.testing.allocator);
    var maps = keymap.KeymapSet.init();
    defer maps.deinit(std.testing.allocator);
    var editor = testKeyEditor(&sink, &maps, "");
    defer editor.deinit();

    // bindkey -s '^X^Z' 'fg\n'
    const body = try std.testing.allocator.dupe(u8, "fg\n");
    const index = try maps.addString(std.testing.allocator, body);
    try maps.get(.emacs).bind(std.testing.allocator, "\x18\x1a", .push_input, index);

    // The text is queued rather than typed directly, so the read loop
    // dispatches it exactly as if the user had hit those keys.
    const flow = try editor.invokeBinding(.{ .widget = .push_input, .index = index }, "\x18\x1a");
    try std.testing.expectEqual(Flow.cont, flow);
    try std.testing.expectEqual(@as(usize, 3), editor.input_queue_len);
    try std.testing.expectEqual(@as(?u8, 'f'), try editor.nextByte());
    try std.testing.expectEqual(@as(?u8, 'g'), try editor.nextByte());
    try std.testing.expectEqual(@as(?u8, '\n'), try editor.nextByte());
}

test "a string binding's text is dispatched as real keys" {
    var sink: std.ArrayList(u8) = .empty;
    defer sink.deinit(std.testing.allocator);
    var maps = keymap.KeymapSet.init();
    defer maps.deinit(std.testing.allocator);
    var editor = testKeyEditor(&sink, &maps, "echo hi");
    defer editor.deinit();

    // Bind Ctrl+T to a macro that is itself Ctrl+A, and check the cursor moves:
    // the pushed byte has to go back through key dispatch, not into the buffer.
    const body = try std.testing.allocator.dupe(u8, "\x01");
    const index = try maps.addString(std.testing.allocator, body);
    try maps.get(.emacs).bind(std.testing.allocator, "\x14", .push_input, index);

    try std.testing.expectEqual(@as(usize, 7), editor.cursor);
    _ = try editor.feedKeys("\x14");
    try std.testing.expectEqual(@as(usize, 0), editor.cursor);
}

test "a string binding with a missing string does nothing" {
    var sink: std.ArrayList(u8) = .empty;
    defer sink.deinit(std.testing.allocator);
    var maps = keymap.KeymapSet.init();
    defer maps.deinit(std.testing.allocator);
    var editor = testKeyEditor(&sink, &maps, "");
    defer editor.deinit();

    try maps.get(.emacs).bind(std.testing.allocator, "\x18\x1a", .push_input, 7);
    _ = try editor.feedKeys("\x18\x1a");
    try std.testing.expectEqual(@as(usize, 0), editor.input_queue_len);
    try std.testing.expectEqual(@as(usize, 0), editor.length);
}
