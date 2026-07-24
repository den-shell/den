# Den Shell Roadmap

This document outlines the development roadmap for Den, a modern shell written in Zig.

## Current Status: v0.1.x (Active Development)

Den is currently in active development with core shell functionality complete and production-ready features being refined. The codebase builds against the Zig 0.17-dev toolchain.

## Phase 1: Core Shell (Complete)

- [x] Command parsing and execution
- [x] Pipeline support (`|`, `||`, `&&`)
- [x] Background jobs (`&`)
- [x] Redirection (`>`, `>>`, `<`, `2>`, `&>`)
- [x] Environment variables
- [x] History with persistence
- [x] Tab completion
- [x] Line editing (emacs/vi modes)
- [x] Globbing and brace expansion
- [x] Alias support

## Phase 2: POSIX Compatibility (Complete)

- [x] Control flow (`if`, `for`, `while`, `case`, `until`)
- [x] Functions
- [x] Parameter expansion (`${}`, arrays)
- [x] Command substitution (`$()`, backticks)
- [x] Arithmetic expansion (`$(())`, `$[]`)
- [x] Process substitution (`<()`, `>()`)
- [x] Here documents and here strings
- [x] Job control (jobs, fg, bg, disown, wait)
- [x] Signal handling
- [x] Exit traps

## Phase 3: Extended Features (Complete)

- [x] C-style for loops (`for ((i=0; i<10; i++))`)
- [x] Select menus
- [x] Coprocess support
- [x] Extended globbing (extglob)
- [x] Configuration file support (JSONC)
- [x] Hot-reload configuration
- [x] Full zsh compatibility layer (`setopt`/`unsetopt`, `%`-prompt escapes, glob qualifiers, arrays, associative arrays, named directories, auto-cd, global/suffix aliases — see `src/compat/zsh.zig`)
- [x] Fish-style autosuggestions (wired into the line editor, config-driven via `line_editor.autosuggestions`)
- [x] Syntax highlighting (wired into the line editor, config-driven via `line_editor.syntax_highlighting`)

## Phase 4: Performance & Polish (Complete)

- [x] Startup time optimization (<10ms target — internal startup ~1ms; lazy-init for line editor, prompt, plugins; verified via `startup_bench`)
- [x] Memory footprint reduction (~4.5MB idle RSS, ~2.8MB release binary; object pools and arena allocators throughout)
- [x] Comprehensive test suite (`zig build test`, `test-all`, and `test-features` covering the new subsystems)
- [x] Cross-platform CI/CD (GitHub Actions on ubuntu + macOS, pinned Zig 0.17-dev; runs build + all test steps)
- [x] Documentation completion (see `docs/EXTENDED_FEATURES.md` plus the existing docs set)
- [x] Plugin ecosystem (native plugin API + discovery, loadable builtins, and a WebAssembly plugin host with an example in `examples/plugins/wasm`)

## Phase 5: Future Directions (Complete)

- [x] Language server protocol support (`den --lsp` — `initialize`, completion, hover, diagnostics; see `src/lsp/`)
- [x] WebAssembly plugins (dependency-free WASM interpreter + `wasm` builtin; runs real compiler-generated modules — see `src/plugins/wasm.zig`)
- [x] Distributed shell sessions (`den --serve` / `den --connect` over TCP; loopback-only by default — see `src/net/session.zig`)
- [x] AI-assisted completions (`ai` builtin backed by an OpenAI/Anthropic-compatible endpoint — see `src/ai/completion.zig`)

## Module Organization

The codebase is organized into focused modules:

```
src/
├── shell.zig           # Main shell logic
├── main.zig            # Entry point
├── cli.zig             # CLI argument handling
├── parser/             # Command parsing
├── executor/           # Command execution
├── types/              # Type definitions
├── utils/              # Utility functions
├── history/            # History management
├── jobs/               # Job control
├── prompt/             # Prompt rendering
├── plugins/            # Plugin system (incl. wasm.zig — WebAssembly host)
├── scripting/          # Script execution
├── compat/             # zsh compatibility layer
├── ai/                 # AI-assisted completions
├── net/                # Distributed shell sessions
├── lsp/                # Language Server Protocol
└── config_loader.zig   # Configuration
```

## Contributing

See [CONTRIBUTING.md](docs/CONTRIBUTING.md) for contribution guidelines.

## Version History

See [CHANGELOG.md](CHANGELOG.md) for detailed version history.
