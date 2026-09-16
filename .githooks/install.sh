#!/bin/sh
# Points git at the versioned hooks in .githooks/.
#
# Run automatically at Maven's initialize phase, so a fresh clone is protected
# the first time anyone builds. Safe to run repeatedly, and a no-op outside a
# git work tree (Docker builds, source tarballs, CI archive checkouts).

set -eu

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
cd "$root" || exit 0

[ -d .githooks ] || exit 0

# Git honours core.hooksPath from 2.9 onward.
current=$(git config --local --get core.hooksPath 2>/dev/null || true)
if [ "$current" != ".githooks" ]; then
    git config --local core.hooksPath .githooks
    printf '[hooks] core.hooksPath -> .githooks\n' >&2
fi

# Clones do not preserve the executable bit reliably across all platforms.
for hook in pre-commit commit-msg pre-push; do
    [ -f ".githooks/$hook" ] && chmod +x ".githooks/$hook" 2>/dev/null || true
done
for check in .githooks/checks/*.sh; do
    [ -f "$check" ] && chmod +x "$check" 2>/dev/null || true
done

exit 0
