//! Variable Handling Module
//! Handles variable resolution, namerefs, and array assignments

const std = @import("std");
const IO = @import("../utils/io.zig").IO;
const types = @import("../types/mod.zig");
const Shell = @import("../shell.zig").Shell;
const HookContext = @import("../plugins/interface.zig").HookContext;
const expansion = @import("../utils/expansion.zig");
const cmd_exp = @import("command_expansion.zig");
const tokenizer = @import("../parser/tokenizer.zig");
const Glob = @import("../utils/glob.zig").Glob;
const BraceExpander = @import("../utils/brace.zig").BraceExpander;

/// End of the word beginning at `start`, one past its last character.
///
/// Quote-aware, and aware that `name=(` opens a parenthesised value: without
/// that, `a=(x y) && echo ok` scanned as the word `a=(x`, which looked like a
/// temporary variable assignment, leaving `y) && echo ok` to be run as the
/// command. An unterminated quote or paren runs to the end, as the callers'
/// own loops did.
pub fn wordEnd(text: []const u8, start: usize) usize {
    var i = start;
    var sq = false;
    var dq = false;
    while (i < text.len) {
        const c = text[i];
        if (c == '\'' and !dq) {
            sq = !sq;
        } else if (c == '"' and !sq) {
            dq = !dq;
        } else if (c == ' ' and !sq and !dq) {
            break;
        } else if (c == '(' and !sq and !dq and
            tokenizer.isArrayAssignPrefix(text[start..i]))
        {
            if (matchingParen(text, i)) |close| {
                i = close + 1;
                continue;
            }
            return text.len;
        }
        i += 1;
    }
    return i;
}

/// Resolve nameref chain to get the actual variable name
pub fn resolveNameref(self: *Shell, name: []const u8) []const u8 {
    var current_name = name;
    var depth: u32 = 0;
    const max_depth = 10;

    while (depth < max_depth) : (depth += 1) {
        if (self.var_attributes.get(current_name)) |attrs| {
            if (attrs.nameref) {
                // This is a nameref, its value is the name of the referenced variable
                if (self.environment.get(current_name)) |ref_name| {
                    current_name = ref_name;
                    continue;
                }
            }
        }
        // Not a nameref or no more references to follow
        break;
    }
    return current_name;
}

/// Get variable value following namerefs
pub fn getVariableValue(self: *Shell, name: []const u8) ?[]const u8 {
    const resolved_name = resolveNameref(self, name);
    return self.environment.get(resolved_name);
}

/// Set variable value following namerefs
pub fn setVariableValue(self: *Shell, name: []const u8, value: []const u8) !void {
    const resolved_name = resolveNameref(self, name);

    // Check if readonly or immutable
    if (self.var_attributes.get(resolved_name)) |attrs| {
        if (attrs.readonly) {
            try IO.eprint("den: {s}: readonly variable\n", .{resolved_name});
            return error.ReadonlyVariable;
        }
        if (attrs.immutable) {
            try IO.eprint("den: {s}: immutable variable (declared with let)\n", .{resolved_name});
            return error.ReadonlyVariable;
        }
    }

    // Apply case conversion if variable has lowercase/uppercase attribute
    var final_value = value;
    var case_buf: ?[]u8 = null;
    if (self.var_attributes.get(resolved_name)) |attrs| {
        if (attrs.lowercase) {
            const lower = try self.allocator.alloc(u8, value.len);
            for (value, 0..) |c, i| {
                lower[i] = std.ascii.toLower(c);
            }
            case_buf = lower;
            final_value = lower;
        } else if (attrs.uppercase) {
            const upper = try self.allocator.alloc(u8, value.len);
            for (value, 0..) |c, i| {
                upper[i] = std.ascii.toUpper(c);
            }
            case_buf = upper;
            final_value = upper;
        }
    }
    errdefer if (case_buf) |buf| self.allocator.free(buf);

    // If inside a function and the variable exists as a local, update local instead
    if (self.function_manager.currentFrame()) |frame| {
        if (frame.local_vars.getKey(resolved_name)) |_| {
            const val = if (case_buf) |buf| buf else try self.allocator.dupe(u8, final_value);
            errdefer if (case_buf == null) self.allocator.free(val);
            const gop = try frame.local_vars.getOrPut(resolved_name);
            if (gop.found_existing) {
                self.allocator.free(gop.value_ptr.*);
            }
            gop.value_ptr.* = val;
            return;
        }
    }

    // Set the value in global environment
    const new_val = if (case_buf) |buf| buf else try self.allocator.dupe(u8, final_value);
    errdefer if (case_buf == null) self.allocator.free(new_val);
    const gop = try self.environment.getOrPut(resolved_name);
    if (gop.found_existing) {
        self.allocator.free(gop.value_ptr.*);
    } else {
        gop.key_ptr.* = try self.allocator.dupe(u8, resolved_name);
    }
    gop.value_ptr.* = new_val;

    // Fire env_change hook for environment variable changes (especially PWD, OLDPWD, PATH, etc.)
    fireEnvChangeHook(self, resolved_name);
}

/// Fire the env_change hook when an environment variable is modified
fn fireEnvChangeHook(self: *Shell, var_name: []const u8) void {
    var name_copy = @as([]const u8, var_name);
    var hook_ctx = HookContext{
        .hook_type = .env_change,
        .data = @ptrCast(@alignCast(&name_copy)),
        .user_data = null,
        .allocator = self.allocator,
    };
    self.plugin_registry.executeHooks(.env_change, &hook_ctx) catch {};
}

/// Check if input is an array element assignment: name[index]=value
pub fn isArrayElementAssignment(input: []const u8) bool {
    const trimmed = std.mem.trim(u8, input, &std.ascii.whitespace);
    // Look for pattern: name[index]=value
    const bracket_pos = std.mem.indexOfScalar(u8, trimmed, '[') orelse return false;
    if (bracket_pos == 0) return false;
    // Verify name part is valid
    for (trimmed[0..bracket_pos]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    // Find closing bracket followed by =
    const close_bracket = std.mem.indexOfScalar(u8, trimmed[bracket_pos..], ']') orelse return false;
    const abs_close = bracket_pos + close_bracket;
    if (abs_close + 1 >= trimmed.len) return false;
    return trimmed[abs_close + 1] == '=';
}

/// Execute array element assignment: name[index]=value
pub fn executeArrayElementAssignment(self: *Shell, input: []const u8) !void {
    const trimmed = std.mem.trim(u8, input, &std.ascii.whitespace);
    const bracket_pos = std.mem.indexOfScalar(u8, trimmed, '[') orelse return;
    const name = trimmed[0..bracket_pos];

    const close_bracket = std.mem.indexOfScalar(u8, trimmed[bracket_pos..], ']') orelse return;
    const abs_close = bracket_pos + close_bracket;
    const index_str = trimmed[bracket_pos + 1 .. abs_close];

    // Value is everything after ]=
    if (abs_close + 2 > trimmed.len) return;
    var raw_value = trimmed[abs_close + 2 ..];
    // Strip quotes
    if (raw_value.len >= 2 and
        ((raw_value[0] == '"' and raw_value[raw_value.len - 1] == '"') or
            (raw_value[0] == '\'' and raw_value[raw_value.len - 1] == '\'')))
    {
        raw_value = raw_value[1 .. raw_value.len - 1];
    }

    // Check if this is an associative array
    if (self.assoc_arrays.contains(name)) {
        const gop = try self.assoc_arrays.getOrPut(name);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, name);
            gop.value_ptr.* = std.StringHashMap([]const u8).init(self.allocator);
        }
        const inner_gop = try gop.value_ptr.getOrPut(index_str);
        if (inner_gop.found_existing) {
            self.allocator.free(inner_gop.value_ptr.*);
        } else {
            inner_gop.key_ptr.* = try self.allocator.dupe(u8, index_str);
        }
        inner_gop.value_ptr.* = try self.allocator.dupe(u8, raw_value);
        self.last_exit_code = 0;
        return;
    }

    // Resolve the subscript: a plain integer, or an arithmetic expression.
    const signed_index: i64 = std.fmt.parseInt(i64, index_str, 10) catch blk: {
        var arith = @import("../utils/arithmetic.zig").Arithmetic.initWithVariables(self.allocator, &self.environment);
        arith.arrays = &self.arrays;
        break :blk arith.eval(index_str) catch return;
    };

    // Negative subscripts count from one past the highest set subscript (bash):
    // a[-1] is the last element. Resolve against any existing array first so a
    // failed negative lookup doesn't materialise an empty one.
    var resolved: i64 = signed_index;
    if (signed_index < 0) {
        const base: i64 = if (self.arrays.get(name)) |arr|
            (if (arr.indices.len == 0) 0 else @as(i64, @intCast(arr.indices[arr.indices.len - 1])) + 1)
        else
            0;
        resolved = base + signed_index;
        if (resolved < 0) {
            self.last_exit_code = 1;
            return;
        }
    }

    // Get or create the indexed array, then set the single subscript sparsely
    // (gaps stay unset, matching bash).
    const gop = try self.arrays.getOrPut(name);
    if (!gop.found_existing) {
        gop.key_ptr.* = try self.allocator.dupe(u8, name);
        gop.value_ptr.* = try types.IndexedArray.initEmpty(self.allocator);
    }
    try gop.value_ptr.setIndex(self.allocator, @intCast(resolved), raw_value);
    self.last_exit_code = 0;
}

/// Check if input is an array assignment: name=(value1 value2 ...)
pub fn isArrayAssignment(input: []const u8) bool {
    const trimmed = std.mem.trim(u8, input, &std.ascii.whitespace);
    // Look for pattern: name=(...) or name+=(...)
    const eq_pos = std.mem.indexOfScalar(u8, trimmed, '=') orelse return false;
    if (eq_pos >= trimmed.len - 1) return false;
    if (trimmed[eq_pos + 1] != '(') return false;

    // Verify the part before = is a valid variable name (no spaces)
    const name_end = if (eq_pos > 0 and trimmed[eq_pos - 1] == '+') eq_pos - 1 else eq_pos;
    if (name_end == 0) return false;
    const name = trimmed[0..name_end];
    // Must not contain spaces (rules out "declare -a arr")
    if (std.mem.indexOfScalar(u8, name, ' ') != null) return false;
    // First char must be letter or underscore
    if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_') return false;
    // All chars must be alphanumeric or underscore
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }

    // The value must be a complete `(...)` with nothing after it.
    //
    // Matching the closing paren matters: a chain like `a=(x) && echo done` was
    // claimed whole here, assigned, and the rest silently dropped. Rejecting it
    // lets the parser handle the line, where the tokenizer keeps `a=(x)` as one
    // word and the executor assigns it as a chain segment.
    const close = matchingParen(trimmed, eq_pos + 1) orelse return false;
    return std.mem.trim(u8, trimmed[close + 1 ..], &std.ascii.whitespace).len == 0;
}

/// Index of the `)` closing the `(` at `open`, counting nesting and skipping
/// quoted text. Null if it is never closed.
pub fn matchingParen(text: []const u8, open: usize) ?usize {
    var depth: usize = 0;
    var quote: u8 = 0;
    var i = open;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (quote != 0) {
            if (c == quote) quote = 0;
            continue;
        }
        switch (c) {
            '\'', '"' => quote = c,
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

/// Parse and execute array assignment (or array append with +=)
/// If a substitution starts at `i`, advance past the whole of it.
///
/// `$(...)`, `${...}` and `` `...` `` are single words even when they contain
/// spaces, so the scanner cannot simply stop at the next whitespace:
/// `a=($(echo p q))` is one word that expands to two elements, not three words.
/// Nesting is counted so that `$(echo $(echo x))` is handled.
fn skipSubstitution(content: []const u8, i: *usize) bool {
    const rest = content[i.*..];
    if (rest.len >= 1 and rest[0] == '`') {
        i.* += 1;
        while (i.* < content.len and content[i.*] != '`') : (i.* += 1) {
            // A backslash inside backticks escapes the next character.
            if (content[i.*] == '\\' and i.* + 1 < content.len) i.* += 1;
        }
        if (i.* < content.len) i.* += 1;
        return true;
    }
    if (rest.len >= 2 and rest[0] == '$' and (rest[1] == '(' or rest[1] == '{')) {
        const open = rest[1];
        const close: u8 = if (open == '(') ')' else '}';
        i.* += 2;
        var depth: usize = 1;
        while (i.* < content.len and depth > 0) : (i.* += 1) {
            if (content[i.*] == open) depth += 1 else if (content[i.*] == close) depth -= 1;
        }
        return true;
    }
    return false;
}

/// One run of characters inside an array element, and how it was quoted.
const Segment = struct {
    text: []const u8,
    quoting: cmd_exp.Quoting,
};

/// Scan one whitespace-delimited word of an array literal into quoted and
/// unquoted runs, advancing `i` past it.
///
/// Quoting is tracked per run rather than per word because the two differ:
/// `a=("x"y)` is one element `xy`, not the two the old scanner produced by
/// stopping at the closing quote and starting again at `y`.
///
/// An unterminated quote runs to the end of the literal, which is what the
/// shell does with `a=("oops)`.
fn scanWord(content: []const u8, i: *usize, out: *[32]Segment) usize {
    var count: usize = 0;
    while (i.* < content.len and !std.ascii.isWhitespace(content[i.*])) {
        const c = content[i.*];
        if (c == '"' or c == '\'') {
            const quote = c;
            i.* += 1;
            const start = i.*;
            while (i.* < content.len and content[i.*] != quote) : (i.* += 1) {}
            if (count < out.len) {
                out[count] = .{
                    .text = content[start..i.*],
                    .quoting = if (quote == '\'') .single else .double,
                };
                count += 1;
            }
            if (i.* < content.len) i.* += 1; // past the closing quote
            continue;
        }

        const start = i.*;
        while (i.* < content.len and
            !std.ascii.isWhitespace(content[i.*]) and
            content[i.*] != '"' and content[i.*] != '\'')
        {
            if (skipSubstitution(content, i)) continue;
            i.* += 1;
        }
        if (count < out.len) {
            out[count] = .{ .text = content[start..i.*], .quoting = .none };
            count += 1;
        }
    }
    return count;
}

pub fn executeArrayAssignment(self: *Shell, input: []const u8) !void {
    const eq_pos = std.mem.indexOfScalar(u8, input, '=') orelse return error.InvalidSyntax;
    const is_append = eq_pos > 0 and input[eq_pos - 1] == '+';
    const name_end = if (is_append) eq_pos - 1 else eq_pos;
    const name = std.mem.trim(u8, input[0..name_end], &std.ascii.whitespace);

    // Validate variable name
    if (name.len == 0) return error.InvalidVariableName;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') {
            return error.InvalidVariableName;
        }
    }

    // Find array content between ( and )
    const start_paren = eq_pos + 1;
    if (input[start_paren] != '(') return error.InvalidSyntax;

    const end_paren = std.mem.lastIndexOfScalar(u8, input, ')') orelse return error.InvalidSyntax;
    if (end_paren <= start_paren + 1) {
        // Empty array: name=() — but `name+=()` is a no-op append, keep existing.
        if (is_append and self.arrays.contains(name)) {
            self.last_exit_code = 0;
            return;
        }
        const key = try self.allocator.dupe(u8, name);
        const empty_array = try types.IndexedArray.initEmpty(self.allocator);

        // Free old array if exists
        if (self.arrays.fetchRemove(name)) |old| {
            old.value.deinit(self.allocator);
            self.allocator.free(old.key);
        }

        try self.arrays.put(key, empty_array);
        self.last_exit_code = 0;
        return;
    }

    // Parse array elements (respecting quoted strings)
    const content = std.mem.trim(u8, input[start_paren + 1 .. end_paren], &std.ascii.whitespace);

    // Subscript form: arr=([3]=c [1]=a) or arr=(x [5]=y z). If any element
    // begins with an unquoted '[', build a sparse array with explicit subscripts
    // (bash semantics: a bare element takes the index after the last one set).
    if (containsSubscriptElement(content)) {
        try executeSubscriptedArrayLiteral(self, name, content, is_append);
        return;
    }

    // Expand the elements.
    //
    // This used to dupe each word verbatim, so `fpath=(~/funcs $fpath)` stored
    // a literal `~/funcs` and a command substitution was merely split on its
    // own whitespace. Array elements are words like any other, so they go
    // through the same pipeline as a command's arguments: parameter, tilde,
    // command and arithmetic expansion, then field splitting of an unquoted
    // result, then braces and globs.
    //
    // One word can therefore yield several elements (`a=($X)` with two fields)
    // or none (`a=(*.nothing)` with nullglob), which is why the count is no
    // longer worked out in advance.
    var storage: cmd_exp.ExpanderStorage = .{};
    var expander = cmd_exp.makeExpander(self, &storage);
    var glob = Glob.init(self.allocator);
    glob.qualifiers_enabled = self.config.zsh.enabled and self.config.zsh.glob_qualifiers;
    var brace = BraceExpander.init(self.allocator);

    var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_result = std.c.getcwd(&cwd_buf, cwd_buf.len) orelse return error.Unexpected;
    const cwd = std.mem.sliceTo(@as([*:0]u8, @ptrCast(cwd_result)), 0);

    var expanded: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (expanded.items) |e| self.allocator.free(e);
        expanded.deinit(self.allocator);
    }

    {
        var ci: usize = 0;
        while (ci < content.len) {
            while (ci < content.len and std.ascii.isWhitespace(content[ci])) : (ci += 1) {}
            if (ci >= content.len) break;

            var segs: [32]Segment = undefined;
            const seg_count = scanWord(content, &ci, &segs);
            if (seg_count == 0) continue;

            if (seg_count == 1) {
                try cmd_exp.expandWordInto(
                    self,
                    &expander,
                    &brace,
                    &glob,
                    cwd,
                    segs[0].text,
                    segs[0].quoting,
                    &expanded,
                );
                continue;
            }

            // A word that mixes quoting, such as `pre"$X"post`. Each run is
            // expanded on its own and the results are joined into one element.
            // Field splitting is not applied across such a word: knowing which
            // part of the result came from the unquoted run needs markers
            // through the expander that den does not carry.
            var joined: std.ArrayList(u8) = .empty;
            defer joined.deinit(self.allocator);
            for (segs[0..seg_count]) |seg| {
                if (seg.quoting == .single) {
                    try joined.appendSlice(self.allocator, seg.text);
                    continue;
                }
                expander.skip_tilde = seg.quoting != .none;
                const piece = try expander.expand(seg.text);
                expander.skip_tilde = false;
                defer self.allocator.free(piece);
                try joined.appendSlice(self.allocator, piece);
            }
            const element = try cmd_exp.stripGlobEscapes(self.allocator, joined.items);
            errdefer self.allocator.free(element);
            try expanded.append(self.allocator, element);
        }
    }

    const array = try expanded.toOwnedSlice(self.allocator);
    errdefer self.allocator.free(array);

    if (is_append) {
        // Append to existing array: new elements take subscripts after the
        // current highest one (matching bash's `arr+=(...)`).
        if (self.arrays.getPtr(name)) |old_ptr| {
            const old = old_ptr.*;
            const base: usize = if (old.indices.len == 0) 0 else old.indices[old.indices.len - 1] + 1;
            const new_vals = try self.allocator.alloc([]const u8, old.values.len + array.len);
            errdefer self.allocator.free(new_vals);
            const new_idx = try self.allocator.alloc(usize, old.indices.len + array.len);
            errdefer self.allocator.free(new_idx);
            @memcpy(new_vals[0..old.values.len], old.values);
            @memcpy(new_idx[0..old.indices.len], old.indices);
            @memcpy(new_vals[old.values.len..], array);
            for (0..array.len) |k| new_idx[old.indices.len + k] = base + k;
            // Free old/new backing slices (element strings are now in new_vals).
            old.deinitShallow(self.allocator);
            self.allocator.free(array);
            old_ptr.* = .{ .values = new_vals, .indices = new_idx };
        } else {
            // No existing array - just create new one (dense 0..N-1)
            const key = try self.allocator.dupe(u8, name);
            try self.arrays.put(key, try types.IndexedArray.fromOwnedDense(self.allocator, array));
        }
    } else {
        // Store array (replace) — dense subscripts 0..N-1.

        // Free old array if exists
        if (self.arrays.fetchRemove(name)) |old| {
            old.value.deinit(self.allocator);
            self.allocator.free(old.key);
        }

        const key = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(key);
        try self.arrays.put(key, try types.IndexedArray.fromOwnedDense(self.allocator, array));
    }
    self.last_exit_code = 0;
}

/// Read the next whitespace-separated word from `content`, treating quotes as
/// boundary-suppressing. Returns the raw slice (quotes included) and advances
/// `ci` past it; null when only trailing whitespace remains.
fn nextRawWord(content: []const u8, ci: *usize) ?[]const u8 {
    while (ci.* < content.len and std.ascii.isWhitespace(content[ci.*])) : (ci.* += 1) {}
    if (ci.* >= content.len) return null;
    const start = ci.*;
    var in_sq = false;
    var in_dq = false;
    while (ci.* < content.len) : (ci.* += 1) {
        const c = content[ci.*];
        if (c == '\\' and !in_sq and ci.* + 1 < content.len) {
            ci.* += 1; // skip escaped char
            continue;
        }
        if (c == '\'' and !in_dq) {
            in_sq = !in_sq;
            continue;
        }
        if (c == '"' and !in_sq) {
            in_dq = !in_dq;
            continue;
        }
        if (!in_sq and !in_dq and std.ascii.isWhitespace(c)) break;
    }
    return content[start..ci.*];
}

/// True if any element of an array literal body begins with an unquoted '[',
/// i.e. uses explicit `[subscript]=value` syntax.
fn containsSubscriptElement(content: []const u8) bool {
    var ci: usize = 0;
    while (nextRawWord(content, &ci)) |word| {
        if (word.len > 0 and word[0] == '[') return true;
    }
    return false;
}

/// Build a sparse indexed array from a literal that mixes bare and
/// `[subscript]=value` elements, e.g. `arr=(x [5]=y z)` → 0:x 5:y 6:z.
/// For `+=`, bare elements continue after the existing highest subscript.
fn executeSubscriptedArrayLiteral(self: *Shell, name: []const u8, content: []const u8, is_append: bool) !void {
    // Seed from the existing array on append; otherwise start fresh (freeing any
    // previous value, since a plain `=` replaces).
    var arr: types.IndexedArray = blk: {
        if (self.arrays.fetchRemove(name)) |old| {
            if (is_append) {
                self.allocator.free(old.key);
                break :blk old.value;
            }
            old.value.deinit(self.allocator);
            self.allocator.free(old.key);
        }
        break :blk try types.IndexedArray.initEmpty(self.allocator);
    };
    errdefer arr.deinit(self.allocator);

    // Next implicit subscript: one past the current highest (0 for a fresh array).
    var cur: usize = if (arr.indices.len > 0) arr.indices[arr.indices.len - 1] + 1 else 0;

    var ci: usize = 0;
    while (nextRawWord(content, &ci)) |word| {
        var idx = cur;
        var value_raw = word;
        if (word.len > 0 and word[0] == '[') {
            if (std.mem.indexOfScalar(u8, word, ']')) |rb| {
                if (rb + 1 < word.len and word[rb + 1] == '=') {
                    const idx_str = std.mem.trim(u8, word[1..rb], &std.ascii.whitespace);
                    idx = parseArraySubscript(self, idx_str) orelse cur;
                    value_raw = word[rb + 2 ..];
                }
            }
        }
        const value = try expansion.removeQuotes(self.allocator, value_raw);
        defer self.allocator.free(value);
        try arr.setIndex(self.allocator, idx, value);
        cur = idx + 1;
    }

    const key = try self.allocator.dupe(u8, name);
    errdefer self.allocator.free(key);
    try self.arrays.put(key, arr);
    self.last_exit_code = 0;
}

/// Parse an array subscript that may be a plain integer or an arithmetic
/// expression (`[1+2]`). Returns null when it cannot be resolved to a
/// non-negative index.
fn parseArraySubscript(self: *Shell, idx_str: []const u8) ?usize {
    if (std.fmt.parseInt(usize, idx_str, 10)) |n| {
        return n;
    } else |_| {}
    var arith = @import("../utils/arithmetic.zig").Arithmetic.initWithVariables(self.allocator, &self.environment);
    arith.arrays = &self.arrays;
    const v = arith.eval(idx_str) catch return null;
    if (v < 0) return null;
    return @intCast(v);
}

/// Parse and execute associative array assignment: name=([key1]=val1 [key2]=val2 ...)
pub fn executeAssocArrayAssignment(self: *Shell, input: []const u8) !void {
    const eq_pos = std.mem.indexOfScalar(u8, input, '=') orelse return error.InvalidSyntax;
    const name = std.mem.trim(u8, input[0..eq_pos], &std.ascii.whitespace);

    if (name.len == 0) return error.InvalidVariableName;

    const start_paren = eq_pos + 1;
    if (start_paren >= input.len or input[start_paren] != '(') return error.InvalidSyntax;
    const end_paren = std.mem.lastIndexOfScalar(u8, input, ')') orelse return error.InvalidSyntax;

    // Get or create the associative array
    const gop = try self.assoc_arrays.getOrPut(name);
    if (!gop.found_existing) {
        const key = try self.allocator.dupe(u8, name);
        gop.key_ptr.* = key;
        gop.value_ptr.* = std.StringHashMap([]const u8).init(self.allocator);
    } else {
        // Clear existing entries
        var iter = gop.value_ptr.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        gop.value_ptr.clearRetainingCapacity();
    }

    if (end_paren <= start_paren + 1) {
        self.last_exit_code = 0;
        return;
    }

    // Parse [key]=value pairs
    const content = input[start_paren + 1 .. end_paren];
    var i: usize = 0;
    while (i < content.len) {
        while (i < content.len and (content[i] == ' ' or content[i] == '\t')) i += 1;
        if (i >= content.len) break;

        if (content[i] == '[') {
            const key_start = i + 1;
            const close_bracket = std.mem.indexOfScalar(u8, content[key_start..], ']') orelse break;
            const akey = content[key_start .. key_start + close_bracket];
            i = key_start + close_bracket + 1;
            if (i < content.len and content[i] == '=') {
                i += 1;
                var val_start = i;
                var val_end = i;
                if (i < content.len and (content[i] == '"' or content[i] == '\'')) {
                    const quote = content[i];
                    i += 1;
                    val_start = i;
                    while (i < content.len and content[i] != quote) i += 1;
                    val_end = i;
                    if (i < content.len) i += 1;
                } else {
                    while (i < content.len and content[i] != ' ' and content[i] != '\t') i += 1;
                    val_end = i;
                }
                const inner_gop = try gop.value_ptr.getOrPut(akey);
                if (inner_gop.found_existing) {
                    self.allocator.free(inner_gop.value_ptr.*);
                } else {
                    inner_gop.key_ptr.* = try self.allocator.dupe(u8, akey);
                }
                inner_gop.value_ptr.* = try self.allocator.dupe(u8, content[val_start..val_end]);
            }
        } else {
            while (i < content.len and content[i] != ' ' and content[i] != '\t') i += 1;
        }
    }
    self.last_exit_code = 0;
}

/// Check if input is an associative array element assignment: name[key]=value (where name is declared -A)
pub fn isAssocArrayElementAssignment(self: *Shell, input: []const u8) bool {
    const trimmed = std.mem.trim(u8, input, &std.ascii.whitespace);
    const bracket_pos = std.mem.indexOfScalar(u8, trimmed, '[') orelse return false;
    if (bracket_pos == 0) return false;
    for (trimmed[0..bracket_pos]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    const close_bracket = std.mem.indexOfScalar(u8, trimmed[bracket_pos..], ']') orelse return false;
    const abs_close = bracket_pos + close_bracket;
    if (abs_close + 1 >= trimmed.len) return false;
    if (trimmed[abs_close + 1] != '=') return false;
    const arr_name = trimmed[0..bracket_pos];
    return self.assoc_arrays.contains(arr_name);
}

/// Execute associative array element assignment: name[key]=value
pub fn executeAssocArrayElementAssignment(self: *Shell, input: []const u8) !void {
    const trimmed = std.mem.trim(u8, input, &std.ascii.whitespace);
    const bracket_pos = std.mem.indexOfScalar(u8, trimmed, '[') orelse return;
    const name = trimmed[0..bracket_pos];

    const close_bracket = std.mem.indexOfScalar(u8, trimmed[bracket_pos..], ']') orelse return;
    const abs_close = bracket_pos + close_bracket;
    const key = trimmed[bracket_pos + 1 .. abs_close];

    if (abs_close + 2 > trimmed.len) return;
    var raw_value = trimmed[abs_close + 2 ..];
    if (raw_value.len >= 2 and
        ((raw_value[0] == '"' and raw_value[raw_value.len - 1] == '"') or
            (raw_value[0] == '\'' and raw_value[raw_value.len - 1] == '\'')))
    {
        raw_value = raw_value[1 .. raw_value.len - 1];
    }

    const gop = try self.assoc_arrays.getOrPut(name);
    if (!gop.found_existing) {
        const dup_name = try self.allocator.dupe(u8, name);
        gop.key_ptr.* = dup_name;
        gop.value_ptr.* = std.StringHashMap([]const u8).init(self.allocator);
    }

    const inner_gop = try gop.value_ptr.getOrPut(key);
    if (inner_gop.found_existing) {
        self.allocator.free(inner_gop.value_ptr.*);
    } else {
        inner_gop.key_ptr.* = try self.allocator.dupe(u8, key);
    }
    inner_gop.value_ptr.* = try self.allocator.dupe(u8, raw_value);
    self.last_exit_code = 0;
}

// ============================================================================
// Tests
// ============================================================================

test "isArrayElementAssignment valid patterns" {
    try std.testing.expect(isArrayElementAssignment("arr[0]=hello"));
    try std.testing.expect(isArrayElementAssignment("my_arr[123]=value"));
    try std.testing.expect(isArrayElementAssignment("x[0]="));
}

test "isArrayElementAssignment invalid patterns" {
    try std.testing.expect(!isArrayElementAssignment("arr=hello"));
    try std.testing.expect(!isArrayElementAssignment("arr[0]"));
    try std.testing.expect(!isArrayElementAssignment("[0]=value"));
    try std.testing.expect(!isArrayElementAssignment(""));
    try std.testing.expect(!isArrayElementAssignment("="));
    // No closing bracket
    try std.testing.expect(!isArrayElementAssignment("arr[0"));
}

test "isArrayAssignment valid patterns" {
    try std.testing.expect(isArrayAssignment("arr=(a b c)"));
    try std.testing.expect(isArrayAssignment("my_arr=(one two three)"));
    try std.testing.expect(isArrayAssignment("x=()"));
    try std.testing.expect(isArrayAssignment("arr+=(d e)"));
}

test "isArrayAssignment invalid patterns" {
    try std.testing.expect(!isArrayAssignment("arr=hello"));
    try std.testing.expect(!isArrayAssignment("arr=("));
    try std.testing.expect(!isArrayAssignment("=(a b c)"));
    try std.testing.expect(!isArrayAssignment(""));
    try std.testing.expect(!isArrayAssignment("1arr=(a b)"));
    // Name with spaces (would be parsed as "declare -a arr")
    try std.testing.expect(!isArrayAssignment("declare -a arr=(a b)"));
}

test "isArrayElementAssignment bounds check" {
    // These inputs would cause OOB without the abs_close + 2 > trimmed.len check:
    // "arr[0]" — has bracket pair but no '=' after closing bracket
    try std.testing.expect(!isArrayElementAssignment("arr[0]"));
    // "arr[0]" — bracket at very end
    try std.testing.expect(!isArrayElementAssignment("a[x]"));
}
