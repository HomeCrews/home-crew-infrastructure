#!/bin/sh
# Runs INSIDE every Java service container locally. Started by ./dev up via the
# entrypoint in compose.dev.yml, never by hand. Two more entry points exist, for
# test/ only:
#
#     sh /dev-reload.sh --build-only           one full build and the main-class
#                                             check, then exit 0 or 1
#     DEV_RELOAD_LIB_ONLY=1 . /dev-reload.sh   define the functions and return
#
# Watches the bind-mounted checkout and reacts at the cheapest level that will
# actually pick the change up:
#
#   src/main/**   (java, resources, anything)  ->  compile
#                 then touch the DevTools trigger file, which restarts the
#                 context in-process: same JVM, same pid, and an attached
#                 debugger stays attached.
#
#   pom.xml, .mvn/**, lombok.config            ->  full build + a NEW JVM
#                 A dependency change cannot be hot-reloaded: a JVM's classpath
#                 is fixed when it launches, so the process has to go.
#
# src/test is deliberately not watched. A test edit should not bounce the
# running service.
#
# THE APPLICATION IS LAUNCHED WITH java, NOT mvnw spring-boot:run. The plugin
# kept a whole Maven JVM parked beside every application for its lifetime,
# forked the lifecycle through test-compile on every start - so a half-written
# test stopped the service from starting at all - and made the application a
# grandchild that only pkill could reach. What spring-boot:run 4.1.1 actually
# forks is reproduced here, in its order (RunMojo/AbstractRunMojo):
#
#     java -XX:TieredStopAtLevel=1 <jvmArguments> -cp /app/target/classes:<deps> <main>
#
# with the project directory as the working directory, the environment
# inherited unchanged, and stderr merged into stdout. test/ compares the two
# launches of all twelve services property by property.
#
# LOG MARKERS ARE A CONTRACT WITH test/. Every line this script writes is
#
#     [dev-reload] <event>: <detail>
#
# on stdout. The detail is prose and may change; the event names do not:
#
#   compiler wrapper watching source-changed build-changed build-pending
#   compile-start compile-ok compile-failed build-start build-ok build-failed
#   build-broken build-retry-scheduled classes-restored classpath-written
#   classpath-error classpath-warning main-class main-class-error
#   main-class-changed reload-skipped resource-removed trigger-touched
#   trigger-error reload-deferred reload-failed app-ready boot-timeout app-started
#   app-stopped app-exited app-killed restart-scheduled restart-exhausted
#   restart-deferred launch-refused stopping build-only fatal
#
# POLLING, NOT INOTIFY, ON PURPOSE. Docker Desktop's bind mounts on macOS and
# Windows do not propagate inotify events from the host, so inotifywait and
# anything built on Java's WatchService see nothing at all - they do not error,
# they just never fire, which is the worst way for a watcher to fail. Spring
# Boot DevTools polls for the same reason, which is why the in-process half
# works at all.
#
# FINGERPRINTS, NOT STAMPS. This used to be `find -newer <stamp>`, which
# compares two clocks: the host's, which stamps your edit, and the Docker VM's,
# which stamped the stamp. The VM drifts - WSL2 notoriously, after the laptop
# sleeps - and ahead of the host a save looked OLD and was never compiled.
# Deleting a file has no mtime at all, so that was never noticed either. Each
# poll now hashes the sorted "path size mtime" list of the watched tree and
# compares it only with the previous hash: created, modified, deleted, renamed,
# even an mtime moving backwards - any difference is a change.

set -eu

APP=${DEV_APP_DIR:-/app}                  # overridable for test/ only
CLASSES=$APP/target/classes
STATUS=$APP/target/maven-status
CP_FILE=$APP/target/dev-classpath.txt
STATE=$APP/target/.dev-reload             # in the target volume: survives restarts
GOOD=$STATE/good

# The file DevTools restarts on, and nothing else. Without one, DevTools
# restarts on any change it sees in target/classes, and it cannot tell a
# finished compile from one still writing: resources are copied first, class
# files land when javac is done, and a gap longer than its quiet period meant a
# restart on half-new classes. With spring.devtools.restart.trigger-file set,
# it ignores all of that until this file changes, and this script touches it
# only after a compile that succeeded. The name comes from the variable compose
# sets for the application, so the two cannot disagree about it.
TRIGGER_NAME=${SPRING_DEVTOOLS_RESTART_TRIGGER_FILE:-.reloadtrigger}
TRIGGER=$CLASSES/$TRIGGER_NAME

WRAPPER_DIR=${MAVEN_USER_HOME:-${HOME:-/root}/.m2}/wrapper
JAVA_CMD=${DEV_JAVA:-${JAVA_HOME:+$JAVA_HOME/bin/}java}   # DEV_JAVA: test/ only
SBA=org.springframework.boot.autoconfigure.SpringBootApplication
SBA_DESC='Lorg/springframework/boot/autoconfigure/SpringBootApplication;'

INTERVAL=${DEV_RELOAD_INTERVAL:-2}
STOP_TIMEOUT=${DEV_STOP_TIMEOUT:-35}      # below compose's stop_grace_period (45s)
BOOT_TIMEOUT=${DEV_BOOT_TIMEOUT:-300}
READY_APPEAR=${DEV_READY_APPEAR:-15}      # test/ only
RELOAD_FAIL_SECS=${DEV_RELOAD_FAIL_SECS:-35}   # test/ only
RESTART_DELAY=${DEV_RESTART_DELAY:-5}     # test/ only
RETRY_DELAY=${DEV_BUILD_RETRY_DELAY:-30}  # test/ only

# Automatic restarts after the application exits on its own - see check_app.
# MAX_RESTARTS attempts, backing off from RESTART_DELAY seconds and doubling;
# a run that stays up for STABLE_SECS earns a fresh budget.
MAX_RESTARTS=5
STABLE_SECS=120
MAX_RETRIES=3

APP_PID=""  APP_STARTED=0  RESTARTS=0  RESTART_AT=0  CHILD_PID=""  COMPILE=""
DEPS=""  MAIN_CLASS=""  MAIN_SEEN=""  MAIN_OK=0  RUNNING_MAIN=""  RUNNING_CP=""
JVM_STALE=0  SRC_FP=""  BUILD_FP=""  BUILD_ONLY=0
BUILD_PENDING=1   # no classpath has been written by this container yet
CLASSES_OK=0      # target/classes holds a SUCCESSFUL compile
READY=1  READY_SINCE=0  READY_SAW_DOWN=1  READY_DEFER_LOGGED=0
READY_KIND=launch  RELOAD_FAILED=0  READY_IDLE_SINCE=""  MAIN_SUM=""
RETRY_AT=0  RETRIES=0  RETRY_KIND=""

# The shared pom-plugins.xml runs `git config core.hooksPath .githooks` at the
# validate phase. Skipped rather than made to work: those hooks belong to the
# HOST's clone, and .git is on the bind mount, so a container installing them
# would be reaching out and reconfiguring your repository behind your back.
#
# Spotless and Checkstyle are skipped for a different reason, and only here.
# Both bind to the VALIDATE phase, which `compile` runs first, and that puts the
# full formatting gate in front of every single save. A save is the wrong
# moment to ask "is this fit to commit": code mid-thought is routinely
# mid-format, and three characters of trailing whitespace should not leave the
# service not reloading until you go and run `./mvnw spotless:apply` by hand.
# Skipping them costs nothing, because the container is not what keeps the
# repository formatted. Three other things already do, all on the HOST where
# spotless:apply is actually available to fix what they find:
#
#   pre-commit  .githooks/checks/formatting.sh  ->  spotless:check
#   pre-push    .githooks/checks/build.sh       ->  clean verify
#   CI          .github/workflows/ci.yml        ->  clean verify
MVN_FLAGS="--batch-mode -Dhooks.install.skip=true -Dspotless.check.skip=true -Dcheckstyle.skip=true"

# Clock skew, compiler side. The fingerprints above make sure a change is
# NOTICED; javac still decides for itself which sources are stale, by comparing
# each source's mtime - the host's clock - with its class file's - the VM's. A
# VM running ahead makes a fresh edit look older than its class, and javac
# reports "Nothing to compile" while DevTools restarts onto the old code. So
# every compile is a full module rebuild - seconds, for modules this size - by
# two means: before each build the compiler's record of its previous inputs is
# deleted (see force_full_compile), which it treats as "everything changed",
# and a granularity of minus one day covers what that misses.
MVN_FLAGS="$MVN_FLAGS -DlastModGranularityMs=-86400000"

# /root/.m2 is ONE named volume shared by twelve containers. Maven 3.9's default
# resolver lock (rwlock-local) only coordinates threads inside one JVM, so twelve
# cold builds wrote the same artifacts, metadata and tracking files at once.
# file-lock + file-gav lock across processes instead, with lock files under
# /root/.m2/repository/.locks - which works because the volume is one ext4
# filesystem inside one kernel, the Docker VM's, not a bind mount.
#
#   time=900  a lock is held for a whole resolution batch, so a container queued
#             behind a cold download of the entire Spring Boot tree has to be
#             allowed to wait that long. 900s is resolver 1.9's own default;
#             mvnd's may differ, so it is pinned.
#   retry=0   in resolver 1.9 a retry never rescues a failed attempt - the
#             failure is recorded and thrown after the loop regardless - so it
#             would only double the wait before the same error.
MVN_FLAGS="$MVN_FLAGS -Daether.syncContext.named.factory=file-lock -Daether.syncContext.named.nameMapper=file-gav -Daether.syncContext.named.time=900 -Daether.syncContext.named.time.unit=SECONDS -Daether.syncContext.named.retry=0"

# And the one setting without which the above excludes nothing. file-lock opens
# each lock file with DELETE_ON_CLOSE, and on Linux the JDK implements that by
# unlinking the file the moment it is opened: the next process creates a NEW
# file with the same name, locks that inode, and the two never meet. It is read
# ONCE, from System properties, when the lock class loads, so it has to be on
# the JVM's own command line - MAVEN_OPTS for the wrapper, JDK_JAVA_OPTIONS for
# the mvnd daemon (see mvnd_cmd) - not a -D to an already-running Maven.
LOCK_JVM_PROP="-Daether.named.file-lock.deleteLockFiles=false"

log() { printf '[dev-reload] %s: %s\n' "$1" "$2"; }
now() { cut -d. -f1 /proc/uptime; }       # monotonic, unlike date +%s

is_uint() { case ${1:-} in ''|*[!0-9]*) return 1 ;; esac; }

# Settings are checked before anything expensive happens. The container is
# restarted by compose whenever this exits, so a typo must fail fast and say
# so - not spin up a 320m daemon first, or, like a bad sleep interval used to,
# turn the loop into a busy wait that re-walks the bind mount nonstop.
validate_settings() {
    if ! awk -v v="$INTERVAL" 'BEGIN { exit !(v ~ /^[0-9]+(\.[0-9]+)?$/ && v + 0 > 0) }'; then
        log fatal "DEV_RELOAD_INTERVAL must be a number of seconds above zero, not '$INTERVAL'"; return 1
    fi
    for _kv in "DEV_STOP_TIMEOUT=$STOP_TIMEOUT" "DEV_BOOT_TIMEOUT=$BOOT_TIMEOUT" \
               "DEV_READY_APPEAR=$READY_APPEAR" "DEV_RESTART_DELAY=$RESTART_DELAY" \
               "DEV_BUILD_RETRY_DELAY=$RETRY_DELAY" "DEV_RELOAD_FAIL_SECS=$RELOAD_FAIL_SECS"; do
        is_uint "${_kv#*=}" || { log fatal "${_kv%%=*} must be whole seconds, not '${_kv#*=}'"; return 1; }
    done
    # Zero would replace the JVM on every tick; above 40 the application's own
    # shutdown runs into compose's 45s stop_grace_period and docker's SIGKILL.
    if [ "$BOOT_TIMEOUT" -eq 0 ] || [ "$RELOAD_FAIL_SECS" -eq 0 ]; then
        log fatal "DEV_BOOT_TIMEOUT and DEV_RELOAD_FAIL_SECS must be above zero"; return 1
    fi
    if [ "$STOP_TIMEOUT" -gt 40 ]; then
        log fatal "DEV_STOP_TIMEOUT must be 40 or less (compose gives the container 45s to stop), not $STOP_TIMEOUT"; return 1
    fi
    if [ -n "${DEV_APP_PORT:-}" ] && ! is_uint "$DEV_APP_PORT"; then
        log fatal "DEV_APP_PORT must be a port number, not '$DEV_APP_PORT'"; return 1
    fi
    case ${DEV_COMPILER:-auto} in auto|mvnd|mvnw) ;; *)
        log fatal "DEV_COMPILER must be auto, mvnd or mvnw, not '$DEV_COMPILER'"; return 1 ;; esac
    case ${DEV_OPTIMIZED_LAUNCH:-true} in true|false) ;; *)
        log fatal "DEV_OPTIMIZED_LAUNCH must be true or false, not '$DEV_OPTIMIZED_LAUNCH'"; return 1 ;; esac
    # Both are split on whitespace, exactly as the plugin's jvmArguments were
    # for input without quotes - and quotes are the one thing that splitting
    # cannot honour, so they are refused rather than silently mangled.
    case "${DEV_JVM_ARGS:-}${DEV_MAVEN_EXTRA_ARGS:-}" in *\"*|*\'*)
        log fatal "DEV_JVM_ARGS and DEV_MAVEN_EXTRA_ARGS are split on whitespace and cannot contain quotes"; return 1 ;; esac
}

# In the background and waited for, because dash runs a trap only after a
# FOREGROUND command ends: `docker compose stop` in the middle of a compile or
# a sleep used to wait it out, and then compose's grace period ran out.
run_waited() {
    "$@" &
    CHILD_PID=$!
    _rw=0
    wait "$CHILD_PID" || _rw=$?
    CHILD_PID=""
    return "$_rw"
}

# ---------------------------------------------------------------------------
# Change detection
# ---------------------------------------------------------------------------

# Editor droppings are pruned so that a swap file appearing and vanishing does
# not cost a compile: vim (.x.swp, 4913), emacs (.#x, x~), JetBrains
# (x___jb_tmp___) and the files Finder and Explorer leave behind.
fingerprint() {
    find "$@" \( -name '.*.sw?' -o -name '*~' -o -name '.#*' -o -name '*___jb_???___' \
                 -o -name 4913 -o -name .DS_Store -o -name Thumbs.db -o -name desktop.ini \) -prune \
        -o -type f -printf '%p %s %T@\n' 2>/dev/null | LC_ALL=C sort | cksum
}
src_fingerprint()   { fingerprint src/main; }
# lombok.config changes generated code without touching a source, so it is a
# build input like the pom.
build_fingerprint() { fingerprint pom.xml .mvn lombok.config; }

# A poll can land in the middle of a write: an IDE "save all", a git checkout
# over a slow Windows share. Compiling half a change fails - or worse succeeds,
# restarts, and then restarts again for the other half. So act only once two
# looks a second apart agree, and give up waiting after ten.
settle() {
    _n=0
    while [ "$_n" -lt 10 ]; do
        run_waited sleep 1 || :
        _b2=$(build_fingerprint); _s2=$(src_fingerprint)
        if [ "$_b2" = "$_b" ] && [ "$_s2" = "$_s" ]; then return 0; fi
        _b=$_b2; _s=$_s2; _n=$((_n + 1))
    done
}

# ---------------------------------------------------------------------------
# Maven: the daemon, the wrapper, and the locks both of them must honour
# ---------------------------------------------------------------------------

# mvnd flags:
#
#   daemonStorage  defaults to ~/.m2/mvnd, and ~/.m2 is SHARED by all twelve
#                  containers. They would see each other's daemons in one
#                  registry and try to connect to sockets that do not exist in
#                  their own namespace. /tmp is per-container.
#   idleTimeout    so that the services you are not editing let their daemon go
#                  instead of each holding a JVM for the default three hours.
#   maxHeapSize    the daemon is the second persistent JVM in a 1g container,
#                  so it is capped. Through this option, not an -Xmx among its
#                  JVM options: mvnd appends its own -Xmx (2g by default) after
#                  them, and the last one wins.
#
# The lock property goes to the daemon in JDK_JAVA_OPTIONS, which the java
# launcher reads, and which the daemon - started by this client - inherits.
# -Dmvnd.jvmArgs did not get it there - most likely because every service has
# a .mvn/jvm.config, which mvnd uses for the daemon's JVM options in its place
# - and no lock file outlived an mvnd build (the harness's first Windows run:
# D-SCAN-mvnd-LOCKS, D-COLD-mvnd). Only this command gets it, never the
# application's java.
mvnd_cmd() {
    JDK_JAVA_OPTIONS="${JDK_JAVA_OPTIONS:+$JDK_JAVA_OPTIONS }$LOCK_JVM_PROP" \
        mvnd -Dmvnd.daemonStorage=/tmp/mvnd -Dmvnd.idleTimeout=15m -Dmvnd.maxHeapSize=320m "$@"
}

# Every Maven invocation this script makes goes through here, so the lock
# settings cannot be forgotten on one path. `sh ./mvnw` rather than ./mvnw: a
# Windows checkout does not reliably carry the exec bit, and chmod-ing it from
# in here would write to your checkout.
run_maven() {
    _q=-q
    [ "${DEV_MAVEN_QUIET:-1}" = 1 ] || _q=""
    if [ "$COMPILE" = mvnd ]; then
        # shellcheck disable=SC2086  # flag lists, split on purpose
        mvnd_cmd $MVN_FLAGS $_q "$@" ${DEV_MAVEN_EXTRA_ARGS:-}
    else
        ensure_wrapper || return 1
        # shellcheck disable=SC2086
        TMPDIR=$WRAPPER_DIR/tmp MAVEN_OPTS="${MAVEN_OPTS:-} $LOCK_JVM_PROP" \
            sh ./mvnw $MVN_FLAGS $_q "$@" ${DEV_MAVEN_EXTRA_ARGS:-}
    fi
}

# mvnd keeps each project's resolved dependencies cached inside the daemon, and
# the cache key does not see every pom edit - an <exclusion>, or a managed
# version that only moves a transitive dependency, leaves it unchanged. After a
# build-file change the daemon goes, so the classpath is resolved afresh.
stop_daemons() {
    [ "$COMPILE" = mvnd ] || return 0
    mvnd_cmd --stop >/dev/null 2>&1 || :
}

# THE WRAPPER'S OWN INSTALL IS NOT COVERED BY ANY RESOLVER LOCK - it happens
# before there is a Maven to take one. mvnw checks only that $MAVEN_HOME exists,
# unpacks into `mktemp -d` and `mv`s the result into ~/.m2/wrapper/dists. With
# /tmp on the container's own filesystem that mv is a file-by-file copy, so a
# second container could find the directory already there, half-full, and run
# it; one killed mid-copy left a broken Maven on the volume for good. So the
# install happens once, under flock (the kernel drops the lock if its holder
# dies), unpacked into a directory ON THE VOLUME so the final mv is an atomic
# rename, after clearing out anything incomplete a previous attempt left.
wrapper_url() {
    sed -n 's/^distributionUrl=//p' .mvn/wrapper/maven-wrapper.properties 2>/dev/null | tr -d '\r[:space:]'
}
dist_complete() {
    [ -f "$1/bin/mvn" ] && ls "$1"/lib/maven-core-*.jar >/dev/null 2>&1 && ls "$1"/boot/plexus-classworlds-*.jar >/dev/null 2>&1
}
wrapper_ready() {
    _url=$(wrapper_url)
    [ -n "$_url" ] || return 1
    for _f in "$WRAPPER_DIR"/dists/*/*/mvnw.url; do
        [ -f "$_f" ] || continue
        # Without unzip in the image, mvnw fetches the .tar.gz instead, and
        # records THAT url - under a directory still named after the .zip one.
        case $(tr -d '\r\n' <"$_f") in
            "$_url"|"${_url%.zip}.tar.gz") dist_complete "${_f%/mvnw.url}" && return 0 ;;
        esac
    done
    return 1
}
install_wrapper() {
    find "$WRAPPER_DIR/tmp" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || :
    for _d in "$WRAPPER_DIR"/dists/*/*; do
        [ -d "$_d" ] || continue
        dist_complete "$_d" || { log wrapper "removing the incomplete Maven install at $_d"; rm -rf "$_d"; }
    done
    # mvnw prints its progress to stdout, and only with MVNW_VERBOSE=true - which
    # test/ sets to count downloads - is that worth keeping in the log.
    if [ "${MVNW_VERBOSE:-}" = true ]; then
        TMPDIR=$WRAPPER_DIR/tmp sh ./mvnw --version
    else
        TMPDIR=$WRAPPER_DIR/tmp sh ./mvnw --version >/dev/null
    fi
}
ensure_wrapper() {
    # First, whether or not Maven is installed yet: an installed Maven does not
    # help a mvnw that cannot run.
    if grep -q "$(printf '\r')" mvnw 2>/dev/null; then
        log wrapper "mvnw has Windows (CRLF) line endings and cannot run. On the host: rm mvnw && git checkout -- mvnw"
        return 1
    fi
    wrapper_ready && return 0
    mkdir -p "$WRAPPER_DIR/tmp"
    # Checked again once the lock is held: whoever held it before may just
    # have installed exactly this.
    if ( flock -w 600 9 || exit 1; wrapper_ready || install_wrapper ) 9>"$WRAPPER_DIR/.install.lock"; then
        log wrapper "Maven $(wrapper_url | sed 's|.*/apache-maven-\([^/]*\)-bin.zip|\1|') is installed for ./mvnw"
        return 0
    fi
    log wrapper "could not install the wrapper's Maven - see the output above"
    return 1
}

# Probe rather than trust the image: the mvnd install in Dockerfile.dev is
# deliberately non-fatal, so it may simply not be here. A slower loop is a far
# better outcome than a loop that does not work. DEV_COMPILER pins the choice
# so that test/ can exercise both paths.
choose_compiler() {
    case ${DEV_COMPILER:-auto} in
      mvnw) COMPILE=mvnw ;;
      *)
        if command -v mvnd >/dev/null 2>&1 && run_waited mvnd_cmd --version >/dev/null 2>&1; then
            COMPILE=mvnd
        elif [ "${DEV_COMPILER:-auto}" = mvnd ]; then
            log fatal "DEV_COMPILER=mvnd, but mvnd is missing or will not run"; return 1
        else
            log compiler "mvnd is missing or would not run - falling back to sh ./mvnw, which is slower"
            COMPILE=mvnw
        fi ;;
    esac
    log compiler "$COMPILE"
}

# ---------------------------------------------------------------------------
# Building
# ---------------------------------------------------------------------------

# The resources plugin copies but never deletes, so a resource you delete or
# rename would otherwise stay on the classpath until the volume is emptied.
# Remember every resource path a build has seen; after one succeeds, drop the
# copies whose source has gone. src/main/resources maps one-to-one onto
# target/classes (spring-boot-starter-parent declares no targetPath).
list_resources() {
    if [ -d src/main/resources ]; then find src/main/resources -type f -printf '%P\n' | LC_ALL=C sort; fi
}
note_resources() {
    list_resources >"$STATE/resources.now"
    touch "$STATE/resources.known"
    LC_ALL=C sort -u "$STATE/resources.known" "$STATE/resources.now" -o "$STATE/resources.known"
}
prune_resources() {
    LC_ALL=C comm -23 "$STATE/resources.known" "$STATE/resources.now" | while IFS= read -r _rel; do
        if [ -f "$CLASSES/$_rel" ]; then rm -f "$CLASSES/$_rel"; log resource-removed "$_rel"; fi
    done
    cp "$STATE/resources.now" "$STATE/resources.known"
}

# A FAILED COMPILE DELETES THE LAST GOOD ONE. Before rebuilding, the compiler
# removes every class file its previous run created (maven-shared-incremental),
# and a javac that then fails puts nothing back - so the application, still
# running, would find any class it has not loaded yet missing: an exception
# handler, a lazy bean. Hence a copy of the last successful compile, restored
# over whatever a failed one leaves behind, together with the compiler's own
# record of what it created so that the next good build still cleans up after
# deleted sources. The trigger file is never copied either way: restoring an
# old mtime onto it would be a change, and DevTools would restart.
snapshot_good() {
    rm -rf "$GOOD.new"
    mkdir -p "$GOOD.new/classes"
    ( cd "$CLASSES" && find . -type f ! -path "./$TRIGGER_NAME" -exec cp -a --parents -t "$GOOD.new/classes" {} + )
    if [ -d "$STATUS" ]; then cp -a "$STATUS" "$GOOD.new/maven-status"; fi
    rm -rf "$GOOD"
    mv "$GOOD.new" "$GOOD"
}
restore_good() {
    [ -d "$GOOD/classes" ] || return 1
    mkdir -p "$CLASSES"
    ( cd "$GOOD/classes" && find . -type f -exec cp -a --parents -t "$CLASSES" {} + )
    ( cd "$CLASSES" && find . -type f ! -path "./$TRIGGER_NAME" | LC_ALL=C sort ) >"$STATE/classes.now"
    ( cd "$GOOD/classes" && find . -type f | LC_ALL=C sort ) >"$STATE/classes.good"
    LC_ALL=C comm -23 "$STATE/classes.now" "$STATE/classes.good" | while IFS= read -r _f; do rm -f "$CLASSES/$_f"; done
    rm -rf "$STATUS"
    if [ -d "$GOOD/maven-status" ]; then cp -a "$GOOD/maven-status" "$STATUS"; fi
    log classes-restored "target/classes is back to the last successful compile"
}

# Pruned BEFORE the snapshot: a resource deleted by this build must not be in
# the copy that a later failed compile restores.
build_ok()     { CLASSES_OK=1; prune_resources; snapshot_good; }
build_failed() { if restore_good; then CLASSES_OK=1; else CLASSES_OK=0; fi; }

force_full_compile() {
    rm -f "$STATUS/maven-compiler-plugin/compile/default-compile/inputFiles.lst"
}

# spring-boot:run keeps provided and system scope on the classpath; the
# runtime scope used below drops them. None of the twelve has either - this
# says so loudly the day one does, instead of starting without it.
check_scopes() {
    if grep -Eq '<scope>[[:space:]]*(provided|system)[[:space:]]*</scope>' pom.xml 2>/dev/null; then
        log classpath-warning "pom.xml has provided- or system-scope dependencies, which spring-boot:run would put on the classpath and this launch does not"
    fi
}

# $1 = initial | build | pending | retry. The classpath file is deleted first,
# so a failed build can never leave a stale one behind for a later start.
full_build() {
    rm -f "$CP_FILE"
    note_resources
    log build-start "$1 ($COMPILE: compile + dependency:build-classpath)"
    _t0=$(now); _rc=0
    force_full_compile
    run_waited run_maven compile dependency:build-classpath \
        "-Dmdep.outputFile=$CP_FILE" -DincludeScope=runtime || _rc=$?
    if [ "$_rc" -eq 0 ] && [ -s "$CP_FILE" ]; then
        log build-ok "$(( $(now) - _t0 ))s"
        log classpath-written "$(tr ':' '\n' <"$CP_FILE" | grep -c .) entries in $CP_FILE"
        check_scopes
        BUILD_PENDING=0
        build_ok
        return 0
    fi
    BUILD_PENDING=1
    [ "$_rc" -ne 0 ] || _rc="0, but no classpath was written"
    if [ -n "$APP_PID" ]; then log build-failed "exit $_rc - still serving the previous build"
    else log build-failed "exit $_rc - nothing is running; fix it and save"; fi
    build_failed
    return 1
}

# A compile failure must not take the application down: the trigger is touched
# only on success, and the classes are put back (see snapshot_good), so a typo
# costs you an error message, not an outage.
compile_only() {
    note_resources
    log compile-start "$1 ($COMPILE: compile)"
    _t0=$(now); _rc=0
    force_full_compile
    run_waited run_maven compile || _rc=$?
    if [ "$_rc" -eq 0 ]; then
        log compile-ok "$(( $(now) - _t0 ))s"
        build_ok
        return 0
    fi
    if [ -n "$APP_PID" ]; then log compile-failed "exit $_rc - still serving the last good build"
    else log compile-failed "exit $_rc - nothing is running; fix it and save"; fi
    build_failed
    return 1
}

# ---------------------------------------------------------------------------
# The main class, the way spring-boot:run finds it
# ---------------------------------------------------------------------------

# Boot's MainClassFinder reads COMPILED classes, never source: dot-directories
# skipped, candidates directly annotated @SpringBootApplication, with a static
# main. Two deliberate differences. It falls back to "any class with a main"
# when none is annotated, which is how the wrong class gets started; this
# refuses instead, and says what it found. And it accepts Java 25's
# argument-less main(), which DevTools cannot restart - RestartLauncher looks
# up main(String[]) and nothing else - so the first save would kill the
# service; that is refused up front too.
class_file() { printf '%s/%s.class' "$CLASSES" "$(printf %s "$1" | tr . /)"; }
annotated_candidates() {
    if [ -d "$CLASSES" ]; then
        find "$CLASSES" -mindepth 1 -type d -name '.*' -prune -o -type f -name '*.class' \
            -exec grep -lF "$SBA_DESC" {} + 2>/dev/null |
            sed -e "s|^$CLASSES/||" -e 's|\.class$||' -e 's|/|.|g' | LC_ALL=C sort
    fi
}
# The descriptor also turns up in method signatures and local-variable tables,
# so a grep hit is only a candidate: javap decides, from the class-level
# annotations and the method table (private members are not listed).
has_main() {
    javap -v "$1" 2>/dev/null | grep -Eq '^  ([a-z]+ )*static ([a-z]+ )*void main\(java\.lang\.String(\[\]|\.\.\.)\)( throws [^;]*)?;$'
}
is_boot_main() {
    javap -v "$1" 2>/dev/null | awk -v sba="$SBA" '
        /^  ([a-z]+ )*static ([a-z]+ )*void main\(java\.lang\.String(\[\]|\.\.\.)\)( throws [^;]*)?;$/ { m = 1 }
        /^RuntimeVisibleAnnotations:$/ { a = 1; next }
        a && index($0, "    " sba) == 1 && (length($0) == length(sba) + 4 || substr($0, length(sba) + 5, 1) == "(") { s = 1 }
        a && /^[^ ]/ { a = 0 }
        END { exit !(m && s) }'
}
resolve_main() {
    MAIN_OK=0
    if [ -n "${DEV_MAIN_CLASS:-}" ]; then
        _f=$(class_file "$DEV_MAIN_CLASS")
        if [ ! -f "$_f" ]; then
            log main-class-error "DEV_MAIN_CLASS=$DEV_MAIN_CLASS, but $_f does not exist. It takes a binary name (a.b.Outer\$Inner) - and did it compile?"
            return 1
        fi
        if ! has_main "$_f"; then
            log main-class-error "DEV_MAIN_CLASS=$DEV_MAIN_CLASS declares no public static void main(String[]), which DevTools needs to restart it"
            return 1
        fi
        MAIN_CLASS=$DEV_MAIN_CLASS
        MAIN_SEEN=""
    else
        _cands=$(annotated_candidates)
        _mains=""; _n=0
        for _c in $_cands; do
            if is_boot_main "$(class_file "$_c")"; then _mains="${_mains:+$_mains, }$_c"; _n=$((_n + 1)); fi
        done
        case $_n in
          1) MAIN_CLASS=$_mains ;;
          0) log main-class-error "Unable to find a suitable main class: no class in target/classes is annotated @SpringBootApplication AND declares public static void main(String[]) (classes mentioning the annotation: $(printf '%s' "${_cands:-none}" | tr '\n' ' ')). Fix it, or set DEV_MAIN_CLASS."
             return 1 ;;
          *) log main-class-error "Unable to find a single main class from the following candidates [$_mains]. Keep one, or set DEV_MAIN_CLASS."
             return 1 ;;
        esac
        MAIN_SEEN=$_cands
    fi
    MAIN_OK=1
    MAIN_SUM=$(cksum <"$(class_file "$MAIN_CLASS")")
    log main-class "$MAIN_CLASS"
}
# Cheap on the common path - one find and grep; javap only when something moved.
main_still_valid() {
    [ "$MAIN_OK" -eq 1 ] && [ -n "$RUNNING_MAIN" ] && [ -f "$(class_file "$RUNNING_MAIN")" ] || return 1
    # A changed main class is checked again: DevTools re-invokes
    # main(String[]), and a signature edit would make that throw.
    [ "$(cksum <"$(class_file "$RUNNING_MAIN")")" = "$MAIN_SUM" ] || return 1
    [ -n "${DEV_MAIN_CLASS:-}" ] && return 0
    [ "$(annotated_candidates)" = "$MAIN_SEEN" ]
}

# ---------------------------------------------------------------------------
# The application
# ---------------------------------------------------------------------------

read_classpath() {
    if [ ! -s "$CP_FILE" ]; then
        log classpath-error "$CP_FILE is missing or empty - a full build has to succeed first"; return 1
    fi
    DEPS=$(cat "$CP_FILE")
    # An empty entry would put the working directory on the classpath.
    case ":$DEPS:" in *::*)
        log classpath-error "$CP_FILE has an empty entry"; return 1 ;; esac
    _gone=$(printf '%s\n' "$DEPS" | tr ':' '\n' | while IFS= read -r _e; do
        [ -e "$_e" ] || { printf '%s' "$_e"; break; }; done)
    if [ -n "$_gone" ]; then
        log classpath-error "$_gone is on the classpath but not in the Maven volume"; return 1
    fi
}

# Runs "$1" with the application's full command line as its arguments:
# launch_app runs it, test/ prints it. -f around the unquoted expansion: the
# debug agent's address=*:5005 must reach the JVM, not the glob.
with_app_argv() {
    _fn=$1
    set -f
    set -- "$JAVA_CMD"
    [ "${DEV_OPTIMIZED_LAUNCH:-true}" = false ] || set -- "$@" -XX:TieredStopAtLevel=1
    # shellcheck disable=SC2086  # a flag list, split on whitespace like jvmArguments
    set -- "$@" ${DEV_JVM_ARGS:-} -cp "$CLASSES:$DEPS" "$MAIN_CLASS"
    set +f
    "$_fn" "$@"
}
print_argv() { printf '%s\n' "$@"; }
spawn()      { "$@" 2>&1 & APP_PID=$!; }
app_argv()   { with_app_argv print_argv; }   # for test/

prepare_launch() {
    read_classpath || { BUILD_PENDING=1; return 1; }
    resolve_main
}
launch_app() {
    with_app_argv spawn
    APP_STARTED=$(now)
    RUNNING_MAIN=$MAIN_CLASS
    RUNNING_CP=$(cksum <"$CP_FILE")
    JVM_STALE=0
    ready_reset launch
    log app-started "pid $APP_PID $MAIN_CLASS"
}
start_app() {
    if prepare_launch; then launch_app; return 0; fi
    log launch-refused "not starting - see above"
    return 1
}
# A start you asked for by saving. Whatever the automatic restarts had used up
# belonged to the previous failure, not to this build.
start_app_fresh() { RESTARTS=0; RESTART_AT=0; start_app; }

# Replace a running JVM only once its replacement is known to be launchable: a
# classpath that reads, a main class that resolves. Otherwise the old one keeps
# serving - on its old classpath, which is remembered, so that the next source
# change asks for a new JVM instead of a DevTools restart onto the wrong jars.
restart_app() {
    if ! prepare_launch; then
        if [ -n "$APP_PID" ]; then
            JVM_STALE=1
            log launch-refused "the new build cannot be launched - still serving the previous one"
        else
            log launch-refused "not starting - see above"
        fi
        return 1
    fi
    stop_app
    RESTARTS=0; RESTART_AT=0
    launch_app
}
relaunch() { if [ -n "$APP_PID" ]; then restart_app; else start_app_fresh; fi; }

# kill -0 also succeeds for a child that has exited but not been reaped.
app_alive() {
    kill -0 "$1" 2>/dev/null || return 1
    _st=$(sed -n 's/^[0-9]* (.*) \([A-Za-z]\) .*/\1/p' "/proc/$1/stat" 2>/dev/null) || _st=""
    [ "$_st" != Z ]
}
# The application is this shell's own child now, so SIGTERM reaches the JVM
# itself - there is no forked grandchild left holding the port, and no pkill.
# One that does not go - a debugger parked on a breakpoint during shutdown - is
# killed after STOP_TIMEOUT, so a stuck JVM cannot hold the ports forever.
stop_app() {
    [ -n "$APP_PID" ] || return 0
    _pid=$APP_PID
    kill -TERM "$_pid" 2>/dev/null || :
    _w=0
    while app_alive "$_pid" && [ "$_w" -lt "$STOP_TIMEOUT" ]; do sleep 1; _w=$((_w + 1)); done
    if app_alive "$_pid"; then
        log app-killed "pid $_pid ignored SIGTERM for ${STOP_TIMEOUT}s - sending SIGKILL"
        kill -KILL "$_pid" 2>/dev/null || :
    fi
    _rc=0
    wait "$_pid" 2>/dev/null || _rc=$?
    log app-stopped "pid $_pid, status $_rc"
    APP_PID=""; RUNNING_MAIN=""; READY=1
}

# ---------------------------------------------------------------------------
# Readiness: when a reload may safely happen
# ---------------------------------------------------------------------------

# A SAVE WHILE THE APPLICATION IS STARTING WAS LOST. DevTools' watcher takes its
# first snapshot of the trigger file only late in startup, so a compile that
# finished before then touched a trigger nobody was watching yet - while having
# swapped the class files out from under a context that was still loading
# them. The same goes for a second save during a DevTools restart. So source
# changes wait until the application answers HTTP on its own port - any
# response at all, a 401 included, means the web server is up and the context
# with it - and after a trigger, until it has visibly gone down and come back,
# or has kept answering for READY_APPEAR seconds. Build-file changes do not
# wait: they replace the JVM anyway.
ready_reset() {
    READY_KIND=$1; RELOAD_FAILED=0; READY_IDLE_SINCE=""
    if [ -z "${DEV_APP_PORT:-}" ]; then READY=1; return 0; fi
    READY=0; READY_SINCE=$(now); READY_DEFER_LOGGED=0
    if [ "$1" = launch ]; then READY_SAW_DOWN=1; else READY_SAW_DOWN=0; fi
}
# The liveness path, not /actuator/health: health runs every indicator -
# config-server's does a git fetch on its first call - and a slow answer would
# count as "down". Liveness runs none, and where probes are not enabled the
# 404 is just as good: any HTTP response means the web server is up.
app_answers() {
    _code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://127.0.0.1:$DEV_APP_PORT/actuator/health/liveness" 2>/dev/null) || :
    [ -n "$_code" ] && [ "$_code" != 000 ]
}
# DevTools runs the application's main method on a thread it names
# restartedMain, at first boot and on every restart, and that thread ends when
# main returns. So while the port does not answer, this tells a restart still
# in progress from one that has FAILED: after a failed restart DevTools keeps
# the JVM alive with no application in it, waiting for the next change, and
# the thread is gone.
restart_running() { grep -qsx restartedMain /proc/"$APP_PID"/task/*/comm; }
# A context that never comes back - a DevTools restart that failed leaves the
# JVM alive with nothing in it, and kill -0 cannot see that - gets a new JVM
# after BOOT_TIMEOUT, out of the same budget as a crash.
check_ready() {
    { [ "$READY" -eq 0 ] && [ -n "$APP_PID" ]; } || return 0
    _age=$(( $(now) - READY_SINCE ))
    # A restart seen in progress counts as seen going down, so a restart
    # quicker than one poll does not have to wait out READY_APPEAR.
    if [ "$READY_KIND" = trigger ] && restart_running; then READY_SAW_DOWN=1; READY_IDLE_SINCE=""; fi
    if app_answers; then
        if [ "$READY_SAW_DOWN" -eq 1 ] || [ "$_age" -ge "$READY_APPEAR" ]; then
            READY=1
            log app-ready "pid $APP_PID answers on $DEV_APP_PORT after ${_age}s"
            return 0
        fi
    else
        READY_SAW_DOWN=1
        # Down, and no restart running, for RELOAD_FAIL_SECS - longer than a
        # slow shutdown, when the thread is not there either: the restart
        # failed. Your next save is what DevTools is waiting for, so from now
        # on source changes are compiled instead of deferred.
        if [ "$READY_KIND" = trigger ] && [ "$RELOAD_FAILED" -eq 0 ] && ! restart_running; then
            if [ -z "$READY_IDLE_SINCE" ]; then
                READY_IDLE_SINCE=$(now)
            elif [ $(( $(now) - READY_IDLE_SINCE )) -ge "$RELOAD_FAIL_SECS" ]; then
                RELOAD_FAILED=1
                log reload-failed "the restarted context did not come up and DevTools is waiting for the next change - fix it and save"
            fi
        fi
    fi
    [ "$_age" -ge "$BOOT_TIMEOUT" ] || return 0
    READY=1
    if [ "$RESTARTS" -lt "$MAX_RESTARTS" ]; then
        RESTARTS=$((RESTARTS + 1))
        log boot-timeout "pid $APP_PID has not answered on $DEV_APP_PORT for ${_age}s - replacing the JVM (attempt $RESTARTS of $MAX_RESTARTS)"
        _keep=$RESTARTS
        restart_app || :
        RESTARTS=$_keep
    else
        log boot-timeout "pid $APP_PID has not answered on $DEV_APP_PORT for ${_age}s, and the restart budget is spent - save a file to build and start it again"
        # That save must start a new JVM: a JVM that never finished booting has
        # no DevTools watcher to notice a trigger.
        JVM_STALE=1
    fi
}

# ---------------------------------------------------------------------------
# Reacting
# ---------------------------------------------------------------------------

reload_after_compile() {
    if ! main_still_valid; then
        if ! resolve_main; then
            log reload-skipped "the main class did not resolve - still serving the last good build"
            return 0
        fi
        if [ "$MAIN_CLASS" != "$RUNNING_MAIN" ]; then
            # DevTools re-runs the main class it was launched with, which has gone.
            log main-class-changed "$RUNNING_MAIN -> $MAIN_CLASS: a new JVM, not a context restart"
            restart_app || :
            return 0
        fi
    fi
    # After the compile has finished, never during it: this is the one change
    # DevTools acts on.
    if ! touch "$TRIGGER"; then
        log trigger-error "could not touch $TRIGGER"
        return 0
    fi
    ready_reset trigger
    log trigger-touched "DevTools will restart the context"
}
after_compile() {
    if [ -z "$APP_PID" ]; then
        start_app_fresh || :
    elif [ "$JVM_STALE" -eq 1 ] || [ "$(cksum <"$CP_FILE")" != "$RUNNING_CP" ]; then
        restart_app || :
    else
        reload_after_compile
    fi
}

# The application can die on its own: a context that fails to refresh, an OOM,
# a port clash - or config-server being down for longer than this service's
# config import will wait. compose sets fail-fast, and the client retries for
# roughly 75s (spring.cloud.config.retry.* in each service, made live by
# spring-retry in its pom) before giving up and exiting. Keep the CONTAINER up
# when any of it happens - and restart the application, backing off, a bounded
# number of times. A failure that outlasts every attempt is a real one, and
# waits for a fix-and-save.
check_app() {
    [ -n "$APP_PID" ] || return 0
    if app_alive "$APP_PID"; then
        # Serving for STABLE_SECS earns back the budget that boot timeouts spent.
        if [ "$RESTARTS" -gt 0 ] && [ "$READY" -eq 1 ] && [ $(( $(now) - APP_STARTED )) -ge "$STABLE_SECS" ]; then RESTARTS=0; fi
        return 0
    fi
    _pid=$APP_PID; _rc=0
    wait "$_pid" 2>/dev/null || _rc=$?
    APP_PID=""; RUNNING_MAIN=""; READY=1
    log app-exited "pid $_pid, status $_rc"
    _now=$(now)
    # Up this long means it was healthy: a new failure with a fresh budget, not
    # the next attempt at an old one.
    if [ $((_now - APP_STARTED)) -ge "$STABLE_SECS" ]; then RESTARTS=0; fi
    if [ "$RESTARTS" -lt "$MAX_RESTARTS" ]; then
        _d=$((RESTART_DELAY << RESTARTS)); RESTARTS=$((RESTARTS + 1)); RESTART_AT=$((_now + _d))
        log restart-scheduled "in ${_d}s (attempt $RESTARTS of $MAX_RESTARTS)"
    else
        log restart-exhausted "exited again after $MAX_RESTARTS restarts - save a file to build and start it again"
    fi
}
# Checked last in each tick, so a save in the same tick starts the new build
# instead of the old one being started and then immediately replaced. Never
# onto a failed compile with nothing to fall back to.
restart_if_due() {
    { [ -z "$APP_PID" ] && [ "$RESTART_AT" -gt 0 ] && [ "$(now)" -ge "$RESTART_AT" ]; } || return 0
    RESTART_AT=0
    if [ "$CLASSES_OK" -ne 1 ]; then
        log restart-deferred "the last build failed and there is no good one to fall back to - the next save that builds starts it"
        return 0
    fi
    if [ "$BUILD_PENDING" -eq 1 ]; then
        if full_build retry; then clear_retry; else schedule_retry full; return 0; fi
    fi
    start_app || :
}

# A build that fails for a reason that goes away on its own - a network blip on
# a cold start, a lock wait that ran out, an mvnd daemon the OOM killer took -
# used to leave the service down until somebody saved a file in it. Retried a
# bounded number of times, backing off; a genuine compile error just fails
# again. Any new change starts over.
schedule_retry() {
    _max=$MAX_RETRIES
    [ "$1" = full ] || _max=1
    if [ "$RETRIES" -lt "$_max" ]; then
        _d=$((RETRY_DELAY << RETRIES)); RETRIES=$((RETRIES + 1))
        RETRY_AT=$(( $(now) + _d )); RETRY_KIND=$1
        log build-retry-scheduled "$1 build again in ${_d}s, in case the failure was transient (attempt $RETRIES of $_max)"
    fi
}
clear_retry() { RETRY_AT=0; RETRIES=0; RETRY_KIND=""; }
retry_if_due() {
    { [ "$RETRY_AT" -gt 0 ] && [ "$(now)" -ge "$RETRY_AT" ]; } || return 0
    { [ -z "$APP_PID" ] || [ "$READY" -eq 1 ] || [ "$RELOAD_FAILED" -eq 1 ]; } || return 0
    RETRY_AT=0
    if [ "$RETRY_KIND" = full ] || [ "$BUILD_PENDING" -eq 1 ]; then
        if full_build retry; then clear_retry; after_compile; else schedule_retry full; fi
    else
        if compile_only retry; then clear_retry; after_compile; else schedule_retry compile; fi
    fi
}

on_signal() {
    trap - TERM INT
    log stopping "signal received"
    # The background job is a subshell running a function, and the Maven client
    # it started is ITS child - signal that too, or it runs on until the
    # container is torn down.
    if [ -n "$CHILD_PID" ]; then
        pkill -TERM -P "$CHILD_PID" 2>/dev/null || :
        kill -TERM "$CHILD_PID" 2>/dev/null || :
    fi
    stop_app
    if [ "$BUILD_ONLY" -eq 1 ]; then exit 143; fi
    exit 0
}

# ---------------------------------------------------------------------------

main() {
    case ${1:-} in
      --build-only) BUILD_ONLY=1 ;;
      '') ;;
      *) log fatal "unknown argument '$1'"; exit 2 ;;
    esac

    validate_settings || exit 1
    cd "$APP"
    mkdir -p "$STATE"
    trap on_signal TERM INT
    choose_compiler || exit 1

    # Installed up front even when mvnd does the building, so that a ./mvnw
    # run by hand in here later finds it and does not race anyone for it.
    # In the background and waited for, like every long step: it can queue on
    # the lock behind eleven other containers, and SIGTERM must not wait.
    if ! run_waited ensure_wrapper && [ "$COMPILE" = mvnw ]; then
        # Waiting beats exiting: compose would restart this straight back into
        # the same failure, over and over.
        log wrapper "retrying every ${RETRY_DELAY}s"
        until run_waited ensure_wrapper; do run_waited sleep "$RETRY_DELAY" || :; done
    fi

    if [ "$BUILD_ONLY" -eq 1 ]; then
        if full_build initial && prepare_launch; then log build-only ok; exit 0; fi
        log build-only failed; exit 1
    fi

    # Taken BEFORE the first compile, so anything you save while the container
    # is still warming up is picked up by the first pass of the loop rather
    # than being marked as already seen.
    SRC_FP=$(src_fingerprint); BUILD_FP=$(build_fingerprint)

    # A failed first build does not exit either - a watcher that restart-loops
    # on a broken checkout is useless at exactly the moment you need it. It
    # falls through to the loop, whose next change or retry starts the service.
    if full_build initial; then start_app_fresh || :; else schedule_retry full; fi
    log watching "src/main, pom.xml, .mvn and lombok.config every ${INTERVAL}s"

    while :; do
        run_waited sleep "$INTERVAL" || :
        check_app
        check_ready

        # Both BEFORE compiling: if a save lands while javac is running, taking
        # them afterwards would mark that edit as already seen.
        _b=$(build_fingerprint); _s=$(src_fingerprint)
        if [ "$_b" != "$BUILD_FP" ] || [ "$_s" != "$SRC_FP" ]; then settle; fi

        if [ "$_b" != "$BUILD_FP" ]; then
            # Both: a new JVM picks up src/main anyway.
            BUILD_FP=$_b; SRC_FP=$_s; clear_retry
            log build-changed "pom.xml, .mvn or lombok.config changed - full build, then a new JVM"
            stop_daemons
            # Built first. A pom that does not resolve must leave the running
            # application alone rather than kill it and fail to come back.
            if full_build build; then
                relaunch || :
            else
                if [ -n "$APP_PID" ]; then log build-broken "still serving the previous build"
                else log build-broken "nothing is running - fix it and save"; fi
                schedule_retry full
            fi
        elif [ "$_s" != "$SRC_FP" ]; then
            if [ -n "$APP_PID" ] && [ "$READY" -eq 0 ] && [ "$RELOAD_FAILED" -eq 0 ]; then
                # NOT recorded as seen: it is picked up on the first tick after
                # the application is ready.
                if [ "$READY_DEFER_LOGGED" -eq 0 ]; then
                    log reload-deferred "src/main changed while the application is still starting - waiting for it"
                    READY_DEFER_LOGGED=1
                fi
            else
                SRC_FP=$_s; clear_retry
                if [ "$BUILD_PENDING" -eq 1 ]; then
                    log build-pending "the last full build failed, so this change gets a full build and a new JVM"
                    # after_compile, not relaunch: the classpath may well
                    # be the one already running, and a trigger then keeps
                    # the JVM - and your debugger session.
                    if full_build pending; then after_compile; else schedule_retry full; fi
                else
                    log source-changed "src/main changed - recompiling"
                    if compile_only source; then after_compile; else schedule_retry compile; fi
                fi
            fi
        fi

        retry_if_due
        restart_if_due
    done
}

if [ "${DEV_RELOAD_LIB_ONLY:-0}" = 1 ]; then return 0 2>/dev/null || exit 0; fi

# Last, and alone on its line: dash reads a script as it runs it, so a host
# `git pull` that rewrites this file during the first, minutes-long build would
# otherwise be read half old and half new. Everything above is only
# definitions; nothing runs until the whole file has been read.
main "$@"
