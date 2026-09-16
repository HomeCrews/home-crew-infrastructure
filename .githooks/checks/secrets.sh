#!/bin/sh
# Check: no secrets in the staged content.
#
# Scans what is about to be committed rather than the whole history, so it
# stays fast on every commit.
set -eu
. "$(dirname "$0")/../common.sh"

info "scanning staged changes for secrets..."

require_gitleaks

# gitleaks renamed its subcommands in 8.19: `protect --staged` became
# `git --staged`, and the old name is deprecated. Prefer the modern form and
# fall back, so the same hook works across the versions people actually have
# installed on macOS, Windows and Linux.
if gitleaks git --help >/dev/null 2>&1; then
    set -- git --staged
else
    set -- protect --staged
fi

# --exit-code makes the leak signal explicit: 1 means secrets were found,
# anything else non-zero means gitleaks itself failed (bad flag, bad config,
# missing binary). Those are different problems and deserve different
# messages - conflating them is how a broken tool masquerades as a clean
# scan, or as a leak that does not exist.
set +e
gitleaks "$@" --redact --no-banner --log-level error --exit-code 1
status=$?
set -e

if [ $status -eq 1 ]; then
    fail "gitleaks found a secret in your staged changes." \
        "  The finding is printed above with the value redacted." \
        "" \
        "  If it is a real credential: remove it, then ROTATE it. Anything" \
        "  that reached a remote must be considered compromised." \
        "" \
        "  If it is a false positive, add a narrow rule to .gitleaks.toml or" \
        "  append the  gitleaks:allow  comment to that specific line."
elif [ $status -ne 0 ]; then
    fail "gitleaks failed to run (exit $status); the scan did not complete." \
        "  This is a tooling problem, not a detected secret." \
        "" \
        "  Check your gitleaks version and any .gitleaks.toml in this repo:" \
        "    gitleaks version" \
        "    gitleaks git --staged --no-banner" \
        "" \
        "  The commit is blocked because an unverified scan is not a pass."
fi

ok "no secrets detected"
