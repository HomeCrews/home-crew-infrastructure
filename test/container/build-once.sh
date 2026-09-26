#!/bin/sh
# Suite D (concurrency), container side: ONE build in one container of the
# isolated test project, leaving a complete record of it behind. Started by
# test/lib/SuiteConcurrency.ps1 as
#
#     docker compose -p homecrew-test ... run -d --no-deps -T --name hct-... \
#         -e DEV_COMPILER=... -v <evidence dir>:/out \
#         --entrypoint sh <svc> /test/container/build-once.sh <svc> [flags]
#
# Everything goes to /out, the host's evidence directory for this round:
#
#   <tag>.ready     written the moment the container runs. The host waits for
#                   all twelve and then writes GO: a barrier, because twelve
#                   `compose run`s issued one after another start seconds
#                   apart, and the race this suite looks for - twelve cold
#                   resolves of the same artifacts - is easily lost in a
#                   stagger that size.
#   <tag>.log       everything the build printed, stdout and stderr, written
#                   straight to /out so that a container that is killed or
#                   OOM-killed still leaves its log
#   <tag>.secs      how long the build took
#   <tag>.cp-check  every dev-classpath.txt entry, checked on disk
#   <tag>.jcmd      (--jcmd) the mvnd daemon's system properties
#   <tag>.rc        the exit code - written LAST, and by rename, because it is
#                   what the host and LockProbe's stop file read as "done"
#
# Usage:
#
#   build-once.sh <svc> [--no-barrier] [--tag T] [--repo DIR] [--jcmd]
#       `sh /dev-reload.sh --build-only`: the first build the real entrypoint
#       runs, compile + dependency:build-classpath + the main-class check
#   build-once.sh <svc> [--no-barrier] [--tag T] --maven <maven args...>
#       one run_maven call, through dev-reload.sh's own functions
#       (DEV_RELOAD_LIB_ONLY=1), so the lock flags are exactly the real ones
#   build-once.sh --seed-partial-wrapper
#       plants an INCOMPLETE Maven install where mvnw looks for its own
#   build-once.sh --diag
#       /proc/locks and a thread dump of every JVM, for a build that hangs
#
# <svc> only names the files (unless --tag does); the service is whichever
# container this runs in. --repo is where every classpath entry must live
# (default /root/.m2/repository, the shared volume).
#
# POSIX sh; runs under dash in homecrew-dev-runtime:jdk25.

set -u

OUT=${HC_OUT:-/out}                        # HC_*: overridable for test/ only
DEV_RELOAD=${HC_DEV_RELOAD:-/dev-reload.sh}
APP=${DEV_APP_DIR:-/app}
GO_TIMEOUT=${HC_GO_TIMEOUT:-900}

now() { cut -d. -f1 /proc/uptime 2>/dev/null || date +%s; }

usage() {
    echo "usage: build-once.sh <svc> [--no-barrier] [--tag T] [--repo DIR] [--jcmd] [--maven <args...>]" >&2
    echo "       build-once.sh --seed-partial-wrapper | --diag" >&2
    exit 2
}

# ---------------------------------------------------------------------------
# The wrapper's download, made visible
# ---------------------------------------------------------------------------

# D-WRAP counts how many containers DOWNLOADED the Maven distribution. mvnw
# announces it ("Couldn't find MAVEN_HOME, downloading and installing it")
# only on stdout, which dev-reload.sh's install_wrapper sends to /dev/null -
# so the fetch itself is the observable: mvnw looks wget and curl up on PATH
# and runs whichever it finds, and these stand-ins note the call on stderr
# (which does reach the log) and hand over to the real program unchanged.
# Nothing else a build runs uses either tool.
install_fetch_shim() {
    _shim=/tmp/hc-fetch-shim
    mkdir -p "$_shim" || return 0
    for _tool in wget curl; do
        _real=$(command -v "$_tool" 2>/dev/null) || continue
        case $_real in /*) ;; *) continue ;; esac
        cat >"$_shim/$_tool" <<EOF
#!/bin/sh
printf 'HC-FETCH %s %s\n' '$_tool' "\$*" >&2
exec '$_real' "\$@"
EOF
        chmod +x "$_shim/$_tool"
    done
    PATH=$_shim:$PATH
    export PATH
}

# ---------------------------------------------------------------------------
# Running the build
# ---------------------------------------------------------------------------

# The build runs in the background and is waited for, so that a `docker stop`
# of this container reaches it: dash runs a trap only between foreground
# commands, and tini hands SIGTERM to this shell, not to its children.
CHILD=""
forward() {
    if [ -n "$CHILD" ]; then kill -TERM "$CHILD" 2>/dev/null || :; else exit 143; fi
}
trap forward TERM INT

wait_child() {
    _wc=0
    wait "$CHILD" || _wc=$?
    # A trapped signal ends `wait` early, with the child still running (it
    # has just been sent TERM): wait again, for its real status.
    while kill -0 "$CHILD" 2>/dev/null; do _wc=0; wait "$CHILD" || _wc=$?; done
    CHILD=""
    return "$_wc"
}

barrier() {
    : >"$OUT/$TAG.ready" || { echo "build-once: $OUT is not writable" >&2; exit 99; }
    echo "build-once $TAG: ready"
    [ "$BARRIER" = 1 ] || return 0
    _limit=$(( $(now) + GO_TIMEOUT ))
    while [ ! -e "$OUT/GO" ]; do
        if [ "$(now)" -ge "$_limit" ]; then
            echo "build-once $TAG: no GO within ${GO_TIMEOUT}s" >&2
            return 1
        fi
        sleep 0.2
    done
    echo "build-once $TAG: go"
}

# Every classpath entry must exist AND come from the shared repository: a jar
# the resolver lost, or one resolved into some other directory, would only
# surface when the application failed to start.
cp_check() {
    _cp=$APP/target/dev-classpath.txt
    if [ ! -s "$_cp" ]; then
        echo "CP-CHECK fail $_cp is missing or empty"
        return 0
    fi
    _all=$(tr -d '\r\n' <"$_cp")
    _n=0 _miss=0 _out=0 _empty=0
    case ":$_all:" in *::*) _empty=1 ;; esac
    # A here-document, not a pipe, so that the loop runs in THIS shell and the
    # counters survive it.
    while IFS= read -r _e; do
        [ -n "$_e" ] || continue
        _n=$((_n + 1))
        if [ ! -e "$_e" ]; then _miss=$((_miss + 1)); echo "MISSING $_e"; fi
        case $_e in "$REPO"/*) ;; *) _out=$((_out + 1)); echo "OUTSIDE $_e" ;; esac
    done <<EOF
$(printf '%s\n' "$_all" | tr ':' '\n')
EOF
    if [ "$_n" -gt 0 ] && [ "$_miss" -eq 0 ] && [ "$_out" -eq 0 ] && [ "$_empty" -eq 0 ]; then
        echo "CP-CHECK ok entries=$_n"
    else
        echo "CP-CHECK fail entries=$_n missing=$_miss outside=$_out empty-entry=$_empty"
    fi
}

# The daemon is the JVM that loads the lock class, so it is the one whose
# system properties decide deleteLockFiles - not the native mvnd client. It
# is still alive here: the build has just finished and idleTimeout is 15m.
jcmd_dump() {
    echo "## jcmd -l"
    jcmd -l 2>&1
    _pids=$( { jcmd -l 2>/dev/null | awk '$2 ~ /mvndaemon|MavenDaemon/ { print $1 }'
               pgrep -f 'mvndaemon|MavenDaemon' 2>/dev/null; } | sort -u)
    _n=0 _ok=0
    for _p in $_pids; do
        [ -r "/proc/$_p/cmdline" ] || continue
        _n=$((_n + 1))
        echo "## pid $_p: $(tr '\0' ' ' <"/proc/$_p/cmdline" | cut -c1-400)"
        _props=$(jcmd "$_p" VM.system_properties 2>&1)
        printf '%s\n' "$_props"
        if printf '%s\n' "$_props" | grep -qx 'aether.named.file-lock.deleteLockFiles=false'; then
            _ok=$((_ok + 1))
        fi
    done
    echo "JCMD-SUMMARY daemons=$_n deleteLockFiles_false=$_ok"
}

finish() {
    printf '%s\n' "$1" >"$OUT/$TAG.rc.tmp" && mv -f "$OUT/$TAG.rc.tmp" "$OUT/$TAG.rc"
    # Root in here, somebody else outside: on a Linux host these files would
    # otherwise be left for the person who ran the harness unable to delete.
    _own=$(stat -c %u:%g "$OUT" 2>/dev/null) && chown "$_own" "$OUT/$TAG".* 2>/dev/null || :
    echo "build-once $TAG: done, exit $1"
    exit "$1"
}

build_only() {
    install_fetch_shim
    _t0=$(now) _rc=0
    sh "$DEV_RELOAD" --build-only >"$OUT/$TAG.log" 2>&1 &
    CHILD=$!
    wait_child || _rc=$?
    echo $(( $(now) - _t0 )) >"$OUT/$TAG.secs"
    cp_check >"$OUT/$TAG.cp-check" 2>&1
    if [ "$JCMD" = 1 ]; then jcmd_dump >"$OUT/$TAG.jcmd" 2>&1; fi
    finish "$_rc"
}

maven_once() {
    _t0=$(now) _rc=0
    # A subshell: dev-reload.sh's `set -eu` and its globals stay in there.
    (
        DEV_RELOAD_LIB_ONLY=1 . "$DEV_RELOAD"
        cd "$APP" && validate_settings && choose_compiler && run_maven "$@"
    ) >"$OUT/$TAG.log" 2>&1 &
    CHILD=$!
    wait_child || _rc=$?
    echo $(( $(now) - _t0 )) >"$OUT/$TAG.secs"
    finish "$_rc"
}

# ---------------------------------------------------------------------------
# The other two entry points
# ---------------------------------------------------------------------------

# mvnw's own hash_string (maven-wrapper 3.3.4): Java's String.hashCode of the
# distribution URL, in hex - the name of the directory mvnw installs into.
hash_string() {
    str="${1:-}" h=0
    while [ -n "$str" ]; do
        char="${str%"${str#?}"}"
        h=$(((h * 31 + $(LC_CTYPE=C printf %d "'$char")) % 4294967296))
        str="${str#?}"
    done
    printf %x\\n $h
}

# What a container killed halfway through the wrapper's install leaves behind:
# bin/ and mvnw.url, no lib/. mvnw itself checks only that the directory
# exists, so without dev-reload.sh's cleanup every later ./mvnw would run
# this stub - and it says so loudly if that ever happens.
seed_partial_wrapper() {
    (
        DEV_RELOAD_LIB_ONLY=1 . "$DEV_RELOAD"
        set +e
        cd "$APP" || exit 1
        _url=$(wrapper_url)
        [ -n "$_url" ] || { echo "no distributionUrl in $APP/.mvn/wrapper/maven-wrapper.properties" >&2; exit 1; }
        _name=${_url##*/}; _name=${_name%.*}; _name=${_name%-bin}
        _dir=$WRAPPER_DIR/dists/$_name/$(hash_string "$_url")
        rm -rf "$_dir" && mkdir -p "$_dir/bin" || exit 1
        printf '%s\n' "$_url" >"$_dir/mvnw.url"
        cat >"$_dir/bin/mvn" <<'EOF'
#!/bin/sh
echo "HC-PARTIAL-DIST-STUB: the incomplete Maven install seeded by test/ was executed" >&2
exit 97
EOF
        chmod +x "$_dir/bin/mvn"
        echo "SEEDED $_dir"
    )
}

diag() {
    echo "== /proc/locks"
    cat /proc/locks 2>&1
    echo "== processes"
    ps -eo pid,ppid,etimes,rss,args 2>&1 | cut -c1-300
    for _p in $(jcmd -l 2>/dev/null | awk '$2 !~ /JCmd/ { print $1 }'); do
        echo "== jcmd $_p Thread.print"
        jcmd "$_p" Thread.print 2>&1
    done
}

# ---------------------------------------------------------------------------

case ${1:-} in
    --seed-partial-wrapper) seed_partial_wrapper; exit $? ;;
    --diag) diag; exit 0 ;;
    ''|-*) usage ;;
esac

TAG=$1; shift
BARRIER=1 JCMD=0 MODE=build
REPO=${HOME:-/root}/.m2/repository
while [ $# -gt 0 ]; do
    case $1 in
        --no-barrier) BARRIER=0 ;;
        --jcmd)       JCMD=1 ;;
        --tag)        [ $# -ge 2 ] || usage; TAG=$2; shift ;;
        --repo)       [ $# -ge 2 ] || usage; REPO=${2%/}; shift ;;
        --maven)      shift; MODE=maven; break ;;
        *)            usage ;;
    esac
    shift
done
case $TAG in ''|*/*) usage ;; esac

barrier || finish 98
if [ "$MODE" = maven ]; then maven_once "$@"; else build_only; fi
