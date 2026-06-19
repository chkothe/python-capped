# python-capped

A tiny wrapper that runs a virtualenv's Python under a **hard, cgroup-enforced
RAM cap**, so a runaway scientific-Python job gets OOM-killed cleanly the moment
it crosses the limit — instead of thrashing the machine into a frozen,
unresponsive state.

> This will **not** be actively maintained by the author; feel free to fork this repo to add custom functionality.

## The problem

On Linux, a process that allocates more memory than is physically free doesn't
fail fast. The kernel evicts page cache, then pages anonymous memory to swap,
then starts evicting the *clean executable pages* of everything running —
including the desktop and the input handler. Under severe pressure, pages are
faulted back in as fast as they're evicted, so the machine spends ~all its time
on disk I/O and ~none doing useful work: a **thrash/livelock** in which even the
mouse cursor freezes. The kernel's OOM killer is a last resort and often won't
fire for minutes, because the system is technically still "making progress."

## The fix

Run the job inside a transient **systemd scope** with a memory limit:

- A cgroup limit (`MemoryMax`) applies to the **aggregate** of the main process
  *and every subprocess*. It doesn't matter how memory is split across workers,
  or that a killed worker gets respawned — the total ceiling is kernel-enforced,
  so the box can't be tanked.
- `OOMPolicy=kill` sets the kernel's `memory.oom.group=1`, so when the ceiling
  is hit the **entire scope is killed atomically** (no whack-a-mole between a
  parent and its respawning children).
- This is strictly better than `ulimit`/`RLIMIT_AS`, which is per-process and
  trips over the large *virtual* address reservations numpy/BLAS/CUDA make
  without actually touching them.

## Install

Deploy the script into the `bin/` directory of each virtualenv you want to
protect, beside that venv's real `python3`. **Name the deployed file
`python3.99`** — JetBrains IDEs only let you pick interpreters whose filename
looks like `python` / `python3` / `python3.<minor>`, and a non-existent minor
like `.99` satisfies that filter without ever colliding with a real interpreter
(see [JetBrains naming](#jetbrains-naming)). If you only ever run it from the
command line the name is arbitrary.

Copy it in:

```sh
cp python-capped.sh /path/to/venv/bin/python3.99
chmod +x            /path/to/venv/bin/python3.99
```

…or symlink it, so editing the one master copy updates every venv at once (the
master is already executable, so no `chmod` is needed):

```sh
ln -s ~/Devel/python-capped/python-capped.sh /path/to/venv/bin/python3.99
```

The script keys off the directory it is *invoked from* (not the symlink
target), so it always finds the right interpreter for that venv: a symlink in
`venv/bin/` still resolves the sibling `venv/bin/python3`, not whatever lives
beside the master copy. Its deployed name differs from the names it searches for
(`python3`, `python`), so there's no risk of it invoking itself.

## Usage

It activates only when `MEM_CAP` is set; otherwise it's a transparent
pass-through (zero overhead), so it's safe to use as your everyday interpreter.
The examples below use the deployed name `python3.99` from [Install](#install):

```sh
# Capped:
MEM_CAP=48G /path/to/venv/bin/python3.99 my_pipeline.py

# Uncapped (identical to calling python3 directly):
/path/to/venv/bin/python3.99 my_pipeline.py
```

### Environment variables

| Variable   | Example | Meaning                                                                 |
|------------|---------|-------------------------------------------------------------------------|
| `MEM_CAP`  | `48G`   | Hard ceiling (`MemoryMax`). Activation switch; unset ⇒ pass-through.     |
| `MEM_HIGH` | `40G`   | Optional soft ceiling (`MemoryHigh`): throttle + reclaim before the kill.|

### PyCharm

1. **Settings → Project → Python Interpreter → Add → System Interpreter**, and
   point it at the venv's `python3.99` (the shim deployed as in [Install](#install)).
2. In each heavy **Run/Debug configuration → Environment variables**, add
   `MEM_CAP=48G` (and optionally `MEM_HIGH=40G`).

Editing, indexing, the Python console, and package management don't set
`MEM_CAP`, so they run uncapped with no overhead. The **debugger works
unchanged**: `systemd-run --user --scope` adds no PID/network/mount namespace,
so pydevd's localhost socket, stdio, breakpoints, and the propagated exit code
(`137` on OOM-kill) all behave normally.

### JetBrains naming

JetBrains IDEs (PyCharm, IntelliJ with the Python plugin, etc.) only let you
**select an interpreter whose filename looks like a Python binary** — `python`,
`python3`, or `python3.<minor>`. A file named `python-capped.sh` simply won't
show up as selectable. Deploying the shim as **`python3.99`** gets around this:
it matches the pattern, and pinning a minor version that doesn't exist means it
can never be confused with — or shadow — a real `python3.x`. Any unused
`pythonX.Y` works; `3.99` is just a memorable, obviously-fake choice.

The IDE still reports the *real* Python version (e.g. `3.11`), not `3.99`:
during interpreter introspection `MEM_CAP` is unset, so the shim transparently
execs the venv's actual `python3`, and that real interpreter is what the IDE
inspects.

## Requirements

- systemd with **cgroups v2 (unified)** and the **memory controller delegated**
  to the user slice — the default on modern systemd desktops (Ubuntu 22.04+,
  Fedora, etc.). Check with:
  ```sh
  stat -fc %T /sys/fs/cgroup                       # -> cgroup2fs
  cat /sys/fs/cgroup/user.slice/cgroup.controllers # -> includes "memory"
  ```

## Complementary measures

This wrapper protects jobs you launch through it. As additional safety measures
on the whole system, also consider:

- A PSI-based early-OOM daemon as a system-wide safety net — `systemd-oomd`
  (cgroup-granular; the natural fit) or `earlyoom -g` (process-group-granular).
- Disabling a small disk swapfile, which mostly just prolongs the thrash when an
  overshoot dwarfs total RAM.
- Enabling the SysRq OOM key (`kernel.sysrq` bit 64) so `Alt+SysRq+f` can kill
  the largest task by hand even when the GUI is wedged.

## License
This project is licensed under the BSD 3-Clause License. See the [LICENSE](LICENSE) file for details.
