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
# empty on a fresh volume and survives restarts after that. Checking for the
# directory is not enough - the mount makes it exist immediately.
if [ -z "$(ls -A node_modules 2>/dev/null)" ]; then
    log "node_modules is empty; installing (slow, once per volume)"
    npm install --no-audit --no-fund
else
    log "node_modules present; skipping install"
    log "run 'docker compose exec webapp npm install' after changing package.json"
fi

# --poll, for the same reason dev-reload.sh polls: Docker Desktop's bind mounts
# on macOS and Windows do not propagate inotify events from the host, so the
# dev server's default watcher would never fire and nothing would rebuild.
#
# --port 80, not 4200. docker-compose.yml already maps host 4200 to container
# 80 for the nginx image, and compose APPENDS ports across files rather than
# replacing them - publishing 4200:4200 here as well would bind host port 4200
# twice and fail to start.
#
# --host 0.0.0.0 because the default binds loopback inside the container, which
# nothing outside it can reach.
log "starting the Angular dev server on container port 80"
exec npx ng serve \
    --host 0.0.0.0 \
    --port 80 \
    --poll "${WEBAPP_POLL_INTERVAL:-2000}"
