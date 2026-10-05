const std = @import("std");

/// LSP Position (0-based line and character)
pub const Position = struct {
    line: u32,
    character: u32,
};

/// LSP Range
pub const Range = struct {
    start: Position,
    end: Position,
};

/// Diagnostic severity levels defined by the LSP specification
pub const DiagnosticSeverity = enum(u8) {
    @"error" = 1,
    warning = 2,
    information = 3,
    hint = 4,

    pub fn toInt(self: DiagnosticSeverity) u8 {
        return @backingInt(self);
    }
};

/// A single diagnostic message (error, warning, etc.)
pub const Diagnostic = struct {
    range: Range,
    severity: DiagnosticSeverity,
    message: []const u8,
    source: []const u8,
    /// True when `message` was allocated on the heap and must be freed
    owned: bool = false,
};

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Analyse `document_text` and return an array of diagnostics.
///
/// The caller owns the returned slice.  For each `Diagnostic` whose `owned`
/// field is `true`, the caller must also free `message` through `allocator`.
pub fn getDiagnostics(
    document_text: []const u8,
    allocator: std.mem.Allocator,
) ![]Diagnostic {
    var results: std.ArrayList(Diagnostic) = .empty;
    errdefer {
        for (results.items) |d| {
            if (d.owned) allocator.free(d.message);
        }
        results.deinit(allocator);
    }

    try checkUnmatchedQuotes(document_text, allocator, &results);
    try checkUnmatchedBrackets(document_text, allocator, &results);
    try checkUnclosedBlocks(document_text, allocator, &results);
    try checkUnknownEscapes(document_text, allocator, &results);

    return try results.toOwnedSlice(allocator);
}

/// Free a diagnostics list previously returned by `getDiagnostics`.
pub fn freeDiagnostics(items: []Diagnostic, allocator: std.mem.Allocator) void {
    for (items) |d| {
        if (d.owned) allocator.free(d.message);
    }
    allocator.free(items);
}

// ---------------------------------------------------------------------------
// Unmatched quotes
// ---------------------------------------------------------------------------

fn checkUnmatchedQuotes(
    text: []const u8,
    allocator: std.mem.Allocator,
    results: *std.ArrayList(Diagnostic),
) !void {
    var line: u32 = 0;
    var col: u32 = 0;
    var in_single_quote = false;
    var in_double_quote = false;
    var single_quote_start = Position{ .line = 0, .character = 0 };
    var double_quote_start = Position{ .line = 0, .character = 0 };
    var i: usize = 0;

    while (i < text.len) : (i += 1) {
        const c = text[i];

        if (c == '\n') {
            line += 1;
            col = 0;
            continue;
        }

        // Skip escaped characters inside double-quoted strings
        if (c == '\\' and in_double_quote and i + 1 < text.len) {
            i += 1;
            col += 2;
            continue;
        }

        if (c == '\'' and !in_double_quote) {
            if (in_single_quote) {
                in_single_quote = false;
            } else {
                in_single_quote = true;
                single_quote_start = .{ .line = line, .character = col };
            }
        } else if (c == '"' and !in_single_quote) {
            if (in_double_quote) {
                in_double_quote = false;
            } else {
                in_double_quote = true;
                double_quote_start = .{ .line = line, .character = col };
            }
        }

        col += 1;
    }

    if (in_single_quote) {
        try results.append(allocator, .{
            .range = .{
                .start = single_quote_start,
                .end = .{ .line = line, .character = col },
            },
            .severity = .@"error",
            .message = "Unmatched single quote",
            .source = "den",
        });
    }

    if (in_double_quote) {
        try results.append(allocator, .{
            .range = .{
                .start = double_quote_start,
                .end = .{ .line = line, .character = col },
            },
            .severity = .@"error",
            .message = "Unmatched double quote",
            .source = "den",
        });
    }
}

// ---------------------------------------------------------------------------
// Unmatched brackets / braces / parens
// ---------------------------------------------------------------------------

const BracketKind = enum { paren, bracket, brace };
const BracketEntry = struct {
    kind: BracketKind,
    pos: Position,
};

fn checkUnmatchedBrackets(
    text: []const u8,
    allocator: std.mem.Allocator,
    results: *std.ArrayList(Diagnostic),
) !void {
    var stack: std.ArrayList(BracketEntry) = .empty;
    defer stack.deinit(allocator);

    var line: u32 = 0;
    var col: u32 = 0;
    var in_single_quote = false;
    var in_double_quote = false;

    for (text) |c| {
        if (c == '\n') {
            line += 1;
            col = 0;
            continue;
        }

        // Track quote state to avoid false positives inside strings
        if (c == '\'' and !in_double_quote) {
            in_single_quote = !in_single_quote;
            col += 1;
            continue;
        }
        if (c == '"' and !in_single_quote) {
            in_double_quote = !in_double_quote;
            col += 1;
            continue;
        }

        if (!in_single_quote and !in_double_quote) {
            const pos = Position{ .line = line, .character = col };
            switch (c) {
                '(' => try stack.append(allocator, .{ .kind = .paren, .pos = pos }),
                '[' => try stack.append(allocator, .{ .kind = .bracket, .pos = pos }),
                '{' => try stack.append(allocator, .{ .kind = .brace, .pos = pos }),
                ')' => {
                    if (popMatching(&stack, .paren) == null) {
                        try results.append(allocator, .{
                            .range = .{ .start = pos, .end = .{ .line = line, .character = col + 1 } },
                            .severity = .@"error",
                            .message = "Unmatched closing parenthesis ')'",
                            .source = "den",
                        });
                    }
                },
                ']' => {
                    if (popMatching(&stack, .bracket) == null) {
                        try results.append(allocator, .{
                            .range = .{ .start = pos, .end = .{ .line = line, .character = col + 1 } },
                            .severity = .@"error",
                            .message = "Unmatched closing bracket ']'",
                            .source = "den",
                        });
                    }
                },
                '}' => {
                    if (popMatching(&stack, .brace) == null) {
                        try results.append(allocator, .{
                            .range = .{ .start = pos, .end = .{ .line = line, .character = col + 1 } },
                            .severity = .@"error",
                            .message = "Unmatched closing brace '}'",
                            .source = "den",
                        });
                    }
                },
                else => {},
            }
        }

        col += 1;
    }

    // Any remaining openers on the stack are unmatched
    for (stack.items) |entry| {
        const label: []const u8 = switch (entry.kind) {
            .paren => "Unmatched opening parenthesis '('",
            .bracket => "Unmatched opening bracket '['",
            .brace => "Unmatched opening brace '{'",
        };
        try results.append(allocator, .{
            .range = .{
                .start = entry.pos,
                .end = .{ .line = entry.pos.line, .character = entry.pos.character + 1 },
            },
            .severity = .@"error",
            .message = label,
            .source = "den",
        });
    }
}

fn popMatching(stack: *std.ArrayList(BracketEntry), kind: BracketKind) ?BracketEntry {
    if (stack.items.len == 0) return null;
    const top = stack.items[stack.items.len - 1];
    if (top.kind == kind) {
        _ = stack.pop();
        return top;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Unclosed control-flow blocks (if/for/while without fi/done)
// ---------------------------------------------------------------------------

fn checkUnclosedBlocks(
    text: []const u8,
    allocator: std.mem.Allocator,
    results: *std.ArrayList(Diagnostic),
) !void {
    const BlockKind = enum { if_block, for_block, while_block, case_block };
    const BlockEntry = struct {
        kind: BlockKind,
        pos: Position,
    };

    var stack: std.ArrayList(BlockEntry) = .empty;
    defer stack.deinit(allocator);

    var line: u32 = 0;
    var line_start: usize = 0;

    // Iterate line by line
    var i: usize = 0;
    while (i <= text.len) : (i += 1) {
        const at_end = i == text.len;
        const is_newline = !at_end and text[i] == '\n';

        if (is_newline or at_end) {
            const line_text = text[line_start..i];
            const trimmed = std.mem.trimStart(u8, line_text, " \t");
            const first_word = firstWord(trimmed);
            const col: u32 = @intCast(pointerDiff(trimmed, line_text));

            if (std.mem.eql(u8, first_word, "if")) {
                // Only count as block opener if not a single-line `if ... fi`
                if (!lineContains(trimmed, "fi")) {
                    try stack.append(allocator, .{ .kind = .if_block, .pos = .{ .line = line, .character = col } });
                }
            } else if (std.mem.eql(u8, first_word, "for")) {
                if (!lineContains(trimmed, "done")) {
                    try stack.append(allocator, .{ .kind = .for_block, .pos = .{ .line = line, .character = col } });
                }
            } else if (std.mem.eql(u8, first_word, "while")) {
                if (!lineContains(trimmed, "done")) {
                    try stack.append(allocator, .{ .kind = .while_block, .pos = .{ .line = line, .character = col } });
                }
            } else if (std.mem.eql(u8, first_word, "case")) {
                if (!lineContains(trimmed, "esac")) {
                    try stack.append(allocator, .{ .kind = .case_block, .pos = .{ .line = line, .character = col } });
                }
            } else if (std.mem.eql(u8, first_word, "fi")) {
                _ = popBlockMatching(&stack, .if_block);
            } else if (std.mem.eql(u8, first_word, "done")) {
                // `done` closes the most recent for or while
                if (popBlockMatching(&stack, .while_block) == null) {
                    _ = popBlockMatching(&stack, .for_block);
                }
            } else if (std.mem.eql(u8, first_word, "esac")) {
                _ = popBlockMatching(&stack, .case_block);
            }

            line += 1;
            line_start = i + 1;
        }
    }

    // Anything remaining is an unclosed block
    for (stack.items) |entry| {
        const msg: []const u8 = switch (entry.kind) {
            .if_block => "Unclosed 'if' block (missing 'fi')",
            .for_block => "Unclosed 'for' loop (missing 'done')",
            .while_block => "Unclosed 'while' loop (missing 'done')",
            .case_block => "Unclosed 'case' statement (missing 'esac')",
        };
        try results.append(allocator, .{
            .range = .{
                .start = entry.pos,
                .end = .{ .line = entry.pos.line, .character = entry.pos.character + 2 },
            },
            .severity = .@"error",
            .message = msg,
            .source = "den",
        });
    }
}

fn popBlockMatching(stack: anytype, kind: anytype) ?@TypeOf(stack.items[0]) {
    if (stack.items.len == 0) return null;
    // Search from top for the matching kind
    var idx: usize = stack.items.len;
    while (idx > 0) {
        idx -= 1;
        if (stack.items[idx].kind == kind) {
            // Remove this entry (shift remaining)
            const entry = stack.items[idx];
            std.mem.copyForwards(
                @TypeOf(stack.items[0]),
                stack.items[idx..],
                stack.items[idx + 1 ..],
            );
            stack.items.len -= 1;
            return entry;
        }
    }
    return null;
}

fn firstWord(text: []const u8) []const u8 {
    const trimmed = std.mem.trimStart(u8, text, " \t");
    for (trimmed, 0..) |c, idx| {
        if (c == ' ' or c == '\t' or c == ';' or c == '\n' or c == '(' or c == '{') {
            return trimmed[0..idx];
        }
    }
    return trimmed;
}

fn lineContains(line: []const u8, keyword: []const u8) bool {
    return std.mem.indexOf(u8, line, keyword) != null;
}

fn pointerDiff(inner: []const u8, outer: []const u8) usize {
    return @intFromPtr(inner.ptr) -| @intFromPtr(outer.ptr);
}

// ---------------------------------------------------------------------------
// Unknown escape sequences inside double-quoted strings
// ---------------------------------------------------------------------------

fn checkUnknownEscapes(
    text: []const u8,
    allocator: std.mem.Allocator,
    results: *std.ArrayList(Diagnostic),
) !void {
    const valid_escapes = "\\\"$`abfnrtv0!";

    var line: u32 = 0;
    var col: u32 = 0;
    var in_double_quote = false;
    var in_single_quote = false;
    var i: usize = 0;

    while (i < text.len) {
        const c = text[i];

        if (c == '\n') {
            line += 1;
            col = 0;
            i += 1;
            continue;
        }

        if (c == '\'' and !in_double_quote) {
            in_single_quote = !in_single_quote;
            col += 1;
            i += 1;
            continue;
        }

        if (c == '"' and !in_single_quote) {
            in_double_quote = !in_double_quote;
            col += 1;
            i += 1;
            continue;
        }

        if (c == '\\' and in_double_quote and i + 1 < text.len) {
            const next = text[i + 1];
            if (next != '\n' and std.mem.indexOfScalar(u8, valid_escapes, next) == null) {
                const msg = try std.fmt.allocPrint(allocator, "Unknown escape sequence '\\{c}'", .{next});
                try results.append(allocator, .{
                    .range = .{
                        .start = .{ .line = line, .character = col },
                        .end = .{ .line = line, .character = col + 2 },
                    },
                    .severity = .warning,
                    .message = msg,
                    .source = "den",
                    .owned = true,
                });
            }
            i += 2;
            col += 2;
            continue;
        }

        col += 1;
        i += 1;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "detect unmatched single quote" {
    const diags = try getDiagnostics("echo 'hello", std.testing.allocator);
    defer freeDiagnostics(diags, std.testing.allocator);
    try std.testing.expect(diags.len >= 1);
    try std.testing.expectEqualStrings("Unmatched single quote", diags[0].message);
}

test "detect unmatched double quote" {
    const diags = try getDiagnostics("echo \"hello", std.testing.allocator);
    defer freeDiagnostics(diags, std.testing.allocator);
    try std.testing.expect(diags.len >= 1);
    try std.testing.expectEqualStrings("Unmatched double quote", diags[0].message);
}

test "detect unmatched paren" {
    const diags = try getDiagnostics("echo (hello", std.testing.allocator);
    defer freeDiagnostics(diags, std.testing.allocator);
    try std.testing.expect(diags.len >= 1);
    try std.testing.expectEqualStrings("Unmatched opening parenthesis '('", diags[0].message);
}

test "detect unclosed if block" {
    const diags = try getDiagnostics("if true\nthen\n  echo hello\n", std.testing.allocator);
    defer freeDiagnostics(diags, std.testing.allocator);
    try std.testing.expect(diags.len >= 1);
    var found = false;
    for (diags) |d| {
        if (std.mem.eql(u8, d.message, "Unclosed 'if' block (missing 'fi')")) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "no diagnostics for well-formed input" {
    const diags = try getDiagnostics("echo 'hello' \"world\"", std.testing.allocator);
    defer freeDiagnostics(diags, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), diags.len);
}

test "detect unknown escape sequence" {
    const diags = try getDiagnostics("echo \"hello \\q world\"", std.testing.allocator);
    defer freeDiagnostics(diags, std.testing.allocator);
    try std.testing.expect(diags.len >= 1);
    try std.testing.expect(std.mem.startsWith(u8, diags[0].message, "Unknown escape sequence"));
}
