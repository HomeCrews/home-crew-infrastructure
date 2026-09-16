#!/bin/sh
# Check: staged Java is already formatted to the project style.
#
# This never edits your files. Spotless runs in :check mode and the hook tells
# you the command to fix it, so a commit only ever contains bytes you have seen.
set -eu
. "$(dirname "$0")/../common.sh"

# Only pay for a JVM start-up when Java actually changed.
staged_java=$(git diff --cached --name-only --diff-filter=ACMR | grep -E '\.java$' || true)

if [ -z "$staged_java" ]; then
    ok "no Java staged; skipped formatting check"
    exit 0
fi

is_maven_repo || exit 0

MVNW=$(mvn_wrapper) || fail "no Maven wrapper (./mvnw) and no mvn on PATH."

info "checking formatting with Spotless..."

# Spotless prints the entire offending file on a violation, which buries the
# useful line. Capture the output and surface only the paths.
# (Same trick as efm-applexm's pre-commit-check-spotless-formatting.sh.)
set +e
output=$("$MVNW" --batch-mode spotless:check 2>&1)
status=$?
set -e

if [ $status -ne 0 ]; then
    printf '\n  Unformatted files:\n' >&2
    printf '%s\n' "$output" \
        | grep -oE '[^ ]*\.java' \
        | sort -u \
        | sed 's|^|    |' >&2

    fail "Spotless found unformatted code." \
        "  Fix it with:" \
        "    ./mvnw spotless:apply" \
        "" \
        "  Then re-stage and commit again:" \
        "    git add -u && git commit"
fi

ok "formatting clean"
