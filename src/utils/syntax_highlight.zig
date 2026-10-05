const std = @import("std");

/// Syntax highlighting for shell commands
pub const SyntaxHighlighter = struct {
    allocator: std.mem.Allocator,

    // ANSI color codes
    const Color = struct {
        const RESET = "\x1b[0m";
        const GREEN = "\x1b[32m"; // Valid commands
        const BLUE = "\x1b[34m"; // Builtins
        const CYAN = "\x1b[36m"; // Flags/options
        const YELLOW = "\x1b[33m"; // Strings
        const MAGENTA = "\x1b[35m"; // Variables
        const RED = "\x1b[31m"; // Errors/invalid
        const RED_BG = "\x1b[41m"; // Error background (for severe errors)
        const GRAY = "\x1b[90m"; // Comments
        const BOLD_GREEN = "\x1b[1;32m"; // Commands (bold)
        const UNDERLINE_RED = "\x1b[4;31m"; // Underlined red for syntax errors
    };

    /// Syntax error types that can be detected
    pub const SyntaxError = struct {
        position: usize,
        length: usize,
        message: []const u8,
    };

    // Shell builtins for highlighting
    const builtins = [_][]const u8{
        "cd",   "pwd",    "echo",   "exit",    "env",     "export",   "set",     "unset",
        "true", "false",  "test",   "[",       "alias",   "unalias",  "which",   "type",
        "help", "read",   "printf", "source",  ".",       "history",  "pushd",   "popd",
        "dirs", "eval",   "exec",   "command", "builtin", "jobs",     "fg",      "bg",
        "wait", "disown", "kill",   "trap",    "times",   "umask",    "getopts", "clear",
        "time", "hash",   "yes",    "reload",  "watch",   "tree",     "grep",    "find",
        "calc", "json",   "ls",     "seq",     "date",    "parallel", "http",    "base64",
        "uuid",   "bindkey", "zle",
    };

    // Shell keywords
    const keywords = [_][]const u8{
        "if",   "then", "else",     "elif",  "fi",
        "case", "esac", "for",      "while", "until",
        "do",   "done", "function", "in",
    };

    pub fn init(allocator: std.mem.Allocator) SyntaxHighlighter {
        return .{ .allocator = allocator };
    }

    /// Apply syntax highlighting to a command line
    pub fn highlight(self: *SyntaxHighlighter, line: []const u8) ![]const u8 {
        if (line.len == 0) return try self.allocator.dupe(u8, line);

        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(self.allocator);

        var pos: usize = 0;
        var in_string: bool = false;
        var string_char: u8 = 0;
        var in_comment: bool = false;
        var word_start: ?usize = null;
        var is_first_word: bool = true;

        while (pos < line.len) {
            const c = line[pos];

            // Handle comments
            if (c == '#' and !in_string) {
                in_comment = true;
                try result.appendSlice(self.allocator, Color.GRAY);
                try result.append(self.allocator, c);
                pos += 1;
                continue;
            }

            if (in_comment) {
                try result.append(self.allocator, c);
                pos += 1;
                continue;
            }

            // Handle strings
            if ((c == '"' or c == '\'') and !in_string) {
                in_string = true;
                string_char = c;
                try result.appendSlice(self.allocator, Color.YELLOW);
                try result.append(self.allocator, c);
                pos += 1;
                continue;
            } else if (in_string and c == string_char) {
                try result.append(self.allocator, c);
                try result.appendSlice(self.allocator, Color.RESET);
                in_string = false;
                pos += 1;
                continue;
            } else if (in_string) {
                try result.append(self.allocator, c);
                pos += 1;
                continue;
            }

            // Handle variables
            if (c == '$') {
                try result.appendSlice(self.allocator, Color.MAGENTA);
                try result.append(self.allocator, c);
                pos += 1;

                // Read variable name
                if (pos < line.len and line[pos] == '{') {
                    try result.append(self.allocator, line[pos]);
                    pos += 1;
                    while (pos < line.len and line[pos] != '}') {
                        try result.append(self.allocator, line[pos]);
                        pos += 1;
                    }
                    if (pos < line.len) {
                        try result.append(self.allocator, line[pos]);
                        pos += 1;
                    }
                } else {
                    while (pos < line.len and (std.ascii.isAlphanumeric(line[pos]) or line[pos] == '_')) {
                        try result.append(self.allocator, line[pos]);
                        pos += 1;
                    }
                }
                try result.appendSlice(self.allocator, Color.RESET);
                continue;
            }

            // Handle flags (- or --)
            if (c == '-' and word_start == null) {
                word_start = pos;
                try result.appendSlice(self.allocator, Color.CYAN);
                try result.append(self.allocator, c);
                pos += 1;

                // Read the rest of the flag
                while (pos < line.len and !std.ascii.isWhitespace(line[pos])) {
                    try result.append(self.allocator, line[pos]);
                    pos += 1;
                }
                try result.appendSlice(self.allocator, Color.RESET);
                word_start = null;
                continue;
            }

            // Handle word boundaries
            if (std.ascii.isWhitespace(c) or c == '|' or c == '&' or c == ';' or c == '(' or c == ')') {
                // End of word - check if it was a command/keyword/builtin
                if (word_start) |start| {
                    const word = line[start..pos];
                    if (is_first_word) {
                        if (self.isBuiltin(word)) {
                            try result.appendSlice(self.allocator, Color.BLUE);
                        } else if (self.isKeyword(word)) {
                            try result.appendSlice(self.allocator, Color.BLUE);
                        } else {
                            try result.appendSlice(self.allocator, Color.BOLD_GREEN);
                        }
                        try result.appendSlice(self.allocator, word);
                        try result.appendSlice(self.allocator, Color.RESET);
                        is_first_word = false;
                    } else {
                        try result.appendSlice(self.allocator, word);
                    }
                    word_start = null;
                }

                try result.append(self.allocator, c);
                if (c == '|' or c == '&' or c == ';') {
                    is_first_word = true;
                }
                pos += 1;
                continue;
            }

            // Start of a new word
            if (word_start == null) {
                word_start = pos;
            }

            pos += 1;
        }

        // Handle final word
        if (word_start) |start| {
            const word = line[start..];
            if (is_first_word) {
                if (self.isBuiltin(word)) {
                    try result.appendSlice(self.allocator, Color.BLUE);
                } else if (self.isKeyword(word)) {
                    try result.appendSlice(self.allocator, Color.BLUE);
                } else {
                    try result.appendSlice(self.allocator, Color.BOLD_GREEN);
                }
                try result.appendSlice(self.allocator, word);
                try result.appendSlice(self.allocator, Color.RESET);
            } else {
                try result.appendSlice(self.allocator, word);
            }
        }

        // Add final reset if still in comment
        if (in_comment) {
            try result.appendSlice(self.allocator, Color.RESET);
        }

        return result.toOwnedSlice(self.allocator);
    }

    fn isBuiltin(self: *SyntaxHighlighter, word: []const u8) bool {
        _ = self;
        for (builtins) |builtin| {
            if (std.mem.eql(u8, word, builtin)) {
                return true;
            }
        }
        return false;
    }

    fn isKeyword(self: *SyntaxHighlighter, word: []const u8) bool {
        _ = self;
        for (keywords) |keyword| {
            if (std.mem.eql(u8, word, keyword)) {
                return true;
            }
        }
        return false;
    }

    /// Detect syntax errors in a command line
    pub fn detectErrors(self: *SyntaxHighlighter, line: []const u8) ![]SyntaxError {
        var errors = std.ArrayList(SyntaxError).empty;
        errdefer errors.deinit(self.allocator);

        // Check for unmatched quotes
        var single_quote_pos: ?usize = null;
        var double_quote_pos: ?usize = null;
        var in_single_quote = false;
        var in_double_quote = false;
        var escape_next = false;

        for (line, 0..) |c, i| {
            if (escape_next) {
                escape_next = false;
                continue;
            }

            if (c == '\\' and !in_single_quote) {
                escape_next = true;
                continue;
            }

            if (c == '\'' and !in_double_quote) {
                if (in_single_quote) {
                    in_single_quote = false;
                    single_quote_pos = null;
                } else {
                    in_single_quote = true;
                    single_quote_pos = i;
                }
            } else if (c == '"' and !in_single_quote) {
                if (in_double_quote) {
                    in_double_quote = false;
                    double_quote_pos = null;
                } else {
                    in_double_quote = true;
                    double_quote_pos = i;
                }
            }
        }

        if (single_quote_pos) |pos| {
            try errors.append(self.allocator, .{
                .position = pos,
                .length = 1,
                .message = "unmatched single quote",
            });
        }

        if (double_quote_pos) |pos| {
            try errors.append(self.allocator, .{
                .position = pos,
                .length = 1,
                .message = "unmatched double quote",
            });
        }

        // Check for unmatched brackets/parentheses
        var paren_stack = std.ArrayList(usize).empty;
        defer paren_stack.deinit(self.allocator);
        var bracket_stack = std.ArrayList(usize).empty;
        defer bracket_stack.deinit(self.allocator);
        var brace_stack = std.ArrayList(usize).empty;
        defer brace_stack.deinit(self.allocator);

        in_single_quote = false;
        in_double_quote = false;
        escape_next = false;

        for (line, 0..) |c, i| {
            if (escape_next) {
                escape_next = false;
                continue;
            }

            if (c == '\\') {
                escape_next = true;
                continue;
            }

            if (c == '\'' and !in_double_quote) {
                in_single_quote = !in_single_quote;
                continue;
            }

            if (c == '"' and !in_single_quote) {
                in_double_quote = !in_double_quote;
                continue;
            }

            if (in_single_quote or in_double_quote) continue;

            switch (c) {
                '(' => try paren_stack.append(self.allocator, i),
                ')' => {
                    if (paren_stack.items.len > 0) {
                        _ = paren_stack.pop();
                    } else {
                        try errors.append(self.allocator, .{
                            .position = i,
                            .length = 1,
                            .message = "unmatched closing parenthesis",
                        });
                    }
                },
                '[' => try bracket_stack.append(self.allocator, i),
                ']' => {
                    if (bracket_stack.items.len > 0) {
                        _ = bracket_stack.pop();
                    } else {
                        try errors.append(self.allocator, .{
                            .position = i,
                            .length = 1,
                            .message = "unmatched closing bracket",
                        });
                    }
                },
                '{' => try brace_stack.append(self.allocator, i),
                '}' => {
                    if (brace_stack.items.len > 0) {
                        _ = brace_stack.pop();
                    } else {
                        try errors.append(self.allocator, .{
                            .position = i,
                            .length = 1,
                            .message = "unmatched closing brace",
                        });
                    }
                },
                else => {},
            }
        }

        // Report unclosed brackets
        for (paren_stack.items) |pos| {
            try errors.append(self.allocator, .{
                .position = pos,
                .length = 1,
                .message = "unmatched opening parenthesis",
            });
        }

        for (bracket_stack.items) |pos| {
            try errors.append(self.allocator, .{
                .position = pos,
                .length = 1,
                .message = "unmatched opening bracket",
            });
        }

        for (brace_stack.items) |pos| {
            try errors.append(self.allocator, .{
                .position = pos,
                .length = 1,
                .message = "unmatched opening brace",
            });
        }

        // Check for trailing operators
        const trimmed = std.mem.trimEnd(u8, line, &std.ascii.whitespace);
        if (trimmed.len > 0) {
            const last_char = trimmed[trimmed.len - 1];
            if (last_char == '|' or last_char == '&') {
                // Check if it's not escaped
                var escaped = false;
                if (trimmed.len > 1) {
                    var backslash_count: usize = 0;
                    var j = trimmed.len - 2;
                    while (j > 0 and trimmed[j] == '\\') : (j -= 1) {
                        backslash_count += 1;
                    }
                    if (trimmed[j] == '\\') backslash_count += 1;
                    escaped = (backslash_count % 2) == 1;
                }

                if (!escaped) {
                    try errors.append(self.allocator, .{
                        .position = trimmed.len - 1,
                        .length = 1,
                        .message = "incomplete command after operator",
                    });
                }
            }
        }

        return errors.toOwnedSlice(self.allocator);
    }

    /// Apply syntax highlighting with error highlighting
    pub fn highlightWithErrors(self: *SyntaxHighlighter, line: []const u8) ![]const u8 {
        const errors = try self.detectErrors(line);
        defer self.allocator.free(errors);

        if (errors.len == 0) {
            return self.highlight(line);
        }

        // Create error position set for quick lookup
        var error_positions = std.AutoHashMap(usize, void).init(self.allocator);
        defer error_positions.deinit();

        for (errors) |err| {
            for (err.position..err.position + err.length) |pos| {
                try error_positions.put(pos, {});
            }
        }

        // Highlight with error positions marked in red
        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(self.allocator);

        var pos: usize = 0;
        var in_string: bool = false;
        var string_char: u8 = 0;
        var in_comment: bool = false;
        var word_start: ?usize = null;
        var is_first_word: bool = true;
        var in_error: bool = false;

        while (pos < line.len) {
            const c = line[pos];
            const is_error_pos = error_positions.contains(pos);

            // Start error highlighting
            if (is_error_pos and !in_error) {
                try result.appendSlice(self.allocator, Color.UNDERLINE_RED);
                in_error = true;
            } else if (!is_error_pos and in_error) {
                try result.appendSlice(self.allocator, Color.RESET);
                in_error = false;
            }

            // Handle comments
            if (c == '#' and !in_string) {
                in_comment = true;
                if (!in_error) try result.appendSlice(self.allocator, Color.GRAY);
                try result.append(self.allocator, c);
                pos += 1;
                continue;
            }

            if (in_comment) {
                try result.append(self.allocator, c);
                pos += 1;
                continue;
            }

            // Handle strings
            if ((c == '"' or c == '\'') and !in_string) {
                in_string = true;
                string_char = c;
                if (!in_error) try result.appendSlice(self.allocator, Color.YELLOW);
                try result.append(self.allocator, c);
                pos += 1;
                continue;
            } else if (in_string and c == string_char) {
                try result.append(self.allocator, c);
                if (!in_error) try result.appendSlice(self.allocator, Color.RESET);
                in_string = false;
                pos += 1;
                continue;
            } else if (in_string) {
                try result.append(self.allocator, c);
                pos += 1;
                continue;
            }

            // Handle variables
            if (c == '$') {
                if (!in_error) try result.appendSlice(self.allocator, Color.MAGENTA);
                try result.append(self.allocator, c);
                pos += 1;

                // Read variable name
                if (pos < line.len and line[pos] == '{') {
                    try result.append(self.allocator, line[pos]);
                    pos += 1;
                    while (pos < line.len and line[pos] != '}') {
                        try result.append(self.allocator, line[pos]);
                        pos += 1;
                    }
                    if (pos < line.len) {
                        try result.append(self.allocator, line[pos]);
                        pos += 1;
                    }
                } else {
                    while (pos < line.len and (std.ascii.isAlphanumeric(line[pos]) or line[pos] == '_')) {
                        try result.append(self.allocator, line[pos]);
                        pos += 1;
                    }
                }
                if (!in_error) try result.appendSlice(self.allocator, Color.RESET);
                continue;
            }

            // Handle flags (- or --)
            if (c == '-' and word_start == null) {
                word_start = pos;
                if (!in_error) try result.appendSlice(self.allocator, Color.CYAN);
                try result.append(self.allocator, c);
                pos += 1;

                // Read the rest of the flag
                while (pos < line.len and !std.ascii.isWhitespace(line[pos])) {
                    try result.append(self.allocator, line[pos]);
                    pos += 1;
                }
                if (!in_error) try result.appendSlice(self.allocator, Color.RESET);
                word_start = null;
                continue;
            }

            // Handle word boundaries
            if (std.ascii.isWhitespace(c) or c == '|' or c == '&' or c == ';' or c == '(' or c == ')') {
                // End of word
                if (word_start) |start| {
                    const word = line[start..pos];
                    if (is_first_word and !in_error) {
                        if (self.isBuiltin(word)) {
                            try result.appendSlice(self.allocator, Color.BLUE);
                        } else if (self.isKeyword(word)) {
                            try result.appendSlice(self.allocator, Color.BLUE);
                        } else {
                            try result.appendSlice(self.allocator, Color.BOLD_GREEN);
                        }
                        try result.appendSlice(self.allocator, word);
                        try result.appendSlice(self.allocator, Color.RESET);
                        is_first_word = false;
                    } else {
                        try result.appendSlice(self.allocator, word);
                    }
                    word_start = null;
                }

                try result.append(self.allocator, c);
                if (c == '|' or c == '&' or c == ';') {
                    is_first_word = true;
                }
                pos += 1;
                continue;
            }

            // Start of a new word
            if (word_start == null) {
                word_start = pos;
            }

            pos += 1;
        }

        // Handle final word
        if (word_start) |start| {
            const word = line[start..];
            if (is_first_word and !in_error) {
                if (self.isBuiltin(word)) {
                    try result.appendSlice(self.allocator, Color.BLUE);
                } else if (self.isKeyword(word)) {
                    try result.appendSlice(self.allocator, Color.BLUE);
                } else {
                    try result.appendSlice(self.allocator, Color.BOLD_GREEN);
                }
                try result.appendSlice(self.allocator, word);
                try result.appendSlice(self.allocator, Color.RESET);
            } else {
                try result.appendSlice(self.allocator, word);
            }
        }

        // Add final reset
        if (in_comment or in_error) {
            try result.appendSlice(self.allocator, Color.RESET);
        }

        return result.toOwnedSlice(self.allocator);
    }

    /// Check if the line has syntax errors
    pub fn hasErrors(self: *SyntaxHighlighter, line: []const u8) !bool {
        const errors = try self.detectErrors(line);
        defer self.allocator.free(errors);
        return errors.len > 0;
    }
};

test "syntax highlighting - basic command" {
    const allocator = std.testing.allocator;
    var highlighter = SyntaxHighlighter.init(allocator);

    const input = "ls -la /home";
    const output = try highlighter.highlight(input);
    defer allocator.free(output);

    // Should have color codes
    try std.testing.expect(output.len > input.len);
}

test "syntax highlighting - builtin" {
    const allocator = std.testing.allocator;
    var highlighter = SyntaxHighlighter.init(allocator);

    const input = "echo hello";
    const output = try highlighter.highlight(input);
    defer allocator.free(output);

    // Should have color codes for builtin
    try std.testing.expect(output.len > input.len);
}

test "error detection - unmatched single quote" {
    const allocator = std.testing.allocator;
    var highlighter = SyntaxHighlighter.init(allocator);

    const errors = try highlighter.detectErrors("echo 'hello");
    defer allocator.free(errors);

    try std.testing.expectEqual(@as(usize, 1), errors.len);
    try std.testing.expectEqual(@as(usize, 5), errors[0].position);
    try std.testing.expectEqualStrings("unmatched single quote", errors[0].message);
}

test "error detection - unmatched double quote" {
    const allocator = std.testing.allocator;
    var highlighter = SyntaxHighlighter.init(allocator);

    const errors = try highlighter.detectErrors("echo \"hello");
    defer allocator.free(errors);

    try std.testing.expectEqual(@as(usize, 1), errors.len);
    try std.testing.expectEqual(@as(usize, 5), errors[0].position);
    try std.testing.expectEqualStrings("unmatched double quote", errors[0].message);
}

test "error detection - unmatched parenthesis" {
    const allocator = std.testing.allocator;
    var highlighter = SyntaxHighlighter.init(allocator);

    const errors = try highlighter.detectErrors("(echo hello");
    defer allocator.free(errors);

    try std.testing.expectEqual(@as(usize, 1), errors.len);
    try std.testing.expectEqual(@as(usize, 0), errors[0].position);
    try std.testing.expectEqualStrings("unmatched opening parenthesis", errors[0].message);
}

test "error detection - unmatched closing parenthesis" {
    const allocator = std.testing.allocator;
    var highlighter = SyntaxHighlighter.init(allocator);

    const errors = try highlighter.detectErrors("echo hello)");
    defer allocator.free(errors);

    try std.testing.expectEqual(@as(usize, 1), errors.len);
    try std.testing.expectEqual(@as(usize, 10), errors[0].position);
    try std.testing.expectEqualStrings("unmatched closing parenthesis", errors[0].message);
}

test "error detection - trailing pipe" {
    const allocator = std.testing.allocator;
    var highlighter = SyntaxHighlighter.init(allocator);

    const errors = try highlighter.detectErrors("echo hello |");
    defer allocator.free(errors);

    try std.testing.expectEqual(@as(usize, 1), errors.len);
    try std.testing.expectEqualStrings("incomplete command after operator", errors[0].message);
}

test "error detection - no errors" {
    const allocator = std.testing.allocator;
    var highlighter = SyntaxHighlighter.init(allocator);

    const errors = try highlighter.detectErrors("echo 'hello' | cat");
    defer allocator.free(errors);

    try std.testing.expectEqual(@as(usize, 0), errors.len);
}

test "hasErrors - returns true for errors" {
    const allocator = std.testing.allocator;
    var highlighter = SyntaxHighlighter.init(allocator);

    try std.testing.expect(try highlighter.hasErrors("echo 'hello"));
    try std.testing.expect(try highlighter.hasErrors("(echo hello"));
    try std.testing.expect(try highlighter.hasErrors("echo |"));
}

test "hasErrors - returns false for valid" {
    const allocator = std.testing.allocator;
    var highlighter = SyntaxHighlighter.init(allocator);

    try std.testing.expect(!try highlighter.hasErrors("echo hello"));
    try std.testing.expect(!try highlighter.hasErrors("echo 'hello world'"));
    try std.testing.expect(!try highlighter.hasErrors("(echo hello)"));
}

test "highlightWithErrors - error positions get red" {
    const allocator = std.testing.allocator;
    var highlighter = SyntaxHighlighter.init(allocator);

    const output = try highlighter.highlightWithErrors("echo 'hello");
    defer allocator.free(output);

    // Should contain the underline red escape code
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[4;31m") != null);
}
