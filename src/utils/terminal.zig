//! Terminal module - modular terminal handling for Den shell
//!
//! This file serves as a compatibility layer that re-exports from the
//! modular terminal/ directory structure for backwards compatibility.
//!
//! The terminal module provides:
//! - Terminal: Raw mode management for terminal I/O
//! - EscapeSequence: Parser for terminal escape sequences
//! - LineEditor: Full-featured line editor with Vi/Emacs modes
//! - Keymap: byte sequences to named editing widgets, behind `bindkey`
//! - Type definitions for editing modes and completion
//!
//! For new code, prefer importing directly from the terminal/ modules:
//! - terminal/terminal.zig: Terminal struct
//! - terminal/escape.zig: EscapeSequence enum
//! - terminal/line_editor.zig: LineEditor struct
//! - terminal/keymap.zig: Keymap, Widget, KeymapSet
//! - terminal/types.zig: Type definitions

const mod = @import("terminal/mod.zig");

// Re-export all public symbols for backwards compatibility
pub const Terminal = mod.Terminal;
pub const windows = mod.windows;
pub const EscapeSequence = mod.EscapeSequence;
pub const CompletionFn = mod.CompletionFn;
pub const EditingMode = mod.EditingMode;
pub const ViMode = mod.ViMode;
pub const UndoState = mod.UndoState;
pub const Flow = mod.Flow;
pub const LineEditor = mod.LineEditor;
pub const keymap = mod.keymap;
pub const Widget = mod.Widget;
pub const KeymapId = mod.KeymapId;
pub const KeymapSet = mod.KeymapSet;
