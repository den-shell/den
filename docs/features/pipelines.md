# Pipelines

A pipeline connects the standard output of one command to the standard input of the next with `|`. Den runs every stage concurrently and returns the exit status of the **last** stage.

```bash
# Count Zig files
ls *.zig | wc -l

# Multi-stage transform
cat access.log | grep ERROR | sort | uniq -c | sort -rn | head
```

## How it works

Each stage runs as its own process, wired together with pipes:

```bash
ps aux | grep den | grep -v grep
```

Builtins participate in pipelines too — both as producers and consumers:

```bash
echo "hello world" | tr a-z A-Z      # builtin echo into external tr
history | grep git                    # builtin history into a filter
```

## Exit status

The pipeline's exit code is that of the last command:

```bash
false | true ; echo $?    # 0  (true's status)
true | false ; echo $?    # 1  (false's status)
```

To fail when *any* stage fails, enable `pipefail`:

```bash
setopt pipefail
grep missing file | sort ; echo $?   # non-zero if grep finds nothing
```

`PIPESTATUS` holds the exit code of every stage:

```bash
false | true | false
echo ${PIPESTATUS[@]}     # 1 0 1
```

## Combining with other operators

Pipelines compose with `&&`, `||`, and `;`:

```bash
grep -q TODO file && echo "has todos" | tee todos.flag
```

They can also run in the background — see [Job Control](./job-control.md):

```bash
sort huge.txt | uniq > out.txt &
```

## See also

- [Redirections](./redirections.md) — sending stdin/stdout/stderr to files
- [Job Control](./job-control.md) — backgrounding pipelines
- [Features overview](../FEATURES.md)
