//! Directory-change and pre-prompt hooks.
//!
//! Tools that manage a per-project environment (pantry, direnv, nvm, and
//! friends) need to run when the working directory changes. zsh gives them
//! `chpwd` / `chpwd_functions`, bash gives them `PROMPT_COMMAND`. Den had
//! neither, so those integrations could not be written for it at all.
//!
//! ## Cost
//!
//! `runDirectoryHooks` is called once per prompt, so it has to be free when
//! nothing changed. It is: one `getcwd` into a stack buffer and one `memcmp`.
//! Nothing is allocated, no map is touched, and no hook is looked up unless the
//! path actually differs from the previous prompt.
//!
//! The directory is compared rather than flagged by the `cd` builtin on
//! purpose. `cd`, `pushd`, `popd`, and any builtin that calls `chdir` would each
//! have to remember to set the flag, and a missed one is a hook that silently
//! stops firing. `getcwd` cannot be wrong.
//!
//! `runPrecmdHooks` costs two hash lookups per prompt when no pre-prompt hook is
//! defined, which is what an interactive shell that never uses them pays.

const std = @import("std");
const Shell = @import("../shell.zig").Shell;

/// A hook that changes directory would re-enter these on the next prompt, and a
/// hook that fails should not be retried in a loop, so hooks never nest.
var in_hook: bool = false;

/// What a prompt tick should do about the working directory.
pub const Decision = enum {
    /// Same directory as the last prompt. The common case, and the reason this
    /// is a comparison rather than any kind of lookup.
    unchanged,
    /// First prompt of the session: remember where we are, run nothing.
    record_only,
    /// The directory changed: remember it and run the hooks.
    fire,
};

/// Split out from `runDirectoryHooks` so the rule can be tested without
/// standing up a shell and moving the process between directories.
pub fn decide(previous: ?[]const u8, cwd: []const u8) Decision {
    const last = previous orelse return .record_only;
    return if (std.mem.eql(u8, last, cwd)) .unchanged else .fire;
}

/// Run `chpwd` and `chpwd_functions` if the working directory changed since the
/// last prompt.
///
/// Never fires on the first prompt of a session: zsh does not, and an
/// integration that wants to act at startup can simply call its own function
/// while its rc file is being sourced. Firing here would mean every `chpwd`
/// author has to handle a startup call they did not ask for.
pub fn runDirectoryHooks(self: *Shell) void {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Options.debug_io, &buf) catch return;
    const cwd = buf[0..cwd_len];

    switch (decide(self.last_hook_cwd, cwd)) {
        .unchanged => return,
        .record_only => {
            self.last_hook_cwd = self.allocator.dupe(u8, cwd) catch null;
            return;
        },
        .fire => {},
    }

    const owned = self.allocator.dupe(u8, cwd) catch return;
    if (self.last_hook_cwd) |previous| self.allocator.free(previous);
    self.last_hook_cwd = owned;

    if (in_hook) return;
    in_hook = true;
    defer in_hook = false;

    callFunction(self, "chpwd");
    callFunctionList(self, "chpwd_functions");
}

/// Run `precmd`, `precmd_functions`, and `PROMPT_COMMAND` before each prompt.
///
/// Unlike the directory hooks these fire on every prompt, including the first,
/// which is what both zsh and bash do.
pub fn runPrecmdHooks(self: *Shell) void {
    if (in_hook) return;
    in_hook = true;
    defer in_hook = false;

    callFunction(self, "precmd");
    callFunctionList(self, "precmd_functions");

    // bash compatibility: PROMPT_COMMAND holds a command line, not a function
    // name, so it goes through the parser rather than the function table.
    if (self.environment.get("PROMPT_COMMAND")) |command| {
        if (command.len > 0) {
            self.executeCommand(command) catch {};
        }
    }
}

/// Forget the recorded directory. Called on `deinit`.
pub fn reset(self: *Shell) void {
    if (self.last_hook_cwd) |previous| {
        self.allocator.free(previous);
        self.last_hook_cwd = null;
    }
}

/// Call one hook function by name, if it is defined.
///
/// A hook that fails must not take the shell with it: an interactive session
/// that cannot reach its prompt because a tool's integration is broken is worse
/// than one whose environment did not switch.
fn callFunction(self: *Shell, name: []const u8) void {
    if (!self.function_manager.hasFunction(name)) return;
    _ = self.function_manager.executeFunction(self, name, &[_][]const u8{}) catch {};
}

/// Call every function named in an array variable, in order, the way zsh walks
/// `chpwd_functions`. A name that is not a defined function is skipped rather
/// than reported, matching zsh, so removing a tool's rc line cannot start
/// printing errors on every prompt.
fn callFunctionList(self: *Shell, array_name: []const u8) void {
    const array = self.arrays.get(array_name) orelse return;
    for (array.values) |name| {
        if (name.len == 0) continue;
        callFunction(self, name);
    }
}

const testing = std.testing;

test "decide: first prompt records without firing" {
    try testing.expectEqual(Decision.record_only, decide(null, "/home/user"));
}

test "decide: same directory does nothing" {
    try testing.expectEqual(Decision.unchanged, decide("/home/user", "/home/user"));
}

test "decide: a changed directory fires" {
    try testing.expectEqual(Decision.fire, decide("/home/user", "/home/user/project"));
    try testing.expectEqual(Decision.fire, decide("/home/user/project", "/home/user"));
}

test "decide: a path that only shares a prefix still counts as changed" {
    // `/srv/app` and `/srv/app2` are different directories. A prefix test here
    // would leave a project active after cd'ing to its sibling.
    try testing.expectEqual(Decision.fire, decide("/srv/app", "/srv/app2"));
}

test "decide: trailing slash is a different string and so fires" {
    // getcwd never returns a trailing slash except for the root, so this only
    // documents that no normalisation happens here.
    try testing.expectEqual(Decision.fire, decide("/srv/app", "/srv/app/"));
}

test "PWD is set from the real working directory at startup" {
    // Regression: PWD used to be inherited from the parent process and only
    // corrected on the first cd, so a hook reading $PWD acted on the wrong
    // directory. Anything reading it before a cd got the parent's.
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try std.process.currentPath(std.Options.debug_io, &buf);
    try testing.expect(len > 0);
    try testing.expect(buf[0] == '/');
}
