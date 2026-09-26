#!/bin/sh
# Suite E (parity): prints the launch facts of ONE running application JVM, so
# that test/java/LaunchDiff.java can compare the OLD launch (spring-boot:run,
# from the baseline dev-reload.sh) with the NEW one (java, from today's).
#
#     docker exec <container> sh /test/container/capture-launch.sh <main class>
#
# Everything comes from the live process - jcmd and /proc - and nothing from
# the scripts that started it. The question is what the JVM actually got, not
# what a script meant to give it: a quoting slip, a flag in the wrong order or
# a variable exported by accident only shows up here.
#
# Output is plain text on stdout, one ==section== header per fact, saved as
# evidence by test/lib/SuiteParity.ps1. Nothing here is a verdict; the diff is.
#
# Exit status: 0 = every section captured; 1 = at least one section failed
# (its text says why, the rest is still printed); 2 = usage; 3 = not exactly
# one JVM runs <main class>, which the suite retries, since an application the
# baseline script is restarting after a crash is briefly not there at all;
# 4 = jcmd -l failed, and nothing was captured.
#
# HC_SALT, from the harness through `docker exec -e HC_SALT` (the docker CLI's
# environment, never an argument list): keys the hashes that stand in for
# secret values in the environ section.
#
# POSIX sh; runs under dash in homecrew-dev-runtime:jdk25.

set -u

HERE=$(dirname "$0")
# shellcheck source=lib.sh
. "$HERE/lib.sh"

# For test/ only: lets the parsing below be exercised against a fake /proc on
# a machine that has none. Inside the dev image it is always /proc.
PROC=${HC_PROC:-/proc}
JCMD=${HC_JCMD:-${JAVA_HOME:+$JAVA_HOME/bin/}jcmd}

MAIN=${1:-}
if [ -z "$MAIN" ] || [ $# -ne 1 ]; then
    echo "usage: capture-launch.sh <fully.qualified.MainClass>" >&2
    exit 2
fi

RC=0
section() { printf '==%s==\n' "$1"; }
failed()  { printf '!! %s\n' "$1"; RC=1; }

# jcmd -l prints "<pid> <main class> <arguments...>" for every JVM in this pid
# namespace: the application, and in the OLD launch the Maven JVM that forked
# it (org.codehaus.plexus.classworlds.launcher.Launcher), plus the mvnd daemon
# and jcmd itself. The main class is the ONLY safe way to tell them apart - the
# Maven JVM's own command line mentions the application's classes directory.
JCMD_L=$("$JCMD" -l 2>&1) || {
    echo "jcmd -l failed: $JCMD_L" >&2
    exit 4
}

# A JVM killed with SIGKILL can leave its hsperfdata entry behind until the
# next JVM of the same user cleans up, so a listed pid only counts if it is
# still a process.
PID="" N=0
for _p in $(printf '%s\n' "$JCMD_L" | awk -v m="$MAIN" '$2 == m { print $1 }'); do
    if [ -d "$PROC/$_p" ]; then PID="$PID $_p"; N=$((N + 1)); fi
done
PID=${PID# }
if [ "$N" -ne 1 ]; then
    echo "expected exactly one running JVM with main class $MAIN, found $N" >&2
    printf '%s\n' "$JCMD_L" >&2
    exit 3
fi

section main
printf '%s\n' "$MAIN"
section pid
printf '%s\n' "$PID"

# jvm_args, java_command and java_class_path (initial), exactly as the JVM
# recorded them at startup.
section vm_command_line
"$JCMD" "$PID" VM.command_line 2>&1 || failed "jcmd $PID VM.command_line failed"

# Sorted, so that two captures diff line by line. Properties.store escaping
# (\: and \n) keeps every property on one line.
section system_properties
_props=$("$JCMD" "$PID" VM.system_properties 2>&1) || failed "jcmd $PID VM.system_properties failed"
printf '%s\n' "$_props" | LC_ALL=C sort

section flags
"$JCMD" "$PID" VM.flags 2>&1 || failed "jcmd $PID VM.flags failed"

# The INITIAL environment: what the process was exec'd with, which is what a
# launch hands over. A value whose name looks like a secret never leaves the
# container: it becomes the first 12 hex digits of sha256(salt, name, value).
# Equal secrets still compare equal between the two captures, a changed or
# emptied one does not, and nothing reversible is stored. Without a salt the
# value is only replaced. The sed then does what lib.sh's hc_redact does for
# a secret quoted INSIDE another value, leaving the hashes alone.
secret_env() {
    while IFS= read -r _line; do
        _k=${_line%%=*}
        case $_k in
          "$_line") ;;
          *[Tt][Oo][Kk][Ee][Nn]* | *[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]* | *[Ss][Ee][Cc][Rr][Ee][Tt]* | \
          *[Ee][Nn][Cc][Rr][Yy][Pp][Tt]_[Kk][Ee][Yy]* | *[Ee][Nn][Cc][Rr][Yy][Pp][Tt][Kk][Ee][Yy]*)
            if [ -n "${HC_SALT:-}" ] && command -v sha256sum >/dev/null 2>&1; then
                _h=$(printf '%s\n%s\n%s' "$HC_SALT" "$_k" "${_line#*=}" | sha256sum | cut -c1-12)
                printf '%s=<redacted:%s>\n' "$_k" "$_h"
            else
                printf '%s=<redacted>\n' "$_k"
            fi
            continue ;;
        esac
        printf '%s\n' "$_line"
    done | sed -E '/^[^=]*=<redacted(:[0-9a-f]+)?>$/!s/((TOKEN|PASSWORD|ENCRYPT_KEY|SECRET)[A-Z_]*=)[^[:space:]]*/\1<redacted>/g'
}
section environ
if [ -r "$PROC/$PID/environ" ]; then
    tr '\0' '\n' <"$PROC/$PID/environ" | LC_ALL=C sort | secret_env
else
    failed "$PROC/$PID/environ is not readable"
fi

# argv as the kernel has it, one argument per line. argv[0] is the one thing
# spring-boot:run spells differently (java.home + bin/java, canonicalised), so
# the exe link below is what is compared; this is evidence.
section cmdline
if [ -r "$PROC/$PID/cmdline" ]; then
    tr '\0' '\n' <"$PROC/$PID/cmdline"
    echo
else
    failed "$PROC/$PID/cmdline is not readable"
fi

for _l in cwd exe fd/0 fd/1 fd/2; do
    section "$(printf %s "$_l" | tr -d /)"
    readlink "$PROC/$PID/$_l" 2>/dev/null || failed "readlink $PROC/$PID/$_l failed"
done

# The parent: the Maven JVM before, the dev-reload.sh shell now.
section ppid
_pp=$(awk '$1 == "PPid:" { print $2 }' "$PROC/$PID/status" 2>/dev/null)
if [ -n "$_pp" ]; then
    printf '%s %s\n' "$_pp" "$(cat "$PROC/$_pp/comm" 2>/dev/null || echo '?')"
    if [ -r "$PROC/$_pp/cmdline" ]; then
        printf 'cmdline: %s\n' "$(tr '\0' ' ' <"$PROC/$_pp/cmdline" | cut -c1-400)"
    fi
else
    failed "no PPid in $PROC/$PID/status"
fi

# Signal dispositions. A command started with & by a non-interactive shell
# begins life with SIGINT and SIGQUIT ignored, and the JVM keeps an inherited
# ignore for its shutdown signals, so this can differ between a JVM forked by
# Maven and one started by sh. Recorded for the diff to report, not to fail on:
# both launches are stopped with SIGTERM.
section sigign
grep '^Sig' "$PROC/$PID/status" 2>/dev/null || failed "no Sig* lines in $PROC/$PID/status"

# The debug port. /proc/<pid>/net/tcp* lists every socket in the container's
# network namespace, so a LISTEN row (state 0A) on port 5005 (hex 138D) alone
# does not say WHO listens - in the OLD launch the Maven JVM shares the
# namespace. The row's inode has to appear among this process's own fds for
# the application to own it.
section jdwp
_rows=$(for _t in tcp tcp6; do
    [ -r "$PROC/$PID/net/$_t" ] || continue
    awk -v t="$_t" 'NR > 1 && $4 == "0A" && $2 ~ /:138D$/ { print t, $2, $10 }' "$PROC/$PID/net/$_t"
done)
if [ -z "$_rows" ]; then
    echo "none"
else
    _fds=$(for _fd in "$PROC/$PID/fd/"*; do readlink "$_fd" 2>/dev/null; done)
    printf '%s\n' "$_rows" | while read -r _t _addr _ino; do
        if printf '%s\n' "$_fds" | grep -qxF "socket:[$_ino]"; then _own=yes; else _own=no; fi
        printf 'listen %s %s inode=%s owned=%s\n' "$_t" "$_addr" "$_ino" "$_own"
    done
fi

# Every JVM in the container, for the "no Maven JVM left" check.
section jcmd_l
printf '%s\n' "$JCMD_L"

# And the command line of each of the others: mvnd 1.x starts its daemon
# through plexus-classworlds, so jcmd -l names it
# org.codehaus.plexus.classworlds.launcher.Launcher like any Maven JVM, and
# only its command line tells the idle build daemon from a Maven client parked
# beside the application.
section jvm_cmdlines
printf '%s\n' "$JCMD_L" | while read -r _p _rest; do
    case $_p in '' | *[!0-9]*) continue ;; esac
    [ "$_p" != "$PID" ] || continue
    case $_rest in *JCmd*) continue ;; esac
    [ -r "$PROC/$_p/cmdline" ] || continue
    printf '%s %s\n' "$_p" "$(tr '\0' ' ' <"$PROC/$_p/cmdline" | cut -c1-800)"
done | hc_redact

exit "$RC"
