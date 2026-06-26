# Custom Commands

Den allows you to extend its functionality through aliases, shell scripts, and custom executables.

## Aliases

The simplest way to create custom commands is through aliases.

### Creating Aliases

```bash
# Simple command alias
alias update='sudo apt update && sudo apt upgrade'

# Alias with default options
alias grep='grep --color=auto'
alias ls='ls -G'  # macOS color

# Multi-command alias
alias dev='cd ~/projects && code .'

# Git shortcuts
alias gs='git status'
alias gp='git push'
alias gc='git commit -m'
alias gco='git checkout'
alias gb='git branch'
```

### Making Aliases Permanent

Add aliases to your configuration file:

```bash
# ~/.denrc

# Development aliases
alias dev='cd ~/Code && ls'
alias serve='python3 -m http.server'
alias ports='lsof -i -P -n | grep LISTEN'

# System aliases
alias update='brew update && brew upgrade'
alias cleanup='brew cleanup && brew autoremove'

# Navigation
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
```

### Dynamic Aliases

While Den doesn't support functions directly in aliases, you can call scripts:

```bash
# Create a script for complex operations
alias today='~/bin/show-today.sh'
```

## Shell Scripts

For more complex commands, create shell scripts.

### Creating a Den Script

```bash
# !/usr/bin/env den

# ~/bin/project-setup.sh
# Script to initialize a new project

# Check for project name
if test -z "$1"; then
    echo "Usage: project-setup <name>"
    exit 1
fi

PROJECT_NAME="$1"

# Create project structure
mkdir -p "$PROJECT_NAME"
pushd "$PROJECT_NAME"

mkdir -p src tests docs
touch README.md
touch src/main.zig

echo "# $PROJECT_NAME" > README.md
echo "Project $PROJECT_NAME created!"

popd
```

### Script Best Practices

```bash
# !/usr/bin/env den

# Always include error handling
set -e  # Exit on error (if supported)

# Use meaningful variable names
export PROJECT_DIR="${HOME}/projects"
export BACKUP_DIR="${HOME}/backups"

# Check for required tools
if ! type git > /dev/null 2>&1; then
    echo "Error: git is required"
    exit 1
fi

# Provide usage information
show_help() {
    echo "Usage: myscript [options] <args>"
    echo ""
    echo "Options:"
    echo "  -h, --help    Show this help"
    echo "  -v, --verbose Enable verbose output"
}

# Parse arguments
for arg in "$@"; do
    if test "$arg" = "-h" || test "$arg" = "--help"; then
        show_help
        exit 0
    fi
done

# Main script logic
echo "Running script..."
```

### Making Scripts Executable

```bash
# Add execute permission
chmod +x ~/bin/my-script.sh

# Add ~/bin to your PATH in ~/.denrc
export PATH="$HOME/bin:$PATH"

# Now you can run it directly
my-script.sh
```

## Custom Executables

Create compiled programs and add them to your PATH.

### Zig Executables

```zig
// ~/src/mycommand/main.zig
const std = @import("std");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("Hello from custom command!\n", .{});
}
```

Build and install:

```bash
cd ~/src/mycommand
zig build -Doptimize=ReleaseFast
cp zig-out/bin/mycommand ~/bin/
```

### Creating Utility Commands

Here's a practical example - a command to quickly jump to projects:

```zig
// jump.zig - Jump to project directories
const std = @import("std");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: jump <project>\n", .{});
        return;
    }

    const project = args[1];
    const home = std.posix.getenv("HOME") orelse "/home/user";
    const path = try std.fmt.allocPrint(allocator, "{s}/projects/{s}", .{home, project});

    // Output the path for cd to consume
    const stdout = std.io.getStdOut().writer();
    try stdout.print("{s}\n", .{path});
}
```

Use with an alias:

```bash
alias j='cd $(jump "$1")'
```

## Command Wrappers

Create wrappers to add functionality to existing commands.

### Git Wrapper Example

```bash
# !/usr/bin/env den
# ~/bin/g - Smart git wrapper

# Handle common typos and shortcuts
if test "$1" = "st"; then
    git status
elif test "$1" = "co"; then
    shift
    git checkout "$@"
elif test "$1" = "cm"; then
    shift
    git commit -m "$@"
elif test "$1" = "p"; then
    git push
elif test "$1" = "l"; then
    git log --oneline -10
else
# Pass through to git
    git "$@"
fi
```

### Docker Wrapper

```bash
# !/usr/bin/env den
# ~/bin/d - Docker shortcuts

if test "$1" = "ps"; then
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
elif test "$1" = "stop-all"; then
    docker stop $(docker ps -q)
elif test "$1" = "clean"; then
    docker system prune -af
else
    docker "$@"
fi
```

## Command Discovery

Den searches for commands in this order:

1. **Built-in commands** (58 built-ins)
2. **Aliases**
3. **PATH directories** (in order)

To see where a command comes from:

```bash
# Show command type
type ls

# Show full path of command
which git

# Show all matches
type -a python
```

## Tips for Custom Commands

### Use Descriptive Names

```bash
# Good - clear purpose
alias git-clean='git clean -fd'
alias docker-logs='docker logs -f'

# Avoid - too short/cryptic
alias gc='git clean -fd'
alias dl='docker logs -f'
```

### Document Your Commands

```bash
# ~/.denrc

# ------------------------------------------------
# Git Aliases
# ------------------------------------------------
alias gs='git status'        # Show status
alias gp='git push'          # Push to remote
alias gl='git log --oneline' # Short log

# ------------------------------------------------
# Development
# ------------------------------------------------
alias serve='python3 -m http.server 8000'  # Local server
alias lint='npm run lint'                   # Run linter
```

### Test Before Adding

```bash
# Test a command before making it an alias
docker ps --format "table {{.Names}}\t{{.Status}}"

# If it works, add the alias
alias dps='docker ps --format "table {{.Names}}\t{{.Status}}"'
```

## Next Steps

Learn about [Scripting](/guide/scripting) to write more complex automation.
