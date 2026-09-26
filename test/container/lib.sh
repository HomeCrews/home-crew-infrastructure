# Sourced by the container-side scripts in test/container/. POSIX sh: it runs
# under dash in homecrew-dev-runtime:jdk25 and busybox ash in node:24-alpine.
#
# Results go to stdout as one line each, which test/lib/Harness.ps1
# (Import-HcResults) turns into report rows:
#
#     HCRESULT<TAB><id><TAB><PASS|FAIL|SKIP|BLOCKED|WARN|INFO|WEAK><TAB><message>
#
# Everything else a script prints is evidence, saved as-is.

HC_FAILED=0

hc_result() {
    # Tabs and newlines inside a message would break the line format.
    _m=$(printf '%s' "$3" | tr '\t\n\r' '   ')
    printf 'HCRESULT\t%s\t%s\t%s\n' "$1" "$2" "$_m"
}
hc_pass() { hc_result "$1" PASS "$2"; }
hc_fail() { hc_result "$1" FAIL "$2"; HC_FAILED=1; }
hc_skip() { hc_result "$1" SKIP "$2"; }
hc_warn() { hc_result "$1" WARN "$2"; }
hc_info() { hc_result "$1" INFO "$2"; }

# hc_check <id> <message> <command...>: PASS if the command succeeds.
hc_check() {
    _id=$1; _msg=$2; shift 2
    if "$@"; then hc_pass "$_id" "$_msg"; else hc_fail "$_id" "$_msg"; fi
}

# hc_eq <id> <what> <expected> <actual>
hc_eq() {
    if [ "$3" = "$4" ]; then hc_pass "$1" "$2: $4"
    else hc_fail "$1" "$2: expected '$3', got '$4'"; fi
}

# Replace secret-looking values in piped text: anything after TOKEN=,
# PASSWORD=, ENCRYPT_KEY= or SECRET= up to the end of the word.
hc_redact() {
    sed -E 's/((TOKEN|PASSWORD|ENCRYPT_KEY|SECRET)[A-Z_]*=)[^[:space:]]*/\1<redacted>/g'
}

# For one KEY=VALUE per line - /proc/<pid>/environ, a properties dump: the
# whole value is replaced, spaces included, and keys match in any case and
# with dots (spring.datasource.password=...).
hc_redact_lines() {
    sed -E 's/^([A-Za-z0-9_.-]*([Tt][Oo][Kk][Ee][Nn]|[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]|[Ee][Nn][Cc][Rr][Yy][Pp][Tt]_?[Kk][Ee][Yy]|[Ss][Ee][Cc][Rr][Ee][Tt])[A-Za-z0-9_.-]*=).*/\1<redacted>/'
}

hc_exit() { exit "$HC_FAILED"; }

# The last line of a script that got to its end, just before hc_exit. A script
# killed half-way also exits non-zero, so without this line the harness could
# not tell "finished, some cases failed" from "stopped, later cases never ran".
hc_done() { printf 'HCDONE\t%s\n' "$1"; }
