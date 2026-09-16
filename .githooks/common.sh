#!/bin/sh
# Shared helpers for the HomeCrew git hooks.
#
# POSIX sh only. No bashisms, no absolute paths, no assumptions about the host
# OS or package manager: these hooks run on whatever machine has the repo.
#
# Structure follows efm-applexm: each hook composes small single-purpose
# scripts from .githooks/checks/ rather than inlining everything, so a check
# can be added, removed or run on its own.

# ---------------------------------------------------------------- output ----

if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RED=$(printf '\033[31m')
    C_YELLOW=$(printf '\033[33m')
    C_GREEN=$(printf '\033[32m')
    C_DIM=$(printf '\033[2m')
    C_OFF=$(printf '\033[0m')
else
    C_RED='' C_YELLOW='' C_GREEN='' C_DIM='' C_OFF=''
fi

hook_name="${HOOK_NAME:-hook}"

info() { printf '%s[%s]%s %s\n' "$C_DIM" "$hook_name" "$C_OFF" "$*" >&2; }
warn() { printf '%s[%s]%s %s\n' "$C_YELLOW" "$hook_name" "$C_OFF" "$*" >&2; }
ok()   { printf '%s[%s]%s %s\n' "$C_GREEN" "$hook_name" "$C_OFF" "$*" >&2; }

fail() {
    printf '\n%s[%s] BLOCKED%s %s\n' "$C_RED" "$hook_name" "$C_OFF" "$1" >&2
    shift
    [ $# -gt 0 ] && printf '%s\n' "$@" >&2
    printf '\n' >&2
    exit 1
}

# ----------------------------------------------------------- branch rules ---

# Approved rule: dev and main are exempt; every other branch must be
#   dev__YYYYmmDD__lower_snake_name
#
# Note this differs slightly from the efm-applexm convention
# (main__YYYYMMDD_<description>, single underscore before the description):
# HomeCrew uses a double underscore in both positions.
BRANCH_PATTERN='^(dev|main)$|^dev__[0-9]{8}__[a-z0-9]+(_[a-z0-9]+)*$'

check_branch_name() {
    _branch="$1"

    # Detached HEAD (rebase, bisect, CI checkout) has no branch to validate.
    [ -z "$_branch" ] && return 0
    [ "$_branch" = "HEAD" ] && return 0

    if ! printf '%s' "$_branch" | grep -Eq "$BRANCH_PATTERN"; then
        fail "branch name '$_branch' does not match the required format." \
            "  Required:  dev__YYYYmmDD__lower_snake_name" \
            "  Example:   dev__$(date +%Y%m%d)__add_spotless_config" \
            "" \
            "  Only 'dev' and 'main' are exempt. Names must be lowercase," \
            "  words joined by single underscores, with a double underscore" \
            "  between each section." \
            "" \
            "  Rename it with:" \
            "    git branch -m dev__$(date +%Y%m%d)__your_change_here"
    fi

    # A syntactically valid date can still be a typo. Borrowed from
    # efm-applexm: only last year, this year and next year are plausible.
    _date=$(printf '%s' "$_branch" | sed -n 's|^dev__\([0-9]\{8\}\)__.*|\1|p')
    [ -z "$_date" ] && return 0

    _year=$(printf '%s' "$_date" | cut -c1-4)
    _month=$(printf '%s' "$_date" | cut -c5-6)
    _day=$(printf '%s' "$_date" | cut -c7-8)
    _now=$(date +%Y)

    if [ "$_year" -lt $((_now - 1)) ] || [ "$_year" -gt $((_now + 1)) ]; then
        fail "branch '$_branch' has an implausible year ($_year)." \
            "  Expected $((_now - 1)), $_now or $((_now + 1)) - looks like a typo."
    fi
    if [ "$_month" -lt 1 ] || [ "$_month" -gt 12 ]; then
        fail "branch '$_branch' has an invalid month ($_month)."
    fi
    if [ "$_day" -lt 1 ] || [ "$_day" -gt 31 ]; then
        fail "branch '$_branch' has an invalid day ($_day)."
    fi
}

current_branch() {
    git symbolic-ref --quiet --short HEAD 2>/dev/null \
        || git rev-parse --abbrev-ref HEAD 2>/dev/null \
        || echo ""
}

# ------------------------------------------------------------------ tools ---

have() { command -v "$1" >/dev/null 2>&1; }

require_gitleaks() {
    have gitleaks && return 0
    fail "gitleaks is not installed, and secret scanning is a required gate." \
        "  Install it with one of:" \
        "    brew install gitleaks" \
        "    apt-get install gitleaks" \
        "    go install github.com/gitleaks/gitleaks/v8@latest" \
        "    https://github.com/gitleaks/gitleaks/releases" \
        "" \
        "  This gate is not optional: a live GitHub token was previously" \
        "  committed to this organisation."
}

# Resolve the Maven wrapper from the repo root.
mvn_wrapper() {
    _root=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
    if [ -x "$_root/mvnw" ]; then
        printf '%s' "$_root/mvnw"
    elif [ -f "$_root/mvnw" ]; then
        chmod +x "$_root/mvnw" 2>/dev/null || true
        printf '%s' "$_root/mvnw"
    elif have mvn; then
        printf 'mvn'
    else
        return 1
    fi
}

# True when the repo is a Maven project.
is_maven_repo() {
    _root=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
    [ -f "$_root/pom.xml" ]
}

# Fail fast when the active JDK is older than the project target. Otherwise the
# build dies deep in the compiler with "release version N not supported", which
# looks like broken code rather than a wrong JAVA_HOME.
check_jdk_version() {
    _root=$(git rev-parse --show-toplevel 2>/dev/null) || return 0
    [ -f "$_root/pom.xml" ] || return 0

    _want=$(sed -n 's|.*<java.version>\([0-9][0-9]*\)</java.version>.*|\1|p' \
        "$_root/pom.xml" | head -1)
    [ -n "$_want" ] || return 0

    _java="java"
    if [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ]; then
        _java="$JAVA_HOME/bin/java"
    fi
    _have=$("$_java" -version 2>&1 | head -1 \
        | sed -n 's/.*version "\([0-9][0-9]*\).*/\1/p')
    [ -n "$_have" ] || return 0

    if [ "$_have" -lt "$_want" ] 2>/dev/null; then
        fail "active JDK is $_have, but this project targets Java $_want." \
            "  The build would fail with \"release version $_want not supported\"." \
            "" \
            "  Point JAVA_HOME at a JDK $_want and try again:" \
            "    macOS:  export JAVA_HOME=\$(/usr/libexec/java_home -v $_want)" \
            "    Linux:  export JAVA_HOME=/path/to/jdk-$_want" \
            "    sdkman: sdk use java $_want.x" \
            "" \
            "  This is an environment problem, not a problem with your change."
    fi
}

# Run one check script from .githooks/checks/, aborting the hook if it fails.
run_check() {
    _script="$(dirname "$0")/checks/$1"
    shift
    [ -f "$_script" ] || fail "missing check script: $_script"
    sh "$_script" "$@" || exit 1
}
