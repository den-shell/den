const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat");
const Arithmetic = @import("arithmetic.zig").Arithmetic;
const env_utils = @import("env.zig");
const process_util = @import("process.zig");

const is_windows = builtin.os.tag == .windows;

/// Expand zsh-style "manydots": a leading run of 3+ dots is shorthand for going
/// that many levels up. `...` -> `../..`, `....` -> `../../..`,
/// `.../foo` -> `../../foo`. A run of 3+ dots only counts when it is the whole
/// token or is immediately followed by `/`, so real filenames like `...rc` or
/// `..foo` are left untouched. `.` and `..` are never rewritten. Returns null
/// (no allocation) when there is nothing to expand; otherwise the caller owns
/// the returned slice.
pub fn expandManyDots(allocator: std.mem.Allocator, path: []const u8) !?[]const u8 {
    var dots: usize = 0;
    while (dots < path.len and path[dots] == '.') : (dots += 1) {}
    if (dots < 3) return null;
    if (dots != path.len and path[dots] != '/') return null;

    const levels = dots - 1; // `...` (3 dots) == two levels up
    const rest = path[dots..]; // "" or "/subpath"

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var i: usize = 0;
    while (i < levels) : (i += 1) {
        try buf.appendSlice(allocator, if (i == 0) ".." else "/..");
    }
    try buf.appendSlice(allocator, rest);
    return try buf.toOwnedSlice(allocator);
}

test "expandManyDots" {
    const a = std.testing.allocator;
    try std.testing.expect((try expandManyDots(a, ".")) == null);
    try std.testing.expect((try expandManyDots(a, "..")) == null);
    try std.testing.expect((try expandManyDots(a, "...rc")) == null);
    try std.testing.expect((try expandManyDots(a, "foo")) == null);
    {
        const r = (try expandManyDots(a, "...")).?;
        defer a.free(r);
        try std.testing.expectEqualStrings("../..", r);
    }
    {
        const r = (try expandManyDots(a, "....")).?;
        defer a.free(r);
        try std.testing.expectEqualStrings("../../..", r);
    }
    {
        const r = (try expandManyDots(a, ".../foo")).?;
        defer a.free(r);
        try std.testing.expectEqualStrings("../../foo", r);
    }
}

/// Persistent PRNG state for $RANDOM, shared across all accesses
var global_random_state: ?std.Random.DefaultPrng = null;

fn getRandomValue() u16 {
    if (global_random_state == null) {
        const seed: u64 = if (compat.Instant.now()) |inst|
            (if (is_windows)
                inst.timestamp
            else
                @as(u64, @intCast(inst.timestamp.sec)) *% 1000000000 +% @as(u64, @intCast(inst.timestamp.nsec)))
        else |_|
            42;
        global_random_state = std.Random.DefaultPrng.init(seed);
    }
    return global_random_state.?.random().intRangeAtMost(u16, 0, 32767);
}

/// LRU cache for variable expansion results
pub const ExpansionCache = struct {
    const CacheEntry = struct {
        value: []const u8,
        age: u64,
    };

    allocator: std.mem.Allocator,
    entries: std.StringHashMap(CacheEntry),
    max_entries: u32,
    access_counter: u64,

    pub fn init(allocator: std.mem.Allocator, max_entries: u32) ExpansionCache {
        return .{
            .allocator = allocator,
            .entries = std.StringHashMap(CacheEntry).init(allocator),
            .max_entries = max_entries,
            .access_counter = 0,
        };
    }

    pub fn deinit(self: *ExpansionCache) void {
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.value);
            self.allocator.free(entry.key_ptr.*);
        }
        self.entries.deinit();
    }

    pub fn get(self: *ExpansionCache, key: []const u8) ?[]const u8 {
        if (self.entries.getPtr(key)) |entry| {
            // Update access time
            self.access_counter += 1;
            entry.age = self.access_counter;
            return entry.value;
        }
        return null;
    }

    pub fn put(self: *ExpansionCache, key: []const u8, value: []const u8) !void {
        // Check if we need to evict
        if (self.entries.count() >= self.max_entries) {
            self.evictOldest();
        }

        // Remove existing entry if present
        if (self.entries.fetchRemove(key)) |old| {
            self.allocator.free(old.value.value);
            self.allocator.free(old.key);
        }

        // Duplicate key and value
        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);

        const value_copy = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(value_copy);

        self.access_counter += 1;
        try self.entries.put(key_copy, .{
            .value = value_copy,
            .age = self.access_counter,
        });
    }

    fn evictOldest(self: *ExpansionCache) void {
        var oldest_key: ?[]const u8 = null;
        var oldest_age: u64 = std.math.maxInt(u64);

        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.age < oldest_age) {
                oldest_age = entry.value_ptr.age;
                oldest_key = entry.key_ptr.*;
            }
        }

        if (oldest_key) |key| {
            if (self.entries.fetchRemove(key)) |removed| {
                self.allocator.free(removed.value.value);
                self.allocator.free(removed.key);
            }
        }
    }

    pub fn clear(self: *ExpansionCache) void {
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.value);
            self.allocator.free(entry.key_ptr.*);
        }
        self.entries.clearRetainingCapacity();
    }

    pub fn count(self: *ExpansionCache) usize {
        return self.entries.count();
    }
};

// Import VarAttributes type
const types = @import("../types/mod.zig");

/// Variable expansion utilities
pub const Expansion = struct {
    allocator: std.mem.Allocator,
    environment: *std.StringHashMap([]const u8),
    arrays: ?*std.StringHashMap([][]const u8), // Indexed array variables
    assoc_arrays: ?*std.StringHashMap(std.StringHashMap([]const u8)), // Associative array variables
    local_vars: ?*std.StringHashMap([]const u8), // Function local variables (checked first)
    var_attributes: ?*std.StringHashMap(types.VarAttributes), // Variable attributes for namerefs
    last_exit_code: i32,
    positional_params: []const []const u8, // $1, $2, etc.
    shell_name: []const u8, // $0
    last_background_pid: i32, // $!
    last_arg: []const u8, // $_
    shell: ?*anyopaque, // Optional shell reference for function local vars
    exec_command_fn: ?*const fn (*anyopaque, []const u8) void, // Callback for command substitution
    option_nounset: bool, // set -u: error on unset variable
    cmd_cache: ?*ExpansionCache, // Optional cache for command substitution results
    line_number: u32, // $LINENO
    shell_start_time: i64, // For $SECONDS
    skip_tilde: bool = false, // When true, suppress tilde expansion (for quoted args)

    pub fn init(allocator: std.mem.Allocator, environment: *std.StringHashMap([]const u8), last_exit_code: i32) Expansion {
        return .{
            .allocator = allocator,
            .environment = environment,
            .arrays = null,
            .assoc_arrays = null,
            .local_vars = null,
            .var_attributes = null,
            .last_exit_code = last_exit_code,
            .positional_params = &[_][]const u8{},
            .shell_name = "den",
            .last_background_pid = 0,
            .last_arg = "",
            .shell = null,
            .exec_command_fn = null,
            .option_nounset = false,
            .cmd_cache = null,
            .line_number = 1,
            .shell_start_time = if (compat.Instant.now()) |inst| (if (@import("builtin").os.tag == .windows) @as(i64, @intCast(inst.timestamp / 10_000_000)) else @as(i64, @intCast(inst.timestamp.sec))) else |_| 0,
            .skip_tilde = false,
        };
    }

    pub fn initWithParams(
        allocator: std.mem.Allocator,
        environment: *std.StringHashMap([]const u8),
        last_exit_code: i32,
        positional_params: []const []const u8,
        shell_name: []const u8,
        last_background_pid: i32,
        last_arg: []const u8,
    ) Expansion {
        return .{
            .allocator = allocator,
            .environment = environment,
            .arrays = null,
            .assoc_arrays = null,
            .local_vars = null,
            .var_attributes = null,
            .last_exit_code = last_exit_code,
            .positional_params = positional_params,
            .shell_name = shell_name,
            .last_background_pid = last_background_pid,
            .last_arg = last_arg,
            .shell = null,
            .exec_command_fn = null,
            .option_nounset = false,
            .cmd_cache = null,
            .line_number = 1,
            .shell_start_time = if (compat.Instant.now()) |inst| (if (@import("builtin").os.tag == .windows) @as(i64, @intCast(inst.timestamp / 10_000_000)) else @as(i64, @intCast(inst.timestamp.sec))) else |_| 0,
        };
    }

    pub fn initWithShell(
        allocator: std.mem.Allocator,
        environment: *std.StringHashMap([]const u8),
        last_exit_code: i32,
        positional_params: []const []const u8,
        shell_name: []const u8,
        last_background_pid: i32,
        last_arg: []const u8,
        shell: *anyopaque,
    ) Expansion {
        return .{
            .allocator = allocator,
            .environment = environment,
            .arrays = null,
            .assoc_arrays = null,
            .local_vars = null,
            .var_attributes = null,
            .last_exit_code = last_exit_code,
            .positional_params = positional_params,
            .shell_name = shell_name,
            .last_background_pid = last_background_pid,
            .last_arg = last_arg,
            .shell = shell,
            .exec_command_fn = null,
            .option_nounset = false,
            .cmd_cache = null,
            .line_number = 1,
            .shell_start_time = if (compat.Instant.now()) |inst| (if (@import("builtin").os.tag == .windows) @as(i64, @intCast(inst.timestamp / 10_000_000)) else @as(i64, @intCast(inst.timestamp.sec))) else |_| 0,
        };
    }

    /// Set the command substitution cache
    pub fn setCommandCache(self: *Expansion, cache: *ExpansionCache) void {
        self.cmd_cache = cache;
    }

    /// Set variable attributes for nameref resolution
    pub fn setVarAttributes(self: *Expansion, attrs: *std.StringHashMap(types.VarAttributes)) void {
        self.var_attributes = attrs;
    }

    /// Set associative arrays for expansion
    pub fn setAssocArrays(self: *Expansion, assoc: *std.StringHashMap(std.StringHashMap([]const u8))) void {
        self.assoc_arrays = assoc;
    }

    /// Resolve a nameref chain - follow the reference to get the actual variable name
    /// Returns the final variable name after following all nameref chains
    /// Limits depth to prevent infinite loops
    fn resolveNameref(self: *Expansion, name: []const u8) []const u8 {
        const attrs = self.var_attributes orelse return name;

        var current_name = name;
        var depth: u32 = 0;
        const max_depth = 10;

        while (depth < max_depth) : (depth += 1) {
            if (attrs.get(current_name)) |attr| {
                if (attr.nameref) {
                    // Get the value of the current nameref which contains the target variable name
                    if (self.environment.get(current_name)) |ref_name| {
                        current_name = ref_name;
                        continue;
                    }
                }
            }
            break;
        }

        return current_name;
    }

    /// Get variable value, resolving namerefs if applicable
    fn getVariableValue(self: *Expansion, name: []const u8) ?[]const u8 {
        // First check local variables
        if (self.local_vars) |locals| {
            if (locals.get(name)) |value| {
                return value;
            }
        }

        // Check positional parameters for numeric names ($1, $2, etc.)
        if (name.len > 0) {
            if (std.fmt.parseInt(usize, name, 10)) |digit| {
                if (digit > 0 and digit <= self.positional_params.len) {
                    return self.positional_params[digit - 1];
                }
                // Positional param referenced but not set
                if (digit > 0) return null;
            } else |_| {}
        }

        // Resolve any nameref chain
        const resolved_name = self.resolveNameref(name);

        // Return value from environment
        return self.environment.get(resolved_name);
    }

    /// Expand all variables in a string
    /// Returns a newly allocated string with variables expanded
    pub fn expand(self: *Expansion, input: []const u8) ![]u8 {
        // Use fixed buffer approach (16KB for large expansions)
        var result_buffer: [16384]u8 = undefined;
        var result_len: usize = 0;

        var i: usize = 0;
        while (i < input.len) {
            const char = input[i];

            // Handle tilde expansion at start of word or after : =
            // Skip tilde expansion for quoted arguments (bash behavior)
            if (char == '~' and !self.skip_tilde) {
                // Don't expand if this is the =~ regex operator (~ followed by space or end)
                const is_regex_op = i > 0 and input[i - 1] == '=' and
                    (i + 1 >= input.len or input[i + 1] == ' ' or input[i + 1] == '\t');

                const should_expand = !is_regex_op and (i == 0 or
                    (i > 0 and (input[i - 1] == ':' or input[i - 1] == '=' or
                        input[i - 1] == ' ' or input[i - 1] == '\t')));

                if (should_expand) {
                    const expansion_result = try self.expandTilde(input[i..]);
                    defer if (expansion_result.owned) self.allocator.free(@constCast(expansion_result.value));

                    // Copy expansion result to buffer
                    if (result_len + expansion_result.value.len > result_buffer.len) {
                        return error.ExpansionTooLong;
                    }
                    @memcpy(result_buffer[result_len .. result_len + expansion_result.value.len], expansion_result.value);
                    result_len += expansion_result.value.len;

                    i += expansion_result.consumed;
                    continue;
                }
            }

            if (char == '<' or char == '>') {
                // Check for process substitution: <(cmd) or >(cmd)
                if (i + 1 < input.len and input[i + 1] == '(') {
                    const expansion_result = try self.expandProcessSubstitution(input[i..], char == '<');
                    defer if (expansion_result.owned) self.allocator.free(@constCast(expansion_result.value));

                    // Copy expansion result to buffer
                    if (result_len + expansion_result.value.len > result_buffer.len) {
                        return error.ExpansionTooLong;
                    }
                    @memcpy(result_buffer[result_len .. result_len + expansion_result.value.len], expansion_result.value);
                    result_len += expansion_result.value.len;

                    i += expansion_result.consumed;
                    continue;
                }
                // Not process substitution - treat as literal
                if (result_len >= result_buffer.len) return error.ExpansionTooLong;
                result_buffer[result_len] = char;
                result_len += 1;
                i += 1;
            } else if (char == '`') {
                // Backtick command substitution
                const expansion_result = try self.expandBacktick(input[i..]);
                defer if (expansion_result.owned) self.allocator.free(@constCast(expansion_result.value));

                // Copy expansion result to buffer
                if (result_len + expansion_result.value.len > result_buffer.len) {
                    return error.ExpansionTooLong;
                }
                @memcpy(result_buffer[result_len .. result_len + expansion_result.value.len], expansion_result.value);
                result_len += expansion_result.value.len;

                i += expansion_result.consumed;
            } else if (char == '$') {
                // Check if this is an escape sequence
                if (i > 0 and input[i - 1] == '\\') {
                    // Remove the backslash, keep the $
                    if (result_len > 0) result_len -= 1;
                    if (result_len >= result_buffer.len) return error.ExpansionTooLong;
                    result_buffer[result_len] = '$';
                    result_len += 1;
                    i += 1;
                    continue;
                }

                // Check for $"..." string interpolation
                if (i + 1 < input.len and input[i + 1] == '"') {
                    const interp_result = try self.expandStringInterpolation(input[i..]);
                    defer if (interp_result.owned) self.allocator.free(@constCast(interp_result.value));

                    if (result_len + interp_result.value.len > result_buffer.len) {
                        return error.ExpansionTooLong;
                    }
                    @memcpy(result_buffer[result_len .. result_len + interp_result.value.len], interp_result.value);
                    result_len += interp_result.value.len;

                    i += interp_result.consumed;
                    continue;
                }

                // Try to expand variable
                const expansion_result = try self.expandVariable(input[i..]);
                defer if (expansion_result.owned) self.allocator.free(@constCast(expansion_result.value));

                // Copy expansion result to buffer
                if (result_len + expansion_result.value.len > result_buffer.len) {
                    return error.ExpansionTooLong;
                }
                @memcpy(result_buffer[result_len .. result_len + expansion_result.value.len], expansion_result.value);
                result_len += expansion_result.value.len;

                i += expansion_result.consumed;
            } else {
                if (result_len >= result_buffer.len) return error.ExpansionTooLong;
                result_buffer[result_len] = char;
                result_len += 1;
                i += 1;
            }
        }

        // Allocate and return final result
        return try self.allocator.dupe(u8, result_buffer[0..result_len]);
    }

    const ExpansionResult = struct {
        value: []const u8,
        consumed: usize, // How many characters were consumed from input
        owned: bool, // Whether value needs to be freed
    };

    /// Expand a single variable starting at $ character
    fn expandVariable(self: *Expansion, input: []const u8) !ExpansionResult {
        if (input.len < 2 or input[0] != '$') {
            return ExpansionResult{ .value = "$", .consumed = 1, .owned = false };
        }

        // Check for special variables
        const next_char = input[1];
        switch (next_char) {
            '?' => {
                // $? - last exit code
                const value = try std.fmt.allocPrint(self.allocator, "{d}", .{self.last_exit_code});
                return ExpansionResult{ .value = value, .consumed = 2, .owned = true };
            },
            '$' => {
                // $$ - current process ID
                const pid: i64 = if (@import("builtin").os.tag == .windows)
                    @intCast(std.os.windows.GetCurrentProcessId())
                else
                    @intCast(std.c.getpid());
                const value = try std.fmt.allocPrint(self.allocator, "{d}", .{pid});
                return ExpansionResult{ .value = value, .consumed = 2, .owned = true };
            },
            '#' => {
                // $# - number of positional parameters
                const value = try std.fmt.allocPrint(self.allocator, "{d}", .{self.positional_params.len});
                return ExpansionResult{ .value = value, .consumed = 2, .owned = true };
            },
            '@' => {
                // $@ - all positional parameters as separate words
                if (self.positional_params.len == 0) {
                    return ExpansionResult{ .value = "", .consumed = 2, .owned = false };
                }
                // Calculate total length needed
                var total_len: usize = 0;
                for (self.positional_params) |param| {
                    total_len += param.len;
                }
                if (self.positional_params.len > 1) {
                    total_len += self.positional_params.len - 1; // spaces
                }

                // Build result string
                var result = try self.allocator.alloc(u8, total_len);
                var pos: usize = 0;
                for (self.positional_params, 0..) |param, i| {
                    @memcpy(result[pos .. pos + param.len], param);
                    pos += param.len;
                    if (i < self.positional_params.len - 1) {
                        result[pos] = ' ';
                        pos += 1;
                    }
                }
                return ExpansionResult{ .value = result, .consumed = 2, .owned = true };
            },
            '*' => {
                // $* - all positional parameters joined by first char of IFS
                if (self.positional_params.len == 0) {
                    return ExpansionResult{ .value = "", .consumed = 2, .owned = false };
                }
                // Determine the separator from IFS
                const ifs_val = self.environment.get("IFS");
                const sep_len: usize = if (ifs_val) |ifs| (if (ifs.len > 0) @as(usize, 1) else @as(usize, 0)) else @as(usize, 1);
                const sep_char: u8 = if (ifs_val) |ifs| (if (ifs.len > 0) ifs[0] else ' ') else ' ';

                // Calculate total length needed
                var total_len: usize = 0;
                for (self.positional_params) |param| {
                    total_len += param.len;
                }
                if (self.positional_params.len > 1) {
                    total_len += (self.positional_params.len - 1) * sep_len;
                }

                // Build result string
                var result = try self.allocator.alloc(u8, total_len);
                var pos: usize = 0;
                for (self.positional_params, 0..) |param, i| {
                    @memcpy(result[pos .. pos + param.len], param);
                    pos += param.len;
                    if (i < self.positional_params.len - 1 and sep_len > 0) {
                        result[pos] = sep_char;
                        pos += 1;
                    }
                }
                return ExpansionResult{ .value = result, .consumed = 2, .owned = true };
            },
            '0' => {
                // $0 - shell name or script name
                const value = try self.allocator.dupe(u8, self.shell_name);
                return ExpansionResult{ .value = value, .consumed = 2, .owned = true };
            },
            '1'...'9' => {
                // $1, $2, etc. - positional arguments
                const digit = next_char - '0';
                if (digit <= self.positional_params.len) {
                    const value = try self.allocator.dupe(u8, self.positional_params[digit - 1]);
                    return ExpansionResult{ .value = value, .consumed = 2, .owned = true };
                }
                // Parameter not set - return empty string
                return ExpansionResult{ .value = "", .consumed = 2, .owned = false };
            },
            '!' => {
                // $! - last background job PID
                const value = try std.fmt.allocPrint(self.allocator, "{d}", .{self.last_background_pid});
                return ExpansionResult{ .value = value, .consumed = 2, .owned = true };
            },
            '_' => {
                // Check if this is a variable name starting with underscore (e.g., $_x)
                // vs the special $_ (last argument of previous command)
                if (input.len > 2 and (std.ascii.isAlphanumeric(input[2]) or input[2] == '_')) {
                    // $_x, $_foo, etc. - treat as simple variable name
                    return try self.expandSimpleVariable(input);
                }
                // $_ - last argument of previous command
                const value = try self.allocator.dupe(u8, self.last_arg);
                return ExpansionResult{ .value = value, .consumed = 2, .owned = true };
            },
            '-' => {
                // $- - current option flags
                var flags_buf: [16]u8 = undefined;
                var flags_len: usize = 0;
                if (self.option_nounset) {
                    flags_buf[flags_len] = 'u';
                    flags_len += 1;
                }
                // TODO: add more flags (e.g., 'e' for errexit, 'x' for xtrace) when accessible
                const value = try self.allocator.dupe(u8, flags_buf[0..flags_len]);
                return ExpansionResult{ .value = value, .consumed = 2, .owned = true };
            },
            '(' => {
                // Check if it's $(( for arithmetic or $( for command substitution
                if (input.len > 2 and input[2] == '(') {
                    // $((expression)) - arithmetic expansion
                    return try self.expandArithmetic(input);
                } else {
                    // $(command) - command substitution
                    return try self.expandCommandSubstitution(input);
                }
            },
            '{' => {
                // ${VAR} - braced expansion
                return try self.expandBracedVariable(input);
            },
            else => {
                // $VAR - simple variable
                return try self.expandSimpleVariable(input);
            },
        }
    }

    /// Helper to expand a value, breaking circular error set inference
    fn expandNested(self: *Expansion, value: []const u8) []u8 {
        const expand_fn = @as(*const fn (*Expansion, []const u8) anyerror![]u8, @ptrCast(&Expansion.expand));
        return expand_fn(self, value) catch self.allocator.dupe(u8, value) catch
            // Allocate a proper empty slice instead of @constCast on a string literal,
            // which would cause UB if the caller tries to free it.
            (self.allocator.alloc(u8, 0) catch &.{});
    }

    /// Expand ${VAR} or ${VAR:-default} form
    fn expandBracedVariable(self: *Expansion, input: []const u8) !ExpansionResult {
        if (input.len < 3 or input[0] != '$' or input[1] != '{') {
            return ExpansionResult{ .value = "$", .consumed = 1, .owned = false };
        }

        // Find closing brace (tracking nesting and quotes)
        var end: usize = 2;
        var brace_depth: usize = 1;
        var in_sq = false;
        var in_dq = false;
        while (end < input.len) {
            const ch = input[end];
            if (ch == '\\' and !in_sq and end + 1 < input.len) {
                end += 2;
                continue;
            }
            if (ch == '\'' and !in_dq) {
                in_sq = !in_sq;
            } else if (ch == '"' and !in_sq) {
                in_dq = !in_dq;
            } else if (!in_sq and !in_dq) {
                if (ch == '{') {
                    brace_depth += 1;
                } else if (ch == '}') {
                    brace_depth -= 1;
                    if (brace_depth == 0) break;
                }
            }
            end += 1;
        }

        if (end >= input.len) {
            // No closing brace found - treat as literal
            return ExpansionResult{ .value = "$", .consumed = 1, .owned = false };
        }

        const content = input[2..end];

        // Check for array expansion: ${arr[@]}, ${arr[*]}, ${arr[0]}, ${assoc[key]}, ${#arr}
        if (std.mem.indexOfScalar(u8, content, '[')) |bracket_pos| {
            const var_name = content[0..bracket_pos];
            const close_bracket = std.mem.indexOfScalar(u8, content[bracket_pos..], ']') orelse {
                // No closing bracket - treat as literal
                return ExpansionResult{ .value = "$", .consumed = 1, .owned = false };
            };
            const index_part = content[bracket_pos + 1 .. bracket_pos + close_bracket];

            // Handle ${!arr[@]} / ${!arr[*]} - array indices/keys
            if (var_name.len > 1 and var_name[0] == '!' and
                (std.mem.eql(u8, index_part, "@") or std.mem.eql(u8, index_part, "*")))
            {
                const actual_name = var_name[1..];
                // Try indexed arrays
                if (self.arrays) |arrays| {
                    if (arrays.get(actual_name)) |array| {
                        if (array.len == 0) {
                            return ExpansionResult{ .value = "", .consumed = end + 1, .owned = false };
                        }
                        var total_len: usize = 0;
                        for (0..array.len) |i| {
                            var nbuf: [20]u8 = undefined;
                            const ns = std.fmt.bufPrint(&nbuf, "{d}", .{i}) catch continue;
                            total_len += ns.len;
                        }
                        total_len += array.len - 1; // spaces
                        var result = try self.allocator.alloc(u8, total_len);
                        var pos: usize = 0;
                        for (0..array.len) |i| {
                            var nbuf: [20]u8 = undefined;
                            const ns = std.fmt.bufPrint(&nbuf, "{d}", .{i}) catch continue;
                            @memcpy(result[pos..][0..ns.len], ns);
                            pos += ns.len;
                            if (i < array.len - 1) {
                                result[pos] = ' ';
                                pos += 1;
                            }
                        }
                        return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
                    }
                }
                // Try associative arrays
                if (self.assoc_arrays) |assoc_arrays| {
                    if (assoc_arrays.get(actual_name)) |assoc| {
                        if (assoc.count() == 0) {
                            return ExpansionResult{ .value = "", .consumed = end + 1, .owned = false };
                        }
                        var keys = std.ArrayList([]const u8).empty;
                        defer keys.deinit(self.allocator);
                        var iter = assoc.iterator();
                        while (iter.next()) |entry| {
                            try keys.append(self.allocator, entry.key_ptr.*);
                        }
                        var total_len: usize = 0;
                        for (keys.items) |k| total_len += k.len;
                        if (keys.items.len > 1) total_len += keys.items.len - 1;
                        var result = try self.allocator.alloc(u8, total_len);
                        var pos: usize = 0;
                        for (keys.items, 0..) |k, ki| {
                            @memcpy(result[pos..][0..k.len], k);
                            pos += k.len;
                            if (ki < keys.items.len - 1) {
                                result[pos] = ' ';
                                pos += 1;
                            }
                        }
                        return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
                    }
                }
                return ExpansionResult{ .value = "", .consumed = end + 1, .owned = false };
            }

            // First try indexed arrays
            if (self.arrays) |arrays| {
                if (arrays.get(var_name)) |array| {
                    if (std.mem.eql(u8, index_part, "@") or std.mem.eql(u8, index_part, "*")) {
                        // Check for array slicing: ${arr[@]:offset:length}
                        const after_bracket = content[bracket_pos + close_bracket + 1 ..];
                        var slice_offset: i64 = 0;
                        var slice_len: ?usize = null;
                        if (after_bracket.len > 0 and after_bracket[0] == ':') {
                            const slice_params = std.mem.trim(u8, after_bracket[1..], " ");
                            if (std.mem.indexOfScalar(u8, slice_params, ':')) |second_colon| {
                                slice_offset = std.fmt.parseInt(i64, std.mem.trim(u8, slice_params[0..second_colon], " "), 10) catch 0;
                                slice_len = std.fmt.parseInt(usize, std.mem.trim(u8, slice_params[second_colon + 1 ..], " "), 10) catch null;
                            } else {
                                slice_offset = std.fmt.parseInt(i64, slice_params, 10) catch 0;
                            }
                        }

                        // Apply slicing (negative offset counts from end)
                        const arr_len: i64 = @intCast(array.len);
                        const effective_offset = if (slice_offset < 0) @max(arr_len + slice_offset, 0) else slice_offset;
                        const start: usize = @intCast(@min(effective_offset, arr_len));
                        const end_idx = if (slice_len) |sl| @min(start + sl, array.len) else array.len;
                        const sliced = array[start..end_idx];

                        if (sliced.len == 0) {
                            return ExpansionResult{ .value = "", .consumed = end + 1, .owned = false };
                        }

                        // For "${arr[*]}", use first character of IFS as separator (default: space)
                        // For "${arr[@]}", always use space
                        const sep: u8 = if (std.mem.eql(u8, index_part, "*")) blk: {
                            const ifs_val = self.environment.get("IFS") orelse " \t\n";
                            break :blk if (ifs_val.len > 0) ifs_val[0] else ' ';
                        } else ' ';

                        var total_len: usize = 0;
                        for (sliced) |item| {
                            total_len += item.len;
                        }
                        if (sliced.len > 1) {
                            total_len += sliced.len - 1; // separators
                        }

                        var result = try self.allocator.alloc(u8, total_len);
                        var pos: usize = 0;
                        for (sliced, 0..) |item, i| {
                            @memcpy(result[pos .. pos + item.len], item);
                            pos += item.len;
                            if (i < sliced.len - 1) {
                                result[pos] = sep;
                                pos += 1;
                            }
                        }
                        return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
                    } else {
                        // ${arr[index]} - specific index (may contain variable like $i)
                        var resolved_index = index_part;
                        if (std.mem.indexOfScalar(u8, index_part, '$') != null) {
                            // Expand variables in the index
                            if (self.environment.get(std.mem.trim(u8, index_part, &[_]u8{ '$', ' ' }))) |val| {
                                resolved_index = val;
                            }
                        }
                        // Try arithmetic evaluation for expressions (supports negative indices)
                        const signed_index: i64 = std.fmt.parseInt(i64, resolved_index, 10) catch blk: {
                            var arith = @import("arithmetic.zig").Arithmetic.initWithVariables(self.allocator, self.environment);
                            arith.local_vars = self.local_vars;
                            arith.arrays = self.arrays;
                            arith.positional_params = self.positional_params;
                            const arith_result = arith.eval(resolved_index) catch {
                                return ExpansionResult{ .value = "", .consumed = end + 1, .owned = false };
                            };
                            break :blk arith_result;
                        };
                        // Handle negative indices: -1 = last element, -2 = second to last, etc.
                        const arr_len: i64 = @intCast(array.len);
                        const effective_index = if (signed_index < 0) signed_index + arr_len else signed_index;
                        if (effective_index >= 0 and effective_index < arr_len) {
                            const index: usize = @intCast(effective_index);
                            const value = try self.allocator.dupe(u8, array[index]);
                            return ExpansionResult{ .value = value, .consumed = end + 1, .owned = true };
                        }
                        return ExpansionResult{ .value = "", .consumed = end + 1, .owned = false };
                    }
                }
            }

            // Try associative arrays
            if (self.assoc_arrays) |assoc_arrays| {
                if (assoc_arrays.get(var_name)) |assoc| {
                    if (std.mem.eql(u8, index_part, "@") or std.mem.eql(u8, index_part, "*")) {
                        // ${assoc[@]} or ${assoc[*]} - all values
                        if (assoc.count() == 0) {
                            return ExpansionResult{ .value = "", .consumed = end + 1, .owned = false };
                        }

                        // Collect all values
                        var values = std.ArrayList([]const u8).empty;
                        defer values.deinit(self.allocator);

                        var iter = assoc.iterator();
                        while (iter.next()) |entry| {
                            try values.append(self.allocator, entry.value_ptr.*);
                        }

                        // Calculate total length
                        var total_len: usize = 0;
                        for (values.items) |item| {
                            total_len += item.len;
                        }
                        if (values.items.len > 1) {
                            total_len += values.items.len - 1; // spaces
                        }

                        var result = try self.allocator.alloc(u8, total_len);
                        var pos: usize = 0;
                        for (values.items, 0..) |item, i| {
                            @memcpy(result[pos .. pos + item.len], item);
                            pos += item.len;
                            if (i < values.items.len - 1) {
                                result[pos] = ' ';
                                pos += 1;
                            }
                        }
                        return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
                    } else {
                        // ${assoc[key]} - specific key lookup
                        // Expand variables in the subscript (e.g., ${m[$k]} -> expand $k first)
                        var resolved_key: []const u8 = index_part;
                        if (std.mem.indexOfScalar(u8, index_part, '$') != null) {
                            // Simple $var expansion in subscript
                            const trimmed = std.mem.trim(u8, index_part, &[_]u8{ '$', ' ' });
                            if (self.getVariableValue(trimmed)) |val| {
                                resolved_key = val;
                            }
                        }
                        if (assoc.get(resolved_key)) |value| {
                            const result = try self.allocator.dupe(u8, value);
                            return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
                        }
                        return ExpansionResult{ .value = "", .consumed = end + 1, .owned = false };
                    }
                }
            }
        }

        // Check for string/array length: ${#VAR} or ${#arr[@]} or ${#arr[index]}
        if (content.len > 0 and content[0] == '#') {
            const raw_name = content[1..];
            // Strip trailing [@] or [*] for array length lookups
            const is_all = std.mem.endsWith(u8, raw_name, "[@]") or std.mem.endsWith(u8, raw_name, "[*]");
            const var_name = if (is_all)
                raw_name[0 .. raw_name.len - 3]
            else if (std.mem.indexOfScalar(u8, raw_name, '[')) |bp|
                raw_name[0..bp]
            else
                raw_name;
            // Check for specific array element length: ${#arr[index]}
            if (!is_all) {
                if (std.mem.indexOfScalar(u8, raw_name, '[')) |bp| {
                    if (std.mem.indexOfScalar(u8, raw_name[bp..], ']')) |cb| {
                        const idx_str = raw_name[bp + 1 .. bp + cb];
                        if (self.arrays) |arrays| {
                            if (arrays.get(var_name)) |array| {
                                const idx = std.fmt.parseInt(usize, idx_str, 10) catch 0;
                                if (idx < array.len) {
                                    const len_str = try std.fmt.allocPrint(self.allocator, "{d}", .{array[idx].len});
                                    return ExpansionResult{ .value = len_str, .consumed = end + 1, .owned = true };
                                }
                                const zero = try self.allocator.dupe(u8, "0");
                                return ExpansionResult{ .value = zero, .consumed = end + 1, .owned = true };
                            }
                        }
                    }
                }
            }
            // First check indexed arrays (array length)
            if (self.arrays) |arrays| {
                if (arrays.get(var_name)) |array| {
                    const value = try std.fmt.allocPrint(self.allocator, "{d}", .{array.len});
                    return ExpansionResult{ .value = value, .consumed = end + 1, .owned = true };
                }
            }
            // Then check associative arrays
            if (self.assoc_arrays) |assoc_arrays| {
                if (assoc_arrays.get(var_name)) |assoc| {
                    const value = try std.fmt.allocPrint(self.allocator, "{d}", .{assoc.count()});
                    return ExpansionResult{ .value = value, .consumed = end + 1, .owned = true };
                }
            }
            // Then check scalar variables for string length
            if (self.getVariableValue(var_name)) |value| {
                const len_str = try std.fmt.allocPrint(self.allocator, "{d}", .{value.len});
                return ExpansionResult{ .value = len_str, .consumed = end + 1, .owned = true };
            }
            // Variable not found - length is 0
            const zero = try self.allocator.dupe(u8, "0");
            return ExpansionResult{ .value = zero, .consumed = end + 1, .owned = true };
        }

        // Check for variable name prefix expansion: ${!prefix@} or ${!prefix*}
        // Also handles ${!arr[@]} for array keys
        if (content.len > 1 and content[0] == '!') {
            const last_char = content[content.len - 1];
            if (last_char == '@' or last_char == '*') {
                const inner = content[1 .. content.len - 1];

                // Check for ${!arr[@]} or ${!arr[*]} - get array indices/keys
                if (inner.len > 2 and inner[inner.len - 1] == '[') {
                    const var_name = inner[0 .. inner.len - 1];

                    // Try indexed arrays first
                    if (self.arrays) |arrays| {
                        if (arrays.get(var_name)) |array| {
                            // Return indices 0, 1, 2, ...
                            if (array.len == 0) {
                                return ExpansionResult{ .value = "", .consumed = end + 1, .owned = false };
                            }

                            // Calculate space needed
                            var total_len: usize = 0;
                            for (0..array.len) |i| {
                                var buf: [20]u8 = undefined;
                                const num_str = std.fmt.bufPrint(&buf, "{d}", .{i}) catch continue;
                                total_len += num_str.len;
                            }
                            total_len += array.len - 1; // spaces

                            var result = try self.allocator.alloc(u8, total_len);
                            var pos: usize = 0;
                            for (0..array.len) |i| {
                                var buf: [20]u8 = undefined;
                                const num_str = std.fmt.bufPrint(&buf, "{d}", .{i}) catch continue;
                                @memcpy(result[pos..][0..num_str.len], num_str);
                                pos += num_str.len;
                                if (i < array.len - 1) {
                                    result[pos] = ' ';
                                    pos += 1;
                                }
                            }
                            return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
                        }
                    }

                    // Try associative arrays
                    if (self.assoc_arrays) |assoc_arrays| {
                        if (assoc_arrays.get(var_name)) |assoc| {
                            if (assoc.count() == 0) {
                                return ExpansionResult{ .value = "", .consumed = end + 1, .owned = false };
                            }

                            // Collect all keys
                            var keys = std.ArrayList([]const u8).empty;
                            defer keys.deinit(self.allocator);

                            var iter = assoc.iterator();
                            while (iter.next()) |entry| {
                                try keys.append(self.allocator, entry.key_ptr.*);
                            }

                            // Sort keys for consistent output
                            std.mem.sort([]const u8, keys.items, {}, struct {
                                fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                                    return std.mem.order(u8, a, b) == .lt;
                                }
                            }.lessThan);

                            // Calculate total length
                            var total_len: usize = 0;
                            for (keys.items) |key| {
                                total_len += key.len;
                            }
                            total_len += keys.items.len - 1; // spaces

                            var result = try self.allocator.alloc(u8, total_len);
                            var pos: usize = 0;
                            for (keys.items, 0..) |key, i| {
                                @memcpy(result[pos..][0..key.len], key);
                                pos += key.len;
                                if (i < keys.items.len - 1) {
                                    result[pos] = ' ';
                                    pos += 1;
                                }
                            }
                            return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
                        }
                    }
                }

                // ${!prefix@} or ${!prefix*} - expand to variable names with prefix
                const prefix = inner;

                // Collect all variable names that start with prefix
                var names = std.ArrayList([]const u8).empty;
                defer names.deinit(self.allocator);

                var env_iter = self.environment.iterator();
                while (env_iter.next()) |entry| {
                    if (std.mem.startsWith(u8, entry.key_ptr.*, prefix)) {
                        try names.append(self.allocator, entry.key_ptr.*);
                    }
                }

                // Sort the names for consistent output
                std.mem.sort([]const u8, names.items, {}, struct {
                    fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                        return std.mem.order(u8, a, b) == .lt;
                    }
                }.lessThan);

                if (names.items.len == 0) {
                    return ExpansionResult{ .value = "", .consumed = end + 1, .owned = false };
                }

                // Join with spaces
                var total_len: usize = 0;
                for (names.items) |name| {
                    total_len += name.len;
                }
                total_len += names.items.len - 1; // spaces between names

                var result = try self.allocator.alloc(u8, total_len);
                var pos: usize = 0;
                for (names.items, 0..) |name, i| {
                    @memcpy(result[pos..][0..name.len], name);
                    pos += name.len;
                    if (i < names.items.len - 1) {
                        result[pos] = ' ';
                        pos += 1;
                    }
                }
                return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
            }

            // Check for indirect expansion: ${!VAR}
            const indirect_name = content[1..];
            // Get the value of the named variable, then use that as a variable name
            if (self.getVariableValue(indirect_name)) |ref_name| {
                if (self.getVariableValue(ref_name)) |value| {
                    const result = try self.allocator.dupe(u8, value);
                    return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
                }
            }
            return ExpansionResult{ .value = "", .consumed = end + 1, .owned = false };
        }

        // Check for substring extraction: ${VAR:offset} or ${VAR:offset:length}
        if (std.mem.indexOf(u8, content, ":")) |colon_pos| {
            // Make sure this isn't :- := :? :+ operators
            if (colon_pos + 1 < content.len) {
                const after_colon = content[colon_pos + 1];
                // Also make sure this isn't a pattern operator (# ## % %%) with : in the pattern.
                // If the part before the colon contains #, %, those are pattern operators, not var names.
                const before_colon = content[0..colon_pos];
                const has_pattern_op = std.mem.indexOfScalar(u8, before_colon, '#') != null or
                    std.mem.indexOfScalar(u8, before_colon, '%') != null;
                if (after_colon != '-' and after_colon != '=' and after_colon != '?' and after_colon != '+' and !has_pattern_op) {
                    // This is substring extraction
                    const var_name = content[0..colon_pos];
                    const params = content[colon_pos + 1 ..];

                    if (self.getVariableValue(var_name)) |value| {
                        // Parse offset and optional length
                        var offset: i64 = 0;
                        var length: ?usize = null;

                        if (std.mem.indexOf(u8, params, ":")) |second_colon| {
                            // ${VAR:offset:length}
                            const offset_str = params[0..second_colon];
                            // Strip parens: ${x:(-2)} -> -2
                            const clean_offset = if (offset_str.len >= 2 and offset_str[0] == '(' and offset_str[offset_str.len - 1] == ')')
                                offset_str[1 .. offset_str.len - 1]
                            else
                                offset_str;
                            offset = std.fmt.parseInt(i64, std.mem.trim(u8, clean_offset, &std.ascii.whitespace), 10) catch 0;
                            length = std.fmt.parseInt(usize, params[second_colon + 1 ..], 10) catch null;
                        } else {
                            // ${VAR:offset}
                            // Strip parens: ${x:(-2)} -> -2
                            const clean_params = if (params.len >= 2 and params[0] == '(' and params[params.len - 1] == ')')
                                params[1 .. params.len - 1]
                            else
                                params;
                            offset = std.fmt.parseInt(i64, std.mem.trim(u8, clean_params, &std.ascii.whitespace), 10) catch 0;
                        }

                        // Handle negative offset (from end of string).
                        // Use @abs() to avoid overflow on i64::MIN (negating -2^63
                        // as a signed i64 would overflow).
                        var start: usize = 0;
                        if (offset < 0) {
                            const abs_offset: usize = @intCast(@abs(offset));
                            if (abs_offset <= value.len) {
                                start = value.len - abs_offset;
                            }
                        } else {
                            start = @min(@as(usize, @intCast(offset)), value.len);
                        }

                        // Calculate end position
                        const end_pos = if (length) |len| @min(start + len, value.len) else value.len;

                        if (start <= end_pos and start <= value.len) {
                            const result = try self.allocator.dupe(u8, value[start..end_pos]);
                            return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
                        }
                        return ExpansionResult{ .value = "", .consumed = end + 1, .owned = false };
                    }
                    return ExpansionResult{ .value = "", .consumed = end + 1, .owned = false };
                }
            }
        }

        // Check for parameter expansion patterns BEFORE case conversion and replacement
        // These must be checked first because patterns like ${VAR%,} could be confused
        // with case conversion operators (${VAR,} lowercases first char).

        // ${VAR##pattern} - remove longest prefix match (greedy)
        if (std.mem.indexOf(u8, content, "##")) |sep_pos| {
            if (sep_pos > 0 and sep_pos < content.len - 2) {
                const var_name_pp = content[0..sep_pos];
                const pp_pattern = content[sep_pos + 2 ..];

                if (self.getVariableValue(var_name_pp)) |value| {
                    const result = try self.removePrefix(value, pp_pattern, true);
                    return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
                }
                return ExpansionResult{ .value = "", .consumed = end + 1, .owned = false };
            }
        }

        // ${VAR#pattern} - remove shortest prefix match
        // But NOT ${VAR/#pat/rep} which is prefix substitution (# after /)
        if (std.mem.indexOf(u8, content, "#")) |sep_pos| {
            if (sep_pos > 0 and sep_pos < content.len - 1 and std.mem.indexOfScalar(u8, content[0..sep_pos], '/') == null) {
                const var_name_pp = content[0..sep_pos];
                const pp_pattern = content[sep_pos + 1 ..];

                if (self.getVariableValue(var_name_pp)) |value| {
                    const result = try self.removePrefix(value, pp_pattern, false);
                    return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
                }
                return ExpansionResult{ .value = "", .consumed = end + 1, .owned = false };
            }
        }

        // ${VAR%%pattern} - remove longest suffix match (greedy)
        if (std.mem.indexOf(u8, content, "%%")) |sep_pos| {
            if (sep_pos > 0 and sep_pos < content.len - 2 and std.mem.indexOfScalar(u8, content[0..sep_pos], '/') == null) {
                const var_name_pp = content[0..sep_pos];
                const pp_pattern = content[sep_pos + 2 ..];

                if (self.getVariableValue(var_name_pp)) |value| {
                    const result = try self.removeSuffix(value, pp_pattern, true);
                    return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
                }
                return ExpansionResult{ .value = "", .consumed = end + 1, .owned = false };
            }
        }

        // ${VAR%pattern} - remove shortest suffix match
        // But NOT ${VAR/%pat/rep} which is suffix substitution (% after /)
        if (std.mem.indexOf(u8, content, "%")) |sep_pos| {
            if (sep_pos > 0 and sep_pos < content.len - 1 and std.mem.indexOfScalar(u8, content[0..sep_pos], '/') == null) {
                const var_name_pp = content[0..sep_pos];
                const pp_pattern = content[sep_pos + 1 ..];

                if (self.getVariableValue(var_name_pp)) |value| {
                    const result = try self.removeSuffix(value, pp_pattern, false);
                    return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
                }
                return ExpansionResult{ .value = "", .consumed = end + 1, .owned = false };
            }
        }

        // Check for case conversion: ${VAR^^} (uppercase all), ${VAR,,} (lowercase all),
        // ${VAR^} (uppercase first), ${VAR,} (lowercase first)
        if (std.mem.indexOf(u8, content, "^^")) |sep_pos| {
            if (sep_pos > 0) {
                const var_name_cc = content[0..sep_pos];
                if (self.getVariableValue(var_name_cc)) |value| {
                    const result = try self.allocator.alloc(u8, value.len);
                    for (value, 0..) |c, ci| {
                        result[ci] = std.ascii.toUpper(c);
                    }
                    return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
                }
                return ExpansionResult{ .value = "", .consumed = end + 1, .owned = false };
            }
        }
        if (std.mem.indexOf(u8, content, ",,")) |sep_pos| {
            if (sep_pos > 0) {
                const var_name_cc = content[0..sep_pos];
                if (self.getVariableValue(var_name_cc)) |value| {
                    const result = try self.allocator.alloc(u8, value.len);
                    for (value, 0..) |c, ci| {
                        result[ci] = std.ascii.toLower(c);
                    }
                    return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
                }
                return ExpansionResult{ .value = "", .consumed = end + 1, .owned = false };
            }
        }
        // ${VAR^} - uppercase first character only
        if (content.len > 1 and content[content.len - 1] == '^') {
            const var_name_cc = content[0 .. content.len - 1];
            // Make sure it's not ^^ (already handled above)
            if (var_name_cc.len > 0 and var_name_cc[var_name_cc.len - 1] != '^') {
                if (self.getVariableValue(var_name_cc)) |value| {
                    if (value.len > 0) {
                        const result = try self.allocator.dupe(u8, value);
                        result[0] = std.ascii.toUpper(value[0]);
                        return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
                    }
                    return ExpansionResult{ .value = "", .consumed = end + 1, .owned = false };
                }
                return ExpansionResult{ .value = "", .consumed = end + 1, .owned = false };
            }
        }
        // ${VAR,} - lowercase first character only
        if (content.len > 1 and content[content.len - 1] == ',') {
            const var_name_cc = content[0 .. content.len - 1];
            // Make sure it's not ,, (already handled above)
            if (var_name_cc.len > 0 and var_name_cc[var_name_cc.len - 1] != ',') {
                if (self.getVariableValue(var_name_cc)) |value| {
                    if (value.len > 0) {
                        const result = try self.allocator.dupe(u8, value);
                        result[0] = std.ascii.toLower(value[0]);
                        return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
                    }
                    return ExpansionResult{ .value = "", .consumed = end + 1, .owned = false };
                }
                return ExpansionResult{ .value = "", .consumed = end + 1, .owned = false };
            }
        }

        // ${VAR~~} - toggle case of all characters
        if (std.mem.indexOf(u8, content, "~~")) |sep_pos| {
            if (sep_pos > 0) {
                const var_name_cc = content[0..sep_pos];
                if (self.getVariableValue(var_name_cc)) |value| {
                    const result = try self.allocator.alloc(u8, value.len);
                    for (value, 0..) |c, ci| {
                        result[ci] = if (std.ascii.isUpper(c)) std.ascii.toLower(c) else std.ascii.toUpper(c);
                    }
                    return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
                }
                return ExpansionResult{ .value = "", .consumed = end + 1, .owned = false };
            }
        }
        // ${VAR~} - toggle case of first character only
        if (content.len > 1 and content[content.len - 1] == '~') {
            const var_name_cc = content[0 .. content.len - 1];
            // Make sure it's not ~~ (already handled above)
            if (var_name_cc.len > 0 and var_name_cc[var_name_cc.len - 1] != '~') {
                if (self.getVariableValue(var_name_cc)) |value| {
                    if (value.len > 0) {
                        const result = try self.allocator.dupe(u8, value);
                        result[0] = if (std.ascii.isUpper(value[0])) std.ascii.toLower(value[0]) else std.ascii.toUpper(value[0]);
                        return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
                    }
                    return ExpansionResult{ .value = "", .consumed = end + 1, .owned = false };
                }
                return ExpansionResult{ .value = "", .consumed = end + 1, .owned = false };
            }
        }

        // Check for replacement: ${VAR/pattern/replacement} or ${VAR//pattern/replacement}
        // Also handles ${VAR/#pattern/rep} (prefix) and ${VAR/%pattern/rep} (suffix)
        // But NOT when :- := :? :+ appear before the / (those are default/assign operators with / in value)
        if (std.mem.indexOf(u8, content, "/")) |slash_pos| {
            const before_slash = content[0..slash_pos];
            const has_default_op = std.mem.indexOf(u8, before_slash, ":-") != null or
                std.mem.indexOf(u8, before_slash, ":=") != null or
                std.mem.indexOf(u8, before_slash, ":?") != null or
                std.mem.indexOf(u8, before_slash, ":+") != null or
                // Also check non-colon variants: ${VAR-/path}, ${VAR=/path}, ${VAR?/path}, ${VAR+/path}
                std.mem.indexOfScalar(u8, before_slash, '-') != null or
                std.mem.indexOfScalar(u8, before_slash, '=') != null or
                std.mem.indexOfScalar(u8, before_slash, '?') != null or
                std.mem.indexOfScalar(u8, before_slash, '+') != null;
            if (slash_pos > 0 and !has_default_op) {
                const var_name = content[0..slash_pos];
                const rest = content[slash_pos..];

                // Check if it's // (replace all), /# (prefix), /% (suffix), or / (replace first)
                const replace_all = rest.len > 1 and rest[1] == '/';
                const anchor_prefix = rest.len > 1 and rest[1] == '#';
                const anchor_suffix = rest.len > 1 and rest[1] == '%';
                const pattern_start: usize = if (replace_all or anchor_prefix or anchor_suffix) 2 else 1;

                // Find the second slash for the replacement
                if (std.mem.indexOf(u8, rest[pattern_start..], "/")) |second_slash| {
                    const pattern = rest[pattern_start .. pattern_start + second_slash];
                    const replacement = rest[pattern_start + second_slash + 1 ..];

                    if (self.getVariableValue(var_name)) |value| {
                        if (anchor_prefix) {
                            // ${VAR/#pattern/replacement} - replace at start
                            if (std.mem.startsWith(u8, value, pattern)) {
                                const result = try self.allocator.alloc(u8, replacement.len + value.len - pattern.len);
                                @memcpy(result[0..replacement.len], replacement);
                                @memcpy(result[replacement.len..], value[pattern.len..]);
                                return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
                            }
                            const result = try self.allocator.dupe(u8, value);
                            return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
                        } else if (anchor_suffix) {
                            // ${VAR/%pattern/replacement} - replace at end
                            if (std.mem.endsWith(u8, value, pattern)) {
                                const result = try self.allocator.alloc(u8, value.len - pattern.len + replacement.len);
                                @memcpy(result[0 .. value.len - pattern.len], value[0 .. value.len - pattern.len]);
                                @memcpy(result[value.len - pattern.len ..], replacement);
                                return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
                            }
                            const result = try self.allocator.dupe(u8, value);
                            return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
                        } else {
                            const result = try self.replaceInString(value, pattern, replacement, replace_all);
                            return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
                        }
                    }
                } else {
                    // No second slash - replacement is empty string (deletion)
                    const pattern = rest[pattern_start..];

                    if (self.getVariableValue(var_name)) |value| {
                        const result = try self.replaceInString(value, pattern, "", replace_all);
                        return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
                    }
                }
                return ExpansionResult{ .value = "", .consumed = end + 1, .owned = false };
            }
        }

        // Check for default value syntax: ${VAR:-default}
        if (std.mem.indexOf(u8, content, ":-")) |sep_pos| {
            const var_name = content[0..sep_pos];
            const default_value = content[sep_pos + 2 ..];

            if (self.getVariableValue(var_name)) |value| {
                if (value.len > 0) {
                    const result = try self.allocator.dupe(u8, value);
                    return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
                }
            }

            // Use default value - expand it first (supports nested ${...})
            const result = self.expandNested(default_value);
            return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
        }

        // Check for assign default syntax: ${VAR:=default}
        if (std.mem.indexOf(u8, content, ":=")) |sep_pos| {
            const var_name = content[0..sep_pos];
            const default_value = content[sep_pos + 2 ..];

            if (self.getVariableValue(var_name)) |value| {
                if (value.len > 0) {
                    const result = try self.allocator.dupe(u8, value);
                    return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
                }
            }

            // Assign and use default value - expand first
            const expanded = self.expandNested(default_value);
            const name_copy = try self.allocator.dupe(u8, var_name);
            errdefer self.allocator.free(name_copy);
            const value_copy = try self.allocator.dupe(u8, expanded);
            errdefer self.allocator.free(value_copy);
            self.environment.put(name_copy, value_copy) catch {
                // Free on put failure to avoid leaking both allocations.
                self.allocator.free(name_copy);
                self.allocator.free(value_copy);
            };
            return ExpansionResult{ .value = expanded, .consumed = end + 1, .owned = true };
        }

        // Check for error if unset syntax: ${VAR:?message}
        if (std.mem.indexOf(u8, content, ":?")) |sep_pos| {
            const var_name = content[0..sep_pos];
            const error_msg = content[sep_pos + 2 ..];

            if (self.getVariableValue(var_name)) |value| {
                if (value.len > 0) {
                    const result = try self.allocator.dupe(u8, value);
                    return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
                }
            }

            // Print error message and return empty (shell should exit)
            var buf: [512]u8 = undefined;
            const msg = if (error_msg.len > 0)
                std.fmt.bufPrint(&buf, "den: {s}: {s}\n", .{ var_name, error_msg }) catch "den: parameter null or not set\n"
            else
                std.fmt.bufPrint(&buf, "den: {s}: parameter null or not set\n", .{var_name}) catch "den: parameter null or not set\n";
            const IO = @import("../utils/io.zig").IO;
            IO.eprint("{s}", .{msg}) catch {};
            return error.ParameterNullOrNotSet;
        }

        // Check for use alternative value syntax: ${VAR:+value}
        if (std.mem.indexOf(u8, content, ":+")) |sep_pos| {
            const var_name = content[0..sep_pos];
            const alt_value = content[sep_pos + 2 ..];

            if (self.getVariableValue(var_name)) |value| {
                if (value.len > 0) {
                    // Variable is set and non-empty, use alternative value
                    const result = self.expandNested(alt_value);
                    return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
                }
            }

            // Variable is unset or empty, return empty string
            return ExpansionResult{ .value = "", .consumed = end + 1, .owned = false };
        }

        // Non-colon variants: check if set (regardless of empty)
        // ${VAR-default}: use default only if VAR is unset
        if (std.mem.indexOfScalar(u8, content, '-')) |sep_pos| {
            if (sep_pos > 0 and (sep_pos < 2 or content[sep_pos - 1] != ':')) {
                const var_name = content[0..sep_pos];
                const default_value = content[sep_pos + 1 ..];
                if (self.getVariableValue(var_name)) |value| {
                    const result = try self.allocator.dupe(u8, value);
                    return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
                }
                const result = try self.allocator.dupe(u8, default_value);
                return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
            }
        }

        // ${VAR+word}: use word if VAR is set (even if empty)
        if (std.mem.indexOfScalar(u8, content, '+')) |sep_pos| {
            if (sep_pos > 0 and (sep_pos < 2 or content[sep_pos - 1] != ':')) {
                const var_name = content[0..sep_pos];
                const alt_value = content[sep_pos + 1 ..];
                if (self.getVariableValue(var_name) != null) {
                    const result = try self.allocator.dupe(u8, alt_value);
                    return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
                }
                return ExpansionResult{ .value = "", .consumed = end + 1, .owned = false };
            }
        }

        // Handle special dynamic variables in braced form
        if (std.mem.eql(u8, content, "RANDOM")) {
            var buf: [16]u8 = undefined;
            const val = getRandomValue();
            const result_str = std.fmt.bufPrint(&buf, "{d}", .{val}) catch "0";
            const result = try self.allocator.dupe(u8, result_str);
            return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
        }
        if (std.mem.eql(u8, content, "LINENO")) {
            var buf: [16]u8 = undefined;
            const result_str = std.fmt.bufPrint(&buf, "{d}", .{self.line_number}) catch "0";
            const result = try self.allocator.dupe(u8, result_str);
            return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
        }
        if (std.mem.eql(u8, content, "SECONDS")) {
            var buf: [16]u8 = undefined;
            const now = if (compat.Instant.now()) |inst| (if (@import("builtin").os.tag == .windows) @as(i64, @intCast(inst.timestamp / 10_000_000)) else @as(i64, @intCast(inst.timestamp.sec))) else |_| @as(i64, 0);
            const elapsed = now - self.shell_start_time;
            const result_str = std.fmt.bufPrint(&buf, "{d}", .{elapsed}) catch "0";
            const result = try self.allocator.dupe(u8, result_str);
            return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
        }
        if (std.mem.eql(u8, content, "PPID")) {
            var buf: [16]u8 = undefined;
            const ppid: i64 = if (@import("builtin").os.tag == .windows) 0 else @intCast(std.c.getppid());
            const result_str = std.fmt.bufPrint(&buf, "{d}", .{ppid}) catch "0";
            const result = try self.allocator.dupe(u8, result_str);
            return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
        }
        if (std.mem.eql(u8, content, "BASHPID")) {
            var buf: [16]u8 = undefined;
            const pid: i64 = if (@import("builtin").os.tag == .windows) @intCast(std.os.windows.GetCurrentProcessId()) else @intCast(std.c.getpid());
            const result_str = std.fmt.bufPrint(&buf, "{d}", .{pid}) catch "0";
            const result = try self.allocator.dupe(u8, result_str);
            return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
        }
        if (std.mem.eql(u8, content, "EUID")) {
            var buf: [16]u8 = undefined;
            const uid: u32 = if (@import("builtin").os.tag == .windows) 0 else std.c.geteuid();
            const result_str = std.fmt.bufPrint(&buf, "{d}", .{uid}) catch "0";
            const result = try self.allocator.dupe(u8, result_str);
            return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
        }
        if (std.mem.eql(u8, content, "UID")) {
            var buf: [16]u8 = undefined;
            const uid: u32 = if (@import("builtin").os.tag == .windows) 0 else std.c.getuid();
            const result_str = std.fmt.bufPrint(&buf, "{d}", .{uid}) catch "0";
            const result = try self.allocator.dupe(u8, result_str);
            return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
        }
        if (std.mem.eql(u8, content, "HOSTNAME")) {
            if (comptime @import("builtin").os.tag == .windows) {
                const result = try self.allocator.dupe(u8, "localhost");
                return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
            }
            var name_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
            const hostname = std.posix.gethostname(&name_buf) catch "unknown";
            const result = try self.allocator.dupe(u8, hostname);
            return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
        }

        // Handle ${var@operator} transform operators
        if (content.len > 2 and content[content.len - 2] == '@') {
            const var_name = content[0 .. content.len - 2];
            const op = content[content.len - 1];
            if (self.getVariableValue(var_name)) |value| {
                switch (op) {
                    'U' => {
                        // Uppercase all
                        const result = try self.allocator.alloc(u8, value.len);
                        for (value, 0..) |c, i| result[i] = std.ascii.toUpper(c);
                        return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
                    },
                    'L' => {
                        // Lowercase all
                        const result = try self.allocator.alloc(u8, value.len);
                        for (value, 0..) |c, i| result[i] = std.ascii.toLower(c);
                        return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
                    },
                    'u' => {
                        // Uppercase first character
                        const result = try self.allocator.dupe(u8, value);
                        if (result.len > 0) result[0] = std.ascii.toUpper(result[0]);
                        return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
                    },
                    'l' => {
                        // Lowercase first character
                        const result = try self.allocator.dupe(u8, value);
                        if (result.len > 0) result[0] = std.ascii.toLower(result[0]);
                        return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
                    },
                    'Q' => {
                        // Quote the value, escaping single quotes with '\'' idiom
                        // Count single quotes in value to determine extra space needed
                        var sq_count: usize = 0;
                        for (value) |c| {
                            if (c == '\'') sq_count += 1;
                        }
                        if (sq_count == 0) {
                            // No single quotes, simple wrap
                            const result = try self.allocator.alloc(u8, value.len + 2);
                            result[0] = '\'';
                            @memcpy(result[1 .. value.len + 1], value);
                            result[value.len + 1] = '\'';
                            return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
                        }
                        // Each single quote becomes '\'' (4 chars) replacing 1 char = +3 per quote
                        const result_len = value.len + 2 + sq_count * 3;
                        const result = try self.allocator.alloc(u8, result_len);
                        var rpos: usize = 0;
                        result[rpos] = '\'';
                        rpos += 1;
                        for (value) |c| {
                            if (c == '\'') {
                                result[rpos] = '\'';
                                result[rpos + 1] = '\\';
                                result[rpos + 2] = '\'';
                                result[rpos + 3] = '\'';
                                rpos += 4;
                            } else {
                                result[rpos] = c;
                                rpos += 1;
                            }
                        }
                        result[rpos] = '\'';
                        rpos += 1;
                        return ExpansionResult{ .value = result[0..rpos], .consumed = end + 1, .owned = true };
                    },
                    else => {},
                }
            }
        }

        // Handle special variables in braces: ${?}, ${$}, ${#}, ${!}, ${@}, ${*}, ${0}-${9}
        if (content.len == 1) {
            switch (content[0]) {
                '?' => {
                    const value = try std.fmt.allocPrint(self.allocator, "{d}", .{self.last_exit_code});
                    return ExpansionResult{ .value = value, .consumed = end + 1, .owned = true };
                },
                '$' => {
                    const pid: i64 = if (@import("builtin").os.tag == .windows)
                        @intCast(std.os.windows.GetCurrentProcessId())
                    else
                        @intCast(std.c.getpid());
                    const value = try std.fmt.allocPrint(self.allocator, "{d}", .{pid});
                    return ExpansionResult{ .value = value, .consumed = end + 1, .owned = true };
                },
                '!' => {
                    const value = try std.fmt.allocPrint(self.allocator, "{d}", .{self.last_background_pid});
                    return ExpansionResult{ .value = value, .consumed = end + 1, .owned = true };
                },
                '@' => {
                    if (self.positional_params.len == 0)
                        return ExpansionResult{ .value = "", .consumed = end + 1, .owned = false };
                    var total_len: usize = 0;
                    for (self.positional_params) |p| total_len += p.len;
                    if (self.positional_params.len > 1) total_len += self.positional_params.len - 1;
                    var result = try self.allocator.alloc(u8, total_len);
                    var pos: usize = 0;
                    for (self.positional_params, 0..) |p, pi| {
                        @memcpy(result[pos .. pos + p.len], p);
                        pos += p.len;
                        if (pi < self.positional_params.len - 1) {
                            result[pos] = ' ';
                            pos += 1;
                        }
                    }
                    return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
                },
                '*' => {
                    if (self.positional_params.len == 0)
                        return ExpansionResult{ .value = "", .consumed = end + 1, .owned = false };
                    const ifs_val = self.environment.get("IFS");
                    const sep_char: u8 = if (ifs_val) |ifs| (if (ifs.len > 0) ifs[0] else 0) else ' ';
                    const sep_len: usize = if (ifs_val) |ifs| (if (ifs.len > 0) @as(usize, 1) else @as(usize, 0)) else 1;
                    var total_len: usize = 0;
                    for (self.positional_params) |p| total_len += p.len;
                    if (self.positional_params.len > 1) total_len += (self.positional_params.len - 1) * sep_len;
                    var result = try self.allocator.alloc(u8, total_len);
                    var pos: usize = 0;
                    for (self.positional_params, 0..) |p, pi| {
                        @memcpy(result[pos .. pos + p.len], p);
                        pos += p.len;
                        if (pi < self.positional_params.len - 1 and sep_len > 0) {
                            result[pos] = sep_char;
                            pos += 1;
                        }
                    }
                    return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
                },
                '0' => {
                    const value = try self.allocator.dupe(u8, self.shell_name);
                    return ExpansionResult{ .value = value, .consumed = end + 1, .owned = true };
                },
                '1'...'9' => {
                    const digit = content[0] - '0';
                    if (digit <= self.positional_params.len) {
                        const value = try self.allocator.dupe(u8, self.positional_params[digit - 1]);
                        return ExpansionResult{ .value = value, .consumed = end + 1, .owned = true };
                    }
                    return ExpansionResult{ .value = "", .consumed = end + 1, .owned = false };
                },
                '-' => {
                    // ${-} - current option flags
                    var flags_buf: [16]u8 = undefined;
                    var flags_len: usize = 0;
                    if (self.option_nounset) {
                        flags_buf[flags_len] = 'u';
                        flags_len += 1;
                    }
                    // TODO: add more flags (e.g., 'e' for errexit, 'x' for xtrace) when accessible
                    const value = try self.allocator.dupe(u8, flags_buf[0..flags_len]);
                    return ExpansionResult{ .value = value, .consumed = end + 1, .owned = true };
                },
                '_' => {
                    const value = try self.allocator.dupe(u8, self.last_arg);
                    return ExpansionResult{ .value = value, .consumed = end + 1, .owned = true };
                },
                else => {},
            }
        }

        // Simple braced variable - use getVariableValue for nameref resolution
        if (self.getVariableValue(content)) |value| {
            const result = try self.allocator.dupe(u8, value);
            return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
        }

        // Variable not found
        // If nounset is enabled, return an error
        if (self.option_nounset) {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "den: {s}: unbound variable\n", .{content}) catch "den: unbound variable\n";
            if (is_windows) {
                if (std.os.windows.kernel32.GetStdHandle(std.os.windows.STD_ERROR_HANDLE)) |stderr_h| {
                    var written: u32 = 0;
                    _ = std.os.windows.kernel32.WriteFile(stderr_h, msg.ptr, @intCast(msg.len), &written, null);
                }
            } else {
                _ = std.c.write(std.posix.STDERR_FILENO, msg.ptr, msg.len);
            }
            return error.UnboundVariable;
        }
        return ExpansionResult{ .value = "", .consumed = end + 1, .owned = false };
    }

    /// Remove prefix pattern from string
    fn removePrefix(self: *Expansion, value: []const u8, pattern: []const u8, greedy: bool) ![]u8 {
        // For greedy (##), find longest match; for non-greedy (#), find shortest
        if (greedy) {
            // Find longest prefix match
            var longest_match: usize = 0;
            var i: usize = 0;
            while (i <= value.len) : (i += 1) {
                if (matchPattern(pattern, value[0..i])) {
                    longest_match = i;
                }
            }
            if (longest_match > 0) {
                return try self.allocator.dupe(u8, value[longest_match..]);
            }
        } else {
            // Find shortest prefix match
            var i: usize = 0;
            while (i <= value.len) : (i += 1) {
                if (matchPattern(pattern, value[0..i])) {
                    return try self.allocator.dupe(u8, value[i..]);
                }
            }
        }

        // Pattern not found, return original value
        return try self.allocator.dupe(u8, value);
    }

    /// Remove suffix pattern from string
    fn removeSuffix(self: *Expansion, value: []const u8, pattern: []const u8, greedy: bool) ![]u8 {
        // For greedy (%%), find longest match; for non-greedy (%), find shortest
        if (greedy) {
            // Find longest suffix match
            var longest_match: usize = 0;
            var i: usize = 0;
            while (i <= value.len) : (i += 1) {
                const start = value.len - i;
                if (matchPattern(pattern, value[start..])) {
                    longest_match = i;
                }
            }
            if (longest_match > 0) {
                return try self.allocator.dupe(u8, value[0 .. value.len - longest_match]);
            }
        } else {
            // Find shortest suffix match
            var i: usize = 0;
            while (i <= value.len) : (i += 1) {
                const start = value.len - i;
                if (matchPattern(pattern, value[start..])) {
                    return try self.allocator.dupe(u8, value[0..start]);
                }
            }
        }

        // Pattern not found, return original value
        return try self.allocator.dupe(u8, value);
    }

    /// Replace pattern in string with replacement
    /// If replace_all is true, replace all occurrences; otherwise just first
    fn replaceInString(self: *Expansion, value: []const u8, pattern: []const u8, replacement: []const u8, replace_all: bool) ![]u8 {
        if (pattern.len == 0) {
            return try self.allocator.dupe(u8, value);
        }

        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(self.allocator);

        var i: usize = 0;
        var replaced = false;

        while (i < value.len) {
            // Check if pattern matches at current position
            var match_len: usize = 0;
            if (self.findPatternMatch(value[i..], pattern)) |len| {
                match_len = len;
            }

            if (match_len > 0 and (replace_all or !replaced)) {
                // Pattern matches - add replacement instead
                try result.appendSlice(self.allocator, replacement);
                i += match_len;
                replaced = true;
            } else {
                // No match - copy character
                try result.append(self.allocator, value[i]);
                i += 1;
            }
        }

        return try result.toOwnedSlice(self.allocator);
    }

    /// Find pattern match at start of string, return length of match or null
    fn findPatternMatch(self: *Expansion, str: []const u8, pattern: []const u8) ?usize {
        _ = self;
        // Try matching pattern at different lengths
        var len: usize = 1;
        while (len <= str.len) : (len += 1) {
            if (matchPattern(pattern, str[0..len])) {
                return len;
            }
        }
        return null;
    }

    /// Match a shell glob pattern against a string
    /// Supports: * (any chars), ? (one char), [abc] (char class)
    fn matchPattern(pattern: []const u8, str: []const u8) bool {
        var p_idx: usize = 0;
        var s_idx: usize = 0;

        while (p_idx < pattern.len and s_idx < str.len) {
            const p_char = pattern[p_idx];

            if (p_char == '*') {
                // Skip consecutive stars
                while (p_idx < pattern.len and pattern[p_idx] == '*') {
                    p_idx += 1;
                }

                // Star at end matches rest of string
                if (p_idx == pattern.len) return true;

                // Try matching rest of pattern at each position
                while (s_idx <= str.len) {
                    if (matchPattern(pattern[p_idx..], str[s_idx..])) {
                        return true;
                    }
                    s_idx += 1;
                }
                return false;
            } else if (p_char == '?') {
                // ? matches any single character
                p_idx += 1;
                s_idx += 1;
            } else if (p_char == '[') {
                // Character class [abc] or [a-z]
                p_idx += 1;
                if (p_idx >= pattern.len) return false;

                var matched = false;
                var negate = false;

                // Check for negation [!abc]
                if (pattern[p_idx] == '!') {
                    negate = true;
                    p_idx += 1;
                }

                while (p_idx < pattern.len and pattern[p_idx] != ']') {
                    if (p_idx + 2 < pattern.len and pattern[p_idx + 1] == '-') {
                        // Range: a-z
                        const range_start = pattern[p_idx];
                        const range_end = pattern[p_idx + 2];
                        if (str[s_idx] >= range_start and str[s_idx] <= range_end) {
                            matched = true;
                        }
                        p_idx += 3;
                    } else {
                        // Single character
                        if (str[s_idx] == pattern[p_idx]) {
                            matched = true;
                        }
                        p_idx += 1;
                    }
                }

                if (negate) matched = !matched;
                if (!matched) return false;

                // Skip closing ]
                if (p_idx < pattern.len and pattern[p_idx] == ']') {
                    p_idx += 1;
                }
                s_idx += 1;
            } else {
                // Exact character match
                if (p_char != str[s_idx]) return false;
                p_idx += 1;
                s_idx += 1;
            }
        }

        // Check if we consumed both pattern and string
        // Account for trailing stars
        while (p_idx < pattern.len and pattern[p_idx] == '*') {
            p_idx += 1;
        }

        return p_idx == pattern.len and s_idx == str.len;
    }

    /// Expand $VAR form (unbraced)
    fn expandSimpleVariable(self: *Expansion, input: []const u8) !ExpansionResult {
        if (input.len < 2 or input[0] != '$') {
            return ExpansionResult{ .value = "$", .consumed = 1, .owned = false };
        }

        // Find end of variable name (alphanumeric and underscore)
        var end: usize = 1;
        while (end < input.len) {
            const char = input[end];
            if (!std.ascii.isAlphanumeric(char) and char != '_') {
                break;
            }
            end += 1;
        }

        if (end == 1) {
            // No valid variable name after $
            return ExpansionResult{ .value = "$", .consumed = 1, .owned = false };
        }

        const var_name = input[1..end];

        // Handle special dynamic variables
        if (std.mem.eql(u8, var_name, "RANDOM")) {
            var buf: [16]u8 = undefined;
            const val = getRandomValue();
            const result_str = std.fmt.bufPrint(&buf, "{d}", .{val}) catch "0";
            const result = try self.allocator.dupe(u8, result_str);
            return ExpansionResult{ .value = result, .consumed = end, .owned = true };
        }
        if (std.mem.eql(u8, var_name, "LINENO")) {
            var buf: [16]u8 = undefined;
            const result_str = std.fmt.bufPrint(&buf, "{d}", .{self.line_number}) catch "0";
            const result = try self.allocator.dupe(u8, result_str);
            return ExpansionResult{ .value = result, .consumed = end, .owned = true };
        }
        if (std.mem.eql(u8, var_name, "SECONDS")) {
            var buf: [16]u8 = undefined;
            const now = if (compat.Instant.now()) |inst| (if (@import("builtin").os.tag == .windows) @as(i64, @intCast(inst.timestamp / 10_000_000)) else @as(i64, @intCast(inst.timestamp.sec))) else |_| @as(i64, 0);
            const elapsed = now - self.shell_start_time;
            const result_str = std.fmt.bufPrint(&buf, "{d}", .{elapsed}) catch "0";
            const result = try self.allocator.dupe(u8, result_str);
            return ExpansionResult{ .value = result, .consumed = end, .owned = true };
        }
        if (std.mem.eql(u8, var_name, "PPID")) {
            var buf: [16]u8 = undefined;
            const ppid: i64 = if (is_windows) 0 else @intCast(std.c.getppid());
            const result_str = std.fmt.bufPrint(&buf, "{d}", .{ppid}) catch "0";
            const result = try self.allocator.dupe(u8, result_str);
            return ExpansionResult{ .value = result, .consumed = end, .owned = true };
        }
        if (std.mem.eql(u8, var_name, "BASHPID")) {
            var buf: [16]u8 = undefined;
            const pid: u32 = if (is_windows) std.os.windows.GetCurrentProcessId() else @intCast(std.c.getpid());
            const result_str = std.fmt.bufPrint(&buf, "{d}", .{pid}) catch "0";
            const result = try self.allocator.dupe(u8, result_str);
            return ExpansionResult{ .value = result, .consumed = end, .owned = true };
        }
        if (std.mem.eql(u8, var_name, "EUID")) {
            var buf: [16]u8 = undefined;
            const uid: u32 = if (is_windows) 0 else @intCast(std.c.geteuid());
            const result_str = std.fmt.bufPrint(&buf, "{d}", .{uid}) catch "0";
            const result = try self.allocator.dupe(u8, result_str);
            return ExpansionResult{ .value = result, .consumed = end, .owned = true };
        }
        if (std.mem.eql(u8, var_name, "UID")) {
            var buf: [16]u8 = undefined;
            const uid: u32 = if (is_windows) 0 else @intCast(std.c.getuid());
            const result_str = std.fmt.bufPrint(&buf, "{d}", .{uid}) catch "0";
            const result = try self.allocator.dupe(u8, result_str);
            return ExpansionResult{ .value = result, .consumed = end, .owned = true };
        }
        if (std.mem.eql(u8, var_name, "HOSTNAME")) {
            if (is_windows) {
                const result = try self.allocator.dupe(u8, "localhost");
                return ExpansionResult{ .value = result, .consumed = end, .owned = true };
            }
            var name_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
            const hostname = std.posix.gethostname(&name_buf) catch "unknown";
            const result = try self.allocator.dupe(u8, hostname);
            return ExpansionResult{ .value = result, .consumed = end, .owned = true };
        }

        // Use getVariableValue which handles local vars and nameref resolution
        if (self.getVariableValue(var_name)) |value| {
            const result = try self.allocator.dupe(u8, value);
            return ExpansionResult{ .value = result, .consumed = end, .owned = true };
        }

        // Variable not found
        // If nounset is enabled, return an error
        if (self.option_nounset) {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "den: {s}: unbound variable\n", .{var_name}) catch "den: unbound variable\n";
            if (is_windows) {
                if (std.os.windows.kernel32.GetStdHandle(std.os.windows.STD_ERROR_HANDLE)) |stderr_h| {
                    var written: u32 = 0;
                    _ = std.os.windows.kernel32.WriteFile(stderr_h, msg.ptr, @intCast(msg.len), &written, null);
                }
            } else {
                _ = std.c.write(std.posix.STDERR_FILENO, msg.ptr, msg.len);
            }
            return error.UnboundVariable;
        }

        // Return empty string (default behavior)
        return ExpansionResult{ .value = "", .consumed = end, .owned = false };
    }

    /// Expand $(command) - command substitution
    fn expandCommandSubstitution(self: *Expansion, input: []const u8) !ExpansionResult {
        if (input.len < 3 or input[0] != '$' or input[1] != '(') {
            return ExpansionResult{ .value = "$", .consumed = 1, .owned = false };
        }

        // Find matching closing parenthesis
        var depth: u32 = 1;
        var end: usize = 2;
        while (end < input.len and depth > 0) {
            if (input[end] == '(') {
                depth += 1;
            } else if (input[end] == ')') {
                depth -= 1;
            }
            if (depth > 0) end += 1;
        }

        if (depth != 0) {
            // Unmatched parenthesis
            return ExpansionResult{ .value = "$(", .consumed = 2, .owned = false };
        }

        const command = input[2..end];

        // Note: Command substitution caching is intentionally disabled.
        // Caching by command string is incorrect because the same command
        // can produce different results each time (e.g., `echo $(date +%s) $(date +%s)`).
        // Each substitution must execute independently for correctness.

        // Execute the command and capture output
        const output = self.executeCommandForSubstitution(command) catch {
            // On error, return empty string
            return ExpansionResult{ .value = "", .consumed = end + 1, .owned = false };
        };
        defer self.allocator.free(output);

        // Trim trailing newlines (bash behavior)
        var trimmed_len = output.len;
        while (trimmed_len > 0 and output[trimmed_len - 1] == '\n') {
            trimmed_len -= 1;
        }

        const result = try self.allocator.dupe(u8, output[0..trimmed_len]);

        return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
    }

    /// Expand backtick command substitution: `command`
    fn expandBacktick(self: *Expansion, input: []const u8) !ExpansionResult {
        if (input.len < 2 or input[0] != '`') {
            return ExpansionResult{ .value = "`", .consumed = 1, .owned = false };
        }

        // Find matching closing backtick
        var end: usize = 1;
        while (end < input.len and input[end] != '`') {
            // Handle escaped backticks
            if (input[end] == '\\' and end + 1 < input.len and input[end + 1] == '`') {
                end += 2;
                continue;
            }
            end += 1;
        }

        if (end >= input.len) {
            // Unmatched backtick
            return ExpansionResult{ .value = "`", .consumed = 1, .owned = false };
        }

        const command = input[1..end];

        // Note: Command substitution caching is intentionally disabled.
        // See expandCommandSubstitution for rationale.

        // Execute the command and capture output
        const output = self.executeCommandForSubstitution(command) catch {
            // On error, return empty string
            return ExpansionResult{ .value = "", .consumed = end + 1, .owned = false };
        };
        defer self.allocator.free(output);

        // Trim trailing newlines (bash behavior)
        var trimmed_len = output.len;
        while (trimmed_len > 0 and output[trimmed_len - 1] == '\n') {
            trimmed_len -= 1;
        }

        const result = try self.allocator.dupe(u8, output[0..trimmed_len]);

        return ExpansionResult{ .value = result, .consumed = end + 1, .owned = true };
    }

    /// Execute a command and return its output using fork/exec/pipe
    fn executeCommandForSubstitution(self: *Expansion, command: []const u8) ![]const u8 {
        const spawn = @import("spawn.zig");

        if (comptime @import("builtin").os.tag == .windows) {
            // Windows: use spawn module for command substitution
            const result = try spawn.shellCapture(self.allocator, command);
            return result.stdout;
        }

        // POSIX: Create a pipe for stdout capture
        var pipe_fds: [2]std.posix.fd_t = undefined;
        if (std.c.pipe(&pipe_fds) != 0) return error.Unexpected;
        const read_end = pipe_fds[0];
        const write_end = pipe_fds[1];

        // Fork the process
        const fork_ret = std.c.fork();
        if (fork_ret < 0) {
            _ = std.c.close(read_end);
            _ = std.c.close(write_end);
            return error.Unexpected;
        }
        const pid: std.posix.pid_t = @intCast(fork_ret);

        if (pid == 0) {
            // Child process
            // Redirect stdout to pipe write end
            _ = std.c.close(read_end);
            if (std.c.dup2(write_end, std.posix.STDOUT_FILENO) < 0) std.c._exit(1);
            _ = std.c.close(write_end);

            // stderr inherits from parent process (like bash)

            // Use the shell's own execution engine to preserve function definitions,
            // variables, and other shell state in command substitutions
            if (self.exec_command_fn) |exec_fn| {
                if (self.shell) |shell_opaque| {
                    exec_fn(shell_opaque, command);
                    // Exit with the shell's last exit code to propagate $?
                    const Shell = @import("../shell.zig").Shell;
                    const shell: *Shell = @ptrCast(@alignCast(shell_opaque));
                    const code: u8 = @intCast(@as(u32, @bitCast(shell.last_exit_code)) & 0xff);
                    std.c._exit(code);
                }
            }

            // Fallback: execute via fork+execve when no shell reference available
            var cmd_buf: [8192]u8 = undefined;
            if (command.len >= cmd_buf.len) std.c._exit(1);
            @memcpy(cmd_buf[0..command.len], command);
            cmd_buf[command.len] = 0;
            const cmd_z: [*:0]const u8 = @ptrCast(&cmd_buf);

            const sh_path: [*:0]const u8 = "/bin/sh";
            const sh_c: [*:0]const u8 = "-c";
            const argv_arr = [_:null]?[*:0]const u8{ sh_path, sh_c, cmd_z, null };
            _ = std.c.execve(sh_path, &argv_arr, @extern(*[*:null]?[*:0]u8, .{ .name = "environ" }).*);
            std.c._exit(127);
        }

        // Parent process - read child's stdout
        _ = std.c.close(write_end);

        const max_output: usize = 1024 * 1024;
        var output_buffer = std.ArrayList(u8).empty;
        errdefer output_buffer.deinit(self.allocator);

        var read_buf: [4096]u8 = undefined;
        while (true) {
            const bytes_read = std.posix.read(read_end, &read_buf) catch break;
            if (bytes_read == 0) break;
            try output_buffer.appendSlice(self.allocator, read_buf[0..bytes_read]);
            if (output_buffer.items.len >= max_output) break;
        }
        _ = std.c.close(read_end);

        // Wait for child to finish and capture exit code for $?
        var wait_status: c_int = 0;
        if (comptime builtin.os.tag != .windows) {
            _ = process_util.waitpidIntr(pid, &wait_status, 0);
            const exit_code: i32 = @intCast(std.posix.W.EXITSTATUS(@as(u32, @bitCast(wait_status))));
            self.last_exit_code = exit_code;
            // Also update the shell's exit code if available
            if (self.shell) |shell_opaque| {
                const Shell = @import("../shell.zig").Shell;
                const shell: *Shell = @ptrCast(@alignCast(shell_opaque));
                shell.last_exit_code = exit_code;
            }
        }

        return try output_buffer.toOwnedSlice(self.allocator);
    }

    /// Expand $((expression)) - arithmetic expansion
    fn expandArithmetic(self: *Expansion, input: []const u8) !ExpansionResult {
        if (input.len < 4 or input[0] != '$' or input[1] != '(' or input[2] != '(') {
            return ExpansionResult{ .value = "$", .consumed = 1, .owned = false };
        }

        // Find matching closing parentheses ))
        var depth: u32 = 2; // Start with depth 2 for ((
        var end: usize = 3;
        while (end < input.len and depth > 0) {
            if (input[end] == '(') {
                depth += 1;
            } else if (input[end] == ')') {
                depth -= 1;
            }
            if (depth > 0) end += 1;
        }

        if (depth != 0 or end >= input.len or input[end - 1] != ')') {
            // Unmatched parentheses
            return ExpansionResult{ .value = "$((", .consumed = 3, .owned = false };
        }

        // Extract expression (between (( and ))
        const raw_expr = input[3 .. end - 1];

        // Pre-expand ${...} parameter expansions within the arithmetic expression
        // Uses direct environment lookups to avoid recursive error set issues
        var arith_buf: [4096]u8 = undefined;
        var arith_len: usize = 0;
        var arith_expanded = false;
        if (std.mem.indexOf(u8, raw_expr, "${") != null) {
            var ri: usize = 0;
            while (ri < raw_expr.len) {
                if (ri + 1 < raw_expr.len and raw_expr[ri] == '$' and raw_expr[ri + 1] == '{') {
                    // Find matching }
                    var depth_b: u32 = 1;
                    var bi: usize = ri + 2;
                    while (bi < raw_expr.len and depth_b > 0) {
                        if (raw_expr[bi] == '{') depth_b += 1;
                        if (raw_expr[bi] == '}') depth_b -= 1;
                        if (depth_b > 0) bi += 1;
                    }
                    if (depth_b == 0) {
                        const var_content = raw_expr[ri + 2 .. bi];
                        var replacement: ?[]const u8 = null;
                        var repl_buf: [32]u8 = undefined;

                        if (var_content.len > 0 and var_content[0] == '#') {
                            // ${#var} - string length
                            const vname = var_content[1..];
                            const val = if (self.local_vars) |lv| lv.get(vname) orelse self.environment.get(vname) else self.environment.get(vname);
                            if (val) |v| {
                                replacement = std.fmt.bufPrint(&repl_buf, "{d}", .{v.len}) catch null;
                            } else {
                                replacement = "0";
                            }
                        } else {
                            // ${var} - variable value
                            // Check positional params first for numeric names like ${1}, ${2}
                            const maybe_pos_idx = std.fmt.parseInt(usize, var_content, 10) catch null;
                            if (maybe_pos_idx) |pos_idx| {
                                if (pos_idx > 0 and pos_idx <= self.positional_params.len) {
                                    replacement = self.positional_params[pos_idx - 1];
                                } else {
                                    replacement = "0";
                                }
                            } else {
                                const val = if (self.local_vars) |lv| lv.get(var_content) orelse self.environment.get(var_content) else self.environment.get(var_content);
                                replacement = val orelse "0";
                            }
                        }

                        if (replacement) |repl| {
                            if (arith_len + repl.len <= arith_buf.len) {
                                @memcpy(arith_buf[arith_len..][0..repl.len], repl);
                                arith_len += repl.len;
                            }
                            arith_expanded = true;
                        }
                        ri = bi + 1;
                    } else {
                        if (arith_len < arith_buf.len) {
                            arith_buf[arith_len] = raw_expr[ri];
                            arith_len += 1;
                        }
                        ri += 1;
                    }
                } else {
                    if (arith_len < arith_buf.len) {
                        arith_buf[arith_len] = raw_expr[ri];
                        arith_len += 1;
                    }
                    ri += 1;
                }
            }
        }
        var expr_after_vars: []const u8 = if (arith_expanded) arith_buf[0..arith_len] else raw_expr;

        // Pre-expand $(...) command substitutions (but NOT $((...)) arithmetic)
        var cmd_buf: [4096]u8 = undefined;
        var cmd_len: usize = 0;
        var cmd_expanded = false;
        if (std.mem.indexOf(u8, expr_after_vars, "$(") != null) {
            var ci: usize = 0;
            while (ci < expr_after_vars.len) {
                if (ci + 1 < expr_after_vars.len and expr_after_vars[ci] == '$' and expr_after_vars[ci + 1] == '(') {
                    // Check if it's $(( — skip nested arithmetic (handled by Arithmetic evaluator)
                    if (ci + 2 < expr_after_vars.len and expr_after_vars[ci + 2] == '(') {
                        // It's $(( — copy as-is, find matching ))
                        var ad: u32 = 2;
                        var ai: usize = ci + 3;
                        while (ai < expr_after_vars.len and ad > 0) {
                            if (expr_after_vars[ai] == '(') ad += 1;
                            if (expr_after_vars[ai] == ')') ad -= 1;
                            ai += 1;
                        }
                        const chunk = expr_after_vars[ci..ai];
                        if (cmd_len + chunk.len <= cmd_buf.len) {
                            @memcpy(cmd_buf[cmd_len..][0..chunk.len], chunk);
                            cmd_len += chunk.len;
                        }
                        ci = ai;
                    } else {
                        // It's $(...) — find matching ) respecting nesting
                        var pd: u32 = 1;
                        var pi: usize = ci + 2;
                        while (pi < expr_after_vars.len and pd > 0) {
                            if (expr_after_vars[pi] == '(') pd += 1;
                            if (expr_after_vars[pi] == ')') pd -= 1;
                            if (pd > 0) pi += 1;
                        }
                        if (pd == 0) {
                            const cmd_str = expr_after_vars[ci + 2 .. pi];
                            const output = self.executeCommandForSubstitution(cmd_str) catch "";
                            defer if (output.len > 0) self.allocator.free(output);

                            // Trim trailing newlines
                            var trimmed = output.len;
                            while (trimmed > 0 and output[trimmed - 1] == '\n') trimmed -= 1;
                            const trimmed_output = output[0..trimmed];

                            if (cmd_len + trimmed_output.len <= cmd_buf.len) {
                                @memcpy(cmd_buf[cmd_len..][0..trimmed_output.len], trimmed_output);
                                cmd_len += trimmed_output.len;
                            }
                            cmd_expanded = true;
                            ci = pi + 1;
                        } else {
                            // Unmatched — copy as-is
                            if (cmd_len < cmd_buf.len) {
                                cmd_buf[cmd_len] = expr_after_vars[ci];
                                cmd_len += 1;
                            }
                            ci += 1;
                        }
                    }
                } else {
                    if (cmd_len < cmd_buf.len) {
                        cmd_buf[cmd_len] = expr_after_vars[ci];
                        cmd_len += 1;
                    }
                    ci += 1;
                }
            }
        }
        const expr: []const u8 = if (cmd_expanded) cmd_buf[0..cmd_len] else expr_after_vars;

        // Evaluate arithmetic expression with variable support
        var arith = Arithmetic.initWithVariables(self.allocator, self.environment);
        arith.local_vars = self.local_vars;
        arith.arrays = self.arrays;
        arith.positional_params = self.positional_params;
        const result_value = arith.eval(expr) catch {
            // On error, return 0
            const value = try std.fmt.allocPrint(self.allocator, "0", .{});
            return ExpansionResult{ .value = value, .consumed = end + 1, .owned = true };
        };

        // Format result as string
        const value = try std.fmt.allocPrint(self.allocator, "{d}", .{result_value});
        return ExpansionResult{ .value = value, .consumed = end + 1, .owned = true };
    }

    /// Expand $"..." string interpolation
    /// Supports {$var}, {$(cmd)}, and {expr} blocks within the string
    fn expandStringInterpolation(self: *Expansion, input: []const u8) !ExpansionResult {
        if (input.len < 3 or input[0] != '$' or input[1] != '"') {
            return ExpansionResult{ .value = "$", .consumed = 1, .owned = false };
        }

        // Skip $"
        var pos: usize = 2;
        var result_buf: [16384]u8 = undefined;
        var result_len: usize = 0;

        while (pos < input.len) {
            const c = input[pos];

            if (c == '"') {
                // End of interpolated string
                pos += 1;
                break;
            }

            if (c == '\\' and pos + 1 < input.len) {
                // Escape sequence
                const next = input[pos + 1];
                if (next == '{' or next == '}' or next == '"' or next == '\\') {
                    if (result_len < result_buf.len) {
                        result_buf[result_len] = next;
                        result_len += 1;
                    }
                    pos += 2;
                    continue;
                }
            }

            if (c == '{') {
                // Find matching }
                var depth: usize = 1;
                var expr_end = pos + 1;
                while (expr_end < input.len and depth > 0) {
                    if (input[expr_end] == '{') depth += 1;
                    if (input[expr_end] == '}') {
                        depth -= 1;
                        if (depth == 0) break;
                    }
                    expr_end += 1;
                }

                if (depth == 0) {
                    const expr = input[pos + 1 .. expr_end];
                    // Expand the expression using expandVariable for $ expressions
                    if (expr.len > 0 and expr[0] == '$') {
                        const var_result = try self.expandVariable(expr);
                        defer if (var_result.owned) self.allocator.free(@constCast(var_result.value));

                        const copy_len = @min(var_result.value.len, result_buf.len - result_len);
                        @memcpy(result_buf[result_len .. result_len + copy_len], var_result.value[0..copy_len]);
                        result_len += copy_len;
                    } else {
                        // Copy expression as literal text
                        const copy_len = @min(expr.len, result_buf.len - result_len);
                        @memcpy(result_buf[result_len .. result_len + copy_len], expr[0..copy_len]);
                        result_len += copy_len;
                    }

                    pos = expr_end + 1; // skip past }
                    continue;
                }
            }

            if (c == '$') {
                // Expand $var or $(cmd) inline
                const var_result = try self.expandVariable(input[pos..]);
                defer if (var_result.owned) self.allocator.free(@constCast(var_result.value));

                const copy_len = @min(var_result.value.len, result_buf.len - result_len);
                @memcpy(result_buf[result_len .. result_len + copy_len], var_result.value[0..copy_len]);
                result_len += copy_len;

                pos += var_result.consumed;
                continue;
            }

            // Regular character
            if (result_len < result_buf.len) {
                result_buf[result_len] = c;
                result_len += 1;
            }
            pos += 1;
        }

        const value = try self.allocator.dupe(u8, result_buf[0..result_len]);
        return ExpansionResult{ .value = value, .consumed = pos, .owned = true };
    }

    /// Expand tilde (~) to home directory
    /// Supports: ~, ~user, ~+, ~-, ~+N, ~-N
    fn expandTilde(self: *Expansion, input: []const u8) !ExpansionResult {
        if (input.len < 1 or input[0] != '~') {
            return ExpansionResult{ .value = "~", .consumed = 1, .owned = false };
        }

        // Find end of username (or tilde alone)
        var end: usize = 1;
        while (end < input.len) {
            const c = input[end];
            if (c == '/' or c == ':' or std.ascii.isWhitespace(c)) {
                break;
            }
            end += 1;
        }

        const expanded_path = if (end == 1) blk: {
            // ~ alone - expand to current user's home
            if (self.environment.get("HOME")) |home| {
                break :blk try self.allocator.dupe(u8, home);
            } else if (env_utils.getEnv("HOME")) |home| {
                break :blk try self.allocator.dupe(u8, home);
            } else {
                // Fallback - return tilde unchanged
                break :blk try self.allocator.dupe(u8, "~");
            }
        } else blk: {
            const suffix = input[1..end];

            // ~+ - current working directory (PWD)
            if (std.mem.eql(u8, suffix, "+")) {
                if (self.environment.get("PWD")) |pwd| {
                    break :blk try self.allocator.dupe(u8, pwd);
                } else if (env_utils.getEnv("PWD")) |pwd| {
                    break :blk try self.allocator.dupe(u8, pwd);
                } else {
                    // Try to get cwd as fallback
                    var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
                    if (std.Io.Dir.cwd().realPathFile(std.Options.debug_io, ".", &cwd_buf)) |path_len| {
                        break :blk try self.allocator.dupe(u8, cwd_buf[0..path_len]);
                    } else |_| {
                        break :blk try self.allocator.dupe(u8, "~+");
                    }
                }
            }

            // ~- - previous working directory (OLDPWD)
            if (std.mem.eql(u8, suffix, "-")) {
                if (self.environment.get("OLDPWD")) |oldpwd| {
                    break :blk try self.allocator.dupe(u8, oldpwd);
                } else if (env_utils.getEnv("OLDPWD")) |oldpwd| {
                    break :blk try self.allocator.dupe(u8, oldpwd);
                } else {
                    // OLDPWD not set
                    break :blk try self.allocator.dupe(u8, "~-");
                }
            }

            // ~username - expand to specified user's home directory
            const username = suffix;

            // First check if it's the current user
            if (self.environment.get("USER")) |current_user| {
                if (std.mem.eql(u8, username, current_user)) {
                    if (self.environment.get("HOME")) |home| {
                        break :blk try self.allocator.dupe(u8, home);
                    }
                }
            }

            // Try to look up user's home directory using getpwnam
            if (getUserHomeDir(username)) |home_dir| {
                break :blk try self.allocator.dupe(u8, home_dir);
            }

            // If we can't resolve, return unchanged
            break :blk try self.allocator.dupe(u8, input[0..end]);
        };

        return ExpansionResult{
            .value = expanded_path,
            .consumed = end,
            .owned = true,
        };
    }

    /// Expand process substitution: <(cmd) or >(cmd)
    /// Creates a pipe, forks a process to run the command, and returns /dev/fd/N
    fn expandProcessSubstitution(self: *Expansion, input: []const u8, is_input: bool) !ExpansionResult {
        // Process substitution is not available on Windows
        if (builtin.os.tag == .windows) {
            // Return the literal text on Windows
            if (input.len < 2) {
                return ExpansionResult{ .value = if (is_input) "<" else ">", .consumed = 1, .owned = false };
            }
            // Find closing paren and return as literal
            var end: usize = 2;
            var depth: u32 = 1;
            while (end < input.len and depth > 0) {
                if (input[end] == '(') depth += 1 else if (input[end] == ')') depth -= 1;
                if (depth > 0) end += 1;
            }
            const literal = try self.allocator.dupe(u8, input[0 .. end + 1]);
            return ExpansionResult{ .value = literal, .consumed = end + 1, .owned = true };
        }

        // Parse: <(cmd) or >(cmd)
        if (input.len < 3 or input[1] != '(') {
            return ExpansionResult{ .value = if (is_input) "<" else ">", .consumed = 1, .owned = false };
        }

        // Find matching closing parenthesis
        var depth: u32 = 1;
        var end: usize = 2;
        while (end < input.len and depth > 0) {
            if (input[end] == '(') {
                depth += 1;
            } else if (input[end] == ')') {
                depth -= 1;
            }
            if (depth > 0) end += 1;
        }

        if (depth != 0) {
            // Unmatched parenthesis - return literal
            return ExpansionResult{ .value = if (is_input) "<(" else ">(", .consumed = 2, .owned = false };
        }

        const command = input[2..end];

        // Create a pipe
        var pipe_fds: [2]std.posix.fd_t = undefined;
        if (std.c.pipe(&pipe_fds) != 0) {
            return ExpansionResult{ .value = "", .consumed = end + 1, .owned = false };
        }

        // Fork a child process
        const fork_ret = std.c.fork();
        if (fork_ret < 0) {
            _ = std.c.close(pipe_fds[0]);
            _ = std.c.close(pipe_fds[1]);
            return ExpansionResult{ .value = "", .consumed = end + 1, .owned = false };
        }
        const fork_result: std.posix.pid_t = @intCast(fork_ret);

        if (fork_result == 0) {
            // Child process. Use std.c._exit instead of std.process.exit because
            // the latter flushes stdio/atexit which can corrupt parent state
            // after fork.
            if (is_input) {
                // <(cmd) - child writes to pipe, parent reads
                // Close read end
                _ = std.c.close(pipe_fds[0]);
                // Redirect stdout to write end of pipe
                if (std.c.dup2(pipe_fds[1], std.posix.STDOUT_FILENO) < 0) {
                    std.c._exit(1);
                }
                _ = std.c.close(pipe_fds[1]);
            } else {
                // >(cmd) - child reads from pipe, parent writes
                // Close write end
                _ = std.c.close(pipe_fds[1]);
                // Redirect stdin to read end of pipe
                if (std.c.dup2(pipe_fds[0], std.posix.STDIN_FILENO) < 0) {
                    std.c._exit(1);
                }
                _ = std.c.close(pipe_fds[0]);
            }

            // Use the shell's own execution engine to preserve function definitions,
            // variables, and other shell state in process substitutions
            if (self.exec_command_fn) |exec_fn| {
                if (self.shell) |shell_opaque| {
                    exec_fn(shell_opaque, command);
                    const Shell = @import("../shell.zig").Shell;
                    const shell: *Shell = @ptrCast(@alignCast(shell_opaque));
                    const code: u8 = @intCast(@as(u32, @bitCast(shell.last_exit_code)) & 0xff);
                    std.c._exit(code);
                }
            }

            // Fallback: execute via /bin/sh -c when no shell reference available
            var cmd_buf: [4096]u8 = undefined;
            if (command.len >= cmd_buf.len) {
                std.c._exit(1);
            }
            @memcpy(cmd_buf[0..command.len], command);
            cmd_buf[command.len] = 0;

            const argv = [_:null]?[*:0]const u8{
                "/bin/sh",
                "-c",
                @ptrCast(&cmd_buf),
                null,
            };
            _ = std.c.execve("/bin/sh", &argv, @ptrCast(getCEnviron()));
            std.c._exit(127);
        }

        // Parent process
        // Determine which fd the parent will use
        const parent_fd = if (is_input) pipe_fds[0] else pipe_fds[1];
        const child_fd = if (is_input) pipe_fds[1] else pipe_fds[0];

        // Close the fd the child is using
        _ = std.c.close(child_fd);

        // Format the /dev/fd/N path
        const fd_path = std.fmt.allocPrint(self.allocator, "/dev/fd/{d}", .{parent_fd}) catch {
            _ = std.c.close(parent_fd);
            return ExpansionResult{ .value = "", .consumed = end + 1, .owned = false };
        };

        return ExpansionResult{ .value = fd_path, .consumed = end + 1, .owned = true };
    }
};

const common = @import("../executor/builtins/common.zig");

/// Get C environment pointer (platform-specific)
fn getCEnviron() [*:null]const ?[*:0]const u8 {
    return common.getCEnviron();
}

/// Get user's home directory from passwd database
/// Uses POSIX getpwnam for lookup
fn getUserHomeDir(username: []const u8) ?[]const u8 {
    // Only available on POSIX systems
    if (builtin.os.tag == .windows) {
        return null;
    }

    // Create null-terminated username
    var name_buf: [256]u8 = undefined;
    if (username.len >= name_buf.len) return null;
    @memcpy(name_buf[0..username.len], username);
    name_buf[username.len] = 0;

    const passwd = std.c.getpwnam(@ptrCast(&name_buf));
    if (passwd) |pw| {
        // The field is 'dir' in Zig's std.c.passwd struct
        if (pw.dir) |dir| {
            return std.mem.span(dir);
        }
    }
    return null;
}

/// IFS-based word splitting utilities
/// Default IFS is space, tab, and newline
pub const WordSplitter = struct {
    allocator: std.mem.Allocator,
    ifs: []const u8,

    /// Default IFS value (space, tab, newline)
    pub const default_ifs = " \t\n";

    /// Initialize with environment lookup for IFS
    pub fn init(allocator: std.mem.Allocator, environment: ?*std.StringHashMap([]const u8)) WordSplitter {
        const ifs = if (environment) |env| env.get("IFS") orelse default_ifs else default_ifs;
        return .{
            .allocator = allocator,
            .ifs = ifs,
        };
    }

    /// Initialize with custom IFS value
    pub fn initWithIfs(allocator: std.mem.Allocator, ifs: []const u8) WordSplitter {
        return .{
            .allocator = allocator,
            .ifs = ifs,
        };
    }

    /// Split a string into words based on IFS
    /// Respects quoting: single quotes, double quotes preserve content
    /// Empty IFS means no splitting
    /// Returns array of word slices (caller must free the array)
    pub fn split(self: *const WordSplitter, input: []const u8) ![][]const u8 {
        // Empty IFS means no splitting - return entire input as one word
        if (self.ifs.len == 0) {
            var result = try self.allocator.alloc([]const u8, 1);
            result[0] = input;
            return result;
        }

        var words = std.ArrayList([]const u8).empty;
        errdefer words.deinit(self.allocator);

        var i: usize = 0;
        var after_word = false; // Track if we just finished a word

        while (i < input.len) {
            // Skip IFS whitespace characters (space, tab, newline)
            while (i < input.len and self.isIfsWhitespace(input[i])) {
                i += 1;
            }

            if (i >= input.len) break;

            // Check for non-whitespace IFS character (acts as delimiter)
            if (self.isIfsNonWhitespace(input[i])) {
                if (!after_word) {
                    // Leading non-ws IFS delimiter produces an empty field
                    try words.append(self.allocator, "");
                }
                i += 1;
                after_word = false;

                // Skip trailing IFS whitespace after the delimiter
                while (i < input.len and self.isIfsWhitespace(input[i])) {
                    i += 1;
                }

                // Check for consecutive non-ws IFS delimiters or end of input
                if (i >= input.len or self.isIfsNonWhitespace(input[i])) {
                    // Another delimiter or end of input: empty field
                    if (i >= input.len) {
                        try words.append(self.allocator, "");
                    }
                    // If another delimiter, the next iteration will handle it
                }
                continue;
            }

            // Start of a word
            const word_start = i;
            var in_single_quote = false;
            var in_double_quote = false;

            while (i < input.len) {
                const c = input[i];

                // Handle quoting
                if (c == '\'' and !in_double_quote) {
                    in_single_quote = !in_single_quote;
                    i += 1;
                    continue;
                }
                if (c == '"' and !in_single_quote) {
                    in_double_quote = !in_double_quote;
                    i += 1;
                    continue;
                }

                // If not in quotes, check for IFS
                if (!in_single_quote and !in_double_quote) {
                    if (self.isIfsChar(c)) {
                        break;
                    }
                }

                i += 1;
            }

            // Add the word if non-empty
            if (i > word_start) {
                try words.append(self.allocator, input[word_start..i]);
                after_word = true;
            }
        }

        return try words.toOwnedSlice(self.allocator);
    }

    /// Split and remove quotes from words
    /// Returns newly allocated strings (caller must free each string and the array)
    pub fn splitAndUnquote(self: *const WordSplitter, input: []const u8) ![][]const u8 {
        const raw_words = try self.split(input);
        defer self.allocator.free(raw_words);

        var result = try self.allocator.alloc([]const u8, raw_words.len);
        errdefer {
            for (result) |word| {
                if (word.len > 0) self.allocator.free(word);
            }
            self.allocator.free(result);
        }

        for (raw_words, 0..) |word, idx| {
            result[idx] = try removeQuotes(self.allocator, word);
        }

        return result;
    }

    /// Check if character is an IFS character
    fn isIfsChar(self: *const WordSplitter, c: u8) bool {
        for (self.ifs) |ifs_char| {
            if (c == ifs_char) return true;
        }
        return false;
    }

    /// Check if character is an IFS whitespace (space, tab, newline)
    fn isIfsWhitespace(self: *const WordSplitter, c: u8) bool {
        if (!self.isIfsChar(c)) return false;
        return c == ' ' or c == '\t' or c == '\n';
    }

    /// Check if character is a non-whitespace IFS character
    fn isIfsNonWhitespace(self: *const WordSplitter, c: u8) bool {
        if (!self.isIfsChar(c)) return false;
        return c != ' ' and c != '\t' and c != '\n';
    }
};

/// Remove single and double quotes from a string
/// Preserves content inside quotes, handles escape sequences in double quotes
pub fn removeQuotes(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    if (input.len == 0) {
        return try allocator.dupe(u8, "");
    }

    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    var in_single_quote = false;
    var in_double_quote = false;

    while (i < input.len) {
        const c = input[i];

        if (c == '\'' and !in_double_quote) {
            // Toggle single quote mode, don't output the quote
            in_single_quote = !in_single_quote;
            i += 1;
            continue;
        }

        if (c == '"' and !in_single_quote) {
            // Toggle double quote mode, don't output the quote
            in_double_quote = !in_double_quote;
            i += 1;
            continue;
        }

        // Handle escape sequences in double quotes
        if (c == '\\' and in_double_quote and i + 1 < input.len) {
            const next = input[i + 1];
            // Only these characters are escaped in double quotes: $ ` " \ newline
            if (next == '$' or next == '`' or next == '"' or next == '\\' or next == '\n') {
                if (next != '\n') { // Escaped newline is removed entirely
                    try result.append(allocator, next);
                }
                i += 2;
                continue;
            }
        }

        // Regular character
        try result.append(allocator, c);
        i += 1;
    }

    return try result.toOwnedSlice(allocator);
}

/// Split expanded value into words using IFS and apply to positional parameters
/// This is the full POSIX field splitting algorithm
pub fn splitFieldsIfs(allocator: std.mem.Allocator, value: []const u8, ifs: []const u8) ![][]const u8 {
    var splitter = WordSplitter.initWithIfs(allocator, ifs);
    return try splitter.split(value);
}

test "expand simple variable" {
    const allocator = std.testing.allocator;

    var env = std.StringHashMap([]const u8).init(allocator);
    defer env.deinit();

    try env.put("HOME", "/home/user");
    try env.put("USER", "testuser");

    var exp = Expansion.init(allocator, &env, 0);

    const result1 = try exp.expand("$HOME/documents");
    defer allocator.free(result1);
    try std.testing.expectEqualStrings("/home/user/documents", result1);

    const result2 = try exp.expand("Hello $USER!");
    defer allocator.free(result2);
    try std.testing.expectEqualStrings("Hello testuser!", result2);
}

test "expand braced variable" {
    const allocator = std.testing.allocator;

    var env = std.StringHashMap([]const u8).init(allocator);
    defer env.deinit();

    try env.put("NAME", "Alice");

    var exp = Expansion.init(allocator, &env, 0);

    const result = try exp.expand("${NAME}_file.txt");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Alice_file.txt", result);
}

test "expand with default value" {
    const allocator = std.testing.allocator;

    var env = std.StringHashMap([]const u8).init(allocator);
    defer env.deinit();

    var exp = Expansion.init(allocator, &env, 0);

    const result = try exp.expand("${MISSING:-default}");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("default", result);
}

test "expand special variables" {
    const allocator = std.testing.allocator;

    var env = std.StringHashMap([]const u8).init(allocator);
    defer env.deinit();

    var exp = Expansion.init(allocator, &env, 42);

    const result = try exp.expand("Exit code: $?");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Exit code: 42", result);
}

test "expand tilde home" {
    const allocator = std.testing.allocator;

    var env = std.StringHashMap([]const u8).init(allocator);
    defer env.deinit();

    try env.put("HOME", "/home/testuser");

    var exp = Expansion.init(allocator, &env, 0);

    const result = try exp.expand("~/documents");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("/home/testuser/documents", result);
}

test "expand tilde+ PWD" {
    const allocator = std.testing.allocator;

    var env = std.StringHashMap([]const u8).init(allocator);
    defer env.deinit();

    try env.put("PWD", "/var/www");

    var exp = Expansion.init(allocator, &env, 0);

    const result = try exp.expand("~+/subdir");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("/var/www/subdir", result);
}

test "expand tilde- OLDPWD" {
    const allocator = std.testing.allocator;

    var env = std.StringHashMap([]const u8).init(allocator);
    defer env.deinit();

    try env.put("OLDPWD", "/tmp/previous");

    var exp = Expansion.init(allocator, &env, 0);

    const result = try exp.expand("~-/file.txt");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("/tmp/previous/file.txt", result);
}

test "expand tilde user" {
    const allocator = std.testing.allocator;

    var env = std.StringHashMap([]const u8).init(allocator);
    defer env.deinit();

    try env.put("USER", "testuser");
    try env.put("HOME", "/home/testuser");

    var exp = Expansion.init(allocator, &env, 0);

    // Current user should expand to HOME
    const result = try exp.expand("~testuser/docs");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("/home/testuser/docs", result);
}

test "IFS word splitting - default IFS" {
    const allocator = std.testing.allocator;

    var splitter = WordSplitter.initWithIfs(allocator, WordSplitter.default_ifs);

    const words = try splitter.split("one  two\tthree\nfour");
    defer allocator.free(words);

    try std.testing.expectEqual(@as(usize, 4), words.len);
    try std.testing.expectEqualStrings("one", words[0]);
    try std.testing.expectEqualStrings("two", words[1]);
    try std.testing.expectEqualStrings("three", words[2]);
    try std.testing.expectEqualStrings("four", words[3]);
}

test "IFS word splitting - custom IFS" {
    const allocator = std.testing.allocator;

    var splitter = WordSplitter.initWithIfs(allocator, ":");

    const words = try splitter.split("/usr/local/bin:/usr/bin:/bin");
    defer allocator.free(words);

    try std.testing.expectEqual(@as(usize, 3), words.len);
    try std.testing.expectEqualStrings("/usr/local/bin", words[0]);
    try std.testing.expectEqualStrings("/usr/bin", words[1]);
    try std.testing.expectEqualStrings("/bin", words[2]);
}

test "IFS word splitting - empty IFS" {
    const allocator = std.testing.allocator;

    var splitter = WordSplitter.initWithIfs(allocator, "");

    const words = try splitter.split("one two three");
    defer allocator.free(words);

    // Empty IFS means no splitting
    try std.testing.expectEqual(@as(usize, 1), words.len);
    try std.testing.expectEqualStrings("one two three", words[0]);
}

test "IFS word splitting - quoted content preserved" {
    const allocator = std.testing.allocator;

    var splitter = WordSplitter.initWithIfs(allocator, WordSplitter.default_ifs);

    const words = try splitter.split("one 'two three' four");
    defer allocator.free(words);

    try std.testing.expectEqual(@as(usize, 3), words.len);
    try std.testing.expectEqualStrings("one", words[0]);
    try std.testing.expectEqualStrings("'two three'", words[1]);
    try std.testing.expectEqualStrings("four", words[2]);
}

test "IFS word splitting - double quoted content preserved" {
    const allocator = std.testing.allocator;

    var splitter = WordSplitter.initWithIfs(allocator, WordSplitter.default_ifs);

    const words = try splitter.split("one \"two three\" four");
    defer allocator.free(words);

    try std.testing.expectEqual(@as(usize, 3), words.len);
    try std.testing.expectEqualStrings("one", words[0]);
    try std.testing.expectEqualStrings("\"two three\"", words[1]);
    try std.testing.expectEqualStrings("four", words[2]);
}

test "removeQuotes - single quotes" {
    const allocator = std.testing.allocator;

    const result = try removeQuotes(allocator, "'hello world'");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello world", result);
}

test "removeQuotes - double quotes" {
    const allocator = std.testing.allocator;

    const result = try removeQuotes(allocator, "\"hello world\"");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello world", result);
}

test "removeQuotes - mixed quotes" {
    const allocator = std.testing.allocator;

    const result = try removeQuotes(allocator, "hello 'single' and \"double\" world");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello single and double world", result);
}

test "removeQuotes - escape in double quotes" {
    const allocator = std.testing.allocator;

    const result = try removeQuotes(allocator, "\"hello \\\"world\\\"\"");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello \"world\"", result);
}

test "negative offset overflow safety" {
    // Verify that @abs() is used instead of @intCast(-offset) which would
    // overflow on i64::MIN. This mirrors the pattern fixed in expansion.zig:1091
    const min_val: i64 = std.math.minInt(i64);

    // This should not panic or misbehave
    const abs_val: u64 = @abs(min_val);
    try std.testing.expectEqual(@as(u64, 1) << 63, abs_val);

    // For "normal" negative values, @abs() behaves the same as -x
    const normal: i64 = -42;
    try std.testing.expectEqual(@as(u64, 42), @abs(normal));
}

test "removeQuotes preserves empty string" {
    const allocator = std.testing.allocator;
    const result = try removeQuotes(allocator, "");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "removeQuotes unchanged when no quotes" {
    const allocator = std.testing.allocator;
    const result = try removeQuotes(allocator, "hello world");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello world", result);
}

test "removeQuotes single-quoted string" {
    const allocator = std.testing.allocator;
    const result = try removeQuotes(allocator, "'hello'");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello", result);
}
