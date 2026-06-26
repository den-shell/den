//! Builtin Dispatch Module
//! Routes shell builtin commands to their implementations

const std = @import("std");
const types = @import("../types/mod.zig");
const Shell = @import("../shell.zig").Shell;
const shell_mod = @import("mod.zig");
const IO = @import("../utils/io.zig").IO;

/// Result of attempting to dispatch a builtin command
pub const DispatchResult = enum {
    /// Command was handled as a builtin
    handled,
    /// Command is not a builtin, should be handled elsewhere
    not_builtin,
};

/// Check if a command name is a shell-level builtin (handled by dispatchBuiltin)
pub fn isShellBuiltin(name: []const u8) bool {
    const shell_builtins = [_][]const u8{
        // Job control
        "jobs",      "fg",       "bg",       "wait",     "disown",
        // History and completion
        "history",   "complete", "compgen",
        // Alias management
         "alias",    "unalias",
        // Command type inspection
        "type",      "which",
        // Source/eval/command
           "source",   ".",        "eval",
        "command",   "builtin",
        // I/O builtins
         "read",     "printf",   "mapfile",
        "readarray",
        // Test/conditionals
        "test",     "[",        "[[",
        // Directory stack
              "pushd",
        "popd",      "dirs",
        // Trivial builtins
            "true",     "false",    ":",
        // Utility builtins
        "sleep",     "help",     "clear",
        // Path utilities
           "basename", "dirname",
        "realpath",
        // System info
         "uname",    "whoami",
        // Control flow
          "return",   "break",
        "continue",  "shift",
        // Variable declaration
           "local",    "declare",  "readonly",
        "typeset",   "let",
        // Process control
             "exec",     "kill",
        // Misc
            "times",
        "time",      "umask",    "hash",     "shopt",    "caller",
        "enable",    "setopt",   "unsetopt", "ai",       "wasm",
    };
    for (shell_builtins) |b| {
        if (std.mem.eql(u8, name, b)) return true;
    }
    return false;
}

/// Try to dispatch a command as a shell builtin
/// Returns .handled if the command was executed, .not_builtin otherwise
pub fn dispatchBuiltin(self: *Shell, cmd: *types.ParsedCommand) !DispatchResult {
    const name = cmd.name;

    // Job control builtins
    if (std.mem.eql(u8, name, "jobs")) {
        self.last_exit_code = try self.job_manager.builtinJobs(cmd.args);
        return .handled;
    }
    if (std.mem.eql(u8, name, "fg")) {
        self.last_exit_code = try self.job_manager.builtinFg(cmd.args);
        return .handled;
    }
    if (std.mem.eql(u8, name, "bg")) {
        self.last_exit_code = try self.job_manager.builtinBg(cmd.args);
        return .handled;
    }

    // History and completion
    if (std.mem.eql(u8, name, "history")) {
        try shell_mod.builtinHistory(self, cmd);
        self.last_exit_code = 0;
        return .handled;
    }
    if (std.mem.eql(u8, name, "complete")) {
        try shell_mod.builtinComplete(self, cmd);
        self.last_exit_code = 0;
        return .handled;
    }
    if (std.mem.eql(u8, name, "compgen")) {
        try shell_mod.builtinCompgen(self, cmd);
        return .handled;
    }

    // Alias management
    if (std.mem.eql(u8, name, "alias")) {
        try shell_mod.builtinAlias(self, cmd);
        self.last_exit_code = 0;
        return .handled;
    }
    if (std.mem.eql(u8, name, "unalias")) {
        try shell_mod.builtinUnalias(self, cmd);
        self.last_exit_code = 0;
        return .handled;
    }

    // Command type inspection
    if (std.mem.eql(u8, name, "type")) {
        try shell_mod.builtinType(self, cmd);
        self.last_exit_code = 0;
        return .handled;
    }
    if (std.mem.eql(u8, name, "which")) {
        try shell_mod.builtinWhich(self, cmd);
        self.last_exit_code = 0;
        return .handled;
    }

    // Source/eval
    if (std.mem.eql(u8, name, "source") or std.mem.eql(u8, name, ".")) {
        try shell_mod.builtinSource(self, cmd);
        return .handled;
    }
    if (std.mem.eql(u8, name, "eval")) {
        try shell_mod.builtinEval(self, cmd);
        return .handled;
    }
    if (std.mem.eql(u8, name, "command")) {
        try shell_mod.builtinCommand(self, cmd);
        return .handled;
    }
    if (std.mem.eql(u8, name, "builtin")) {
        try shell_mod.builtinBuiltin(self, cmd);
        return .handled;
    }

    // I/O builtins
    if (std.mem.eql(u8, name, "read")) {
        try shell_mod.builtinRead(self, cmd);
        return .handled;
    }
    if (std.mem.eql(u8, name, "printf")) {
        try shell_mod.builtinPrintf(self, cmd);
        self.last_exit_code = 0;
        return .handled;
    }
    if (std.mem.eql(u8, name, "mapfile") or std.mem.eql(u8, name, "readarray")) {
        try shell_mod.builtinMapfile(self, cmd);
        return .handled;
    }

    // Test/conditionals
    if (std.mem.eql(u8, name, "test") or std.mem.eql(u8, name, "[")) {
        try shell_mod.builtinTest(self, cmd);
        return .handled;
    }
    if (std.mem.eql(u8, name, "[[")) {
        const test_builtins = @import("../executor/builtins/test_builtins.zig");
        self.last_exit_code = try test_builtins.extendedTest(cmd, self);
        return .handled;
    }

    // Directory stack
    if (std.mem.eql(u8, name, "pushd")) {
        try shell_mod.builtinPushd(self, cmd);
        return .handled;
    }
    if (std.mem.eql(u8, name, "popd")) {
        try shell_mod.builtinPopd(self, cmd);
        return .handled;
    }
    if (std.mem.eql(u8, name, "dirs")) {
        try shell_mod.builtinDirs(self, cmd);
        self.last_exit_code = 0;
        return .handled;
    }

    // Trivial builtins
    if (std.mem.eql(u8, name, "true")) {
        self.last_exit_code = 0;
        return .handled;
    }
    if (std.mem.eql(u8, name, "false")) {
        self.last_exit_code = 1;
        return .handled;
    }
    if (std.mem.eql(u8, name, ":")) {
        self.last_exit_code = 0;
        return .handled;
    }

    // Utility builtins
    if (std.mem.eql(u8, name, "sleep")) {
        try shell_mod.builtinSleep(self, cmd);
        return .handled;
    }
    if (std.mem.eql(u8, name, "help")) {
        try shell_mod.builtinHelp(self, cmd);
        self.last_exit_code = 0;
        return .handled;
    }
    if (std.mem.eql(u8, name, "clear")) {
        try shell_mod.builtinClear(self, cmd);
        self.last_exit_code = 0;
        return .handled;
    }

    // Path utilities
    if (std.mem.eql(u8, name, "basename")) {
        try shell_mod.builtinBasename(self, cmd);
        return .handled;
    }
    if (std.mem.eql(u8, name, "dirname")) {
        try shell_mod.builtinDirname(self, cmd);
        return .handled;
    }
    if (std.mem.eql(u8, name, "realpath")) {
        try shell_mod.builtinRealpath(self, cmd);
        return .handled;
    }

    // System info
    if (std.mem.eql(u8, name, "uname")) {
        try shell_mod.builtinUname(self, cmd);
        self.last_exit_code = 0;
        return .handled;
    }
    if (std.mem.eql(u8, name, "whoami")) {
        try shell_mod.builtinWhoami(self, cmd);
        self.last_exit_code = 0;
        return .handled;
    }

    // Control flow
    if (std.mem.eql(u8, name, "return")) {
        try shell_mod.builtinReturn(self, cmd);
        return .handled;
    }
    if (std.mem.eql(u8, name, "break")) {
        try shell_mod.builtinBreak(self, cmd);
        return .handled;
    }
    if (std.mem.eql(u8, name, "continue")) {
        try shell_mod.builtinContinue(self, cmd);
        return .handled;
    }
    if (std.mem.eql(u8, name, "shift")) {
        try shell_mod.builtinShift(self, cmd);
        return .handled;
    }

    // Variable declaration
    if (std.mem.eql(u8, name, "local")) {
        try shell_mod.builtinLocal(self, cmd);
        return .handled;
    }
    if (std.mem.eql(u8, name, "declare")) {
        try shell_mod.builtinDeclare(self, cmd);
        return .handled;
    }
    if (std.mem.eql(u8, name, "readonly")) {
        try shell_mod.builtinReadonly(self, cmd);
        return .handled;
    }
    if (std.mem.eql(u8, name, "typeset")) {
        try shell_mod.builtinTypeset(self, cmd);
        return .handled;
    }
    if (std.mem.eql(u8, name, "let")) {
        try shell_mod.builtinLet(self, cmd);
        return .handled;
    }

    // Process control
    if (std.mem.eql(u8, name, "exec")) {
        try shell_mod.builtinExec(self, cmd);
        return .handled;
    }
    if (std.mem.eql(u8, name, "wait")) {
        self.last_exit_code = try self.job_manager.builtinWait(cmd.args);
        return .handled;
    }
    if (std.mem.eql(u8, name, "kill")) {
        try shell_mod.builtinKill(self, cmd);
        return .handled;
    }
    if (std.mem.eql(u8, name, "disown")) {
        self.last_exit_code = try self.job_manager.builtinDisown(cmd.args);
        return .handled;
    }

    // Misc
    // getopts: handled by executor's state_builtins.getopts (real implementation)
    if (std.mem.eql(u8, name, "times")) {
        try IO.print("0m0.000s 0m0.000s\n", .{}); // Shell user/sys time
        try IO.print("0m0.000s 0m0.000s\n", .{}); // Children user/sys time
        self.last_exit_code = 0;
        return .handled;
    }
    if (std.mem.eql(u8, name, "time")) {
        try shell_mod.builtinTime(self, cmd);
        return .handled;
    }
    if (std.mem.eql(u8, name, "umask")) {
        try shell_mod.builtinUmask(self, cmd);
        return .handled;
    }
    if (std.mem.eql(u8, name, "hash")) {
        try shell_mod.builtinHash(self, cmd);
        return .handled;
    }
    if (std.mem.eql(u8, name, "shopt")) {
        try shell_mod.builtinShopt(self, cmd);
        return .handled;
    }
    if (std.mem.eql(u8, name, "caller")) {
        try shell_mod.builtinCaller(self, cmd);
        return .handled;
    }
    if (std.mem.eql(u8, name, "enable")) {
        try shell_mod.builtinEnable(self, cmd);
        return .handled;
    }
    if (std.mem.eql(u8, name, "setopt")) {
        try shell_mod.builtinSetopt(self, cmd);
        return .handled;
    }
    if (std.mem.eql(u8, name, "unsetopt")) {
        try shell_mod.builtinUnsetopt(self, cmd);
        return .handled;
    }
    if (std.mem.eql(u8, name, "ai")) {
        try shell_mod.builtinAi(self, cmd);
        return .handled;
    }
    if (std.mem.eql(u8, name, "wasm")) {
        try shell_mod.builtinWasm(self, cmd);
        return .handled;
    }

    return .not_builtin;
}
