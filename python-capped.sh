#!/bin/sh
# python-capped.sh — run a venv's Python under a hard RAM cap (cgroup-enforced).
#
# Drop (copy or symlink) this script into a virtualenv's bin/ directory, beside
# that venv's `python3`. When invoked, it locates the interpreter sitting next
# to itself and execs it. If the environment variable MEM_CAP is set, the
# interpreter is launched inside a transient systemd scope with a hard memory
# limit, so a runaway run — together with all of its subprocesses — is
# OOM-killed as a single unit the instant it exceeds the cap, instead of
# thrashing swap/file-cache and freezing the whole machine.
#
# Why a scope and not ulimit: a cgroup limit applies to the *aggregate* of the
# main process plus every child, and `OOMPolicy=kill` (-> memory.oom.group=1)
# tears the whole group down atomically, so a killed worker can't just be
# respawned to refill the ceiling. ulimit/RLIMIT_AS, by contrast, is per-process
# and trips over the large virtual reservations numpy/BLAS/CUDA make.
#
# Knobs (all via environment variables):
#   MEM_CAP   e.g. 48G  Hard ceiling (cgroup MemoryMax). This is the activation
#                       switch: if unset, the script is a transparent pass-
#                       through to the real interpreter (zero overhead — good
#                       for IDE introspection, the Python console, pip, etc.).
#   MEM_HIGH  e.g. 40G  Optional soft ceiling (cgroup MemoryHigh): above this the
#                       kernel throttles and reclaims aggressively as an early
#                       brake, before the hard kill at MEM_CAP.
#
# Preflight: when MEM_CAP is set, the launch is refused up-front (exit 75) if
# available memory right now is below MEM_CAP. The cgroup cap bounds only this
# job, so it can't stop the box being driven OOM by this job plus what's
# already resident; this guard does. The decision uses MemAvailable (counts
# reclaimable cache as headroom); see the preflight block to switch to MemFree.
#
# PyCharm: set this script as the project interpreter, then add `MEM_CAP=48G`
# to the run/debug configuration's Environment variables. Only those runs are
# capped. The debugger works unchanged: a --user --scope adds no PID/network/
# mount namespace, so pydevd's localhost socket, stdio, and the exit code (137
# on OOM-kill) all pass through normally.
#
# CLI: MEM_CAP=48G /path/to/venv/bin/python-capped.sh my_pipeline.py
#
# Requires: systemd with cgroups v2 and the memory controller delegated to the
# user slice (the default on modern systemd desktops, incl. Ubuntu 22.04+).

set -eu

# --- locate the interpreter sitting beside this script ----------------------
# We use the directory the script was *invoked* from (dirname of $0, made
# absolute) rather than resolving symlinks. That way a symlink placed in a
# venv's bin/ still looks for python in that venv's bin/, not wherever the
# master copy lives — so both `cp` and `ln -s` deployment work as expected.
# The interpreter names we look for differ from this script's name, so there
# is no risk of the wrapper invoking itself.
bindir=$(cd "$(dirname "$0")" && pwd) || {
    echo "python-capped.sh: cannot determine own directory" >&2
    exit 1
}

real=
for cand in python3 python; do
    if [ -x "$bindir/$cand" ]; then
        real="$bindir/$cand"
        break
    fi
done
if [ -z "$real" ]; then
    echo "python-capped.sh: no python3/python executable found beside $bindir" >&2
    echo "  (copy this script into a venv's bin/ directory, next to its python)" >&2
    exit 127
fi

# --- no cap requested: transparent pass-through -----------------------------
if [ -z "${MEM_CAP:-}" ]; then
    exec "$real" "$@"
fi

# --- cap requested: preflight on currently-available memory ----------------
# The cgroup cap bounds only our own usage; it does nothing about the box being
# driven OOM by this job plus everything else already resident. So if available
# memory is already below the ceiling we'd grant ourselves, bail rather than
# risk a system-wide squeeze. MemAvailable is used (reclaimable cache counts as
# headroom); switch `avail_bytes` to `free_bytes` at the marked line to instead
# require that much *unused* RAM, ignoring reclaimable cache.
preflight_bytes() {           # systemd-style size (48G / 512M / 50% / bytes) -> bytes
    v=$1
    case "$v" in
        *%)     t=$(awk '/^MemTotal:/{print $2; exit}' /proc/meminfo); [ -n "$t" ] || return 1
                echo $(( t * 1024 * ${v%\%} / 100 )) ;;
        *[Kk])  echo $(( ${v%?} * 1024 )) ;;
        *[Mm])  echo $(( ${v%?} * 1024 * 1024 )) ;;
        *[Gg])  echo $(( ${v%?} * 1024 * 1024 * 1024 )) ;;
        *[Tt])  echo $(( ${v%?} * 1024 * 1024 * 1024 * 1024 )) ;;
        *[0-9]) echo "$v" ;;
        *)      return 1 ;;
    esac
}
human() { awk -v b="$1" 'BEGIN{ printf "%.1f GiB", b/1073741824 }'; }

if cap_bytes=$(preflight_bytes "$MEM_CAP"); then
    free_kb=$(awk '/^MemFree:/{print $2; exit}' /proc/meminfo)
    avail_kb=$(awk '/^MemAvailable:/{print $2; exit}' /proc/meminfo)
    if [ -n "${free_kb:-}" ]; then
        free_bytes=$(( free_kb * 1024 ))
        avail_bytes=$(( ${avail_kb:-0} * 1024 ))
        if [ "$avail_bytes" -lt "$cap_bytes" ]; then  # <-- decision metric (avail_bytes | free_bytes)
            echo "python-capped.sh: refusing to launch — available memory $(human "$avail_bytes") is below MEM_CAP ($(human "$cap_bytes"))." >&2
            echo "  (MemAvailable $(human "$avail_bytes") incl. reclaimable cache; MemFree $(human "$free_bytes").) Free some memory and retry." >&2
            exit 75   # EX_TEMPFAIL: the job is fine, there just isn't RAM right now
        fi
    else
        echo "python-capped.sh: /proc/meminfo unreadable; skipping preflight" >&2
    fi
else
    echo "python-capped.sh: could not parse MEM_CAP='$MEM_CAP' for preflight; skipping" >&2
fi

# --- launch inside a transient memory-limited scope -------------------------
if ! command -v systemd-run >/dev/null 2>&1; then
    echo "python-capped.sh: MEM_CAP set but systemd-run not found; running uncapped" >&2
    exec "$real" "$@"
fi

props="-p MemoryMax=$MEM_CAP -p OOMPolicy=kill"
if [ -n "${MEM_HIGH:-}" ]; then
    props="$props -p MemoryHigh=$MEM_HIGH"
fi

# shellcheck disable=SC2086  # $props is intentionally word-split into flags
exec systemd-run --user --scope --quiet --collect \
    --description="python-capped (MemoryMax=$MEM_CAP)" \
    $props -- "$real" "$@"
