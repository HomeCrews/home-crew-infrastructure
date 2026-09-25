#!/bin/sh
# Runs INSIDE every service container locally. Started by ./dev up via the
# entrypoint in compose.dev.yml, never by hand.
#
# Watches the bind-mounted checkout and reacts at the cheapest level that will
# actually pick the change up:
#
#   src/main/**   (java, resources, anything)  ->  compile
#                 DevTools sees target/classes change and restarts the context
#                 in-process. This is the common case: roughly 3-5s with mvnd,
#                 8-15s without, because a cold `mvn` spends most of its time
#                 booting a JVM rather than compiling.
#
#   pom.xml, .mvn/**                           ->  compile + restart the app
#                 A dependency change cannot be hot-reloaded: spring-boot:run
#                 fixed its classpath when it launched, so the process has to go.
#                 30-60s, because Maven re-resolves and the JVM starts cold.
#
# src/test is deliberately not watched. A test edit should not bounce the
# running service.
#
# POLLING, NOT INOTIFY, ON PURPOSE. Docker Desktop's bind mounts on macOS and
# Windows do not propagate inotify events from the host, so inotifywait and
# anything built on Java's WatchService see nothing at all - they do not error,
# they just never fire, which is the worst way for a watcher to fail. `find
# -newer` against a stamp file works everywhere. Spring Boot DevTools polls for
# the same reason, which is why the in-process half works at all.

set -eu

APP=/app
SRC_STAMP=/tmp/dev-reload-src
BUILD_STAMP=/tmp/dev-reload-build
INTERVAL=${DEV_RELOAD_INTERVAL:-2}

APP_PID=""
APP_STARTED=0

# Automatic restarts after the application exits on its own - see the top of
# the loop. MAX_RESTARTS attempts, backing off from RESTART_DELAY seconds and
# doubling; a run that stays up for STABLE_SECS earns a fresh budget.
MAX_RESTARTS=5
RESTART_DELAY=5
STABLE_SECS=120
RESTARTS=0
RESTART_AT=0

cd "$APP"

# The wrapper comes from a bind mount, so its mode is whatever the host has.
chmod +x mvnw 2>/dev/null || true

log() {
    printf '[dev-reload] %s\n' "$1"
}

# The shared pom-plugins.xml runs `git config core.hooksPath .githooks` at the
# validate phase, on the stated assumption that "git necessarily is on PATH if
# you are building from a clone". True on a laptop, false in this container -
# and the plugin's tolerance of exit 128 does not save it, because git is not
# found at all, so exec-maven-plugin throws rather than returning a code:
#
#     Cannot run program "git" (in directory "/app"): No such file or directory
#
# Skipped rather than made to work: those hooks belong to the HOST's clone, and
# .git is on the bind mount, so a container installing them would be reaching
# out and reconfiguring your repository behind your back. Dockerfile.dev also
# installs git, so nothing else that expects it breaks.
#
# Spotless and Checkstyle are skipped for a different reason, and only here.
#
# Both bind to the VALIDATE phase, which runs before compile - and
# spring-boot:run forks its own lifecycle through test-compile, so it runs them
# too. That puts the full formatting gate in front of every single save, and a
# save is the wrong moment to ask "is this fit to commit". Code mid-thought is
# routinely mid-format; three characters of trailing whitespace should not fail
# the build at validate and leave the service not reloading until you go and run
# `./mvnw spotless:apply` by hand.
#
# Spotless and the editor now share one formatter profile
# (config/eclipse-formatter.xml), so they no longer disagree the way they did
# when the build ran google-java-format and the editor ran Eclipse JDT. That
# makes this skip less load-bearing than it was - but not pointless: the two
# still resolve their own JDT builds, and an unfinished edit can be unformatted
# for entirely ordinary reasons.
#
# Skipping them costs nothing, because the container is not what keeps the
# repository formatted. Three other things already do, and all three run on the
# HOST where spotless:apply is actually available to fix what they find:
#
#   pre-commit  .githooks/checks/formatting.sh  ->  spotless:check
#   pre-push    .githooks/checks/build.sh       ->  clean verify
#   CI          .github/workflows/ci.yml        ->  clean verify
#
# So unformatted code still cannot be committed, pushed or merged. It just no
# longer takes your running service down while you are in the middle of writing
# it. The inner loop answers "does this compile", and the gates answer "is this
# fit to commit" - which is a question worth asking once per commit, not once
# per keystroke.
MVN_FLAGS="-Dhooks.install.skip=true -Dspotless.check.skip=true -Dcheckstyle.skip=true"

# mvnd flags, explained once because two of them are load-bearing:
#
#   daemonStorage  defaults to ~/.m2/mvnd, and ~/.m2 is bind-mounted and SHARED
#                  by all twelve containers. They would see each other's daemons
#                  in one registry and try to connect to sockets that do not
#                  exist in their own namespace. /tmp is per-container.
#   idleTimeout    so that the ten services you are not editing let their daemon
#                  go instead of each holding a JVM for the default three hours.
#   jvmArgs        the daemon is a THIRD persistent JVM in a 1g container,
#                  alongside the Maven that launched the app and the app itself.
MVND_FLAGS="-Dmvnd.daemonStorage=/tmp/mvnd -Dmvnd.idleTimeout=15m -Dmvnd.jvmArgs=-Xmx320m"

# Probe rather than trust the image: the mvnd install in Dockerfile.dev is
# deliberately non-fatal, so it may simply not be here. A slower loop is a far
# better outcome than a loop that does not work.
COMPILE="./mvnw"
if command -v mvnd >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    if mvnd $MVND_FLAGS --version >/dev/null 2>&1; then
        COMPILE="mvnd"
    else
        log "mvnd is installed but would not run; falling back to ./mvnw"
    fi
fi

# spring-boot:run always uses the wrapper, never mvnd. mvnd is built for build
# goals that finish; parking a process that runs until you stop the container on
# one of its daemons is not what it is for.
run_compile() {
    if [ "$COMPILE" = mvnd ]; then
        # shellcheck disable=SC2086
        mvnd $MVND_FLAGS $MVN_FLAGS --batch-mode -q compile
    else
        ./mvnw $MVN_FLAGS --batch-mode -q compile
    fi
}

start_app() {
    # set -- rather than interpolating into the command line: a jvmArgument
    # containing a space would otherwise split into two broken arguments.
    # Positional parameters are local to a function, so this clobbers nothing.
    set --
    [ -n "${DEV_JVM_ARGS:-}" ] && set -- "-Dspring-boot.run.jvmArguments=$DEV_JVM_ARGS"

    # shellcheck disable=SC2086
    ./mvnw $MVN_FLAGS --batch-mode spring-boot:run "$@" &
    APP_PID=$!
    APP_STARTED=$(date +%s)
    log "application started (pid $APP_PID)"
}

# A start you asked for by saving. Whatever the automatic restarts had used up
# belonged to the previous failure, not to this build.
start_app_fresh() {
    RESTARTS=0
    RESTART_AT=0
    start_app
}

stop_app() {
    [ -n "$APP_PID" ] || return 0

    kill -TERM "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true

    # spring-boot:run FORKS the application into its own JVM - forking is not
    # optional here, the plugin turns it on by itself once devtools is on the
    # classpath - and relies on a shutdown hook to take the child with it. If
    # that hook loses the race, the old JVM keeps holding the port and the
    # replacement dies on bind, which looks like a broken port mapping rather
    # than a failed restart. Make sure it is gone.
    pkill -f "$APP/target/classes" 2>/dev/null || true

    APP_PID=""
}

shutdown() {
    trap - TERM INT
    log "stopping"
    stop_app
    exit 0
}

trap shutdown TERM INT

src_changed() {
    find src/main -type f -newer "$SRC_STAMP" -print -quit 2>/dev/null
}

build_changed() {
    find pom.xml .mvn -type f -newer "$BUILD_STAMP" -print -quit 2>/dev/null
}

# Stamped before the first compile, so anything you save while the container is
# still warming up is picked up by the first pass of the loop rather than being
# marked as already seen.
touch "$SRC_STAMP" "$BUILD_STAMP"

log "compiling with: $COMPILE"
log "resolving dependencies and compiling once - the first run is the slow one"

# Guarded exactly like the two calls in the loop below, and for the same reason.
# A bare `run_compile` here would be the only unguarded one in the script: under
# `set -e` a failed first compile kills the script, the container exits
# non-zero, and compose restarts it straight back into the same failure. A
# watcher that restart-loops on a broken checkout is useless at exactly the
# moment you need it, because the thing that would pick up your fix is the thing
# that is not running.
#
# So do not start the application - but do not give up either. Fall through to
# the loop: its src_changed branch calls start_app whenever a compile succeeds
# and nothing is running, so the first save that builds brings the service up.
if run_compile; then
    start_app
else
    log "THE FIRST COMPILE FAILED - fix the code and save; this will retry" >&2
fi

while :; do
    sleep "$INTERVAL"

    # The application can die on its own: a context that fails to refresh, an
    # OOM, a port clash - or config-server being down for longer than this
    # service's config import will wait. compose sets fail-fast, and the client
    # retries for roughly 75s (spring.cloud.config.retry.* in each service, made
    # live by spring-retry in its pom) before giving up and exiting. Keep the
    # CONTAINER up when any of it happens.
    #
    # And restart the application, backing off, a bounded number of times.
    # Waiting for a save left every service whose start overlapped a long
    # config-server restart down until you went and touched it, for a cause
    # that was gone as soon as config-server was back. A failure that outlasts
    # every attempt is a real one, and waits for a fix-and-save as before.
    if [ -n "$APP_PID" ] && ! kill -0 "$APP_PID" 2>/dev/null; then
        wait "$APP_PID" 2>/dev/null || true
        APP_PID=""
        now=$(date +%s)

        # Up this long means it was healthy: a new failure with a fresh budget,
        # not the next attempt at an old one.
        if [ $((now - APP_STARTED)) -ge "$STABLE_SECS" ]; then
            RESTARTS=0
        fi

        if [ "$RESTARTS" -lt "$MAX_RESTARTS" ]; then
            delay=$((RESTART_DELAY << RESTARTS))
            RESTARTS=$((RESTARTS + 1))
            RESTART_AT=$((now + delay))
            log "the application exited - restarting in ${delay}s (attempt $RESTARTS of $MAX_RESTARTS)" >&2
        else
            log "the application exited again after $MAX_RESTARTS restarts - save a file to build and start it again" >&2
        fi
    fi

    if [ -n "$(build_changed)" ]; then
        # Both stamps: a pom change is followed by a full restart, which picks
        # up whatever is in src/main anyway. Leaving SRC_STAMP behind would
        # recompile again on the next tick for nothing.
        touch "$BUILD_STAMP" "$SRC_STAMP"
        log "pom.xml or .mvn changed - restarting the application"

        # Compile first. A pom that does not resolve must leave the running
        # application alone rather than killing it and failing to come back.
        if run_compile; then
            stop_app
            start_app_fresh
        else
            log "BUILD FILE BROKEN - still serving the previous build" >&2
        fi
        continue
    fi

    if [ -n "$(src_changed)" ]; then
        # Stamped BEFORE compiling, not after. If a save lands while javac is
        # running, stamping afterwards would mark that edit as already seen and
        # you would sit looking at a stale application wondering why.
        touch "$SRC_STAMP"
        log "source or resources changed - recompiling"

        # A compile failure must not take the application down. target/classes
        # is left holding the last set that did compile, DevTools sees no
        # change, and the running context is untouched - so a typo costs you an
        # error message, not an outage.
        if run_compile; then
            if [ -n "$APP_PID" ]; then
                log "recompiled - DevTools will restart the context"
            else
                start_app_fresh
            fi
        else
            log "COMPILE FAILED - still serving the last good build" >&2
        fi
    fi

    # Checked last, so a save in the same tick starts the new build instead of
    # the old one being started and then immediately replaced. It starts
    # whatever target/classes holds, which a failed compile leaves alone - see
    # COMPILE FAILED above - so a broken edit cannot be what this launches.
    if [ -z "$APP_PID" ] && [ "$RESTART_AT" -gt 0 ] && [ "$(date +%s)" -ge "$RESTART_AT" ]; then
        RESTART_AT=0
        start_app
    fi
done
