# Den for Bash Users

A comprehensive guide for Bash users transitioning to Den shell. This guide maps common Bash features to their Den equivalents.

## Quick Start

Den is designed to be familiar to Bash users. Most Bash scripts will work in Den with minimal or no modifications.

```bash
# Your .bashrc aliases work in Den
alias ll='ls -la'
alias gs='git status'

# Your scripts work too
./my_script.sh
```

## Feature Comparison

| Feature | Bash | Den | Notes |
|---------|------|-----|-------|
| Startup time | ~50ms | ~5ms | 10x faster |
| Memory usage | ~15MB | ~2MB | 7x less |
| Configuration | `.bashrc` | `den.jsonc` | JSON + shell scripts |
| Scripting | Full POSIX | Full POSIX | Compatible |
| Plugins | Limited | Native support | Hot-reload |

## Syntax Compatibility

### Variables

```bash
# Identical in both shells
NAME="Den"
echo $NAME
echo ${NAME}

# Default values - identical
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

### Arrays

```bash
# Indexed arrays - identical
arr=(one two three)
echo ${arr[0]}
echo ${arr[@]}
echo ${#arr[@]}

# Associative arrays - identical
declare -A map
map[key]=value
echo ${map[key]}
echo ${!map[@]}    # All keys
```

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

## Shell Options

### set Options

```bash
# These work identically
set -e          # Exit on error (errexit)
set -u          # Error on unset variables (nounset)
set -x          # Print commands (xtrace)
set -o pipefail # Pipeline fails on any error
set -f          # Disable globbing (noglob)
```

### shopt Options

Den supports most bash shopt options:

```bash
shopt -s extglob      # Extended globbing
shopt -s nullglob     # Empty glob returns nothing
shopt -s dotglob      # Glob matches dotfiles
shopt -s globstar     # ** recursive matching
shopt -s autocd       # cd to directory by name
shopt -s cdspell      # Correct cd typos
```

## Key Differences

### 1. Configuration File

**Bash:**
```bash
# ~/.bashrc
export PATH="$HOME/bin:$PATH"
alias ll='ls -la'
PS1='\u@\h:\w\$ '
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

You can also use shell scripts with Den. It reads three: `~/.denenv` for every
shell, `~/.denprofile` for login shells, and `~/.denrc` for interactive ones.
`$PATH` and exported variables belong in `~/.denenv` -- in `~/.denrc` they would
not reach `den -c`, scripts, or anything running `$SHELL -c`. The split matches
bash's own `.bash_profile` / `.bashrc` distinction, but unlike bash the
always-sourced file is a separate one.

### 2. Prompt Customization

**Bash:** Uses escape codes like `\u`, `\h`, `\w`

**Den:** Uses placeholders like `{user}`, `{host}`, `{cwd}`

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

### 3. History

**Bash:**
```bash
history           # Show history
!42               # Execute command 42
!!                # Repeat last command
!$                # Last argument of previous command
```

**Den:** Same features plus:
```bash
# Fuzzy search with Ctrl+R then Ctrl+S
# Toggle between substring and fuzzy match
```

### 4. Completion

**Bash:** Uses `complete`, `compgen`, `compopt`

**Den:** Same commands, plus enhanced context-aware completion:
```bash
complete -F _git_complete git    # Works same as Bash
```

## Migration Checklist

### 1. Copy Your Aliases

Your Bash aliases work directly in Den:

```bash
# Extract aliases from .bashrc
grep "^alias" ~/.bashrc >> ~/.denrc

# Or use den.jsonc format
```

> `den import-zsh` does this properly for zsh files, keeping multi-line
> functions and `case` blocks intact and reporting what it cannot translate.
> There is no bash equivalent yet, so the `grep` above is still the recipe --
> note that it drops anything spanning more than one line.

### 2. Copy Your Functions

Functions work identically:

```bash
# Copy function definitions to ~/.denrc
grep -A 10 "^[a-z_]*() {" ~/.bashrc >> ~/.denrc
```

### 3. Set Up Prompt

Convert your PS1:

| Bash | Den |
|------|-----|
| `\u` | `{user}` |
| `\h` | `{host}` |
| `\w` | `{cwd}` |
| `\W` | `{cwd_basename}` |
| `\$` | `{prompt_char}` |
| `\n` | newline |

### 4. Test Your Scripts

```bash
# Run scripts in Den
den ./my_script.sh

# Check for compatibility issues
den -n ./my_script.sh  # Syntax check only
```

## Unsupported Bash Features

A few Bash-specific features are not yet implemented:

| Feature | Status | Workaround |
|---------|--------|------------|
| `PROMPT_COMMAND` | Planned | Use hooks in config |
| `coproc` | Supported | Use coprocesses |
| `mapfile/readarray` | Supported | Use mapfile builtin |
| `compopt` | Planned | Use complete |

## Performance Tips

Den is optimized for speed. To get the best performance:

1. **Use builtin commands** - Den's builtins are faster than external commands
2. **Avoid unnecessary subshells** - `$(cmd)` creates a process
3. **Use simple prompts** - Complex git info adds latency
4. **Enable caching** - Path resolution is cached automatically

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
- [Feature Comparison](./FEATURES.md)
- [Configuration Guide](./config.md)
- [Troubleshooting](./TROUBLESHOOTING.md)
