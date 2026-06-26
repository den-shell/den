# Tab Completion

## Overview

Den provides powerful, interactive tab completion similar to zsh, making command-line navigation and file operations faster and more intuitive. Press `TAB` to complete commands, file paths, and directories with intelligent suggestions.

## Features

### 1. Basic Tab Completion

Press `TAB` to complete the current word based on context:

```bash
# Complete commands
❯ git st<TAB>
❯ git status

# Complete file paths
❯ cat README<TAB>
❯ cat README.md

# Complete directory paths
❯ cd Doc<TAB>
❯ cd Documents/
```

### 2. Multiple Suggestions

When multiple completions are available, Den displays them in a neat, color-coded list:

```bash
❯ cd /usr/l<TAB>

/usr/lib/     /usr/libexec/     /usr/local/
```

**Cycling through suggestions:**

- Press `TAB` repeatedly to cycle through all available options
- The current selection is **highlighted** in the list
- The highlighted completion is automatically inserted into your command line

**Example:**
```bash
# Type and press TAB
❯ cd /usr/l<TAB>

# First suggestion appears, list shows
# > lib/        libexec/        local/
❯ cd /usr/lib/

# Press TAB again to cycle
# > lib/        libexec/        local/
❯ cd /usr/libexec/

# Press TAB again
# > lib/        libexec/        local/
❯ cd /usr/local/
```

### 3. Mid-Word Path Completion (zsh-style)

Type abbreviated paths and expand them instantly - one of zsh's most loved features:

```bash
# Type abbreviations
❯ cd /u/l/b<TAB>

# Expands to full path
❯ cd /usr/local/bin/
```

**How it works:**

- Each segment can be abbreviated to its first letter(s)
- Den resolves ambiguous segments using lookahead
- Only expands if a unique path can be determined

**Examples:**
```bash
/u/l/b     → /usr/local/bin/
/u/l/s     → /usr/local/share/
/h/D/P/d   → /home/Documents/Projects/den/
~/D/P      → ~/Documents/Projects/

# Works with relative paths too
./s/u/c    → ./src/utils/completion.zig
```

**Ambiguity resolution:**
Even when intermediate segments are ambiguous, Den uses lookahead:

```bash
# /u/l could be /usr/lib or /usr/local
# But only /usr/local has a directory starting with 'b'
/u/l/b → /usr/local/bin/  ✓
```

See [MID_WORD_COMPLETION.md](./MID_WORD_COMPLETION.md) for detailed documentation.

### 4. Smart Directory Completion

Den adds trailing slashes to directories and distinguishes between files and folders:

```bash
# Directories get a trailing slash
❯ cd Documents<TAB>
❯ cd Documents/

# Files don't
❯ cat config<TAB>
❯ cat config.json
```

### 5. Context-Aware Completion

Different commands get different completion behaviors:

```bash
# cd completes only directories
❯ cd <TAB>
Documents/    Downloads/    Desktop/

# ls completes both files and directories
❯ ls <TAB>
Documents/    file.txt    README.md

# Commands complete from PATH
❯ git<TAB>
git    gitk    git-flow
```

### 6. Script and Executable Highlighting

Executable files and scripts are highlighted differently in completion lists:

```bash
❯ ./<TAB>
script.sh_    data.json    build.sh_    README.md
```

_(Scripts and executables are marked with special colors)_

## Keyboard Shortcuts

| Key | Action |
|-----|--------|
| `TAB` | Complete current word / Cycle through suggestions |
| `Shift+TAB` | Cycle backwards through suggestions (coming soon) |
| `Esc` | Cancel completion and clear suggestions |
| `Enter` | Accept current completion and execute |
| Type any character | Accept current completion and continue typing |

## Advanced Features

### Path Prefix Preservation

When cycling through completions in subdirectories, Den preserves your path context:

```bash
❯ cd Documents/Projects/<TAB>
den/    myapp/    website/

# Prefix "Documents/Projects/" is preserved while cycling
❯ cd Documents/Projects/den/
```

### Empty Line Behavior

Pressing `TAB` on an empty line or with only whitespace inserts 4 spaces (standard tab):

```bash
❯ <TAB>
❯
```

### No Suggestions Behavior

If no completions are available, Den emits a subtle bell sound (system beep) and makes no changes:

```bash
❯ cd /nonexistent<TAB>
# _beep_ - no changes
```

## Completion Types

Den provides different completion strategies based on context:

### File Completion

- Completes files and directories in the current path
- Adds `/` to directories
- Filters hidden files (starting with `.`) unless you type `.` first

```bash
❯ cat .<TAB>
.bashrc    .gitignore    .config/
```

### Directory Completion (cd, pushd, etc.)

- Only shows directories
- Includes hidden directories if you start with `.`
- Performs mid-word path expansion

### Command Completion

- Searches `PATH` for executable commands
- Includes built-in shell commands
- Filters based on prefix match

## Implementation Details

### Components

1. **Completion Engine** (`src/utils/completion.zig`)
   - Core logic for finding matches
   - Path expansion algorithm
   - File system traversal

2. **Line Editor** (`src/utils/terminal.zig`)
   - Tab key handling
   - Suggestion cycling
   - List display and highlighting

3. **Completion Functions**
   - `completeFile()` - Files and directories
   - `completeDirectory()` - Directories only
   - `completeCommand()` - Executables from PATH

### Display Format

Completions are displayed in a multi-column layout:

- **4 columns** maximum for readability
- **Color-coded** by type (directories, files, executables)
- **Highlighted** current selection
- **Auto-sized** to fit terminal width

### Performance

- Efficient directory traversal using Zig's standard library
- Lazy evaluation - completions only computed when requested
- Minimal memory allocation - reuses buffers where possible
- Fast path resolution with caching

## Comparison with zsh

Den's tab completion implements many popular zsh features:

**What Den does (like zsh):**

- ✅ Mid-word path expansion (`/u/l/b` → `/usr/local/bin/`)
- ✅ Multi-segment lookahead for ambiguity resolution
- ✅ Cycling through suggestions with Tab
- ✅ Visual suggestion list with highlighting
- ✅ Context-aware completion (files vs directories)
- ✅ Executable detection and marking
- ✅ Smart slash handling for directories

**zsh features not yet in Den:**

- Arrow key navigation through suggestions
- Fuzzy matching (e.g., `doc/proj` matches `Documents/Projects`)
- Menu selection mode
- Colored completion categories
- Completion descriptions
- Approximate completion (did you mean...?)

## Configuration

Tab completion is enabled by default and requires no configuration. All features work out of the box!

### Customization (Future)

Planned configuration options:

- Completion style (cycling vs menu)
- Number of columns in display
- Color scheme for completions
- Case sensitivity settings
- Fuzzy matching toggle

## Usage Examples

### Example 1: Quick Directory Navigation

```bash
# Navigate deep directory structures quickly
❯ cd /u/l/s/f/t<TAB>
❯ cd /usr/local/share/fonts/truetype/

# Works with home directory too
❯ cd ~/D/P/d<TAB>
❯ cd ~/Documents/Projects/den/
```

### Example 2: Finding Files

```bash
# Complete file names
❯ cat sr<TAB>
src/    scripts/

# Cycle through matches
❯ cat src/<TAB>
main.zig    cli.zig    shell.zig
# Press TAB to cycle through each file
```

### Example 3: Discovering Commands

```bash
# Explore available git commands
❯ git <TAB>
git-add      git-commit    git-push
git-branch   git-diff      git-pull
# Tab through to find what you need
```

### Example 4: Working with Hidden Files

```bash
# Show hidden files by starting with dot
❯ cat .<TAB>
.gitignore    .bashrc    .config/
```

## Troubleshooting

### Completions Not Appearing

**Symptom:** Pressing TAB does nothing

**Solutions:**

1. Make sure you've typed at least one character (TAB on empty line = 4 spaces)
2. Check if the directory/file actually exists
3. Verify file permissions - Den can't complete files it can't read

### Too Many Suggestions

**Symptom:** Overwhelming list of completions

**Solution:** Type more characters to narrow down:
```bash
# Instead of
❯ cd D<TAB>  # Shows: Desktop/ Documents/ Downloads/

# Type more
❯ cd Doc<TAB>  # Shows: Documents/
```

### Completion Cycling Not Working

**Symptom:** Pressing TAB multiple times shows the same result

**Solution:** Make sure you haven't modified the line between TAB presses. Any character input resets the cycling state.

### Mid-Word Expansion Not Working

**Symptom:** `/u/l/b<TAB>` doesn't expand

**Possible causes:**

1. Path doesn't exist or isn't unique
2. Permissions prevent reading directories
3. Typing error in abbreviation

**Debug:**
```bash
# Test the completion engine directly
den complete "/u/l/b"
# Should output: ["/usr/local/bin/"]
```

## Performance Tips

1. **Be specific:** More characters = faster completion

   ```bash
# Faster
   ❯ cd Doc<TAB>

# Slower (scans more files)
   ❯ cd D<TAB>
   ```

2. **Use mid-word expansion for deep paths:**

   ```bash
# Efficient
   ❯ cd /u/l/s/a/j<TAB>

# Less efficient
   ❯ cd /u<TAB>sr<TAB>loc<TAB>sha<TAB>app<TAB>jav<TAB>
   ```

3. **Avoid completions on huge directories:**

   ```bash
# May be slow
   ❯ ls /usr/bin/<TAB>  # Thousands of files
   ```

## See Also

- [MID_WORD_COMPLETION.md](./MID_WORD_COMPLETION.md) - Detailed guide to path abbreviation
- [HISTORY_SUBSTRING_SEARCH.md](./HISTORY_SUBSTRING_SEARCH.md) - History navigation
- [AUTOCOMPLETION.md](./AUTOCOMPLETION.md) - Shell-specific completion scripts (bash/zsh/fish)
- [Completion API](./API.md) - Completion engine documentation

## Technical Details

### Completion Algorithm

1. **Parse context:** Determine what's being completed (command, file, directory)
2. **Extract word:** Find the word under the cursor
3. **Detect expansion:** Check if it's a mid-word path abbreviation
4. **Expand segments:** Recursively expand each path segment
5. **Filter matches:** Find all valid completions
6. **Display results:** Show single match or list

### State Management

Den maintains completion state between TAB presses:

- `completion_list`: Array of available completions
- `completion_index`: Current position in cycling
- `completion_word_start`: Buffer position where completion began
- `completion_path_prefix`: Saved directory prefix for cycling

This state is cleared when:

- User types any character
- User moves cursor
- User cancels with Esc
- Command is executed

### Memory Management

All completion strings are:

- Allocated using the line editor's allocator
- Freed when completion state is cleared
- Managed safely to prevent leaks

## Future Enhancements

1. **Arrow key navigation:** Use ↑/↓ to navigate suggestion list
2. **Fuzzy matching:** `doc/prj` matches `Documents/Projects`
3. **Completion descriptions:** Show file types, sizes, etc.
4. **Menu selection mode:** Visual menu with arrow keys
5. **Git-aware completion:** Complete branch names, remotes, etc.
6. **History-based suggestions:** Learn from frequently used paths
7. **Alias expansion:** Complete custom aliases
8. **Plugin completions:** Extensions can register custom completers

## Contributing

To improve tab completion:

1. Source code: `src/utils/completion.zig` and `src/utils/terminal.zig`
2. Tests: Add test cases for new features
3. Documentation: Update this file with new capabilities

## License

Same as Den Shell project.
