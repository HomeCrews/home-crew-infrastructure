#!/bin/sh
# Check: the full Maven gate passes.
#
# Tests, Spotless, Checkstyle, SpotBugs and JaCoCo. This is the slow one; it
# runs at pre-push so a red build never reaches the remote and never triggers
# the Docker publish or the infrastructure deployment.
set -eu
. "$(dirname "$0")/../common.sh"

is_maven_repo || { ok "not a Maven repo; skipped build"; exit 0; }

check_jdk_version

MVNW=$(mvn_wrapper) || fail "no Maven wrapper (./mvnw) and no mvn on PATH."

info "running the full build gate - this takes a while"
info "  (tests, Spotless, Checkstyle, SpotBugs, JaCoCo)"

if ! "$MVNW" --batch-mode clean verify; then
    fail "the build failed; push aborted." \
        "  Scroll up for the specific failure. Common causes:" \
        "" \
        "    Spotless    ->  ./mvnw spotless:apply" \
        "    Checkstyle  ->  target/checkstyle-result.xml" \
        "    SpotBugs    ->  target/spotbugsXml.xml" \
        "    JaCoCo      ->  target/site/jacoco/index.html" \
        "    Tests       ->  target/surefire-reports/" \
        "" \
        "  Pushing a broken build triggers the Docker publish and the" \
        "  infrastructure deployment, so this gate is not advisory."
fi

ok "build green"
