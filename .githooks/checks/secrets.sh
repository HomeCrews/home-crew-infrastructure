#!/bin/sh
# Check: no secrets in the staged content.
#
# Uses `gitleaks protect --staged`, which scans what is about to be committed
# rather than the whole history, so it stays fast on every commit.
set -eu
. "$(dirname "$0")/../common.sh"

info "scanning staged changes for secrets..."

require_gitleaks

if ! gitleaks protect --staged --redact --no-banner --quiet; then
    fail "gitleaks found a secret in your staged changes." \
        "  The finding is printed above with the value redacted." \
        "" \
        "  If it is a real credential: remove it, then ROTATE it. Anything" \
        "  that reached a remote must be considered compromised." \
        "" \
        "  If it is a false positive, add a narrow rule to .gitleaks.toml or" \
        "  append the  gitleaks:allow  comment to that specific line."
fi

ok "no secrets detected"
