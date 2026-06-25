const std = @import("std");
const Shell = @import("../shell.zig").Shell;
const ControlFlowParser = @import("control_flow.zig").ControlFlowParser;
const ControlFlowExecutor = @import("control_flow.zig").ControlFlowExecutor;
const FunctionParser = @import("functions.zig").FunctionParser;
const IO = @import("../utils/io.zig").IO;

/// Cached script entry
const CachedScript = struct {
    path: []const u8,
    content: []const u8,
    mtime_ns: i128, // File modification time (nanoseconds); i128 matches stat.mtime
    line_count: usize,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *CachedScript) void {
        self.allocator.free(self.path);
        self.allocator.free(self.content);
    }
};

/// Script execution result
pub const ScriptResult = struct {
    exit_code: i32,
    line_executed: usize,
    error_message: ?[]const u8,
};

/// Extract the heredoc delimiter from a line containing <<
/// Returns the delimiter string (stripped of quotes), or null if not found
fn extractHeredocDelimiter(line: []const u8) ?[]const u8 {
    const idx = std.mem.indexOf(u8, line, "<<") orelse return null;
    var pos = idx + 2;
    // Skip <<< (that's a herestring, not heredoc)
    if (pos < line.len and line[pos] == '<') return null;
    // Skip <<- (strip tabs variant)
    if (pos < line.len and line[pos] == '-') pos += 1;
    // Skip whitespace
    while (pos < line.len and (line[pos] == ' ' or line[pos] == '\t')) : (pos += 1) {}
    if (pos >= line.len) return null;
    // Handle quoted delimiters: 'EOF', "EOF", \EOF
    const start_char = line[pos];
    if (start_char == '\'' or start_char == '"') {
        pos += 1;
        const start = pos;
        while (pos < line.len and line[pos] != start_char) : (pos += 1) {}
        if (pos > start) return line[start..pos];
        return null;
    }
    if (start_char == '\\') pos += 1;
    const start = pos;
    while (pos < line.len and line[pos] != ' ' and line[pos] != '\t' and line[pos] != '\n' and line[pos] != ';') : (pos += 1) {}
    if (pos > start) return line[start..pos];
    return null;
}

/// Script Manager - handles script loading, caching, and execution
pub const ScriptManager = struct {
    allocator: std.mem.Allocator,
    cache: std.StringHashMap(CachedScript),
    cache_enabled: bool,
    max_cache_size: usize,
    cache_ttl_ns: i128, // Cache time-to-live in nanoseconds

    const DEFAULT_CACHE_SIZE = 32;
    const DEFAULT_TTL_SECONDS = 300; // 5 minutes

    pub fn init(allocator: std.mem.Allocator) ScriptManager {
        return .{
            .allocator = allocator,
            .cache = std.StringHashMap(CachedScript).init(allocator),
            .cache_enabled = true,
            .max_cache_size = DEFAULT_CACHE_SIZE,
            .cache_ttl_ns = DEFAULT_TTL_SECONDS * std.time.ns_per_s,
        };
    }

    pub fn deinit(self: *ScriptManager) void {
        // Free all cached scripts and their keys
        var iter = self.cache.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            var cached = entry.value_ptr;
            cached.deinit();
        }
        self.cache.deinit();
    }

    /// Load a script from file (with caching)
    pub fn loadScript(self: *ScriptManager, path: []const u8) ![]const u8 {
        // Check cache first if enabled
        if (self.cache_enabled) {
            if (try self.getFromCache(path)) |content| {
                return content;
            }
        }

        // Load from file
        const content = try self.loadScriptFromFile(path);

        // Add to cache (which duplicates the content)
        if (self.cache_enabled) {
            try self.addToCache(path, content);
            // Free the original since the cache now owns its own copy
            self.allocator.free(content);
            // Return the cached copy
            if (try self.getFromCache(path)) |cached_content| {
                return cached_content;
            }
        }

        return content;
    }

    /// Load script directly from file (bypassing cache)
    pub fn loadScriptFromFile(self: *ScriptManager, path: []const u8) ![]const u8 {
        const file = std.Io.Dir.cwd().openFile(std.Options.debug_io, path, .{}) catch |err| {
            IO.eprint("den: error loading script '{s}': {}\n", .{ path, err }) catch {};
            return error.ScriptLoadFailed;
        };
        defer file.close(std.Options.debug_io);

        const max_size: usize = 10 * 1024 * 1024;
        const file_size = (file.stat(std.Options.debug_io) catch |err| {
            IO.eprint("den: error reading script '{s}': {}\n", .{ path, err }) catch {};
            return error.ScriptReadFailed;
        }).size;
        const read_size: usize = @min(file_size, max_size);
        const buffer = self.allocator.alloc(u8, read_size) catch |err| {
            IO.eprint("den: error allocating for script '{s}': {}\n", .{ path, err }) catch {};
            return error.ScriptReadFailed;
        };
        errdefer self.allocator.free(buffer);
        var total_read: usize = 0;
        while (total_read < read_size) {
            const n = file.readStreaming(std.Options.debug_io, &.{buffer[total_read..]}) catch |err| {
                IO.eprint("den: error reading script '{s}': {}\n", .{ path, err }) catch {};
                return error.ScriptReadFailed;
            };
            if (n == 0) break;
            total_read += n;
        }
        const content = buffer[0..total_read];

        return content;
    }

    /// Reload a script (invalidate cache and reload)
    pub fn reloadScript(self: *ScriptManager, path: []const u8) ![]const u8 {
        // Remove from cache if present
        if (self.cache.fetchRemove(path)) |entry| {
            var cached = entry.value;
            cached.deinit();
        }

        // Load fresh copy
        return try self.loadScript(path);
    }

    /// Get script from cache if valid
    fn getFromCache(self: *ScriptManager, path: []const u8) !?[]const u8 {
        const cached = self.cache.get(path) orelse return null;

        // Check if cache entry is still valid
        const file = std.Io.Dir.cwd().openFile(std.Options.debug_io, path, .{}) catch return null;
        defer file.close(std.Options.debug_io);

        const stat = file.stat(std.Options.debug_io) catch return null;
        const mtime = stat.mtime;

        // Check if file has been modified
        if (mtime.nanoseconds != cached.mtime_ns) {
            // File modified, invalidate cache
            return null;
        }

        // Skip TTL check for simplicity (file modification time is more reliable)

        // Cache hit - return content
        return cached.content;
    }

    /// Add script to cache
    fn addToCache(self: *ScriptManager, path: []const u8, content: []const u8) !void {
        // Check cache size limit
        if (self.cache.count() >= self.max_cache_size) {
            try self.evictOldest();
        }

        // Get file modification time
        const file = std.Io.Dir.cwd().openFile(std.Options.debug_io, path, .{}) catch return;
        defer file.close(std.Options.debug_io);
        const stat = file.stat(std.Options.debug_io) catch return;
        const mtime = stat.mtime;

        // Count lines
        var line_count: usize = 0;
        for (content) |c| {
            if (c == '\n') line_count += 1;
        }

        // Create cache entry
        const cached = CachedScript{
            .path = try self.allocator.dupe(u8, path),
            .content = try self.allocator.dupe(u8, content),
            .mtime_ns = mtime.nanoseconds,
            .line_count = line_count,
            .allocator = self.allocator,
        };

        // Store in cache
        const path_key = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_key);
        try self.cache.put(path_key, cached);
    }

    /// Evict oldest cache entry
    fn evictOldest(self: *ScriptManager) !void {
        var oldest_key: ?[]const u8 = null;
        var oldest_time: i128 = std.math.maxInt(i128);

        var iter = self.cache.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.mtime_ns < oldest_time) {
                oldest_time = entry.value_ptr.mtime_ns;
                oldest_key = entry.key_ptr.*;
            }
        }

        if (oldest_key) |key| {
            if (self.cache.fetchRemove(key)) |entry| {
                var cached = entry.value;
                cached.deinit();
                self.allocator.free(entry.key);
            }
        }
    }

    /// Clear all cached scripts
    pub fn clearCache(self: *ScriptManager) void {
        var iter = self.cache.iterator();
        while (iter.next()) |entry| {
            var cached = entry.value_ptr;
            cached.deinit();
            self.allocator.free(entry.key_ptr.*);
        }
        self.cache.clearRetainingCapacity();
    }

    /// Get cache statistics
    pub fn getCacheStats(self: *ScriptManager) struct {
        count: usize,
        max_size: usize,
        enabled: bool,
    } {
        return .{
            .count = self.cache.count(),
            .max_size = self.max_cache_size,
            .enabled = self.cache_enabled,
        };
    }

    /// Validate script syntax (basic check)
    pub fn validateScript(self: *ScriptManager, path: []const u8) !bool {
        const content = try self.loadScript(path);
        defer if (!self.cache_enabled) self.allocator.free(content);

        // Basic validation: check for unmatched quotes, braces
        var in_single_quote = false;
        var in_double_quote = false;
        var brace_count: i32 = 0;
        var paren_count: i32 = 0;
        var case_depth: i32 = 0;

        var i: usize = 0;
        while (i < content.len) : (i += 1) {
            const c = content[i];

            // Handle escapes
            if (c == '\\' and i + 1 < content.len) {
                i += 1;
                continue;
            }

            // Handle comments (skip to end of line)
            // But NOT inside parameter expansions like ${#var}
            if (!in_single_quote and !in_double_quote and c == '#') {
                // Check if this # is inside ${...} — look back for unmatched ${
                if (brace_count <= 0 or i < 2 or content[i - 1] != '{') {
                    // Check more carefully — if brace_count > 0 we might be in ${...}
                    // Only treat as comment if brace_count is 0 (not inside any braces)
                    if (brace_count <= 0) {
                        while (i < content.len and content[i] != '\n') : (i += 1) {}
                        continue;
                    }
                }
            }

            // Skip parameter expansions ${...} — don't parse inside them
            if (!in_single_quote and !in_double_quote and c == '$' and i + 1 < content.len and content[i + 1] == '{') {
                // Skip to matching }, tracking nesting
                var depth: i32 = 0;
                i += 1; // skip $, now at {
                while (i < content.len) : (i += 1) {
                    if (content[i] == '\\' and i + 1 < content.len) {
                        i += 1;
                        continue;
                    }
                    if (content[i] == '{') depth += 1;
                    if (content[i] == '}') {
                        depth -= 1;
                        if (depth <= 0) break;
                    }
                }
                continue;
            }

            if (!in_double_quote and c == '\'') {
                in_single_quote = !in_single_quote;
            } else if (!in_single_quote and c == '"') {
                in_double_quote = !in_double_quote;
            } else if (!in_single_quote and !in_double_quote) {
                // Track case/esac depth to ignore ) in case patterns
                if (c == 'c' and i + 4 < content.len and
                    std.mem.eql(u8, content[i .. i + 4], "case") and
                    (i == 0 or content[i - 1] == ' ' or content[i - 1] == '\n' or content[i - 1] == '\t' or content[i - 1] == ';') and
                    (i + 4 >= content.len or content[i + 4] == ' ' or content[i + 4] == '\t'))
                {
                    case_depth += 1;
                    i += 3;
                    continue;
                }
                if (c == 'e' and i + 4 <= content.len and
                    std.mem.eql(u8, content[i .. i + 4], "esac") and
                    (i == 0 or content[i - 1] == ' ' or content[i - 1] == '\n' or content[i - 1] == '\t' or content[i - 1] == ';') and
                    (i + 4 >= content.len or content[i + 4] == ' ' or content[i + 4] == '\n' or content[i + 4] == '\t' or content[i + 4] == ';'))
                {
                    case_depth -= 1;
                    i += 3;
                    continue;
                }

                if (c == '{') brace_count += 1;
                if (c == '}') brace_count -= 1;
                if (c == '(') paren_count += 1;
                // In case blocks, ) is a pattern terminator, not a closing paren
                if (c == ')' and case_depth <= 0) paren_count -= 1;
            }
        }

        if (in_single_quote or in_double_quote) {
            IO.eprint("den: validation error: unmatched quotes in '{s}'\n", .{path}) catch {};
            return false;
        }

        if (brace_count != 0) {
            IO.eprint("den: validation error: unmatched braces in '{s}'\n", .{path}) catch {};
            return false;
        }

        if (paren_count != 0) {
            IO.eprint("den: validation error: unmatched parentheses in '{s}'\n", .{path}) catch {};
            return false;
        }

        return true;
    }

    /// Execute script with enhanced error handling
    pub fn executeScript(self: *ScriptManager, shell: *Shell, path: []const u8, args: []const []const u8) anyerror!ScriptResult {
        // Load script (may use cache)
        const content = try self.loadScript(path);
        defer if (!self.cache_enabled) self.allocator.free(content);

        // Validate before execution
        if (!try self.validateScript(path)) {
            return ScriptResult{
                .exit_code = 1,
                .line_executed = 0,
                .error_message = try self.allocator.dupe(u8, "Script validation failed"),
            };
        }

        // Setup positional parameters
        var param_count: usize = 0;
        for (args) |arg| {
            if (param_count >= 64) break;
            const param_copy = try self.allocator.dupe(u8, arg);
            shell.positional_params[param_count] = param_copy;
            param_count += 1;
        }
        shell.positional_params_count = param_count;

        // Set shell name
        const shell_name_copy = try self.allocator.dupe(u8, path);
        shell.shell_name = shell_name_copy;

        // Convert lines to array for control flow processing
        var lines_buffer: [10000][]const u8 = undefined;
        var lines_count: usize = 0;

        var line_iter = std.mem.splitScalar(u8, content, '\n');
        while (line_iter.next()) |line| {
            if (lines_count >= lines_buffer.len) return error.TooManyLines;
            lines_buffer[lines_count] = try self.allocator.dupe(u8, line);
            lines_count += 1;
        }
        const lines = lines_buffer[0..lines_count];
        defer {
            for (lines) |line| {
                self.allocator.free(line);
            }
        }

        // Execute with control flow support
        var line_num: usize = 0;
        var parser = ControlFlowParser.init(self.allocator);
        var executor = ControlFlowExecutor.init(shell);
        var func_parser = FunctionParser.init(self.allocator);

        while (line_num < lines.len) : (line_num += 1) {
            shell.current_line = line_num + 1;
            const trimmed = std.mem.trim(u8, lines[line_num], &std.ascii.whitespace);

            // Skip empty lines and comments
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            // Check for function definition
            // function name { ... } or name() { ... }
            const is_function_keyword = std.mem.startsWith(u8, trimmed, "function ");

            // For name() syntax, check if line contains () followed by { (either same line or next)
            var is_paren_syntax = false;
            if (std.mem.indexOf(u8, trimmed, "()")) |_| {
                // Has (), now check for { on same line or next line
                if (std.mem.indexOf(u8, trimmed, "{") != null) {
                    is_paren_syntax = true;
                } else if (line_num + 1 < lines.len) {
                    const next_trimmed = std.mem.trim(u8, lines[line_num + 1], &std.ascii.whitespace);
                    if (std.mem.startsWith(u8, next_trimmed, "{")) {
                        is_paren_syntax = true;
                    }
                }
            }

            if (is_function_keyword or is_paren_syntax) {
                const result = func_parser.parseFunction(lines, line_num) catch {
                    shell.last_exit_code = 1;
                    shell.executeErrTrap();
                    break;
                };
                defer {
                    shell.allocator.free(result.name);
                    for (result.body) |line| shell.allocator.free(line);
                    shell.allocator.free(result.body);
                }
                // Define the function
                shell.function_manager.defineFunction(result.name, result.body, false) catch {
                    shell.last_exit_code = 1;
                    shell.executeErrTrap();
                    break;
                };
                line_num = result.end;
                continue;
            }

            // Check for control flow keywords
            if (std.mem.startsWith(u8, trimmed, "if ")) {
                // One-liner if (has fi on same line) - delegate to executeCommand
                if (std.mem.indexOf(u8, trimmed, "fi") != null) {
                    _ = shell.executeCommand(trimmed) catch {};
                } else {
                    var result = parser.parseIf(lines, line_num) catch {
                        shell.last_exit_code = 1;
                        shell.executeErrTrap();
                        break;
                    };
                    defer result.stmt.deinit();
                    shell.last_exit_code = executor.executeIf(&result.stmt) catch 1;
                    if (shell.last_exit_code != 0) {
                        shell.executeErrTrap();
                    }
                    line_num = result.end;
                }
                continue;
            }

            if (std.mem.startsWith(u8, trimmed, "while ")) {
                // One-liner while (has done on same line) - delegate to executeCommand
                if (std.mem.indexOf(u8, trimmed, "done") != null) {
                    _ = shell.executeCommand(trimmed) catch {};
                } else {
                    var result = parser.parseWhile(lines, line_num, false) catch {
                        shell.last_exit_code = 1;
                        shell.executeErrTrap();
                        break;
                    };
                    defer result.loop.deinit();
                    shell.last_exit_code = executor.executeWhile(&result.loop) catch 1;
                    if (shell.last_exit_code != 0) {
                        shell.executeErrTrap();
                    }
                    line_num = result.end;
                }
                continue;
            }

            if (std.mem.startsWith(u8, trimmed, "until ")) {
                // One-liner until (has done on same line) - delegate to executeCommand
                if (std.mem.indexOf(u8, trimmed, "done") != null) {
                    _ = shell.executeCommand(trimmed) catch {};
                } else {
                    var result = parser.parseWhile(lines, line_num, true) catch {
                        shell.last_exit_code = 1;
                        shell.executeErrTrap();
                        break;
                    };
                    defer result.loop.deinit();
                    shell.last_exit_code = executor.executeWhile(&result.loop) catch 1;
                    if (shell.last_exit_code != 0) {
                        shell.executeErrTrap();
                    }
                    line_num = result.end;
                }
                continue;
            }

            if (std.mem.startsWith(u8, trimmed, "for ((")) {
                // Collect multi-line C-style for loop and delegate to executeCommand
                // which has proper arithmetic handling via shell/loop_execution.zig
                if (std.mem.indexOf(u8, trimmed, "done") != null) {
                    // One-liner - pass directly
                    _ = shell.executeCommand(trimmed) catch {};
                } else {
                    // Collect lines until matching 'done', tracking nesting depth
                    var combined: std.ArrayListUnmanaged(u8) = .empty;
                    defer combined.deinit(self.allocator);
                    combined.appendSlice(self.allocator, trimmed) catch {};
                    var do_done_depth: i32 = 1; // We already have one 'do' from the for line
                    while (line_num + 1 < lines.len) {
                        line_num += 1;
                        const body_line = std.mem.trim(u8, lines[line_num], &std.ascii.whitespace);
                        combined.append(self.allocator, '\n') catch {};
                        combined.appendSlice(self.allocator, body_line) catch {};
                        // Track nested do/done depth
                        if (std.mem.indexOf(u8, body_line, "; do") != null or
                            std.mem.endsWith(u8, body_line, " do") or
                            std.mem.eql(u8, body_line, "do"))
                        {
                            do_done_depth += 1;
                        }
                        if (std.mem.eql(u8, body_line, "done") or
                            std.mem.startsWith(u8, body_line, "done;") or
                            std.mem.startsWith(u8, body_line, "done "))
                        {
                            do_done_depth -= 1;
                            if (do_done_depth <= 0) break;
                        }
                    }
                    _ = shell.executeCommand(combined.items) catch {};
                }
                continue;
            }

            if (std.mem.startsWith(u8, trimmed, "for ")) {
                // One-liner for loop (has done on same line) - delegate to executeCommand
                // which handles semicolon-to-newline conversion via executeControlFlowOneliner
                if (std.mem.indexOf(u8, trimmed, "done") != null) {
                    _ = shell.executeCommand(trimmed) catch {};
                } else {
                    var result = parser.parseFor(lines, line_num) catch {
                        shell.last_exit_code = 1;
                        shell.executeErrTrap();
                        break;
                    };
                    defer result.loop.deinit();
                    shell.last_exit_code = executor.executeFor(&result.loop) catch 1;
                    if (shell.last_exit_code != 0) {
                        shell.executeErrTrap();
                    }
                    line_num = result.end;
                }
                continue;
            }

            if (std.mem.startsWith(u8, trimmed, "case ")) {
                // One-liner case (has esac on same line) - delegate to executeCommand
                if (std.mem.indexOf(u8, trimmed, "esac") != null) {
                    _ = shell.executeCommand(trimmed) catch {};
                } else {
                    var result = parser.parseCase(lines, line_num) catch {
                        shell.last_exit_code = 1;
                        shell.executeErrTrap();
                        break;
                    };
                    defer result.stmt.deinit();
                    shell.last_exit_code = executor.executeCase(&result.stmt) catch 1;
                    if (shell.last_exit_code != 0) {
                        shell.executeErrTrap();
                    }
                    line_num = result.end;
                }
                continue;
            }

            // Collect heredoc content: join current line with subsequent lines until delimiter
            if (std.mem.indexOf(u8, trimmed, "<<") != null) {
                if (extractHeredocDelimiter(trimmed)) |delimiter| {
                    var combined: std.ArrayListUnmanaged(u8) = .empty;
                    defer combined.deinit(self.allocator);
                    combined.appendSlice(self.allocator, trimmed) catch {};
                    combined.append(self.allocator, '\n') catch {};
                    // Collect lines until we find the delimiter
                    while (line_num + 1 < lines.len) {
                        line_num += 1;
                        const heredoc_line = lines[line_num];
                        combined.appendSlice(self.allocator, heredoc_line) catch {};
                        combined.append(self.allocator, '\n') catch {};
                        const htrimmed = std.mem.trim(u8, heredoc_line, &std.ascii.whitespace);
                        if (std.mem.eql(u8, htrimmed, delimiter)) break;
                    }
                    _ = shell.executeCommand(combined.items) catch {};
                    continue;
                }
            }

            // Execute regular command (ignoring errors - exit code set in shell)
            // Note: executeCommand already handles ERR trap execution
            _ = shell.executeCommand(trimmed) catch {};

            // Check if we should exit due to errexit
            if (shell.option_errexit and shell.last_exit_code != 0) {
                shell.current_line = 0;
                return ScriptResult{
                    .exit_code = shell.last_exit_code,
                    .line_executed = line_num,
                    .error_message = null,
                };
            }
        }

        shell.current_line = 0;

        return ScriptResult{
            .exit_code = shell.last_exit_code,
            .line_executed = line_num,
            .error_message = null,
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "ScriptManager init and deinit" {
    var mgr = ScriptManager.init(std.testing.allocator);
    defer mgr.deinit();

    try std.testing.expect(mgr.cache_enabled);
    try std.testing.expectEqual(ScriptManager.DEFAULT_CACHE_SIZE, mgr.max_cache_size);
}

test "ScriptManager cache stats" {
    var mgr = ScriptManager.init(std.testing.allocator);
    defer mgr.deinit();

    const stats = mgr.getCacheStats();
    try std.testing.expectEqual(@as(usize, 0), stats.count);
    try std.testing.expect(stats.enabled);
}

test "CachedScript uses i128 for mtime" {
    // Ensures the i96 → i128 change is in effect. @hasField/@FieldType are
    // version-agnostic; the raw @typeInfo().fields shape changed across zig releases.
    try std.testing.expect(@hasField(CachedScript, "mtime_ns"));
    try std.testing.expectEqual(i128, @FieldType(CachedScript, "mtime_ns"));
}

test "extractHeredocDelimiter basic" {
    // EOF marker
    const d1 = extractHeredocDelimiter("cat << EOF");
    try std.testing.expect(d1 != null);
    try std.testing.expectEqualStrings("EOF", d1.?);

    // Quoted delimiter
    const d2 = extractHeredocDelimiter("cat << 'END'");
    try std.testing.expect(d2 != null);
    try std.testing.expectEqualStrings("END", d2.?);

    // Double-quoted
    const d3 = extractHeredocDelimiter("cat << \"FOO\"");
    try std.testing.expect(d3 != null);
    try std.testing.expectEqualStrings("FOO", d3.?);

    // <<- variant (tab strip)
    const d4 = extractHeredocDelimiter("cat <<- TAB_EOF");
    try std.testing.expect(d4 != null);
    try std.testing.expectEqualStrings("TAB_EOF", d4.?);
}

test "extractHeredocDelimiter rejects herestring" {
    // <<< is a herestring, not a heredoc
    try std.testing.expect(extractHeredocDelimiter("cat <<< text") == null);
}

test "extractHeredocDelimiter handles no delimiter" {
    try std.testing.expect(extractHeredocDelimiter("cat hello") == null);
    try std.testing.expect(extractHeredocDelimiter("cat <<") == null);
}
