# History Substring Search

## Overview

Den now supports **zsh-style history substring search**, one of the most popular and useful features from zsh. This allows you to search through your command history by typing part of a command and using the arrow keys to navigate through matching entries.

## How It Works

When you type a few characters and press **Up**or**Down**arrow, Den will only show history entries that**contain** those characters anywhere in the command, not just at the beginning.

### Basic Usage

```bash
# Type part of a command you want to find
❯ git

# Press Up arrow - shows previous commands containing "git"
❯ git commit -m "fix bug"

# Press Up again - shows next older command containing "git"
❯ git push origin main

# Press Down - navigates forward through matching commands
❯ git pull --rebase

# Press Down past the end - returns to your original search query
❯ git
```

### Examples

**Search for commands with "docker":**
```bash
# Type the search term
❯ docker

# Press Up to cycle through matches
❯ docker ps -a
❯ docker build -t myapp .
❯ docker run -p 8080:8080 myapp
❯ sudo docker system prune -f
```

**Search for file operations:**
```bash
# Search for any command that modified config files
❯ config

# Cycle through
❯ vi ~/.config/den/config.json
❯ cat src/config_loader.zig
❯ cp config.template config.prod
```

**Search for specific flags:**
```bash
# Find all commands using the -rf flag
❯ -rf

# Shows
❯ rm -rf node_modules
❯ cp -rf dist/ backup/
```

## Features

### Substring Matching

Unlike basic history navigation (which matches from the start), substring search finds matches anywhere in the command:

```bash
# Searching for "main" will find
git push origin main
cd ~/Documents/main_project
vim src/main.zig
```

### Smart Behavior

**Empty Line Navigation:**

- If you press Up/Down with an empty line, it behaves like traditional history browsing (shows all commands in order)

**Locked Search:**

- Once you start searching with a query, Up/Down will only show matching entries
- The search query is locked until you modify the line or press Enter/Esc

**Return to Original:**

- Pressing Down past the last match returns you to your original search query
- You can then modify it and search again

## Keyboard Shortcuts

| Key | Action |
|-----|--------|
| `Up Arrow` | Previous matching history entry (or start search if typing) |
| `Down Arrow` | Next matching history entry |
| `Enter` | Execute the currently displayed command |
| Type any character | Exit search mode and modify the line |
| `Ctrl+C` | Cancel and clear line |
| `Backspace`/`Delete` | Exit search mode and edit |

## Implementation Details

The history substring search is implemented in `src/utils/terminal.zig`:

### Key Components

1. **Search Query**: When you first press Up with text on the line, that text becomes the search query
2. **Filtered Navigation**: `historyPrevious()` and `historyNext()` skip entries that don't contain the search query
3. **State Management**: Search state is cleared when you type new characters

### Algorithm

```

1. User types: "git"
2. User presses Up
   - Save "git" as search query
   - Search backward through history for entries containing "git"
   - Show first match
3. User presses Up again
   - Continue searching backward with same query
   - Show next older match
4. User presses Down
   - Search forward through history with same query
   - Show next newer match
5. User types any character
   - Clear search state
   - Insert character normally

```

### Memory Management

- Search query is allocated when search starts
- Properly freed when search ends or is cancelled
- Saved line is restored if user exits search
- All allocations are tracked and cleaned up in `deinit()`

## Comparison with zsh

Den's implementation provides the core functionality of zsh's history substring search:

**What Den does (like zsh):**

- ✅ Substring matching anywhere in the command
- ✅ Up/Down arrow navigation through matches
- ✅ Return to original query when reaching the end
- ✅ Clear search on text modification
- ✅ Traditional history browsing with empty line

**zsh additional features (not yet in Den):**

- Incremental search with Ctrl+R
- Highlighting of search matches in the displayed command
- Case-insensitive search option
- Fuzzy matching
- Search history count indicator

## Usage Tips

### 1. **Be Specific**

Search for distinctive parts of commands:
```bash
# Instead of searching "git", search for
❯ rebase      # finds git rebase commands
❯ origin      # finds git remote operations
```

### 2. **Search by flags**

Find commands by their arguments:
```bash
❯ --verbose
❯ -la
❯ --help
```

### 3. **Search by file extensions**

```bash
❯ .zig        # finds all commands operating on Zig files
❯ .json       # finds JSON file operations
```

### 4. **Partial paths**

```bash
❯ src/        # finds commands in src directory
❯ test/       # finds test-related commands
```

## Configuration

History substring search is enabled by default and works automatically. No configuration needed!

The feature integrates seamlessly with:

- History persistence (`~/.den_history`)
- History size limits (1000 entries)
- History deduplication

## Troubleshooting

**Search not finding commands:**

- Remember it's substring search - check your spelling
- The search is case-sensitive
- Make sure the command is actually in your history

**Search feels stuck:**

- You might have reached the end of matches
- Press Down to return to your search query
- Type a new character to exit search mode

**Want to exit search mode:**

- Type any character to modify the line
- Press Ctrl+C to cancel
- Press Enter to execute current command

## Performance

History substring search is highly efficient:

- **O(n)** search through history entries
- Only searches when you press Up/Down
- No background processing
- Minimal memory overhead (one search query string)

## Future Enhancements

Potential improvements for history substring search:

1. **Ctrl+R incremental search**: Interactive search with live filtering
2. **Match highlighting**: Visually show which part matched
3. **Case-insensitive option**: Match regardless of case
4. **Fuzzy matching**: Find "gps" for "git push"
5. **Search statistics**: Show "match 3 of 15"
6. **History filtering**: Exclude duplicates or failed commands
7. **Multi-pattern search**: Search for multiple terms

## Examples in Practice

### Finding long commands

```bash
# You remember you ran a complex docker command
❯ docker run

# Cycle through to find the exact one
❯ docker run -d -p 8080:8080 --name myapp --restart=always myimage:latest
```

### Reusing flags

```bash
# Find that curl command with all the right flags
❯ curl

# Found it
❯ curl -X POST -H "Content-Type: application/json" -d '{"key":"value"}' https://api.example.com
```

### Directory navigation

```bash
# Find when you cd'd to a project
❯ Documents

# Shows
❯ cd ~/Documents/Projects/den
```

## See Also

- [Command History](./HISTORY.md) - General history documentation
- [ZSH Comparison](./ZSH_COMPARISON.md) - Feature comparison with zsh
- [Keyboard Shortcuts](./KEYBINDINGS.md) - All keyboard shortcuts
- Source: `src/utils/terminal.zig` (lines 704-791)

## Technical Notes

### Implementation Highlights

1. **Stateful Search**: Uses `history_search_query` to maintain search context
2. **Clean State Management**: Automatically clears search on text modification
3. **Backward Compatibility**: Empty line still does traditional history browsing
4. **Memory Safe**: All allocations properly tracked and freed

### Edge Cases Handled

- Empty history
- Single entry in history
- No matches found (stays at current position)
- Search query at start/end of history
- User modifying line during search
- Multiple consecutive Up/Down presses

### Code Quality

- Clear separation of concerns
- Proper error handling
- No memory leaks
- Consistent with existing code style
- Well-commented implementation
