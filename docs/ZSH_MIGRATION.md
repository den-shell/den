# Den for Zsh Users

A comprehensive guide for Zsh users transitioning to Den shell. This guide maps common Zsh features to their Den equivalents.

## Quick Start

Den is designed to be familiar to Zsh users while offering better performance. Most Zsh scripts will work with minimal modifications.

```bash
# Your .zshrc aliases work in Den
alias ll='ls -la'
alias gs='git status'

# Your scripts work too
./my_script.sh
```

## Feature Comparison

| Feature | Zsh | Den | Notes |
|---------|-----|-----|-------|
| Startup time | ~40ms | ~5ms | 8x faster |
| Memory usage | ~20MB | ~2MB | 10x less |
| Configuration | `.zshrc` | `den.jsonc` | JSON + shell scripts |
| Scripting | Zsh/POSIX | Full POSIX | Bash-compatible |
| Plugins | Oh-My-Zsh, etc. | Native support | Hot-reload |
| Completion | zstyle-based | Built-in, context-aware | No setup; `zstyle` accepted |

## Syntax Compatibility

### Variables

```bash
# Standard variables - identical
NAME="Den"
echo $NAME
echo ${NAME}

# Default values - identical to Zsh/Bash
${VAR:-default}
${VAR:=default}
${VAR:?error message}
${VAR:+alternative}

# String operations - identical
${VAR#pattern}      # Remove shortest prefix
${VAR##pattern}     # Remove longest prefix
${VAR%pattern}      # Remove shortest suffix
${VAR%%pattern}     # Remove longest suffix
${VAR/old/new}      # Replace first match
${VAR//old/new}     # Replace all matches
${#VAR}             # String length
${VAR:offset:len}   # Substring
```

### Zsh-specific Variable Features

| Zsh Feature | Status | Den Equivalent |
|-------------|--------|----------------|
| `${(L)VAR}` lowercase | Not supported | Use `tr` or external tool |
| `${(U)VAR}` uppercase | Not supported | Use `tr` or external tool |
| `${(C)VAR}` capitalize | Not supported | Use external tool |
| `${VAR:l}` lowercase | Not supported | Use `tr` |
| `${VAR:u}` uppercase | Not supported | Use `tr` |
| `${(s:/:)VAR}` split | Not supported | Use `IFS` splitting |
| `${(j:/:)arr}` join | Not supported | Use loop or `printf` |

### Arrays

```bash
# Indexed arrays - slightly different indexing
arr=(one two three)
echo ${arr[0]}      # Den/Bash use 0-based indexing
echo ${arr[@]}      # All elements
echo ${#arr[@]}     # Array length

# Note: Zsh uses 1-based indexing by default
# In Zsh: arr[1] is first element
# In Den: arr[0] is first element

# Associative arrays - identical
declare -A map
map[key]=value
echo ${map[key]}
echo ${!map[@]}     # All keys (Zsh uses ${(k)map})
```

### Zsh Array Features

| Zsh Feature | Den Equivalent |
|-------------|----------------|
| `arr[1]` (1-based) | `arr[0]` (0-based) |
| `${(k)map[@]}` keys | `${!map[@]}` |
| `${(v)map[@]}` values | `${map[@]}` |
| `${arr[(i)value]}` index | Loop search |
| `${arr[-1]}` last | `${arr[@]: -1}` |

### Control Flow

```bash
# If statements - identical
if [ condition ]; then
    echo "true"
elif [ other ]; then
    echo "other"
else
    echo "false"
fi

# For loops - identical
for i in 1 2 3; do
    echo $i
done

for file in _.txt; do
    cat "$file"
done

# While/Until - identical
while [ condition ]; do
    echo "loop"
done

# Case statements - identical
case "$var" in
    pattern1) echo "matched 1" ;;
    pattern2) echo "matched 2" ;;
    _) echo "default" ;;
esac
```

### Zsh-specific Control Flow

| Zsh Feature | Status | Den Equivalent |
|-------------|--------|----------------|
| `foreach` | Not supported | Use `for` |
| `repeat N` | Not supported | Use `for i in {1..N}` |
| `select` | Supported | Same syntax |

### Functions

```bash
# Function definition - identical
greet() {
    local name="$1"
    echo "Hello, $name"
}

# Call function
greet "World"

# Return values
add() {
    return $(($1 + $2))
}
```

## Globbing

### Standard Globs

```bash
# These work identically
_.txt           # Match .txt files
file?.txt       # Match single character
[abc].txt       # Match character class
```

### Extended Globbing

```bash
# Enable extended glob (Zsh: setopt EXTENDED_GLOB)
shopt -s extglob

# Extended patterns
_(pattern)      # Zero or more
+(pattern)      # One or more
?(pattern)      # Zero or one
@(pattern)      # Exactly one
!(pattern)      # Not matching
```

### Zsh-specific Globs

| Zsh Glob | Status | Alternative |
|----------|--------|-------------|
| `**/_.txt` | Supported | Use `shopt -s globstar` |
| `_(.)` files only | Not supported | Use `find` |
| `_(/)` dirs only | Not supported | Use `find -type d` |
| `_(@)` symlinks | Not supported | Use `find -type l` |
| `^pattern` negation | Not supported | Use `!(pattern)` |
| `(#i)` case-insensitive | Not supported | Use `find -iname` |
| `<1-10>` numeric range | Not supported | Use brace expansion |

## Key Differences

### 1. Configuration File

**Zsh:**
```bash
# ~/.zshrc
export PATH="$HOME/bin:$PATH"
alias ll='ls -la'
PROMPT='%n@%m:%~%# '
```

**Den:**
```jsonc
// ~/.config/den/den.jsonc
{
  "prompt": {
    "format": "{user}@{host}:{cwd}$ "
  },
  "aliases": {
    "ll": "ls -la"
  },
  "environment": {
    "PATH": "$HOME/bin:$PATH"
  }
}
```

You can also use shell scripts with Den. It reads three, matching zsh's:
`~/.denenv` for every shell, `~/.denprofile` for login shells, and `~/.denrc`
for interactive ones. `$PATH` and exported variables belong in `~/.denenv` --
in `~/.denrc` they would not reach `den -c`, scripts, or anything running
`$SHELL -c`, exactly as `.zshrc` would not in zsh.

### 2. Prompt Customization

**Zsh:** Uses `%` escape codes like `%n`, `%m`, `%~`

**Den:** Uses placeholders like `{user}`, `{host}`, `{cwd}`

| Zsh | Den |
|-----|-----|
| `%n` | `{user}` |
| `%m` | `{host}` |
| `%~` | `{cwd}` |
| `%/` | `{cwd_full}` |
| `%#` | `{prompt_char}` |

```jsonc
// den.jsonc
{
  "prompt": {
    "format": "{user}@{host}:{cwd}{git_branch}$ ",
    "git": {
      "enabled": true,
      "format": " ({branch})"
    }
  }
}
```

### 3. Completion System

**Zsh:** Uses `compinit`, `zstyle`, complex completion system

**Den:** Accepts all of it; completion itself needs no setup

**Den:** Context-aware completion with no setup, plus Bash-compatible
`complete` commands

```bash
# Zsh style
zstyle ':completion:*' menu select
compinit

# Den style (Bash-compatible)
complete -F _git_complete git
```

`zstyle` itself is implemented, so the lines above are accepted rather than
reported as unknown commands, and `zstyle -s`/`-t` read styles back. But den's
completion engine does not consult them: `menu select` changes nothing, and that
behaviour belongs in the `completion` section of `den.jsonc`. The exception is
`matcher-list`, where a case-folding spec turns case sensitivity off. See
[Extended Features](./EXTENDED_FEATURES.md#zstyle).

### 4. History

**Zsh:**
```bash
history           # Show history
!42               # Execute command 42
!!                # Repeat last command
fc -l             # List history
```

**Den:** Same features plus fuzzy search:
```bash
# Fuzzy search with Ctrl+R
# Toggle between substring and fuzzy match with Ctrl+S
```

### 5. Options

**Zsh uses setopt/unsetopt:**
```bash
setopt AUTO_CD
setopt CORRECT
unsetopt BEEP
```

**Den uses set/shopt (Bash-compatible):**
```bash
shopt -s autocd
shopt -s cdspell
set +o beep
```

| Zsh Option | Den Equivalent |
|------------|----------------|
| `AUTO_CD` | `shopt -s autocd` |
| `CORRECT` | `shopt -s cdspell` |
| `EXTENDED_GLOB` | `shopt -s extglob` |
| `NULL_GLOB` | `shopt -s nullglob` |
| `GLOB_DOTS` | `shopt -s dotglob` |
| `GLOB_STAR` | `shopt -s globstar` |

## Oh-My-Zsh Migration

If you're using Oh-My-Zsh, here's how to migrate common features:

### Plugins

| Oh-My-Zsh Plugin | Den Alternative |
|------------------|-----------------|
| git | Git aliases in `den.jsonc` |
| autojump/z | Built-in directory history |
| syntax-highlighting | Native syntax highlighting |
| autosuggestions | Native autosuggestions |
| colored-man-pages | Set MANPAGER in environment |

### Theme

Convert your Zsh theme to Den prompt format:

```jsonc
// Example: agnoster-like prompt
{
  "prompt": {
    "format": "{user}@{host} {cwd} {git_branch}{prompt_char} ",
    "git": {
      "enabled": true,
      "format": "({branch}{status})",
      "dirty": "_",
      "clean": ""
    }
  }
}
```

## Migration Checklist

### 1. Import Your Zsh Config

```bash
den import-zsh            # show what would be imported, change nothing
den import-zsh --write    # append it
```

This reads `~/.zshenv`, `~/.zprofile` and `~/.zshrc` and copies what it can into
the matching den file, keeping multi-line functions, `case` blocks and aliases
whose value spans lines intact. It prints every line it skips with the reason --
oh-my-zsh, zsh's completion system, sourced zsh completion functions -- rather
than copying lines that cannot run under Den.

It appends inside a marked block, so nothing you have already written is
overwritten and the whole import can be removed in one edit.

Two things to check afterwards:

- Exports that came from `~/.zshrc` land in `~/.denrc`, so they only apply to
  interactive shells. The importer counts them and tells you; move any that
  `den -c` needs -- `$PATH` almost always does -- into `~/.denenv`.
- oh-my-zsh does not port. Its aliases are the part worth keeping, and they are
  plain shell: copy the ones you use into `~/.denrc` by hand.

### 2. Update Array Indexing

If you use arrays, update to 0-based indexing:

```bash
# Zsh (1-based)
arr=(one two three)
echo ${arr[1]}  # "one"

# Den (0-based)
arr=(one two three)
echo ${arr[0]}  # "one"
```

### 4. Convert Prompt

Convert `%` escapes to `{}` placeholders:

```bash
# Zsh
PROMPT='%n@%m:%~%# '

# Den (in den.jsonc)
"format": "{user}@{host}:{cwd}{prompt_char} "
```

### 5. Update Glob Patterns

Replace Zsh-specific globs:

| Zsh | Den Alternative |
|-----|-----------------|
| `_(.)` | `find . -type f` |
| `_(/)` | `find . -type d` |
| `^_.txt` | `!(_.txt)` with `shopt -s extglob` |

### 6. Test Your Scripts

```bash
# Run scripts in Den
den ./my_script.sh

# Check for compatibility issues
den -n ./my_script.sh  # Syntax check only
```

## Unsupported Zsh Features

Features not available in Den:

| Feature | Status | Workaround |
|---------|--------|------------|
| Zsh parameter flags `${(L)var}` | Not planned | Use `tr` |
| Glob qualifiers `*(.)` | Not planned | Use `find` |
| Zsh modules (zmodload) | Not planned | Use builtins |
| `bindkey` | Supported | zsh notation, widget names and keymaps |
| `zle -N` user widgets | Supported | Shell functions as widgets, with `$BUFFER`/`$CURSOR` |
| `vared` | Not planned | Use `read` |
| Floating point arithmetic | Not planned | Use `bc` or `awk` |
| `zparseopts` | Not planned | Use `getopts` |
| Precommand modifiers (noglob, etc.) | Partial | Case-by-case |

## Performance Tips

Den is optimized for speed. To get the best performance:

1. **Use builtins** - Den's builtins are faster than external commands
2. **Simple prompts** - Avoid expensive git operations in prompts
3. **Native completion** - Simpler than zstyle-based completion
4. **No framework overhead** - Unlike Oh-My-Zsh, Den is lightweight

## Getting Help

```bash
# Built-in help
help              # List all builtins
help cd           # Help for specific builtin
den --help        # CLI options

# Man page
man den
```

## Resources

- [Den Documentation](https://den.sh/docs)
- [Bash Migration Guide](./BASH_MIGRATION.md)
- [Feature Comparison](./FEATURES.md)
- [Configuration Guide](./config.md)
