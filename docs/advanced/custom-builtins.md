# Extending Den

Den can be extended at several levels, from quick aliases to compiled plugins. Pick the lightest tool that does the job.

## Aliases

Quick command rewrites — define at runtime or in [`den.jsonc`](../config.md):

```bash
alias gst='git status'
alias ll='ls -lh'
```

## Suffix aliases

Run a file by name, dispatched on its extension (zsh-style):

```bash
alias -s ts='bun'      # `./script.ts` runs `bun ./script.ts`
alias -s py='python3'
```

## Functions

For logic, arguments, and multiple statements, define a shell function:

```bash
mkcd() { mkdir -p "$1" && cd "$1"; }
gcap() { git commit -am "$1" && git push; }
```

Put functions in `~/.denrc` (or a file it sources) to have them available in every session. See [Scripting](../SCRIPTING.md) for the full function syntax.

## WebAssembly plugins

Den ships a dependency-free WASM interpreter. Compile a plugin from any
WebAssembly-targeting language and call its exports:

```bash
wasm ./plugin.wasm add 17 25     # -> 42
wasm --exports ./plugin.wasm     # list exported functions
```

See [Extended Features](../EXTENDED_FEATURES.md) for the interpreter's capabilities.

## Native plugins

For deeper integration (hooks, custom builtins, prompt modules), Den has a native
plugin API. See [Plugin Development](../PLUGIN_DEVELOPMENT.md) for the interface,
lifecycle, and examples.

## Which should I use?

| Need | Use |
|---|---|
| Rename a command | alias |
| Run files by extension | suffix alias |
| Logic / arguments | function |
| Portable compiled logic | WASM plugin |
| Hooks, builtins, prompt modules | native plugin |

## See also

- [Custom Commands guide](../guide/custom-commands.md) · [Plugin Development](../PLUGIN_DEVELOPMENT.md) · [Scripting](../SCRIPTING.md)
