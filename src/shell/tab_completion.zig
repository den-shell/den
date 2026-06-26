//! Tab Completion Module
//! Handles intelligent tab completion for various commands

const std = @import("std");
const types = @import("../types/mod.zig");
const Completion = @import("../utils/completion.zig").Completion;
const ContextCompletion = @import("../utils/context_completion.zig").ContextCompletion;

/// Global completion configuration (thread-local)
var g_completion_config: types.CompletionConfig = .{};
var g_completion_config_initialized: bool = false;

/// Set the global completion configuration
pub fn setCompletionConfig(config: types.CompletionConfig) void {
    g_completion_config = config;
    g_completion_config_initialized = true;
}

/// Get the global completion configuration
pub fn getCompletionConfig() types.CompletionConfig {
    return g_completion_config;
}

/// Main tab completion function
pub fn tabCompletionFn(input: []const u8, allocator: std.mem.Allocator) ![][]const u8 {
    // Check if completion is enabled via config
    if (g_completion_config_initialized and !g_completion_config.enabled) {
        return &[_][]const u8{};
    }

    var completion = Completion.init(allocator);
    var ctx_completion = ContextCompletion.init(allocator);

    // If input is empty, show nothing
    if (input.len == 0) {
        return &[_][]const u8{};
    }

    // Find the first word (command) and current word being completed
    var first_word_end: usize = 0;
    while (first_word_end < input.len) : (first_word_end += 1) {
        const c = input[first_word_end];
        if (c == ' ' or c == '\t') break;
    }

    var word_start: usize = 0;
    for (input, 0..) |c, i| {
        if (c == ' ' or c == '\t' or c == '|' or c == '&' or c == ';') {
            word_start = i + 1;
        }
    }
    const prefix = input[word_start..];
    const command = input[0..first_word_end];

    // If first word, complete a command name — unless it's written as a path
    // (`./foo`, `../foo`, `/abs/foo`, `~/foo`, or any word containing '/'), in
    // which case complete it as a file like bash/zsh do for `./lan<TAB>`.
    if (word_start == 0) {
        const looks_like_path = std.mem.indexOfScalar(u8, prefix, '/') != null or
            std.mem.startsWith(u8, prefix, "~");
        if (!looks_like_path) {
            return completion.completeCommand(prefix);
        }
        return completion.completeFile(prefix);
    }

    // Check for environment variable completion ($...)
    if (prefix.len > 0 and prefix[0] == '$') {
        const env_prefix = if (prefix.len > 1) prefix[1..] else "";
        const items = try ctx_completion.completeEnvVars(env_prefix);
        if (items.len > 0) {
            var results = try allocator.alloc([]const u8, items.len);
            for (items, 0..) |item, i| {
                results[i] = try std.fmt.allocPrint(allocator, "${s}", .{item.text});
                allocator.free(item.text);
            }
            allocator.free(items);
            return results;
        }
        allocator.free(items);
    }

    // Check for option/flag completion (-...)
    if (prefix.len > 0 and prefix[0] == '-') {
        const items = try ctx_completion.completeOptions(command, prefix);
        if (items.len > 0) {
            errdefer {
                for (items) |item| allocator.free(item.text);
                allocator.free(items);
            }
            var results = try allocator.alloc([]const u8, items.len);
            errdefer allocator.free(results);
            var filled: usize = 0;
            errdefer for (results[0..filled]) |r| allocator.free(r);
            for (items, 0..) |item, i| {
                results[i] = try allocator.dupe(u8, item.text);
                filled = i + 1;
            }
            // Success: free original items now that we own copies
            for (items) |item| allocator.free(item.text);
            allocator.free(items);
            return results;
        }
        allocator.free(items);
    }

    // For cd command, only complete directories
    if (std.mem.eql(u8, command, "cd")) {
        return completion.completeDirectory(prefix);
    }

    // For git command, show branches, files, subcommands
    if (std.mem.eql(u8, command, "git")) {
        return try completeGit(allocator, input, prefix);
    }

    // For bun command, show scripts, commands, and files
    if (std.mem.eql(u8, command, "bun")) {
        return try completeBun(allocator, prefix);
    }

    // For npm command, show scripts, commands, and files
    if (std.mem.eql(u8, command, "npm")) {
        return try completeNpm(allocator, prefix);
    }

    // For yarn command, show scripts, commands, and files
    if (std.mem.eql(u8, command, "yarn")) {
        return try completeYarn(allocator, input, prefix);
    }

    // For pnpm command, show scripts, commands, and files
    if (std.mem.eql(u8, command, "pnpm")) {
        return try completePnpm(allocator, input, prefix);
    }

    // For docker command, show containers, images, subcommands
    if (std.mem.eql(u8, command, "docker")) {
        return try completeDocker(allocator, input, prefix);
    }

    // Otherwise, try file completion
    const results = try completion.completeFile(prefix);

    // Apply max_suggestions limit from config
    if (g_completion_config_initialized and g_completion_config.max_suggestions > 0) {
        const max = @as(usize, g_completion_config.max_suggestions);
        if (results.len > max) {
            // Free excess results
            for (results[max..]) |r| {
                allocator.free(r);
            }
            // Shrink the slice
            const limited = allocator.realloc(results, max) catch results[0..max];
            return limited;
        }
    }

    return results;
}

/// Get completions for git command (branches, files, subcommands)
pub fn completeGit(allocator: std.mem.Allocator, input: []const u8, prefix: []const u8) ![][]const u8 {
    var results = std.ArrayList([]const u8).empty;
    defer results.deinit(allocator);

    // Parse to find the git subcommand
    var tokens = std.mem.tokenizeScalar(u8, input, ' ');
    _ = tokens.next(); // Skip "git"
    const subcommand = tokens.next(); // Get subcommand (if any)

    const git_commands = [_][]const u8{
        "add",  "bisect", "branch", "checkout", "cherry-pick", "clone",  "commit",
        "diff", "fetch",  "grep",   "init",     "log",         "merge",  "mv",
        "pull", "push",   "rebase", "reset",    "restore",     "revert", "rm",
        "show", "stash",  "status", "switch",   "tag",
    };

    // If no subcommand yet, or if we're still typing the subcommand (prefix matches subcommand),
    // show matching git subcommands
    if (subcommand == null or (subcommand != null and std.mem.eql(u8, subcommand.?, prefix))) {
        for (git_commands) |cmd| {
            if (std.mem.startsWith(u8, cmd, prefix)) {
                const marked_cmd = try std.fmt.allocPrint(allocator, "\x02{s}", .{cmd});
                try results.append(allocator, marked_cmd);
            }
        }

        const owned = try allocator.alloc([]const u8, results.items.len);
        @memcpy(owned, results.items);
        return owned;
    }

    // At this point, we have a complete subcommand and are completing arguments

    // Branch-related subcommands: checkout, branch, merge, rebase, switch
    const branch_commands = [_][]const u8{ "checkout", "branch", "merge", "rebase", "switch", "cherry-pick" };
    for (branch_commands) |branch_cmd| {
        if (std.mem.eql(u8, subcommand.?, branch_cmd)) {
            return try getGitBranches(allocator, prefix);
        }
    }

    // File-related subcommands: add, diff, restore, reset
    const file_commands = [_][]const u8{ "add", "diff", "restore", "reset" };
    for (file_commands) |file_cmd| {
        if (std.mem.eql(u8, subcommand.?, file_cmd)) {
            return try getGitModifiedFiles(allocator, prefix);
        }
    }

    // For other subcommands, don't provide completions
    return &[_][]const u8{};
}

/// Get git branches for completion by reading .git/refs/ directly
pub fn getGitBranches(allocator: std.mem.Allocator, prefix: []const u8) ![][]const u8 {
    var results = std.ArrayList([]const u8).empty;
    defer results.deinit(allocator);

    // Find .git directory
    const git_dir = findGitDirForCompletion() orelse return &[_][]const u8{};

    // Read local branches from .git/refs/heads/
    var refs_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const refs_path = std.fmt.bufPrint(&refs_path_buf, "{s}/refs/heads", .{git_dir}) catch return &[_][]const u8{};
    try collectBranchNames(allocator, refs_path, "", prefix, &results);

    // Read remote branches from .git/refs/remotes/
    var remotes_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const remotes_path = std.fmt.bufPrint(&remotes_path_buf, "{s}/refs/remotes", .{git_dir}) catch "";
    if (remotes_path.len > 0) {
        try collectBranchNames(allocator, remotes_path, "", prefix, &results);
    }

    // Also try packed-refs for branches not yet unpacked
    var packed_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const packed_path = std.fmt.bufPrint(&packed_path_buf, "{s}/packed-refs", .{git_dir}) catch "";
    if (packed_path.len > 0) {
        collectPackedBranches(allocator, packed_path, prefix, &results) catch {};
    }

    // Limit to 10 results
    const max_branches = 10;
    const count = @min(results.items.len, max_branches);
    if (results.items.len > max_branches) {
        for (results.items[max_branches..]) |item| {
            allocator.free(item);
        }
    }

    const owned = try allocator.alloc([]const u8, count);
    @memcpy(owned, results.items[0..count]);
    return owned;
}

/// Recursively collect branch names from refs/heads/ directory
fn collectBranchNames(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    rel_prefix: []const u8,
    filter_prefix: []const u8,
    results: *std.ArrayList([]const u8),
) !void {
    var dir = std.Io.Dir.cwd().openDir(std.Options.debug_io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(std.Options.debug_io);

    var iter = dir.iterate();
    while (try iter.next(std.Options.debug_io)) |entry| {
        var name_buf: [512]u8 = undefined;
        const full_name = if (rel_prefix.len > 0)
            std.fmt.bufPrint(&name_buf, "{s}/{s}", .{ rel_prefix, entry.name }) catch continue
        else
            entry.name;

        if (entry.kind == .directory) {
            var sub_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const sub_path = std.fmt.bufPrint(&sub_path_buf, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
            // Need to dupe rel_prefix for recursive call since full_name borrows name_buf
            const duped_name = try allocator.dupe(u8, full_name);
            defer allocator.free(duped_name);
            try collectBranchNames(allocator, sub_path, duped_name, filter_prefix, results);
        } else {
            if (std.mem.startsWith(u8, full_name, filter_prefix)) {
                const marked = try std.fmt.allocPrint(allocator, "\x03{s}", .{full_name});
                try results.append(allocator, marked);
            }
        }
    }
}

/// Collect branches from packed-refs file
fn collectPackedBranches(
    allocator: std.mem.Allocator,
    packed_path: []const u8,
    prefix: []const u8,
    results: *std.ArrayList([]const u8),
) !void {
    const file = std.Io.Dir.cwd().openFile(std.Options.debug_io, packed_path, .{}) catch return;
    defer file.close(std.Options.debug_io);

    var buf: [8192]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = file.readStreaming(std.Options.debug_io, &.{buf[total..]}) catch break;
        if (n == 0) break;
        total += n;
    }

    const refs_prefix = "refs/heads/";
    var lines = std.mem.splitScalar(u8, buf[0..total], '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        // Format: <hash> <ref>
        var parts = std.mem.splitScalar(u8, line, ' ');
        _ = parts.next(); // skip hash
        const ref = parts.next() orelse continue;
        if (std.mem.startsWith(u8, ref, refs_prefix)) {
            const branch = ref[refs_prefix.len..];
            if (std.mem.startsWith(u8, branch, prefix)) {
                // Check not already in results
                var already = false;
                for (results.items) |existing| {
                    // Skip the \x03 marker byte
                    if (existing.len > 0 and std.mem.eql(u8, existing[1..], branch)) {
                        already = true;
                        break;
                    }
                }
                if (!already) {
                    const marked = try std.fmt.allocPrint(allocator, "\x03{s}", .{branch});
                    try results.append(allocator, marked);
                }
            }
        }
    }
}

fn toOwned(allocator: std.mem.Allocator, results: *std.ArrayList([]const u8)) ![][]const u8 {
    const owned = try allocator.alloc([]const u8, results.items.len);
    @memcpy(owned, results.items);
    return owned;
}

/// Find .git directory from current working directory
fn findGitDirForCompletion() ?[]const u8 {
    // Use a static buffer to avoid allocation
    const Static = struct {
        var git_dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    };

    const cwd_len = std.process.currentPath(std.Options.debug_io, &Static.path_buf) catch return null;
    var current = Static.path_buf[0..cwd_len];

    while (true) {
        var git_head_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const git_head_path = std.fmt.bufPrint(&git_head_buf, "{s}/.git/HEAD", .{current}) catch return null;

        const file = std.Io.Dir.cwd().openFile(std.Options.debug_io, git_head_path, .{}) catch {
            const parent = std.fs.path.dirname(current) orelse return null;
            if (parent.len == current.len) return null;
            current = Static.path_buf[0..parent.len];
            continue;
        };
        file.close(std.Options.debug_io);

        const git_dir = std.fmt.bufPrint(&Static.git_dir_buf, "{s}/.git", .{current}) catch return null;
        return git_dir;
    }
}

/// Get git modified files for completion
/// Falls back to regular file completion since git status requires process spawning
pub fn getGitModifiedFiles(allocator: std.mem.Allocator, prefix: []const u8) ![][]const u8 {
    var completion = Completion.init(allocator);
    return completion.completeFile(prefix);
}

/// Get completions for bun command
pub fn completeBun(allocator: std.mem.Allocator, prefix: []const u8) ![][]const u8 {
    var results = std.ArrayList([]const u8).empty;
    defer results.deinit(allocator);

    // Bun subcommands
    const bun_commands = [_][]const u8{
        "run",     "test",   "x",        "repl",
        "install", "add",    "remove",   "update",
        "link",    "unlink", "pm",       "build",
        "init",    "create", "upgrade",  "completions",
        "discord", "help",   "outdated",
    };

    // If prefix is empty or matches a subcommand, show subcommands
    for (bun_commands) |cmd| {
        if (std.mem.startsWith(u8, cmd, prefix)) {
            const marked_cmd = try std.fmt.allocPrint(allocator, "\x02{s}", .{cmd});
            try results.append(allocator, marked_cmd);
        }
    }

    // Try to read package.json for scripts
    const pkg_scripts = getPackageJsonScripts(allocator) catch null;
    if (pkg_scripts) |scripts| {
        defer {
            for (scripts) |s| allocator.free(s);
            allocator.free(scripts);
        }
        for (scripts) |script| {
            if (std.mem.startsWith(u8, script, prefix)) {
                const marked_script = try std.fmt.allocPrint(allocator, "\x04{s}", .{script});
                try results.append(allocator, marked_script);
            }
        }
    }

    const owned = try allocator.alloc([]const u8, results.items.len);
    @memcpy(owned, results.items);
    return owned;
}

/// Read scripts from package.json
fn getPackageJsonScripts(allocator: std.mem.Allocator) ![][]const u8 {
    var results = std.ArrayList([]const u8).empty;
    errdefer {
        for (results.items) |item| allocator.free(item);
        results.deinit(allocator);
    }

    const file = std.Io.Dir.cwd().openFile(std.Options.debug_io, "package.json", .{}) catch return error.NotFound;
    defer file.close(std.Options.debug_io);

    // Read file (limit to 64KB for safety)
    const max_size: usize = 65536;
    const file_size = (try file.stat(std.Options.debug_io)).size;
    const read_size: usize = @min(file_size, max_size);
    const buffer = try allocator.alloc(u8, read_size);
    defer allocator.free(buffer);

    var total_read: usize = 0;
    while (total_read < read_size) {
        const n = try file.readStreaming(std.Options.debug_io, &.{buffer[total_read..]});
        if (n == 0) break;
        total_read += n;
    }
    const content = buffer[0..total_read];

    // Simple JSON parsing to find "scripts": { ... }
    var i: usize = 0;
    while (i < content.len) : (i += 1) {
        if (std.mem.startsWith(u8, content[i..], "\"scripts\"")) {
            // Find the opening brace
            var j = i + 9; // Skip "scripts"
            while (j < content.len and content[j] != '{') : (j += 1) {}
            if (j >= content.len) break;
            j += 1; // Skip opening brace

            // Parse script names
            while (j < content.len and content[j] != '}') : (j += 1) {
                // Skip whitespace
                while (j < content.len and (content[j] == ' ' or content[j] == '\t' or content[j] == '\n' or content[j] == '\r' or content[j] == ',')) : (j += 1) {}
                if (j >= content.len or content[j] == '}') break;

                // Find script name (in quotes)
                if (content[j] == '"') {
                    j += 1;
                    const name_start = j;
                    while (j < content.len and content[j] != '"') : (j += 1) {}
                    if (j > name_start) {
                        try results.append(allocator, try allocator.dupe(u8, content[name_start..j]));
                    }
                    j += 1; // Skip closing quote

                    // Skip to value and past it
                    while (j < content.len and content[j] != ':') : (j += 1) {}
                    j += 1; // Skip colon
                    while (j < content.len and content[j] != '"') : (j += 1) {}
                    j += 1; // Skip opening quote
                    while (j < content.len and content[j] != '"') : (j += 1) {
                        if (content[j] == '\\' and j + 1 < content.len) j += 1; // Skip escaped chars
                    }
                }
            }
            break;
        }
    }

    return try results.toOwnedSlice(allocator);
}

/// Get completions for npm command
pub fn completeNpm(allocator: std.mem.Allocator, prefix: []const u8) ![][]const u8 {
    var results = std.ArrayList([]const u8).empty;
    defer results.deinit(allocator);

    // npm subcommands
    const npm_commands = [_][]const u8{
        "access",       "adduser",    "audit",      "bin",
        "bugs",         "cache",      "ci",         "completion",
        "config",       "dedupe",     "deprecate",  "diff",
        "dist-tag",     "docs",       "doctor",     "edit",
        "exec",         "explain",    "explore",    "find-dupes",
        "fund",         "get",        "help",       "help-search",
        "hook",         "init",       "install",    "install-ci-test",
        "install-test", "link",       "ll",         "login",
        "logout",       "ls",         "org",        "outdated",
        "owner",        "pack",       "ping",       "pkg",
        "prefix",       "profile",    "prune",      "publish",
        "query",        "rebuild",    "repo",       "restart",
        "root",         "run",        "run-script", "search",
        "set",          "shrinkwrap", "star",       "stars",
        "start",        "stop",       "team",       "test",
        "token",        "uninstall",  "unpublish",  "unstar",
        "update",       "version",    "view",       "whoami",
    };

    // If prefix is empty or matches a subcommand, show subcommands
    for (npm_commands) |cmd| {
        if (std.mem.startsWith(u8, cmd, prefix)) {
            const marked_cmd = try std.fmt.allocPrint(allocator, "\x02{s}", .{cmd});
            try results.append(allocator, marked_cmd);
        }
    }

    // Try to read package.json for scripts
    const pkg_scripts = getPackageJsonScripts(allocator) catch null;
    if (pkg_scripts) |scripts| {
        defer {
            for (scripts) |s| allocator.free(s);
            allocator.free(scripts);
        }
        for (scripts) |script| {
            if (std.mem.startsWith(u8, script, prefix)) {
                const marked_script = try std.fmt.allocPrint(allocator, "\x04{s}", .{script});
                try results.append(allocator, marked_script);
            }
        }
    }

    const owned = try allocator.alloc([]const u8, results.items.len);
    @memcpy(owned, results.items);
    return owned;
}

/// Get completions for yarn command
pub fn completeYarn(allocator: std.mem.Allocator, input: []const u8, prefix: []const u8) ![][]const u8 {
    var results = std.ArrayList([]const u8).empty;
    defer results.deinit(allocator);

    // Parse to find if we have a subcommand
    var tokens = std.mem.tokenizeScalar(u8, input, ' ');
    _ = tokens.next(); // Skip "yarn"
    const subcommand = tokens.next();

    // yarn subcommands
    const yarn_commands = [_][]const u8{
        "add",                 "audit",               "autoclean", "bin",
        "cache",               "check",               "config",    "create",
        "dedupe",              "generate-lock-entry", "global",    "help",
        "import",              "info",                "init",      "install",
        "licenses",            "link",                "list",      "login",
        "logout",              "node",                "outdated",  "owner",
        "pack",                "policies",            "publish",   "remove",
        "run",                 "set",                 "tag",       "team",
        "test",                "unlink",              "unplug",    "upgrade",
        "upgrade-interactive", "version",             "versions",  "why",
        "workspace",           "workspaces",
    };

    // If no subcommand yet, show subcommands
    if (subcommand == null or (subcommand != null and std.mem.eql(u8, subcommand.?, prefix))) {
        for (yarn_commands) |cmd| {
            if (std.mem.startsWith(u8, cmd, prefix)) {
                const marked_cmd = try std.fmt.allocPrint(allocator, "\x02{s}", .{cmd});
                try results.append(allocator, marked_cmd);
            }
        }

        // Also show scripts from package.json
        const pkg_scripts = getPackageJsonScripts(allocator) catch null;
        if (pkg_scripts) |scripts| {
            defer {
                for (scripts) |s| allocator.free(s);
                allocator.free(scripts);
            }
            for (scripts) |script| {
                if (std.mem.startsWith(u8, script, prefix)) {
                    const marked_script = try std.fmt.allocPrint(allocator, "\x04{s}", .{script});
                    try results.append(allocator, marked_script);
                }
            }
        }
    }

    const owned = try allocator.alloc([]const u8, results.items.len);
    @memcpy(owned, results.items);
    return owned;
}

/// Get completions for pnpm command
pub fn completePnpm(allocator: std.mem.Allocator, input: []const u8, prefix: []const u8) ![][]const u8 {
    var results = std.ArrayList([]const u8).empty;
    defer results.deinit(allocator);

    // Parse to find if we have a subcommand
    var tokens = std.mem.tokenizeScalar(u8, input, ' ');
    _ = tokens.next(); // Skip "pnpm"
    const subcommand = tokens.next();

    // pnpm subcommands
    const pnpm_commands = [_][]const u8{
        "add",     "audit",        "bin",          "config",
        "dedupe",  "dlx",          "doctor",       "exec",
        "fetch",   "i",            "import",       "init",
        "install", "install-test", "licenses",     "link",
        "list",    "ln",           "ls",           "outdated",
        "pack",    "patch",        "patch-commit", "prune",
        "publish", "rebuild",      "remove",       "rm",
        "root",    "run",          "server",       "setup",
        "store",   "test",         "uninstall",    "unlink",
        "update",  "upgrade",      "why",
    };

    // If no subcommand yet, show subcommands
    if (subcommand == null or (subcommand != null and std.mem.eql(u8, subcommand.?, prefix))) {
        for (pnpm_commands) |cmd| {
            if (std.mem.startsWith(u8, cmd, prefix)) {
                const marked_cmd = try std.fmt.allocPrint(allocator, "\x02{s}", .{cmd});
                try results.append(allocator, marked_cmd);
            }
        }

        // Also show scripts from package.json
        const pkg_scripts = getPackageJsonScripts(allocator) catch null;
        if (pkg_scripts) |scripts| {
            defer {
                for (scripts) |s| allocator.free(s);
                allocator.free(scripts);
            }
            for (scripts) |script| {
                if (std.mem.startsWith(u8, script, prefix)) {
                    const marked_script = try std.fmt.allocPrint(allocator, "\x04{s}", .{script});
                    try results.append(allocator, marked_script);
                }
            }
        }
    }

    const owned = try allocator.alloc([]const u8, results.items.len);
    @memcpy(owned, results.items);
    return owned;
}

/// Get completions for docker command
pub fn completeDocker(allocator: std.mem.Allocator, input: []const u8, prefix: []const u8) ![][]const u8 {
    var results = std.ArrayList([]const u8).empty;
    defer results.deinit(allocator);

    // Parse to find the docker subcommand
    var tokens = std.mem.tokenizeScalar(u8, input, ' ');
    _ = tokens.next(); // Skip "docker"
    const subcommand = tokens.next();

    // docker subcommands
    const docker_commands = [_][]const u8{
        "attach",   "build",     "commit",  "compose",
        "config",   "container", "context", "cp",
        "create",   "diff",      "events",  "exec",
        "export",   "history",   "image",   "images",
        "import",   "info",      "inspect", "kill",
        "load",     "login",     "logout",  "logs",
        "manifest", "network",   "node",    "pause",
        "plugin",   "port",      "ps",      "pull",
        "push",     "rename",    "restart", "rm",
        "rmi",      "run",       "save",    "search",
        "secret",   "service",   "stack",   "start",
        "stats",    "stop",      "swarm",   "system",
        "tag",      "top",       "trust",   "unpause",
        "update",   "version",   "volume",  "wait",
    };

    // If no subcommand yet, show subcommands
    if (subcommand == null or (subcommand != null and std.mem.eql(u8, subcommand.?, prefix))) {
        for (docker_commands) |cmd| {
            if (std.mem.startsWith(u8, cmd, prefix)) {
                const marked_cmd = try std.fmt.allocPrint(allocator, "\x02{s}", .{cmd});
                try results.append(allocator, marked_cmd);
            }
        }

        const owned = try allocator.alloc([]const u8, results.items.len);
        @memcpy(owned, results.items);
        return owned;
    }

    // Container-related subcommands
    const container_commands = [_][]const u8{
        "attach",  "exec",    "inspect", "kill",  "logs", "pause",
        "port",    "restart", "rm",      "start", "stop", "top",
        "unpause",
    };
    for (container_commands) |container_cmd| {
        if (std.mem.eql(u8, subcommand.?, container_cmd)) {
            return try getDockerContainers(allocator, prefix);
        }
    }

    // Image-related subcommands
    const image_commands = [_][]const u8{ "rmi", "tag", "push", "save", "history" };
    for (image_commands) |image_cmd| {
        if (std.mem.eql(u8, subcommand.?, image_cmd)) {
            return try getDockerImages(allocator, prefix);
        }
    }

    // For run command, show images
    if (std.mem.eql(u8, subcommand.?, "run")) {
        return try getDockerImages(allocator, prefix);
    }

    return &[_][]const u8{};
}

/// Get docker containers for completion
fn getDockerContainers(allocator: std.mem.Allocator, prefix: []const u8) ![][]const u8 {
    var results = std.ArrayList([]const u8).empty;
    defer results.deinit(allocator);

    // Run: docker ps -a --format {{.Names}}
    const result = std.process.run(allocator, std.Options.debug_io, .{
        .argv = &[_][]const u8{ "docker", "ps", "-a", "--format", "{{.Names}}" },
    }) catch {
        return &[_][]const u8{};
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term.exited != 0) {
        return &[_][]const u8{};
    }

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;

        if (std.mem.startsWith(u8, trimmed, prefix)) {
            try results.append(allocator, try allocator.dupe(u8, trimmed));
        }
    }

    const owned = try allocator.alloc([]const u8, results.items.len);
    @memcpy(owned, results.items);
    return owned;
}

/// Get docker images for completion
fn getDockerImages(allocator: std.mem.Allocator, prefix: []const u8) ![][]const u8 {
    var results = std.ArrayList([]const u8).empty;
    defer results.deinit(allocator);

    // Run: docker images --format {{.Repository}}:{{.Tag}}
    const result = std.process.run(allocator, std.Options.debug_io, .{
        .argv = &[_][]const u8{ "docker", "images", "--format", "{{.Repository}}:{{.Tag}}" },
    }) catch {
        return &[_][]const u8{};
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term.exited != 0) {
        return &[_][]const u8{};
    }

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;
        if (std.mem.eql(u8, trimmed, "<none>:<none>")) continue;

        if (std.mem.startsWith(u8, trimmed, prefix)) {
            try results.append(allocator, try allocator.dupe(u8, trimmed));
        }
    }

    // Also try to complete from common base images if prefix is short
    if (prefix.len < 3) {
        const common_images = [_][]const u8{
            "alpine", "ubuntu",  "debian",   "centos",
            "node",   "python",  "golang",   "rust",
            "nginx",  "redis",   "postgres", "mysql",
            "mongo",  "busybox", "httpd",    "php",
        };
        for (common_images) |img| {
            if (std.mem.startsWith(u8, img, prefix)) {
                // Check if already in results
                var found = false;
                for (results.items) |r| {
                    if (std.mem.startsWith(u8, r, img)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    // Just add the common image name as a suggestion
                    try results.append(allocator, try allocator.dupe(u8, img));
                }
            }
        }
    }

    return try results.toOwnedSlice(allocator);
}
