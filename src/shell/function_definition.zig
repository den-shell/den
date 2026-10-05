//! Function Definition Module
//! Handles multiline function definition parsing and registration

const std = @import("std");
const IO = @import("../utils/io.zig").IO;
const Shell = @import("../shell.zig").Shell;
const FunctionParser = @import("../scripting/functions.zig").FunctionParser;
const functions = @import("../scripting/functions.zig");

/// Everything a function name is allowed to be made of.
fn isValidFunctionName(name: []const u8) bool {
    if (name.len == 0) return false;

    for (name) |c| {
        if (c == '_' or c == '-' or std.ascii.isAlphanumeric(c)) continue;
        return false;
    }

    return true;
}

/// Does this line *begin* a function definition, as opposed to merely
/// containing `()` somewhere in it?
///
/// The old test was "there is a `()` with something in front of it", which is
/// also true of `eval "hi() { echo hi; }"` - so that line was read as defining
/// a function called `eval "hi`, and never reached eval at all. It is true of
/// any command carrying a function definition in an *argument*, which is
/// precisely how a shell integration is loaded (`eval "$(tool init)"`).
///
/// A definition names its function first, so everything before the parens has
/// to be one valid name and nothing besides.
pub fn isFunctionDefinitionStart(trimmed: []const u8) bool {
    if (std.mem.startsWith(u8, trimmed, "function ")) {
        const after = std.mem.trim(u8, trimmed["function ".len..], &std.ascii.whitespace);
        // `function name { ... }` is legal with no parens at all.
        const name_end = std.mem.indexOfAny(u8, after, " \t{(") orelse after.len;
        return isValidFunctionName(after[0..name_end]);
    }

    const paren = std.mem.indexOf(u8, trimmed, "()") orelse return false;

    return isValidFunctionName(std.mem.trim(u8, trimmed[0..paren], &std.ascii.whitespace));
}

/// Check if input starts a function definition
pub fn checkFunctionDefinitionStart(self: *Shell, trimmed: []const u8) !bool {
    // Check for "def name [params] -> type { ... }" syntax (Phase 5.2)
    if (std.mem.startsWith(u8, trimmed, "def ")) {
        return try handleDefSyntax(self, trimmed);
    }

    // Check for "function name" or "name()" syntax
    const is_function_keyword = std.mem.startsWith(u8, trimmed, "function ");

    if (!isFunctionDefinitionStart(trimmed)) {
        return false;
    }

    // This is a function definition - start collecting
    // Count braces in this line
    var brace_count: i32 = 0;
    for (trimmed) |c| {
        if (c == '{') brace_count += 1;
        if (c == '}') brace_count -= 1;
    }

    // Store the first line
    if (self.multiline_count >= self.multiline_buffer.len) {
        try IO.eprint("Function definition too long\n", .{});
        return true;
    }
    self.multiline_buffer[self.multiline_count] = try self.allocator.dupe(u8, trimmed);
    self.multiline_count += 1;
    self.multiline_brace_count = brace_count;

    if (brace_count > 0) {
        // Incomplete - need more lines
        self.multiline_mode = .function_def;
        return true;
    } else if (brace_count == 0) {
        // Check if we have an opening brace at all
        if (std.mem.indexOf(u8, trimmed, "{")) |open_brace| {
            // Complete single-line function like: function foo { echo hi; }
            // Handle single-line function directly without parser
            const close_brace = std.mem.lastIndexOf(u8, trimmed, "}") orelse {
                try IO.eprint("Syntax error: missing closing brace\n", .{});
                resetMultilineState(self);
                return true;
            };

            // Extract function name
            var func_name: []const u8 = undefined;
            if (is_function_keyword) {
                const after_keyword = std.mem.trim(u8, trimmed[9..], &std.ascii.whitespace);
                const name_end = std.mem.indexOfAny(u8, after_keyword, " \t{") orelse after_keyword.len;
                func_name = after_keyword[0..name_end];
            } else {
                // name() syntax
                const paren_pos = std.mem.indexOf(u8, trimmed, "()") orelse 0;
                func_name = std.mem.trim(u8, trimmed[0..paren_pos], &std.ascii.whitespace);
            }

            // Extract body (content between { and })
            const body_content = std.mem.trim(u8, trimmed[open_brace + 1 .. close_brace], &std.ascii.whitespace);

            // Create body as array of lines (split by semicolons, respecting control flow nesting)
            var body_lines: [32][]const u8 = undefined;
            var body_count: usize = 0;
            {
                var cf_depth: u32 = 0;
                var br_depth: u32 = 0; // Track nested brace depth for inner function defs
                var seg_start: usize = 0;
                var si: usize = 0;
                var in_sq = false;
                var in_dq = false;
                while (si < body_content.len) : (si += 1) {
                    const bc = body_content[si];
                    if (bc == '\\' and !in_sq and si + 1 < body_content.len) {
                        si += 1;
                        continue;
                    }
                    if (bc == '\'' and !in_dq) {
                        in_sq = !in_sq;
                    } else if (bc == '"' and !in_sq) {
                        in_dq = !in_dq;
                    } else if (!in_sq and !in_dq) {
                        // Track brace nesting for nested function definitions
                        if (bc == '{') {
                            br_depth += 1;
                        } else if (bc == '}' and br_depth > 0) {
                            br_depth -= 1;
                        }
                        // Track control flow nesting
                        if (isControlFlowWord(body_content, si, "for ") or
                            isControlFlowWord(body_content, si, "while ") or
                            isControlFlowWord(body_content, si, "until ") or
                            isControlFlowWord(body_content, si, "if ") or
                            isControlFlowWord(body_content, si, "case "))
                        {
                            cf_depth += 1;
                        } else if (isControlFlowEnd(body_content, si, "done") or
                            isControlFlowEnd(body_content, si, "fi") or
                            isControlFlowEnd(body_content, si, "esac"))
                        {
                            if (cf_depth > 0) cf_depth -= 1;
                        }
                        if (bc == ';' and cf_depth == 0 and br_depth == 0) {
                            // Skip ;; in case statements
                            if (si + 1 < body_content.len and body_content[si + 1] == ';') {
                                si += 1;
                                continue;
                            }
                            const part_trimmed = std.mem.trim(u8, body_content[seg_start..si], &std.ascii.whitespace);
                            if (part_trimmed.len > 0 and body_count < body_lines.len) {
                                body_lines[body_count] = try self.allocator.dupe(u8, part_trimmed);
                                body_count += 1;
                            }
                            seg_start = si + 1;
                        }
                    }
                }
                // Last segment
                const last_seg = std.mem.trim(u8, body_content[seg_start..], &std.ascii.whitespace);
                if (last_seg.len > 0 and body_count < body_lines.len) {
                    body_lines[body_count] = try self.allocator.dupe(u8, last_seg);
                    body_count += 1;
                }
            }

            // Define the function
            self.function_manager.defineFunction(func_name, body_lines[0..body_count], false) catch |err| {
                try IO.eprint("Function definition error: {}\n", .{err});
                // Free the body lines we allocated
                for (body_lines[0..body_count]) |line_content| {
                    self.allocator.free(line_content);
                }
                resetMultilineState(self);
                return true;
            };

            // Free the body lines (function_manager made its own copy)
            for (body_lines[0..body_count]) |line_content| {
                self.allocator.free(line_content);
            }

            resetMultilineState(self);
            return true;
        } else {
            // No brace yet - might be "function foo" and { on next line
            self.multiline_mode = .function_def;
            return true;
        }
    }

    return true;
}

/// Handle continuation of multiline input
pub fn handleMultilineContinuation(self: *Shell, trimmed: []const u8) !void {
    // Store the line
    if (self.multiline_count >= self.multiline_buffer.len) {
        try IO.eprint("Function definition too long\n", .{});
        resetMultilineState(self);
        return;
    }
    self.multiline_buffer[self.multiline_count] = try self.allocator.dupe(u8, trimmed);
    self.multiline_count += 1;

    // Update brace count
    for (trimmed) |c| {
        if (c == '{') self.multiline_brace_count += 1;
        if (c == '}') self.multiline_brace_count -= 1;
    }

    // Check if function is complete
    if (self.multiline_brace_count == 0 and self.multiline_count > 0) {
        // Check if we ever had an opening brace
        var had_opening_brace = false;
        for (self.multiline_buffer[0..self.multiline_count]) |maybe_line| {
            if (maybe_line) |line_content| {
                if (std.mem.indexOf(u8, line_content, "{") != null) {
                    had_opening_brace = true;
                    break;
                }
            }
        }

        if (had_opening_brace) {
            try finishFunctionDefinition(self);
        }
    }
}

// The two body-splitting paths - this one and the single-line parser in
// `scripting/functions.zig` - have to agree about where a top level is, so
// there is one implementation and it lives with the parser.
const isControlFlowWord = functions.isControlFlowWord;
const isControlFlowEnd = functions.isControlFlowEnd;

/// Complete function definition parsing and register the function
pub fn finishFunctionDefinition(self: *Shell) !void {
    // Collect lines into array for parser
    var lines: [100][]const u8 = undefined;
    var line_count: usize = 0;
    for (self.multiline_buffer[0..self.multiline_count]) |maybe_line| {
        if (maybe_line) |line_content| {
            lines[line_count] = line_content;
            line_count += 1;
        }
    }

    // Parse the function definition
    var parser = FunctionParser.init(self.allocator);

    const result = parser.parseFunction(lines[0..line_count], 0) catch |err| {
        try IO.eprint("Function parse error: {}\n", .{err});
        resetMultilineState(self);
        return;
    };

    // Define the function
    self.function_manager.defineFunction(result.name, result.body, false) catch |err| {
        try IO.eprint("Function definition error: {}\n", .{err});
        resetMultilineState(self);
        return;
    };

    // Free the name that was duped by parser (function_manager made its own copy)
    self.allocator.free(result.name);
    for (result.body) |body_line| {
        self.allocator.free(body_line);
    }
    self.allocator.free(result.body);

    resetMultilineState(self);
}

/// Reset multiline state and free buffered lines
pub fn resetMultilineState(self: *Shell) void {
    for (self.multiline_buffer[0..self.multiline_count]) |maybe_line| {
        if (maybe_line) |line_content| {
            self.allocator.free(line_content);
        }
    }
    self.multiline_buffer = @splat(null);
    self.multiline_count = 0;
    self.multiline_brace_count = 0;
    self.multiline_mode = .none;
}

/// Handle `def name [params] -> type { body }` syntax (Phase 5.2 typed commands).
///
/// This provides Nushell-style function definitions with typed parameters:
///   def greet [name: string, --formal(-f): bool] -> string { echo "Hello $name" }
fn handleDefSyntax(self: *Shell, trimmed: []const u8) !bool {
    const after_def = std.mem.trim(u8, trimmed[4..], &std.ascii.whitespace);

    // Extract function name (first word after "def")
    const name_end = std.mem.indexOfAny(u8, after_def, " \t[{") orelse after_def.len;
    if (name_end == 0) {
        try IO.eprint("def: missing function name\n", .{});
        return true;
    }
    const func_name = after_def[0..name_end];

    // Parse typed parameters if present: [param: type, ...]
    var typed_params: ?[]functions.TypedParam = null;
    var after_params = after_def[name_end..];
    after_params = std.mem.trim(u8, after_params, &std.ascii.whitespace);

    if (after_params.len > 0 and after_params[0] == '[') {
        // Find matching ']'
        var bracket_depth: i32 = 0;
        var bracket_end: usize = 0;
        for (after_params, 0..) |c, idx| {
            if (c == '[') bracket_depth += 1;
            if (c == ']') {
                bracket_depth -= 1;
                if (bracket_depth == 0) {
                    bracket_end = idx + 1;
                    break;
                }
            }
        }

        if (bracket_end > 0) {
            typed_params = functions.parseTypedParams(self.allocator, after_params[0..bracket_end]) catch null;
            after_params = std.mem.trim(u8, after_params[bracket_end..], &std.ascii.whitespace);
        }
    }

    // Parse return type: -> type
    var return_type: ?[]const u8 = null;
    if (std.mem.startsWith(u8, after_params, "->")) {
        const after_arrow = std.mem.trim(u8, after_params[2..], &std.ascii.whitespace);
        const type_end = std.mem.indexOfAny(u8, after_arrow, " \t{") orelse after_arrow.len;
        if (type_end > 0) {
            return_type = try self.allocator.dupe(u8, after_arrow[0..type_end]);
            after_params = std.mem.trim(u8, after_arrow[type_end..], &std.ascii.whitespace);
        }
    }

    // Count braces
    var brace_count: i32 = 0;
    for (trimmed) |c| {
        if (c == '{') brace_count += 1;
        if (c == '}') brace_count -= 1;
    }

    // Store the first line
    if (self.multiline_count >= self.multiline_buffer.len) {
        try IO.eprint("Function definition too long\n", .{});
        return true;
    }
    self.multiline_buffer[self.multiline_count] = try self.allocator.dupe(u8, trimmed);
    self.multiline_count += 1;
    self.multiline_brace_count = brace_count;

    if (brace_count > 0) {
        // Incomplete - need more lines
        self.multiline_mode = .function_def;
        return true;
    } else if (brace_count == 0) {
        // Check if we have an opening brace at all
        if (std.mem.indexOf(u8, trimmed, "{")) |open_brace| {
            const close_brace = std.mem.lastIndexOf(u8, trimmed, "}") orelse {
                try IO.eprint("def: syntax error: missing closing brace\n", .{});
                resetMultilineState(self);
                return true;
            };

            // Extract body between { and }
            const body_content = std.mem.trim(u8, trimmed[open_brace + 1 .. close_brace], &std.ascii.whitespace);

            // Split body by semicolons
            var body_lines: [32][]const u8 = undefined;
            var body_count: usize = 0;
            var seg_start: usize = 0;
            var si: usize = 0;
            var in_sq = false;
            var in_dq = false;

            while (si < body_content.len) : (si += 1) {
                const bc = body_content[si];
                if (bc == '\\' and !in_sq and si + 1 < body_content.len) {
                    si += 1;
                    continue;
                }
                if (bc == '\'' and !in_dq) in_sq = !in_sq;
                if (bc == '"' and !in_sq) in_dq = !in_dq;
                if (!in_sq and !in_dq and bc == ';') {
                    const part_trimmed = std.mem.trim(u8, body_content[seg_start..si], &std.ascii.whitespace);
                    if (part_trimmed.len > 0 and body_count < body_lines.len) {
                        body_lines[body_count] = try self.allocator.dupe(u8, part_trimmed);
                        body_count += 1;
                    }
                    seg_start = si + 1;
                }
            }
            // Last segment
            const last_seg = std.mem.trim(u8, body_content[seg_start..], &std.ascii.whitespace);
            if (last_seg.len > 0 and body_count < body_lines.len) {
                body_lines[body_count] = try self.allocator.dupe(u8, last_seg);
                body_count += 1;
            }

            // Define the function with typed params
            self.function_manager.defineFunction(func_name, body_lines[0..body_count], false) catch |err| {
                try IO.eprint("def: function definition error: {}\n", .{err});
                for (body_lines[0..body_count]) |line_content| {
                    self.allocator.free(line_content);
                }
                resetMultilineState(self);
                return true;
            };

            // Set typed params and return type on the function
            if (self.function_manager.getFunction(func_name)) |func| {
                func.typed_params = typed_params;
                func.return_type = return_type;
            }

            // Free body lines (function_manager made its own copy)
            for (body_lines[0..body_count]) |line_content| {
                self.allocator.free(line_content);
            }

            resetMultilineState(self);
            return true;
        } else {
            // No brace yet - might be multiline
            self.multiline_mode = .function_def;
            return true;
        }
    }

    return true;
}
