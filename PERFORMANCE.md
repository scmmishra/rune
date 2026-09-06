# Performance work

## September 2026

The workspace now owns a single watcher and repository model. The file tree and
Quick Open consume its file index; the tree derives file status from the same
snapshot as the Git sidebar. Ordinary content changes reuse the index and commit
history. Structural filesystem events, Git metadata events, dropped events, and
explicit Git operations invalidate caches. Relative commit dates refresh on the
next repository refresh after 60 seconds.

Quick Open reopening requires no additional file-list subprocess. Tree rows are
flattened only when the tree or expanded folders change. Diff previews retain
their native editor and cache up to four small diff results, invalidated by
workspace events and Git operations.

File preview reads and decoding run off the main actor. Highlighting runs in a
serial background actor, reuses edited Tree-sitter trees, and coalesces typing
with a 60 ms delay. Stale results are discarded. Only differing attribute runs
are applied to NSTextStorage, preserving text, selection, and undo history.
Highlight queries still cover the full document; this is not viewport-only
highlighting.

### Measurement

On the local Chatwoot checkout, compared the Git subprocess portion of an
ordinary content-only refresh: previous tree + sidebar sequence (six commands)
against the shared sequence with warm index/history caches (three commands).
Used one warm-up and eight samples, alternating order, with
GIT_OPTIONAL_LOCKS=0 and output discarded:

| Sequence | Median | Range |
| --- | --- | --- |
| Previous | 286.7 ms | 281.4–323.3 ms |
| Shared, warm caches | 124.0 ms | 122.4–133.0 ms |

This measures combined sequential Git subprocess cost, not UI latency or frame
rate. The old tree and sidebar could run concurrently. Cold refreshes still load
the index and history. No end-to-end speedup percentage is claimed.
Reproduce with `python3 Scripts/benchmark-git.py /path/to/repository`.

### Verification

Build Debug and Release with xcodebuild. After `mise run build`, run
`bash Scripts/check-highlighting.sh` to compare incremental highlighting against
fresh parsing for Swift, Ruby, and Go across Unicode, multiline, CRLF, deletion,
and restoration edits.

Remaining profiling work: Release UI traces for typing in very large documents,
resizing, scroll frame times, sustained log/build activity, and idle energy use.
Metal and control replacements are not needed for this batch of changes.
