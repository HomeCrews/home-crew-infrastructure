#!/bin/sh
# Suite C, part 2: the dev-reload.sh STATE MACHINE, run for real against fakes
# (R7, and the launch half of R6).
#
#     sh /src/test/container/unit-state-machine.sh [--compiler mvnd|mvnw|both]
#            [--script PATH] [--only CASE[,CASE...]]
#
# Runs inside homecrew-dev-runtime:jdk25 - dash, GNU find and coreutils,
# util-linux, JDK 25 - with the infra repo read-only at /src and --network
# none. --script defaults to /src/dev-reload.sh, --compiler to both (mvnd
# first, then mvnw), --only to every case, in the order of SM_ALL_CASES.
#
# WHY THE REAL LOOP. The functions are unit-tested one by one in part 1; what
# goes wrong in a state machine is the ORDER things happen in - a fingerprint
# taken after the compile instead of before, a JVM stopped before its
# replacement is known to launch, a readiness gate that swallows a save. So
# every case starts the real `sh dev-reload.sh` loop with its timings turned
# down from minutes to seconds, and drives it the way a developer does: by
# editing files. Only what is slow or needs the network is fake:
#
#   mvnd, ./mvnw  one fake behind both names. `compile` puts PRECOMPILED
#                 classes into target/classes - one per source file, compiled
#                 by javac once at setup - and behaves like
#                 maven-compiler-plugin wherever the state machine can tell the
#                 difference: it reads the source list before it "works", it
#                 deletes every previous class before "javac" runs and does not
#                 put them back when it fails (maven-shared-incremental), and it
#                 decides what is stale the way the plugin does - from its
#                 record of the last inputs (inputFiles.lst) and from mtimes,
#                 honouring -DlastModGranularityMs. `dependency:build-classpath`
#                 writes a classpath of dummy jars. --version installs a fake
#                 wrapper distribution, --stop is logged.
#   java          given as DEV_JAVA. Logs START and STOP, stays up until
#                 stopped, and can be told to crash or to ignore SIGTERM.
#   curl          answers the readiness probe with whatever ctl/http says.
#
# Control files, in <fixture>/.sm/ctl/ and read by the fakes on every call:
#
#   http              the probe's HTTP code: 200, or 000 for "nothing answers"
#   delay             seconds every build sleeps after reading its sources
#   rc                a forced exit code for every build
#   fail-once         the next build fails before doing anything; the file goes
#   cp                ok | fail | missing | empty: what build-classpath does
#   java-crash        every fake java exits 1 as soon as it sees this
#   java-ignore-term  fake javas started from now on ignore SIGTERM
#   java-exit         every fake java exits 0: written when the case is over
#
# A source or pom.xml containing SM_BROKEN does not "compile"; a pom.xml
# containing SM_EXTRA_DEP gets one more jar on its classpath.
#
# VERDICTS COME FROM WHAT HAPPENED, not from what the script says happened,
# wherever that is possible: builds are counted in the fake Maven's log, JVMs
# in the fake java's, and the trigger's mtime and the class files are read off
# the disk. The log markers ('[dev-reload] <event>:', the contract in the
# header of dev-reload.sh) are asserted where the event itself is what is under
# test - reload-deferred, boot-timeout, app-killed. That is what lets the
# mutation suite point --script at the pre-rewrite dev-reload.sh and get a
# FAIL from delete-file and backdated-edit that means something: that script
# logs none of the markers, but its builds are still counted. It does not
# honour DEV_APP_DIR either, so a copy of it with APP=$DEV_APP_DIR - that one
# line changed - is what runs; the fake mvnw also plays its spring-boot:run.
#
# NOTHING HANGS AND NOTHING LEAKS. Every wait polls with a bound, and every
# bound is also capped by a per-case limit (SM_CASE_LIMIT). Each loop runs in
# its own session (setsid), so the whole tree it started - JVM, Maven, sleeps -
# is one process group that is killed when the case ends, whatever the script
# under test did; then anything still mentioning the fixture is killed too. A
# trap does the same when this script itself is interrupted.
#
# Output: one HCRESULT line per case and compiler, id C-SM-<case> with the
# compiler in brackets at the start of the message, preceded by that case's
# evidence (the loop's output and the fakes' logs). Exit 0 when every case
# passed, 1 when any failed, 2 on a usage error.
#
# POSIX sh, for dash. Outside the image it needs at least GNU find (-printf,
# as dev-reload.sh does); without /proc it falls back to kill -0 for liveness
# and to perl or date for the clock, and skips the orphan checks.

set -u

HERE=$(dirname "$0")
# shellcheck source=lib.sh
. "$HERE/lib.sh"

SM_ALL_CASES="boot src-edit failed-src-edit pom-edit broken-pom first-build-fails-then-fix
classpath-fails crash-backoff sigterm edit-during-compile ignore-term main-missing-at-boot
save-during-boot boot-timeout retry delete-file backdated-edit burst reload-failed"

SM_SCRIPT=/src/dev-reload.sh
SM_COMPILERS="mvnd mvnw"
SM_CASES=""

sm_usage() {
    printf '%s\n' "usage: unit-state-machine.sh [--compiler mvnd|mvnw|both] [--script PATH] [--only CASE[,CASE...]]" \
        "cases: $(echo $SM_ALL_CASES)" >&2
    exit 2
}

while [ $# -gt 0 ]; do
    case $1 in
        --compiler)
            [ $# -ge 2 ] || sm_usage
            case $2 in
                mvnd|mvnw) SM_COMPILERS=$2 ;;
                both) SM_COMPILERS="mvnd mvnw" ;;
                *) sm_usage ;;
            esac
            shift 2 ;;
        --script)
            [ $# -ge 2 ] || sm_usage
            SM_SCRIPT=$2; shift 2 ;;
        --only)
            [ $# -ge 2 ] || sm_usage
            SM_CASES=$(printf '%s' "$2" | tr ',' ' '); shift 2 ;;
        *) sm_usage ;;
    esac
done

# --only keeps the canonical order, so that a subset runs exactly as it does
# inside the full set.
if [ -n "$SM_CASES" ]; then
    for _c in $SM_CASES; do
        case " $(echo $SM_ALL_CASES) " in *" $_c "*) ;; *)
            printf '%s\n' "unit-state-machine.sh: unknown case '$_c'" >&2; sm_usage ;; esac
    done
    _sel=""
    for _c in $SM_ALL_CASES; do
        case " $SM_CASES " in *" $_c "*) _sel="$_sel $_c" ;; esac
    done
    SM_CASES=$_sel
else
    SM_CASES=$SM_ALL_CASES
fi

# The loop's settings, the same in every case (a case that needs one changed
# says so in SM_ENV). Seconds instead of minutes, but in the same proportions
# that matter: the stop timeout below the boot timeout, the retry delay longer
# than a poll.
SM_INTERVAL=1 SM_RESTART_DELAY=1 SM_RETRY_DELAY=2 SM_READY_APPEAR=3
SM_BOOT_TIMEOUT=8 SM_STOP_TIMEOUT=3 SM_PORT=18080
SM_CASE_LIMIT=150

SM_ROOT=/tmp
SM_PRE=$SM_ROOT/sm-pre
SM_DIST_URL=https://repo.maven.apache.org/maven2/org/apache/maven/apache-maven/3.9.16/apache-maven-3.9.16-bin.zip
SM_DIST_REL=wrapper/dists/apache-maven-3.9.16-bin/smfake

# Per-case state; sm_run_case resets all of it.
SM_CASE="" SM_COMPILER="" SM_P="" SM_H="" SM_PREAL="" SM_DEPS=""
SM_OUT="" SM_ERR="" SM_JLOG="" SM_MLOG="" SM_JTIMES=""
SM_FAILS="" SM_NOTES="" SM_WHAT="" SM_ENV=""
SM_LOOP_PID="" SM_PGID="" SM_LOOP_DONE=0 SM_DEADLINE=0 SM_MATCH=""

# ---------------------------------------------------------------------------
# Clocks and processes
# ---------------------------------------------------------------------------

# Centiseconds on a monotonic clock - the one dev-reload.sh itself uses. The
# fallbacks only matter when this is run by hand somewhere without /proc.
sm_cs() {
    if [ -r /proc/uptime ]; then
        read -r _cs_u _cs_x </proc/uptime
        echo $(( ${_cs_u%.*} * 100 + 1${_cs_u#*.} - 100 ))
    elif command -v perl >/dev/null 2>&1; then
        perl -MTime::HiRes=time -e 'printf("%d\n", time() * 100)'
    else
        echo $(( $(date +%s) * 100 ))
    fi
}

# kill -0 also succeeds for a zombie: an exited child nobody has reaped yet.
sm_alive() {
    [ -n "${1:-}" ] || return 1
    kill -0 "$1" 2>/dev/null || return 1
    [ -r "/proc/$1/stat" ] || return 0
    _al_st=$(sed -n 's/^[0-9]* (.*) \([A-Za-z]\) .*/\1/p' "/proc/$1/stat" 2>/dev/null) || _al_st=""
    [ "$_al_st" != Z ]
}
sm_dead() { ! sm_alive "${1:-}"; }

sm_pgid() { sed -n 's/^.*) [A-Za-z] [0-9-]* \([0-9-]*\) .*/\1/p' "/proc/$1/stat" 2>/dev/null; }

SM_CANLIST=0
[ -r /proc/self/cmdline ] && SM_CANLIST=1

# Sets SM_MATCH to the live processes whose command line contains $1. Read
# straight from /proc rather than through ps, and in this shell rather than a
# pipeline, so that the only processes that could match by accident - this
# script's own forks - are the ones it skips.
sm_find_procs() {
    SM_MATCH=""
    [ "$SM_CANLIST" = 1 ] || return 0
    for _fp_d in /proc/[0-9]*; do
        _fp_p=${_fp_d#/proc/}
        [ "$_fp_p" = "$$" ] && continue
        _fp_c=$(tr '\0' ' ' 2>/dev/null <"$_fp_d/cmdline") || continue
        case $_fp_c in *"$1"*) ;; *) continue ;; esac
        case $_fp_c in *unit-state-machine.sh*) continue ;; esac
        sm_alive "$_fp_p" || continue
        SM_MATCH="${SM_MATCH:+$SM_MATCH }$_fp_p"
    done
}
# Sets SM_MATCH to the live members of process group $1.
sm_group_procs() {
    SM_MATCH=""
    [ "$SM_CANLIST" = 1 ] && [ -n "${1:-}" ] || return 0
    for _gp_d in /proc/[0-9]*; do
        _gp_p=${_gp_d#/proc/}
        [ "$(sm_pgid "$_gp_p")" = "$1" ] || continue
        sm_alive "$_gp_p" || continue
        SM_MATCH="${SM_MATCH:+$SM_MATCH }$_gp_p"
    done
}
sm_describe_procs() {
    for _dp in "$@"; do
        printf '%s[%s] ' "$_dp" "$(tr '\0' ' ' 2>/dev/null <"/proc/$_dp/cmdline" | cut -c1-120)"
    done
}
sm_no_procs() { sm_find_procs "$1"; [ -z "$SM_MATCH" ]; }

# ---------------------------------------------------------------------------
# Bounded waiting. Never a fixed sleep for an outcome: poll, with a limit,
# and the limit is capped by the case's own deadline.
# ---------------------------------------------------------------------------

# sm_wait SECONDS COMMAND...: until COMMAND succeeds; 1 if it never did.
sm_wait() {
    _wt_end=$(( $(sm_cs) + $1 * 100 )); shift
    [ "$_wt_end" -le "$SM_DEADLINE" ] || _wt_end=$SM_DEADLINE
    while :; do
        "$@" && return 0
        [ "$(sm_cs)" -lt "$_wt_end" ] || return 1
        sleep 0.2
    done
}
# sm_holds SECONDS COMMAND...: COMMAND keeps succeeding for that long.
sm_holds() {
    _hd_end=$(( $(sm_cs) + $1 * 100 )); shift
    [ "$_hd_end" -le "$SM_DEADLINE" ] || _hd_end=$SM_DEADLINE
    while :; do
        "$@" || return 1
        [ "$(sm_cs)" -lt "$_hd_end" ] || return 0
        sleep 0.2
    done
}
# sm_quiet SECONDS LIMIT: nothing new in the loop's output or the fakes' logs
# for SECONDS. Where a case asserts "exactly one", it waits for this first: a
# second compile or JVM that is merely late must still be counted. Every
# deferred action dev-reload.sh has is announced by a line (app-ready,
# restart-scheduled ...), which restarts the window.
sm_logsig() { printf '%s/' $(wc -c <"$SM_OUT") $(wc -c <"$SM_JLOG") $(wc -c <"$SM_MLOG"); }
sm_quiet() {
    _qt_need=$(( $1 * 100 )); _qt_end=$(( $(sm_cs) + $2 * 100 ))
    [ "$_qt_end" -le "$SM_DEADLINE" ] || _qt_end=$SM_DEADLINE
    _qt_last="" _qt_since=0
    while :; do
        _qt_sig=$(sm_logsig); _qt_now=$(sm_cs)
        if [ "$_qt_sig" != "$_qt_last" ]; then _qt_last=$_qt_sig; _qt_since=$_qt_now; fi
        [ $(( _qt_now - _qt_since )) -lt "$_qt_need" ] || return 0
        [ "$_qt_now" -lt "$_qt_end" ] || return 1
        sleep 0.2
    done
}

# ---------------------------------------------------------------------------
# Reading what happened
# ---------------------------------------------------------------------------

sm_count() { _cn=$(grep -c "$1" "$2" 2>/dev/null) || :; echo "${_cn:-0}"; }

# dev-reload.sh's markers: '[dev-reload] <event>: <detail>'.
sm_ev_n()  { sm_count "^\[dev-reload\] $1: " "$SM_OUT"; }
sm_ev_ge() { [ "$(sm_ev_n "$1")" -ge "$2" ]; }
sm_ev_eq() { [ "$(sm_ev_n "$1")" -eq "$2" ]; }
sm_ev_line() { grep -n "^\[dev-reload\] $1: " "$SM_OUT" 2>/dev/null | sed -n "${2:-1}p" | cut -d: -f1; }

# The fake java's log: START <pid> <args>, STOP <pid>, CRASH <pid>,
# TERM-IGNORED <pid> <cs>.
sm_java_n()  { sm_count "^$1 " "$SM_JLOG"; }
sm_java_ge() { [ "$(sm_java_n "$1")" -ge "$2" ]; }
sm_java_eq() { [ "$(sm_java_n "$1")" -eq "$2" ]; }
sm_java_pid() { awk -v k="$2" -v w="$1" '$1 == w { if (++n == k + 0) { print $2; exit } }' "$SM_JLOG"; }
sm_java_seq() {
    awk '$1 == "START" || $1 == "STOP" || $1 == "CRASH" || $1 == "TERM-IGNORED" { printf "%s%s", s, $1; s = " " }
         END { print "" }' "$SM_JLOG"
}

# The fake Maven's log: BEGIN <seq> <tool> <cs> goals=<g,...> sources=<s,...>
# and END <seq> rc=<n> <why> around every build; VERSION, INSTALL,
# DAEMON-STOP, SPRING-BOOT-RUN and MVND-STUB lines for the rest.
SM_RE_COMPILE='^BEGIN .* goals=([^ ]*,)?compile(,| )'
SM_RE_FULL='^BEGIN .* goals=([^ ]*,)?dependency:build-classpath(,| )'
sm_mvn_n() {
    case $1 in
        compile) _mn_re=$SM_RE_COMPILE ;;
        full)    _mn_re=$SM_RE_FULL ;;
        *)       _mn_re="^$1 " ;;
    esac
    _mn=$(grep -cE "$_mn_re" "$SM_MLOG" 2>/dev/null) || :
    echo "${_mn:-0}"
}
sm_mvn_ge() { [ "$(sm_mvn_n "$1")" -ge "$2" ]; }
sm_mvn_idle() { [ "$(sm_mvn_n BEGIN)" -eq "$(sm_mvn_n END)" ]; }
sm_mvn_begin() { grep -E "$1" "$SM_MLOG" 2>/dev/null | sed -n "${2}p"; }

sm_mtime() { _mt=$(find "$1" -prune -printf '%T@' 2>/dev/null) || _mt=""; echo "${_mt:-absent}"; }
sm_trigger() { sm_mtime "$SM_P/target/classes/.reloadtrigger"; }
sm_trigger_changed() { [ "$(sm_trigger)" != "$1" ]; }
sm_mtime_changed() { [ "$(sm_mtime "$1")" != "$2" ]; }
sm_is_file() { [ -f "$1" ]; }
sm_no_file() { [ ! -e "$1" ]; }
sm_ne() { [ "$1" != "$2" ]; }

sm_fail() { SM_FAILS="${SM_FAILS:+$SM_FAILS; }$1"; }
sm_note() { SM_NOTES="${SM_NOTES:+$SM_NOTES; }$1"; }
# sm_expect DESCRIPTION COMMAND...: DESCRIPTION is the failure if it fails.
sm_expect() { _ex_d=$1; shift; "$@" || sm_fail "$_ex_d"; }
sm_expect_eq() { [ "$2" = "$3" ] || sm_fail "$1: expected $2, got $3"; }

# ---------------------------------------------------------------------------
# The fixture: a project, its fakes, and their control files
# ---------------------------------------------------------------------------

# Compiled once per run. The annotation is a stand-in with the real one's name
# and retention: resolve_main greps the bytecode for its descriptor and asks
# javap about it, and neither cares which jar it came from.
sm_write_pre_sources() {
    mkdir -p "$SM_PRE/src/demo" "$SM_PRE/src/org/springframework/boot/autoconfigure" "$SM_PRE/classes"
    cat >"$SM_PRE/src/org/springframework/boot/autoconfigure/SpringBootApplication.java" <<'EOF'
package org.springframework.boot.autoconfigure;

import java.lang.annotation.ElementType;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;

@Retention(RetentionPolicy.RUNTIME)
@Target(ElementType.TYPE)
public @interface SpringBootApplication {
}
EOF
    cat >"$SM_PRE/src/demo/App.java" <<'EOF'
package demo;

import org.springframework.boot.autoconfigure.SpringBootApplication;

@SpringBootApplication
public class App {
    public static void main(String[] args) {
    }
}
EOF
    # A main without the annotation: Boot's MainClassFinder falls back to
    # that, dev-reload.sh must not.
    cat >"$SM_PRE/src/demo/Plain.java" <<'EOF'
package demo;

public class Plain {
    public static void main(String[] args) {
    }
}
EOF
    for _ps in Extra Probe1 Probe2; do
        printf 'package demo;\n\npublic class %s {\n}\n' "$_ps" >"$SM_PRE/src/demo/$_ps.java"
    done
}

sm_write_src() {   # NAME [LINE TO APPEND]
    cp "$SM_PRE/src/demo/$1.java" "$SM_P/src/main/java/demo/$1.java"
    if [ $# -ge 2 ]; then printf '%s\n' "$2" >>"$SM_P/src/main/java/demo/$1.java"; fi
}
sm_append() { printf '%s\n' "$2" >>"$SM_P/$1"; }

sm_write_pom() {   # [EXTRA LINE]
    cat >"$SM_P/pom.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!-- Fixture of test/container/unit-state-machine.sh; only its fake Maven reads it. -->
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>demo</groupId>
  <artifactId>sm-fixture</artifactId>
  <version>1</version>
  ${1:-}
</project>
EOF
}

# An mtime HOURS in the past, without GNU date arithmetic: the clock read in a
# zone that many hours west of UTC, then stamped as UTC.
sm_backdate() {
    _bd_ts=$(TZ=UTC+$1 date +%Y%m%d%H%M.%S) && TZ=UTC touch -t "$_bd_ts" "$2"
}

sm_ctl()     { printf '%s\n' "$2" >"$SM_H/ctl/$1"; }
sm_ctl_on()  { : >"$SM_H/ctl/$1"; }

# The wrapper's Maven, as ensure_wrapper checks for it (dist_complete): a
# complete one so that the wrapper is ready, or - for boot - a half-copied one
# of the kind a killed install leaves, which must be removed and replaced.
sm_install_dist() {
    _di=$SM_P/m2/$SM_DIST_REL
    rm -rf "$_di"
    mkdir -p "$_di/bin"
    printf '#!/bin/sh\nexit 0\n' >"$_di/bin/mvn"
    printf '%s\n' "$SM_DIST_URL" >"$_di/mvnw.url"
    if [ "$1" = partial ]; then : >"$_di/bin/sm-partial"; return 0; fi
    mkdir -p "$_di/lib" "$_di/boot"
    : >"$_di/lib/maven-core-3.9.16.jar"
    : >"$_di/boot/plexus-classworlds-2.9.0.jar"
}

# The part every fake starts with: where the case lives, and the same clock as
# this script, so that times logged by a fake compare with times taken here.
sm_fake_head() {
    printf '#!/bin/sh\n'
    printf '# %s, written by test/container/unit-state-machine.sh for one case; see its header.\n' "$1"
    printf "SM_H='%s'\nSM_PRE='%s'\nSM_TOOL='%s'\n" "$SM_H" "$SM_PRE" "${2:-}"
    cat <<'EOF'
CTL=$SM_H/ctl
cs() {
    if [ -r /proc/uptime ]; then
        read -r _u _x </proc/uptime
        echo $(( ${_u%.*} * 100 + 1${_u#*.} - 100 ))
    elif command -v perl >/dev/null 2>&1; then
        perl -MTime::HiRes=time -e 'printf("%d\n", time() * 100)'
    else
        echo $(( $(date +%s) * 100 ))
    fi
}
EOF
}

sm_write_fake_maven() {   # TOOL PATH
    { sm_fake_head "Fake $1" "$1"; cat <<'EOF'
LOG=$SM_H/log/mvn.log
mtime() { find "$1" -prune -printf '%T@' 2>/dev/null; }
seq=$(( $(cat "$SM_H/log/mvn.seq" 2>/dev/null || echo 0) + 1 ))
echo "$seq" >"$SM_H/log/mvn.seq"
{
    for a in "$@"; do printf 'arg:%s\n' "$a"; done
    printf 'env:MAVEN_OPTS=%s\n' "${MAVEN_OPTS:-}"
    printf 'env:JAVA_TOOL_OPTIONS=%s\n' "${JAVA_TOOL_OPTIONS:-}"
    printf 'env:TMPDIR=%s\n' "${TMPDIR:-}"
    printf 'cwd:%s\n' "$(pwd -P)"
} >"$SM_H/log/mvn-args.$seq"

goals="" out="" gran=0 ver=0 stop=0 compiled=none
for a in "$@"; do
    case $a in
        --version|-v) ver=1 ;;
        --stop) stop=1 ;;
        -Dmdep.outputFile=*) out=${a#-Dmdep.outputFile=} ;;
        -DlastModGranularityMs=*) gran=${a#-DlastModGranularityMs=} ;;
        -*) ;;
        *) goals="${goals:+$goals,}$a" ;;
    esac
done
has_goal() { case ",$goals," in *",$1,"*) return 0 ;; esac; return 1; }
finish() { echo "END $seq rc=$1 $2" >>"$LOG"; exit "$1"; }

# What `mvnw --version` does the first time: download, unpack into TMPDIR, and
# mv the result into place - which ensure_wrapper serialises with flock.
install_dist() {
    url=$(sed -n 's/^distributionUrl=//p' .mvn/wrapper/maven-wrapper.properties 2>/dev/null | tr -d '\r')
    dist=${MAVEN_USER_HOME:-${HOME:-/root}/.m2}/wrapper/dists/apache-maven-3.9.16-bin/smfake
    if [ -f "$dist/bin/mvn" ] && [ -f "$dist/lib/maven-core-3.9.16.jar" ] && [ -f "$dist/boot/plexus-classworlds-2.9.0.jar" ]; then
        return 0
    fi
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/smfake.XXXXXX") || return 1
    mkdir -p "$tmp/d/bin" "$tmp/d/lib" "$tmp/d/boot" &&
        printf '#!/bin/sh\nexit 0\n' >"$tmp/d/bin/mvn" &&
        : >"$tmp/d/lib/maven-core-3.9.16.jar" &&
        : >"$tmp/d/boot/plexus-classworlds-2.9.0.jar" &&
        printf '%s\n' "$url" >"$tmp/d/mvnw.url" &&
        rm -rf "$dist" && mkdir -p "${dist%/*}" && mv "$tmp/d" "$dist" || return 1
    rm -rf "$tmp"
    echo "INSTALL $seq $dist" >>"$LOG"
}

if [ "$stop" = 1 ]; then echo "DAEMON-STOP $seq $SM_TOOL" >>"$LOG"; exit 0; fi
if [ "$ver" = 1 ]; then
    echo "VERSION $seq $SM_TOOL" >>"$LOG"
    if [ "$SM_TOOL" = mvnw ] && ! install_dist; then
        echo "[ERROR] (fake mvnw) could not install the wrapper's distribution"
        exit 1
    fi
    echo "Apache Maven 3.9.16 (fake $SM_TOOL)"
    exit 0
fi

# Only the pre-rewrite dev-reload.sh asks for this: it ran the application
# through the plugin, which forked the JVM. The fake java stands in for it.
if has_goal spring-boot:run; then
    echo "SPRING-BOOT-RUN $seq $SM_TOOL" >>"$LOG"
    exec "$SM_H/java" -XX:TieredStopAtLevel=1 -cp "$(pwd)/target/classes:$SM_H/deps/dep-a.jar:$SM_H/deps/dep-b.jar" demo.App
fi

# The source list is read FIRST, as javac reads its sources when it starts:
# an edit made while this build "works" is not in it.
srcs=""
if [ -d src/main/java ]; then
    srcs=$(cd src/main/java && find . -type f -name '*.java' | sed 's|^\./||' | LC_ALL=C sort)
fi
echo "BEGIN $seq $SM_TOOL $(cs) goals=$goals sources=$(printf '%s' "$srcs" | tr '\n' ',')" >>"$LOG"

if [ -f "$CTL/fail-once" ]; then
    rm -f "$CTL/fail-once"
    echo "[ERROR] (fake) Could not transfer artifact demo:dep-a:jar:1 - a transient failure (ctl/fail-once)"
    finish 1 fail-once
fi
rc=$(cat "$CTL/rc" 2>/dev/null) || rc=0
case $rc in ''|0) ;; *) echo "[ERROR] (fake) failing with exit $rc (ctl/rc)"; finish "$rc" forced ;; esac
if grep -q SM_BROKEN pom.xml 2>/dev/null; then
    echo "[ERROR] (fake) Non-parseable POM $(pwd)/pom.xml"
    finish 1 broken-pom
fi
delay=$(cat "$CTL/delay" 2>/dev/null) || delay=0
case $delay in ''|0) ;; *) sleep "$delay" ;; esac

if has_goal compile; then
    mkdir -p target/classes
    # maven-resources-plugin: copies, never deletes.
    if [ -d src/main/resources ]; then cp -R src/main/resources/. target/classes/; fi
    # maven-compiler-plugin's staleness check: a source list that differs from
    # its record of the last one (inputFiles.lst - so a deleted record makes
    # everything stale), a class missing, or a source newer than its class by
    # more than the granularity. Without either, a source whose mtime is behind
    # its class - clock skew, a backdated edit - is "up to date".
    status=target/maven-status/maven-compiler-plugin/compile/default-compile
    stale=0
    [ "$(cat "$status/inputFiles.lst" 2>/dev/null)" = "$srcs" ] || stale=1
    for s in $srcs; do
        [ "$stale" = 0 ] || break
        c=target/classes/${s%.java}.class
        if [ ! -f "$c" ]; then stale=1; break; fi
        if awk -v s="$(mtime "src/main/java/$s")" -v c="$(mtime "$c")" -v g="$gran" \
               'BEGIN { exit !(s + 0 > c + g / 1000) }'; then stale=1; fi
    done
    if [ "$stale" = 0 ]; then
        echo "[INFO] (fake) Nothing to compile - all classes are up to date"
        compiled=nothing
    else
        echo "[INFO] (fake) Changes detected - recompiling the module!"
        # maven-shared-incremental, before javac runs - and not undone when
        # javac fails: every class of the previous compile goes.
        find target/classes -type f -name '*.class' -exec rm -f {} +
        rm -rf "$status"
        for s in $srcs; do
            if grep -q SM_BROKEN "src/main/java/$s" 2>/dev/null; then
                echo "[ERROR] COMPILATION ERROR : src/main/java/$s:[1,1] (fake) SM_BROKEN"
                finish 1 compile-error
            fi
        done
        created=""
        for s in $srcs; do
            r=${s%.java}
            if [ ! -f "$SM_PRE/classes/$r.class" ]; then
                echo "[ERROR] (fake) there is no precompiled class for $s"
                finish 1 no-precompiled-class
            fi
            mkdir -p "target/classes/$(dirname "$r")"
            cp "$SM_PRE/classes/$r.class" "target/classes/$r.class"
            created="$created$r.class
"
        done
        mkdir -p "$status"
        printf '%s\n' "$srcs" >"$status/inputFiles.lst"
        printf '%s' "$created" >"$status/createdFiles.lst"
        compiled=$(printf '%s' "$srcs" | grep -c .)
    fi
fi

if has_goal dependency:build-classpath; then
    deps="$SM_H/deps/dep-a.jar:$SM_H/deps/dep-b.jar"
    if grep -q SM_EXTRA_DEP pom.xml 2>/dev/null; then deps="$deps:$SM_H/deps/dep-c.jar"; fi
    mode=$(cat "$CTL/cp" 2>/dev/null) || mode=ok
    case $mode in
        fail)
            echo "[ERROR] (fake) Failed to execute goal maven-dependency-plugin:build-classpath: Could not resolve dependencies (ctl/cp=fail)"
            finish 1 classpath-failed ;;
        missing) deps="$deps:$SM_H/deps/never-downloaded.jar" ;;
        empty) deps="" ;;
    esac
    if [ -z "$out" ]; then
        echo "[ERROR] (fake) dependency:build-classpath without -Dmdep.outputFile"
        finish 1 no-output-file
    fi
    mkdir -p "$(dirname "$out")"
    printf '%s' "$deps" >"$out"
fi
finish 0 "compiled=$compiled"
EOF
    } >"$2"
    chmod +x "$2"
}

# The traps are set before START is logged: a TERM arriving between the two
# must already be answered the way the case asked for.
sm_write_fake_java() {
    { sm_fake_head "Fake java"; cat <<'EOF'
if [ -f "$CTL/java-ignore-term" ]; then
    trap 'echo "TERM-IGNORED $$ $(cs)" >>"$SM_H/log/java.log"' TERM
else
    trap 'echo "STOP $$" >>"$SM_H/log/java.log"; exit 143' TERM
fi
for a in "$@"; do printf '%s\n' "$a"; done >"$SM_H/log/java-argv.$$"
pwd -P >"$SM_H/log/java-cwd.$$" 2>/dev/null
echo "$(cs) START $$" >>"$SM_H/log/java-times.log"
echo "START $$ $*" >>"$SM_H/log/java.log"
echo "FAKEJAVA-STDERR $$: written to stderr, so it only reaches dev-reload's stdout through 2>&1" >&2
while :; do
    if [ -f "$CTL/java-crash" ]; then
        echo "CRASH $$" >>"$SM_H/log/java.log"
        exit 1
    fi
    # The case is over. The last resort for a fake java that ignores SIGTERM
    # under a script that never escalates, where there is no process group.
    if [ -f "$CTL/java-exit" ]; then
        echo "EXIT $$ (the case is over)" >>"$SM_H/log/java.log"
        exit 0
    fi
    sleep 0.5
done
EOF
    } >"$SM_H/java"
    chmod +x "$SM_H/java"
}

# curl -s -o /dev/null -m <n> -w '%{http_code}' <url>, as app_answers calls it;
# the URL does not matter here. Like the real one, it prints 000 and fails
# when nothing answers.
sm_write_fake_curl() {
    { sm_fake_head "Fake curl"; cat <<'EOF'
code=$(cat "$CTL/http" 2>/dev/null) || code=000
[ -n "$code" ] || code=000
fmt=""
while [ $# -gt 0 ]; do
    case $1 in
        -w|--write-out) fmt=${2:-}; [ $# -lt 2 ] || shift ;;
        -o|--output|-m|--max-time) [ $# -lt 2 ] || shift ;;
    esac
    shift
done
echo "CURL $code" >>"$SM_H/log/curl.log"
printf '%s' "$fmt" | sed "s/%{http_code}/$code/g"
[ "$code" != 000 ] || exit 7
exit 0
EOF
    } >"$SM_H/bin/curl"
    chmod +x "$SM_H/bin/curl"
}

# For DEV_COMPILER=mvnw: shadows the image's real mvnd, which dev-reload.sh
# must not call at all then - and which the pre-rewrite script would otherwise
# pick up and run against a network that is not there.
sm_write_mvnd_stub() {
    { sm_fake_head "Disabled mvnd"; cat <<'EOF'
echo "MVND-STUB $*" >>"$SM_H/log/mvn.log"
echo "mvnd: disabled by unit-state-machine.sh for a DEV_COMPILER=mvnw run" >&2
exit 1
EOF
    } >"$SM_H/bin/mvnd"
    chmod +x "$SM_H/bin/mvnd"
}

# A fresh project for one case: pom, wrapper properties, one resource, App as
# the only source; a target/ with a trigger file from "an earlier run" (two
# hours old, so that any touch shows); a complete wrapper distribution; the
# fakes; empty logs; the probe answering 200.
sm_fixture() {
    rm -rf "$SM_P"
    mkdir -p "$SM_P/src/main/java/demo" "$SM_P/src/main/resources" "$SM_P/.mvn/wrapper" \
             "$SM_P/target/classes" "$SM_H/bin" "$SM_H/ctl" "$SM_H/log" "$SM_H/deps" "$SM_H/tmp"
    SM_PREAL=$(cd "$SM_P" && pwd -P)
    sm_write_pom ""
    printf '%s\n' "wrapperVersion=3.3.4" "distributionType=only-script" "distributionUrl=$SM_DIST_URL" \
        >"$SM_P/.mvn/wrapper/maven-wrapper.properties"
    printf '%s\n' "spring.application.name=sm-fixture" >"$SM_P/src/main/resources/application.properties"
    sm_write_src App
    for _dj in dep-a dep-b dep-c; do
        printf '%s\n' "dummy jar of unit-state-machine.sh: only its existence is checked" >"$SM_H/deps/$_dj.jar"
    done
    : >"$SM_P/target/classes/.reloadtrigger"
    sm_backdate 2 "$SM_P/target/classes/.reloadtrigger"
    sm_install_dist complete
    for _lf in loop.out loop.err java.log java-times.log mvn.log curl.log; do : >"$SM_H/log/$_lf"; done
    sm_ctl http 200
    sm_write_fake_maven mvnw "$SM_P/mvnw"
    if [ "$SM_COMPILER" = mvnd ]; then sm_write_fake_maven mvnd "$SM_H/bin/mvnd"; else sm_write_mvnd_stub; fi
    sm_write_fake_java
    sm_write_fake_curl
}

# ---------------------------------------------------------------------------
# The loop under test
# ---------------------------------------------------------------------------

# The environment is emptied of everything that could steer the script, then
# given exactly the settings of the case. The subshell execs, so $! is the
# loop's own pid - and with setsid, its process group too.
sm_start() {
    (
        unset DEV_JVM_ARGS DEV_MAIN_CLASS DEV_MAVEN_EXTRA_ARGS DEV_MAVEN_QUIET DEV_OPTIMIZED_LAUNCH \
              DEV_RELOAD_LIB_ONLY DEV_RELOAD_FAIL_SECS SPRING_DEVTOOLS_RESTART_TRIGGER_FILE \
              JAVA_TOOL_OPTIONS JDK_JAVA_OPTIONS MAVEN_OPTS MAVEN_ARGS
        export DEV_APP_DIR="$SM_P" DEV_COMPILER="$SM_COMPILER" DEV_RELOAD_INTERVAL="$SM_INTERVAL" \
               DEV_RESTART_DELAY="$SM_RESTART_DELAY" DEV_BUILD_RETRY_DELAY="$SM_RETRY_DELAY" \
               DEV_READY_APPEAR="$SM_READY_APPEAR" DEV_BOOT_TIMEOUT="$SM_BOOT_TIMEOUT" \
               DEV_STOP_TIMEOUT="$SM_STOP_TIMEOUT" DEV_APP_PORT="$SM_PORT" \
               DEV_JAVA="$SM_H/java" MAVEN_USER_HOME="$SM_P/m2" PATH="$SM_H/bin:$PATH"
        for _kv in $SM_ENV; do export "$_kv"; done
        cd "$SM_P" || exit 1
        exec $SM_SETSID sh "$SM_RUN_SCRIPT"
    ) >"$SM_OUT" 2>"$SM_ERR" </dev/null &
    SM_LOOP_PID=$!
    SM_PGID=""
    # Until setsid has run, the child is still in THIS script's group, which
    # must never be killed - so the group is trusted only once it is its own.
    if [ -n "$SM_SETSID" ] && [ "$SM_CANLIST" = 1 ]; then
        _sg=0
        while [ "$_sg" -lt 40 ]; do
            if [ "$(sm_pgid "$SM_LOOP_PID")" = "$SM_LOOP_PID" ]; then SM_PGID=$SM_LOOP_PID; break; fi
            sleep 0.05; _sg=$((_sg + 1))
        done
    fi
}

# Ends the loop the way docker does - SIGTERM, then SIGKILL - and then kills
# whatever of the case is still around, so that nothing leaks into the next.
# A loop that is already gone exited by itself, which dev-reload.sh must never
# do: a watcher that dies is useless exactly when it is needed.
sm_stop_loop() {
    [ -n "$SM_LOOP_PID" ] || return 0
    SM_DEADLINE=$(( $(sm_cs) + 6000 ))     # the case's own limit no longer applies
    if [ "$SM_LOOP_DONE" = 0 ]; then
        if sm_alive "$SM_LOOP_PID"; then
            kill -TERM "$SM_LOOP_PID" 2>/dev/null
            # stop_app may wait DEV_STOP_TIMEOUT for a JVM that ignores TERM.
            if ! sm_wait $((SM_STOP_TIMEOUT + 7)) sm_dead "$SM_LOOP_PID"; then
                sm_fail "dev-reload.sh was still running $((SM_STOP_TIMEOUT + 7))s after SIGTERM, so it was killed"
            fi
        else
            _sl_rc=0
            wait "$SM_LOOP_PID" 2>/dev/null || _sl_rc=$?
            SM_LOOP_DONE=1
            sm_fail "dev-reload.sh exited by itself with status $_sl_rc (its stderr is in the evidence)"
        fi
    fi
    # The group is killed even when the loop has gone: its orphans keep the
    # group id. The pid only while it is still ours - a reaped one is free.
    [ -z "$SM_PGID" ] || kill -KILL "-$SM_PGID" 2>/dev/null
    if [ "$SM_LOOP_DONE" = 0 ]; then
        kill -KILL "$SM_LOOP_PID" 2>/dev/null
        # wait only for a process that is known to be gone: it must not hang.
        if sm_wait 5 sm_dead "$SM_LOOP_PID"; then wait "$SM_LOOP_PID" 2>/dev/null; fi
        SM_LOOP_DONE=1
    fi
    sm_find_procs "$SM_P/"
    if [ -n "$SM_MATCH" ]; then
        printf '%s\n' "still running after the loop ended, killed: $(sm_describe_procs $SM_MATCH)" >>"$SM_ERR"
        kill -KILL $SM_MATCH 2>/dev/null
    fi
    # Without /proc or setsid none of the above can see an orphaned JVM, so
    # every fake java of this case is also told to go, and given a moment to.
    : >"$SM_H/ctl/java-exit"
    for _sl_p in $(awk '$1 == "START" { print $2 }' "$SM_JLOG"); do sm_wait 2 sm_dead "$_sl_p" || :; done
    SM_LOOP_PID="" SM_PGID=""
}

# ---------------------------------------------------------------------------
# Shared checks
# ---------------------------------------------------------------------------

# Up and idle: the first JVM has started and, for a script that logs the
# contract's markers, reported ready. The pre-rewrite script logs no markers;
# for it, idle is two quiet seconds after the START.
sm_booted() {
    if ! sm_wait 25 sm_java_ge START 1; then sm_fail "boot: no START within 25s of starting the loop"; return 1; fi
    if [ "$SM_LEGACY" = 1 ]; then sm_quiet 2 10 || :; return 0; fi
    if ! sm_wait 10 sm_ev_ge app-ready 1; then sm_fail "boot: no app-ready within 10s of the START"; return 1; fi
    return 0
}

# The launch from the JVM's side: argv in spring-boot:run's order (RunMojo:
# the optimisation flag first, then jvmArguments - none here - then the
# classpath with the ABSOLUTE classes directory first, then the main class),
# the project as working directory, and stderr merged into stdout.
sm_check_launch() {   # WHICH-START EXPECTED-DEPENDENCY-CLASSPATH
    _cl_pid=$(sm_java_pid START "$1")
    if [ -z "$_cl_pid" ]; then sm_fail "launch $1: there was no such START"; return; fi
    _cl_want=$(printf '%s\n' -XX:TieredStopAtLevel=1 -cp "$SM_P/target/classes:$2" demo.App)
    _cl_got=$(cat "$SM_H/log/java-argv.$_cl_pid" 2>/dev/null)
    [ "$_cl_got" = "$_cl_want" ] || sm_fail "launch $1 argv: expected [$(echo $_cl_want)], got [$(echo $_cl_got)]"
    _cl_cwd=$(cat "$SM_H/log/java-cwd.$_cl_pid" 2>/dev/null)
    [ "$_cl_cwd" = "$SM_PREAL" ] || sm_fail "launch $1 working directory: expected $SM_PREAL, got ${_cl_cwd:-nothing}"
    grep -q "^FAKEJAVA-STDERR $_cl_pid:" "$SM_OUT" ||
        sm_fail "launch $1: the JVM's stderr did not reach dev-reload's stdout (no 2>&1)"
}

# The flags the fake Maven was actually given for the first full build: the
# lock settings on every build, and on the JVM that loads the lock class - the
# daemon's for mvnd, the wrapper's through MAVEN_OPTS for mvnw.
sm_check_maven_flags() {
    _mf_seq=$(awk '$1 == "BEGIN" && / goals=([^ ]*,)?dependency:build-classpath(,| )/ { print $2; exit }' "$SM_MLOG")
    _mf=$SM_H/log/mvn-args.${_mf_seq:-none}
    if [ ! -f "$_mf" ]; then sm_fail "no full build to check the Maven flags of"; return; fi
    for _mf_w in --batch-mode -Daether.syncContext.named.factory=file-lock \
                 -Daether.syncContext.named.nameMapper=file-gav -DlastModGranularityMs=-86400000 \
                 "-Dmdep.outputFile=$SM_P/target/dev-classpath.txt" -DincludeScope=runtime; do
        grep -qxF -- "arg:$_mf_w" "$_mf" || sm_fail "the full build was not given $_mf_w"
    done
    if [ "$SM_COMPILER" = mvnd ]; then
        grep -qxF -- "arg:-Dmvnd.daemonStorage=/tmp/mvnd" "$_mf" ||
            sm_fail "mvnd was not given -Dmvnd.daemonStorage=/tmp/mvnd"
        # In the environment the daemon inherits: mvnd 1.0.2 drops it from
        # -Dmvnd.jvmArgs (the project's .mvn/jvm.config replaces them) and
        # from JDK_JAVA_OPTIONS (its own --add-opens list replaces that).
        grep -q '^env:JAVA_TOOL_OPTIONS=\(.* \)\{0,1\}-Daether\.named\.file-lock\.deleteLockFiles=false\( .*\)\{0,1\}$' "$_mf" ||
            sm_fail "mvnd ran without -Daether.named.file-lock.deleteLockFiles=false in JAVA_TOOL_OPTIONS, which is how it reaches the daemon's JVM"
    else
        grep -q '^env:MAVEN_OPTS=.*-Daether\.named\.file-lock\.deleteLockFiles=false' "$_mf" ||
            sm_fail "./mvnw ran without -Daether.named.file-lock.deleteLockFiles=false in MAVEN_OPTS"
        grep -qxF -- "env:TMPDIR=$SM_P/m2/wrapper/tmp" "$_mf" ||
            sm_fail "./mvnw ran without TMPDIR on the Maven volume ($SM_P/m2/wrapper/tmp)"
        sm_expect_eq "mvnd invocations with DEV_COMPILER=mvnw" 0 "$(sm_mvn_n MVND-STUB)"
    fi
}

# The half-copied distribution is replaced, once, by ./mvnw --version - in
# both modes, since the wrapper is installed up front even for mvnd.
sm_check_wrapper() {
    _cw=$SM_P/m2/$SM_DIST_REL
    [ ! -e "$_cw/bin/sm-partial" ] || sm_fail "the incomplete wrapper distribution was not removed"
    [ -f "$_cw/lib/maven-core-3.9.16.jar" ] || sm_fail "no complete wrapper distribution after start-up"
    sm_expect_eq "wrapper installs (./mvnw --version)" 1 "$(sm_mvn_n INSTALL)"
    sm_ev_ge wrapper 1 || sm_fail "no 'wrapper' marker for the install"
}

# ---------------------------------------------------------------------------
# The cases. Each prepares its fixture, starts the loop, drives it, and
# records failures with sm_fail; returning early is fine - the runner stops
# the loop and reports.
# ---------------------------------------------------------------------------

case_boot() {
    SM_WHAT="1 build-start, 1 START, app-ready only once curl answers 200; launch argv/cwd/2>&1; lock flags on the build; incomplete wrapper distribution replaced"
    sm_install_dist partial
    sm_ctl http 000
    sm_start
    if ! sm_wait 25 sm_java_ge START 1; then sm_fail "no START within 25s"; return; fi
    sm_wait 5 sm_ev_ge app-started 1 || sm_fail "no app-started marker"
    sm_holds 2 sm_ev_eq app-ready 0 || sm_fail "app-ready while the probe still got 000"
    sm_ctl http 200
    sm_wait 6 sm_ev_ge app-ready 1 || sm_fail "no app-ready within 6s of the probe answering 200"
    sm_quiet 2 8 || :
    sm_expect_eq "build-start markers" 1 "$(sm_ev_n build-start)"
    sm_expect_eq "builds" 1 "$(sm_mvn_n compile)"
    sm_expect_eq "full builds (compile + build-classpath)" 1 "$(sm_mvn_n full)"
    sm_expect_eq "START lines" 1 "$(sm_java_n START)"
    sm_expect_eq "STOP lines" 0 "$(sm_java_n STOP)"
    sm_expect_eq "app-ready markers" 1 "$(sm_ev_n app-ready)"
    sm_expect_eq "boot-timeout markers" 0 "$(sm_ev_n boot-timeout)"
    sm_expect "no 'main-class: demo.App' marker" grep -q '^\[dev-reload\] main-class: demo\.App$' "$SM_OUT"
    sm_check_launch 1 "$SM_DEPS"
    sm_check_maven_flags
    sm_check_wrapper
}

case_src_edit() {
    SM_WHAT="an edit in src/main: 1 compile, trigger-touched, trigger mtime changed, same JVM (0 STOP)"
    sm_start
    sm_booted || return
    _t0=$(sm_trigger); _pid=$(sm_java_pid START 1); _n=$(sm_mvn_n compile)
    sm_append src/main/java/demo/App.java "// src-edit"
    sm_wait 15 sm_ev_ge trigger-touched 1 || sm_fail "no trigger-touched within 15s of the edit"
    sm_quiet 2 10 || :
    sm_expect "the trigger's mtime did not change ($_t0)" sm_trigger_changed "$_t0"
    sm_expect_eq "builds after the edit" "$((_n + 1))" "$(sm_mvn_n compile)"
    sm_expect_eq "full builds" 1 "$(sm_mvn_n full)"
    sm_expect_eq "STOP lines" 0 "$(sm_java_n STOP)"
    sm_expect_eq "START lines" 1 "$(sm_java_n START)"
    sm_expect "the JVM (pid $_pid) is gone" sm_alive "$_pid"
}

case_failed_src_edit() {
    SM_WHAT="an edit that does not compile: compile-failed, classes-restored, trigger untouched, 0 STOP, the JVM still running"
    sm_start
    sm_booted || return
    _t0=$(sm_trigger); _pid=$(sm_java_pid START 1)
    sm_append src/main/java/demo/App.java "SM_BROKEN this line does not compile"
    sm_wait 15 sm_ev_ge compile-failed 1 || { sm_fail "no compile-failed within 15s of the edit"; return; }
    sm_wait 5 sm_ev_ge classes-restored 1 || sm_fail "no classes-restored after the failed compile"
    # The one automatic retry of a failed compile fails the same way; what is
    # checked is the state after both.
    if sm_wait 2 sm_ev_ge build-retry-scheduled 1; then
        sm_wait $((SM_RETRY_DELAY + 8)) sm_ev_ge compile-failed 2 || sm_note "the scheduled retry did not run"
    fi
    sm_quiet 2 10 || :
    [ "$(sm_trigger)" = "$_t0" ] || sm_fail "the trigger's mtime changed ($_t0 -> $(sm_trigger))"
    sm_expect_eq "trigger-touched markers" 0 "$(sm_ev_n trigger-touched)"
    sm_expect_eq "STOP lines" 0 "$(sm_java_n STOP)"
    sm_expect_eq "START lines" 1 "$(sm_java_n START)"
    sm_expect "the JVM (pid $_pid) is gone" sm_alive "$_pid"
    sm_expect "target/classes/demo/App.class is missing: the last good classes were not put back" \
        sm_is_file "$SM_P/target/classes/demo/App.class"
}

case_pom_edit() {
    SM_WHAT="a pom.xml edit: build-changed, exactly one STOP then one START, the new JVM on the new classpath"
    sm_start
    sm_booted || return
    _pid1=$(sm_java_pid START 1)
    sm_write_pom "<!-- SM_EXTRA_DEP: one more dependency -->"
    sm_wait 20 sm_java_ge START 2 || sm_fail "no second START within 20s of the pom edit"
    sm_quiet 3 12 || :
    sm_expect_eq "build-changed markers" 1 "$(sm_ev_n build-changed)"
    sm_expect_eq "JVM events" "START STOP START" "$(sm_java_seq)"
    sm_expect_eq "the pid that was stopped" "$_pid1" "$(sm_java_pid STOP 1)"
    _pid2=$(sm_java_pid START 2)
    if [ -n "$_pid2" ]; then
        sm_expect "the new JVM (pid $_pid2) is not running" sm_alive "$_pid2"
        sm_check_launch 2 "$SM_DEPS:$SM_H/deps/dep-c.jar"
    fi
    sm_expect "the old JVM (pid $_pid1) is still running" sm_dead "$_pid1"
    if [ "$SM_COMPILER" = mvnd ]; then
        # mvnd caches resolved dependencies across builds; the daemon has to go
        # BEFORE the build that is to see the new pom.
        awk '$1 == "DAEMON-STOP" && !s { s = NR }
             $1 == "BEGIN" && / goals=([^ ]*,)?dependency:build-classpath(,| )/ { if (++f == 2) b = NR }
             END { exit !(s && b && s < b) }' "$SM_MLOG" ||
            sm_fail "mvnd --stop did not run before the rebuild"
    fi
}

case_broken_pom() {
    SM_WHAT="a pom.xml that does not build: build-failed and build-broken, 0 STOP; then one that builds but whose classpath cannot launch: launch-refused, still 0 STOP; the JVM running throughout"
    sm_start
    sm_booted || return
    _pid=$(sm_java_pid START 1)
    sm_write_pom "<!-- SM_BROKEN: the fake Maven refuses this pom -->"
    sm_wait 15 sm_ev_ge build-broken 1 || sm_fail "no build-broken within 15s of the pom edit"
    # Long enough for the first automatic retry, which fails the same way.
    sm_holds $((SM_RETRY_DELAY + 2)) sm_java_eq STOP 0 || sm_fail "the JVM was stopped after the broken pom"
    sm_expect "no build-failed marker" sm_ev_ge build-failed 1
    sm_expect "target/classes/demo/App.class is missing" sm_is_file "$SM_P/target/classes/demo/App.class"
    # Built, but not launchable: the old JVM must be left alone, not stopped
    # first and then found to have no successor.
    sm_ctl cp missing
    sm_write_pom "<!-- builds, but its classpath names a jar that was never downloaded -->"
    sm_wait 15 sm_ev_ge launch-refused 1 || sm_fail "no launch-refused within 15s of a pom whose classpath cannot launch"
    sm_holds 2 sm_java_eq STOP 0 || :
    sm_expect_eq "STOP lines" 0 "$(sm_java_n STOP)"
    sm_expect_eq "START lines" 1 "$(sm_java_n START)"
    sm_expect "the JVM (pid $_pid) is gone" sm_alive "$_pid"
}

case_first_build_fails_then_fix() {
    SM_WHAT="the first build fails: no START while broken, the loop stays up, and the fix gives exactly 1 START"
    sm_write_src App "SM_BROKEN this line does not compile"
    sm_start
    sm_wait 15 sm_ev_ge build-failed 1 || { sm_fail "no build-failed within 15s"; return; }
    sm_holds 3 sm_java_eq START 0 || sm_fail "a JVM was started from a failed build"
    sm_expect "the loop exited after the failed first build" sm_alive "$SM_LOOP_PID"
    sm_write_src App
    sm_wait 20 sm_java_ge START 1 || sm_fail "no START within 20s of the fix"
    sm_quiet 3 12 || :
    sm_expect_eq "START lines" 1 "$(sm_java_n START)"
    sm_expect_eq "STOP lines" 0 "$(sm_java_n STOP)"
}

case_classpath_fails() {
    SM_WHAT="build-classpath fails, then writes a jar that is not there: build-failed, no stale classpath file, classpath-error, launch-refused, 0 START"
    sm_ctl cp fail
    sm_start
    sm_wait 15 sm_ev_ge build-failed 1 || { sm_fail "no build-failed within 15s"; return; }
    sm_expect "a failed build left target/dev-classpath.txt behind" sm_no_file "$SM_P/target/dev-classpath.txt"
    # A pom edit forces the next full build now, rather than relying on when
    # the automatic retry comes round; either way it reaches the same check.
    sm_ctl cp missing
    sm_write_pom "<!-- the classpath now names a jar that was never downloaded -->"
    sm_wait 15 sm_ev_ge launch-refused 1 || sm_fail "no launch-refused within 15s"
    sm_holds 2 sm_java_eq START 0 || :
    sm_expect "no classpath-error marker for the missing jar" sm_ev_ge classpath-error 1
    sm_expect_eq "START lines" 0 "$(sm_java_n START)"
    sm_expect "the loop exited" sm_alive "$SM_LOOP_PID"
}

case_crash_backoff() {
    SM_WHAT="an application that keeps crashing: restart-scheduled at 1,2,4,8,16s, each delay honoured, restart-exhausted after 5, 6 STARTs, then no more"
    sm_ctl_on java-crash
    sm_start
    sm_wait 90 sm_ev_ge restart-exhausted 1 || { sm_fail "no restart-exhausted within 90s"; return; }
    _n=$(sm_java_n START)
    sm_holds 3 sm_java_eq START "$_n" || sm_fail "a JVM was started after restart-exhausted"
    _delays=$(sed -n 's/^\[dev-reload\] restart-scheduled: [^0-9]*\([0-9][0-9]*\)s.*/\1/p' "$SM_OUT" | tr '\n' ' ')
    _delays=${_delays% }
    sm_expect_eq "restart-scheduled delays (s)" "1 2 4 8 16" "$_delays"
    sm_expect_eq "restart-exhausted markers" 1 "$(sm_ev_n restart-exhausted)"
    sm_expect_eq "START lines (1 + 5 restarts)" 6 "$(sm_java_n START)"
    sm_expect_eq "app-exited markers" 6 "$(sm_ev_n app-exited)"
    sm_expect_eq "STOP lines" 0 "$(sm_java_n STOP)"
    # A delay that is only logged is not a backoff. now() counts whole
    # seconds, so a restart may come up to a second early.
    _early=$(awk -v d="$_delays" 'BEGIN { n = split(d, D, " ") }
        $2 == "START" { t[++k] = $1 }
        END { for (i = 1; i <= n && i < k; i++)
                  if (t[i + 1] - t[i] < (D[i] - 1) * 100)
                      printf "restart %d came %.1fs after the crash it followed, before its %ss; ", i, (t[i + 1] - t[i]) / 100, D[i] }' "$SM_JTIMES")
    [ -z "$_early" ] || sm_fail "$_early"
    sm_note "delays $_delays"
}

case_sigterm() {
    SM_WHAT="SIGTERM to the loop: stopping, the JVM gets STOP, exit status 0, no fake java left running"
    sm_start
    sm_booted || return
    _pid=$(sm_java_pid START 1)
    kill -TERM "$SM_LOOP_PID"
    if ! sm_wait 15 sm_dead "$SM_LOOP_PID"; then sm_fail "the loop was still running 15s after SIGTERM"; return; fi
    _rc=0
    wait "$SM_LOOP_PID" 2>/dev/null || _rc=$?
    SM_LOOP_DONE=1
    sm_expect_eq "exit status after SIGTERM" 0 "$_rc"
    sm_expect "no stopping marker" sm_ev_ge stopping 1
    sm_expect_eq "the pid that logged STOP" "$_pid" "$(sm_java_pid STOP 1)"
    sm_expect "the JVM (pid $_pid) outlived the loop" sm_dead "$_pid"
    if [ "$SM_CANLIST" = 1 ]; then
        if ! sm_wait 3 sm_no_procs "$SM_H/java"; then
            sm_fail "fake java still running after the loop exited: $(sm_describe_procs $SM_MATCH)"
        fi
        if [ -n "$SM_PGID" ]; then
            sm_group_procs "$SM_PGID"
            [ -z "$SM_MATCH" ] || sm_fail "left in the loop's process group: $(sm_describe_procs $SM_MATCH)"
        fi
    else
        sm_note "no /proc here: the orphan check was not made"
    fi
}

case_edit_during_compile() {
    SM_WHAT="an edit made while a compile is running (fake compile sleeps 3s) gets a second compile, and its class is served"
    sm_start
    sm_booted || return
    _n=$(sm_mvn_n compile)
    sm_ctl delay 3
    sm_write_src Probe1
    sm_wait 15 sm_mvn_ge compile $((_n + 1)) || { sm_fail "no compile within 15s of adding Probe1.java"; return; }
    # The fake logs BEGIN only after it has read its source list, so this
    # edit is guaranteed to miss the running compile.
    sm_write_src Probe2
    sm_ctl delay 0
    sm_wait 25 sm_is_file "$SM_P/target/classes/demo/Probe2.class" ||
        sm_fail "Probe2.class never appeared: the edit made during the compile was lost"
    sm_quiet 4 15 || :
    case $(sm_mvn_begin "$SM_RE_COMPILE" $((_n + 1))) in
        *Probe2*) sm_note "the first compile already saw Probe2.java, so this proved less than it should" ;;
    esac
    sm_expect_eq "compiles after the first edit" "$((_n + 2))" "$(sm_mvn_n compile)"
    sm_expect "target/classes/demo/Probe1.class is missing" sm_is_file "$SM_P/target/classes/demo/Probe1.class"
    sm_expect_eq "trigger-touched markers" 2 "$(sm_ev_n trigger-touched)"
    sm_expect_eq "STOP lines" 0 "$(sm_java_n STOP)"
    sm_expect_eq "START lines" 1 "$(sm_java_n START)"
}

case_ignore_term() {
    SM_WHAT="a JVM that ignores SIGTERM, on a pom change: app-killed within DEV_STOP_TIMEOUT (${SM_STOP_TIMEOUT}s), then a new START"
    sm_ctl_on java-ignore-term
    sm_start
    sm_booted || return
    _pid=$(sm_java_pid START 1)
    sm_write_pom "<!-- ignore-term: this edit asks for a new JVM -->"
    sm_wait 20 sm_java_ge TERM-IGNORED 1 || { sm_fail "the JVM never got SIGTERM after the pom edit"; return; }
    _t1=$(awk '$1 == "TERM-IGNORED" { print $3; exit }' "$SM_JLOG")
    if sm_wait $((SM_STOP_TIMEOUT + 7)) sm_dead "$_pid"; then
        _t2=$(sm_cs)
        _dt=$(( _t2 - ${_t1:-$_t2} ))
        [ "$_dt" -le $(( (SM_STOP_TIMEOUT + 2) * 100 )) ] ||
            sm_fail "the JVM was killed $((_dt / 100)).$((_dt % 100 / 10))s after it ignored SIGTERM, not within ${SM_STOP_TIMEOUT}s"
        sm_note "killed $((_dt / 100)).$((_dt % 100 / 10))s after ignoring SIGTERM"
    else
        sm_fail "the JVM (pid $_pid) was still running $((SM_STOP_TIMEOUT + 7))s after it ignored SIGTERM"
    fi
    sm_expect "no app-killed marker" sm_ev_ge app-killed 1
    sm_wait 10 sm_java_ge START 2 || sm_fail "no new START after the kill"
    sm_expect_eq "STOP lines (the JVM never stopped cleanly)" 0 "$(sm_java_n STOP)"
}

case_main_missing_at_boot() {
    SM_WHAT="no @SpringBootApplication class at boot: main-class-error, no START, the loop stays up; adding one gives exactly 1 START"
    rm -f "$SM_P/src/main/java/demo/App.java"
    sm_write_src Plain
    sm_start
    sm_wait 15 sm_ev_ge main-class-error 1 || { sm_fail "no main-class-error within 15s"; return; }
    sm_wait 5 sm_ev_ge watching 1 || sm_fail "no watching marker: the loop did not go on"
    sm_holds 2 sm_java_eq START 0 || sm_fail "a JVM was started without a main class (the unannotated Plain has a main)"
    sm_expect "the loop exited" sm_alive "$SM_LOOP_PID"
    sm_expect "no launch-refused marker" sm_ev_ge launch-refused 1
    sm_write_src App
    sm_wait 15 sm_java_ge START 1 || sm_fail "no START within 15s of adding App.java"
    sm_quiet 3 12 || :
    sm_expect_eq "START lines" 1 "$(sm_java_n START)"
    [ "$(sm_java_n START)" = 0 ] || sm_check_launch 1 "$SM_DEPS"
}

case_save_during_boot() {
    SM_WHAT="a save while the application is starting: reload-deferred, no trigger; once it answers: app-ready, then exactly one trigger-touched"
    # The case controls when the application "answers", so a boot timeout
    # would only be noise here; boot-timeout has a case of its own.
    SM_ENV="DEV_BOOT_TIMEOUT=30"
    sm_ctl http 000
    sm_start
    sm_wait 20 sm_ev_ge app-started 1 || { sm_fail "no app-started within 20s"; return; }
    _t0=$(sm_trigger); _n=$(sm_mvn_n compile)
    sm_append src/main/java/demo/App.java "// saved while the application starts"
    sm_wait 10 sm_ev_ge reload-deferred 1 || sm_fail "no reload-deferred within 10s of the save"
    sm_expect_eq "trigger-touched markers while starting" 0 "$(sm_ev_n trigger-touched)"
    [ "$(sm_trigger)" = "$_t0" ] || sm_fail "the trigger was touched while the application was starting"
    sm_expect_eq "builds while starting" "$_n" "$(sm_mvn_n compile)"
    sm_ctl http 200
    sm_wait 8 sm_ev_ge app-ready 1 || sm_fail "no app-ready within 8s of the probe answering"
    sm_wait 10 sm_ev_ge trigger-touched 1 || sm_fail "no trigger-touched after app-ready: the save was lost"
    sm_quiet 5 15 || :
    sm_expect_eq "trigger-touched markers" 1 "$(sm_ev_n trigger-touched)"
    sm_expect_eq "reload-deferred markers (logged once)" 1 "$(sm_ev_n reload-deferred)"
    sm_expect_eq "builds" "$((_n + 1))" "$(sm_mvn_n compile)"
    _lr=$(sm_ev_line app-ready 1); _lt=$(sm_ev_line trigger-touched 1)
    [ -z "$_lr" ] || [ -z "$_lt" ] || [ "$_lr" -lt "$_lt" ] || sm_fail "trigger-touched came before app-ready"
    sm_expect_eq "STOP lines" 0 "$(sm_java_n STOP)"
    sm_expect_eq "START lines" 1 "$(sm_java_n START)"
}

case_boot_timeout() {
    SM_WHAT="an application that never answers: boot-timeout after DEV_BOOT_TIMEOUT (${SM_BOOT_TIMEOUT}s), then STOP and a new START"
    sm_ctl http 000
    sm_start
    sm_wait 20 sm_java_ge START 1 || { sm_fail "no START within 20s"; return; }
    _ts=$(awk '$2 == "START" { print $1; exit }' "$SM_JTIMES")
    if sm_wait $((SM_BOOT_TIMEOUT + 7)) sm_ev_ge boot-timeout 1; then
        _dt=$(( $(sm_cs) - ${_ts:-0} ))
        [ "$_dt" -ge $(( (SM_BOOT_TIMEOUT - 1) * 100 )) ] ||
            sm_fail "boot-timeout came $((_dt / 100))s after the START, before DEV_BOOT_TIMEOUT=${SM_BOOT_TIMEOUT}s"
    else
        sm_fail "no boot-timeout within $((SM_BOOT_TIMEOUT + 7))s of the START"
    fi
    sm_wait 10 sm_java_ge START 2 || sm_fail "no new START after the boot-timeout"
    sm_ctl http 200
    case "$(sm_java_seq) " in
        "START STOP START "*) ;;
        *) sm_fail "JVM events: expected START STOP START first, got $(sm_java_seq)" ;;
    esac
    sm_expect_eq "the pid that was stopped" "$(sm_java_pid START 1)" "$(sm_java_pid STOP 1)"
}

case_retry() {
    SM_WHAT="a first build that fails once: build-retry-scheduled, then build-ok after DEV_BUILD_RETRY_DELAY (${SM_RETRY_DELAY}s) and 1 START"
    sm_ctl_on fail-once
    sm_start
    sm_wait 15 sm_ev_ge build-retry-scheduled 1 || { sm_fail "no build-retry-scheduled within 15s"; return; }
    sm_wait 15 sm_java_ge START 1 || sm_fail "no START within 15s of the retry being scheduled"
    sm_quiet 2 10 || :
    sm_expect_eq "build-failed markers" 1 "$(sm_ev_n build-failed)"
    _ls=$(sm_ev_line build-retry-scheduled 1); _lo=$(sm_ev_line build-ok 1)
    [ -n "$_lo" ] && [ -n "$_ls" ] && [ "$_lo" -gt "$_ls" ] || sm_fail "no build-ok after build-retry-scheduled"
    sm_expect_eq "full builds (failed + retried)" 2 "$(sm_mvn_n full)"
    sm_expect_eq "START lines" 1 "$(sm_java_n START)"
    _gap=$(awk '$1 == "BEGIN" { t[++k] = $4 } END { if (k >= 2) print t[2] - t[1] }' "$SM_MLOG")
    if [ -n "$_gap" ]; then
        [ "$_gap" -ge $(( (SM_RETRY_DELAY - 1) * 100 )) ] ||
            sm_fail "the retry ran $((_gap / 100)).$((_gap % 100 / 10))s after the failure, before its ${SM_RETRY_DELAY}s"
        sm_note "retried after $((_gap / 100)).$((_gap % 100 / 10))s"
    fi
}

# Script-agnostic from here on: builds counted by the fake, files on disk.
case_delete_file() {
    SM_WHAT="deleting a source file: a compile, its class gone from target/classes, trigger touched"
    sm_write_src Extra
    sm_start
    sm_booted || return
    sm_expect "target/classes/demo/Extra.class missing after boot" sm_is_file "$SM_P/target/classes/demo/Extra.class"
    _n=$(sm_mvn_n compile); _t0=$(sm_trigger)
    rm -f "$SM_P/src/main/java/demo/Extra.java"
    if ! sm_wait 15 sm_mvn_ge compile $((_n + 1)); then
        sm_fail "no compile within 15s of deleting src/main/java/demo/Extra.java"
        return
    fi
    sm_wait 10 sm_mvn_idle || :
    sm_wait 5 sm_no_file "$SM_P/target/classes/demo/Extra.class" ||
        sm_fail "Extra.class is still in target/classes after the compile"
    sm_wait 5 sm_trigger_changed "$_t0" || sm_fail "the trigger was not touched after the compile"
}

case_backdated_edit() {
    SM_WHAT="an edit whose mtime is an hour in the past (WSL2 clock skew): a compile that really recompiles, trigger touched"
    sm_start
    sm_booted || return
    _n=$(sm_mvn_n compile); _t0=$(sm_trigger)
    _c0=$(sm_mtime "$SM_P/target/classes/demo/App.class")
    # Edited and backdated outside src/main, then renamed into place: the
    # watcher must never see the edit with a current mtime, even for an
    # instant, or a find -newer watcher would pass by luck.
    cp "$SM_P/src/main/java/demo/App.java" "$SM_H/tmp/App.java"
    printf '%s\n' "// edited, with an mtime an hour in the past" >>"$SM_H/tmp/App.java"
    sm_backdate 1 "$SM_H/tmp/App.java"
    mv -f "$SM_H/tmp/App.java" "$SM_P/src/main/java/demo/App.java"
    if ! sm_wait 15 sm_mvn_ge compile $((_n + 1)); then
        sm_fail "no compile within 15s of a backdated edit of src/main/java/demo/App.java"
        return
    fi
    sm_wait 10 sm_mvn_idle || :
    sm_wait 5 sm_mtime_changed "$SM_P/target/classes/demo/App.class" "$_c0" ||
        sm_fail "App.class was not rewritten: the compile found nothing stale (is -DlastModGranularityMs=-86400000 passed?)"
    sm_wait 5 sm_trigger_changed "$_t0" || sm_fail "the trigger was not touched after the compile"
}

case_burst() {
    SM_WHAT="5 edits 0.3s apart, a save-all or a checkout: exactly one compile and one trigger-touched"
    sm_start
    sm_booted || return
    _n=$(sm_mvn_n compile)
    # Longer than one poll, so that some poll is bound to land inside the
    # burst - a loop without the settle then compiles half of it and comes
    # back for the rest - while every gap stays far under the settle's second.
    _b0=$(sm_cs) _bp=$_b0 _bmax=0
    for _i in 1 2 3 4 5; do
        sm_append src/main/java/demo/App.java "// burst edit $_i"
        _bn=$(sm_cs)
        [ $((_bn - _bp)) -le "$_bmax" ] || _bmax=$((_bn - _bp))
        _bp=$_bn
        [ "$_i" = 5 ] || sleep 0.3
    done
    sm_note "5 edits over $(( (_bp - _b0) * 10 ))ms, gaps up to $((_bmax * 10))ms"
    [ "$_bmax" -lt 90 ] || sm_note "a gap this long can let a correct settle compile twice"
    sm_wait 15 sm_mvn_ge compile $((_n + 1)) || { sm_fail "no compile within 15s of the edits"; return; }
    sm_wait 10 sm_ev_ge trigger-touched 1 || sm_fail "no trigger-touched after the compile"
    sm_quiet 4 15 || :
    sm_expect_eq "compiles for the burst" "$((_n + 1))" "$(sm_mvn_n compile)"
    sm_expect_eq "trigger-touched markers" 1 "$(sm_ev_n trigger-touched)"
}

# The fake java has no thread named restartedMain, so to check_ready it is a
# JVM whose DevTools restart has FAILED once it stops answering. That must not
# leave saves deferred forever: DevTools is waiting for exactly that save.
case_reload_failed() {
    SM_WHAT="a DevTools restart that never answers again: reload-failed after DEV_RELOAD_FAIL_SECS, then the next save is compiled at once (not deferred), same JVM"
    SM_ENV="DEV_RELOAD_FAIL_SECS=3 DEV_BOOT_TIMEOUT=60"
    sm_start
    sm_booted || return
    sm_append src/main/java/demo/App.java "// the save whose restart fails"
    sm_wait 15 sm_ev_ge trigger-touched 1 || { sm_fail "no trigger-touched within 15s of the first save"; return; }
    sm_ctl http 000
    sm_wait 15 sm_ev_ge reload-failed 1 || { sm_fail "no reload-failed within 15s of the application going quiet"; return; }
    _n=$(sm_mvn_n compile)
    sm_append src/main/java/demo/App.java "// the fix"
    sm_wait 10 sm_ev_ge trigger-touched 2 || sm_fail "the save after reload-failed was not compiled and triggered within 10s"
    sm_expect_eq "reload-deferred markers" 0 "$(sm_ev_n reload-deferred)"
    sm_expect_eq "compiles for the fix" "$((_n + 1))" "$(sm_mvn_n compile)"
    sm_expect_eq "STOP lines" 0 "$(sm_java_n STOP)"
    sm_expect_eq "START lines" 1 "$(sm_java_n START)"
}

# ---------------------------------------------------------------------------
# Running
# ---------------------------------------------------------------------------

sm_evidence() {
    printf '\n%s\n' "==== C-SM-$SM_CASE [$SM_COMPILER] evidence - fixture $SM_P, script $SM_SCRIPT ===="
    for _ef in loop.out loop.err java.log mvn.log; do
        printf '%s\n' "---- $_ef ----"
        sed -n '1,400p' "$SM_H/log/$_ef" 2>/dev/null
        _el=$(wc -l <"$SM_H/log/$_ef" 2>/dev/null) || _el=0
        [ "$_el" -le 400 ] || printf '%s\n' "(... $((_el - 400)) more lines)"
    done
}

sm_run_case() {
    SM_CASE=$1
    SM_P=$SM_ROOT/sm-$SM_CASE
    SM_H=$SM_P/.sm
    SM_OUT=$SM_H/log/loop.out SM_ERR=$SM_H/log/loop.err SM_JLOG=$SM_H/log/java.log
    SM_MLOG=$SM_H/log/mvn.log SM_JTIMES=$SM_H/log/java-times.log
    SM_DEPS=$SM_H/deps/dep-a.jar:$SM_H/deps/dep-b.jar
    SM_FAILS="" SM_NOTES="" SM_WHAT="" SM_ENV=""
    SM_LOOP_PID="" SM_PGID="" SM_LOOP_DONE=0
    SM_DEADLINE=$(( $(sm_cs) + SM_CASE_LIMIT * 100 ))
    printf '\n%s\n' "== C-SM-$SM_CASE [$SM_COMPILER]"
    sm_fixture
    "case_$(printf '%s' "$SM_CASE" | tr - _)"
    [ "$(sm_cs)" -lt "$SM_DEADLINE" ] || sm_fail "the case ran into its ${SM_CASE_LIMIT}s limit"
    sm_stop_loop
    [ "$SM_LEGACY" = 0 ] || sm_note "pre-rewrite script: it logs no markers"
    sm_evidence
    if [ -z "$SM_FAILS" ]; then
        hc_pass "C-SM-$SM_CASE" "[$SM_COMPILER] $SM_WHAT${SM_NOTES:+ ($SM_NOTES)}"
    else
        hc_fail "C-SM-$SM_CASE" "[$SM_COMPILER] $SM_FAILS${SM_NOTES:+ ($SM_NOTES)} - checked: $SM_WHAT"
    fi
}

sm_cleanup() {
    if [ -n "$SM_LOOP_PID" ]; then
        [ -z "$SM_PGID" ] || kill -KILL "-$SM_PGID" 2>/dev/null
        [ "$SM_LOOP_DONE" = 1 ] || kill -KILL "$SM_LOOP_PID" 2>/dev/null
    fi
    sm_find_procs "$SM_ROOT/sm-"
    [ -z "$SM_MATCH" ] || kill -KILL $SM_MATCH 2>/dev/null
    for _cu_d in "$SM_ROOT"/sm-*/.sm/ctl; do
        [ -d "$_cu_d" ] && : >"$_cu_d/java-exit"
    done
}
trap 'sm_cleanup' EXIT
trap 'sm_cleanup; trap - EXIT; exit 130' INT
trap 'sm_cleanup; trap - EXIT; exit 143' TERM

# --- the script under test ----------------------------------------------------

if [ ! -r "$SM_SCRIPT" ]; then
    hc_fail C-SM-setup "the script under test, $SM_SCRIPT, is not readable"
    hc_exit
fi
SM_RUN_SCRIPT=$SM_SCRIPT
SM_LEGACY=0
grep -q DEV_RELOAD_LIB_ONLY "$SM_SCRIPT" || SM_LEGACY=1
# The pre-rewrite script hard-codes APP=/app. A copy with that one line
# changed runs against the fixture; nothing else about it is touched.
if ! grep -q DEV_APP_DIR "$SM_SCRIPT"; then
    mkdir -p "$SM_ROOT/sm-script"
    sed 's|^APP=/app$|APP=${DEV_APP_DIR:-/app}|' "$SM_SCRIPT" >"$SM_ROOT/sm-script/dev-reload.sh"
    if grep -q DEV_APP_DIR "$SM_ROOT/sm-script/dev-reload.sh"; then
        SM_RUN_SCRIPT=$SM_ROOT/sm-script/dev-reload.sh
        hc_info C-SM-script "$SM_SCRIPT does not honour DEV_APP_DIR (a pre-rewrite dev-reload.sh): running a copy with APP=\${DEV_APP_DIR} and nothing else changed"
    else
        hc_info C-SM-script "$SM_SCRIPT honours no DEV_APP_DIR and has no APP=/app line to adapt: it will not see the fixtures, and its cases will fail"
    fi
fi

# --- prerequisites and the precompiled classes ---------------------------------

_miss=""
for _t in javac javap; do command -v "$_t" >/dev/null 2>&1 || _miss="$_miss $_t"; done
find /dev/null -prune -printf '' >/dev/null 2>&1 || _miss="$_miss find-printf(GNU find)"
if [ -n "$_miss" ]; then
    hc_fail C-SM-setup "missing here:$_miss - this runs inside homecrew-dev-runtime:jdk25"
    hc_exit
fi
SM_SETSID=""
command -v setsid >/dev/null 2>&1 && SM_SETSID=setsid

rm -rf "$SM_PRE"
sm_write_pre_sources
if ! javac -d "$SM_PRE/classes" "$SM_PRE/src/org/springframework/boot/autoconfigure/SpringBootApplication.java" \
        "$SM_PRE"/src/demo/*.java >"$SM_PRE/javac.log" 2>&1; then
    hc_fail C-SM-setup "javac could not compile the fixture classes: $(head -c 600 "$SM_PRE/javac.log")"
    hc_exit
fi
# If the script's own main-class check rejected the stub, every case would
# fail on main-class-error, and say nothing about the state machine.
_self="not checked (a pre-rewrite script has no DEV_RELOAD_LIB_ONLY)"
if [ "$SM_LEGACY" = 0 ]; then
    if ( DEV_RELOAD_LIB_ONLY=1; export DEV_RELOAD_LIB_ONLY
         . "$SM_RUN_SCRIPT" >/dev/null 2>&1
         is_boot_main "$SM_PRE/classes/demo/App.class" ); then
        _self="accepted by the script's is_boot_main"
    else
        hc_fail C-SM-setup "the script's own is_boot_main rejects the fixture's @SpringBootApplication class $SM_PRE/classes/demo/App.class: every launch below will be refused"
        _self="REJECTED by the script's is_boot_main"
    fi
fi
hc_info C-SM-setup "script $SM_SCRIPT; compilers: $SM_COMPILERS; $(javac -version 2>&1 | head -n 1); fixture main class demo.App $_self; process groups: ${SM_SETSID:-none (no setsid)}; /proc: $([ "$SM_CANLIST" = 1 ] && echo yes || echo no)"

for SM_COMPILER in $SM_COMPILERS; do
    for _case in $SM_CASES; do
        sm_run_case "$_case"
    done
done

sm_cleanup
trap - EXIT
hc_done unit-state-machine.sh
hc_exit
