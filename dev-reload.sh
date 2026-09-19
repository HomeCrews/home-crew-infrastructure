#!/bin/sh
# Runs INSIDE every service container locally. Started by ./dev up via the
# entrypoint in compose.dev.yml, never by hand.
#
# Watches the bind-mounted checkout and reacts at the cheapest level that will
# actually pick the change up:
#
#   src/main/**   (java, resources, anything)  ->  mvn compile
#                 DevTools sees target/classes change and restarts the context
#                 in-process. ~2-5s. This is the common case.
#
#   pom.xml, .mvn/**                           ->  mvn compile + restart the app
#                 A dependency change cannot be hot-reloaded: spring-boot:run
#                 fixed its classpath when it launched, so the process has to go.
#                 ~20-40s, because Maven re-resolves.
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

cd "$APP"

# The wrapper comes from a bind mount, so its mode is whatever the host has.
chmod +x mvnw 2>/dev/null || true

log() {
    printf '[dev-reload] %s\n' "$1"
}

start_app() {
    # set -- rather than interpolating into the command line: a jvmArgument
    # containing a space would otherwise split into two broken arguments.
    # Positional parameters are local to a function, so this clobbers nothing.
    set --
    [ -n "${DEV_JVM_ARGS:-}" ] && set -- "-Dspring-boot.run.jvmArguments=$DEV_JVM_ARGS"

    ./mvnw --batch-mode spring-boot:run "$@" &
    APP_PID=$!
    log "application started (pid $APP_PID)"
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

log "resolving dependencies and compiling once - the first run is the slow one"
./mvnw --batch-mode -q compile

start_app

while :; do
    sleep "$INTERVAL"

    # The application can die on its own: a context that fails to refresh, an
    # OOM, a port clash. Keep the CONTAINER up when that happens, so that a
    # fix-and-save brings it back instead of needing a docker restart.
    if [ -n "$APP_PID" ] && ! kill -0 "$APP_PID" 2>/dev/null; then
        wait "$APP_PID" 2>/dev/null || true
        APP_PID=""
        log "the application exited - save a file to build and start it again" >&2
    fi

    if [ -n "$(build_changed)" ]; then
        # Both stamps: a pom change is followed by a full restart, which picks
        # up whatever is in src/main anyway. Leaving SRC_STAMP behind would
        # recompile again on the next tick for nothing.
        touch "$BUILD_STAMP" "$SRC_STAMP"
        log "pom.xml or .mvn changed - restarting the application"

        # Compile first. A pom that does not resolve must leave the running
        # application alone rather than killing it and failing to come back.
        if ./mvnw --batch-mode -q compile; then
            stop_app
            start_app
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
        if ./mvnw --batch-mode -q compile; then
            if [ -n "$APP_PID" ]; then
                log "recompiled - DevTools will restart the context"
            else
                start_app
            fi
        else
            log "COMPILE FAILED - still serving the last good build" >&2
        fi
    fi
done
