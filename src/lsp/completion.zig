const std = @import("std");

/// LSP Position (0-based line and character)
pub const Position = struct {
    line: u32,
    character: u32,
};

/// LSP CompletionItemKind
pub const CompletionItemKind = enum(u8) {
    text = 1,
    method = 2,
    function = 3,
    constructor = 4,
    field = 5,
    variable = 6,
    class = 7,
    interface = 8,
    module = 9,
    property = 10,
    unit = 11,
    value = 12,
    enum_member = 13,
    keyword = 14,
    snippet = 15,
    color = 16,
    file = 17,
    reference = 18,
    folder = 19,
    operator = 24,

    pub fn toInt(self: CompletionItemKind) u8 {
        return @backingInt(self);
    }
};

/// A single completion suggestion returned by the LSP
pub const CompletionItem = struct {
    label: []const u8,
    kind: CompletionItemKind,
    detail: []const u8,
    insert_text: []const u8,
    /// Whether the strings above are heap-allocated and need freeing
    owned: bool = false,
};

// ---------------------------------------------------------------------------
// Built-in command table
// ---------------------------------------------------------------------------

const CommandInfo = struct {
    label: []const u8,
    detail: []const u8,
    insert_text: []const u8,
};

const builtin_commands = [_]CommandInfo{
    .{ .label = "echo", .detail = "Print arguments to stdout", .insert_text = "echo " },
    .{ .label = "cd", .detail = "Change current directory", .insert_text = "cd " },
    .{ .label = "ls", .detail = "List directory contents", .insert_text = "ls " },
    .{ .label = "grep", .detail = "Search text with patterns", .insert_text = "grep " },
    .{ .label = "seq", .detail = "Generate numeric sequences", .insert_text = "seq " },
    .{ .label = "watch", .detail = "Execute a command periodically", .insert_text = "watch " },
    .{ .label = "http", .detail = "HTTP client for making requests", .insert_text = "http " },
    .{ .label = "str", .detail = "String manipulation commands", .insert_text = "str " },
    .{ .label = "path", .detail = "Path manipulation commands", .insert_text = "path " },
    .{ .label = "math", .detail = "Mathematical operations", .insert_text = "math " },
    .{ .label = "date", .detail = "Date and time operations", .insert_text = "date " },
    .{ .label = "pwd", .detail = "Print working directory", .insert_text = "pwd" },
    .{ .label = "exit", .detail = "Exit the shell", .insert_text = "exit " },
    .{ .label = "export", .detail = "Set environment variable", .insert_text = "export " },
    .{ .label = "source", .detail = "Execute commands from a file", .insert_text = "source " },
    .{ .label = "alias", .detail = "Define or display aliases", .insert_text = "alias " },
    .{ .label = "unalias", .detail = "Remove an alias", .insert_text = "unalias " },
    .{ .label = "type", .detail = "Display information about a command", .insert_text = "type " },
    .{ .label = "which", .detail = "Locate a command", .insert_text = "which " },
    .{ .label = "test", .detail = "Evaluate conditional expression", .insert_text = "test " },
    .{ .label = "true", .detail = "Return success exit code", .insert_text = "true" },
    .{ .label = "false", .detail = "Return failure exit code", .insert_text = "false" },
    .{ .label = "read", .detail = "Read a line from stdin", .insert_text = "read " },
    .{ .label = "printf", .detail = "Format and print data", .insert_text = "printf " },
    .{ .label = "set", .detail = "Set shell options", .insert_text = "set " },
    .{ .label = "unset", .detail = "Unset variables or functions", .insert_text = "unset " },
    .{ .label = "jobs", .detail = "List background jobs", .insert_text = "jobs" },
    .{ .label = "fg", .detail = "Move job to foreground", .insert_text = "fg " },
    .{ .label = "bg", .detail = "Move job to background", .insert_text = "bg " },
    .{ .label = "kill", .detail = "Send signal to a process", .insert_text = "kill " },
    .{ .label = "wait", .detail = "Wait for background processes", .insert_text = "wait " },
    .{ .label = "history", .detail = "Display command history", .insert_text = "history" },
    .{ .label = "help", .detail = "Display help information", .insert_text = "help " },
};

// ---------------------------------------------------------------------------
// Variable table
// ---------------------------------------------------------------------------

const VariableInfo = struct {
    label: []const u8,
    detail: []const u8,
    insert_text: []const u8,
};

const builtin_variables = [_]VariableInfo{
    .{ .label = "$HOME", .detail = "Home directory of the current user", .insert_text = "$HOME" },
    .{ .label = "$PATH", .detail = "Executable search path", .insert_text = "$PATH" },
    .{ .label = "$PWD", .detail = "Present working directory", .insert_text = "$PWD" },
    .{ .label = "$USER", .detail = "Current user name", .insert_text = "$USER" },
    .{ .label = "$SHELL", .detail = "Path to the current shell", .insert_text = "$SHELL" },
    .{ .label = "$OLDPWD", .detail = "Previous working directory", .insert_text = "$OLDPWD" },
    .{ .label = "$TERM", .detail = "Terminal type", .insert_text = "$TERM" },
    .{ .label = "$LANG", .detail = "Current locale", .insert_text = "$LANG" },
    .{ .label = "$EDITOR", .detail = "Default text editor", .insert_text = "$EDITOR" },
    .{ .label = "$?", .detail = "Exit status of the last command", .insert_text = "$?" },
    .{ .label = "$!", .detail = "PID of the last background process", .insert_text = "$!" },
    .{ .label = "$$", .detail = "PID of the current shell", .insert_text = "$$" },
    .{ .label = "$#", .detail = "Number of positional parameters", .insert_text = "$#" },
    .{ .label = "$@", .detail = "All positional parameters (separate words)", .insert_text = "$@" },
    .{ .label = "$*", .detail = "All positional parameters (single word)", .insert_text = "$*" },
    .{ .label = "$0", .detail = "Name of the shell or script", .insert_text = "$0" },
    .{ .label = "$DEN_VERSION", .detail = "Den shell version", .insert_text = "$DEN_VERSION" },
};

// ---------------------------------------------------------------------------
// Keyword table
// ---------------------------------------------------------------------------

const KeywordInfo = struct {
    label: []const u8,
    detail: []const u8,
    insert_text: []const u8,
};

const keywords = [_]KeywordInfo{
    .{ .label = "if", .detail = "Conditional branch", .insert_text = "if " },
    .{ .label = "else", .detail = "Alternative branch of if", .insert_text = "else" },
    .{ .label = "elif", .detail = "Else-if branch", .insert_text = "elif " },
    .{ .label = "fi", .detail = "End if block", .insert_text = "fi" },
    .{ .label = "for", .detail = "Iterate over a list", .insert_text = "for " },
    .{ .label = "while", .detail = "Loop while condition is true", .insert_text = "while " },
    .{ .label = "do", .detail = "Begin loop body", .insert_text = "do" },
    .{ .label = "done", .detail = "End loop body", .insert_text = "done" },
    .{ .label = "match", .detail = "Pattern matching expression", .insert_text = "match " },
    .{ .label = "try", .detail = "Begin error-handling block", .insert_text = "try " },
    .{ .label = "catch", .detail = "Handle errors from try block", .insert_text = "catch " },
    .{ .label = "let", .detail = "Declare an immutable variable", .insert_text = "let " },
    .{ .label = "mut", .detail = "Declare a mutable variable", .insert_text = "mut " },
    .{ .label = "module", .detail = "Define a module", .insert_text = "module " },
    .{ .label = "use", .detail = "Import a module", .insert_text = "use " },
    .{ .label = "def", .detail = "Define a function", .insert_text = "def " },
    .{ .label = "return", .detail = "Return from a function", .insert_text = "return " },
    .{ .label = "break", .detail = "Break out of a loop", .insert_text = "break" },
    .{ .label = "continue", .detail = "Skip to next loop iteration", .insert_text = "continue" },
    .{ .label = "in", .detail = "Used with for loops", .insert_text = "in " },
    .{ .label = "then", .detail = "Begin if/elif body", .insert_text = "then" },
    .{ .label = "case", .detail = "Case statement", .insert_text = "case " },
    .{ .label = "esac", .detail = "End case statement", .insert_text = "esac" },
};

// ---------------------------------------------------------------------------
// Subcommand tables
// ---------------------------------------------------------------------------

const SubcommandInfo = struct {
    parent: []const u8,
    label: []const u8,
    detail: []const u8,
    insert_text: []const u8,
};

const subcommands = [_]SubcommandInfo{
    // str subcommands
    .{ .parent = "str", .label = "trim", .detail = "Remove leading/trailing whitespace", .insert_text = "trim " },
    .{ .parent = "str", .label = "replace", .detail = "Replace occurrences of a pattern", .insert_text = "replace " },
    .{ .parent = "str", .label = "split", .detail = "Split string by delimiter", .insert_text = "split " },
    .{ .parent = "str", .label = "join", .detail = "Join strings with delimiter", .insert_text = "join " },
    .{ .parent = "str", .label = "length", .detail = "Get string length", .insert_text = "length " },
    .{ .parent = "str", .label = "upper", .detail = "Convert to uppercase", .insert_text = "upper " },
    .{ .parent = "str", .label = "lower", .detail = "Convert to lowercase", .insert_text = "lower " },
    .{ .parent = "str", .label = "contains", .detail = "Check if string contains substring", .insert_text = "contains " },
    .{ .parent = "str", .label = "starts-with", .detail = "Check if string starts with prefix", .insert_text = "starts-with " },
    .{ .parent = "str", .label = "ends-with", .detail = "Check if string ends with suffix", .insert_text = "ends-with " },
    .{ .parent = "str", .label = "substring", .detail = "Extract a substring", .insert_text = "substring " },
    .{ .parent = "str", .label = "reverse", .detail = "Reverse a string", .insert_text = "reverse " },
    .{ .parent = "str", .label = "repeat", .detail = "Repeat a string N times", .insert_text = "repeat " },
    // path subcommands
    .{ .parent = "path", .label = "join", .detail = "Join path components", .insert_text = "join " },
    .{ .parent = "path", .label = "dirname", .detail = "Get directory portion of path", .insert_text = "dirname " },
    .{ .parent = "path", .label = "basename", .detail = "Get filename portion of path", .insert_text = "basename " },
    .{ .parent = "path", .label = "extension", .detail = "Get file extension", .insert_text = "extension " },
    .{ .parent = "path", .label = "stem", .detail = "Get filename without extension", .insert_text = "stem " },
    .{ .parent = "path", .label = "exists", .detail = "Check if path exists", .insert_text = "exists " },
    .{ .parent = "path", .label = "is-dir", .detail = "Check if path is a directory", .insert_text = "is-dir " },
    .{ .parent = "path", .label = "is-file", .detail = "Check if path is a file", .insert_text = "is-file " },
    .{ .parent = "path", .label = "resolve", .detail = "Resolve to absolute path", .insert_text = "resolve " },
    .{ .parent = "path", .label = "normalize", .detail = "Normalize path separators", .insert_text = "normalize " },
    // math subcommands
    .{ .parent = "math", .label = "sum", .detail = "Sum a list of numbers", .insert_text = "sum " },
    .{ .parent = "math", .label = "avg", .detail = "Average of a list of numbers", .insert_text = "avg " },
    .{ .parent = "math", .label = "min", .detail = "Minimum of a list of numbers", .insert_text = "min " },
    .{ .parent = "math", .label = "max", .detail = "Maximum of a list of numbers", .insert_text = "max " },
    .{ .parent = "math", .label = "abs", .detail = "Absolute value", .insert_text = "abs " },
    .{ .parent = "math", .label = "ceil", .detail = "Ceiling (round up)", .insert_text = "ceil " },
    .{ .parent = "math", .label = "floor", .detail = "Floor (round down)", .insert_text = "floor " },
    .{ .parent = "math", .label = "round", .detail = "Round to nearest integer", .insert_text = "round " },
    .{ .parent = "math", .label = "sqrt", .detail = "Square root", .insert_text = "sqrt " },
    .{ .parent = "math", .label = "pow", .detail = "Exponentiation", .insert_text = "pow " },
    // date subcommands
    .{ .parent = "date", .label = "now", .detail = "Current date and time", .insert_text = "now" },
    .{ .parent = "date", .label = "format", .detail = "Format a date", .insert_text = "format " },
    .{ .parent = "date", .label = "parse", .detail = "Parse a date string", .insert_text = "parse " },
    .{ .parent = "date", .label = "add", .detail = "Add duration to a date", .insert_text = "add " },
    .{ .parent = "date", .label = "sub", .detail = "Subtract duration from a date", .insert_text = "sub " },
    .{ .parent = "date", .label = "diff", .detail = "Difference between two dates", .insert_text = "diff " },
    // http subcommands
    .{ .parent = "http", .label = "get", .detail = "HTTP GET request", .insert_text = "get " },
    .{ .parent = "http", .label = "post", .detail = "HTTP POST request", .insert_text = "post " },
    .{ .parent = "http", .label = "put", .detail = "HTTP PUT request", .insert_text = "put " },
    .{ .parent = "http", .label = "delete", .detail = "HTTP DELETE request", .insert_text = "delete " },
    .{ .parent = "http", .label = "head", .detail = "HTTP HEAD request", .insert_text = "head " },
    .{ .parent = "http", .label = "patch", .detail = "HTTP PATCH request", .insert_text = "patch " },
};

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Retrieve completion items for the given document position.
///
/// The caller owns the returned slice and must free it with `allocator`.
/// The individual `CompletionItem` values reference compile-time strings
/// except when `owned` is true, in which case the caller must free the
/// corresponding heap-allocated fields.
pub fn getCompletions(
    document_text: []const u8,
    position: Position,
    allocator: std.mem.Allocator,
) ![]CompletionItem {
    // Extract the current line from the document
    const line_text = getLineAt(document_text, position.line);

    // Get the text up to the cursor position on this line
    const cursor_col: usize = @min(position.character, @as(u32, @intCast(line_text.len)));
    const text_before_cursor = line_text[0..cursor_col];

    // Determine what kind of completion to provide based on context
    const ctx = analyzeContext(text_before_cursor);

    var results: std.ArrayList(CompletionItem) = .empty;
    errdefer results.deinit(allocator);

    switch (ctx) {
        .variable => {
            // User is typing a $-prefixed variable
            const prefix = ctx.variable;
            for (&builtin_variables) |*v| {
                if (prefix.len == 0 or std.mem.startsWith(u8, v.label, prefix)) {
                    try results.append(allocator, .{
                        .label = v.label,
                        .kind = .variable,
                        .detail = v.detail,
                        .insert_text = v.insert_text,
                    });
                }
            }
        },
        .subcommand => {
            const parent = ctx.subcommand;
            for (&subcommands) |*sc| {
                if (std.mem.eql(u8, sc.parent, parent)) {
                    try results.append(allocator, .{
                        .label = sc.label,
                        .kind = .function,
                        .detail = sc.detail,
                        .insert_text = sc.insert_text,
                    });
                }
            }
        },
        .command => {
            const prefix = ctx.command;
            // Commands
            for (&builtin_commands) |*cmd| {
                if (prefix.len == 0 or std.mem.startsWith(u8, cmd.label, prefix)) {
                    try results.append(allocator, .{
                        .label = cmd.label,
                        .kind = .function,
                        .detail = cmd.detail,
                        .insert_text = cmd.insert_text,
                    });
                }
            }
            // Keywords
            for (&keywords) |*kw| {
                if (prefix.len == 0 or std.mem.startsWith(u8, kw.label, prefix)) {
                    try results.append(allocator, .{
                        .label = kw.label,
                        .kind = .keyword,
                        .detail = kw.detail,
                        .insert_text = kw.insert_text,
                    });
                }
            }
        },
    }

    return try results.toOwnedSlice(allocator);
}

/// Free a completion list previously returned by `getCompletions`.
pub fn freeCompletions(items: []CompletionItem, allocator: std.mem.Allocator) void {
    for (items) |item| {
        if (item.owned) {
            allocator.free(item.label);
            allocator.free(item.detail);
            allocator.free(item.insert_text);
        }
    }
    allocator.free(items);
}

// ---------------------------------------------------------------------------
// Context analysis
// ---------------------------------------------------------------------------

const CompletionContext = union(enum) {
    /// User is typing a command (or keyword) at the beginning of a line / after a pipe
    command: []const u8,
    /// User is typing a $-variable
    variable: []const u8,
    /// User is typing a subcommand (e.g. after "str ")
    subcommand: []const u8,
};

fn analyzeContext(text_before_cursor: []const u8) CompletionContext {
    // Trim leading whitespace
    const trimmed = std.mem.trimStart(u8, text_before_cursor, " \t");

    // Check if the cursor is right after a $ sign (variable completion)
    if (findLastVariable(text_before_cursor)) |var_start| {
        return .{ .variable = text_before_cursor[var_start..] };
    }

    // Check if we are in a subcommand position: "parent_cmd <cursor>"
    // Look for a known parent command followed by a space
    const parents = [_][]const u8{ "str", "path", "math", "date", "http" };
    for (&parents) |parent| {
        if (trimmed.len > parent.len and
            std.mem.eql(u8, trimmed[0..parent.len], parent) and
            trimmed[parent.len] == ' ')
        {
            return .{ .subcommand = parent };
        }
    }

    // After a pipe we start a new command context
    if (std.mem.lastIndexOfScalar(u8, text_before_cursor, '|')) |pipe_pos| {
        const after_pipe = std.mem.trimStart(u8, text_before_cursor[pipe_pos + 1 ..], " \t");
        return .{ .command = after_pipe };
    }

    // Default: command/keyword completion for the current word
    return .{ .command = getCurrentWord(trimmed) };
}

/// Walk backwards from the end to find a $ that starts a variable reference.
fn findLastVariable(text: []const u8) ?usize {
    if (text.len == 0) return null;
    var i: usize = text.len;
    while (i > 0) {
        i -= 1;
        const c = text[i];
        if (c == '$') return i;
        // If we hit whitespace or a non-variable character, stop searching
        if (c == ' ' or c == '\t' or c == ';' or c == '|' or c == '(' or c == ')') return null;
    }
    return null;
}

/// Extract the current (possibly partial) word at the end of the text.
fn getCurrentWord(text: []const u8) []const u8 {
    if (text.len == 0) return text;
    var i: usize = text.len;
    while (i > 0) {
        i -= 1;
        const c = text[i];
        if (c == ' ' or c == '\t' or c == ';' or c == '|' or c == '\n') {
            return text[i + 1 ..];
        }
    }
    return text;
}

/// Get the contents of a specific line (0-based) from document text.
fn getLineAt(text: []const u8, line: u32) []const u8 {
    var current_line: u32 = 0;
    var start: usize = 0;
    for (text, 0..) |c, idx| {
        if (c == '\n') {
            if (current_line == line) {
                return text[start..idx];
            }
            current_line += 1;
            start = idx + 1;
        }
    }
    // Last line (no trailing newline)
    if (current_line == line) {
        return text[start..];
    }
    return "";
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "getLineAt returns correct line" {
    const doc = "first\nsecond\nthird";
    try std.testing.expectEqualStrings("first", getLineAt(doc, 0));
    try std.testing.expectEqualStrings("second", getLineAt(doc, 1));
    try std.testing.expectEqualStrings("third", getLineAt(doc, 2));
    try std.testing.expectEqualStrings("", getLineAt(doc, 99));
}

test "getCurrentWord extracts trailing word" {
    try std.testing.expectEqualStrings("ec", getCurrentWord("ec"));
    try std.testing.expectEqualStrings("ls", getCurrentWord("echo foo | ls"));
    try std.testing.expectEqualStrings("", getCurrentWord("echo "));
}

test "analyzeContext detects variable" {
    const ctx = analyzeContext("echo $HO");
    switch (ctx) {
        .variable => |v| try std.testing.expectEqualStrings("$HO", v),
        else => return error.UnexpectedContext,
    }
}

test "analyzeContext detects subcommand" {
    const ctx = analyzeContext("str ");
    switch (ctx) {
        .subcommand => |p| try std.testing.expectEqualStrings("str", p),
        else => return error.UnexpectedContext,
    }
}

test "analyzeContext detects command" {
    const ctx = analyzeContext("ech");
    switch (ctx) {
        .command => |c| try std.testing.expectEqualStrings("ech", c),
        else => return error.UnexpectedContext,
    }
}
