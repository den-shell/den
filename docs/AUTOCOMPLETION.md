# Den Shell Autocompletion

This document describes the autocompletion feature for Den Shell, which provides shell-specific tab completion for Bash, Zsh, and Fish.

## Overview

Den Shell now includes built-in support for generating autocompletion scripts for popular shells. The completion system leverages Den's existing `den complete` command for dynamic completions and provides static completions for subcommands.

## Features

- **Multi-shell support**: Bash, Zsh, and Fish
- **Dynamic completions**: Commands and files are completed using Den's completion engine
- **Static completions**: Subcommands and options are statically defined
- **Easy installation**: Single command to generate and install completions

## Architecture

### Components

1. **`src/shell_completion.zig`**: New module that generates shell-specific completion scripts
2. **`src/cli.zig`**: Extended with `completion` subcommand
3. **Existing `den complete`**: Used by completion scripts for dynamic suggestions

### How It Works

1. User types `den <TAB>`
2. Shell calls the appropriate completion function
3. Completion script determines context (subcommand, file, etc.)
4. For dynamic completions, script calls `den complete <input>`
5. Results are parsed and presented to the user

## Usage

### Generate Completion Scripts

```bash
# Bash
den completion bash

# Zsh
den completion zsh

# Fish
den completion fish
```

### Installation

#### Bash

```bash
# System-wide (requires sudo)
sudo den completion bash > /etc/bash_completion.d/den

# User-specific
mkdir -p ~/.local/share/bash-completion/completions
den completion bash > ~/.local/share/bash-completion/completions/den

# Or add to .bashrc
echo 'eval "$(den completion bash)"' >> ~/.bashrc
source ~/.bashrc
```

#### Zsh

```bash
# User-specific
mkdir -p ~/.zsh/completions
den completion zsh > ~/.zsh/completions/_den

# Add to .zshrc if not already there
echo 'fpath=(~/.zsh/completions $fpath)' >> ~/.zshrc
echo 'autoload -Uz compinit && compinit' >> ~/.zshrc
source ~/.zshrc
```

#### Fish

```bash
# User-specific (recommended)
mkdir -p ~/.config/fish/completions
den completion fish > ~/.config/fish/completions/den.fish

# Or source directly in config.fish
den completion fish | source
```

## Testing

After installation, test the completions:

### Bash/Zsh

```bash
den <TAB>           # Should show: shell, exec, complete, completion, etc.
den completion <TAB> # Should show: bash, zsh, fish
den exec ls <TAB>   # Should show files in current directory
```

### Fish

```fish
den <TAB>           # Should show subcommands with descriptions
den completion <TAB> # Should show shell types with descriptions
```

## Implementation Details

### File Structure

```
src/
├── cli.zig                  # Extended with completion command
├── shell_completion.zig     # New module for generating scripts
└── utils/
    └── completion.zig       # Existing completion engine
```

### Code Organization

The `ShellCompletion` struct in `src/shell_completion.zig` provides:

- `generateBash()`: Generates Bash completion script
- `generateZsh()`: Generates Zsh completion script
- `generateFish()`: Generates Fish completion script
- `generate(shell_type)`: Dispatcher method

Each completion script includes:

1. Installation instructions as comments
2. Static completion for Den subcommands
3. Dynamic completion using `den complete`
4. Context-aware completion (files, commands, etc.)

### Shell-Specific Features

#### Bash

- Uses `complete -F` with `_den_completions` function
- Leverages `compgen` for word matching
- Parses JSON output from `den complete`

#### Zsh

- Uses `#compdef` magic comment
- Provides descriptions for subcommands
- Uses `_arguments` for sophisticated parsing
- Supports context-sensitive completion

#### Fish

- Uses declarative `complete` syntax
- Provides rich descriptions for all options
- Uses `__fish_use_subcommand` for context detection
- Simplest to understand and debug

## Troubleshooting

### Completions Not Working

1. **Verify installation**:

   ```bash
# Bash
   ls -la ~/.local/share/bash-completion/completions/den

# Zsh
   ls -la ~/.zsh/completions/_den

# Fish
   ls -la ~/.config/fish/completions/den.fish
   ```

2. **Check if completion is loaded**:

   ```bash
# Bash
   complete -p den

# Zsh
   which _den

# Fish
   complete -c den
   ```

3. **Reload shell**:

   ```bash
   exec $SHELL
   ```

### JSON Parsing Issues

If you see raw JSON instead of completions, the shell script may need adjustment. Check:

- `den complete` is in your PATH
- JSON output is valid: `den complete ls`

### Permission Issues

If you cannot write to system directories, use user-specific installation paths shown above.

## Future Enhancements

Potential improvements for the completion system:

1. **Built-in command completion**: Include Den's 58 built-in commands in completions
2. **Alias expansion**: Complete custom aliases
3. **History-based suggestions**: Use command history for intelligent suggestions
4. **Plugin-aware completion**: Complete plugin-specific commands
5. **Advanced Fish integration**: Better use of Fish's rich completion features

## Development

### Adding New Completions

To add completions for a new shell:

1. Add a new `generate<Shell>()` method to `ShellCompletion`
2. Create the shell-specific script template
3. Add the shell type to `generate()` dispatcher
4. Update tests in `shell_completion.zig`
5. Update this documentation

### Testing Completions

Manual testing checklist:

- [ ] `den <TAB>` shows all subcommands
- [ ] `den completion <TAB>` shows bash/zsh/fish
- [ ] `den exec <TAB>` shows commands from PATH
- [ ] File paths complete with trailing `/` for directories
- [ ] Help text includes completion examples
- [ ] Error messages are clear and helpful

## References

- [Bash Programmable Completion](https://www.gnu.org/software/bash/manual/html_node/Programmable-Completion.html)
- [Zsh Completion System](http://zsh.sourceforge.net/Doc/Release/Completion-System.html)
- [Fish Completions Tutorial](https://fishshell.com/docs/current/completions.html)

## License

Same as Den Shell project.
