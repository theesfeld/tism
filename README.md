# tism

`tism` is POSIX [`time`](https://pubs.opengroup.org/onlinepubs/9699919799/utilities/time.html) for x86-64 Linux, written in assembly. The binary is static. It does not link libc. Every kernel call is a `syscall` instruction.

## Build

GNU binutils on x86-64 Linux. `as` assembles `tism.s` and `ld` links it.

```sh
make
```

That writes `./tism`. `make clean` removes the binary and `tism.o`.

## Usage

```text
tism [-p] utility [argument...]
```

The report goes to standard error. The utility's own output is left as it is.

The default report is the traditional shell rendering. Each line is a label, a tab, then minutes, seconds, and three digits of fraction:

```text
$ tism sleep 0.05
real	0m0.051s
user	0m0.001s
sys	0m0.000s
```

`-p` selects the POSIX format. Each line is a label, a space, and seconds with two digits after the decimal:

```text
$ tism -p true
real 0.00
user 0.00
sys 0.00
```

`--` ends the options, so a utility whose name starts with `-` can be timed.

A name that contains no `/` is searched on `PATH`. When `PATH` is unset, the search uses:

```text
/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
```

An empty `PATH` component means the current directory.

`tism` exits with the utility's status. A utility killed by a signal exits as `128` plus the signal number, the same way a shell does. `SIGTERM` is 143.

When the utility cannot be executed, `tism` still prints the report, then exits 126 or 127:

```text
$ tism definitely-not-a-command
tism: definitely-not-a-command: No such file or directory
real	0m0.000s
user	0m0.000s
sys	0m0.000s
```

| Status | Meaning |
| --- | --- |
| utility status | The utility ran. A signal death is `128` plus the signal number. |
| 126 | The name was found, and `exec` failed. A directory is reported as "Is a directory". |
| 127 | The utility was not found. |
| 1 | The command line was wrong, or `tism` itself failed (`clock_gettime`, `pipe`, `fork`, or `wait`). |

A utility that runs and then exits 126 or 127 keeps that status. Those two codes mean "could not execute" only when `exec` failed.

## What is measured

Wall time is `CLOCK_MONOTONIC`, taken before `fork` and again after `wait4`. User time and system time come from the `rusage` `wait4` fills in: the child, plus descendants that child has waited for.

Parent and child share a pipe opened with `O_CLOEXEC`. A successful `exec` closes the write end, so the parent reads end-of-file. A failed `exec` writes its errno down the pipe and exits. That keeps "the utility exited 127" distinct from "the utility was not found".

## Requirements

- x86-64 Linux
- GNU `as` and `ld`

No C compiler. No libc.
