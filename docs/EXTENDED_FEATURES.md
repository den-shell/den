# Extended Features

This page documents Den's extended capabilities beyond the POSIX/zsh core:
the zsh compatibility layer, inline autosuggestions and syntax highlighting,
AI-assisted completions, distributed shell sessions, and WebAssembly plugins.

All of these are configurable in `den.jsonc`. See [config.md](./config.md) for
the full configuration reference.

## Line editor: autosuggestions & syntax highlighting

Den's interactive line editor offers fish-style inline autosuggestions (drawn
from your history) and real-time syntax highlighting. Both are on by default and
configurable:

```jsonc
{
  "line_editor": {
    "syntax_highlighting": true,   // colorize the command line as you type
    "autosuggestions": true,       // show a greyed-out suggestion from history
    "suggestion_min_chars": 1      // chars typed before suggesting
  }
}
```

- Accept the current suggestion with **→ (Right arrow)** or **End**.
- Suggestions are matched against your most recent history entries by prefix.

## zsh compatibility layer

Den implements a number of zsh-flavored behaviors. The layer is configurable:

```jsonc
{
  "zsh": {
    "enabled": true,
    "glob_qualifiers": true,     // *(.) *(/) *(x) ... filtering engine
    "prompt_escapes": true,      // %n %m %~ %# ... in prompt formats
    "setopt": true               // setopt / unsetopt builtins
  }
}
```

### `setopt` / `unsetopt`

Accept zsh option names and map them onto Den's option flags:

```sh
setopt nullglob extendedglob autocd
unsetopt nullglob
setopt            # list enabled options
```

Recognized names include `extendedglob`, `nullglob`, `globdots`, `nocaseglob`,
`globstar`, `nomatch`/`failglob`, `autocd`, `appendhistory`, `errexit`,
`nounset`, `xtrace`, `noglob`, `pipefail`, `verbose` (and common `no_` / case
variants). Unknown names report `no such option`.

### Prompt `%`-escapes

When `zsh.prompt_escapes` is enabled and your prompt format contains `%`, the
following zsh escapes are expanded: `%n` (user), `%m`/`%M` (short/full host),
`%~` (cwd with `~`), `%d`/`%/` (cwd), `%c`/`%C` (last path component), `%#`
(`#` for root else `%`), `%?` (last exit code), `%B`/`%b`, `%U`/`%u`,
`%F{color}`/`%f`, `%K{color}`/`%k`, `%T`/`%*` (time), `%D` (date), `%%`.

### Glob qualifiers

The qualifier engine filters glob matches by type/permission: `/` or `d`
(directory), `.` or `f` (regular file), `@` (symlink), `x`/`X` (executable),
`r`/`R` (readable), `w`/`W` (writable), `p` (pipe), `s` (socket). Note that
Den's `*(...)` syntax is also used by bash-style extended globbing; the
qualifier engine applies wherever a qualifier reaches glob expansion.

## AI-assisted completions

The `ai` builtin turns a natural-language description into a shell command using
an OpenAI-compatible (or Anthropic) chat endpoint. The HTTPS request is made via
`curl`; the request/response handling is built in. Disabled by default.

```jsonc
{
  "ai": {
    "enabled": true,
    "endpoint": "https://api.openai.com/v1/chat/completions",
    "model": "gpt-4o-mini",
    "api_key_env": "OPENAI_API_KEY",
    "max_tokens": 64,
    "timeout_ms": 4000
  }
}
```

```sh
export OPENAI_API_KEY=sk-...
ai find all zig files modified today
# -> find . -name '*.zig' -mtime 0
```

Den prints the suggested command for review; it never auto-executes model
output. Network/parse failures degrade gracefully to a friendly message.

## Distributed shell sessions

Den can act as a session server and client over TCP, reusing the full shell:

```sh
# On the host (binds 127.0.0.1:7878 by default):
den --serve
den --serve 127.0.0.1:9000      # custom address

# From a client:
den --connect 127.0.0.1:9000
```

> **Security:** the server is an *unauthenticated* remote shell. It binds to
> loopback by default and refuses non-loopback addresses unless
> `DEN_ALLOW_REMOTE=1` is set. Never expose it on an untrusted network; tunnel
> over SSH for remote use.

## WebAssembly plugins

Den ships a dependency-free WebAssembly interpreter and can load `.wasm` plugin
modules, calling their exported functions with integer arguments:

```sh
wasm ./plugin.wasm add 17 25     # -> 42
wasm --exports ./plugin.wasm     # list exported functions
```

The interpreter supports the core integer instruction set (i32/i64),
structured control flow (`block`/`loop`/`if`/`br`/`br_if`/`return`), function
calls, and linear-memory load/store. Compile plugins from any
WebAssembly-targeting language (e.g. `zig build-exe -target wasm32-freestanding`,
`clang --target=wasm32`, Rust `wasm32-unknown-unknown`) and export the functions
you want to call.

See [PLUGIN_DEVELOPMENT.md](./PLUGIN_DEVELOPMENT.md) for the native plugin API.

## Language Server

Den ships a Language Server Protocol (LSP) implementation for editor integration —
diagnostics, hover, and completion for shell scripts:

```sh
den --lsp        # serve LSP over stdio
```

Point your editor's LSP client at `den --lsp` for the `shellscript` language to get
in-editor completion and diagnostics backed by Den's own parser and completion
engine. This is the same engine documented in [Tab Completion](./TAB_COMPLETION.md)
and [Autocompletion](./AUTOCOMPLETION.md), exposed over LSP.
