#!/bin/sh
# Suite C, part 1: unit tests of dev-reload.sh's functions, one at a time.
#
# Runs INSIDE homecrew-dev-runtime:jdk25, started by test/lib/SuiteUnit.ps1:
#
#     docker run --rm --network none -v <infra>:/src:ro \
#         --entrypoint sh homecrew-dev-runtime:jdk25 -c 'sh /src/test/container/unit-dev-reload.sh'
#
# The same dash, GNU find, GNU cp, util-linux flock and javap that dev-reload.sh
# uses in the real containers - which is the point: half of what can go wrong
# with it is a tool behaving differently from the one it was written against.
# Nothing here touches /src (it is read-only) or the network; every fixture is
# generated under /tmp and thrown away with the container.
#
# The functions are loaded the way the script offers for exactly this:
#
#     DEV_RELOAD_LIB_ONLY=1 DEV_APP_DIR=<fixture> . /src/dev-reload.sh
#
# once per case, in a subshell of its own. Its globals (APP, CLASSES, CP_FILE,
# STATE, GOOD, TRIGGER, WRAPPER_DIR, JAVA_CMD, ...) are computed at source time
# from the environment, so a case sets its environment FIRST and sources
# second, and one case can never see another's state. Sourcing also turns on
# the script's own `set -eu` - deliberately left on: a case runs under the same
# rules as main's loop, and a function that aborts under them is reported as
# <id>-ABORTED rather than passing by accident.
#
# Results are HCRESULT lines (test/container/lib.sh). Groups of cases (fp, mc,
# lc, good, res, val, wrap, mvn) each run as a separate process under a
# timeout, so one that hangs - a flock that is never released - costs that
# group, not the rest. The exit status is 1 if anything FAILed, else 0.
#
#     sh unit-dev-reload.sh              every group
#     sh unit-dev-reload.sh fp mc        only these groups
#
# Knobs, for working on this file outside the image only: HC_SRC (the infra
# checkout, default /src), HC_JAVA_RELEASE (default 25; javac --release),
# HC_SH (the shell for group processes, default sh), HC_GROUP_TIMEOUT
# (seconds, default 600), HC_KEEP=1 (keep the /tmp work directory).

set -u

HC_SRC=${HC_SRC:-/src}
DR=$HC_SRC/dev-reload.sh
REL=${HC_JAVA_RELEASE:-25}
HC_SH=${HC_SH:-sh}
case $0 in /*) SELF=$0 ;; *) SELF=$(pwd)/$0 ;; esac

# Written by hand: without lib.sh there is no hc_fail, and a dot of a missing
# file would end the shell with no result line at all.
if [ ! -r "$HC_SRC/test/container/lib.sh" ] || [ ! -r "$DR" ]; then
    printf 'HCRESULT\tC-UNIT-SRC\tFAIL\t%s\n' "$DR or $HC_SRC/test/container/lib.sh is not readable - is the infra checkout mounted at $HC_SRC?"
    exit 1
fi
. "$HC_SRC/test/container/lib.sh"

ALL_GROUPS="fp mc lc good res val wrap mvn"
TAB=$(printf '\t')

# Fixed timestamps, set with touch -t so that "one second later" and "an hour
# earlier" need no date arithmetic. T0M1H is the WSL2 case: a Docker VM whose
# clock ran ahead of the host sees a fresh save as an hour OLD.
T0=202601011200.00
T0P1=202601011200.01
T0M1H=202601011100.00
TOLD=202001010000.00

# The knobs dev-reload.sh reads. Cleared once here, so that every case starts
# from the defaults and sets only what it is about - an image or a shell that
# happens to export one of these must not change what a test means.
unset DEV_APP_DIR DEV_JAVA DEV_COMPILER DEV_MAVEN_EXTRA_ARGS DEV_MAVEN_QUIET \
      DEV_RELOAD_INTERVAL DEV_STOP_TIMEOUT DEV_BOOT_TIMEOUT DEV_READY_APPEAR \
      DEV_RESTART_DELAY DEV_BUILD_RETRY_DELAY DEV_RELOAD_FAIL_SECS DEV_APP_PORT \
      DEV_MAIN_CLASS DEV_OPTIMIZED_LAUNCH DEV_JVM_ARGS DEV_RELOAD_LIB_ONLY MAVEN_USER_HOME \
      SPRING_DEVTOOLS_RESTART_TRIGGER_FILE MAVEN_OPTS MAVEN_ARGS 2>/dev/null || :

# ---------------------------------------------------------------------------
# Helpers shared by every case
# ---------------------------------------------------------------------------
#
# Variables are prefixed u_ (cases) and uh_ (helpers): dev-reload.sh's own
# functions use _-prefixed globals (_f, _rc, _n, ...), and a case calling one
# of them must not have its own state overwritten in between.

# Loads the functions. The environment a case exported before this call is
# what the globals are computed from.
load_dr() {
    DEV_RELOAD_LIB_ONLY=1
    export DEV_RELOAD_LIB_ONLY
    . "$DR"
}
load_dr_at() {
    DEV_APP_DIR=$1
    export DEV_APP_DIR
    load_dr
}

# Evidence: a captured log, indented so it cannot be mistaken for a result.
show() {
    if [ -s "$1" ]; then sed 's/^/    | /' "$1"; fi
}
# One line, for messages: newline-separated text joined with " | ".
joined() {
    awk 'NR > 1 { printf " | " } { printf "%s", $0 } END { printf "\n" }' "$1"
}
# The first error line of a dev-reload.sh log with the given event, for a
# message (trimmed: messages are one table cell).
event_text() {
    sed -n "s/^\\[dev-reload\\] $2: //p" "$1" | head -n 1 | cut -c1-260
}
count_lines() {
    if [ -f "$1" ]; then wc -l <"$1" | tr -d ' '; else echo 0; fi
}

# GNU find, like dev-reload.sh: %T@ has nanoseconds, so "unchanged" means
# unchanged, not merely the same second.
mtime_of() { find "$1" -maxdepth 0 -printf '%T@\n'; }

# Name, size, mtime and content of every file under $1 except the one named
# $2 (relative to $1): "exactly as snapshotted" in one comparable string.
tree_state() {
    if [ -d "$1" ]; then
        ( cd "$1" && find . -type f ! -path "./$2" -printf '%p %s %T@\n' | LC_ALL=C sort &&
          find . -type f ! -path "./$2" -exec cksum {} + | LC_ALL=C sort )
    fi
}

# sub <id> <function> [args...]: one case, in a subshell of its own. U_ID is
# the case's id, for the function to report under. A non-zero exit means the
# case never reached its verdict - usually a command failing under the set -eu
# that sourcing turned on - and that is a FAIL, not a silent gap in the report.
sub() {
    U_ID=$1
    shift
    ( "$@" )
    uh_rc=$?
    if [ "$uh_rc" -ne 0 ]; then
        hc_fail "$U_ID-ABORTED" "the case stopped with status $uh_rc before reaching a verdict (a command failed under dev-reload.sh's set -eu - see the output above)"
    fi
}

# ---------------------------------------------------------------------------
# C-FP: change detection. fingerprint(), src_fingerprint(), build_fingerprint()
# ---------------------------------------------------------------------------

# A small service checkout, every file stamped T0.
fp_tree() {
    mkdir -p "$1/src/main/java/com/x/sub" "$1/src/main/resources" "$1/src/test/java/com/x" "$1/.mvn/wrapper"
    printf 'package com.x;\nclass App {}\n' >"$1/src/main/java/com/x/App.java"
    printf 'package com.x.sub;\nclass Util {}\n' >"$1/src/main/java/com/x/sub/Util.java"
    printf 'server.port=8081\n' >"$1/src/main/resources/application.properties"
    printf 'package com.x;\nclass AppTest {}\n' >"$1/src/test/java/com/x/AppTest.java"
    printf '<project/>\n' >"$1/pom.xml"
    printf '%s\n' '-Xmx1g' >"$1/.mvn/jvm.config"
    printf 'distributionUrl=https://example.invalid/apache-maven-3.9.16-bin.zip\n' >"$1/.mvn/wrapper/maven-wrapper.properties"
    find "$1" -type f -exec touch -t "$T0" {} +
}

# fp_run <src|build> <differ|same> <what> <mutate> [<prepare>]
# Fingerprint, mutate, fingerprint again. <prepare> shapes the tree before the
# first look (not counted as the change).
fp_run() {
    u_kind=$1 u_want=$2 u_what=$3 u_mut=$4 u_prep=${5:-}
    u_dir=$HC_W/$U_ID
    fp_tree "$u_dir"
    cd "$u_dir" || exit 1
    if [ -n "$u_prep" ]; then "$u_prep"; fi
    load_dr
    u_a=$("${u_kind}_fingerprint")
    "$u_mut"
    u_b=$("${u_kind}_fingerprint")
    if [ "$u_want" = differ ]; then
        if [ "$u_a" != "$u_b" ]; then hc_pass "$U_ID" "$u_what changes ${u_kind}_fingerprint ($u_a -> $u_b)"
        else hc_fail "$U_ID" "$u_what does NOT change ${u_kind}_fingerprint (still $u_a): the change would never be compiled"; fi
    else
        if [ "$u_a" = "$u_b" ]; then hc_pass "$U_ID" "$u_what leaves ${u_kind}_fingerprint unchanged ($u_a)"
        else hc_fail "$U_ID" "$u_what changes ${u_kind}_fingerprint ($u_a -> $u_b): it would cost a compile or restart for nothing"; fi
    fi
    return 0
}

fpm_none()       { :; }
fpm_create()     { printf 'package com.x;\nclass New {}\n' >src/main/java/com/x/New.java; touch -t "$T0" src/main/java/com/x/New.java; }
# Same size, one second later: only the mtime tells it apart.
fpm_modify()     { printf 'package com.x;\nclass Apq {}\n' >src/main/java/com/x/App.java; touch -t "$T0P1" src/main/java/com/x/App.java; }
fpm_mtime()      { touch -t "$T0P1" src/main/java/com/x/App.java; }
fpm_backdate()   { touch -t "$T0M1H" src/main/java/com/x/App.java; }
fpm_delete()     { rm src/main/java/com/x/sub/Util.java; }
fpm_renfile()    { mv src/main/java/com/x/App.java src/main/java/com/x/Main.java; }
fpm_rendir()     { mv src/main/java/com/x/sub src/main/java/com/x/util; }
fpm_space_new()  { printf 'a=1\n' >'src/main/resources/my file.properties'; touch -t "$T0" 'src/main/resources/my file.properties'; }
fpm_space_mod()  { touch -t "$T0P1" 'src/main/resources/my file.properties'; }
fpm_srctest()    {
    printf 'package com.x;\nclass AppTezt {}\n' >src/test/java/com/x/AppTest.java
    printf 'package com.x;\nclass NewTest {}\n' >src/test/java/com/x/NewTest.java
    mkdir -p src/test/resources
    printf 'k=v\n' >src/test/resources/test.properties
}
fpm_pom()        { printf '<!-- a dependency added -->\n' >>pom.xml; }
fpm_jvmconfig()  { printf '%s\n' '-Xmx2g' >.mvn/jvm.config; touch -t "$T0P1" .mvn/jvm.config; }
fpm_newmvn()     { printf '%s\n' '-T1C' >.mvn/maven.config; }
fpm_lombok_new() { printf 'lombok.addLombokGeneratedAnnotation = true\n' >lombok.config; }
fpp_lombok()     { fpm_lombok_new; touch -t "$T0" lombok.config; }
fpm_lombok_mod() { printf 'lombok.accessors.chain = true\n' >>lombok.config; }
fpp_nosrc()      { rm -rf src/main; }
fpm_first_src()  { mkdir -p src/main/java; printf 'class A {}\n' >src/main/java/A.java; }
# Order of creation must not matter: find's order is the directory's.
fpm_editor()     { : >"src/main/java/com/x/$U_EDITOR"; }
fpm_editor_mvn() { : >.mvn/jvm.config~; : >.mvn/.jvm.config.swp; : >.mvn/wrapper/.#maven-wrapper.properties; }

fp_sane() {
    u_dir=$HC_W/$U_ID
    fp_tree "$u_dir"
    cd "$u_dir" || exit 1
    load_dr
    u_a=$(src_fingerprint)
    u_empty=$(printf '' | cksum)
    case $u_a in
      *[!0-9\ ]* | '' | ' '* | *' ') hc_fail "$U_ID" "src_fingerprint printed '$u_a', not a cksum line" ;;
      "$u_empty") hc_fail "$U_ID" "src_fingerprint of a tree with files equals the empty-input cksum ($u_a): it sees no files" ;;
      *) hc_pass "$U_ID" "src_fingerprint is a cksum line over real input ($u_a)" ;;
    esac
    return 0
}

# Two trees with the same paths, sizes and mtimes, built in opposite orders.
# That alone proves little where this runs: ext4 lists even a one-block
# directory in name-hash order, whatever order the files were created in, so
# both trees list alike with or without the sort. The control is find's own
# listing: when it is NOT already sorted, the fingerprint must equal the cksum
# of that listing sorted by hand.
fp_stable() {
    u_one=$HC_W/$U_ID/one u_two=$HC_W/$U_ID/two
    mkdir -p "$u_one/src/main/java" "$u_two/src/main/java"
    for u_f in A B C D E F G H; do printf 'class %s {}\n' "$u_f" >"$u_one/src/main/java/$u_f.java"; done
    for u_f in H G F E D C B A; do printf 'class %s {}\n' "$u_f" >"$u_two/src/main/java/$u_f.java"; done
    find "$u_one" "$u_two" -type f -exec touch -t "$T0" {} +
    load_dr
    u_a=$(cd "$u_one" && src_fingerprint)
    u_b=$(cd "$u_two" && src_fingerprint)
    u_raw=$(cd "$u_one" && find src/main -type f -printf '%p %s %T@\n')
    u_sorted=$(printf '%s\n' "$u_raw" | LC_ALL=C sort)
    u_want=$(printf '%s\n' "$u_sorted" | cksum)
    if [ "$u_a" != "$u_b" ]; then
        hc_fail "$U_ID" "the same tree written in two orders gives $u_a and $u_b: the sort is not doing its job, and a checkout would look changed after every poll"
    elif [ "$u_raw" = "$u_sorted" ]; then
        hc_info "$U_ID" "find already lists this directory in sorted order here, so this case cannot tell a sorted fingerprint from an unsorted one ($u_a)"
    elif [ "$u_a" = "$u_want" ]; then
        hc_pass "$U_ID" "the fingerprint is the cksum of the SORTED listing (find lists this directory in another order), and the tree written in two orders gives the same value ($u_a)"
    else
        hc_fail "$U_ID" "the fingerprint ($u_a) is not the cksum of the sorted listing ($u_want): it depends on the order the directory lists in"
    fi
    return 0
}

# A service with no src/main at all, under set -e exactly as main's loop has
# it: a FRESH shell, because a subshell of a tested context (like this one's
# caller) would have -e silently switched off and prove nothing.
fp_nosrc() {
    u_dir=$HC_W/$U_ID
    mkdir -p "$u_dir"
    u_out=$(DEV_RELOAD_LIB_ONLY=1 "$HC_SH" -c '
        cd "$1" || exit 9
        . "$2"
        a=$(src_fingerprint); b=$(src_fingerprint); c=$(build_fingerprint)
        printf "%s|%s|%s|reached\n" "$a" "$b" "$c"' sh "$u_dir" "$DR" 2>&1)
    u_rc=$?
    case $u_out in
      *'|reached')
        u_a=${u_out%%|*}
        u_rest=${u_out#*|}
        u_b=${u_rest%%|*}
        if [ "$u_rc" -eq 0 ] && [ "$u_a" = "$u_b" ]; then
            hc_pass "$U_ID" "no src/main (and no pom.xml, .mvn or lombok.config): the fingerprints are stable ($u_a) and set -e does not abort"
        else
            hc_fail "$U_ID" "no src/main: status $u_rc, two fingerprints '$u_a' and '$u_b' - not stable"
        fi ;;
      *) hc_fail "$U_ID" "no src/main: the fingerprint aborted the shell under set -e (status $u_rc, output: $(printf '%s' "$u_out" | tr '\n' ' ' | cut -c1-200))" ;;
    esac
    return 0
}

fp_limit() {
    u_dir=$HC_W/$U_ID
    fp_tree "$u_dir"
    cd "$u_dir" || exit 1
    load_dr
    u_a=$(src_fingerprint)
    touch -r src/main/java/com/x/App.java "$HC_W/limit.ref"
    printf 'package com.x;\nclass Apq {}\n' >src/main/java/com/x/App.java
    touch -r "$HC_W/limit.ref" src/main/java/com/x/App.java
    u_b=$(src_fingerprint)
    if [ "$u_a" = "$u_b" ]; then
        hc_info "$U_ID" "documented limit, as expected: a same-size edit with its mtime put back is NOT detected - the fingerprint is path, size and mtime, never content"
    else
        hc_info "$U_ID" "a same-size edit with its mtime put back WAS detected here ($u_a -> $u_b); the documented limit did not show on this filesystem"
    fi
    return 0
}

group_fp() {
    sub C-FP-SANE      fp_sane
    sub C-FP-NOCHANGE  fp_run src   same   'nothing at all'                              fpm_none
    sub C-FP-NOCHANGE-BUILD fp_run build same 'nothing at all'                           fpm_none
    sub C-FP-STABLE    fp_stable
    sub C-FP-CREATE    fp_run src   differ 'a new file under src/main'                   fpm_create
    sub C-FP-MODIFY    fp_run src   differ 'a same-size edit one second later'           fpm_modify
    sub C-FP-MTIME     fp_run src   differ 'an mtime-only change (touch)'                fpm_mtime
    sub C-FP-BACKDATE  fp_run src   differ 'an mtime set one hour BACK (VM clock ahead of the host)' fpm_backdate
    sub C-FP-DELETE    fp_run src   differ 'deleting a file'                             fpm_delete
    sub C-FP-RENAME-FILE fp_run src differ 'renaming a file'                             fpm_renfile
    sub C-FP-RENAME-DIR  fp_run src differ 'renaming a directory'                        fpm_rendir
    sub C-FP-SPACE-NEW fp_run src   differ 'a new file with a space in its name'         fpm_space_new
    sub C-FP-SPACE-MOD fp_run src   differ 'touching a file with a space in its name'    fpm_space_mod fpm_space_new
    sub C-FP-SRCTEST   fp_run src   same   'editing and adding files under src/test'     fpm_srctest
    sub C-FP-SRCTEST-BUILD fp_run build same 'editing and adding files under src/test'  fpm_srctest
    sub C-FP-POM       fp_run build differ 'a pom.xml edit'                              fpm_pom
    sub C-FP-POM-SRC   fp_run src   same   'a pom.xml edit'                              fpm_pom
    sub C-FP-JVMCONFIG fp_run build differ 'a same-size .mvn/jvm.config edit'            fpm_jvmconfig
    sub C-FP-NEWMVN    fp_run build differ 'a new file under .mvn (maven.config)'        fpm_newmvn
    sub C-FP-LOMBOK-NEW fp_run build differ 'creating lombok.config'                     fpm_lombok_new
    sub C-FP-LOMBOK-MOD fp_run build differ 'editing lombok.config'                      fpm_lombok_mod fpp_lombok
    sub C-FP-NOSRC     fp_nosrc
    sub C-FP-NOSRC-CREATE fp_run src differ 'the first file of a missing src/main'       fpm_first_src fpp_nosrc
    for u_e in '.App.java.swp:SWP' '.App.java.swx:SWX' 'App.java~:TILDE' '.#App.java:EMACS' \
               'App.java___jb_tmp___:JBTMP' 'App.java___jb_old___:JBOLD' '4913:VIM4913' \
               '.DS_Store:DSSTORE' 'Thumbs.db:THUMBS' 'desktop.ini:DESKTOPINI'; do
        U_EDITOR=${u_e%:*}
        sub "C-FP-EDITOR-${u_e##*:}" fp_run src same "the editor/OS file '${u_e%:*}' appearing in src/main" fpm_editor
    done
    sub C-FP-EDITOR-MVN fp_run build same 'editor files appearing under .mvn' fpm_editor_mvn
    sub C-FP-LIMIT     fp_limit
}

# ---------------------------------------------------------------------------
# C-MC: the main class, from compiled classes. resolve_main, main_still_valid
# ---------------------------------------------------------------------------

SBA_FQCN=org.springframework.boot.autoconfigure.SpringBootApplication
SBA_STRING='Lorg/springframework/boot/autoconfigure/SpringBootApplication;'

# The annotation as Boot declares it - RUNTIME retention, TYPE target, and an
# element, so that javap's "SpringBootApplication(" form is exercised too. It
# is compiled to its own directory and put on javac's classpath only: in a
# real service it arrives in a jar, never in target/classes.
mc_stub() {
    uh_s=$HC_W/stub-src/org/springframework/boot/autoconfigure
    mkdir -p "$uh_s" "$HC_W/stub"
    cat >"$uh_s/SpringBootApplication.java" <<'EOF'
package org.springframework.boot.autoconfigure;

import java.lang.annotation.Documented;
import java.lang.annotation.ElementType;
import java.lang.annotation.Inherited;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;

@Target(ElementType.TYPE)
@Retention(RetentionPolicy.RUNTIME)
@Documented
@Inherited
public @interface SpringBootApplication {
    String[] scanBasePackages() default {};
}
EOF
    javac --release "$REL" -d "$HC_W/stub" "$uh_s/SpringBootApplication.java"
}

# jfile <app-dir> <path under src/main/java>: the Java source on stdin.
jfile() {
    mkdir -p "$(dirname "$1/src/main/java/$2")"
    cat >"$1/src/main/java/$2"
}
pkgdir() { printf '%s' "$1" | tr . /; }
# An annotated class with public static void main(String[]) - a real service.
japp() {
    jfile "$1" "$(pkgdir "$2")/$3.java" <<EOF
package $2;

import org.springframework.boot.autoconfigure.SpringBootApplication;

@SpringBootApplication
public class $3 {
    public static void main(String[] args) {
        System.out.println("$3");
    }
}
EOF
}
# Neither annotated nor with a main: a service class.
jplain() {
    jfile "$1" "$(pkgdir "$2")/$3.java" <<EOF
package $2;

public class $3 {
    public String name() { return "$3"; }
}
EOF
}
# A main, and no annotation: a CLI tool or a test helper in src/main.
jmainonly() {
    jfile "$1" "$(pkgdir "$2")/$3.java" <<EOF
package $2;

public class $3 {
    public static void main(String[] args) {
        System.out.println("$3");
    }
}
EOF
}
# Compiles everything under src/main/java into target/classes, as Maven does.
jcompile() {
    mkdir -p "$1/target/classes"
    find "$1/src/main/java" -name '*.java' >"$1/sources.lst"
    javac --release "$REL" -proc:none -cp "$HC_W/stub" -d "$1/target/classes" @"$1/sources.lst"
}

# expect_main <what> <fqcn>: resolve_main must pick exactly this class.
expect_main() {
    u_log=$HC_W/$U_ID.log
    u_rc=0
    resolve_main >"$u_log" 2>&1 || u_rc=$?
    show "$u_log"
    if [ "$u_rc" -eq 0 ] && [ "$MAIN_CLASS" = "$2" ] && [ "$MAIN_OK" = 1 ] &&
       grep -qxF "[dev-reload] main-class: $2" "$u_log"; then
        hc_pass "$U_ID" "$1: resolve_main chose $2"
    else
        hc_fail "$U_ID" "$1: expected $2, got status $u_rc, MAIN_CLASS='$MAIN_CLASS', MAIN_OK=$MAIN_OK ($(event_text "$u_log" main-class-error))"
    fi
    return 0
}
# expect_refusal <what> <text>...: resolve_main must fail, leave no main class
# behind (no fallback), and say each <text> in its main-class-error.
expect_refusal() {
    u_what=$1
    shift
    u_log=$HC_W/$U_ID.log
    u_rc=0
    resolve_main >"$u_log" 2>&1 || u_rc=$?
    show "$u_log"
    u_missing=""
    for u_t in "$@"; do
        grep -F -- "$u_t" "$u_log" >/dev/null 2>&1 || u_missing="$u_missing [$u_t]"
    done
    u_err=$(event_text "$u_log" main-class-error)
    if [ "$u_rc" -ne 0 ] && [ "$MAIN_OK" = 0 ] && [ -z "$MAIN_CLASS" ] && [ -n "$u_err" ] && [ -z "$u_missing" ]; then
        hc_pass "$U_ID" "$u_what: refused - $u_err"
    else
        hc_fail "$U_ID" "$u_what: expected a refusal; got status $u_rc, MAIN_CLASS='$MAIN_CLASS', MAIN_OK=$MAIN_OK, error '$u_err', missing from it:${u_missing:- nothing}"
    fi
    return 0
}
# mc_build: compile $u_d or report and stop the case.
mc_build() {
    if ! jcompile "$u_d"; then
        hc_fail "$U_ID" "the fixture did not compile (javac output above)"
        exit 0
    fi
}

mc_one() {
    u_d=$HC_W/$U_ID
    japp "$u_d" com.x App
    jplain "$u_d" com.x Service
    jplain "$u_d" com.x.web Controller
    mc_build
    load_dr_at "$u_d"
    expect_main 'one annotated class with main(String[]) among plain ones' com.x.App
}
mc_none() {
    u_d=$HC_W/$U_ID
    jmainonly "$u_d" com.x Tool
    jplain "$u_d" com.x Service
    mc_build
    load_dr_at "$u_d"
    expect_refusal 'no annotated class' 'Unable to find a suitable main class' 'classes mentioning the annotation: none' 'DEV_MAIN_CLASS'
}
mc_two() {
    u_d=$HC_W/$U_ID
    japp "$u_d" com.x A
    japp "$u_d" com.y B
    mc_build
    load_dr_at "$u_d"
    expect_refusal 'two annotated classes with main' 'Unable to find a single main class from the following candidates [com.x.A, com.y.B]'
}
mc_comment() {
    u_d=$HC_W/$U_ID
    japp "$u_d" com.x App
    jfile "$u_d" com/x/Tool.java <<'EOF'
package com.x;

// @SpringBootApplication
/* @org.springframework.boot.autoconfigure.SpringBootApplication */
public class Tool {
    public static void main(String[] args) {
    }
}
EOF
    mc_build
    load_dr_at "$u_d"
    u_c=$(annotated_candidates | tr '\n' ' ')
    case " $u_c " in
      *' com.x.Tool '*) hc_fail "$U_ID" "a class with the annotation only in a comment is a candidate ($u_c)"; return 0 ;;
    esac
    expect_main 'the annotation only in a comment does not make a candidate' com.x.App
}
# The descriptor as a string constant: grep finds it, only javap can tell.
mc_decoy_string() {
    u_d=$HC_W/$U_ID
    jfile "$u_d" com/x/Decoy.java <<'EOF'
package com.x;

public class Decoy {
    public static void main(String[] args) {
        System.out.println("Lorg/springframework/boot/autoconfigure/SpringBootApplication;");
    }
}
EOF
    mc_build
    load_dr_at "$u_d"
    expect_refusal 'an unannotated main whose constant pool holds the descriptor string' \
        'Unable to find a suitable main class' 'classes mentioning the annotation: com.x.Decoy'
}
# The descriptor in a method signature: the other way grep over-matches.
mc_decoy_sig() {
    u_d=$HC_W/$U_ID
    jfile "$u_d" com/x/Sig.java <<'EOF'
package com.x;

import org.springframework.boot.autoconfigure.SpringBootApplication;

public class Sig {
    static String take(SpringBootApplication a) {
        return String.valueOf(a);
    }

    public static void main(String[] args) {
    }
}
EOF
    mc_build
    load_dr_at "$u_d"
    expect_refusal 'an unannotated main that takes the annotation type as a parameter' \
        'Unable to find a suitable main class' 'classes mentioning the annotation: com.x.Sig'
}
mc_pkg_path() {
    u_d=$HC_W/$U_ID
    jfile "$u_d" com/wrong/Place.java <<'EOF'
package com.right;

import org.springframework.boot.autoconfigure.SpringBootApplication;

@SpringBootApplication
public class Place {
    public static void main(String[] args) {
    }
}
EOF
    mc_build
    load_dr_at "$u_d"
    expect_main 'source under com/wrong declaring package com.right: the name comes from the compiled class' com.right.Place
}
mc_noargs() {
    u_d=$HC_W/$U_ID
    jfile "$u_d" com/x/App.java <<'EOF'
package com.x;

import org.springframework.boot.autoconfigure.SpringBootApplication;

@SpringBootApplication
public class App {
    static void main() {
    }
}
EOF
    mc_build
    load_dr_at "$u_d"
    expect_refusal "Java 25's argument-less static main() (DevTools can only restart main(String[]))" \
        'Unable to find a suitable main class' 'main(String[])' 'com.x.App'
}
mc_instance() {
    u_d=$HC_W/$U_ID
    jfile "$u_d" com/x/App.java <<'EOF'
package com.x;

import org.springframework.boot.autoconfigure.SpringBootApplication;

@SpringBootApplication
public class App {
    public void main(String[] args) {
    }
}
EOF
    mc_build
    load_dr_at "$u_d"
    expect_refusal 'an instance main(String[])' 'Unable to find a suitable main class' 'com.x.App'
}
mc_nofallback() {
    u_d=$HC_W/$U_ID
    jfile "$u_d" com/x/Config.java <<'EOF'
package com.x;

import org.springframework.boot.autoconfigure.SpringBootApplication;

@SpringBootApplication
public class Config {
}
EOF
    jmainonly "$u_d" com.x Runner
    mc_build
    load_dr_at "$u_d"
    expect_refusal 'an annotated class without main plus an unannotated main: no fallback to "any main"' \
        'Unable to find a suitable main class' 'classes mentioning the annotation: com.x.Config'
}
mc_override() {
    u_d=$HC_W/$U_ID
    japp "$u_d" com.x A
    japp "$u_d" com.y B
    mc_build
    DEV_MAIN_CLASS=com.y.B
    export DEV_MAIN_CLASS
    load_dr_at "$u_d"
    expect_main 'DEV_MAIN_CLASS picks one of two candidates' com.y.B
}
mc_override_plain() {
    u_d=$HC_W/$U_ID
    japp "$u_d" com.x App
    jmainonly "$u_d" com.x Runner
    mc_build
    DEV_MAIN_CLASS=com.x.Runner
    export DEV_MAIN_CLASS
    load_dr_at "$u_d"
    expect_main 'DEV_MAIN_CLASS is taken as given, annotated or not (like the plugin'"'"'s mainClass)' com.x.Runner
}
mc_override_missing() {
    u_d=$HC_W/$U_ID
    japp "$u_d" com.x App
    mc_build
    DEV_MAIN_CLASS=com.x.Nope
    export DEV_MAIN_CLASS
    load_dr_at "$u_d"
    expect_refusal 'DEV_MAIN_CLASS naming a class that does not exist' 'DEV_MAIN_CLASS=com.x.Nope' 'does not exist'
}
mc_override_nomain() {
    u_d=$HC_W/$U_ID
    japp "$u_d" com.x App
    jplain "$u_d" com.x Service
    mc_build
    DEV_MAIN_CLASS=com.x.Service
    export DEV_MAIN_CLASS
    load_dr_at "$u_d"
    expect_refusal 'DEV_MAIN_CLASS naming a class without main' 'DEV_MAIN_CLASS=com.x.Service' 'declares no public static void main'
}
mc_inner_src() {
    jfile "$1" com/x/Outer.java <<'EOF'
package com.x;

import org.springframework.boot.autoconfigure.SpringBootApplication;

public class Outer {
    @SpringBootApplication
    public static class Inner {
        public static void main(String[] args) {
        }
    }
}
EOF
}
mc_inner_override() {
    u_d=$HC_W/$U_ID
    mc_inner_src "$u_d"
    mc_build
    DEV_MAIN_CLASS='com.x.Outer$Inner'
    export DEV_MAIN_CLASS
    load_dr_at "$u_d"
    expect_main 'DEV_MAIN_CLASS as a binary name (Outer$Inner)' 'com.x.Outer$Inner'
}
mc_inner_auto() {
    u_d=$HC_W/$U_ID
    mc_inner_src "$u_d"
    mc_build
    load_dr_at "$u_d"
    expect_main 'an annotated static nested class is found under its binary name' 'com.x.Outer$Inner'
}
mc_inner_canonical() {
    u_d=$HC_W/$U_ID
    mc_inner_src "$u_d"
    mc_build
    DEV_MAIN_CLASS=com.x.Outer.Inner
    export DEV_MAIN_CLASS
    load_dr_at "$u_d"
    expect_refusal 'DEV_MAIN_CLASS as the canonical name Outer.Inner' 'does not exist' 'binary name'
}
mc_noclasses() {
    u_d=$HC_W/$U_ID
    mkdir -p "$u_d/src/main/java"
    load_dr_at "$u_d"
    expect_refusal 'no target/classes at all' 'Unable to find a suitable main class' 'classes mentioning the annotation: none'
}
mc_hidden() {
    u_d=$HC_W/$U_ID
    japp "$u_d" com.x App
    mc_build
    u_g=$HC_W/$U_ID.ghost
    japp "$u_g" com.z Ghost
    if ! jcompile "$u_g"; then hc_fail "$U_ID" "the .hidden fixture did not compile"; return 0; fi
    mkdir -p "$u_d/target/classes/.hidden/com/z"
    cp "$u_g/target/classes/com/z/Ghost.class" "$u_d/target/classes/.hidden/com/z/Ghost.class"
    load_dr_at "$u_d"
    u_c=$(annotated_candidates | tr '\n' ' ')
    case $u_c in
      *hidden*) hc_fail "$U_ID" "a class under target/classes/.hidden is a candidate ($u_c)"; return 0 ;;
    esac
    expect_main 'an annotated main under a .hidden/ directory is skipped, as MainClassFinder skips it' com.x.App
}
mc_elements() {
    u_d=$HC_W/$U_ID
    jfile "$u_d" com/x/App.java <<'EOF'
package com.x;

import org.springframework.boot.autoconfigure.SpringBootApplication;

@Deprecated
@SpringBootApplication(scanBasePackages = {"com.x", "com.shared"})
public class App {
    public static void main(String[] args) {
    }
}
EOF
    mc_build
    load_dr_at "$u_d"
    expect_main 'the annotation with element values, after another class annotation' com.x.App
}
mc_varargs() {
    u_d=$HC_W/$U_ID
    jfile "$u_d" com/x/App.java <<'EOF'
package com.x;

import org.springframework.boot.autoconfigure.SpringBootApplication;

@SpringBootApplication
public class App {
    public static void main(String... args) throws Exception {
    }
}
EOF
    mc_build
    load_dr_at "$u_d"
    expect_main 'main(String...) throws Exception' com.x.App
}
mc_lookalike() {
    u_d=$HC_W/$U_ID
    jfile "$u_d" com/x/SpringBootApplication.java <<'EOF'
package com.x;

import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;

@Retention(RetentionPolicy.RUNTIME)
public @interface SpringBootApplication {
}
EOF
    jfile "$u_d" com/x/Fake.java <<'EOF'
package com.x;

@SpringBootApplication
public class Fake {
    public static void main(String[] args) {
    }
}
EOF
    mc_build
    load_dr_at "$u_d"
    expect_refusal 'an annotation that is only named SpringBootApplication (com.x)' 'Unable to find a suitable main class' 'classes mentioning the annotation: none'
}
mc_still() {
    u_d=$HC_W/$U_ID
    japp "$u_d" com.x App
    mc_build
    u_o=$HC_W/$U_ID.other
    japp "$u_o" com.x Other
    if ! jcompile "$u_o"; then hc_fail "$U_ID" "the second candidate did not compile"; return 0; fi
    u_v=$HC_W/$U_ID.v2
    jfile "$u_v" com/x/App.java <<'EOF'
package com.x;

import org.springframework.boot.autoconfigure.SpringBootApplication;

@SpringBootApplication
public class App {
    public static void main(String[] args) {
        System.out.println("the second version");
    }
}
EOF
    if ! jcompile "$u_v"; then hc_fail "$U_ID" "the second version of App did not compile"; return 0; fi
    load_dr_at "$u_d"
    u_log=$HC_W/$U_ID.log
    if ! resolve_main >"$u_log" 2>&1; then
        show "$u_log"
        hc_fail "$U_ID" "resolve_main failed on a one-candidate fixture; nothing to check"
        return 0
    fi
    # launch_app would record this; the JVM itself is not needed here.
    RUNNING_MAIN=$MAIN_CLASS
    u_rc=0; main_still_valid || u_rc=$?
    if [ "$u_rc" -eq 0 ]; then hc_pass "$U_ID-VALID" "main_still_valid is true right after resolve_main"
    else hc_fail "$U_ID-VALID" "main_still_valid is false right after resolve_main: every compile would re-run javap"; fi

    cp "$u_o/target/classes/com/x/Other.class" "$CLASSES/com/x/Other.class"
    u_rc=0; main_still_valid || u_rc=$?
    if [ "$u_rc" -ne 0 ]; then hc_pass "$U_ID-NEWCAND" "main_still_valid is false once a second annotated class appears"
    else hc_fail "$U_ID-NEWCAND" "main_still_valid stays true with a second annotated class: an ambiguous main would go unnoticed"; fi

    rm -f "$CLASSES/com/x/Other.class"
    u_rc=0; main_still_valid || u_rc=$?
    if [ "$u_rc" -eq 0 ]; then hc_pass "$U_ID-BACK" "main_still_valid is true again when the candidate set is back to what resolve_main saw"
    else hc_fail "$U_ID-BACK" "main_still_valid stays false after the extra candidate is gone"; fi

    # Same name, new bytes - what a signature edit to main looks like from
    # here. DevTools would re-invoke main(String[]) on it without a check.
    cp "$CLASSES/com/x/App.class" "$u_d/App.class.orig"
    cp "$u_v/target/classes/com/x/App.class" "$CLASSES/com/x/App.class"
    u_rc=0; main_still_valid || u_rc=$?
    if [ "$u_rc" -ne 0 ]; then hc_pass "$U_ID-CHANGED" "main_still_valid is false once the main class's bytes change, so it is checked again before a trigger"
    else hc_fail "$U_ID-CHANGED" "main_still_valid stays true after the main class was recompiled differently: a broken main would be restarted into"; fi
    cp "$u_d/App.class.orig" "$CLASSES/com/x/App.class"

    rm -f "$CLASSES/com/x/App.class"
    u_rc=0; main_still_valid || u_rc=$?
    if [ "$u_rc" -ne 0 ]; then hc_pass "$U_ID-DELETED" "main_still_valid is false once the main class file is deleted"
    else hc_fail "$U_ID-DELETED" "main_still_valid is true with the main class file gone: a DevTools restart onto a missing main"; fi
    return 0
}

group_mc() {
    if ! command -v javac >/dev/null 2>&1 || ! command -v javap >/dev/null 2>&1; then
        hc_fail C-MC-TOOLS "javac or javap is not on PATH - dev-reload.sh's main-class check needs javap, and these fixtures need javac"
        return 0
    fi
    if ! mc_stub; then
        hc_fail C-MC-STUB "the stub @SpringBootApplication did not compile with javac --release $REL"
        return 0
    fi
    sub C-MC-ONE             mc_one
    sub C-MC-NONE            mc_none
    sub C-MC-TWO             mc_two
    sub C-MC-COMMENT         mc_comment
    sub C-MC-DECOY-STRING    mc_decoy_string
    sub C-MC-DECOY-SIG       mc_decoy_sig
    sub C-MC-PKG-PATH        mc_pkg_path
    sub C-MC-NOARGS          mc_noargs
    sub C-MC-INSTANCE        mc_instance
    sub C-MC-NOFALLBACK      mc_nofallback
    sub C-MC-OVERRIDE        mc_override
    sub C-MC-OVERRIDE-PLAIN  mc_override_plain
    sub C-MC-OVERRIDE-MISSING mc_override_missing
    sub C-MC-OVERRIDE-NOMAIN mc_override_nomain
    sub C-MC-INNER-OVERRIDE  mc_inner_override
    sub C-MC-INNER-AUTO      mc_inner_auto
    sub C-MC-INNER-CANONICAL mc_inner_canonical
    sub C-MC-NOCLASSES       mc_noclasses
    sub C-MC-HIDDEN          mc_hidden
    sub C-MC-ELEMENTS        mc_elements
    sub C-MC-VARARGS         mc_varargs
    sub C-MC-LOOKALIKE       mc_lookalike
    sub C-MC-STILL           mc_still
}

# ---------------------------------------------------------------------------
# C-LC: the launch command. app_argv, with_app_argv, read_classpath, launch_app
# ---------------------------------------------------------------------------

JDWP='-agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address=*:5005'
LC_DEPS=/root/.m2/repository/org/a/a/1/a-1.jar:/root/.m2/repository/org/b/b/2/b-2.jar

# lc_expect <what> <argv...>: app_argv must print exactly these words. The
# files are compared byte for byte: a command substitution would drop trailing
# newlines, and with them an empty last argument.
lc_expect() {
    u_what=$1
    shift
    u_exp=$HC_W/$U_ID.expected u_got=$HC_W/$U_ID.got
    printf '%s\n' "$@" >"$u_exp"
    app_argv >"$u_got"
    if cmp -s "$u_exp" "$u_got"; then
        hc_pass "$U_ID" "$u_what: $(joined "$u_got")"
    else
        hc_fail "$U_ID" "$u_what: expected [$(joined "$u_exp")], got [$(joined "$u_got")]"
    fi
    return 0
}
lc_java() {
    if [ -n "${JAVA_HOME:-}" ]; then printf '%s/bin/java' "$JAVA_HOME"; else printf java; fi
}

lc_order() {
    DEV_JVM_ARGS="$JDWP -Xmx256m"
    export DEV_JVM_ARGS
    load_dr
    DEPS=$LC_DEPS MAIN_CLASS=com.x.App
    lc_expect 'java, TieredStopAtLevel FIRST, the jvm args, -cp /app/target/classes:deps, main (the plugin'"'"'s order)' \
        "$(lc_java)" -XX:TieredStopAtLevel=1 "$JDWP" -Xmx256m -cp "/app/target/classes:$LC_DEPS" com.x.App
}
lc_devjava() {
    DEV_JAVA=/opt/hc/bin/java
    export DEV_JAVA
    load_dr
    DEPS=$LC_DEPS MAIN_CLASS=com.x.App
    lc_expect 'DEV_JAVA replaces the java binary' /opt/hc/bin/java -XX:TieredStopAtLevel=1 -cp "/app/target/classes:$LC_DEPS" com.x.App
}
lc_appdir() {
    DEV_APP_DIR=$HC_W/$U_ID/app
    export DEV_APP_DIR
    load_dr
    DEPS=$LC_DEPS MAIN_CLASS=com.x.App
    lc_expect 'DEV_APP_DIR moves the absolute classes directory with it' \
        "$(lc_java)" -XX:TieredStopAtLevel=1 -cp "$HC_W/$U_ID/app/target/classes:$LC_DEPS" com.x.App
}
lc_noopt() {
    DEV_OPTIMIZED_LAUNCH=false DEV_JVM_ARGS=$JDWP
    export DEV_OPTIMIZED_LAUNCH DEV_JVM_ARGS
    load_dr
    DEPS=$LC_DEPS MAIN_CLASS=com.x.App
    lc_expect 'DEV_OPTIMIZED_LAUNCH=false drops -XX:TieredStopAtLevel=1 and nothing else' \
        "$(lc_java)" "$JDWP" -cp "/app/target/classes:$LC_DEPS" com.x.App
}
lc_nojvm() {
    load_dr
    DEPS=$LC_DEPS MAIN_CLASS=com.x.App
    lc_expect 'no DEV_JVM_ARGS: no empty argument in their place' \
        "$(lc_java)" -XX:TieredStopAtLevel=1 -cp "/app/target/classes:$LC_DEPS" com.x.App
}
lc_split() {
    DEV_JVM_ARGS="  -Da=1${TAB}-Db=2    -Dc=3 "
    export DEV_JVM_ARGS
    load_dr
    DEPS=$LC_DEPS MAIN_CLASS=com.x.App
    lc_expect 'DEV_JVM_ARGS split on runs of spaces and tabs, like jvmArguments' \
        "$(lc_java)" -XX:TieredStopAtLevel=1 -Da=1 -Db=2 -Dc=3 -cp "/app/target/classes:$LC_DEPS" com.x.App
}
lc_noglob() {
    u_d=$HC_W/$U_ID
    mkdir -p "$u_d"
    cd "$u_d" || exit 1
    : >'./-agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address=GLOBBED:5005'
    : >'./-Dglob=GLOBBED'
    # The control: in this directory the two words DO expand, so a pass below
    # is the set -f and not an accident of an empty directory.
    set -- $JDWP -Dglob=*
    u_ctl="$1 $2"
    DEV_JVM_ARGS="$JDWP -Dglob=*"
    export DEV_JVM_ARGS
    load_dr
    DEPS=$LC_DEPS MAIN_CLASS=com.x.App
    case $u_ctl in
      *GLOBBED*GLOBBED*) ;;
      *) hc_fail "$U_ID" "control failed: '$u_ctl' did not glob in the fixture directory, so this case proves nothing"; return 0 ;;
    esac
    lc_expect "'*' in address=*:5005 reaches the JVM literally, with matching files in the cwd" \
        "$(lc_java)" -XX:TieredStopAtLevel=1 "$JDWP" '-Dglob=*' -cp "/app/target/classes:$LC_DEPS" com.x.App
    case $- in
      *f*) hc_fail "$U_ID-RESTORED" "with_app_argv left set -f on in the caller" ;;
      *) hc_pass "$U_ID-RESTORED" "with_app_argv turns globbing back on afterwards" ;;
    esac
    return 0
}

# launch_app itself, with a stand-in java that reports what it was given.
lc_spawn() {
    if [ ! -r /proc/uptime ]; then
        hc_skip "$U_ID" "needs /proc/uptime (Linux): launch_app timestamps the start with it"
        return 0
    fi
    u_d=$HC_W/$U_ID
    mkdir -p "$u_d/bin" "$u_d/app/target/classes"
    cat >"$u_d/bin/java" <<'EOF'
#!/bin/sh
printf '%s\n' "$0" "$@" >"$HC_ARGV_OUT"
echo "fake-java: on stdout"
echo "fake-java: on stderr" >&2
EOF
    chmod +x "$u_d/bin/java"
    : >"$u_d/dep.jar"
    printf '%s' "$u_d/dep.jar" >"$u_d/app/target/dev-classpath.txt"
    HC_ARGV_OUT=$u_d/argv DEV_JAVA=$u_d/bin/java DEV_APP_DIR=$u_d/app DEV_JVM_ARGS=-Dhc.test=1
    export HC_ARGV_OUT DEV_JAVA DEV_APP_DIR DEV_JVM_ARGS
    load_dr
    cd "$APP" || exit 1
    if ! read_classpath; then hc_fail "$U_ID" "read_classpath refused a valid one-jar classpath"; return 0; fi
    MAIN_CLASS=com.x.App
    app_argv >"$u_d/expected"
    launch_app >"$u_d/stdout" 2>"$u_d/stderr"
    u_pid=$APP_PID
    wait "$u_pid" || :
    show "$u_d/stdout"
    if [ -n "$u_pid" ] && cmp -s "$u_d/argv" "$u_d/expected"; then
        hc_pass "$U_ID" "launch_app runs exactly what app_argv prints: $(joined "$u_d/argv")"
    else
        hc_fail "$U_ID" "launch_app (pid '$u_pid') ran [$(joined "$u_d/argv" 2>/dev/null)], app_argv says [$(joined "$u_d/expected")]"
    fi
    if grep -qxF 'fake-java: on stderr' "$u_d/stdout" && [ ! -s "$u_d/stderr" ]; then
        hc_pass "$U_ID-STDERR" "the application's stderr is merged into stdout (2>&1), like the plugin's RunProcess"
    else
        hc_fail "$U_ID-STDERR" "the application's stderr is not merged into stdout (stderr file: $(cat "$u_d/stderr" | tr '\n' ' '))"
    fi
    return 0
}

# lc_cp <ok|refuse> <what> <content|MISSING> [<text in the error>...]
# In <content> and the texts, @A@ and @B@ are jars that exist, @G@ one that
# does not, and a final @NL@ is a trailing newline (spelled out, because a
# command substitution would silently eat a real one).
lc_cp() {
    u_want=$1 u_what=$2 u_content=$3
    shift 3
    u_d=$HC_W/$U_ID
    mkdir -p "$u_d/app/target"
    : >"$u_d/a.jar"
    : >"$u_d/b.jar"
    u_ja=$u_d/a.jar u_jb=$u_d/b.jar u_jg=$u_d/gone.jar
    u_nl=""
    case $u_content in *@NL@) u_content=${u_content%@NL@} u_nl=yes ;; esac
    u_content=$(printf '%s' "$u_content" | sed -e "s|@A@|$u_ja|g" -e "s|@B@|$u_jb|g" -e "s|@G@|$u_jg|g")
    if [ "$u_content" != MISSING ]; then
        printf '%s' "$u_content" >"$u_d/app/target/dev-classpath.txt"
        if [ -n "$u_nl" ]; then printf '\n' >>"$u_d/app/target/dev-classpath.txt"; fi
    fi
    load_dr_at "$u_d/app"
    u_log=$HC_W/$U_ID.log
    u_rc=0
    read_classpath >"$u_log" 2>&1 || u_rc=$?
    show "$u_log"
    if [ "$u_want" = ok ]; then
        if [ "$u_rc" -eq 0 ] && [ "$DEPS" = "$(printf '%s' "$u_content")" ]; then hc_pass "$U_ID" "$u_what: accepted, DEPS=$DEPS"
        else hc_fail "$U_ID" "$u_what: expected it accepted; status $u_rc, DEPS='$DEPS' ($(event_text "$u_log" classpath-error))"; fi
        return 0
    fi
    u_missing=""
    for u_t in "$@"; do
        u_t=$(printf '%s' "$u_t" | sed -e "s|@G@|$u_jg|g")
        grep -F -- "$u_t" "$u_log" >/dev/null 2>&1 || u_missing="$u_missing [$u_t]"
    done
    u_err=$(event_text "$u_log" classpath-error)
    if [ "$u_rc" -ne 0 ] && [ -n "$u_err" ] && [ -z "$u_missing" ]; then hc_pass "$U_ID" "$u_what: refused - $u_err"
    else hc_fail "$U_ID" "$u_what: expected a refusal; status $u_rc, error '$u_err', missing from it:${u_missing:- nothing}"; fi
    return 0
}

# start_app on a missing classpath: refused, and no java ever started.
lc_refuse_nospawn() {
    u_d=$HC_W/$U_ID
    mkdir -p "$u_d/bin" "$u_d/app/target/classes"
    printf '#!/bin/sh\n: >"%s/java-ran"\n' "$u_d" >"$u_d/bin/java"
    chmod +x "$u_d/bin/java"
    DEV_JAVA=$u_d/bin/java
    export DEV_JAVA
    load_dr_at "$u_d/app"
    # Sourcing sets it to 1; cleared, so that the check below measures start_app.
    BUILD_PENDING=0
    u_log=$HC_W/$U_ID.log
    u_rc=0
    start_app >"$u_log" 2>&1 || u_rc=$?
    sleep 1
    show "$u_log"
    if [ "$u_rc" -ne 0 ] && [ -z "$APP_PID" ] && [ ! -e "$u_d/java-ran" ] && [ "$BUILD_PENDING" = 1 ] &&
       grep -q '^\[dev-reload\] launch-refused: ' "$u_log"; then
        hc_pass "$U_ID" "no classpath file: start_app refuses (launch-refused), spawns no java and marks a full build pending"
    else
        hc_fail "$U_ID" "no classpath file: status $u_rc, APP_PID='$APP_PID', java ran: $([ -e "$u_d/java-ran" ] && echo yes || echo no), BUILD_PENDING=$BUILD_PENDING"
    fi
    return 0
}

# full_build must never leave a stale classpath behind for a later start.
lc_stale() {
    u_mode=$1
    if [ ! -r /proc/uptime ]; then
        hc_skip "$U_ID" "needs /proc/uptime (Linux): full_build times itself with it"
        return 0
    fi
    u_d=$HC_W/$U_ID
    mkdir -p "$u_d/bin" "$u_d/app/target/classes"
    : >"$u_d/old.jar"
    printf '%s' "$u_d/old.jar" >"$u_d/app/target/dev-classpath.txt"
    # A mvnd that fails, or "succeeds" without writing the file.
    if [ "$u_mode" = fail ]; then printf '#!/bin/sh\necho "[fake mvnd] BUILD FAILURE"\nexit 1\n' >"$u_d/bin/mvnd"
    else printf '#!/bin/sh\necho "[fake mvnd] BUILD SUCCESS"\nexit 0\n' >"$u_d/bin/mvnd"; fi
    chmod +x "$u_d/bin/mvnd"
    PATH=$u_d/bin:$PATH
    export PATH
    load_dr_at "$u_d/app"
    cd "$APP" || exit 1
    mkdir -p "$STATE"
    COMPILE=mvnd
    # Sourcing sets it to 1; cleared, so that the check below measures full_build.
    BUILD_PENDING=0
    u_log=$HC_W/$U_ID.log
    u_rc=0
    full_build test >"$u_log" 2>&1 || u_rc=$?
    show "$u_log"
    u_rc2=0
    read_classpath >>"$u_log" 2>&1 || u_rc2=$?
    if [ "$u_rc" -ne 0 ] && [ ! -e "$CP_FILE" ] && [ "$u_rc2" -ne 0 ] && [ "$BUILD_PENDING" = 1 ] &&
       grep -q '^\[dev-reload\] build-failed: ' "$u_log"; then
        hc_pass "$U_ID" "a full build that $([ "$u_mode" = fail ] && echo fails || echo writes no classpath) deletes the old dev-classpath.txt, so no later start can use it"
    else
        hc_fail "$U_ID" "full_build status $u_rc, classpath file $([ -e "$CP_FILE" ] && echo 'still there' || echo gone), read_classpath status $u_rc2, BUILD_PENDING=$BUILD_PENDING"
    fi
    return 0
}

group_lc() {
    sub C-LC-ORDER        lc_order
    sub C-LC-DEVJAVA      lc_devjava
    sub C-LC-APPDIR       lc_appdir
    sub C-LC-NOOPT        lc_noopt
    sub C-LC-NOJVMARGS    lc_nojvm
    sub C-LC-SPLIT        lc_split
    sub C-LC-NOGLOB       lc_noglob
    sub C-LC-SPAWN        lc_spawn
    sub C-LC-CP-OK        lc_cp ok     'two existing jars'                '@A@:@B@'
    sub C-LC-CP-NEWLINE   lc_cp ok     'a trailing newline'               '@A@:@B@@NL@'
    sub C-LC-CP-MISSING   lc_cp refuse 'no classpath file'                MISSING 'missing or empty'
    sub C-LC-CP-EMPTY     lc_cp refuse 'an empty classpath file'          ''      'missing or empty'
    sub C-LC-CP-EMPTYENTRY lc_cp refuse "an empty '::' entry (the cwd on the classpath)" '@A@::@B@' 'empty entry'
    sub C-LC-CP-LEADING   lc_cp refuse 'a leading colon'                  ':@A@:@B@' 'empty entry'
    sub C-LC-CP-TRAILING  lc_cp refuse 'a trailing colon'                 '@A@:@B@:' 'empty entry'
    sub C-LC-CP-GONE      lc_cp refuse 'a jar that is not in the volume'  '@A@:@G@:@B@' '@G@' 'not in the Maven volume'
    sub C-LC-REFUSE-NOSPAWN lc_refuse_nospawn
    sub C-LC-STALE-FAILED lc_stale fail
    sub C-LC-STALE-NOFILE lc_stale nofile
}

# ---------------------------------------------------------------------------
# C-GOOD: the last good compile. snapshot_good, restore_good
# ---------------------------------------------------------------------------

good_fixture() {
    mkdir -p "$1/target/classes/com/x/web" "$1/target/classes/META-INF" \
             "$1/target/maven-status/maven-compiler-plugin/compile/default-compile"
    printf 'A-v1' >"$1/target/classes/com/x/A.class"
    printf 'B-v1' >"$1/target/classes/com/x/B.class"
    printf 'C-v1' >"$1/target/classes/com/x/web/C.class"
    printf 'server.port=8081\n' >"$1/target/classes/application.properties"
    printf 'x\n' >"$1/target/classes/META-INF/my notes.txt"
    u_mcp=$1/target/maven-status/maven-compiler-plugin/compile/default-compile
    printf 'com/x/A.class\ncom/x/B.class\ncom/x/web/C.class\n' >"$u_mcp/createdFiles.lst"
    printf '/app/src/main/java/com/x/A.java\n/app/src/main/java/com/x/B.java\n' >"$u_mcp/inputFiles.lst"
    find "$1/target" -type f -exec touch -t "$T0" {} +
    : >"$1/target/classes/.reloadtrigger"
    touch -t "$TOLD" "$1/target/classes/.reloadtrigger"
}

good_restore() {
    u_d=$HC_W/$U_ID
    good_fixture "$u_d"
    load_dr_at "$u_d"
    mkdir -p "$STATE"
    u_cls=$(tree_state "$CLASSES" "$TRIGGER_NAME")
    u_sts=$(tree_state "$STATUS" none)

    snapshot_good
    if [ "$(tree_state "$GOOD/classes" none)" = "$u_cls" ] && [ ! -e "$GOOD/classes/$TRIGGER_NAME" ] &&
       [ "$(tree_state "$GOOD/maven-status" none)" = "$u_sts" ]; then
        hc_pass "$U_ID-SNAPSHOT" "snapshot_good copies target/classes (names, sizes, mtimes, contents) and maven-status, and not the trigger file"
    else
        hc_fail "$U_ID-SNAPSHOT" "the snapshot in $GOOD is not an exact copy of target/classes + maven-status without the trigger"
    fi
    # The good compile is followed by reload_after_compile touching the
    # trigger - AFTER the snapshot. A restore that put the snapshot-time mtime
    # back would be a change, and DevTools would restart onto the failure.
    touch -t "$T0P1" "$TRIGGER"
    u_trig=$(mtime_of "$TRIGGER")

    # What a failed compile leaves: maven-shared-incremental deleted what the
    # last run created, javac wrote part of the new output, and the status
    # files describe a build that never finished.
    rm -f "$CLASSES/com/x/A.class"
    printf 'B-v2' >"$CLASSES/com/x/B.class"
    mkdir -p "$CLASSES/com/y"
    printf 'stray' >"$CLASSES/com/y/Stray.class"
    printf 'stray' >"$CLASSES/com/x/Stray two.class"
    u_mcp=$STATUS/maven-compiler-plugin/compile/default-compile
    printf 'com/x/B.class\n' >"$u_mcp/createdFiles.lst"
    printf 'half\n' >"$u_mcp/stale.lst"

    u_log=$HC_W/$U_ID.log
    u_rc=0
    restore_good >"$u_log" 2>&1 || u_rc=$?
    show "$u_log"
    if [ "$u_rc" -eq 0 ] && grep -q '^\[dev-reload\] classes-restored: ' "$u_log"; then
        hc_pass "$U_ID-RC" "restore_good succeeds and says classes-restored"
    else
        hc_fail "$U_ID-RC" "restore_good returned $u_rc"
    fi
    if [ "$(tree_state "$CLASSES" "$TRIGGER_NAME")" = "$u_cls" ]; then
        hc_pass "$U_ID-CLASSES" "target/classes is exactly as snapshotted: the deleted class is back, the changed one reverted, mtimes kept"
    else
        hc_fail "$U_ID-CLASSES" "target/classes differs from the snapshot after restore_good"
        tree_state "$CLASSES" "$TRIGGER_NAME" | sed 's/^/    now  | /'
        printf '%s\n' "$u_cls" | sed 's/^/    want | /'
    fi
    if [ ! -e "$CLASSES/com/y/Stray.class" ] && [ ! -e "$CLASSES/com/x/Stray two.class" ]; then
        hc_pass "$U_ID-STRAY" "classes the failed compile added are removed (a space in the name included)"
    else
        hc_fail "$U_ID-STRAY" "a class the failed compile added survived restore_good"
    fi
    if [ "$(tree_state "$STATUS" none)" = "$u_sts" ]; then
        hc_pass "$U_ID-STATUS" "target/maven-status is back to the good build's, the half-written file gone"
    else
        hc_fail "$U_ID-STATUS" "target/maven-status differs from the snapshot after restore_good: the next good build would clean up after the wrong set of classes"
    fi
    u_trig2=$(mtime_of "$TRIGGER" 2>/dev/null) || u_trig2=missing
    if [ "$u_trig2" = "$u_trig" ]; then
        hc_pass "$U_ID-TRIGGER" "the trigger file's mtime is unchanged ($u_trig): DevTools does not restart onto a failed compile"
    else
        hc_fail "$U_ID-TRIGGER" "the trigger file's mtime moved ($u_trig -> $u_trig2): DevTools would restart after a FAILED compile"
    fi
    return 0
}

good_nosnap() {
    u_d=$HC_W/$U_ID
    good_fixture "$u_d"
    load_dr_at "$u_d"
    mkdir -p "$STATE"
    u_cls=$(tree_state "$CLASSES" "$TRIGGER_NAME")
    u_rc=0
    restore_good >/dev/null 2>&1 || u_rc=$?
    # And through build_failed, which acts on that failure: target/classes
    # must no longer count as a successful compile.
    CLASSES_OK=1
    build_failed >/dev/null 2>&1
    if [ "$u_rc" -ne 0 ] && [ "$CLASSES_OK" = 0 ] && [ "$(tree_state "$CLASSES" "$TRIGGER_NAME")" = "$u_cls" ]; then
        hc_pass "$U_ID" "with no snapshot yet, restore_good fails, build_failed sets CLASSES_OK=0, and target/classes is left alone"
    else
        hc_fail "$U_ID" "with no snapshot: restore_good returned $u_rc, CLASSES_OK=$CLASSES_OK after build_failed, target/classes $([ "$(tree_state "$CLASSES" "$TRIGGER_NAME")" = "$u_cls" ] && echo unchanged || echo changed)"
    fi
    return 0
}

# A second good build REPLACES the snapshot: a class a successful compile
# deleted must not come back on the next failure.
good_resnap() {
    u_d=$HC_W/$U_ID
    good_fixture "$u_d"
    load_dr_at "$u_d"
    mkdir -p "$STATE"
    snapshot_good
    rm -f "$CLASSES/com/x/A.class"
    snapshot_good
    rm -f "$CLASSES/com/x/B.class"
    restore_good >/dev/null 2>&1 || :
    if [ ! -e "$CLASSES/com/x/A.class" ] && [ -f "$CLASSES/com/x/B.class" ]; then
        hc_pass "$U_ID" "the second snapshot replaces the first: a class deleted by a GOOD compile stays deleted, one lost to a failed compile comes back"
    else
        hc_fail "$U_ID" "after two snapshots and a restore: A.class $([ -e "$CLASSES/com/x/A.class" ] && echo resurrected || echo absent), B.class $([ -f "$CLASSES/com/x/B.class" ] && echo restored || echo missing)"
    fi
    return 0
}

# build_ok prunes BEFORE it snapshots: a resource deleted by a good build must
# not be in the copy that a later failed compile restores.
good_pruned() {
    u_d=$HC_W/$U_ID
    good_fixture "$u_d"
    mkdir -p "$u_d/src/main/resources/static" "$u_d/target/classes/static"
    printf 'server.port=8081\n' >"$u_d/src/main/resources/application.properties"
    printf 'body {}\n' >"$u_d/src/main/resources/static/app.css"
    cp "$u_d/src/main/resources/static/app.css" "$u_d/target/classes/static/app.css"
    cd "$u_d" || exit 1
    load_dr_at "$u_d"
    mkdir -p "$STATE"
    u_log=$HC_W/$U_ID.log
    # A good build that knows both resources; then app.css is deleted and the
    # next build is good too; then a compile fails.
    note_resources
    build_ok >"$u_log" 2>&1
    rm src/main/resources/static/app.css
    note_resources
    build_ok >>"$u_log" 2>&1
    rm -f "$CLASSES/com/x/A.class"
    restore_good >>"$u_log" 2>&1 || :
    show "$u_log"
    if [ ! -e "$CLASSES/static/app.css" ] && [ ! -e "$GOOD/classes/static/app.css" ] && [ -f "$CLASSES/com/x/A.class" ]; then
        hc_pass "$U_ID" "build_ok prunes before it snapshots: a resource deleted by a good build does not come back when a later compile fails"
    else
        hc_fail "$U_ID" "after a good build deleted static/app.css and a later compile failed, it is $([ -e "$CLASSES/static/app.css" ] && echo 'back on the classpath' || echo gone) (in the snapshot: $([ -e "$GOOD/classes/static/app.css" ] && echo yes || echo no))"
    fi
    return 0
}

# force_full_compile: the compiler's record of its inputs goes, so it treats
# every source as changed (clock skew cannot make it skip one), while its
# record of what it created stays, so that it can still clean up.
good_forcefull() {
    u_d=$HC_W/$U_ID
    good_fixture "$u_d"
    load_dr_at "$u_d"
    u_mcp=$STATUS/maven-compiler-plugin/compile/default-compile
    force_full_compile
    if [ ! -e "$u_mcp/inputFiles.lst" ] && [ -f "$u_mcp/createdFiles.lst" ]; then
        hc_pass "$U_ID" "force_full_compile deletes inputFiles.lst (every source counts as changed) and keeps createdFiles.lst (stale classes are still cleaned up)"
    else
        hc_fail "$U_ID" "force_full_compile: inputFiles.lst $([ -e "$u_mcp/inputFiles.lst" ] && echo 'still there' || echo gone), createdFiles.lst $([ -f "$u_mcp/createdFiles.lst" ] && echo kept || echo 'deleted too')"
    fi
    return 0
}
# ... and compile_only does it before Maven runs, not after.
good_forcefull_order() {
    if [ ! -r /proc/uptime ]; then
        hc_skip "$U_ID" "needs /proc/uptime (Linux): compile_only times itself with it"
        return 0
    fi
    u_d=$HC_W/$U_ID
    good_fixture "$u_d"
    mkdir -p "$u_d/bin"
    cat >"$u_d/bin/mvnd" <<'EOF'
#!/bin/sh
if [ -e "$HC_INPUTS" ]; then echo present >"$HC_REC"; else echo absent >"$HC_REC"; fi
EOF
    chmod +x "$u_d/bin/mvnd"
    HC_INPUTS=$u_d/target/maven-status/maven-compiler-plugin/compile/default-compile/inputFiles.lst
    HC_REC=$u_d/seen PATH=$u_d/bin:$PATH
    export HC_INPUTS HC_REC PATH
    cd "$u_d" || exit 1
    load_dr_at "$u_d"
    mkdir -p "$STATE"
    COMPILE=mvnd
    u_log=$HC_W/$U_ID.log
    u_rc=0
    compile_only source >"$u_log" 2>&1 || u_rc=$?
    show "$u_log"
    u_seen=$(cat "$HC_REC" 2>/dev/null) || u_seen=never-ran
    if [ "$u_rc" -eq 0 ] && [ "$u_seen" = absent ]; then
        hc_pass "$U_ID" "compile_only removes inputFiles.lst before Maven runs"
    else
        hc_fail "$U_ID" "compile_only: status $u_rc; while Maven ran, inputFiles.lst was $u_seen"
    fi
    return 0
}

group_good() {
    sub C-GOOD        good_restore
    sub C-GOOD-NOSNAP good_nosnap
    sub C-GOOD-RESNAP good_resnap
    sub C-GOOD-PRUNED good_pruned
    sub C-GOOD-FORCEFULL good_forcefull
    sub C-GOOD-FORCEFULL-ORDER good_forcefull_order
}

# ---------------------------------------------------------------------------
# C-RES: deleted resources leave target/classes. note_resources, prune_resources
# ---------------------------------------------------------------------------

res_fixture() {
    mkdir -p "$1/src/main/resources/static" "$1/target/classes/static" "$1/target/classes/com/x" "$1/target/classes/META-INF"
    printf 'server.port=8081\n' >"$1/src/main/resources/application.properties"
    printf 'body {}\n' >"$1/src/main/resources/static/app.css"
    printf 'b\n' >"$1/src/main/resources/b c.txt"
    # What the resources plugin copied, plus files that were never resources.
    cp "$1/src/main/resources/application.properties" "$1/target/classes/"
    cp "$1/src/main/resources/static/app.css" "$1/target/classes/static/"
    cp "$1/src/main/resources/b c.txt" "$1/target/classes/"
    printf 'A' >"$1/target/classes/com/x/A.class"
    printf 'generated\n' >"$1/target/classes/META-INF/generated.txt"
}
res_load() {
    u_d=$HC_W/$U_ID
    res_fixture "$u_d"
    cd "$u_d" || exit 1
    load_dr_at "$u_d"
    mkdir -p "$STATE"
    u_log=$HC_W/$U_ID.log
    : >"$u_log"
}
res_build_ok() { note_resources; prune_resources >>"$u_log" 2>&1; }

res_keep() {
    res_load
    res_build_ok
    show "$u_log"
    if [ ! -s "$u_log" ] && [ -f target/classes/static/app.css ] && [ -f 'target/classes/b c.txt' ] && [ -f target/classes/application.properties ]; then
        hc_pass "$U_ID" "a build with every resource still present removes nothing"
    else
        hc_fail "$U_ID" "a build with nothing deleted removed or reported something"
    fi
    return 0
}
res_deleted() {
    res_load
    res_build_ok
    rm src/main/resources/static/app.css 'src/main/resources/b c.txt'
    res_build_ok
    show "$u_log"
    if [ ! -e target/classes/static/app.css ] && [ ! -e 'target/classes/b c.txt' ] &&
       grep -qxF '[dev-reload] resource-removed: static/app.css' "$u_log" &&
       grep -qxF '[dev-reload] resource-removed: b c.txt' "$u_log"; then
        hc_pass "$U_ID" "deleted resources (one with a space in its name) are removed from target/classes and reported"
    else
        hc_fail "$U_ID" "a deleted resource's copy is still on the classpath, or was not reported as resource-removed"
    fi
    if [ -f target/classes/application.properties ] && [ -f target/classes/com/x/A.class ] && [ -f target/classes/META-INF/generated.txt ]; then
        hc_pass "$U_ID-OTHERS" "remaining resources, classes and files that never were resources are left alone"
    else
        hc_fail "$U_ID-OTHERS" "prune_resources removed something that was not a deleted resource"
    fi
    return 0
}
res_renamed() {
    res_load
    res_build_ok
    mv src/main/resources/application.properties src/main/resources/application.yml
    cp src/main/resources/application.yml target/classes/application.yml
    res_build_ok
    show "$u_log"
    if [ ! -e target/classes/application.properties ] && [ -f target/classes/application.yml ]; then
        hc_pass "$U_ID" "a renamed resource: the old name's copy goes, the new one stays"
    else
        hc_fail "$U_ID" "after a rename, application.properties is $([ -e target/classes/application.properties ] && echo 'still there' || echo gone) and application.yml $([ -f target/classes/application.yml ] && echo present || echo missing)"
    fi
    return 0
}
# A resource deleted while the compile is failing is still pruned by the
# first compile that succeeds.
res_afterfail() {
    res_load
    res_build_ok
    rm src/main/resources/static/app.css
    note_resources
    res_build_ok
    show "$u_log"
    if [ ! -e target/classes/static/app.css ]; then
        hc_pass "$U_ID" "a resource deleted during a failed compile is pruned by the next good one"
    else
        hc_fail "$U_ID" "a resource deleted during a failed compile stays on the classpath for good"
    fi
    return 0
}
res_dirgone() {
    res_load
    res_build_ok
    rm -rf src/main/resources
    res_build_ok
    show "$u_log"
    if [ ! -e target/classes/static/app.css ] && [ ! -e target/classes/application.properties ] && [ ! -e 'target/classes/b c.txt' ] &&
       [ -f target/classes/com/x/A.class ]; then
        hc_pass "$U_ID" "deleting src/main/resources entirely removes every resource copy, and no class"
    else
        hc_fail "$U_ID" "after deleting src/main/resources, resource copies survive or a class went"
    fi
    return 0
}

group_res() {
    sub C-RES-KEEP      res_keep
    sub C-RES-DELETED   res_deleted
    sub C-RES-RENAMED   res_renamed
    sub C-RES-AFTERFAIL res_afterfail
    sub C-RES-DIRGONE   res_dirgone
}

# ---------------------------------------------------------------------------
# C-VAL: settings are refused up front. validate_settings
# ---------------------------------------------------------------------------

# val <ok|fatal> <what> [NAME=value...]
val() {
    u_want=$1 u_what=$2
    shift 2
    for u_kv in "$@"; do export "$u_kv"; done
    load_dr
    u_log=$HC_W/$U_ID.log
    u_rc=0
    validate_settings >"$u_log" 2>&1 || u_rc=$?
    u_err=$(event_text "$u_log" fatal)
    if [ "$u_want" = ok ]; then
        if [ "$u_rc" -eq 0 ] && [ ! -s "$u_log" ]; then hc_pass "$U_ID" "$u_what: accepted"
        else hc_fail "$U_ID" "$u_what: refused (status $u_rc) - $u_err"; fi
    else
        u_name=${1%%=*}
        if [ "$u_rc" -ne 0 ] && [ -n "$u_err" ] && case $u_err in *"$u_name"*) true ;; *) false ;; esac; then
            hc_pass "$U_ID" "$u_what: refused - $u_err"
        else
            hc_fail "$U_ID" "$u_what: expected a fatal naming $u_name, got status $u_rc - '$u_err'"
        fi
    fi
    return 0
}

# The real entry point, with a bad setting: it must stop before the mvnd
# probe, the cd, or anything else - the whole point of validating first.
val_failfast() {
    u_d=$HC_W/$U_ID
    mkdir -p "$u_d/bin"
    printf '#!/bin/sh\n: >"%s/mvnd-ran"\n' "$u_d" >"$u_d/bin/mvnd"
    chmod +x "$u_d/bin/mvnd"
    u_out=$(PATH="$u_d/bin:$PATH" DEV_RELOAD_LIB_ONLY=0 DEV_RELOAD_INTERVAL=abc DEV_APP_DIR="$u_d/app" \
            "$HC_SH" "$DR" --build-only 2>&1)
    u_rc=$?
    printf '%s\n' "$u_out" | sed 's/^/    | /'
    if [ "$u_rc" -eq 1 ] && [ ! -e "$u_d/mvnd-ran" ] && [ ! -e "$u_d/app" ] &&
       printf '%s\n' "$u_out" | grep -q '^\[dev-reload\] fatal: DEV_RELOAD_INTERVAL'; then
        hc_pass "$U_ID" "sh dev-reload.sh --build-only with DEV_RELOAD_INTERVAL=abc exits 1 with a fatal line before probing mvnd or touching the app directory"
    else
        hc_fail "$U_ID" "bad setting: exit $u_rc, mvnd probed: $([ -e "$u_d/mvnd-ran" ] && echo yes || echo no), app dir created: $([ -e "$u_d/app" ] && echo yes || echo no)"
    fi
    return 0
}

group_val() {
    sub C-VAL-DEFAULTS         val ok    'every setting at its default'
    sub C-VAL-INTERVAL-ABC     val fatal 'DEV_RELOAD_INTERVAL=abc'   DEV_RELOAD_INTERVAL=abc
    sub C-VAL-INTERVAL-ZERO    val fatal 'DEV_RELOAD_INTERVAL=0'     DEV_RELOAD_INTERVAL=0
    sub C-VAL-INTERVAL-ZEROF   val fatal 'DEV_RELOAD_INTERVAL=0.0'   DEV_RELOAD_INTERVAL=0.0
    sub C-VAL-INTERVAL-2SEC    val fatal 'DEV_RELOAD_INTERVAL=2sec'  DEV_RELOAD_INTERVAL=2sec
    sub C-VAL-INTERVAL-DOTS    val fatal 'DEV_RELOAD_INTERVAL=1.2.3' DEV_RELOAD_INTERVAL=1.2.3
    sub C-VAL-INTERVAL-NEG     val fatal 'DEV_RELOAD_INTERVAL=-1'    DEV_RELOAD_INTERVAL=-1
    sub C-VAL-INTERVAL-2       val ok    'DEV_RELOAD_INTERVAL=2'     DEV_RELOAD_INTERVAL=2
    sub C-VAL-INTERVAL-HALF    val ok    'DEV_RELOAD_INTERVAL=0.5'   DEV_RELOAD_INTERVAL=0.5
    sub C-VAL-STOP-ABC         val fatal 'DEV_STOP_TIMEOUT=abc'      DEV_STOP_TIMEOUT=abc
    sub C-VAL-STOP-10S         val fatal 'DEV_STOP_TIMEOUT=10s'      DEV_STOP_TIMEOUT=10s
    sub C-VAL-STOP-35          val ok    'DEV_STOP_TIMEOUT=35'       DEV_STOP_TIMEOUT=35
    sub C-VAL-STOP-40          val ok    'DEV_STOP_TIMEOUT=40'       DEV_STOP_TIMEOUT=40
    sub C-VAL-STOP-41          val fatal "DEV_STOP_TIMEOUT=41 (past compose's 45s stop_grace_period once the JVM's own shutdown is added)" DEV_STOP_TIMEOUT=41
    sub C-VAL-BOOT-5M          val fatal 'DEV_BOOT_TIMEOUT=5m'       DEV_BOOT_TIMEOUT=5m
    sub C-VAL-BOOT-ZERO        val fatal 'DEV_BOOT_TIMEOUT=0 (a new JVM on every tick)' DEV_BOOT_TIMEOUT=0
    sub C-VAL-FAILSECS-ABC     val fatal 'DEV_RELOAD_FAIL_SECS=abc'  DEV_RELOAD_FAIL_SECS=abc
    sub C-VAL-FAILSECS-ZERO    val fatal 'DEV_RELOAD_FAIL_SECS=0'    DEV_RELOAD_FAIL_SECS=0
    sub C-VAL-PORT-ABC         val fatal 'DEV_APP_PORT=80a'          DEV_APP_PORT=80a
    sub C-VAL-PORT-8081        val ok    'DEV_APP_PORT=8081'         DEV_APP_PORT=8081
    sub C-VAL-COMPILER-GRADLE  val fatal 'DEV_COMPILER=gradle'       DEV_COMPILER=gradle
    sub C-VAL-COMPILER-AUTO    val ok    'DEV_COMPILER=auto'         DEV_COMPILER=auto
    sub C-VAL-COMPILER-MVND    val ok    'DEV_COMPILER=mvnd'         DEV_COMPILER=mvnd
    sub C-VAL-COMPILER-MVNW    val ok    'DEV_COMPILER=mvnw'         DEV_COMPILER=mvnw
    sub C-VAL-OPT-YES          val fatal 'DEV_OPTIMIZED_LAUNCH=yes'  DEV_OPTIMIZED_LAUNCH=yes
    sub C-VAL-OPT-FALSE        val ok    'DEV_OPTIMIZED_LAUNCH=false' DEV_OPTIMIZED_LAUNCH=false
    sub C-VAL-JVMARGS-DQUOTE   val fatal 'DEV_JVM_ARGS with a double quote' 'DEV_JVM_ARGS=-Dx="a b"'
    sub C-VAL-JVMARGS-SQUOTE   val fatal "DEV_JVM_ARGS with a single quote" "DEV_JVM_ARGS=-Dx='a b'"
    sub C-VAL-EXTRA-QUOTE      val fatal 'DEV_MAVEN_EXTRA_ARGS with a quote' 'DEV_MAVEN_EXTRA_ARGS=-Dx="y"'
    sub C-VAL-JVMARGS-JDWP     val ok    "compose's DEV_JVM_ARGS (JDWP on *:5005)" "DEV_JVM_ARGS=$JDWP"
    sub C-VAL-FAILFAST         val_failfast
}

# ---------------------------------------------------------------------------
# C-WRAP: the wrapper's Maven, installed once. ensure_wrapper and friends
# ---------------------------------------------------------------------------

wrap_url() { printf 'https://repo.maven.apache.org/maven2/org/apache/maven/apache-maven/%s/apache-maven-%s-bin.zip' "$1" "$1"; }

# A project whose mvnw is a stand-in for the only-script mvnw 3.3: same
# MAVEN_HOME layout (dists/<name>/<hash>), same "exists? then run it" check,
# same mktemp-then-mv install - but it downloads nothing, counts its installs
# in $HC_WRAP_COUNT (recording the TMPDIR it was given), and takes
# $HC_WRAP_SLOW seconds, so that concurrent callers really overlap. Mode 644,
# like a Windows checkout: dev-reload.sh runs it with sh.
wrap_project() {
    mkdir -p "$1/.mvn/wrapper"
    printf 'wrapperVersion=3.3.4\ndistributionType=only-script\ndistributionUrl=%s\n' "$(wrap_url "$2")" \
        >"$1/.mvn/wrapper/maven-wrapper.properties"
    cat >"$1/mvnw" <<'EOF'
#!/bin/sh
set -eu
url=$(sed -n 's/^distributionUrl=//p' .mvn/wrapper/maven-wrapper.properties | tr -d '\r')
name=${url##*/}
main=${name%.*}
main=${main%-bin}
home=${MAVEN_USER_HOME:-$HOME/.m2}/wrapper/dists/$main/0123abcd
if [ -d "$home" ]; then exec sh "$home/bin/mvn" "$@"; fi
printf '%s\n' "${TMPDIR:-unset}" >>"$HC_WRAP_COUNT"
tmp=$(mktemp -d)
mkdir -p "${home%/*}" "$tmp/$main/bin" "$tmp/$main/lib" "$tmp/$main/boot"
sleep "${HC_WRAP_SLOW:-0}"
printf '#!/bin/sh\necho "Apache Maven (fake, installed by the test mvnw)"\n' >"$tmp/$main/bin/mvn"
: >"$tmp/$main/lib/maven-core-3.9.16.jar"
: >"$tmp/$main/boot/plexus-classworlds-2.9.0.jar"
printf '%s\n' "$url" >"$tmp/$main/mvnw.url"
mv -- "$tmp/$main" "$home" || [ -d "$home" ] || exit 1
rm -rf "$tmp"
exec sh "$home/bin/mvn" "$@"
EOF
    chmod 644 "$1/mvnw"
}
# seed_dist <m2> <version> <complete|binonly>
seed_dist() {
    uh_h=$1/wrapper/dists/apache-maven-$2/0123abcd
    mkdir -p "$uh_h/bin"
    printf '#!/bin/sh\necho "Apache Maven %s (seeded)"\n' "$2" >"$uh_h/bin/mvn"
    chmod +x "$uh_h/bin/mvn"
    if [ "$3" = complete ]; then
        mkdir -p "$uh_h/lib" "$uh_h/boot"
        : >"$uh_h/lib/maven-core-$2.jar"
        : >"$uh_h/boot/plexus-classworlds-2.9.0.jar"
        printf '%s\n' "$(wrap_url "$2")" >"$uh_h/mvnw.url"
    fi
}
# The environment every wrap case shares, then the functions, then cd into
# the project (every wrapper function works on ./mvnw and ./.mvn).
wrap_load() {
    u_d=$HC_W/$U_ID
    u_p=$u_d/proj u_m=$u_d/m2
    wrap_project "$u_p" "${1:-3.9.16}"
    mkdir -p "$u_m"
    MAVEN_USER_HOME=$u_m HC_WRAP_COUNT=$u_d/installs
    export MAVEN_USER_HOME HC_WRAP_COUNT
    load_dr
    cd "$u_p" || exit 1
    u_log=$HC_W/$U_ID.log
    u_home=$u_m/wrapper/dists/apache-maven-3.9.16/0123abcd
}
wrap_ready_rc() { uh_r=0; wrapper_ready || uh_r=$?; echo "$uh_r"; }

wrap_flock() {
    if command -v flock >/dev/null 2>&1; then hc_pass "$U_ID" "flock is on PATH ($(command -v flock)): the wrapper install can be serialised"
    else hc_fail "$U_ID" "flock is not on PATH in the dev image - ensure_wrapper cannot take its lock"; fi
    return 0
}
wrap_fresh() {
    wrap_load
    u_r0=$(wrap_ready_rc)
    u_rc=0
    ensure_wrapper >"$u_log" 2>&1 || u_rc=$?
    show "$u_log"
    u_r1=$(wrap_ready_rc)
    u_n=$(count_lines "$HC_WRAP_COUNT")
    if [ "$u_r0" -ne 0 ] && [ "$u_rc" -eq 0 ] && [ "$u_n" = 1 ] && [ "$u_r1" -eq 0 ] && dist_complete "$u_home" &&
       grep -qxF '[dev-reload] wrapper: Maven 3.9.16 is installed for ./mvnw' "$u_log" && [ -f "$WRAPPER_DIR/.install.lock" ]; then
        hc_pass "$U_ID" "empty volume: wrapper_ready false, ensure_wrapper installs once (via sh ./mvnw, no exec bit) under the lock, wrapper_ready true after"
    else
        hc_fail "$U_ID" "empty volume: ready-before=$u_r0 ensure_wrapper=$u_rc installs=$u_n ready-after=$u_r1"
    fi
    u_t=$(head -n 1 "$HC_WRAP_COUNT" 2>/dev/null) || u_t=none
    if [ "$u_t" = "$u_m/wrapper/tmp" ]; then
        hc_pass "$U_ID-TMPDIR" "mvnw unpacked into \$MAVEN_USER_HOME/wrapper/tmp - on the volume, so its final mv is an atomic rename"
    else
        hc_fail "$U_ID-TMPDIR" "mvnw ran with TMPDIR=$u_t, not $u_m/wrapper/tmp: its mv becomes a copy another container can see half-done"
    fi
    u_rc=0
    ensure_wrapper >>"$u_log" 2>&1 || u_rc=$?
    u_n=$(count_lines "$HC_WRAP_COUNT")
    if [ "$u_rc" -eq 0 ] && [ "$u_n" = 1 ]; then
        hc_pass "$U_ID-AGAIN" "a second ensure_wrapper finds it ready and installs nothing"
    else
        hc_fail "$U_ID-AGAIN" "a second ensure_wrapper returned $u_rc with $u_n installs in total"
    fi
    return 0
}
wrap_partial() {
    wrap_load
    # What an interrupted file-by-file copy leaves: bin/ and nothing else.
    seed_dist "$u_m" 3.9.16 binonly
    u_r0=$(wrap_ready_rc)
    u_rc=0
    ensure_wrapper >"$u_log" 2>&1 || u_rc=$?
    show "$u_log"
    u_n=$(count_lines "$HC_WRAP_COUNT")
    u_r1=$(wrap_ready_rc)
    if [ "$u_r0" -ne 0 ] && [ "$u_rc" -eq 0 ] && [ "$u_n" = 1 ] && [ "$u_r1" -eq 0 ] && dist_complete "$u_home" &&
       grep -q '^\[dev-reload\] wrapper: removing the incomplete Maven install at ' "$u_log"; then
        hc_pass "$U_ID" "an incomplete dist (bin/ only) is not trusted: it is removed and installed again, once"
    else
        hc_fail "$U_ID" "incomplete dist: ready-before=$u_r0 ensure_wrapper=$u_rc installs=$u_n ready-after=$u_r1 - a broken Maven stays on the volume"
    fi
    return 0
}
wrap_other() {
    wrap_load
    seed_dist "$u_m" 3.9.9 complete
    u_rc=0
    ensure_wrapper >"$u_log" 2>&1 || u_rc=$?
    show "$u_log"
    u_n=$(count_lines "$HC_WRAP_COUNT")
    if [ "$u_rc" -eq 0 ] && [ "$u_n" = 1 ] && [ "$(wrap_ready_rc)" -eq 0 ] && dist_complete "$u_m/wrapper/dists/apache-maven-3.9.9/0123abcd"; then
        hc_pass "$U_ID" "a complete Maven for ANOTHER distributionUrl does not count as ready, and is left in place"
    else
        hc_fail "$U_ID" "with 3.9.9 installed and 3.9.16 wanted: ensure_wrapper=$u_rc installs=$u_n"
    fi
    return 0
}
wrap_crlf() {
    wrap_load
    awk '{ printf "%s\r\n", $0 }' mvnw >mvnw.crlf
    mv mvnw.crlf mvnw
    u_rc=0
    ensure_wrapper >"$u_log" 2>&1 || u_rc=$?
    show "$u_log"
    u_n=$(count_lines "$HC_WRAP_COUNT")
    if [ "$u_rc" -ne 0 ] && [ "$u_n" = 0 ] && grep -qF 'CRLF' "$u_log" && grep -qF 'rm mvnw && git checkout -- mvnw' "$u_log" &&
       [ ! -d "$u_m/wrapper/dists" ]; then
        hc_pass "$U_ID" "a CRLF mvnw is refused before it runs, with the remedy: $(event_text "$u_log" wrapper)"
    else
        hc_fail "$U_ID" "a CRLF mvnw: ensure_wrapper=$u_rc installs=$u_n, remedy $(grep -qF 'git checkout -- mvnw' "$u_log" && echo given || echo missing)"
    fi
    return 0
}
# The same, with Maven already on the volume (another service installed it):
# an installed Maven does not help a mvnw that cannot run, and without this
# check the failure would surface later as dash's "set: Illegal option -".
wrap_crlf_ready() {
    wrap_load
    seed_dist "$u_m" 3.9.16 complete
    awk '{ printf "%s\r\n", $0 }' mvnw >mvnw.crlf
    mv mvnw.crlf mvnw
    u_rc=0
    ensure_wrapper >"$u_log" 2>&1 || u_rc=$?
    show "$u_log"
    if [ "$u_rc" -ne 0 ] && grep -qF 'rm mvnw && git checkout -- mvnw' "$u_log"; then
        hc_pass "$U_ID" "a CRLF mvnw is refused with the remedy even when the wrapper's Maven is already installed"
    else
        hc_fail "$U_ID" "a CRLF mvnw with Maven already installed: ensure_wrapper returned $u_rc without the remedy - run_maven would then fail inside sh ./mvnw"
    fi
    return 0
}
wrap_url_crlf() {
    wrap_load
    awk '{ printf "%s\r\n", $0 }' .mvn/wrapper/maven-wrapper.properties >p.crlf
    mv p.crlf .mvn/wrapper/maven-wrapper.properties
    u_url=$(wrapper_url)
    u_rc=0
    ensure_wrapper >"$u_log" 2>&1 || u_rc=$?
    show "$u_log"
    if [ "$u_url" = "$(wrap_url 3.9.16)" ] && [ "$u_rc" -eq 0 ] && [ "$(wrap_ready_rc)" -eq 0 ]; then
        hc_pass "$U_ID" "a CRLF maven-wrapper.properties (Windows autocrlf) still yields the clean URL, and the install is recognised"
    else
        hc_fail "$U_ID" "CRLF properties: wrapper_url='$(printf '%s' "$u_url" | od -c | head -n 2 | tr -s ' \n' ' ')' ensure_wrapper=$u_rc"
    fi
    return 0
}
wrap_concurrent() {
    wrap_load
    HC_WRAP_SLOW=2
    export HC_WRAP_SLOW
    for u_i in 1 2 3; do
        ( uh_r=0; ensure_wrapper >"$u_d/log.$u_i" 2>&1 || uh_r=$?; echo "$uh_r" >"$u_d/rc.$u_i" ) &
    done
    wait
    for u_i in 1 2 3; do printf '    [call %s]\n' "$u_i"; show "$u_d/log.$u_i"; done
    u_n=$(count_lines "$HC_WRAP_COUNT")
    u_rcs=$(cat "$u_d/rc.1" "$u_d/rc.2" "$u_d/rc.3" 2>/dev/null | tr '\n' ' ')
    u_dirs=$(ls "$u_m/wrapper/dists/apache-maven-3.9.16" | wc -l | tr -d ' ')
    if [ "$u_n" = 1 ] && [ "$u_rcs" = '0 0 0 ' ] && [ "$u_dirs" = 1 ] && [ ! -e "$u_home/apache-maven-3.9.16" ] &&
       [ "$(wrap_ready_rc)" -eq 0 ]; then
        hc_pass "$U_ID" "three concurrent ensure_wrapper calls on one volume: exactly one install, all three succeed, no nested dist"
    else
        hc_fail "$U_ID" "three concurrent ensure_wrapper calls: $u_n installs, statuses [$u_rcs], $u_dirs dist dirs, nested: $([ -e "$u_home/apache-maven-3.9.16" ] && echo yes || echo no)"
    fi
    return 0
}

# Without unzip, the real mvnw fetches the .tar.gz and records THAT url, in a
# directory still named after the .zip - which must count as installed, or
# every start would take the lock and run mvnw again.
wrap_targz() {
    wrap_load
    seed_dist "$u_m" 3.9.16 complete
    printf '%s\n' "$(wrap_url 3.9.16 | sed 's/\.zip$/.tar.gz/')" >"$u_home/mvnw.url"
    u_r=$(wrap_ready_rc)
    u_rc=0
    ensure_wrapper >"$u_log" 2>&1 || u_rc=$?
    show "$u_log"
    u_n=$(count_lines "$HC_WRAP_COUNT")
    if [ "$u_r" -eq 0 ] && [ "$u_rc" -eq 0 ] && [ "$u_n" = 0 ]; then
        hc_pass "$U_ID" "a Maven that mvnw fetched as .tar.gz (its mvnw.url says -bin.tar.gz) counts as installed for the -bin.zip distributionUrl"
    else
        hc_fail "$U_ID" ".tar.gz install: wrapper_ready=$u_r ensure_wrapper=$u_rc installs=$u_n"
    fi
    if command -v unzip >/dev/null 2>&1; then
        hc_info "$U_ID-UNZIP" "unzip is in this image, so a real mvnw downloads the -bin.zip"
    else
        hc_info "$U_ID-UNZIP" "unzip is not in this image, so a real mvnw downloads the -bin.tar.gz - the case above is the one that happens"
    fi
    return 0
}

group_wrap() {
    sub C-WRAP-FLOCK      wrap_flock
    sub C-WRAP-FRESH      wrap_fresh
    sub C-WRAP-PARTIAL    wrap_partial
    sub C-WRAP-OTHER      wrap_other
    sub C-WRAP-TARGZ      wrap_targz
    sub C-WRAP-CRLF       wrap_crlf
    sub C-WRAP-CRLF-READY wrap_crlf_ready
    sub C-WRAP-URL-CRLF   wrap_url_crlf
    sub C-WRAP-CONCURRENT wrap_concurrent
}

# ---------------------------------------------------------------------------
# C-MVN: every Maven call carries the lock settings. run_maven, stop_daemons,
# choose_compiler
# ---------------------------------------------------------------------------

# Written out here, not read from dev-reload.sh's MVN_FLAGS: a test that
# compares a variable with itself proves nothing.
MVN_REQUIRED='--batch-mode
-Dhooks.install.skip=true
-Dspotless.check.skip=true
-Dcheckstyle.skip=true
-DlastModGranularityMs=-86400000
-Daether.syncContext.named.factory=file-lock
-Daether.syncContext.named.nameMapper=file-gav
-Daether.syncContext.named.time=900
-Daether.syncContext.named.time.unit=SECONDS
-Daether.syncContext.named.retry=0'
LOCK_PROP=-Daether.named.file-lock.deleteLockFiles=false

# A fake mvnd on PATH (it shadows the image's real one) and a fake mvnw, both
# recording their arguments one per line.
mvn_load() {
    u_d=$HC_W/$U_ID
    u_p=$u_d/proj u_m=$u_d/m2
    mkdir -p "$u_d/bin" "$u_p/.mvn/wrapper"
    cat >"$u_d/bin/mvnd" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >"$HC_REC"
printf 'JDK_JAVA_OPTIONS=%s\n' "${JDK_JAVA_OPTIONS:-}" >"$HC_REC.mvnd-env"
echo x >>"$HC_REC.calls"
exit "${HC_MVND_EXIT:-0}"
EOF
    chmod +x "$u_d/bin/mvnd"
    cat >"$u_p/mvnw" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >"$HC_REC"
printf 'TMPDIR=%s\nMAVEN_OPTS=%s\n' "${TMPDIR:-}" "${MAVEN_OPTS:-}" >"$HC_REC.env"
EOF
    printf 'distributionUrl=%s\n' "$(wrap_url 3.9.16)" >"$u_p/.mvn/wrapper/maven-wrapper.properties"
    # A complete install already on the volume, so run_maven's ensure_wrapper
    # is a no-op and the call reaches ./mvnw.
    seed_dist "$u_m" 3.9.16 complete
    PATH=$u_d/bin:$PATH MAVEN_USER_HOME=$u_m HC_REC=$u_d/rec
    export PATH MAVEN_USER_HOME HC_REC
    load_dr
    cd "$u_p" || exit 1
    u_log=$HC_W/$U_ID.log
}
# mvn_flags_missing <recorded-args-file>: the required flags it lacks.
mvn_flags_missing() {
    uh_miss=""
    uh_old_ifs=$IFS
    IFS='
'
    for uh_f in $MVN_REQUIRED; do
        grep -qxF -- "$uh_f" "$1" 2>/dev/null || uh_miss="$uh_miss $uh_f"
    done
    IFS=$uh_old_ifs
    printf '%s' "$uh_miss"
}

mvn_mvnw() {
    MAVEN_OPTS=-Xmx256m DEV_MAVEN_EXTRA_ARGS='-Dx=1 -Dy=2'
    export MAVEN_OPTS DEV_MAVEN_EXTRA_ARGS
    mvn_load
    COMPILE=mvnw
    u_rc=0
    run_maven compile >"$u_log" 2>&1 || u_rc=$?
    show "$u_log"
    u_miss=$(mvn_flags_missing "$HC_REC")
    u_tail=$(tail -n 3 "$HC_REC" 2>/dev/null | tr '\n' ' ')
    if [ "$u_rc" -eq 0 ] && [ -z "$u_miss" ] && grep -qxF -- -q "$HC_REC" && [ "$u_tail" = 'compile -Dx=1 -Dy=2 ' ]; then
        hc_pass "$U_ID" "sh ./mvnw gets --batch-mode, the hook/format skips, lastModGranularityMs and all five lock flags, -q, then the goals, then DEV_MAVEN_EXTRA_ARGS last"
    else
        hc_fail "$U_ID" "sh ./mvnw: status $u_rc, missing:${u_miss:- none}, -q $(grep -qxF -- -q "$HC_REC" 2>/dev/null && echo present || echo absent), last three [$u_tail]"
    fi
    if grep -qxF "MAVEN_OPTS=-Xmx256m $LOCK_PROP" "$HC_REC.env" 2>/dev/null && grep -qxF "TMPDIR=$u_m/wrapper/tmp" "$HC_REC.env" 2>/dev/null; then
        hc_pass "$U_ID-ENV" "mvnw's JVM gets $LOCK_PROP appended to compose's MAVEN_OPTS, and TMPDIR on the volume"
    else
        hc_fail "$U_ID-ENV" "mvnw's environment: $(tr '\n' ' ' <"$HC_REC.env" 2>/dev/null)"
    fi
    return 0
}
mvn_mvnd() {
    mvn_load
    COMPILE=mvnd
    u_rc=0
    run_maven compile dependency:build-classpath -Dmdep.outputFile=/x/cp.txt -DincludeScope=runtime >"$u_log" 2>&1 || u_rc=$?
    show "$u_log"
    u_miss=$(mvn_flags_missing "$HC_REC")
    for u_f in -Dmvnd.daemonStorage=/tmp/mvnd -Dmvnd.idleTimeout=15m; do
        grep -qxF -- "$u_f" "$HC_REC" || u_miss="$u_miss $u_f"
    done
    # The heap cap has to be mvnd's own option: mvnd appends its default -Xmx
    # after the daemon's other JVM options, and the last -Xmx wins.
    u_heap=$(grep -- '^-Dmvnd.maxHeapSize=' "$HC_REC" | head -n 1) || u_heap=""
    # The lock property travels in the daemon's environment, JDK_JAVA_OPTIONS
    # (-Dmvnd.jvmArgs never got it to the daemon) - and only there: left in
    # this shell's environment, the application's java would pick it up too.
    u_env=$(sed -n 's/^JDK_JAVA_OPTIONS=//p' "$HC_REC.mvnd-env" 2>/dev/null) || u_env=""
    u_tail=$(tail -n 4 "$HC_REC" | tr '\n' ' ')
    if [ "$u_rc" -eq 0 ] && [ -z "$u_miss" ] && [ -n "$u_heap" ] &&
       case " $u_env " in *" $LOCK_PROP "*) true ;; *) false ;; esac &&
       case $u_env in *-Xmx*) false ;; *) true ;; esac &&
       [ -z "${JDK_JAVA_OPTIONS:-}" ] &&
       grep -qxF -- -q "$HC_REC" &&
       [ "$u_tail" = 'compile dependency:build-classpath -Dmdep.outputFile=/x/cp.txt -DincludeScope=runtime ' ]; then
        hc_pass "$U_ID" "mvnd gets its own daemonStorage and idleTimeout, $u_heap, $LOCK_PROP in JDK_JAVA_OPTIONS for the daemon's JVM (and not in this shell's environment, which the application inherits), and every required flag"
    else
        hc_fail "$U_ID" "mvnd: status $u_rc, missing:${u_miss:- none}, heap option '${u_heap:-none}', JDK_JAVA_OPTIONS for mvnd '$u_env', left in this shell '${JDK_JAVA_OPTIONS:-}', last four [$u_tail]"
    fi
    return 0
}
mvn_quiet() {
    DEV_MAVEN_QUIET=0
    export DEV_MAVEN_QUIET
    mvn_load
    COMPILE=mvnd
    run_maven compile >"$u_log" 2>&1 || :
    if ! grep -qxF -- -q "$HC_REC" && [ -z "$(mvn_flags_missing "$HC_REC")" ]; then
        hc_pass "$U_ID" "DEV_MAVEN_QUIET=0 drops -q and keeps every other flag"
    else
        hc_fail "$U_ID" "DEV_MAVEN_QUIET=0: -q $(grep -qxF -- -q "$HC_REC" && echo 'still there' || echo gone), missing:$(mvn_flags_missing "$HC_REC")"
    fi
    return 0
}
mvn_stop() {
    mvn_load
    COMPILE=mvnd
    stop_daemons
    u_ok=0
    if [ "$(tail -n 1 "$HC_REC" 2>/dev/null)" = --stop ] && grep -qxF -- -Dmvnd.daemonStorage=/tmp/mvnd "$HC_REC"; then u_ok=1; fi
    rm -f "$HC_REC" "$HC_REC.calls"
    COMPILE=mvnw
    stop_daemons
    if [ "$u_ok" = 1 ] && [ ! -e "$HC_REC.calls" ]; then
        hc_pass "$U_ID" "stop_daemons stops mvnd in the same daemonStorage the builds use, and does nothing with mvnw"
    else
        hc_fail "$U_ID" "stop_daemons: mvnd --stop with daemonStorage=/tmp/mvnd: $([ "$u_ok" = 1 ] && echo yes || echo no); mvnd called under mvnw: $([ -e "$HC_REC.calls" ] && echo yes || echo no)"
    fi
    return 0
}
# choose_compiler <DEV_COMPILER> <fake mvnd exit> <expected COMPILE|fatal> <what>
mvn_choose() {
    DEV_COMPILER=$1 HC_MVND_EXIT=$2
    export DEV_COMPILER HC_MVND_EXIT
    mvn_load
    u_rc=0
    choose_compiler >"$u_log" 2>&1 || u_rc=$?
    show "$u_log"
    u_calls=$(count_lines "$HC_REC.calls")
    case $3 in
      fatal)
        if [ "$u_rc" -ne 0 ] && grep -q '^\[dev-reload\] fatal: DEV_COMPILER=mvnd' "$u_log"; then hc_pass "$U_ID" "$4"
        else hc_fail "$U_ID" "$4: status $u_rc, COMPILE=$COMPILE"; fi ;;
      *)
        if [ "$u_rc" -eq 0 ] && [ "$COMPILE" = "$3" ] && grep -qxF "[dev-reload] compiler: $3" "$u_log" &&
           { [ "$1" != mvnw ] || [ "$u_calls" = 0 ]; }; then
            hc_pass "$U_ID" "$4 (mvnd probed $u_calls times)"
        else
            hc_fail "$U_ID" "$4: status $u_rc, COMPILE='$COMPILE', mvnd probed $u_calls times"
        fi ;;
    esac
    return 0
}

group_mvn() {
    sub C-MVN-MVNW            mvn_mvnw
    sub C-MVN-MVND            mvn_mvnd
    sub C-MVN-QUIET           mvn_quiet
    sub C-MVN-STOP            mvn_stop
    sub C-MVN-CHOOSE-PINNED   mvn_choose mvnw 0 mvnw  'DEV_COMPILER=mvnw uses the wrapper without probing mvnd'
    sub C-MVN-CHOOSE-AUTO     mvn_choose auto 0 mvnd  'DEV_COMPILER=auto with a working mvnd picks mvnd'
    sub C-MVN-CHOOSE-FALLBACK mvn_choose auto 1 mvnw  'DEV_COMPILER=auto with an mvnd that will not run falls back to mvnw'
    sub C-MVN-CHOOSE-STRICT   mvn_choose mvnd 1 fatal 'DEV_COMPILER=mvnd with an mvnd that will not run is fatal, not a silent fallback'
}

# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------

group_prefix() {
    case $1 in
      fp) echo C-FP ;; mc) echo C-MC ;; lc) echo C-LC ;; good) echo C-GOOD ;;
      res) echo C-RES ;; val) echo C-VAL ;; wrap) echo C-WRAP ;; mvn) echo C-MVN ;;
      *) echo "C-$1" ;;
    esac
}

# The tools dev-reload.sh itself relies on, including the GNU-only options
# that a busybox or BSD userland would reject - a missing one fails every
# container at its first poll, so it is a result of its own.
preflight() {
    uh_miss=""
    for uh_t in find cp flock javap cksum comm awk sed grep tr cut sort curl touch mkdir mv rm cat ls; do
        command -v "$uh_t" >/dev/null 2>&1 || uh_miss="$uh_miss $uh_t"
    done
    mkdir -p "$W/preflight/a/b"
    : >"$W/preflight/a/b/f"
    find "$W/preflight/a" -type f -printf '%p %s %T@\n' >/dev/null 2>&1 || uh_miss="$uh_miss find-printf(GNU)"
    mkdir -p "$W/preflight/to"
    ( cd "$W/preflight/a" && cp -a --parents -t "$W/preflight/to" ./b/f ) >/dev/null 2>&1 && [ -f "$W/preflight/to/b/f" ] ||
        uh_miss="$uh_miss cp--parents(GNU)"
    if [ -z "$uh_miss" ]; then
        hc_pass C-UNIT-TOOLS "every tool dev-reload.sh calls is present, GNU find -printf and cp --parents included"
    else
        hc_fail C-UNIT-TOOLS "missing from this image:$uh_miss"
    fi
    printf 'unit-dev-reload: %s, java %s, javac release %s\n' "$(uname -srm)" \
        "$(java -version 2>&1 | head -n 1)" "$REL"
}

run_all() {
    uh_groups=${*:-$ALL_GROUPS}
    for uh_g in $uh_groups; do
        case " $ALL_GROUPS " in
          *" $uh_g "*) ;;
          *) hc_fail C-UNIT-ARGS "unknown group '$uh_g' (known: $ALL_GROUPS)"; hc_exit ;;
        esac
    done
    W=$(mktemp -d /tmp/hc-unit.XXXXXX)
    preflight
    uh_timeout=""
    if command -v timeout >/dev/null 2>&1; then uh_timeout="timeout -k 10 ${HC_GROUP_TIMEOUT:-600}"; fi
    for uh_g in $uh_groups; do
        uh_p=$(group_prefix "$uh_g")
        mkdir -p "$W/$uh_g"
        printf '\n== %s (%s)\n' "$uh_p" "$uh_g"
        uh_rc=0
        # shellcheck disable=SC2086  # the timeout prefix is a word list
        HC_W=$W/$uh_g $uh_timeout "$HC_SH" "$SELF" --group "$uh_g" >"$W/$uh_g.out" 2>&1 || uh_rc=$?
        cat "$W/$uh_g.out"
        if grep -q "^HCRESULT$TAB[^$TAB]*${TAB}FAIL$TAB" "$W/$uh_g.out"; then HC_FAILED=1; fi
        if [ "$uh_rc" -eq 124 ] || [ "$uh_rc" -eq 137 ]; then
            hc_fail "$uh_p-TIMEOUT" "the $uh_g group did not finish within ${HC_GROUP_TIMEOUT:-600}s and was killed; its remaining cases never ran"
        elif [ ! -f "$W/$uh_g/.complete" ]; then
            hc_fail "$uh_p-INCOMPLETE" "the $uh_g group exited with status $uh_rc before its last case"
        fi
    done
    if [ "${HC_KEEP:-0}" = 1 ]; then printf 'work directory kept: %s\n' "$W"; else rm -rf "$W"; fi
    hc_done unit-dev-reload.sh
    hc_exit
}

case ${1:-} in
  --group)
    # One group, in this separate process (see run_all). HC_W is its work dir.
    "group_$2"
    : >"$HC_W/.complete"
    exit 0 ;;
  -h | --help)
    sed -n '2,/^$/p' "$0"
    exit 0 ;;
  *)
    run_all "$@" ;;
esac
