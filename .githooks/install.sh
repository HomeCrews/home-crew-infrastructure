#!/bin/sh
# Points git at the versioned hooks in .githooks/.
#
# Normally you do not need to run this: the Maven build invokes
# `git config core.hooksPath .githooks` directly at the initialize phase, on
# every platform. This script exists for repos with no Maven build, and for
# setting the hooks up without running a build first.
#
# Safe to run repeatedly, and a no-op outside a git work tree.

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

# Unix only, and only a fallback: the executable bit is recorded in the index
# (mode 100755), so a normal clone already has it. Windows has no such bit and
# Git for Windows runs hooks through its bundled sh regardless.
for hook in pre-commit commit-msg pre-push; do
    [ -f ".githooks/$hook" ] && chmod +x ".githooks/$hook" 2>/dev/null || true
done
for check in .githooks/checks/*.sh; do
    [ -f "$check" ] && chmod +x "$check" 2>/dev/null || true
done

exit 0
