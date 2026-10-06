//! The zsh startup preamble: `compinit`, `bashcompinit`, `zmodload`, `emulate`,
//! `compdef` and `is-at-least`.
//!
//! These are the lines at the top of nearly every `.zshrc`, above anything
//! interesting. Without them a user sourcing their config met a wall of
//! `command not found` before reaching the `setopt`, `bindkey` and `zstyle`
//! lines den does implement.
//!
//! Most of them are setup for machinery den does not have, and the honest
//! answer is that no setup is needed rather than that the command is missing:
//! completion is always on, there are no loadable modules, and there is one set
//! of shell semantics. So they succeed and do nothing. That is a real answer to
//! what the caller asked for, not a pretence -- the capability is present, it
//! just needed no arranging. Where that is *not* true the command says so
//! instead; see `is-at-least`.
//!
//! What this file must never do is print on a successful call. These run while
//! an rc file is being sourced, so a note per line would be noise on every
//! single shell start. The divergences are documented instead.

const std = @import("std");
const IO = @import("../utils/io.zig").IO;
const types = @import("../types/mod.zig");
const version = @import("../compat/version.zig");

const Shell = @import("../shell.zig").Shell;

/// `compinit` -- zsh's completion initialiser.
///
/// Den's completion is built in and context-aware with nothing to initialise,
/// so this succeeds. Every flag zsh takes (`-d dumpfile`, `-u`, `-i`, `-C`,
/// `-D`) concerns the dump file it builds and the insecure-directory check it
/// runs; den builds no dump and so has nothing to check or skip.
pub fn builtinCompinit(self: *Shell, cmd: *types.ParsedCommand) !void {
    _ = cmd;
    self.last_exit_code = 0;
}

/// `bashcompinit` -- in zsh, switches on the bash-style `complete`/`compgen`.
///
/// Den has both of those as ordinary builtins that are always available, so
/// there is nothing to switch on.
pub fn builtinBashcompinit(self: *Shell, cmd: *types.ParsedCommand) !void {
    _ = cmd;
    self.last_exit_code = 0;
}

/// `compdef` -- bind a zsh completion function to a command.
///
/// Accepted and ignored. Den's completion is driven by its own context-aware
/// engine rather than by `_`-prefixed shell functions, so there is no function
/// here for a name like `_git` to refer to. A command whose completion den does
/// not already know is completed as a file, which is what it did before.
///
/// `complete -F` is the supported way to attach a shell function to a command.
pub fn builtinCompdef(self: *Shell, cmd: *types.ParsedCommand) !void {
    _ = cmd;
    self.last_exit_code = 0;
}

/// `zmodload` -- load a zsh binary module.
///
/// Den has no loadable modules: what the common ones provide is either built in
/// (`zsh/complist`'s menu selection, `zsh/zle`'s editor, `zsh/terminfo`'s
/// queries) or absent, and either way nothing is loaded on request. A module
/// whose features really are missing surfaces that at the point of use, with the
/// name of whatever could not be found, which is a better error than refusing
/// the `zmodload` line itself.
///
/// `-e`, which asks whether a module is loaded, answers no rather than yes: a
/// config that tests before using a module should take its fallback path.
pub fn builtinZmodload(self: *Shell, cmd: *types.ParsedCommand) !void {
    for (cmd.args) |arg| {
        if (arg.len >= 2 and arg[0] == '-') {
            for (arg[1..]) |c| {
                if (c == 'e') {
                    self.last_exit_code = 1;
                    return;
                }
            }
        }
    }
    self.last_exit_code = 0;
}

/// `emulate` -- switch to another shell's semantics.
///
/// Den has one set of semantics, close to zsh's with POSIX behaviour where they
/// conflict, and does not reshape itself on request. `sh`, `ksh` and `zsh` are
/// accepted because what a caller wants from them -- predictable POSIX
/// behaviour, usually inside a function with `-L` -- is what it already gets.
///
/// `csh` is refused. Its word splitting and history syntax are nothing like
/// den's, so a function that asked for csh and carried on would quietly do the
/// wrong thing; the error is the better outcome.
pub fn builtinEmulate(self: *Shell, cmd: *types.ParsedCommand) !void {
    for (cmd.args) |arg| {
        if (arg.len >= 1 and arg[0] == '-') continue;
        if (std.mem.eql(u8, arg, "csh")) {
            try IO.eprint("den: emulate: csh semantics are not available\n", .{});
            self.last_exit_code = 1;
            return;
        }
        if (!std.mem.eql(u8, arg, "sh") and
            !std.mem.eql(u8, arg, "ksh") and
            !std.mem.eql(u8, arg, "zsh"))
        {
            try IO.eprint("den: emulate: unknown shell: {s}\n", .{arg});
            self.last_exit_code = 1;
            return;
        }
    }
    self.last_exit_code = 0;
}

/// `is-at-least <version> [<against>]` -- zsh's version test.
///
/// With two operands this is a straight version comparison and behaves exactly
/// as zsh's does.
///
/// With one, zsh compares against `$ZSH_VERSION`. Den does not set that
/// variable -- it reports itself as den, through `DEN_VERSION`, rather than
/// claiming to be zsh -- so there is no zsh version to be at least. This
/// returns false, which sends a config down its older-zsh branch. That is the
/// conservative direction: the alternative enables whatever the config guards
/// behind a modern zsh, which is exactly the set of features most likely to be
/// the ones den does not have.
pub fn builtinIsAtLeast(self: *Shell, cmd: *types.ParsedCommand) !void {
    if (cmd.args.len == 0) {
        try IO.eprint("usage: is-at-least version [against]\n", .{});
        self.last_exit_code = 2;
        return;
    }

    const want = cmd.args[0];
    const against = if (cmd.args.len >= 2)
        cmd.args[1]
    else
        self.environment.get("ZSH_VERSION") orelse {
            self.last_exit_code = 1;
            return;
        };

    self.last_exit_code = if (version.isAtLeast(against, want)) 0 else 1;
}
