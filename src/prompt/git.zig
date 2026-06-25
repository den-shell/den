const std = @import("std");
const spawn = @import("../utils/spawn.zig");

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

/// Git integration module — branch/commit/stash are read straight from .git/;
/// working-tree status (dirty/staged/unstaged/untracked, ahead/behind) comes from
/// one `git status` call via spawn.captureOutput (see populateStatus).
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

        // Working-tree status: staged/unstaged/untracked counts and ahead/behind.
        self.populateStatus(cwd, &info);

        return info;
    }

    /// Fill in working-tree status (staged/unstaged/untracked) and ahead/behind
    /// by running `git status`. Branch/commit/stash are read straight from .git/
    /// above, but an accurate dirty state means diffing the working tree against
    /// the index, so we shell out via spawn.captureOutput (the same fork+exec+pipe
    /// path that command substitution uses; std.process.run isn't usable here as
    /// its capture comes back empty in this build). On any failure the counts stay
    /// zero (rendered as a clean ✓), so this never breaks the prompt.
    fn populateStatus(self: *GitModule, cwd: []const u8, info: *GitInfo) void {
        const cap = spawn.captureOutput(self.allocator, .{
            .argv = &[_][]const u8{ "git", "status", "--porcelain=v1", "--branch" },
            .cwd = cwd,
        }) catch return;
        defer cap.deinit(self.allocator);
        if (cap.exit_code != 0) return;

        var iter = std.mem.splitScalar(u8, cap.stdout, '\n');
        while (iter.next()) |line| {
            if (line.len == 0) continue;
            if (std.mem.startsWith(u8, line, "## ")) {
                // e.g. "## main...origin/main [ahead 1, behind 2]"
                if (std.mem.indexOf(u8, line, "[ahead ")) |pos| {
                    info.ahead = parseLeadingUint(line[pos + "[ahead ".len ..]);
                }
                if (std.mem.indexOf(u8, line, "behind ")) |pos| {
                    info.behind = parseLeadingUint(line[pos + "behind ".len ..]);
                }
                continue;
            }
            if (line.len < 2) continue;
            const x = line[0]; // index (staged) status
            const y = line[1]; // working-tree (unstaged) status
            if (x == '?' and y == '?') {
                info.untracked_count += 1;
            } else {
                if (x != ' ') info.staged_count += 1;
                if (y != ' ') info.unstaged_count += 1;
            }
        }
        info.is_dirty = info.staged_count > 0 or info.unstaged_count > 0 or info.untracked_count > 0;
    }

    /// Parse the run of leading ASCII digits of `s` as a usize (0 if none).
    fn parseLeadingUint(s: []const u8) usize {
        var n: usize = 0;
        var i: usize = 0;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
            n = n * 10 + (s[i] - '0');
        }
        return n;
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
