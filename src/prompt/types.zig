const std = @import("std");

/// Prompt segment alignment
pub const Alignment = enum {
    left,
    right,
};

/// Prompt segment style
pub const SegmentStyle = struct {
    foreground: ?[]const u8, // Color name or hex
    background: ?[]const u8,
    bold: bool,
    italic: bool,
    underline: bool,

    pub fn initDefault() SegmentStyle {
        return .{
            .foreground = null,
            .background = null,
            .bold = false,
            .italic = false,
            .underline = false,
        };
    }
};

/// Prompt segment
pub const Segment = struct {
    content: []const u8,
    style: SegmentStyle,
    alignment: Alignment,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, content: []const u8, style: SegmentStyle, alignment: Alignment) !Segment {
        return .{
            .content = try allocator.dupe(u8, content),
            .style = style,
            .alignment = alignment,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Segment) void {
        self.allocator.free(self.content);
    }
};

/// Prompt context data
pub const PromptContext = struct {
    // Path info
    current_dir: []const u8,
    home_dir: ?[]const u8,

    // Git info
    git_branch: ?[]const u8,
    git_dirty: bool,
    git_ahead: usize,
    git_behind: usize,
    git_staged: usize,
    git_unstaged: usize,
    git_untracked: usize,
    git_stash: usize,

    // User info
    username: []const u8,
    hostname: []const u8,
    is_root: bool,

    // Command info
    last_exit_code: i32,
    last_duration_ms: ?u64,

    // Prompt symbol (borrowed from theme.symbols.prompt; not owned, never freed)
    prompt_symbol: []const u8 = "\xE2\x9E\x9C", // ➜

    // Runtime info
    node_version: ?[]const u8,
    bun_version: ?[]const u8,
    deno_version: ?[]const u8,
    zig_version: ?[]const u8,
    python_version: ?[]const u8,
    ruby_version: ?[]const u8,
    go_version: ?[]const u8,
    rust_version: ?[]const u8,

    // Package info
    package_version: ?[]const u8,

    // Battery
    battery_percent: ?u8,

    // Time
    current_time: i64,

    // Custom data
    custom_data: std.StringHashMap([]const u8),

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) PromptContext {
        return .{
            .current_dir = "",
            .home_dir = null,
            .git_branch = null,
            .git_dirty = false,
            .git_ahead = 0,
            .git_behind = 0,
            .git_staged = 0,
            .git_unstaged = 0,
            .git_untracked = 0,
            .git_stash = 0,
            .username = "",
            .hostname = "",
            .is_root = false,
            .last_exit_code = 0,
            .last_duration_ms = null,
            .prompt_symbol = "\xE2\x9E\x9C",
            .node_version = null,
            .bun_version = null,
            .deno_version = null,
            .zig_version = null,
            .python_version = null,
            .ruby_version = null,
            .go_version = null,
            .rust_version = null,
            .package_version = null,
            .battery_percent = null,
            .current_time = 0, // Will be updated when needed
            .custom_data = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PromptContext) void {
        if (self.current_dir.len > 0) self.allocator.free(self.current_dir);
        if (self.home_dir) |v| self.allocator.free(v);
        if (self.git_branch) |v| self.allocator.free(v);
        if (self.username.len > 0) self.allocator.free(self.username);
        if (self.hostname.len > 0) self.allocator.free(self.hostname);
        if (self.node_version) |v| self.allocator.free(v);
        if (self.bun_version) |v| self.allocator.free(v);
        if (self.deno_version) |v| self.allocator.free(v);
        if (self.zig_version) |v| self.allocator.free(v);
        if (self.python_version) |v| self.allocator.free(v);
        if (self.ruby_version) |v| self.allocator.free(v);
        if (self.go_version) |v| self.allocator.free(v);
        if (self.rust_version) |v| self.allocator.free(v);
        if (self.package_version) |v| self.allocator.free(v);

        var iter = self.custom_data.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.custom_data.deinit();
    }

    pub fn setCustom(self: *PromptContext, key: []const u8, value: []const u8) !void {
        const key_copy = try self.allocator.dupe(u8, key);
        const value_copy = try self.allocator.dupe(u8, value);
        try self.custom_data.put(key_copy, value_copy);
    }

    pub fn getCustom(self: *const PromptContext, key: []const u8) ?[]const u8 {
        return self.custom_data.get(key);
    }
};

/// Prompt template configuration
pub const PromptTemplate = struct {
    left_format: []const u8,
    right_format: ?[]const u8,
    transient_enabled: bool,
    transient_format: ?[]const u8,

    pub fn initDefault(allocator: std.mem.Allocator) !PromptTemplate {
        // Modern detailed prompt format:
        // ~/Code/den in bold cyan
        // on 🌱 main in bold purple
        // [📝] if dirty
        // 📦 v0.1.0 in bold orange (package version)
        // via ⬢ v20.0.0 in bold green (node)
        // via 🐰 v1.3.1 in bold red (bun)
        // via 🐍 v3.12.0 in bold blue (python)
        // via 💎 v3.3.0 in bold red (ruby)
        // via 🐹 v1.22.0 in bold cyan (go)
        // via 🦀 v1.75.0 in bold orange (rust)
        // via ↯ v0.15.1 in bold yellow (zig)
        // > in green/red based on exit code
        return .{
            .left_format = try allocator.dupe(u8, "{symbol}\x1b[1;96m{path}\x1b[0m{git}{pkg}{runtimes}{battery} "),
            .right_format = null,
            .transient_enabled = false,
            .transient_format = null,
        };
    }

    pub fn initSimple(allocator: std.mem.Allocator) !PromptTemplate {
        return .{
            .left_format = try allocator.dupe(u8, "{symbol} "),
            .right_format = null,
            .transient_enabled = false,
            .transient_format = null,
        };
    }

    pub fn deinit(self: *PromptTemplate, allocator: std.mem.Allocator) void {
        allocator.free(self.left_format);
        if (self.right_format) |rf| allocator.free(rf);
        if (self.transient_format) |tf| allocator.free(tf);
    }
};
