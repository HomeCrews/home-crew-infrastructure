#!/bin/sh
# Suite F (stack): looks at ONE running service container of the live dev
# stack from the inside and says what it sees. test/lib/SuiteStack.ps1 copies
# this file, lib.sh and KafkaProbe.java into the container's /tmp with
# `docker cp` - the live containers mount no /test, and nothing is ever written
# into the checkout - and runs it with docker exec:
#
#     sh /tmp/hc-stack/stack-probe.sh probe <service> <main class>
#         F-JDWP-01-<service>      the application's own pid (the one JVM whose
#                                  main class is <main class>) owns the LISTEN
#                                  socket on container port 5005
#         F-VOL-03-<service>       every dev-classpath.txt entry is a file under
#                                  /root/.m2/repository/
#         F-VOL-03-<service>-jvm   and so is every dependency on the RUNNING
#                                  JVM's -cp, which is what actually matters
#         STACKPROBE devino=...    dev:inode of /root/.m2/repository, compared
#                                  across all twelve by the suite (F-VOL-02)
#
#     sh /tmp/hc-stack/stack-probe.sh jdwp-state
#         STACKPROBE listen/established counts for :5005 in this container's
#         network namespace - asked when a host-side JDWP handshake fails, to
#         tell "a debugger is attached" from "broken"
#
#     sh /tmp/hc-stack/stack-probe.sh kafka <service> <KafkaProbe.java> <host:port>
#         F-NET-05-<service>       an AdminClient built from the application's
#                                  own classpath reaches the broker
#
# Results are HCRESULT lines (lib.sh); STACKPROBE<TAB>key=value lines carry the
# facts the suite compares across containers. Everything else is evidence.
#
# Exit status: 0 = nothing failed, 1 = at least one FAIL, 2 = usage.
#
# POSIX sh; runs under dash in homecrew-dev-runtime:jdk25. Nothing in here
# needs the network except the kafka command, and nothing writes anywhere but
# stdout.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"

# Overridable so the parsing below can be exercised against a fake /proc, a
# fake jcmd and a fake checkout on a machine that has none of them. Inside the
# container they are always the real ones.
PROC=${HC_PROC:-/proc}
JCMD=${HC_JCMD:-${JAVA_HOME:+$JAVA_HOME/bin/}jcmd}
JAVA=${HC_JAVA:-${JAVA_HOME:+$JAVA_HOME/bin/}java}
APP=${HC_APP:-/app}
M2=${HC_M2:-/root/.m2}
CP_FILE=$APP/target/dev-classpath.txt
REPO=$M2/repository

# Container port 5005, as /proc/net/tcp writes it: upper-case hex.
JDWP_HEX=138D

usage() {
    echo "usage: stack-probe.sh probe <service> <main class>" >&2
    echo "       stack-probe.sh jdwp-state" >&2
    echo "       stack-probe.sh kafka <service> <KafkaProbe.java> <host:port>" >&2
    exit 2
}

# One STACKPROBE line: key=value pairs separated by tabs, because a value (the
# way the pid was found, say) can contain spaces.
kv() { printf 'STACKPROBE'; printf '\t%s' "$@"; printf '\n'; }

count_lines() { printf '%s\n' "$1" | grep -c . || :; }

# ---------------------------------------------------------------------------
# The application's pid
# ---------------------------------------------------------------------------

# jcmd -l lists every JVM in this pid namespace: the application, a mvnd
# daemon if one is still up, jcmd itself, and a KafkaProbe if one runs. The
# main class is what tells them apart. A JVM that died hard can leave its
# hsperfdata entry behind, so a listed pid only counts if it is a process.
#
# /proc is the fallback, for a JVM that jcmd cannot see (-XX:-UsePerfData, or
# a /tmp it cannot read): a process named java whose argv contains the main
# class as a whole argument, which is how dev-reload.sh launches it.
PID="" PID_HOW="" PID_WHY=""
find_app_pid() {
    PID="" PID_HOW="" PID_WHY=""
    _jl=$("$JCMD" -l 2>/dev/null) || _jl=""
    _n=0 _p=""
    for _c in $(printf '%s\n' "$_jl" | awk -v m="$1" '$2 == m { print $1 }'); do
        if [ -d "$PROC/$_c" ]; then _p="$_p $_c"; _n=$((_n + 1)); fi
    done
    if [ "$_n" -eq 1 ]; then PID=${_p# }; PID_HOW="jcmd -l"; return 0; fi
    if [ "$_n" -gt 1 ]; then
        PID_WHY="jcmd -l lists $_n running JVMs with main class $1 (pids$_p) - expected exactly one"
        return 1
    fi
    _n=0 _p=""
    for _d in "$PROC"/[0-9]*; do
        [ -r "$_d/cmdline" ] || continue
        [ "$(cat "$_d/comm" 2>/dev/null)" = java ] || continue
        if tr '\0' '\n' <"$_d/cmdline" 2>/dev/null | grep -qxF -- "$1"; then
            _p="$_p ${_d##*/}"; _n=$((_n + 1))
        fi
    done
    if [ "$_n" -eq 1 ]; then PID=${_p# }; PID_HOW="/proc (jcmd -l did not list it)"; return 0; fi
    PID_WHY="no single running JVM has main class $1: jcmd -l found none, /proc found $_n (jcmd -l said: $(printf '%s' "$_jl" | tr '\n' ';' | cut -c1-300))"
    return 1
}

# ---------------------------------------------------------------------------
# The debug port
# ---------------------------------------------------------------------------

# Rows of /proc/<pid>/net/tcp and tcp6 for local port 5005 in state $2 (0A =
# LISTEN, 01 = ESTABLISHED), as "<table> <local address> <inode>". These tables
# describe the whole network namespace, not the process - in a container every
# process shares one - so a row says nothing about WHO holds the socket. The
# inode does: it has to be one of the process's own file descriptors.
# $1 = pid, or empty for this shell's own view of the namespace.
jdwp_rows() {
    if [ -n "$1" ]; then _base=$PROC/$1/net; else _base=$PROC/net; fi
    for _t in tcp tcp6; do
        [ -r "$_base/$_t" ] || continue
        awk -v t="$_t" -v st="$2" -v port=":$JDWP_HEX" '
            NR > 1 && $4 == st && substr($2, length($2) - 4) == port { print t, $2, $10 }' "$_base/$_t"
    done
}

# Every socket:[inode] link among the process's file descriptors.
pid_sockets() {
    for _fd in "$PROC/$1/fd/"*; do
        _l=$(readlink "$_fd" 2>/dev/null) || continue
        case $_l in socket:*) printf '%s\n' "$_l" ;; esac
    done
}

# $1 = rows (jdwp_rows output), $2 = socket list: prints "owned" and
# "foreign" lists as two lines, "<table>:<inode> ..." each.
split_owned() {
    _own="" _foreign=""
    while read -r _t _a _ino; do
        [ -n "${_ino:-}" ] || continue
        if printf '%s\n' "$2" | grep -qxF "socket:[$_ino]"; then _own="$_own $_t:$_ino"
        else _foreign="$_foreign $_t:$_ino"; fi
    done <<EOF
$1
EOF
    OWNED=${_own# } FOREIGN=${_foreign# }
}

check_jdwp() {
    _id="F-JDWP-01-$SVC"
    if [ -z "$PID" ]; then
        kv "jdwp_listen=?" "jdwp_established=?"
        hc_fail "$_id" "$PID_WHY"
        return
    fi
    _listen=$(jdwp_rows "$PID" 0A)
    _est=$(jdwp_rows "$PID" 01)
    _nl=$(count_lines "$_listen")
    _ne=$(count_lines "$_est")
    kv "jdwp_listen=$_nl" "jdwp_established=$_ne"
    _socks=$(pid_sockets "$PID")
    if [ "$_nl" -gt 0 ]; then
        split_owned "$_listen" "$_socks"
        if [ -z "$FOREIGN" ]; then
            hc_pass "$_id" "pid $PID ($MAIN, found by $PID_HOW) owns the LISTEN socket on container port 5005 ($OWNED)"
        elif [ -n "$OWNED" ]; then
            hc_fail "$_id" "pid $PID owns a LISTEN socket on :5005 ($OWNED), but another process in the container listens there too ($FOREIGN)"
        else
            hc_fail "$_id" "something listens on container port 5005 ($FOREIGN), but not the application (pid $PID, $MAIN): its socket inode is not among the pid's file descriptors"
        fi
        return
    fi
    if [ "$_ne" -gt 0 ]; then
        split_owned "$_est" "$_socks"
        if [ -n "$OWNED" ]; then
            # JDWP stops listening while a debugger is attached and listens
            # again when it detaches: this is somebody debugging, not a fault.
            hc_skip "$_id" "a debugger is attached: pid $PID holds an ESTABLISHED connection on :5005 ($OWNED), and the JDWP agent does not listen while one is - detach and run again to check the LISTEN socket"
            return
        fi
    fi
    hc_fail "$_id" "nothing listens on container port 5005 (hex $JDWP_HEX) in the network namespace of pid $PID ($MAIN): the JDWP agent is not running in the application"
}

# ---------------------------------------------------------------------------
# The Maven repository behind the classpath
# ---------------------------------------------------------------------------

# $1 = id, $2 = what, $3 = newline-separated entries. Every entry must be an
# existing file strictly under $REPO/ - no .. or . segments, which a string
# prefix test would otherwise wave through.
check_entries() {
    _n=0 _out=0 _outs="" _gone=0 _gones=""
    while IFS= read -r _e; do
        [ -n "$_e" ] || continue
        _n=$((_n + 1))
        case $_e in
          "$REPO"/?*)
            case $_e in
              */../*|*/./*|*/..|*/.)
                _out=$((_out + 1)); [ "$_out" -le 3 ] && _outs="$_outs $_e" ;;
              *)
                if [ ! -f "$_e" ]; then _gone=$((_gone + 1)); [ "$_gone" -le 3 ] && _gones="$_gones $_e"; fi ;;
            esac ;;
          *) _out=$((_out + 1)); [ "$_out" -le 3 ] && _outs="$_outs $_e" ;;
        esac
    done <<EOF
$3
EOF
    if [ "$_n" -eq 0 ]; then
        hc_fail "$1" "$2 has no entries at all"
    elif [ "$_out" -gt 0 ]; then
        hc_fail "$1" "$_out of $_n entries of $2 are not under $REPO/ - the classpath comes from somewhere other than the shared Maven volume:$_outs"
    elif [ "$_gone" -gt 0 ]; then
        hc_fail "$1" "$_gone of $_n entries of $2 are not files in the volume:$_gones"
    else
        hc_pass "$1" "all $_n entries of $2 are files under $REPO/"
    fi
}

check_classpath_file() {
    _id="F-VOL-03-$SVC"
    if [ ! -s "$CP_FILE" ]; then
        hc_fail "$_id" "$CP_FILE is missing or empty - no full build has succeeded in this container"
        return
    fi
    CP_TEXT=$(tr -d '\r\n' <"$CP_FILE")
    # An empty entry puts the working directory - the checkout - on the
    # classpath, which dev-reload.sh refuses too.
    case ":$CP_TEXT:" in *::*)
        hc_fail "$_id" "$CP_FILE has an empty entry, which means the working directory"
        return ;;
    esac
    check_entries "$_id" "$CP_FILE" "$(printf '%s' "$CP_TEXT" | tr ':' '\n')"
}

# The file is what the NEXT launch uses; the process is what runs now. They
# differ legitimately only while dev-reload.sh is refusing to replace a JVM
# (launch-refused), and that is worth saying.
check_classpath_jvm() {
    _id="F-VOL-03-$SVC-jvm"
    if [ -z "$PID" ]; then hc_fail "$_id" "$PID_WHY"; return; fi
    _cp=$(tr '\0' '\n' <"$PROC/$PID/cmdline" 2>/dev/null |
        awk 'p { print; exit } $0 == "-cp" || $0 == "-classpath" || $0 == "--class-path" { p = 1 }')
    if [ -z "$_cp" ]; then
        hc_fail "$_id" "pid $PID was not started with -cp, so its classpath cannot be checked"
        return
    fi
    _first=${_cp%%:*}
    if [ "$_first" != "$APP/target/classes" ]; then
        hc_fail "$_id" "the first classpath entry of pid $PID is '$_first', not $APP/target/classes"
        return
    fi
    case $_cp in
      *:*) _deps=${_cp#*:} ;;
      *)   hc_fail "$_id" "pid $PID runs with $APP/target/classes alone - no dependency is on its classpath"; return ;;
    esac
    check_entries "$_id" "the -cp of pid $PID (after $APP/target/classes)" "$(printf '%s' "$_deps" | tr ':' '\n')"
    if [ -n "${CP_TEXT:-}" ] && [ "$_deps" != "$CP_TEXT" ]; then
        hc_warn "$_id-stale" "pid $PID runs on a different classpath than $CP_FILE now holds - dev-reload.sh has a newer build it did not (yet) launch"
    fi
}

cmd_probe() {
    [ $# -eq 2 ] || usage
    SVC=$1 MAIN=$2
    kv "service=$SVC"
    if find_app_pid "$MAIN"; then kv "pid=$PID" "pid_how=$PID_HOW"; else kv "pid="; fi

    check_jdwp
    CP_TEXT=""
    check_classpath_file
    check_classpath_jvm

    # One volume, one filesystem: the same device and inode in every
    # container is what "shared" means. The root's device is printed beside
    # it so the suite can also tell a real mount from a plain directory in the
    # container's own layer.
    _di=$(stat -c %d:%i "$REPO" 2>/dev/null) || _di=""
    _rd=$(stat -c %d / 2>/dev/null) || _rd=""
    if [ -n "$_di" ]; then
        kv "devino=$_di" "rootdev=$_rd"
    else
        kv "devino="
        hc_fail "F-VOL-02-$SVC" "stat -c %d:%i $REPO failed - the directory does not exist in this container"
    fi
    hc_exit
}

cmd_jdwp_state() {
    [ $# -eq 0 ] || usage
    _nl=$(count_lines "$(jdwp_rows "" 0A)")
    _ne=$(count_lines "$(jdwp_rows "" 01)")
    kv "jdwp_listen=$_nl" "jdwp_established=$_ne"
    exit 0
}

# ---------------------------------------------------------------------------
# Kafka, with the application's own client code
# ---------------------------------------------------------------------------

# The classpath is the application's own dev-classpath.txt, so the probe runs
# the same kafka-clients jar the service does, against the same advertised
# listener. KafkaProbe.java falls back to a TCP connect when no Kafka client is
# on that classpath, which is reported as a finding rather than a pass.
cmd_kafka() {
    [ $# -eq 3 ] || usage
    SVC=$1 _probe=$2 _boot=$3
    _id="F-NET-05-$SVC"
    if [ ! -f "$_probe" ]; then hc_fail "$_id" "$_probe is not in the container"; hc_exit; fi
    if [ ! -s "$CP_FILE" ]; then hc_fail "$_id" "$CP_FILE is missing or empty, so there is no application classpath to run the probe with"; hc_exit; fi
    _cp=$(tr -d '\r\n' <"$CP_FILE")
    if printf '%s\n' "$_cp" | tr ':' '\n' | grep -q '/kafka-clients-[^/]*\.jar$'; then _kc=yes; else _kc=no; fi
    kv "kafka_clients=$_kc"
    # A small heap: this runs beside the application inside its 1g limit,
    # and the kernel's OOM killer would pick the application, not the probe.
    set -- -Xmx128m -XX:+UseSerialGC -XX:TieredStopAtLevel=1 -cp "$_cp" "$_probe" "$_boot"
    if command -v timeout >/dev/null 2>&1; then set -- timeout 90 "$JAVA" "$@"; else set -- "$JAVA" "$@"; fi
    _rc=0
    _out=$("$@" 2>&1) || _rc=$?
    printf '%s\n' "$_out" | hc_redact
    _line=$(printf '%s\n' "$_out" | grep '^KAFKAPROBE ' | tail -n 1)
    case $_line in
      "KAFKAPROBE OK mode=adminclient "*)
        hc_pass "$_id" "AdminClient from the application's own kafka-clients: ${_line#KAFKAPROBE OK mode=adminclient }" ;;
      "KAFKAPROBE OK mode=tcp "*)
        if [ "$_kc" = yes ]; then
            hc_warn "$_id" "kafka-clients is on the classpath but the probe could not load it, so only a TCP connect was tried: ${_line#KAFKAPROBE OK mode=tcp }"
        else
            hc_info "$_id" "no Kafka client code on this service's classpath, so only a TCP connect was tried, and it worked: ${_line#KAFKAPROBE OK mode=tcp }"
        fi ;;
      "KAFKAPROBE FAIL "*)
        hc_fail "$_id" "${_line#KAFKAPROBE FAIL }" ;;
      *)
        _last=$(printf '%s\n' "$_out" | grep . | tail -n 1 | cut -c1-300)
        # Source-file mode compiles the probe against -cp first, and javac
        # opens every jar on it: one unreadable jar in the volume stops it
        # here - and would stop the application's next launch as well.
        _cerr=$(printf '%s\n' "$_out" | grep -m 1 '^error: ' | cut -c1-300)
        if [ "$_rc" -eq 124 ]; then hc_fail "$_id" "the probe did not finish within 90s"
        elif printf '%s\n' "$_out" | grep -q '^error: compilation failed'; then
            hc_fail "$_id" "KafkaProbe.java did not compile against this service's classpath: ${_cerr:-see the evidence}"
        else hc_fail "$_id" "the probe did not run to a verdict (exit $_rc): ${_last:-no output}"; fi ;;
    esac
    hc_exit
}

[ $# -ge 1 ] || usage
_cmd=$1; shift
case $_cmd in
    probe)      cmd_probe "$@" ;;
    jdwp-state) cmd_jdwp_state "$@" ;;
    kafka)      cmd_kafka "$@" ;;
    *)          usage ;;
esac
