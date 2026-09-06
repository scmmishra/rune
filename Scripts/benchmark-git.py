"""Compare sequential Git work for an ordinary content-only refresh, without writes."""

import os
import statistics
import subprocess
import sys
import time

root = sys.argv[1]
environment = dict(os.environ, GIT_OPTIONAL_LOCKS="0")
status = ["status", "--porcelain=v1", "-z", "--branch", "--untracked-files=all"]
diffs = [
    ["diff", "--cached", "--numstat", "-z", "--no-renames"],
    ["diff", "--numstat", "-z", "--no-renames"],
]
previous = [status] + diffs + [
    ["log", "--max-count=50", "-z", "--format=%H%x1f%h%x1f%an%x1f%ar%x1f%s"],
    ["ls-files", "--cached", "--others", "--exclude-standard", "-z"],
    ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored=no"],
]
sequences = [("previous", previous), ("shared", [status] + diffs)]
results = {name: [] for name, _ in sequences}
for iteration in range(9):
    for name, commands in sequences if iteration % 2 == 0 else reversed(sequences):
        start = time.perf_counter()
        for command in commands:
            subprocess.run(
                ["git", "-C", root] + command,
                env=environment,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=True,
            )
        if iteration:
            results[name].append((time.perf_counter() - start) * 1000)
for name, samples in results.items():
    print(f"{name}: median {statistics.median(samples):.1f} ms, "
          f"range {min(samples):.1f}–{max(samples):.1f} ms")
