//! Terminal module - modular terminal handling for Den shell
//!
//! This module provides:
//! - Terminal: Raw mode management for terminal I/O
//! - EscapeSequence: Parser for terminal escape sequences
//! - LineEditor: Full-featured line editor with Vi/Emacs modes
//! - Keymap: byte sequences to named editing widgets, behind `bindkey`
//! - Type definitions for editing modes and completion

const std = @import("std");

// Re-export components
pub const Terminal = @import("terminal.zig").Terminal;
pub const windows = @import("terminal.zig").windows;
pub const EscapeSequence = @import("escape.zig").EscapeSequence;

// Keymaps and widgets (the data layer behind `bindkey`)
pub const keymap = @import("keymap.zig");
pub const Widget = keymap.Widget;
pub const KeymapId = keymap.KeymapId;
pub const KeymapSet = keymap.KeymapSet;

// Re-export types
pub const CompletionFn = @import("types.zig").CompletionFn;
pub const EditingMode = @import("types.zig").EditingMode;
pub const ViMode = @import("types.zig").ViMode;
pub const UndoState = @import("types.zig").UndoState;

// LineEditor is imported from the main terminal file for now
// (will be fully modularized in a future iteration)
pub const LineEditor = @import("line_editor.zig").LineEditor;
