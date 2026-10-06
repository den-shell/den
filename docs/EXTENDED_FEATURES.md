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

### `bindkey`

Binds keys to named editing widgets, using zsh's notation, widget names and
keymaps, so lines copied out of a `.zshrc` work as written:

```sh
bindkey '^T' kill-whole-line        # rebind Ctrl+T
bindkey '\e[1;5C' forward-word      # Ctrl+Right
bindkey -s '^X^Z' 'fg\n'            # literal input, dispatched as if typed
bindkey -M vicmd 'H' beginning-of-line
bindkey -L                          # dump as re-runnable bindkey commands
```

Keymaps are `emacs`, `viins`, `vicmd`, `vireplace`, `isearch` and `main`.
`bindkey -e`/`-v` pick the editing mode, which `keybindings.mode` also sets.

Two deliberate divergences: `\M-x` binds the ESC prefix rather than setting the
high bit, matching what terminals actually send for Option; and key sequences are
capped at 8 bytes, with longer specs rejected rather than truncated.

A shell function can be a widget, as in zsh:

```sh
insert-date() { LBUFFER="$LBUFFER$(date +%F)" }
zle -N insert-date
bindkey '^X^D' insert-date
```

The function reads and writes the line through `$BUFFER`, `$CURSOR`, `$LBUFFER`
and `$RBUFFER`. See [Line Editing](./LINE_EDITING.md#customizing-keybindings-with-bindkey)
for the full option and widget reference.

### `zstyle`

Zsh's pattern-keyed style database. Styles are set against a context pattern and
read back by the most specific pattern that matches, so a `.zshrc` completion
block is accepted as written instead of failing line by line:

```sh
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'
zstyle ':completion:*:*:git:*' verbose yes
zstyle -L                           # dump as re-runnable zstyle commands
```

The query forms are there too, which is what makes a function that configures
itself through styles work rather than silently seeing nothing:

| Form | Meaning |
|---|---|
| `-t ctx style [val...]` | true if set and true, or one of the given values |
| `-T ctx style` | as `-t`, but an unset style is true |
| `-b ctx style var` | `yes`/`no` into `var` |
| `-s ctx style var` | the values, joined, into `var` |
| `-a ctx style var` | the values into `var` |
| `-m ctx style pattern` | true if a value matches the pattern |
| `-g var [pattern [style]]` | collect patterns, style names, or values |
| `-d [pattern [style...]]` | delete |

Be aware of what this does and does not do. Styles are stored, matched and
readable, and `zstyle` itself behaves as zsh's does — but **den's completion
engine does not consult them.** Setting `menu select` or `verbose yes` changes
nothing; the behaviour they ask for is configured under the `completion` section
of `den.jsonc`. The one exception is `matcher-list`: a case-folding spec such as
`m:{a-z}={A-Z}` turns completion's case sensitivity off, taking effect on the
next completion. The styles are kept so that migration is not lossy and so a
function can read its own configuration, not because each one is honoured.

Two further limits: `-e` is refused rather than accepted, because a style holds
values and not code to be evaluated on each lookup; and `-a`/`-g` join their
values with spaces, since den has no array assignment from a builtin.

### Startup: `autoload`, `compinit` and hooks

The lines at the top of a `.zshrc`, above anything interesting. These used to be
a wall of `command not found` before the `setopt`, `bindkey` and `zstyle` lines
den does implement:

```sh
autoload -Uz compinit && compinit
autoload -Uz bashcompinit && bashcompinit
zmodload zsh/complist
emulate -L zsh
is-at-least 5.1 && setopt extendedglob
compdef _git g
```

Most of these are setup for machinery den does not have, and the honest answer is
that no setup is needed rather than that the command is missing: completion is
always on, there are no loadable modules, and there is one set of semantics. So
they succeed and do nothing, silently -- they run while an rc file is sourced, so
a note per line would print on every shell start.

Where that is not true, they say so:

| Command | Behaviour |
|---|---|
| `compinit`, `bashcompinit`, `compdef` | Succeed; completion needs no setup |
| `zmodload` | Succeeds; `-e` reports no module is loaded |
| `emulate sh`/`ksh`/`zsh` | Succeeds; `csh` is refused |
| `is-at-least a b` | Real comparison, numeric per component |
| `is-at-least a` | False: den reports itself as den, not a zsh version |

#### `autoload`

Marks a name to be defined from `$fpath` on first use, and is the only thing that
gives `fpath` a meaning -- den accepted the array but nothing read it.

```sh
fpath=(/usr/local/share/den/functions $fpath)
autoload -Uz my_helper      # not read yet
my_helper arg               # read and defined now
```

Lazy, as zsh is: the file is read on the first call, so a config can autoload
dozens of names and pay for none at startup. The file holds a function *body*,
not a `name() { ... }` wrapper, which is zsh's convention. Both the `fpath` array
and `FPATH` are searched. A missing definition file is reported as zsh words it,
with status 1 rather than 127 -- the name was known, the search path is wrong.

One deliberate divergence: a name den already provides is not marked. zsh's
placeholder shadows even a builtin, so `autoload -Uz echo` breaks `echo` there,
while the names configs actually autoload -- `compinit`, `add-zsh-hook`,
`bashcompinit`, `is-at-least` -- are builtins here. Not shadowing them is what
makes `autoload -Uz compinit; compinit` work.

**Known limitation.** Array assignment does not expand its elements yet, so
`fpath=(~/funcs $fpath)` stores the literal `~/funcs`. Until that is fixed, use a
literal path in the array, or `FPATH`, which is a scalar and does expand:

```sh
export FPATH=$HOME/funcs    # works today
fpath=(/home/you/funcs)     # works today
fpath=(~/funcs)             # does NOT expand yet
```

#### Hooks

Den runs `chpwd`, `precmd`, `preexec` and `zshexit`, each as a bare function and
as a `<name>_functions` array, and `add-zsh-hook` registers on them:

```sh
timer_start() { TIMER=$SECONDS }
add-zsh-hook preexec timer_start
add-zsh-hook -L precmd        # list, as a re-runnable declaration
add-zsh-hook -d precmd fn     # remove one
add-zsh-hook -D precmd 'f*'   # remove by pattern
```

`preexec` fires after history expansion, so it sees the line that will actually
run rather than the `!!` that was typed, and is handed that line as `$1`. zsh also
passes a size-limited and a full form; den has no distinct forms here, so all
three arguments carry the same text. `zshexit` runs after the bash-style `EXIT`
trap rather than instead of it.

`periodic`, `zshaddhistory` and `zsh_directory_name` are refused rather than
accepted as zsh does: den fires none of them, so a function registered there
would silently never run.

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
