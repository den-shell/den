//! Prompt Context Module
//! Handles prompt rendering and context updates for the shell

const std = @import("std");
const compat = @import("compat");
const IO = @import("../utils/io.zig").IO;
const PromptRenderer = @import("../prompt/renderer.zig").PromptRenderer;
const PromptTemplate = @import("../prompt/types.zig").PromptTemplate;
const SystemInfo = @import("../prompt/sysinfo.zig").SystemInfo;
const ansi = @import("../utils/ansi.zig");
const Shell = @import("../shell.zig").Shell;
const shell_mod = @import("mod.zig");

/// Render the prompt to stdout
pub fn renderPrompt(self: *Shell) !void {
    const prompt = try getPromptString(self);
    defer self.allocator.free(prompt);
    try IO.print("{s}", .{prompt});
}

/// Get the formatted prompt string
pub fn getPromptString(self: *Shell) ![]const u8 {
    // Initialize prompt renderer if not already done. Build the template from
    // the user's prompt config (~/.config/den.jsonc) rather than the hardcoded
    // default so `format`, `right_prompt` and `transient` are actually honored.
    if (self.prompt_renderer == null) {
        const pcfg = self.config.prompt;
        const template = PromptTemplate{
            .left_format = try self.allocator.dupe(u8, pcfg.format),
            .right_format = if (pcfg.right_prompt) |rp|
                try self.allocator.dupe(u8, rp)
            else
                null,
            .transient_enabled = pcfg.transient,
            .transient_format = null,
        };
        self.prompt_renderer = try PromptRenderer.init(self.allocator, template);
        self.prompt_renderer.?.zsh_escapes = self.config.zsh.enabled and self.config.zsh.prompt_escapes;
    }

    // Update prompt context with current information
    try updatePromptContext(self);

    // Render prompt
    const term_size = ansi.getTerminalSize() catch ansi.TerminalSize{ .rows = 24, .cols = 80 };
    return try self.prompt_renderer.?.render(&self.prompt_context, term_size.cols);
}

/// Update the prompt context with current system and environment information
pub fn updatePromptContext(self: *Shell) !void {
    var sysinfo = SystemInfo.init(self.allocator);

    // Get current directory
    const cwd = try sysinfo.getCurrentDir();
    defer self.allocator.free(cwd);

    // Get home directory
    const home = try sysinfo.getHomeDir();

    // Get username
    const username = try sysinfo.getUsername();
    defer self.allocator.free(username);

    // Get hostname
    const hostname = try sysinfo.getHostname();
    defer self.allocator.free(hostname);

    // Update context - free old current_dir if it was heap-allocated
    if (self.prompt_context.current_dir.len > 0) {
        self.allocator.free(self.prompt_context.current_dir);
    }
    self.prompt_context.current_dir = try self.allocator.dupe(u8, cwd);
    if (self.prompt_context.home_dir) |old_home| {
        self.allocator.free(old_home);
    }
    self.prompt_context.home_dir = home;

    // Free old username/hostname if they exist
    if (self.prompt_context.username.len > 0) {
        self.allocator.free(self.prompt_context.username);
    }
    self.prompt_context.username = try self.allocator.dupe(u8, username);

    if (self.prompt_context.hostname.len > 0) {
        self.allocator.free(self.prompt_context.hostname);
    }
    self.prompt_context.hostname = try self.allocator.dupe(u8, hostname);

    self.prompt_context.is_root = sysinfo.isRoot();
    self.prompt_context.last_exit_code = self.last_exit_code;

    // Honor the configured prompt symbol (theme.symbols.prompt, e.g. "❯").
    // Borrowed from config memory — lives as long as the shell, never freed here.
    self.prompt_context.prompt_symbol = self.config.theme.symbols.prompt;

    // Get git info by reading .git/ files directly (no process spawning)
    const GitModule = @import("../prompt/git.zig").GitModule;
    var git_module = GitModule.init(self.allocator);
    var git_info = try git_module.getInfo(cwd);
    defer git_info.deinit();

    if (self.prompt_context.git_branch) |old_branch| {
        self.allocator.free(old_branch);
    }
    self.prompt_context.git_branch = if (git_info.branch) |branch|
        try self.allocator.dupe(u8, branch)
    else
        null;

    self.prompt_context.git_dirty = git_info.is_dirty;
    self.prompt_context.git_ahead = git_info.ahead;
    self.prompt_context.git_behind = git_info.behind;
    self.prompt_context.git_staged = git_info.staged_count;
    self.prompt_context.git_unstaged = git_info.unstaged_count;
    self.prompt_context.git_untracked = git_info.untracked_count;
    self.prompt_context.git_stash = git_info.stash_count;

    // Detect package version from package.json/package.jsonc/pantry.json/pantry.jsonc
    if (self.prompt_context.package_version) |old_ver| {
        self.allocator.free(old_ver);
    }
    self.prompt_context.package_version = shell_mod.detectPackageVersion(self.allocator, cwd) catch null;

    // Detect primary package manager (bun takes precedence over node)
    const has_bun_lock = hasBunLock(self, cwd);

    if (has_bun_lock) {
        // Bun project - only show bun
        if (self.prompt_context.bun_version) |old_ver| {
            self.allocator.free(old_ver);
        }
        self.prompt_context.bun_version = shell_mod.detectBunVersion(self.allocator) catch null;

        // Clear node version
        if (self.prompt_context.node_version) |old_ver| {
            self.allocator.free(old_ver);
        }
        self.prompt_context.node_version = null;
    } else {
        // Node project or no lock file - show node
        if (self.prompt_context.node_version) |old_ver| {
            self.allocator.free(old_ver);
        }
        self.prompt_context.node_version = shell_mod.detectNodeVersion(self.allocator) catch null;

        // Clear bun version
        if (self.prompt_context.bun_version) |old_ver| {
            self.allocator.free(old_ver);
        }
        self.prompt_context.bun_version = null;
    }

    // Detect python version
    if (self.prompt_context.python_version) |old_ver| {
        self.allocator.free(old_ver);
    }
    self.prompt_context.python_version = shell_mod.detectPythonVersion(self.allocator) catch null;

    // Detect ruby version
    if (self.prompt_context.ruby_version) |old_ver| {
        self.allocator.free(old_ver);
    }
    self.prompt_context.ruby_version = shell_mod.detectRubyVersion(self.allocator) catch null;

    // Detect go version
    if (self.prompt_context.go_version) |old_ver| {
        self.allocator.free(old_ver);
    }
    self.prompt_context.go_version = shell_mod.detectGoVersion(self.allocator) catch null;

    // Detect rust version
    if (self.prompt_context.rust_version) |old_ver| {
        self.allocator.free(old_ver);
    }
    self.prompt_context.rust_version = shell_mod.detectRustVersion(self.allocator) catch null;

    // Detect zig version
    if (self.prompt_context.zig_version) |old_ver| {
        self.allocator.free(old_ver);
    }
    self.prompt_context.zig_version = shell_mod.detectZigVersion(self.allocator) catch null;

    // Detect battery level
    self.prompt_context.battery_percent = sysinfo.getBatteryPercent();

    self.prompt_context.current_time = if (compat.Instant.now()) |instant| blk: {
        break :blk if (@import("builtin").os.tag == .windows)
            @as(i64, @intCast(instant.timestamp / 10_000_000))
        else
            @as(i64, @intCast(instant.timestamp.sec));
    } else |_| 0;
}

/// Check if the current directory has a bun.lock or bun.lockb file
fn hasBunLock(self: *Shell, cwd: []const u8) bool {
    _ = self;
    const lock_files = [_][]const u8{ "bun.lockb", "bun.lock" };

    for (lock_files) |filename| {
        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ cwd, filename }) catch continue;

        // Just check if file exists
        const file = std.Io.Dir.cwd().openFile(std.Options.debug_io, path, .{}) catch continue;
        file.close(std.Options.debug_io);
        return true;
    }

    return false;
}
