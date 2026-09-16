#!/bin/sh
# Check: the commit message follows Conventional Commits.
#
# Argument: path to the commit message file (passed through from commit-msg).
set -eu
. "$(dirname "$0")/../common.sh"

msg_file="${1:-}"
[ -n "$msg_file" ] || fail "no commit message file supplied"
[ -f "$msg_file" ] || fail "commit message file not found: $msg_file"

info "checking commit message..."

# First line that is neither blank nor a comment is the subject.
subject=$(grep -v '^#' "$msg_file" | grep -v '^[[:space:]]*$' | head -n 1 || true)

[ -z "$subject" ] && fail "empty commit message."

# git-generated messages we do not police.
case "$subject" in
    "Merge "*|"Revert "*|"fixup! "*|"squash! "*|"Applied "*)
        ok "generated commit message; skipped"
        exit 0
        ;;
esac

TYPES='feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert'
PATTERN="^($TYPES)(\([a-z0-9._/-]+\))?!?: .+"

if ! printf '%s' "$subject" | grep -Eq "$PATTERN"; then
    fail "commit message does not follow Conventional Commits." \
        "  Got:       $subject" \
        "" \
        "  Required:  <type>[(scope)][!]: <description>" \
        "  Types:     feat, fix, docs, style, refactor, perf, test," \
        "             build, ci, chore, revert" \
        "" \
        "  Examples:" \
        "    feat: add spotless and checkstyle gates" \
        "    fix(auth): reject expired refresh tokens" \
        "    chore(deps)!: drop support for Java 21"
fi

# Keep subjects readable in git log --oneline and the GitHub UI.
subject_len=$(printf '%s' "$subject" | wc -c | tr -d ' ')
if [ "$subject_len" -gt 100 ]; then
    fail "commit subject is ${subject_len} characters; the limit is 100." \
        "  Move the detail into the commit body: leave a blank line after" \
        "  the subject, then write as much as you like."
fi

ok "commit message valid"
