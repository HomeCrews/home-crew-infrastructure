#!/bin/sh
# Runs INSIDE the webapp container locally. Started by ./dev up via the
# entrypoint in compose.dev.yml, never by hand.
#
# The Java services need a hand-rolled compile loop because a JVM will not pick
# up new classes on its own. Angular's dev server already does the whole job -
# watch, rebuild, push to the browser - so this only has to install
# dependencies and start it.

set -eu

log() {
    printf '[webapp-dev] %s\n' "$1"
}

cd /app

# node_modules lives in a named volume mounted over /app/node_modules, so it is
# empty on a fresh volume and survives restarts after that. Whether it is
# CURRENT is a different question: a pull that changes package-lock.json used
# to leave the old tree in place until someone remembered to install by hand.
# So the install is keyed on the two files that define it, and repeated
# whenever either differs from what was installed last time.
#
# npm ci, not npm install. install may rewrite package-lock.json - and /app is
# your checkout, so the container would be editing your lockfile behind your
# back. ci installs exactly what the lockfile says and never writes it; if the
# lockfile and package.json disagree it stops and says so, which is the
# correct outcome (fix it on the host with npm install, and commit the result).
STAMP=node_modules/.homecrew-lock.cksum
want=$(cat package.json package-lock.json 2>/dev/null | cksum)
have=$(cat "$STAMP" 2>/dev/null || :)

if [ "$want" != "$have" ]; then
    if [ -z "$have" ]; then
        log "installing dependencies with npm ci (slow, once per volume)"
    else
        log "package.json or package-lock.json changed since the last install; reinstalling with npm ci"
    fi
    if ! npm ci --no-audit --no-fund; then
        log "npm ci failed. If it says package.json and package-lock.json are out of sync,"
        log "run npm install on the host and commit the lockfile; this retries by itself"
        log "as soon as either file changes."
        # Waiting, not exiting: compose would restart the container straight
        # back into the same failure, over and over, re-downloading each time.
        trap 'exit 0' TERM INT
        while [ "$(cat package.json package-lock.json 2>/dev/null | cksum)" = "$want" ]; do
            sleep 5
        done
        exec /bin/sh /webapp-dev.sh
    fi
    printf '%s\n' "$want" >"$STAMP"
else
    log "node_modules matches package-lock.json; skipping install"
fi

# --poll, for the same reason dev-reload.sh polls: Docker Desktop's bind mounts
# on macOS and Windows do not propagate inotify events from the host, so the
# dev server's default watcher would never fire and nothing would rebuild.
#
# --port 80, not 4200, so that the dev server sits on the same container port as
# the nginx image it stands in for: docker-compose.yml maps host 4200 to
# container 80, and compose.dev.yml keeps that mapping (bound to 127.0.0.1).
#
# --host 0.0.0.0 because the default binds loopback inside the container, which
# nothing outside it can reach.
log "starting the Angular dev server on container port 80"
exec npx ng serve \
    --host 0.0.0.0 \
    --port 80 \
    --poll "${WEBAPP_POLL_INTERVAL:-2000}"
