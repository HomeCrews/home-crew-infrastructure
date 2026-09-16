#!/bin/sh
# Check: the current branch follows the HomeCrew naming convention.
set -eu
. "$(dirname "$0")/../common.sh"

info "checking branch name..."
check_branch_name "$(current_branch)"
ok "branch name valid"
