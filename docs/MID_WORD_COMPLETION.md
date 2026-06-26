# Mid-Word Path Completion

## Overview

Den now supports **zsh-style mid-word path completion**, allowing you to type abbreviated path components and have them automatically expanded when pressing TAB.

## How It Works

When you press TAB after typing a partial path like `/u/l/b`, Den will attempt to expand each abbreviated component to its full form if there's a unique match:

- `/u` → `/usr`
- `/usr/l` → `/usr/local`
- `/usr/local/b` → `/usr/local/bin`

### Examples

```bash
# Basic usage - expand abbreviated paths
/u/l/b<TAB>  → /usr/local/bin/

# Relative paths work too
./s/u<TAB>   → ./src/utils/  (if unique)

# Works in any command context
cd /u/l<TAB>      → cd /usr/local/
ls ~/D/P<TAB>     → ls ~/Documents/Projects/
cat s/m/c<TAB>    → cat src/main/config.zig
```

## Behavior

### Unique Matches

When each path segment has exactly one match, expansion happens automatically:
```bash
/u/l/b<TAB> → /usr/local/bin/  # if all segments are unique
```

### Ambiguous Segments with Lookahead

When a segment matches multiple directories, Den uses **multi-segment lookahead** to resolve ambiguity:
```bash
# /u/l is ambiguous (/usr/lib or /usr/local)
# But looking ahead at 'b' - only /usr/local has a directory starting with 'b'
/u/l/b<TAB> → /usr/local/bin/  ✓

# Works even with multiple ambiguous segments
/u/l/s<TAB> → /usr/local/share/  # Only 'local' has 'share'
```

**How lookahead works:**

1. Den finds all matches for current segment (e.g., `/u/l` → `lib`, `local`)
2. For each match, tries to expand the remaining segments
3. If exactly ONE path successfully expands through all segments → expand!
4. If zero or multiple paths work → show all possibilities

**Example of true ambiguity:**
```bash
# Both /usr/lib and /usr/local have directories starting with 'p'
/u/l/p<TAB> → shows: /usr/lib/python3.9/ /usr/local/python/
```

### Partial Expansion

If expansion cannot be uniquely determined, Den shows all possible matches:
```bash
# If /usr is unique but /usr/l matches both "lib" and "local"
# and both have matching subdirectories
/u/l<TAB> → shows: /usr/lib/ /usr/local/
```

## Implementation Details

The mid-word completion feature is implemented in `src/utils/completion.zig`:

- **`expandMidWordPath()`**: Main entry point for path expansion with lookahead
- **`expandPathWithLookahead()`**: Recursive algorithm that explores all possible paths
- **`expandSegment()`**: Expands a single path segment if it has a unique match
- **`completeFile()`**: Integrates mid-word expansion with regular file completion
- **`completeDirectory()`**: Directory-only completion with mid-word expansion

### Algorithm

**Simple Expansion (no lookahead needed):**

1. Split the path by `/` into segments
2. For each segment:
   - Skip special directories (`.`, `..`)
   - Try to find a unique match in the current directory
   - If unique: use the expanded name and continue
   - If ambiguous: use lookahead algorithm
3. Return the maximally expanded path

**Lookahead Algorithm (for ambiguous segments):**

1. Find all directory matches for current segment
2. If 0 matches: fail
3. If 1 match: expand and continue to next segment
4. If multiple matches:
   - If no remaining segments: fail (truly ambiguous)
   - For each match, recursively try to expand remaining segments
   - If exactly ONE match leads to successful full expansion: use it!
   - If zero or multiple matches succeed: fail (ambiguous)
5. Prevent infinite recursion with depth limit (20 levels)

**Example walkthrough:**
```
Input: /u/l/b

Step 1: Expand 'u' in '/'
  → Matches: 'usr' (unique)
  → Current: /usr

Step 2: Expand 'l' in '/usr'
  → Matches: 'lib', 'libexec', 'local' (ambiguous!)
  → Lookahead with remaining segment 'b':

    - Try /usr/lib + 'b': no match
    - Try /usr/libexec + 'b': no match
    - Try /usr/local + 'b': matches 'bin' ✓

  → Only ONE path succeeded
  → Current: /usr/local/bin

Step 3: No more segments
  → Result: /usr/local/bin/
```

### Performance

- Only activates for paths containing `/`
- Skips expansion for paths that look complete (e.g., ending in `.zig`, `/`)
- Uses stack buffers to avoid allocations
- Early exit on ambiguous segments

## Configuration

Mid-word completion is enabled by default and works automatically in all path contexts:

- File arguments
- Directory navigation (`cd`, `pushd`)
- Command completion with paths

## Differences from zsh

Den's implementation provides the core functionality of zsh's mid-word completion with some enhancements:

**What Den does (like zsh):**

- ✅ Expands unambiguous abbreviated path segments
- ✅ Multi-segment lookahead to resolve ambiguity
- ✅ Works with both absolute and relative paths
- ✅ Handles special directories (`.`, `..`)
- ✅ Intelligent path traversal and matching
- ✅ **Text replacement** (replaces abbreviation, doesn't append)

**What Den does differently:**

- ✅ Simpler, more predictable behavior
- ✅ Single unique path expansion (not multiple candidates)
- ✅ Clear success/failure semantics

**What zsh additionally does:**

- Multiple ambiguous path expansions (shows all possible full paths)
- Fuzzy matching with approximate completion
- More sophisticated matching heuristics
- Highly configurable expansion rules
- Menu-based selection for multiple matches

## Future Enhancements

Potential improvements for mid-word completion:

1. **Fuzzy matching**: Match segments that aren't just prefixes
2. **Multiple path candidates**: Show all possible expansions when ambiguous
3. **Smart abbreviation**: Learn common abbreviations (e.g., `doc` → `Documents`)
4. **Configuration options**: Allow users to disable or customize behavior
5. **Case-insensitive expansion**: Match regardless of case

## Technical Notes

### Safety

- Validates paths don't contain null bytes
- Uses bounded buffers to prevent overflows
- Gracefully handles inaccessible directories

### Memory Management

- Uses stack buffers where possible (`std.fs.max_path_bytes`)
- Allocates only for final results
- Properly cleans up temporary allocations

### Edge Cases

- Empty paths: returns null (no expansion)
- Single-component paths: no expansion needed
- Paths ending in `/`: treated as complete, no expansion
- Hidden files: only expanded if explicitly prefixed with `.`

## Testing

To test mid-word completion:

```bash
# Create test directory structure
mkdir -p /tmp/test_completion/unique_dir/subdir
cd /tmp/test_completion

# Test in den shell
./zig-out/bin/den
❯ cd u/s<TAB>  # Should expand to unique_dir/subdir/
```

## See Also

- [Tab Completion](./COMPLETION.md) - General completion documentation
- [ZSH Comparison](./ZSH_COMPARISON.md) - Feature comparison with zsh
- Source: `src/utils/completion.zig`
