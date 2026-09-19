#!/bin/sh
# Runs INSIDE every service container locally. Started by ./dev up via the
# entrypoint in compose.dev.yml, never by hand. Two jobs, in one container, so
# that a code change on your machine turns into a restarted application without
# rebuilding an image:
#
#   1. poll the bind-mounted sources and recompile when a .java file changes
#   2. run the application, so DevTools restarts the context when
#      target/classes changes underneath it
#
# POLLING, NOT INOTIFY, ON PURPOSE. Docker Desktop's bind mounts on macOS and
# Windows do not propagate inotify events from the host into the container, so
# inotifywait and anything built on Java's WatchService see nothing at all -
# they do not error, they just never fire, which is the worst way for a watcher
# to fail. `find -newer` against a stamp file costs one stat per source file
# every couple of seconds and works on every platform.
#
# Spring Boot DevTools polls for the same reason, which is why the second half
# of this works at all.

set -eu

APP=/app
STAMP=/tmp/dev-reload-stamp
INTERVAL=${DEV_RELOAD_INTERVAL:-2}

cd "$APP"

# The wrapper comes from a bind mount, so its mode is whatever the host has.
chmod +x mvnw 2>/dev/null || true

log() {
    printf '[dev-reload] %s\n' "$1"
}

# The stamp lives in /tmp, not in target/. target/ is on the bind mount, and a
# file written there by this container shows up in `git status` on the host.
touch "$STAMP"

log "resolving dependencies and compiling once - the first run is the slow one"
./mvnw --batch-mode -q compile

compile_loop() {
    while :; do
        sleep "$INTERVAL"

        # -print -quit: stop at the first hit. There is no reason to walk the
        # whole tree once we know something changed.
        changed=$(find src/main -name '*.java' -newer "$STAMP" -print -quit 2>/dev/null || true)
        [ -n "$changed" ] || continue

        # Stamped BEFORE compiling, not after. If a save lands while javac is
        # running, stamping afterwards would mark that edit as already seen and
        # you would sit looking at a stale application wondering why.
        touch "$STAMP"
        log "change detected, recompiling"

        # A compile failure must not take the application down. target/classes
        # is left holding the last set that did compile, DevTools sees no
        # change, and the running context is untouched - so a typo costs you an
        # error message, not a restart.
        if ./mvnw --batch-mode -q compile; then
            log "recompiled - DevTools will restart the context"
        else
            log "COMPILE FAILED - still serving the last good build" >&2
        fi
    done
}

compile_loop &

log "starting the application"

# fork is left at its default (true). DevTools wants the application in its own
# JVM, and that is also what keeps DEV_JVM_ARGS - the debug agent - off the
# Maven JVM and off the compile loop, which would otherwise fight over port
# 5005 every two seconds.
if [ -n "${DEV_JVM_ARGS:-}" ]; then
    exec ./mvnw --batch-mode spring-boot:run \
        -Dspring-boot.run.jvmArguments="$DEV_JVM_ARGS"
fi

exec ./mvnw --batch-mode spring-boot:run
