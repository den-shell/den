# Quick Start

Get up and running with Den in minutes.

## Running Den

After building Den, start it interactively:

```bash
./zig-out/bin/den
```

You'll get a prompt (the default is a two-line prompt ending in `❯`):

```
~/projects
❯
```

## Basic Commands

### Running External Commands

```bash
❯ ls -la
drwxr-xr-x  15 user  staff   480 Oct 25 12:00 .
-rw-r--r--   1 user  staff  1234 Oct 25 12:00 README.md

❯ git status
On branch main
nothing to commit, working tree clean
```

### Pipelines

Combine commands with pipes:

```bash
❯ ls -la | grep zig
drwxr-xr-x  15 user  staff   480 Oct 25 12:00 zig-out
-rw-r--r--   1 user  staff  1234 Oct 25 12:00 build.zig

❯ cat README.md | head -5
# Den Shell
A modern shell written in Zig.
```

### Environment Variables

```bash
❯ export MY_VAR="Hello, World!"
❯ echo $MY_VAR
Hello, World!

❯ export PATH="$HOME/bin:$PATH"
❯ echo $PATH
/Users/user/bin:/usr/local/bin:/usr/bin:/bin
```

### Command Substitution

```bash
❯ echo "Today is $(date)"
Today is Mon Oct 25 12:00:00 PDT 2024

❯ mkdir "backup-$(date +%Y%m%d)"
❯ ls
backup-20241025
```

## Navigation

### Changing Directories

```bash
❯ cd /tmp
❯ pwd
/tmp

❯ cd -
/home/user

❯ cd ~/projects
❯ pwd
/home/user/projects
```

### Directory Stack

```bash
❯ pushd /var/log
/var/log ~

❯ pushd /etc
/etc /var/log ~

❯ dirs
/etc /var/log ~

❯ popd
/var/log ~

❯ popd
~
```

## Job Control

### Background Jobs

```bash
❯ sleep 30 &
[1] 12345

❯ jobs
[1]+ Running    sleep 30 &

❯ fg %1
# (brings sleep to foreground)
# Press Ctrl+Z to suspend

[1]+ Stopped    sleep 30

❯ bg %1
[1]+ Running    sleep 30 &
```

## Scripting

### Running a Script

```bash
❯ ./script.sh
# Runs the script

❯ den script.sh
# Also runs the script
```

### Simple Script Example

Create a file `hello.sh`:

```bash
# !/usr/bin/env den

echo "Hello from Den!"
echo "Current directory: $(pwd)"
echo "Today: $(date)"
```

Run it:

```bash
❯ chmod +x hello.sh
❯ ./hello.sh
Hello from Den!
Current directory: /home/user
Today: Mon Oct 25 12:00:00 PDT 2024
```

## Useful Aliases

Add to your `~/.denrc`:

```bash
# List aliases
alias ll='ls -la'
alias la='ls -A'
alias l='ls -CF'

# Navigation
alias ..='cd ..'
alias ...='cd ../..'
alias ~='cd ~'

# Safety
alias rm='rm -i'
alias cp='cp -i'
alias mv='mv -i'

# Git shortcuts
alias gs='git status'
alias gp='git push'
alias gl='git log --oneline'
```

## Tab Completion

Den supports intelligent tab completion:

```bash
❯ cd ~/pro<TAB>
❯ cd ~/projects/

❯ git sta<TAB>
❯ git status
```

## History

Navigate previous commands:

- **Up/Down arrows** - Browse history
- **Ctrl+R** - Search history
- `history` - View all history

```bash
❯ history
    1  ls -la
    2  cd /tmp
    3  echo "Hello"
    4  git status
```

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `Ctrl+A` | Move to beginning of line |
| `Ctrl+E` | Move to end of line |
| `Ctrl+U` | Clear line before cursor |
| `Ctrl+K` | Clear line after cursor |
| `Ctrl+W` | Delete word before cursor |
| `Ctrl+L` | Clear screen |
| `Ctrl+C` | Cancel current command |
| `Ctrl+D` | Exit shell (on empty line) |
| `Tab` | Auto-complete |

## Getting Help

List all built-in commands:

```bash
❯ help
```

Get help for a specific command:

```bash
❯ help cd
❯ help export
```

## Next Steps

- [Configuration](/guide/configuration) - Customize Den
- [Custom Commands](/guide/custom-commands) - Create aliases and scripts
- [Features](/features/overview) - Explore all capabilities
- [Builtins Reference](/builtins/reference) - All 58 built-in commands
