# Introduction

**Den** is a modern, POSIX-compliant shell written in [Zig](https://ziglang.org). It pairs the familiarity of bash/zsh with native performance, memory safety, and a single dependency-free binary.

Den was originally prototyped in TypeScript/Bun and rewritten in Zig for zero runtime dependencies, ~5ms startup, and minimal memory use.

## Why Den

- **⚡ Fast** — ~5ms startup, 5–9x faster than bash/zsh/fish, no runtime overhead.
- **📦 Tiny** — a ~1.8MB static binary with zero dependencies; deploy anywhere.
- **🛡️ Safe** — written in Zig; compile-time safety prevents whole classes of bugs.
- **🎯 Complete** — 58 builtins, pipelines, job control, history, completion, and full expansion.
- **🧩 Extensible** — WASM plugins, AI-assisted completions, distributed sessions, and an LSP server.
- **✅ Compatible** — POSIX-compliant with a zsh compatibility layer and a bash migration path.

## What you get

- A full interactive line editor with inline autosuggestions, syntax highlighting, and a navigable completion grid — see [Line Editing](./LINE_EDITING.md) and [Tab Completion](./TAB_COMPLETION.md).
- Variable, command, arithmetic, brace, tilde, and glob expansion — see [Features](./FEATURES.md).
- POSIX scripting with functions, loops, conditionals, and traps — see [Scripting](./SCRIPTING.md).
- A two-line prompt with git status and runtime modules, fully themeable — see [Themes](./THEMES.md).

## Get started

1. [Install Den](./install.md)
2. Follow the [Quick Start](./guide/quick-start.md)
3. [Configure](./config.md) your prompt, aliases, and keybindings
4. Keep the [Quick Reference](./QUICK_REFERENCE.md) handy

## Community

- [Discussions on GitHub](https://github.com/stacksjs/den/discussions)
- [Join the Stacks Discord Server](https://discord.gg/stacksjs)

## License

The MIT License (MIT). See [LICENSE](https://github.com/stacksjs/den/blob/main/LICENSE.md).

Made with 💙 by the Stacks team.
