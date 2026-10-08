# Configuration

Den reads a declarative config plus up to three shell scripts:

- **`~/.config/den.jsonc`** — declarative [JSONC](https://www.json.org) (JSON with comments) for the prompt, history, completion, theme, aliases, and keybindings. Read by every shell.
- **`~/.denenv`** — shell script, run by **every** shell: interactive, `den -c`, scripts, and anything invoking `$SHELL -c`. This is where `$PATH` and exported environment variables belong.
- **`~/.denprofile`** — shell script, run only by **login** shells, after `.denenv`.
- **`~/.denrc`** — shell script, run only by **interactive** shells, last. Aliases, keybindings, prompt tweaks, anything that only matters when you are typing at a prompt.

The split matters. `$PATH` set only in `~/.denrc` is invisible to `den -c`, to
scripts, and to every editor, CI job or GUI app that runs `$SHELL -c` — those
shells are not interactive, so `.denrc` never runs for them. Put it in
`~/.denenv` and it applies everywhere. This mirrors zsh, where `$PATH`
conventionally goes in `.zshenv` rather than `.zshrc`, for the same reason.

Coming from zsh, the files line up like this:

| zsh | den | runs for |
|---|---|---|
| `.zshenv` | `~/.denenv` | every shell |
| `.zprofile` | `~/.denprofile` | login shells |
| `.zshrc` | `~/.denrc` | interactive shells |
| `.zlogin` | — | den has one login file, not two |
| `.zlogout` | — | use the `zshexit` hook |

`den import-zsh` copies what it can out of your existing zsh files into these;
see [Migrating from zsh](#migrating-from-zsh) below.

`--norc` skips all three scripts and `den.jsonc`.

A fully-commented example config ships in the repo root: [`den.jsonc`](https://github.com/stacksjs/den/blob/main/den.jsonc).

## File locations

`den.jsonc` is loaded from the first of these that exists:

1. `./den.jsonc` (project-local)
2. `./config/den.jsonc`
3. `./.config/den.jsonc`
4. `~/.config/den.jsonc` (user home)

This lets a project ship its own shell config that overrides your personal one when you `cd` into it.

## The shell scripts

All three are plain shell, sourced top-to-bottom. They run in this order, and
each is optional -- an absent one is the normal case, not an error.

`~/.denenv`, for anything every shell needs:

```bash
export EDITOR="code --wait"
export PATH="$HOME/.local/bin:$PATH"
source "$HOME/.cargo/env"
```

`~/.denprofile`, for login-time setup:

```bash
source "$HOME/.orbstack/shell/init.zsh"
```

`~/.denrc`, for the interactive shell only:

```bash
alias gs="git status"
bindkey '^T' kill-whole-line
source "$HOME/.dotfiles/aliases.sh"
```

Unsure which file something belongs in? Ask whether it needs to work under
`den -c`. If yes, it goes in `~/.denenv`.

## Migrating from zsh

`den import-zsh` reads `~/.zshenv`, `~/.zprofile` and `~/.zshrc` and appends
what it can translate to the matching den file -- aliases, functions, exports
and `source` lines. It prints what it skipped and why, rather than copying lines
that cannot work: zsh's own completion system, `oh-my-zsh`, and anything calling
a zsh builtin den does not implement.

```bash
den import-zsh            # show what would be imported, change nothing
den import-zsh --write    # append it
```

It never overwrites: everything it adds goes at the end of the file, under a
marked block you can delete in one go.

## `den.jsonc` reference

### General

```jsonc
{
  "verbose": false,        // extra diagnostic output
  "stream_output": null    // null = auto
}
```

### Prompt

```jsonc
"prompt": {
  "format": "{symbol} {path}{git}{modules} ",
  "path_style": "full",      // "full" = ~/Documents/Projects/den, "basename" = den
  "git_style": "compact",    // "compact" = git:(main) !32 ?85, "verbose" = on 🌱 main ✓ !32 ?85
  "show_git": true,          // git branch + working-tree status
  "show_time": false,
  "show_user": false,
  "show_host": false,
  "show_path": true,
  "show_exit_code": true,    // colour the prompt symbol red after a failure
  "right_prompt": null,      // optional right-aligned prompt
  "transient": false,        // collapse past prompts to a minimal form
  "simple_when_not_tty": true
}
```

**Placeholders** available in `format`:

- `{path}` — current directory: the home-relative path (`~/Code/den`) with `path_style: "full"`, or just its name (`den`) with `path_style: "basename"`
- `{git}` — branch and working-tree status (when `show_git` is on): ` git:(main)` with `git_style: "compact"`, or ` on 🌱 main` with `git_style: "verbose"`. Both append the counters `+staged !unstaged ?untracked $stashed ↑ahead ↓behind`; verbose adds a green `✓` when the tree is clean, compact stays bare (falling back to a yellow `✗` if the tree is dirty but has no counts)
- `{modules}` — runtime/context modules (e.g. detected tool versions); expands with a leading space, or to nothing when no runtime is detected
- `{symbol}` — the prompt symbol from `theme.symbols.prompt`, with a trailing space; green normally, red after a failed command
- `\n` — a newline

The default keeps what you type on the same line as the prompt. Move it to its own line by putting `{symbol}` after a `\n`:

```jsonc
"format": "{path}{git}{modules} \n{symbol} "
```

See [Themes](./THEMES.md) for a full prompt/styling deep-dive.

### History

```jsonc
"history": {
  "max_entries": 50000,
  "file": "~/.den_history",
  "ignore_duplicates": true,
  "ignore_space": true,       // don't record commands starting with a space
  "search_mode": "fuzzy",     // "fuzzy" | "substring" | "prefix"
  "search_limit": null
}
```

See [History Substring Search](./HISTORY_SUBSTRING_SEARCH.md) for interactive search.

### Completion

```jsonc
"completion": {
  "enabled": true,
  "case_sensitive": false,
  "show_descriptions": true,
  "max_suggestions": 15,
  "cache": {
    "enabled": true,
    "ttl": 3600000,     // ms
    "max_entries": 1000
  }
}
```

See [Tab Completion](./TAB_COMPLETION.md) and [Autocompletion](./AUTOCOMPLETION.md).

### Theme

```jsonc
"theme": {
  "name": "default",
  "auto_detect_color_scheme": true,
  "enable_right_prompt": true,
  "colors": {
    "primary":   "#00D9FF",
    "secondary": "#FF6B9D",
    "success":   "#00FF88",
    "warning":   "#FFD700",
    "err":       "#FF4757",
    "info":      "#74B9FF"
  },
  "symbols": {
    "prompt": "➜",
    "continuation": "…"
  }
}
```

### Expansion

Caps on Den's expansion caches (advanced tuning):

```jsonc
"expansion": {
  "cache_limits": { "arg": 200, "exec": 500, "arithmetic": 500 }
}
```

### Aliases

Aliases can be defined declaratively here, or at runtime with the `alias` builtin.

```jsonc
"aliases": {
  "enabled": true,
  "custom": [
    { "name": "ll", "command": "/bin/ls -lh" },
    { "name": "g",  "command": "git" },
    { "name": "gst","command": "git status" }
  ],
  // Suffix aliases (zsh-style): running "hello.ts" runs "bun hello.ts".
  // Add more at runtime with: alias -s ts='bun'
  "suffix": [
    { "extension": "ts", "command": "bun" },
    { "extension": "py", "command": "python3" }
  ]
}
```

### Keybindings

```jsonc
"keybindings": {
  "mode": "emacs",   // "emacs" | "vi"
  "custom": null
}
```

`mode` chooses the editing style for the interactive line editor. With `"vi"`,
each line starts in insert mode; **Esc** switches to normal mode for navigation
(`h` `l` `0` `$` `^` `w` `b` `e` `x` `dd` `cc` `u` …), and `i` `a` `A` `I` `o`
`s` `S` `C` `R` return to inserting. Every new prompt starts in insert mode
again, as zsh's `viins` does.

`custom` binds keys to named editing widgets, the same way the `bindkey` builtin
does. Each entry takes a `key` in zsh's notation and an `action`:

```jsonc
"keybindings": {
  "mode": "emacs",
  "custom": [
    { "key": "^X^E", "action": "kill-whole-line" },
    { "key": "\\e[1;5C", "action": "forward-word" },
    { "key": "^X^Z", "action": "fg\\n", "string": true },
    { "key": "jj", "action": "vi-cmd-mode", "keymap": "viins" }
  ]
}
```

| Field | Default | Meaning |
|-------|---------|---------|
| `key` | — | Key sequence in `bindkey` notation |
| `action` | — | Widget name, or literal text when `string` is true |
| `keymap` | `"main"` | `main`, `emacs`, `viins`, `vicmd`, `vireplace` or `isearch` |
| `string` | `false` | Treat `action` as literal input rather than a widget name |

Note the double backslash: JSON consumes one level of escaping, so zsh's `\e`
is written `\\e` here. The caret form (`^X`, `^[`) needs no escaping and is
usually easier to read.

Config bindings are applied before `~/.denrc` is sourced, so a `bindkey` in the
rc file wins for the same key. On hot reload they are re-applied additively:
bindings made interactively or in `~/.denrc` survive, so removing one from this
file takes a restart or an explicit `bindkey -r`. A bad entry warns and is
skipped rather than failing startup.

Run `bindkey -L` for every current binding and `bindkey -l` for the keymap
names. See [Line Editing](./LINE_EDITING.md#customizing-keybindings-with-bindkey)
for the full reference.

## See also

- [Themes](./THEMES.md) — prompt and colour customization
- [Features](./FEATURES.md) — what each capability does
- [Quick Reference](./QUICK_REFERENCE.md) — cheat sheet
