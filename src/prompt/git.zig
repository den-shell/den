const std = @import("std");

/// Git repository information
pub const GitInfo = struct {
    branch: ?[]const u8,
    commit_hash: ?[]const u8,
    is_dirty: bool,
    staged_count: usize,
    unstaged_count: usize,
    untracked_count: usize,
    ahead: usize,
    behind: usize,
    stash_count: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) GitInfo {
        return .{
            .branch = null,
            .commit_hash = null,
            .is_dirty = false,
            .staged_count = 0,
            .unstaged_count = 0,
            .untracked_count = 0,
            .ahead = 0,
            .behind = 0,
            .stash_count = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *GitInfo) void {
        if (self.branch) |b| self.allocator.free(b);
        if (self.commit_hash) |h| self.allocator.free(h);
    }
};

/// Ahead/behind counts
pub const AheadBehind = struct {
    ahead: usize,
    behind: usize,
};

/// Git integration module — reads .git/ files directly (no process spawning).
/// NOTE: working-tree status (staged/unstaged/untracked, ahead/behind) is not
/// yet computed — those counts stay 0, so the prompt shows a clean ✓ even when
/// the tree is dirty. Populating them needs either parsing .git/index against
/// the working tree or a `git status` call (the latter currently no-ops because
/// this build's std.process.run-based spawning isn't returning output).
pub const GitModule = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) GitModule {
        return .{ .allocator = allocator };
    }

    /// Get Git information for current directory
    pub fn getInfo(self: *GitModule, cwd: []const u8) !GitInfo {
        var info = GitInfo.init(self.allocator);

        // Find the .git directory by walking up from cwd
        const git_dir = self.findGitDir(cwd) orelse return info;
        defer self.allocator.free(git_dir);

        // Read branch from .git/HEAD
        info.branch = self.readBranch(git_dir) catch null;

        // Read commit hash
        if (info.branch) |_| {
            info.commit_hash = self.readCommitHash(git_dir) catch null;
        }

        // Check for stash
        info.stash_count = self.countStashes(git_dir) catch 0;

        return info;
    }

    /// Find .git directory by walking up from cwd
    fn findGitDir(self: *GitModule, cwd: []const u8) ?[]const u8 {
        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        var current = path_buf[0..cwd.len];
        @memcpy(current, cwd);

        while (true) {
            // Try to open .git/HEAD to confirm this is a real git dir
            var git_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const git_head_path = std.fmt.bufPrint(&git_path_buf, "{s}/.git/HEAD", .{current}) catch return null;

            const file = std.Io.Dir.cwd().openFile(std.Options.debug_io, git_head_path, .{}) catch {
                // Go up one level
                const parent = std.fs.path.dirname(current) orelse return null;
                if (parent.len == current.len) return null;
                current = path_buf[0..parent.len];
                continue;
            };
            file.close(std.Options.debug_io);

            // Found it — return path to .git dir
            const git_dir_path = std.fmt.bufPrint(&git_path_buf, "{s}/.git", .{current}) catch return null;
            return self.allocator.dupe(u8, git_dir_path) catch null;
        }
    }

    /// Read current branch name from .git/HEAD
    fn readBranch(self: *GitModule, git_dir: []const u8) ![]const u8 {
        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const head_path = try std.fmt.bufPrint(&path_buf, "{s}/HEAD", .{git_dir});

        const content = try self.readFileContent(head_path);
        defer self.allocator.free(content);

        const trimmed = std.mem.trim(u8, content, &std.ascii.whitespace);

        // HEAD contains "ref: refs/heads/<branch>" for a normal branch
        const prefix = "ref: refs/heads/";
        if (std.mem.startsWith(u8, trimmed, prefix)) {
            return try self.allocator.dupe(u8, trimmed[prefix.len..]);
        }

        // Detached HEAD — return short hash
        if (trimmed.len >= 7) {
            return try self.allocator.dupe(u8, trimmed[0..7]);
        }

        return error.InvalidHead;
    }

    /// Read current commit hash
    fn readCommitHash(self: *GitModule, git_dir: []const u8) ![]const u8 {
        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const head_path = try std.fmt.bufPrint(&path_buf, "{s}/HEAD", .{git_dir});

        const head_content = try self.readFileContent(head_path);
        defer self.allocator.free(head_content);

        const trimmed = std.mem.trim(u8, head_content, &std.ascii.whitespace);

        // If HEAD is a ref, resolve it
        const prefix = "ref: ";
        if (std.mem.startsWith(u8, trimmed, prefix)) {
            const ref = trimmed[prefix.len..];
            var ref_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const ref_path = try std.fmt.bufPrint(&ref_path_buf, "{s}/{s}", .{ git_dir, ref });

            const hash_content = try self.readFileContent(ref_path);
            defer self.allocator.free(hash_content);

            const hash = std.mem.trim(u8, hash_content, &std.ascii.whitespace);
            if (hash.len >= 7) {
                return try self.allocator.dupe(u8, hash[0..7]);
            }
            return error.InvalidHash;
        }

        // Detached HEAD — hash is directly in HEAD
        if (trimmed.len >= 7) {
            return try self.allocator.dupe(u8, trimmed[0..7]);
        }

        return error.InvalidHash;
    }

    /// Count stash entries from .git/refs/stash or .git/logs/refs/stash
    fn countStashes(self: *GitModule, git_dir: []const u8) !usize {
        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const stash_log_path = try std.fmt.bufPrint(&path_buf, "{s}/logs/refs/stash", .{git_dir});

        const content = self.readFileContent(stash_log_path) catch return 0;
        defer self.allocator.free(content);

        var count: usize = 0;
        var iter = std.mem.splitScalar(u8, content, '\n');
        while (iter.next()) |line| {
            if (line.len > 0) count += 1;
        }
        return count;
    }

    /// Read file content into an allocated buffer
    fn readFileContent(self: *GitModule, path: []const u8) ![]const u8 {
        const file = std.Io.Dir.cwd().openFile(std.Options.debug_io, path, .{}) catch return error.FileNotFound;
        defer file.close(std.Options.debug_io);

        var buf: [4096]u8 = undefined;
        var total: usize = 0;
        while (total < buf.len) {
            const n = file.readStreaming(std.Options.debug_io, &.{buf[total..]}) catch break;
            if (n == 0) break;
            total += n;
        }

        return try self.allocator.dupe(u8, buf[0..total]);
    }

    /// Find git repository root from a given path
    pub fn findRepositoryRoot(self: *GitModule, start_path: []const u8) !?[]const u8 {
        var current_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const current_path = blk: {
            var path_z: [std.Io.Dir.max_path_bytes]u8 = undefined;
            if (start_path.len >= path_z.len) return error.NameTooLong;
            @memcpy(path_z[0..start_path.len], start_path);
            path_z[start_path.len] = 0;
            const result = std.c.realpath(path_z[0..start_path.len :0], &current_path_buf) orelse return error.FileNotFound;
            break :blk std.mem.span(@as([*:0]const u8, @ptrCast(result)));
        };

        var path = try self.allocator.dupe(u8, current_path);
        defer self.allocator.free(path);

        while (true) {
            var dir = std.Io.Dir.openDirAbsolute(std.Options.debug_io, path, .{}) catch break;
            defer dir.close(std.Options.debug_io);

            dir.access(std.Options.debug_io, ".git", .{}) catch {
                const parent = std.fs.path.dirname(path) orelse break;
                const parent_copy = try self.allocator.dupe(u8, parent);
                self.allocator.free(path);
                path = parent_copy;
                continue;
            };

            return try self.allocator.dupe(u8, path);
        }

        return null;
    }
};
