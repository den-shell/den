# Configuration

Den can be configured through configuration files, environment variables, and runtime settings.

## Configuration Files

Den reads configuration from the following locations (in order):

1. `~/.denrc` - User configuration
2. `~/.config/den/config` - XDG configuration
3. `.denrc` - Project-specific configuration

### Example Configuration

```bash
# ~/.denrc

# Set custom prompt
export PS1='❯ '

# Configure history
export HISTSIZE=10000
export HISTFILE="$HOME/.den_history"

# Set default editor
export EDITOR=vim

# Custom aliases
alias ll='ls -la'
alias la='ls -A'
alias l='ls -CF'
alias ..='cd ..'
alias ...='cd ../..'

# Add to PATH
export PATH="$HOME/.local/bin:$PATH"
```

## Environment Variables

Den supports the following environment variables:

### Shell Behavior

| Variable | Description | Default |
|----------|-------------|---------|
| `PS1` | Primary prompt string | `❯ ` |
| `PS2` | Continuation prompt | `> ` |
| `HOME` | Home directory | From system |
| `PATH` | Command search path | From system |
| `PWD` | Current working directory | Auto-set |
| `OLDPWD` | Previous directory | Auto-set |

### History Settings

| Variable | Description | Default |
|----------|-------------|---------|
| `HISTFILE` | History file location | `~/.den_history` |
| `HISTSIZE` | Max history entries | `1000` |
| `HISTCONTROL` | History control flags | None |

### Editor Settings

| Variable | Description | Default |
|----------|-------------|---------|
| `EDITOR` | Default text editor | `vi` |
| `VISUAL` | Visual editor | Value of `EDITOR` |

## Prompt Customization

The prompt can be customized using special escape sequences in `PS1`:

```bash
# Simple prompt with username and directory
export PS1='\u@\h:\w$ '

# Colored prompt (if terminal supports it)
export PS1='\[\033[32m\]\u@\h\[\033[0m\]:\[\033[34m\]\w\[\033[0m\]$ '
```

### Escape Sequences

| Sequence | Description |
|----------|-------------|
| `\u` | Username |
| `\h` | Hostname (short) |
| `\H` | Hostname (full) |
| `\w` | Current directory |
| `\W` | Current directory (basename) |
| `\$` | `$` for normal user, `#` for root |
| `\n` | Newline |
| `\\` | Literal backslash |

## Aliases

Create command aliases for frequently used commands:

```bash
# Simple alias
alias gs='git status'
alias gp='git push'
alias gc='git commit'

# Alias with arguments (use functions for complex cases)
alias grep='grep --color=auto'
alias ls='ls --color=auto'

# Safety aliases
alias rm='rm -i'
alias mv='mv -i'
alias cp='cp -i'
```

### Managing Aliases

```bash
# List all aliases
alias

# Show specific alias
alias ll

# Remove an alias
unalias ll

# Remove all aliases
unalias -a
```

## Startup Files

Den executes startup files in this order:

### Login Shell

1. `/etc/profile` (if exists)
2. `~/.den_profile` (if exists)
3. `~/.denrc` (if exists)

### Interactive Non-Login Shell

1. `~/.denrc` (if exists)

### Non-Interactive Shell

Only environment variables from the calling shell are inherited.

## Tab Completion

Den provides intelligent tab completion for:

- Commands (from PATH)
- File and directory paths
- Built-in commands
- Aliases

### Completion Behavior

| Input | Tab Behavior |
|-------|--------------|
| Empty | List files in current directory |
| Partial command | Complete or list matching commands |
| Partial path | Complete or list matching paths |

## Key Bindings

Den supports common readline-like key bindings:

| Key | Action |
|-----|--------|
| `Ctrl+A` | Move to beginning of line |
| `Ctrl+E` | Move to end of line |
| `Ctrl+U` | Clear line before cursor |
| `Ctrl+K` | Clear line after cursor |
| `Ctrl+W` | Delete word before cursor |
| `Ctrl+L` | Clear screen |
| `Ctrl+C` | Interrupt current command |
| `Ctrl+D` | Exit shell (on empty line) |
| `Ctrl+R` | Reverse history search |
| `Up/Down` | Navigate history |

## Performance Tuning

### Reduce Startup Time

Keep your configuration minimal:

```bash
# ~/.denrc

# Only essential configuration
export PATH="$HOME/.local/bin:$PATH"

# Minimal aliases
alias ll='ls -la'
```

### History Optimization

```bash
# Limit history size
export HISTSIZE=1000

# Ignore duplicates
export HISTCONTROL=ignoredups

# Ignore common commands
export HISTIGNORE="ls:cd:pwd:exit"
```

## Debugging Configuration

To debug configuration issues:

```bash
# Run den with verbose mode (if available)
den --verbose

# Check environment variables
env | grep DEN

# Source config manually to check for errors
source ~/.denrc
```

## Next Steps

Learn about creating [Custom Commands](/guide/custom-commands) to extend Den's functionality.
