const std = @import("std");
const cli = @import("cli");

// CLI Tests
// Tests for command-line interface argument parsing and subcommand handling

// Forces the cli module to be analysed under test, so a change that breaks its
// compilation fails here rather than only in `zig build`. It does not reach the
// tests of the files cli.zig imports: Zig pulls those in only through a
// `_ = @import(...)` in a test block within the module being analysed, which is
// why src/import_zsh.zig is listed in src/test_new_features.zig instead.
test {
    _ = cli;
}

test "CLI: parseArgs with no arguments returns interactive" {
    // NOTE: This test is conceptual because mocking std.process.args is complex
    // The actual logic is tested through integration testing
}

test "CLI: parseArgs with 'version' flag" {
    // Conceptual test - actual testing done via integration
}

test "CLI: parseArgs with 'help' flag" {
    // Conceptual test - actual testing done via integration
}

test "CLI: parseArgs with 'exec' subcommand" {
    // Conceptual test - actual testing done via integration
}

test "CLI: parseArgs with script file" {
    // Conceptual test - actual testing done via integration
}

test "CLI: version string format" {
    try std.testing.expect(cli.VERSION.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, cli.VERSION, ".") != null);
}

test "CLI: Command enum has all expected commands" {
    // Verify all commands are defined
    const cmd1: cli.Command = .interactive;
    const cmd2: cli.Command = .shell;
    const cmd3: cli.Command = .exec;
    const cmd4: cli.Command = .complete;
    const cmd5: cli.Command = .dev_setup;
    const cmd6: cli.Command = .setup;
    const cmd7: cli.Command = .set_shell;
    const cmd8: cli.Command = .uninstall;
    const cmd9: cli.Command = .version;
    const cmd10: cli.Command = .help;
    const cmd11: cli.Command = .script;

    _ = cmd1;
    _ = cmd2;
    _ = cmd3;
    _ = cmd4;
    _ = cmd5;
    _ = cmd6;
    _ = cmd7;
    _ = cmd8;
    _ = cmd9;
    _ = cmd10;
    _ = cmd11;
}

test "CLI: CliArgs structure" {
    const allocator = std.testing.allocator;

    var args = cli.CliArgs{
        .command = .version,
        .args = &[_][]const u8{},
        .allocator = allocator,
    };

    try std.testing.expectEqual(cli.Command.version, args.command);
    try std.testing.expectEqual(@as(usize, 0), args.args.len);

    args.deinit();
}
