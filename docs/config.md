# Configuration

Den is configured by two files:

- **`~/.denrc`** — a shell script sourced at startup (like `.zshrc`). Use it for environment variables, `$PATH`, runtime aliases, and any commands you want to run when a shell starts.
- **`~/.config/den.jsonc`** — declarative [JSONC](https://www.json.org) (JSON with comments) for the prompt, history, completion, theme, aliases, and keybindings.

A fully-commented example config ships in the repo root: [`den.jsonc`](https://github.com/stacksjs/den/blob/main/den.jsonc).

## File locations

`den.jsonc` is loaded from the first of these that exists:

1. `./den.jsonc` (project-local)
2. `./config/den.jsonc`
3. `./.config/den.jsonc`
4. `~/.config/den.jsonc` (user home)

This lets a project ship its own shell config that overrides your personal one when you `cd` into it.

## `~/.denrc`

`~/.denrc` is plain shell, sourced top-to-bottom at startup:

```bash
# Environment + PATH
export EDITOR="code --wait"
export PATH="$HOME/.local/bin:$PATH"

# Source shared files (works in den and other shells)
source "$HOME/.dotfiles/env.sh"
source "$HOME/.dotfiles/aliases.sh"
```

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
  "format": "{path}{git} {modules} \n{symbol} ",
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

- `{path}` — current directory, home-relative (`~/Code`)
- `{git}` — branch and working-tree status (when `show_git` is on)
- `{modules}` — runtime/context modules (e.g. detected tool versions)
- `{symbol}` — the prompt symbol from `theme.symbols.prompt`
- `\n` — a newline (for a two-line prompt)

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
    "prompt": "❯",
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

See [Line Editing](./LINE_EDITING.md) for the full keymap.

## See also

- [Themes](./THEMES.md) — prompt and colour customization
- [Features](./FEATURES.md) — what each capability does
- [Quick Reference](./QUICK_REFERENCE.md) — cheat sheet
