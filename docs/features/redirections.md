# Redirections

Redirections send a command's input and output to files or other file descriptors. Den supports the full set of POSIX redirection operators.

## Output

```bash
echo "hello" > file.txt      # overwrite (truncate)
echo "world" >> file.txt     # append
```

With `noclobber` set, `>` refuses to overwrite an existing file; use `>|` to force:

```bash
setopt noclobber
echo hi > existing.txt        # error: file exists
echo hi >| existing.txt       # forced overwrite
```

## Input

```bash
sort < unsorted.txt           # read stdin from a file
```

### Here-documents

Feed a block of text to a command's stdin:

```bash
cat <<EOF
line one
line two
EOF
```

### Here-strings

Feed a single string to stdin:

```bash
grep foo <<< "foo bar baz"
```

## Standard error

```bash
cmd 2> errors.log             # redirect stderr to a file
cmd 2>> errors.log            # append stderr
cmd 2>&1                      # merge stderr into stdout
cmd > all.log 2>&1            # both streams to one file
cmd 2>/dev/null               # discard stderr
```

> Order matters: `> all.log 2>&1` sends stdout to the file, then points stderr at the same place. `2>&1 > all.log` would send stderr to the *original* stdout (the terminal).

## Combining redirections

Redirections work alongside [pipelines](./pipelines.md):

```bash
make 2>&1 | tee build.log     # capture stdout+stderr to a file and the screen
```

## See also

- [Pipelines](./pipelines.md)
- [Features overview](../FEATURES.md)
