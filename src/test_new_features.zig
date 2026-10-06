//! Aggregate test root for Den's newer subsystems so they get a dedicated
//! `zig build test-features` step. These tests also run as part of the main
//! `zig build test` suite (they are reachable from main.zig), but a focused
//! step keeps iteration fast.

test {
    _ = @import("compat/zsh.zig"); // zsh compatibility layer
    _ = @import("compat/bindkey.zig"); // zsh bindkey key-sequence notation
    _ = @import("compat/zstyle.zig"); // zsh zstyle database
    _ = @import("compat/version.zig"); // version comparison for is-at-least
    _ = @import("ai/completion.zig"); // AI-assisted completions
    _ = @import("net/session.zig"); // distributed shell sessions
    _ = @import("plugins/wasm.zig"); // WebAssembly plugin host
}
