#!/bin/sh
# Entry point for macOS, Linux, WSL and Git Bash.
#
# With PowerShell 7 on PATH this runs the full harness, test/run.ps1, with the
# same arguments. Without it, it runs the two parts that need neither pwsh nor
# docker - the shell syntax checks and the ./dev half of the CLI tests - and
# says what it skipped.

set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
INFRA=$(cd "$HERE/.." && pwd)

if command -v pwsh >/dev/null 2>&1; then
    exec pwsh -NoProfile -File "$HERE/run.ps1" "$@"
fi

printf '%s\n' "pwsh not found: running only the static shell checks and the ./dev side of the CLI tests." \
    "Install PowerShell 7 for the rest (dev.ps1, unit tests in the dev image, and the Docker suites)." >&2

rc=0
sh "$HERE/static/sh-syntax.sh" "$INFRA" || rc=1
sh "$HERE/cli/run-cli.sh" --check || rc=1
exit "$rc"
