# Job Control

Den manages background and suspended commands as **jobs**, with the standard POSIX job-control builtins.

## Running in the background

Append `&` to start a command without waiting for it:

```bash
sleep 30 &
[1] 12345           # job number and PID
```

## Listing jobs

```bash
jobs
[1]+ Running    sleep 30 &
```

## Suspending and resuming

- **Ctrl+Z** suspends the foreground job (it becomes Stopped).
- `bg [%n]` resumes a stopped job in the background.
- `fg [%n]` brings a job to the foreground.

```bash
sleep 60          # press Ctrl+Z
[1]+ Stopped    sleep 60
bg %1             # resume in background
fg %1             # pull back to the foreground
```

## Job specifiers

| Spec | Refers to |
|---|---|
| `%n` | job number `n` |
| `%+` / `%%` | current job |
| `%-` | previous job |

## Waiting and signalling

```bash
wait              # wait for all background jobs
wait %1           # wait for a specific job
kill %1           # send SIGTERM to a job
kill -9 %1        # force kill
disown %1         # remove a job from the table (won't be killed on exit)
```

## Backgrounding pipelines

Whole [pipelines](./pipelines.md) can be backgrounded:

```bash
sort huge.txt | uniq -c > counts.txt &
```

## See also

- Builtins: `jobs`, `fg`, `bg`, `wait`, `kill`, `disown` — see [Builtins](../BUILTINS.md)
- [Features overview](../FEATURES.md)
