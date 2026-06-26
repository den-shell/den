# Den Shell

> A modern, POSIX-compliant shell written in Zig — native performance, a tiny dependency-free binary, and a feature set that rivals zsh and fish.

Den combines the familiarity of traditional shells with native speed and memory safety. It was originally prototyped in TypeScript/Bun and completely rewritten in Zig for zero runtime dependencies and minimal memory use.

- ⚡ **Native performance** — ~5ms startup, no runtime overhead
- 📦 **Tiny binary** — ~1.8MB executable with zero dependencies
- 🛡️ **Memory safe** — Zig's compile-time safety prevents whole classes of bugs
- 🎯 **Feature rich** — 58 builtins, job control, history, completion, expansion, a full line editor
- 🧩 **Extensible** — WASM plugins, AI-assisted completions, distributed sessions, an LSP server
- ✅ **Compatible** — POSIX-compliant with a zsh compatibility layer and a bash migration path

📖 **Full documentation lives in [`./docs`](docs/) — every feature below links to its dedicated page.**

## Table of Contents

- [Why Den](#why-den) · [Performance](#performance)
- [Quick Start](#quick-start) · [Installation](#installation) · [Configuration](#configuration)
- [Features](#features) — [core](#core-shell), [expansion](#expansion), [interactive](#interactive-experience), [completion](#completion), [builtins](#built-in-commands), [scripting](#scripting), [extended](#extended-capabilities)
- [Compatibility & Migration](#compatibility--migration)
- [Documentation](#documentation) · [Building from Source](#building-from-source) · [Contributing](#contributing)

## Why Den

| | Den | Bash | Zsh | Fish |
|---|---|---|---|---|
| **Startup time** | 5ms | 25ms | 35ms | 45ms |
| **Memory (idle)** | 2MB | 4MB | 6MB | 8MB |
| **Command exec** | 0.8ms | 2.1ms | 2.5ms | 3.2ms |
| **Dependencies** | 0 | libc | libc | multiple |

Den is **5–9x faster to start** and uses **2–4x less memory** than popular shells, while shipping a single static binary. See [Benchmarks](docs/BENCHMARKS.md) for methodology and full results.

### Performance

Den's speed comes from deliberate engineering, documented in depth:

- [Benchmarks](docs/BENCHMARKS.md) — methodology and head-to-head numbers
- [Algorithms](docs/ALGORITHMS.md) — the algorithmic choices behind hot paths
- [Data Structures](docs/DATA_STRUCTURES.md) — the structures backing history, completion, and expansion
- [CPU Optimization](docs/CPU_OPTIMIZATION.md) — branch-friendly, cache-aware execution
- [Memory Optimization](docs/MEMORY_OPTIMIZATION.md) — arena/pool strategies and zero-copy parsing
- [Concurrency](docs/CONCURRENCY.md) — async git status, background jobs, and the prompt fetcher
- [Profiling](docs/profiling.md) — how to profile Den and read the output

## Quick Start

```bash
# Build Den (see Installation for prebuilt binaries / package managers)
zig build -Doptimize=ReleaseFast

# Start an interactive shell
./zig-out/bin/den

# Run a script
./zig-out/bin/den script.sh

# Run a single command
./zig-out/bin/den -c 'echo "Hello from Den!"'
```

A first interactive session:

```text
❯ echo "Hello, World!"
Hello, World!

❯ export MY_VAR="test"
❯ echo $MY_VAR
test

❯ ls -la | grep zig
-rw-r--r--  1 user  staff  42627 build.zig
drwxr-xr-x  3 user  staff     96 zig-out
```

New to Den? Start with the [Introduction](docs/intro.md) and the [Quick Reference](docs/QUICK_REFERENCE.md) cheat sheet.

## Installation

```bash
# Homebrew (macOS / Linux)
brew install stacksjs/tap/den

# Install script (downloads the latest release binary)
curl -fsSL https://raw.githubusercontent.com/stacksjs/den/main/scripts/install.sh | bash

# From source
zig build -Doptimize=ReleaseFast && zig build install --prefix ~/.local
```

Distribution packages are provided for Debian/Ubuntu (`.deb`), Fedora/RHEL (`.rpm`), Arch (`PKGBUILD`), and Nix ([`packaging/`](packaging/)). To make Den your login shell, add it to `/etc/shells` and run `chsh`. Full details — prebuilt binaries, package managers, and login-shell setup — are in the [Installation guide](docs/install.md).

## Configuration

Den reads two files at startup:

- **`~/.denrc`** — a shell script sourced on startup (like `.zshrc`): set environment, `$PATH`, aliases, and run commands.
- **`~/.config/den.jsonc`** — declarative JSONC config for the prompt, history, completion, theme, aliases, and keybindings. A fully-commented example lives at [`den.jsonc`](den.jsonc).

Everything you can configure — prompt format, history behaviour, completion, colours/symbols, and keybindings — is documented in the [Configuration reference](docs/config.md). Prompt styling has its own deep-dive in [Themes](docs/THEMES.md).

## Features

### Core Shell

| Feature | Description | Docs |
|---|---|---|
| Pipelines | Multi-stage `cmd1 \| cmd2 \| cmd3` | [Features](docs/FEATURES.md) |
| I/O redirection | `>`, `>>`, `<`, `2>`, `2>&1`, here-docs, here-strings | [Features](docs/FEATURES.md) |
| Boolean operators | Short-circuit `&&` and `\|\|` | [Features](docs/FEATURES.md) |
| Command chaining | Sequential `;` lists | [Features](docs/FEATURES.md) |
| Background jobs | `&`, `jobs`, `fg`, `bg`, `wait`, `disown` | [Features](docs/FEATURES.md) |
| Subshells & grouping | `( … )` and `{ …; }` | [Scripting](docs/SCRIPTING.md) |

### Expansion

| Feature | Description | Docs |
|---|---|---|
| Variable expansion | `$VAR`, `${VAR}`, `${VAR:-default}`, `${#VAR}`, `${VAR#prefix}`, special vars (`$?`, `$$`, `$!`, `$_`, `$0`–`$9`, `$@`, `$*`, `$#`) | [Features](docs/FEATURES.md) |
| Command substitution | `$(command)` (and backticks) | [Features](docs/FEATURES.md) |
| Arithmetic | `$(( expr ))` with `+ - * / % **` | [Features](docs/FEATURES.md) |
| Brace expansion | `{1..10}`, `{a..z}`, `{foo,bar,baz}` | [Features](docs/FEATURES.md) |
| Tilde expansion | `~`, `~/path`, `~user` | [Features](docs/FEATURES.md) |
| Glob expansion | `*.zig`, `**/*.txt`, plus zsh glob qualifiers | [Features](docs/FEATURES.md) |

### Interactive Experience

| Feature | Description | Docs |
|---|---|---|
| Line editor | Emacs & Vi keymaps, word motions, kill-ring, multi-line editing | [Line Editing](docs/LINE_EDITING.md) |
| Inline autosuggestions | fish-style suggestions from history as you type | [Autocompletion](docs/AUTOCOMPLETION.md) |
| Syntax highlighting | Live command highlighting in the prompt | [Line Editing](docs/LINE_EDITING.md) |
| Persistent history | Shared, de-duplicated, configurable history file | [Features](docs/FEATURES.md) |
| History substring search | Up/Down filters history by what you've typed | [History Substring Search](docs/HISTORY_SUBSTRING_SEARCH.md) |
| Prompt & themes | Two-line prompt, git status, runtime modules, colours/symbols | [Themes](docs/THEMES.md) |

### Completion

| Feature | Description | Docs |
|---|---|---|
| Tab completion | Commands, files, options, and a navigable grid menu (arrow keys move by row/column) | [Tab Completion](docs/TAB_COMPLETION.md) |
| Mid-word completion | Expand abbreviated paths like `/u/l/b` → `/usr/local/bin` | [Mid-word Completion](docs/MID_WORD_COMPLETION.md) |
| Git completion | Branches, remotes, files, and subcommands for `git` | [Git Completion](docs/GIT_COMPLETION.md) |
| Context-aware completion | Per-command argument/flag completion (npm, bun, docker, …) | [Autocompletion](docs/AUTOCOMPLETION.md) |

### Built-in Commands

Den ships **58 built-in commands**. The complete reference — flags, behaviour, and examples for each — is in [Builtins](docs/BUILTINS.md) (run `help` inside Den for a quick summary).

- **Core**: `exit`, `help`, `true`, `false`
- **File system**: `cd`, `pwd`, `pushd`, `popd`, `dirs`, `realpath`
- **Environment**: `env`, `export`, `set`, `unset`
- **Introspection**: `alias`, `unalias`, `type`, `which`
- **Job control**: `jobs`, `fg`, `bg`, `kill`, `wait`, `disown`
- **History & completion**: `history`, `complete`
- **Scripting**: `source`/`.`, `read`, `test`/`[`, `eval`, `shift`, `command`, `return`, `break`, `continue`, `local`, `declare`, `readonly`, `getopts`
- **Path utilities**: `basename`, `dirname`
- **Output**: `echo`, `printf`
- **System**: `time`, `sleep`, `umask`, `hash`, `clear`, `uname`, `whoami`, `times`
- **Advanced execution**: `exec`, `builtin`, `trap`
- **zsh & extended**: `setopt`, `unsetopt`, `ai`, `wasm`

> Den also provides fast built-in implementations of common coreutils (`grep`, `ls`, `find`, `date`, `seq`, `base64`, `tree`, …). When invoked with options the builtin doesn't implement, Den transparently falls back to the real tool on `$PATH`, so advanced usage always works.

### Scripting

Full POSIX scripting — `if`/`then`/`else`, `for`, `while`, `until`, `case`, and functions — plus here-documents and traps. See the [Scripting guide](docs/SCRIPTING.md).

```bash
#!/usr/bin/env den

export PROJECT="my-app"

if test -f README.md; then
  echo "$PROJECT: README present"
fi

for file in *.zig; do
  echo "compiling $(basename "$file")"
done

greet() { echo "hello, $1"; }
greet world
```

### Extended Capabilities

| Feature | Description | Docs |
|---|---|---|
| zsh compatibility | `setopt`/`unsetopt`, `%`-prompt escapes, glob qualifiers, arrays, associative arrays, named directories, auto-cd | [zsh Compatibility](docs/ZSH_MIGRATION.md) |
| WASM plugins | `wasm <module.wasm> <export> [args]` via a built-in interpreter; write your own | [Plugin Development](docs/PLUGIN_DEVELOPMENT.md) |
| AI-assisted completions | `ai <describe a command>` (OpenAI/Anthropic-compatible) | [Extended Features](docs/EXTENDED_FEATURES.md) |
| Distributed sessions | `den --serve` / `den --connect` (loopback-only by default) | [Extended Features](docs/EXTENDED_FEATURES.md) |
| Language Server | `den --lsp` for editor integration | [Extended Features](docs/EXTENDED_FEATURES.md) |

## Compatibility & Migration

- Coming from **bash**? See the [Bash Migration guide](docs/BASH_MIGRATION.md).
- Coming from **zsh**? See [zsh Compatibility](docs/ZSH_MIGRATION.md).
- Upgrading from an older Den / the TypeScript prototype? See the [Migration guide](docs/MIGRATION.md).
- Stuck? The [Troubleshooting guide](docs/TROUBLESHOOTING.md) covers common issues.

## Documentation

Everything is under [`./docs`](docs/). Highlights by audience:

**Get started**
- [Introduction](docs/intro.md) · [Installation](docs/install.md) · [Quick Start](docs/guide/quick-start.md) · [Usage](docs/usage.md) · [Quick Reference](docs/QUICK_REFERENCE.md)

**Use Den**
- [Features](docs/FEATURES.md) · [Builtins](docs/BUILTINS.md) · [Scripting](docs/SCRIPTING.md) · [Configuration](docs/config.md) · [Themes](docs/THEMES.md)
- [Line Editing](docs/LINE_EDITING.md) · [Tab Completion](docs/TAB_COMPLETION.md) · [Autocompletion](docs/AUTOCOMPLETION.md) · [Git Completion](docs/GIT_COMPLETION.md) · [Mid-word Completion](docs/MID_WORD_COMPLETION.md) · [History Substring Search](docs/HISTORY_SUBSTRING_SEARCH.md)
- [Advanced Usage](docs/ADVANCED.md) · [Extended Features](docs/EXTENDED_FEATURES.md) · [Custom Commands](docs/guide/custom-commands.md)

**Migrate**
- [Bash Migration](docs/BASH_MIGRATION.md) · [zsh Compatibility](docs/ZSH_MIGRATION.md) · [Migration](docs/MIGRATION.md) · [Troubleshooting](docs/TROUBLESHOOTING.md)

**Performance**
- [Benchmarks](docs/BENCHMARKS.md) · [Algorithms](docs/ALGORITHMS.md) · [Data Structures](docs/DATA_STRUCTURES.md) · [CPU Optimization](docs/CPU_OPTIMIZATION.md) · [Memory Optimization](docs/MEMORY_OPTIMIZATION.md) · [Concurrency](docs/CONCURRENCY.md) · [Profiling](docs/profiling.md)

**Develop & extend**
- [Architecture](docs/ARCHITECTURE.md) · [API Reference](docs/API.md) · [Plugin Development](docs/PLUGIN_DEVELOPMENT.md) · [Testing](docs/TESTING.md) · [CI/CD](docs/CI_CD.md) · [Dependencies](docs/DEPENDENCIES.md) · [Contributing](docs/CONTRIBUTING.md)

## Building from Source

**Requirements:** Zig 0.17-dev or later; macOS, Linux, or BSD (Windows support planned).

```bash
zig build                            # debug build
zig build -Doptimize=ReleaseFast     # optimized release
zig build install --prefix ~/.local  # install
zig build test                       # run the test suite
```

See [Architecture](docs/ARCHITECTURE.md) for the source layout and [Testing](docs/TESTING.md) for the test framework. The full feature roadmap is in [ROADMAP.md](ROADMAP.md).

## Contributing

Contributions are welcome! Please read the [Contributing guide](docs/CONTRIBUTING.md) to get started.

## License

MIT License — see [LICENSE](LICENSE.md).

Made with 💙 by the Stacks team.

## Community

- [GitHub Discussions](https://github.com/stacksjs/den/discussions)
- [Discord Server](https://discord.gg/stacksjs)
