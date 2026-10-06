# Migration Guide

This guide helps users migrate to Den Shell from other shells (Bash, Zsh, Fish) and covers the transition from the TypeScript version to the Zig implementation.

## Table of Contents

- [From Bash](#from-bash)
- [From Zsh](#from-zsh)
- [From Fish](#from-fish)
- [TypeScript to Zig Migration](#typescript-to-zig-migration)
- [Configuration Migration](#configuration-migration)
- [Feature Parity](#feature-parity)
- [Common Issues](#common-issues)

---

## From Bash

### Compatibility

Den is highly compatible with Bash. Most Bash scripts will work without modification.

### Supported Features

| Feature | Status | Notes |
|---------|--------|-------|
| Variables (`$VAR`, `${VAR}`) | ✅ Full | All parameter expansion forms |
| Command substitution | ✅ Full | `$(cmd)` and backticks |
| Arithmetic | ✅ Full | `$((expr))` with all operators |
| Brace expansion | ✅ Full | `{a,b}`, `{1..10}`, `{01..10}` |
| Glob patterns | ✅ Full | `*`, `?`, `[...]`, `**` |
| Pipelines | ✅ Full | Multi-stage pipes |
| Redirections | ✅ Full | `>`, `>>`, `<`, `2>`, `&>`, heredoc |
| Control flow | ✅ Full | if, for, while, until, case, select |
| Functions | ✅ Full | Both syntaxes |
| Job control | ✅ Full | bg, fg, jobs, disown |
| Arrays | ✅ Full | Indexed and associative arrays |
| Associative arrays | ✅ Full | declare -A supported |
| `shopt` options | ✅ Full | 30+ options supported |

### Configuration Migration

**Bash (~/.bashrc):**
```bash
# Aliases
alias ll='ls -la'
alias gs='git status'

# Environment
export EDITOR=vim
export PATH="$HOME/bin:$PATH"

# Prompt
PS1='\u@\h:\w\$ '
```

**Den (~/.config/den/den.jsonc):**
```jsonc
{
  "aliases": {
    "ll": "ls -la",
    "gs": "git status"
  },
  "environment": {
    "EDITOR": "vim"
  },
  "path": {
    "prepend": ["~/bin"]
  },
  "prompt": {
    "format": "{user}@{host}:{cwd}$ "
  }
}
```

### Script Compatibility

Most Bash scripts work directly:

```bash
# !/usr/bin/env den
# or
# !/path/to/den

# Standard Bash syntax works
for file in *.txt; do
    echo "Processing $file"
done
```

### Known Differences

1. **Process substitution paths**: Den uses `/dev/fd/N` (like Linux), not named pipes
2. **Some `shopt` options**: Not all Bash-specific options are implemented
3. **Completion scripts**: Bash completion scripts need adaptation

---

## From Zsh

### Compatibility

Den supports many Zsh features but uses different configuration.

### Supported Features

| Feature | Status | Notes |
|---------|--------|-------|
| Extended globs | ✅ Full | `**`, negation patterns |
| Parameter expansion | ✅ Full | All forms |
| Prompt customization | ✅ Full | Different syntax |
| Completion | ✅ Full | Built-in system |
| History | ✅ Full | Search, expansion |
| Line editing | ✅ Full | Emacs mode |
| Themes | ✅ Full | JSON-based |

### Configuration Migration

**Zsh (~/.zshrc):**
```zsh
# Plugins (Oh My Zsh style)
plugins=(git docker kubectl)

# Aliases
alias -g L='| less'
alias -s txt=vim

# Prompt
PROMPT='%n@%m:%~%# '

# Completion
autoload -Uz compinit && compinit
```

**Den (~/.config/den/den.jsonc):**
```jsonc
{
  // Den has built-in completion for git, docker, kubectl
  "completion": {
    "enabled": true,
    "git": true,
    "docker": true,
    "kubectl": true
  },
  "aliases": {
    // Global aliases not supported, use functions instead
  },
  "prompt": {
    "format": "{user}@{host}:{cwd}$ ",
    "git": {
      "enabled": true,
      "show_branch": true
    }
  }
}
```

### Feature Differences

1. **Global aliases (`-g`)**: Not supported; use functions
2. **Suffix aliases (`-s`)**: Not supported
3. **Prompt escapes**: Different syntax (`{user}` vs `%n`)
4. **Plugin system**: Different architecture

### Migrating Oh My Zsh

Den has built-in equivalents for common Oh My Zsh plugins:

| Oh My Zsh Plugin | Den Equivalent |
|------------------|----------------|
| git | Built-in git completion and prompt |
| docker | Built-in docker completion |
| kubectl | Built-in kubectl completion |
| colored-man-pages | Built-in syntax highlighting |
| history-substring-search | Built-in (Ctrl+R) |
| autosuggestions | Built-in inline suggestions |

---

## From Fish

### Compatibility

Fish has a different syntax, so scripts need modification.

### Syntax Differences

**Fish:**
```fish
# Variables
set myvar "value"
set -x PATH ~/bin $PATH

# Functions
function greet
    echo "Hello, $argv[1]"
end

# Conditionals
if test -f file.txt
    echo "exists"
end

# Loops
for file in *.txt
    echo $file
end
```

**Den:**
```bash
# Variables
myvar="value"
export PATH="$HOME/bin:$PATH"

# Functions
greet() {
    echo "Hello, $1"
}

# Conditionals
if [ -f file.txt ]; then
    echo "exists"
fi

# Loops
for file in *.txt; do
    echo "$file"
done
```

### Configuration Migration

**Fish (~/.config/fish/config.fish):**
```fish
set -x EDITOR vim
alias ll 'ls -la'

function fish_prompt
    echo (whoami)'@'(hostname)':'(pwd)'$ '
end
```

**Den (~/.config/den/den.jsonc):**
```jsonc
{
  "environment": {
    "EDITOR": "vim"
  },
  "aliases": {
    "ll": "ls -la"
  },
  "prompt": {
    "format": "{user}@{host}:{cwd}$ "
  }
}
```

### Feature Mapping

| Fish Feature | Den Equivalent |
|--------------|----------------|
| `set` | `export`, `VAR=value` |
| `set -x` | `export` |
| `function` | `function name { }` or `name() { }` |
| `$argv` | `$@`, `$1`, `$2`, etc. |
| `test` | `test`, `[ ]`, `[[ ]]` |
| Abbreviations | Aliases |
| Universal variables | Environment + config |

---

## TypeScript to Zig Migration

If you were using the TypeScript version of Den, here's what changed.

### Breaking Changes

1. **Binary name**: Still `den`, but now a native binary
2. **Configuration format**: Now uses JSONC (JSON with comments)
3. **Plugin API**: Completely redesigned
4. **Some command flags**: Minor differences in some builtins

### Configuration Changes

**Old (TypeScript) config:**
```typescript
// den.config.ts
export default {
  aliases: {
    ll: 'ls -la'
  },
  plugins: ['my-plugin']
}
```

**New (Zig) config:**
```jsonc
// den.jsonc
{
  "aliases": {
    "ll": "ls -la"
  },
  "plugins": {
    "enabled": true,
    "list": ["my-plugin"]
  }
}
```

### Performance Improvements

The Zig version offers significant performance improvements:

| Metric | TypeScript | Zig | Improvement |
|--------|------------|-----|-------------|
| Startup time | ~150ms | ~5ms | 30x faster |
| Memory usage | ~50MB | ~2MB | 25x less |
| Command latency | ~10ms | ~0.1ms | 100x faster |
| Binary size | ~50MB (with Node) | ~2MB | 25x smaller |

### Migration Steps

1. **Install the Zig version**:

   ```bash
# Build from source
   git clone https://github.com/anthropics/den.git
   cd den
   zig build -Doptimize=ReleaseFast
   sudo cp zig-out/bin/den /usr/local/bin/
   ```

2. **Convert configuration**:

   ```bash
# Move old config
   mv ~/.config/den/config.ts ~/.config/den/config.ts.bak

# Create new config
   touch ~/.config/den/den.jsonc
   ```

3. **Migrate settings** from TypeScript to JSONC format

4. **Update plugins**: TypeScript plugins need to be rewritten

5. **Test your workflow**: Run common commands to verify

---

## Configuration Migration

### Automatic Migration Tool

Create a script to help migrate your configuration:

```bash
# !/usr/bin/env bash
# migrate-config.sh

OLD_CONFIG="$HOME/.bashrc"
NEW_CONFIG="$HOME/.config/den/den.jsonc"

# Extract aliases from bashrc
echo '{'
echo '  "aliases": {'

grep "^alias " "$OLD_CONFIG" | while read -r line; do
    name=$(echo "$line" | sed 's/alias \([^=]_\)=._/\1/')
    value=$(echo "$line" | sed "s/alias [^=]_='\(._\)'/\1/" | sed 's/alias [^=]_="\(._\)"/\1/')
    echo "    \"$name\": \"$value\","
done

echo '  }'
echo '}'
```

### Manual Migration Checklist

- [ ] Aliases converted to JSON format
- [ ] Environment variables in config or shell profile
- [ ] PATH modifications in config
- [ ] Prompt customization converted
- [ ] Completion settings configured
- [ ] History settings migrated
- [ ] Keybindings verified

---

## Feature Parity

### Fully Implemented

- ✅ All POSIX shell features
- ✅ Bash-compatible syntax
- ✅ Variable expansion (all forms)
- ✅ Command substitution
- ✅ Arithmetic expansion
- ✅ Brace expansion
- ✅ Glob expansion (including `**`)
- ✅ Tilde expansion
- ✅ History expansion
- ✅ Pipelines and redirections
- ✅ Job control
- ✅ Control flow (if, for, while, until, case, select)
- ✅ Functions with local variables
- ✅ Traps and signal handling
- ✅ Tab completion (files, commands, context-aware)
- ✅ Syntax highlighting
- ✅ Line editing (Emacs mode)
- ✅ Reverse history search

### Partially Implemented

- ⚠️ Bash completion scripts: Native completion preferred

### Implemented

- ✅ Arrays: Both indexed arrays and associative arrays (declare -A)
- ✅ Network redirections (`/dev/tcp`, `/dev/udp`) with IPv4 and IPv6 support
- ✅ `shopt` options: 30+ options including extglob, globstar, autocd, cdspell, etc.
- ✅ Vi editing mode: Normal, insert, and replace modes with navigation keys (h,j,k,l,w,b,e,0,$)
- ✅ Coprocesses: `coproc [NAME] command` with bidirectional pipes
- ✅ Loadable builtins: `enable -f <library.so> <name>` with dlopen support

### Den-Specific Features

Features unique to Den:

- 🆕 JSONC configuration
- 🆕 Built-in JSON processing
- 🆕 Built-in HTTP client
- 🆕 Built-in calculator with functions
- 🆕 Inline suggestions
- 🆕 Typo correction
- 🆕 Context-aware completion (git, docker, kubectl, npm)
- 🆕 Hot-reload configuration
- 🆕 Extended builtins (tree, watch, parallel, etc.)

---

## Common Issues

### "Command not found" for aliases

**Problem**: Aliases defined in config aren't working.

**Solution**: Check config syntax:
```jsonc
{
  "aliases": {
    "ll": "ls -la"  // No trailing comma on last item
  }
}
```

### Scripts fail with syntax error

**Problem**: Bash script fails in Den.

**Solution**: Check for Bash-specific features:
```bash
# May need adjustment
declare -A assoc_array  # Associative arrays not yet supported

# Use instead
# (workaround with regular variables)
```

### Completion not working

**Problem**: Tab completion doesn't work.

**Solution**: Ensure completion is enabled:
```jsonc
{
  "completion": {
    "enabled": true
  }
}
```

### History not persisting

**Problem**: Command history is lost between sessions.

**Solution**: Check history configuration:
```jsonc
{
  "history": {
    "enabled": true,
    "file": "~/.config/den/history",
    "max_size": 10000
  }
}
```

### Colors not displaying

**Problem**: No colors in output.

**Solution**: Check terminal and config:
```jsonc
{
  "colors": true,
  "syntax_highlighting": true
}
```

Verify terminal supports colors:
```bash
echo $TERM  # Should be xterm-256color or similar
```

### Slow startup

**Problem**: Shell takes time to start.

**Solution**:

1. Check config file size
2. Disable unused features
3. Use release build

```bash
# Build optimized version
zig build -Doptimize=ReleaseFast
```

---

## Getting Help

- **Documentation**: See [docs/](./README.md)
- **Troubleshooting**: See [TROUBLESHOOTING.md](./TROUBLESHOOTING.md)
- **Issues**: Report at <https://github.com/anthropics/den/issues>
- **Discussions**: Ask questions in GitHub Discussions

---

## Intentionally Unsupported Features

Some features from Bash/Zsh are intentionally not supported in Den to keep the implementation minimal, predictable, and secure.

### From Bash

| Feature | Reason |
|---------|--------|
| `eval` | Security risk; use functions or command substitution instead |
| `source` from network | Security risk; only local files supported |
| Bash-specific `[[` extensions | Some regex features differ; use standard test or grep |
| `compgen`/`complete` bash API | Den uses native completion; different architecture |
| `PROMPT_COMMAND` | Use Den's prompt config instead |

### From Zsh

| Feature | Reason |
|---------|--------|
| Global aliases (`-g`) | Confusing behavior; use functions |
| Suffix aliases (`-s`) | Available in config as `aliases.suffix` |
| `zparseopts` | Use standard `getopts` or manual parsing |
| `zle -N` user widgets | Not implemented; `bindkey` binds the built-in widgets |
| `zmodload` | Den uses plugin system |
| `precmd`/`preexec` hooks | Use config-based hooks |

### From Fish

| Feature | Reason |
|---------|--------|
| Fish syntax | Den uses POSIX/Bash syntax for compatibility |
| Universal variables | Use environment + config instead |
| Abbreviations | Use aliases (similar functionality) |
| `string` builtin | Use standard shell tools or Den builtins |
| Event handlers | Use trap or config hooks |

### Design Philosophy

Den prioritizes:

1. **POSIX compatibility**: Scripts should be portable
2. **Predictable behavior**: No magic or implicit behavior
3. **Security**: No features that commonly lead to vulnerabilities
4. **Simplicity**: Features must justify their complexity cost
5. **Performance**: Features shouldn't impact startup or runtime

If you need an unsupported feature, consider:

- Writing a function that achieves the same goal
- Using a Den plugin
- Using standard Unix tools in combination

---

## Zsh Power User Quick Reference

Quick mapping for common Zsh workflows:

### Prompt

| Zsh | Den |
|-----|-----|
| `%n` | `{user}` |
| `%m` | `{host}` |
| `%~` | `{cwd}` or `{path}` |
| `%#` | `{symbol}` |
| `%?` | `{exit_code}` |
| `%(?..)` | Use `show_exit_code` option |

### Keybindings

`bindkey` works as written, with zsh's key notation, widget names and keymaps.
See [Line Editing](./LINE_EDITING.md#customizing-keybindings-with-bindkey).

| Zsh | Den |
|-----|-----|
| `bindkey '^R' history-incremental-search-backward` | Works as written |
| `bindkey '^[[A' up-line-or-history` | Works as written |
| `bindkey '^A' beginning-of-line` | Works as written |
| `bindkey -s '^X^Z' 'fg\n'` | Works as written |
| `bindkey -e` / `-v` / `-a` / `-M vicmd` | Works as written |
| `bindkey -l` / `-L` / `-r` / `-d` | Works as written |
| `bindkey -A` / `-N` / `-D` | Rejected: den has a fixed set of keymaps |
| `bindkey -m` | Rejected: den decodes Meta as an ESC prefix, so bind `\e<key>` |
| `bindkey -p` / `-R` | Rejected: use `bindkey -L` and filter, or bind keys individually |
| `zle -N my-widget my-func` | Works as written; `$BUFFER`, `$CURSOR`, `$LBUFFER`, `$RBUFFER` |

Two deliberate differences. `\M-x` binds the ESC prefix (`ESC x`) rather than
setting the high bit, which is what a terminal actually sends for Option/Alt;
and `history-incremental-search-forward` is accepted but mapped to den's Ctrl+S,
which toggles fuzzy matching inside the reverse search rather than searching
forward.

### Completion

| Zsh | Den |
|-----|-----|
| `compinit` | Accepted; completion needs no setup |
| `_git`, `_docker` | Built-in context-aware completion |
| `zstyle ':completion:*'` | Runs as written; see below |
| `fpath+=` | Use `plugins` config |

#### Startup lines

| Zsh | Den |
|-----|-----|
| `autoload -Uz name` | Works; defines from `$fpath` on first use |
| `compinit`, `bashcompinit` | Accepted; nothing to set up |
| `compdef _git g` | Accepted; completion is context-aware already |
| `zmodload zsh/complist` | Accepted; no loadable modules |
| `emulate -L zsh` | Accepted (`csh` is refused) |
| `is-at-least 5.1` | Works with two operands; false with one |
| `add-zsh-hook precmd fn` | Works; `chpwd`, `precmd`, `preexec`, `zshexit` |

Note that array assignment does not expand its elements yet, so a `fpath` array
written with `~` stores the tilde literally. Use a literal path, or `FPATH`,
which is a scalar and does expand. See
[Extended Features](./EXTENDED_FEATURES.md#startup-autoload-compinit-and-hooks).

#### `zstyle`

`zstyle` exists, with the same context patterns, specificity ordering and query
forms (`-t`, `-s`, `-b`, `-a`, `-g`, `-m`, `-d`, `-L`) as zsh, so a completion
block copied out of a `.zshrc` is accepted and a function that reads its own
configuration through `zstyle -s` sees it.

What it does not do is drive completion. Styles are stored and readable, but
den's completion engine does not consult them, so `menu select`, `verbose yes`
and `list-max` change nothing on their own — configure that behaviour in the
`completion` section of `den.jsonc`. The one style that has an effect is
`matcher-list`: a case-folding spec turns case sensitivity off.

```sh
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'   # case-insensitive
```

`zstyle -e` is refused rather than silently stored, since the store holds values
and not code to evaluate on each lookup.

### History

| Zsh | Den |
|-----|-----|
| `HISTSIZE`, `SAVEHIST` | `history.max_entries` |
| `HISTFILE` | `history.file` |
| `setopt SHARE_HISTORY` | Default behavior |
| `setopt HIST_IGNORE_DUPS` | `history.ignore_duplicates` |
| `setopt HIST_IGNORE_SPACE` | `history.ignore_space` |

---

## Fish Power User Quick Reference

Quick mapping for common Fish workflows:

### Variables

| Fish | Den |
|------|-----|
| `set var value` | `var=value` |
| `set -x var value` | `export var=value` |
| `set -e var` | `unset var` |
| `set -g var` | `export var` (in init) |
| `set -U var` | Use config `environment` |

### Functions

| Fish | Den |
|------|-----|
| `function name; ...; end` | `name() { ...; }` |
| `$argv` | `$@`, `$1`, `$2`, ... |
| `$argv[1]` | `$1` |
| `count $argv` | `$#` |

### Control Flow

| Fish | Den |
|------|-----|
| `if; ...; end` | `if ...; then ...; fi` |
| `for x in ...; ...; end` | `for x in ...; do ...; done` |
| `while; ...; end` | `while ...; do ...; done` |
| `switch/case` | `case ... in ...) ;; esac` |
| `and`, `or` | `&&`, `||` |

### Prompt

| Fish | Den |
|------|-----|
| `fish_prompt` function | `prompt.format` config |
| `fish_right_prompt` | `prompt.right_prompt` config |
| `set_color` | Use theme colors |
| `fish_git_prompt` | `{git}` in prompt format |

### Autosuggestions

Fish's autosuggestions are built into Den:

- Suggestions appear inline (dimmed)
- Press Right Arrow or End to accept
- Configure in `completion` section

---

## See Also

- [Configuration Guide](./config.md)
- [Builtin Commands](./BUILTINS.md)
- [Scripting Guide](./SCRIPTING.md)
- [Troubleshooting](./TROUBLESHOOTING.md)
