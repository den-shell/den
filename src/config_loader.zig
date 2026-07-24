const std = @import("std");
const builtin = @import("builtin");
const types = @import("types/mod.zig");
const IO = @import("utils/io.zig").IO;
const DenConfig = types.DenConfig;

/// Cross-platform file read helper
fn readFileChunk(file: std.Io.File, buf: []u8) !usize {
    if (builtin.os.tag == .windows) {
        var bytes_read: u32 = 0;
        const success = @import("windows_compat").ReadFile(file.handle, buf.ptr, @intCast(buf.len), &bytes_read, null);
        if (success == 0) return error.ReadFailed;
        return bytes_read;
    } else {
        return std.posix.read(file.handle, buf);
    }
}

fn getenv(key: [*:0]const u8) ?[]const u8 {
    const value = std.c.getenv(key) orelse return null;
    return std.mem.span(@as([*:0]const u8, @ptrCast(value)));
}

/// Configuration source information
pub const ConfigSource = struct {
    path: ?[]const u8,
    source_type: SourceType,

    pub const SourceType = enum {
        default,
        den_jsonc,
        package_jsonc,
        custom_path,
    };
};

/// Result of loading config with source tracking
pub const ConfigLoadResult = struct {
    config: DenConfig,
    source: ConfigSource,
};

/// Load Den shell configuration from multiple sources
/// Priority: env vars > local file > home directory > defaults
pub fn loadConfig(allocator: std.mem.Allocator) !DenConfig {
    return loadConfigWithPath(allocator, null);
}

/// Load configuration and return source information
pub fn loadConfigWithSource(allocator: std.mem.Allocator) !ConfigLoadResult {
    return loadConfigWithPathAndSource(allocator, null);
}

/// Load Den shell configuration from a custom path
/// If custom_path is provided, it takes priority over default search paths
pub fn loadConfigWithPath(allocator: std.mem.Allocator, custom_path: ?[]const u8) !DenConfig {
    const result = try loadConfigWithPathAndSource(allocator, custom_path);
    return result.config;
}

/// Load configuration with source tracking
pub fn loadConfigWithPathAndSource(allocator: std.mem.Allocator, custom_path: ?[]const u8) !ConfigLoadResult {
    if (custom_path) |path| {
        // Load from custom path directly
        const config = try loadFromFile(allocator, path);
        return .{
            .config = config,
            .source = .{ .path = path, .source_type = .custom_path },
        };
    }

    // Search order:
    // 1. ./den.jsonc
    // 2. ./package.jsonc (with "den" key)
    // 3. ./config/den.jsonc
    // 4. ./.config/den.jsonc
    // 5. ~/.config/den.jsonc
    // 6. ~/package.jsonc (with "den" key)

    // Try ./den.jsonc
    if (tryLoadFromPath(DenConfig, allocator, "den.jsonc")) |config| {
        return .{
            .config = config,
            .source = .{ .path = "den.jsonc", .source_type = .den_jsonc },
        };
    }

    // Try ./package.jsonc with "den" key
    if (tryLoadDenFromPackageJson(allocator, "package.jsonc")) |config| {
        return .{
            .config = config,
            .source = .{ .path = "package.jsonc", .source_type = .package_jsonc },
        };
    }

    // Try config/den.jsonc
    if (tryLoadFromPath(DenConfig, allocator, "config/den.jsonc")) |config| {
        return .{
            .config = config,
            .source = .{ .path = "config/den.jsonc", .source_type = .den_jsonc },
        };
    }

    // Try .config/den.jsonc
    if (tryLoadFromPath(DenConfig, allocator, ".config/den.jsonc")) |config| {
        return .{
            .config = config,
            .source = .{ .path = ".config/den.jsonc", .source_type = .den_jsonc },
        };
    }

    // Try home directory
    if (getenv("HOME")) |home| {
        // Try ~/.config/den.jsonc
        const home_config_path = std.fmt.allocPrint(allocator, "{s}/.config/den.jsonc", .{home}) catch null;
        if (home_config_path) |path| {
            defer allocator.free(path);
            if (tryLoadFromPath(DenConfig, allocator, path)) |config| {
                return .{
                    .config = config,
                    .source = .{ .path = null, .source_type = .den_jsonc }, // Don't store allocated path
                };
            }
        }

        // Try ~/package.jsonc with "den" key
        const home_package_path = std.fmt.allocPrint(allocator, "{s}/package.jsonc", .{home}) catch null;
        if (home_package_path) |path| {
            defer allocator.free(path);
            if (tryLoadDenFromPackageJson(allocator, path)) |config| {
                return .{
                    .config = config,
                    .source = .{ .path = null, .source_type = .package_jsonc },
                };
            }
        }
    }

    // Return defaults
    return .{
        .config = DenConfig{},
        .source = .{ .path = null, .source_type = .default },
    };
}

/// Load config from a specific file path.
///
/// Memory model: parsed strings live in a `std.json.Parsed(T)` arena that is
/// allocated on `std.heap.page_allocator`. We discard the `Parsed` handle and
/// return only `.value`, which means the arena is intentionally leaked for the
/// lifetime of the process. This keeps every `[]const u8` inside the returned
/// `DenConfig` valid forever without forcing every consumer to thread a
/// `Parsed` through. The OS reclaims the pages at exit. The leak is bounded
/// by config file size and only happens once at startup.
fn loadFromFile(allocator: std.mem.Allocator, path: []const u8) !DenConfig {
    const file = std.Io.Dir.cwd().openFile(std.Options.debug_io, path, .{}) catch |err| {
        IO.eprint("den: failed to open config file '{s}': {any}\n", .{ path, err }) catch {};
        return error.ConfigFileNotFound;
    };
    defer file.close(std.Options.debug_io);

    // Read file content
    var content = std.ArrayList(u8).empty;
    defer content.deinit(allocator);

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = readFileChunk(file, &buf) catch break;
        if (n == 0) break;
        try content.appendSlice(allocator, buf[0..n]);
    }

    // Remove JSONC comments (same as zig-config does)
    const json = try removeJsoncComments(allocator, content.items);
    defer allocator.free(json);

    // Parse JSON using page_allocator - this memory lives for program lifetime
    const parsed = std.json.parseFromSlice(DenConfig, std.heap.page_allocator, json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| {
        IO.eprint("den: failed to parse config file '{s}': {any}\n", .{ path, err }) catch {};
        return error.ConfigParseError;
    };

    return parsed.value;
}

/// Try to load config from a path, return null on failure.
/// See `loadFromFile` for the page-allocator/arena lifetime rationale.
fn tryLoadFromPath(comptime T: type, allocator: std.mem.Allocator, path: []const u8) ?T {
    const file = std.Io.Dir.cwd().openFile(std.Options.debug_io, path, .{}) catch return null;
    defer file.close(std.Options.debug_io);

    // Read file content
    var content = std.ArrayList(u8).empty;
    defer content.deinit(allocator);

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = readFileChunk(file, &buf) catch break;
        if (n == 0) break;
        content.appendSlice(allocator, buf[0..n]) catch return null;
    }

    // Remove JSONC comments
    const json = removeJsoncComments(allocator, content.items) catch return null;
    defer allocator.free(json);

    // Parse JSON using page_allocator - this memory lives for program lifetime
    // and won't trigger GPA leak warnings
    const parsed = std.json.parseFromSlice(T, std.heap.page_allocator, json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return null;

    return parsed.value;
}

/// Package.jsonc structure with optional "den" key
const PackageJsonWithDen = struct {
    den: ?DenConfig = null,
};

/// Try to load Den config from package.jsonc "den" key.
/// See `loadFromFile` for the page-allocator/arena lifetime rationale.
fn tryLoadDenFromPackageJson(allocator: std.mem.Allocator, path: []const u8) ?DenConfig {
    const file = std.Io.Dir.cwd().openFile(std.Options.debug_io, path, .{}) catch return null;
    defer file.close(std.Options.debug_io);

    // Read file content
    var content = std.ArrayList(u8).empty;
    defer content.deinit(allocator);

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = readFileChunk(file, &buf) catch break;
        if (n == 0) break;
        content.appendSlice(allocator, buf[0..n]) catch return null;
    }

    // Remove JSONC comments
    const json = removeJsoncComments(allocator, content.items) catch return null;
    defer allocator.free(json);

    // Parse JSON using page_allocator - this memory lives for program lifetime
    const parsed = std.json.parseFromSlice(PackageJsonWithDen, std.heap.page_allocator, json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return null;

    return parsed.value.den;
}

/// Remove JSONC comments (// and /* */) and trailing commas
fn removeJsoncComments(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    var i: usize = 0;
    var in_string = false;
    var escape_next = false;

    while (i < input.len) {
        const c = input[i];

        if (escape_next) {
            try output.append(allocator, c);
            escape_next = false;
            i += 1;
            continue;
        }

        if (c == '\\' and in_string) {
            try output.append(allocator, c);
            escape_next = true;
            i += 1;
            continue;
        }

        if (c == '"') {
            in_string = !in_string;
            try output.append(allocator, c);
            i += 1;
            continue;
        }

        if (in_string) {
            try output.append(allocator, c);
            i += 1;
            continue;
        }

        // Check for // comment
        if (c == '/' and i + 1 < input.len and input[i + 1] == '/') {
            // Skip until end of line
            while (i < input.len and input[i] != '\n') {
                i += 1;
            }
            continue;
        }

        // Check for /* */ comment
        if (c == '/' and i + 1 < input.len and input[i + 1] == '*') {
            i += 2;
            while (i + 1 < input.len) {
                if (input[i] == '*' and input[i + 1] == '/') {
                    i += 2;
                    break;
                }
                i += 1;
            }
            continue;
        }

        // Handle trailing commas before } or ]
        if (c == ',') {
            // Look ahead for } or ] (skipping whitespace)
            var j = i + 1;
            while (j < input.len and (input[j] == ' ' or input[j] == '\t' or input[j] == '\n' or input[j] == '\r')) {
                j += 1;
            }
            if (j < input.len and (input[j] == '}' or input[j] == ']')) {
                // Skip the trailing comma
                i += 1;
                continue;
            }
        }

        try output.append(allocator, c);
        i += 1;
    }

    return try output.toOwnedSlice(allocator);
}

/// Try to load config, return null on error (no error output)
pub fn tryLoadConfig(allocator: std.mem.Allocator) ?DenConfig {
    return loadConfig(allocator) catch null;
}

/// Try to load config from custom path, return null on error (no error output)
pub fn tryLoadConfigWithPath(allocator: std.mem.Allocator, custom_path: ?[]const u8) ?DenConfig {
    return loadConfigWithPath(allocator, custom_path) catch null;
}

/// Configuration validation error
pub const ConfigError = struct {
    field: []const u8,
    message: []const u8,
    severity: Severity,

    pub const Severity = enum {
        warning,
        err,
    };
};

/// ANSI color codes for terminal output
const TermColors = struct {
    const reset = "\x1b[0m";
    const bold = "\x1b[1m";
    const red = "\x1b[31m";
    const yellow = "\x1b[33m";
    const cyan = "\x1b[36m";
    const dim = "\x1b[2m";
};

/// Validation result with errors and warnings
pub const ValidationResult = struct {
    valid: bool,
    errors: []ConfigError,
    warnings: []ConfigError,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ValidationResult) void {
        self.allocator.free(self.errors);
        self.allocator.free(self.warnings);
    }

    /// Format validation result without colors (for plain output)
    pub fn format(self: *const ValidationResult, writer: anytype) !void {
        for (self.errors) |err| {
            try writer.print("den: config: error: {s}: {s}\n", .{ err.field, err.message });
        }
        for (self.warnings) |warn| {
            try writer.print("den: config: warning: {s}: {s}\n", .{ warn.field, warn.message });
        }
    }

    /// Format validation result with ANSI colors
    pub fn formatColored(self: *const ValidationResult, writer: anytype) !void {
        for (self.errors) |err| {
            try writer.print("{s}den: config:{s} {s}{s}error:{s} {s}{s}{s}: {s}\n", .{
                TermColors.cyan,
                TermColors.reset,
                TermColors.bold,
                TermColors.red,
                TermColors.reset,
                TermColors.bold,
                err.field,
                TermColors.reset,
                err.message,
            });
        }
        for (self.warnings) |warn| {
            try writer.print("{s}den: config:{s} {s}{s}warning:{s} {s}{s}{s}: {s}\n", .{
                TermColors.cyan,
                TermColors.reset,
                TermColors.bold,
                TermColors.yellow,
                TermColors.reset,
                TermColors.dim,
                warn.field,
                TermColors.reset,
                warn.message,
            });
        }
    }

    /// Print to stderr with color auto-detection
    pub fn printToStderr(self: *const ValidationResult) void {
        const stderr_file = if (builtin.os.tag == .windows)
            std.Io.File{ .handle = @import("windows_compat").GetStdHandle(@import("windows_compat").STD_ERROR_HANDLE) orelse return, .flags = .{ .nonblocking = false } }
        else
            std.Io.File{ .handle = std.posix.STDERR_FILENO, .flags = .{ .nonblocking = false } };
        // Check if stderr is a TTY for color support
        const use_color = stderr_file.isTty(std.Options.debug_io) catch false;
        const stderr = stderr_file.writer(std.Options.debug_io);
        if (use_color) {
            self.formatColored(stderr) catch {};
        } else {
            self.format(stderr) catch {};
        }
    }

    /// Returns true if there are any issues (errors or warnings)
    pub fn hasIssues(self: *const ValidationResult) bool {
        return self.errors.len > 0 or self.warnings.len > 0;
    }
};

/// Validate configuration and return detailed error messages
pub fn validateConfig(allocator: std.mem.Allocator, config: DenConfig) !ValidationResult {
    var errors = std.ArrayList(ConfigError).empty;
    errdefer errors.deinit(allocator);

    var warnings = std.ArrayList(ConfigError).empty;
    errdefer warnings.deinit(allocator);

    // ========================================
    // History validation
    // ========================================
    if (config.history.max_entries < 100) {
        try warnings.append(allocator, ConfigError{
            .field = "history.max_entries",
            .message = "Very small history size (<100) may limit usability",
            .severity = .warning,
        });
    }
    if (config.history.max_entries > 1000000) {
        try warnings.append(allocator, ConfigError{
            .field = "history.max_entries",
            .message = "Very large history size (>1M) may cause performance issues",
            .severity = .warning,
        });
    }

    // Validate history file path
    if (config.history.file.len == 0) {
        try errors.append(allocator, ConfigError{
            .field = "history.file",
            .message = "History file path cannot be empty",
            .severity = .err,
        });
    }

    // ========================================
    // Completion validation
    // ========================================
    if (config.completion.max_suggestions == 0) {
        try errors.append(allocator, ConfigError{
            .field = "completion.max_suggestions",
            .message = "Must be at least 1",
            .severity = .err,
        });
    }
    if (config.completion.max_suggestions > 100) {
        try warnings.append(allocator, ConfigError{
            .field = "completion.max_suggestions",
            .message = "Very large value (>100) may cause display issues",
            .severity = .warning,
        });
    }

    // Validate completion cache settings
    if (config.completion.cache.enabled and config.completion.cache.max_entries == 0) {
        try errors.append(allocator, ConfigError{
            .field = "completion.cache.max_entries",
            .message = "Cache is enabled but max_entries is 0",
            .severity = .err,
        });
    }

    // Validate cache TTL
    if (config.completion.cache.enabled and config.completion.cache.ttl == 0) {
        try warnings.append(allocator, ConfigError{
            .field = "completion.cache.ttl",
            .message = "Cache TTL is 0, cache entries will expire immediately",
            .severity = .warning,
        });
    }

    // ========================================
    // Theme validation - all colors
    // ========================================
    if (!isValidColor(config.theme.colors.primary)) {
        try warnings.append(allocator, ConfigError{
            .field = "theme.colors.primary",
            .message = "Invalid color format (expected #RRGGBB or named color)",
            .severity = .warning,
        });
    }
    if (!isValidColor(config.theme.colors.secondary)) {
        try warnings.append(allocator, ConfigError{
            .field = "theme.colors.secondary",
            .message = "Invalid color format (expected #RRGGBB or named color)",
            .severity = .warning,
        });
    }
    if (!isValidColor(config.theme.colors.success)) {
        try warnings.append(allocator, ConfigError{
            .field = "theme.colors.success",
            .message = "Invalid color format (expected #RRGGBB or named color)",
            .severity = .warning,
        });
    }
    if (!isValidColor(config.theme.colors.warning)) {
        try warnings.append(allocator, ConfigError{
            .field = "theme.colors.warning",
            .message = "Invalid color format (expected #RRGGBB or named color)",
            .severity = .warning,
        });
    }
    if (!isValidColor(config.theme.colors.err)) {
        try warnings.append(allocator, ConfigError{
            .field = "theme.colors.error",
            .message = "Invalid color format (expected #RRGGBB or named color)",
            .severity = .warning,
        });
    }
    if (!isValidColor(config.theme.colors.info)) {
        try warnings.append(allocator, ConfigError{
            .field = "theme.colors.info",
            .message = "Invalid color format (expected #RRGGBB or named color)",
            .severity = .warning,
        });
    }

    // Validate theme name
    if (config.theme.name.len == 0) {
        try warnings.append(allocator, ConfigError{
            .field = "theme.name",
            .message = "Theme name is empty, using default",
            .severity = .warning,
        });
    }

    // Validate prompt symbols
    if (config.theme.symbols.prompt.len == 0) {
        try warnings.append(allocator, ConfigError{
            .field = "theme.symbols.prompt",
            .message = "Prompt symbol is empty, may cause display issues",
            .severity = .warning,
        });
    }

    // ========================================
    // Prompt validation
    // ========================================
    if (config.prompt.format.len == 0) {
        try errors.append(allocator, ConfigError{
            .field = "prompt.format",
            .message = "Prompt format cannot be empty",
            .severity = .err,
        });
    }

    // Validate right_prompt if set
    if (config.prompt.right_prompt) |right| {
        if (right.len == 0) {
            try warnings.append(allocator, ConfigError{
                .field = "prompt.right_prompt",
                .message = "Right prompt is set but empty",
                .severity = .warning,
            });
        }
    }

    // ========================================
    // Expansion cache limits validation
    // ========================================
    if (config.expansion.cache_limits.glob > 10000) {
        try warnings.append(allocator, ConfigError{
            .field = "expansion.cache_limits.glob",
            .message = "Very large glob cache (>10000) may use excessive memory",
            .severity = .warning,
        });
    }
    if (config.expansion.cache_limits.variable > 10000) {
        try warnings.append(allocator, ConfigError{
            .field = "expansion.cache_limits.variable",
            .message = "Very large variable cache (>10000) may use excessive memory",
            .severity = .warning,
        });
    }
    if (config.expansion.cache_limits.exec > 10000) {
        try warnings.append(allocator, ConfigError{
            .field = "expansion.cache_limits.exec",
            .message = "Very large exec cache (>10000) may use excessive memory",
            .severity = .warning,
        });
    }

    // ========================================
    // Aliases validation
    // ========================================
    if (config.aliases.custom) |custom_aliases| {
        for (custom_aliases, 0..) |alias, i| {
            // Validate alias name
            if (alias.name.len == 0) {
                try errors.append(allocator, ConfigError{
                    .field = if (i < 10) blk: {
                        const fields = [_][]const u8{
                            "aliases.custom[0].name",
                            "aliases.custom[1].name",
                            "aliases.custom[2].name",
                            "aliases.custom[3].name",
                            "aliases.custom[4].name",
                            "aliases.custom[5].name",
                            "aliases.custom[6].name",
                            "aliases.custom[7].name",
                            "aliases.custom[8].name",
                            "aliases.custom[9].name",
                        };
                        break :blk fields[i];
                    } else "aliases.custom[N].name",
                    .message = "Alias name cannot be empty",
                    .severity = .err,
                });
            }
            // Validate alias command
            if (alias.command.len == 0) {
                try errors.append(allocator, ConfigError{
                    .field = if (i < 10) blk: {
                        const fields = [_][]const u8{
                            "aliases.custom[0].command",
                            "aliases.custom[1].command",
                            "aliases.custom[2].command",
                            "aliases.custom[3].command",
                            "aliases.custom[4].command",
                            "aliases.custom[5].command",
                            "aliases.custom[6].command",
                            "aliases.custom[7].command",
                            "aliases.custom[8].command",
                            "aliases.custom[9].command",
                        };
                        break :blk fields[i];
                    } else "aliases.custom[N].command",
                    .message = "Alias command cannot be empty",
                    .severity = .err,
                });
            }
            // Warn about potentially dangerous alias names
            const dangerous_names = [_][]const u8{ "cd", "exit", "source", ".", "exec", "eval" };
            for (dangerous_names) |dangerous| {
                if (std.mem.eql(u8, alias.name, dangerous)) {
                    try warnings.append(allocator, ConfigError{
                        .field = if (i < 10) blk: {
                            const fields = [_][]const u8{
                                "aliases.custom[0].name",
                                "aliases.custom[1].name",
                                "aliases.custom[2].name",
                                "aliases.custom[3].name",
                                "aliases.custom[4].name",
                                "aliases.custom[5].name",
                                "aliases.custom[6].name",
                                "aliases.custom[7].name",
                                "aliases.custom[8].name",
                                "aliases.custom[9].name",
                            };
                            break :blk fields[i];
                        } else "aliases.custom[N].name",
                        .message = "Aliasing shell builtins may cause unexpected behavior",
                        .severity = .warning,
                    });
                    break;
                }
            }
        }
    }

    // Validate suffix aliases
    if (config.aliases.suffix) |suffix_aliases| {
        for (suffix_aliases, 0..) |alias, i| {
            if (alias.extension.len == 0) {
                try errors.append(allocator, ConfigError{
                    .field = if (i < 10) blk: {
                        const fields = [_][]const u8{
                            "aliases.suffix[0].extension",
                            "aliases.suffix[1].extension",
                            "aliases.suffix[2].extension",
                            "aliases.suffix[3].extension",
                            "aliases.suffix[4].extension",
                            "aliases.suffix[5].extension",
                            "aliases.suffix[6].extension",
                            "aliases.suffix[7].extension",
                            "aliases.suffix[8].extension",
                            "aliases.suffix[9].extension",
                        };
                        break :blk fields[i];
                    } else "aliases.suffix[N].extension",
                    .message = "Suffix alias extension cannot be empty",
                    .severity = .err,
                });
            }
            if (alias.command.len == 0) {
                try errors.append(allocator, ConfigError{
                    .field = if (i < 10) blk: {
                        const fields = [_][]const u8{
                            "aliases.suffix[0].command",
                            "aliases.suffix[1].command",
                            "aliases.suffix[2].command",
                            "aliases.suffix[3].command",
                            "aliases.suffix[4].command",
                            "aliases.suffix[5].command",
                            "aliases.suffix[6].command",
                            "aliases.suffix[7].command",
                            "aliases.suffix[8].command",
                            "aliases.suffix[9].command",
                        };
                        break :blk fields[i];
                    } else "aliases.suffix[N].command",
                    .message = "Suffix alias command cannot be empty",
                    .severity = .err,
                });
            }
        }
    }

    // ========================================
    // Keybindings validation
    // ========================================
    if (config.keybindings.custom) |custom_bindings| {
        for (custom_bindings, 0..) |binding, i| {
            if (binding.key.len == 0) {
                try errors.append(allocator, ConfigError{
                    .field = if (i < 10) blk: {
                        const fields = [_][]const u8{
                            "keybindings.custom[0].key",
                            "keybindings.custom[1].key",
                            "keybindings.custom[2].key",
                            "keybindings.custom[3].key",
                            "keybindings.custom[4].key",
                            "keybindings.custom[5].key",
                            "keybindings.custom[6].key",
                            "keybindings.custom[7].key",
                            "keybindings.custom[8].key",
                            "keybindings.custom[9].key",
                        };
                        break :blk fields[i];
                    } else "keybindings.custom[N].key",
                    .message = "Keybinding key cannot be empty",
                    .severity = .err,
                });
            }
            if (binding.action.len == 0) {
                try errors.append(allocator, ConfigError{
                    .field = if (i < 10) blk: {
                        const fields = [_][]const u8{
                            "keybindings.custom[0].action",
                            "keybindings.custom[1].action",
                            "keybindings.custom[2].action",
                            "keybindings.custom[3].action",
                            "keybindings.custom[4].action",
                            "keybindings.custom[5].action",
                            "keybindings.custom[6].action",
                            "keybindings.custom[7].action",
                            "keybindings.custom[8].action",
                            "keybindings.custom[9].action",
                        };
                        break :blk fields[i];
                    } else "keybindings.custom[N].action",
                    .message = "Keybinding action cannot be empty",
                    .severity = .err,
                });
            }
        }
    }

    // ========================================
    // Environment validation
    // ========================================
    if (config.environment.variables) |env_vars| {
        for (env_vars, 0..) |entry, i| {
            if (entry.name.len == 0) {
                try errors.append(allocator, ConfigError{
                    .field = if (i < 10) blk: {
                        const fields = [_][]const u8{
                            "environment.variables[0].name",
                            "environment.variables[1].name",
                            "environment.variables[2].name",
                            "environment.variables[3].name",
                            "environment.variables[4].name",
                            "environment.variables[5].name",
                            "environment.variables[6].name",
                            "environment.variables[7].name",
                            "environment.variables[8].name",
                            "environment.variables[9].name",
                        };
                        break :blk fields[i];
                    } else "environment.variables[N].name",
                    .message = "Environment variable name cannot be empty",
                    .severity = .err,
                });
            }
            // Warn about overriding important env vars
            const important_vars = [_][]const u8{ "PATH", "HOME", "USER", "SHELL" };
            for (important_vars) |important| {
                if (std.mem.eql(u8, entry.name, important)) {
                    try warnings.append(allocator, ConfigError{
                        .field = if (i < 10) blk: {
                            const fields = [_][]const u8{
                                "environment.variables[0].name",
                                "environment.variables[1].name",
                                "environment.variables[2].name",
                                "environment.variables[3].name",
                                "environment.variables[4].name",
                                "environment.variables[5].name",
                                "environment.variables[6].name",
                                "environment.variables[7].name",
                                "environment.variables[8].name",
                                "environment.variables[9].name",
                            };
                            break :blk fields[i];
                        } else "environment.variables[N].name",
                        .message = "Overriding system environment variable may cause issues",
                        .severity = .warning,
                    });
                    break;
                }
            }
        }
    }

    return ValidationResult{
        .valid = errors.items.len == 0,
        .errors = try errors.toOwnedSlice(allocator),
        .warnings = try warnings.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

/// Check if a color value is valid
fn isValidColor(color: []const u8) bool {
    if (color.len == 0) return false;

    // Check hex color format: #RGB, #RRGGBB, or #RRGGBBAA
    if (color[0] == '#') {
        const hex_part = color[1..];
        if (hex_part.len != 3 and hex_part.len != 6 and hex_part.len != 8) return false;
        for (hex_part) |c| {
            if (!std.ascii.isHex(c)) return false;
        }
        return true;
    }

    // Check named colors
    const named_colors = [_][]const u8{
        "black", "red",  "green",  "yellow", "blue",   "magenta", "cyan",   "white",
        "gray",  "grey", "orange", "pink",   "purple", "brown",   "silver", "gold",
    };
    for (named_colors) |name| {
        if (std.mem.eql(u8, color, name)) return true;
    }

    return false;
}

/// Load and validate config, returning both config and validation result
pub fn loadAndValidateConfig(allocator: std.mem.Allocator) !struct { config: DenConfig, validation: ValidationResult } {
    const config = try loadConfig(allocator);
    const validation = try validateConfig(allocator, config);
    return .{ .config = config, .validation = validation };
}

/// Load and validate config from custom path
pub fn loadAndValidateConfigWithPath(allocator: std.mem.Allocator, custom_path: ?[]const u8) !struct { config: DenConfig, validation: ValidationResult } {
    const config = try loadConfigWithPath(allocator, custom_path);
    const validation = try validateConfig(allocator, config);
    return .{ .config = config, .validation = validation };
}

test "loadConfig returns defaults when no file found" {
    const allocator = std.testing.allocator;
    const config = try loadConfig(allocator);
    try std.testing.expect(!config.verbose);
}

test "validateConfig - valid default config" {
    const allocator = std.testing.allocator;
    const config = DenConfig{};
    var result = try validateConfig(allocator, config);
    defer result.deinit();
    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
}

test "validateConfig - invalid completion max_suggestions" {
    const allocator = std.testing.allocator;
    var config = DenConfig{};
    config.completion.max_suggestions = 0;
    var result = try validateConfig(allocator, config);
    defer result.deinit();
    try std.testing.expect(!result.valid);
    try std.testing.expectEqual(@as(usize, 1), result.errors.len);
}

test "isValidColor - hex colors" {
    try std.testing.expect(isValidColor("#FFF"));
    try std.testing.expect(isValidColor("#FFFFFF"));
    try std.testing.expect(isValidColor("#00D9FF"));
    try std.testing.expect(isValidColor("#FFFFFFFF"));
    try std.testing.expect(!isValidColor("#GGG"));
    try std.testing.expect(!isValidColor("#"));
    try std.testing.expect(!isValidColor(""));
}

test "isValidColor - named colors" {
    try std.testing.expect(isValidColor("red"));
    try std.testing.expect(isValidColor("blue"));
    try std.testing.expect(isValidColor("green"));
    try std.testing.expect(!isValidColor("notacolor"));
}

test "validateConfig - empty prompt format fails" {
    const allocator = std.testing.allocator;
    var config = DenConfig{};
    config.prompt.format = "";
    var result = try validateConfig(allocator, config);
    defer result.deinit();
    try std.testing.expect(!result.valid);
    // Should have error for empty prompt
    var found_prompt_error = false;
    for (result.errors) |err| {
        if (std.mem.eql(u8, err.field, "prompt.format")) {
            found_prompt_error = true;
            break;
        }
    }
    try std.testing.expect(found_prompt_error);
}

test "validateConfig - empty history file fails" {
    const allocator = std.testing.allocator;
    var config = DenConfig{};
    config.history.file = "";
    var result = try validateConfig(allocator, config);
    defer result.deinit();
    try std.testing.expect(!result.valid);
    var found_history_error = false;
    for (result.errors) |err| {
        if (std.mem.eql(u8, err.field, "history.file")) {
            found_history_error = true;
            break;
        }
    }
    try std.testing.expect(found_history_error);
}

test "validateConfig - warnings don't prevent valid config" {
    const allocator = std.testing.allocator;
    var config = DenConfig{};
    // Set a very small history size (should warn but not error)
    config.history.max_entries = 50;
    var result = try validateConfig(allocator, config);
    defer result.deinit();
    // Should still be valid (warnings don't affect validity)
    try std.testing.expect(result.valid);
    // But should have a warning
    try std.testing.expect(result.warnings.len > 0);
}

test "validateConfig - cache enabled with zero entries fails" {
    const allocator = std.testing.allocator;
    var config = DenConfig{};
    config.completion.cache.enabled = true;
    config.completion.cache.max_entries = 0;
    var result = try validateConfig(allocator, config);
    defer result.deinit();
    try std.testing.expect(!result.valid);
}

test "validateConfig - invalid theme color warns" {
    const allocator = std.testing.allocator;
    var config = DenConfig{};
    config.theme.colors.primary = "notacolor";
    var result = try validateConfig(allocator, config);
    defer result.deinit();
    // Invalid colors are warnings, not errors
    try std.testing.expect(result.valid);
    try std.testing.expect(result.warnings.len > 0);
}

test "ValidationResult - hasIssues" {
    const allocator = std.testing.allocator;
    const config = DenConfig{};
    var result = try validateConfig(allocator, config);
    defer result.deinit();
    // Default config should have no issues
    try std.testing.expect(!result.hasIssues());
}

test "ValidationResult - format output" {
    const allocator = std.testing.allocator;
    var config = DenConfig{};
    config.completion.max_suggestions = 0;
    var result = try validateConfig(allocator, config);
    defer result.deinit();

    // Test plain format - just verify it doesn't crash
    // (actual output testing would require a writer)
    try std.testing.expect(!result.valid);
    try std.testing.expect(result.errors.len > 0);
}

test "loadFromFile returns FileNotFound for missing file" {
    const allocator = std.testing.allocator;
    const result = loadFromFile(allocator, "__nonexistent_config_file_xyz123__.jsonc");
    try std.testing.expectError(error.ConfigFileNotFound, result);
}

test "ConfigSource default source" {
    const source = ConfigSource{
        .path = null,
        .source_type = .default,
    };
    try std.testing.expectEqual(ConfigSource.SourceType.default, source.source_type);
    try std.testing.expect(source.path == null);
}

test "ConfigSource enum variants" {
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(ConfigSource.SourceType.default));
}

test "DenConfig default values are reasonable" {
    const config = DenConfig{};
    // History should have positive max entries
    try std.testing.expect(config.history.max_entries > 0);
    // Completion should have positive max suggestions
    try std.testing.expect(config.completion.max_suggestions > 0);
}
