#!/bin/sh
# Suite D (concurrency): a READ-ONLY integrity scan of a Maven volume after
# twelve builds shared it, printed as HCRESULT lines (test/container/lib.sh).
#
#     sh /test/container/scan-repo.sh [--m2 DIR] [--no-wrapper]
#     sh /test/container/scan-repo.sh --snapshot [--m2 DIR]
#
# Run by test/lib/SuiteConcurrency.ps1 in a `compose run --rm` of user-service,
# with the volume at /root/.m2 (the default for --m2). In D-REAL that is your
# REAL Maven cache, and the checkout is mounted read-write, so this writes
# NOTHING outside the container's own /tmp: no touch, no mvn goal, and Java
# only as `java File.java`, which compiles in memory.
#
# The repository (ids SCAN-*):
#
#   SCAN-REPO       there is something to scan at all
#   SCAN-LEFTOVERS  no *.tmp (the resolver's download-in-progress names),
#                   *.lastUpdated (a failed resolution) or *.part* files
#   SCAN-ZERO       no zero-byte jar or pom
#   SCAN-SHA1       every X.sha1 that the resolver stored agrees with X
#   SCAN-JARS       every entry of every jar reads back with the right CRC
#                   (test/java/VerifyJars.java)
#   SCAN-LOCKS      .locks holds artifact~*.lock files NOW, after every build
#                   has exited. With the resolver's default they would not be
#                   there: file-lock opens each one DELETE_ON_CLOSE, which the
#                   JDK does by unlinking it straight after open - and a lock
#                   on an unlinked file excludes nobody. Files that persist
#                   prove deleteLockFiles=false reached the JVMs that took
#                   them, which is why this runs after an mvnd-only AND after
#                   an mvnw-only round.
#
# The Maven Wrapper's install under <m2>/wrapper (ids WRAP-*):
#
#   WRAP-DISTS      at least one installed distribution
#   WRAP-NESTED     no <dist>/<hash>/apache-maven-* inside one: what mvnw's
#                   `mv` makes of a second install racing the first
#   WRAP-COMPLETE   bin/mvn, lib/maven-core-*.jar and boot/plexus-classworlds-*
#                   are all there (dev-reload.sh's dist_complete)
#   WRAP-VERSION    bin/mvn --version runs, and is the version the directory
#                   is named for
#   WRAP-URL        the install sits exactly where mvnw looks for the
#                   checkout's distributionUrl
#   WRAP-TMP        nothing left in wrapper/tmp by an interrupted install
#
# --snapshot prints "<path> <size>" for every jar, pom and sha1 (sorted, the
# .locks directory and maven-metadata* excluded) and nothing else: D-WARM
# compares one taken before a warm round with one taken after it.
#
# POSIX sh; runs under dash in homecrew-dev-runtime:jdk25.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"

M2=${HOME:-/root}/.m2
WRAPPER=1
MODE=scan
while [ $# -gt 0 ]; do
    case $1 in
        --m2)         [ $# -ge 2 ] || { echo "--m2 needs a directory" >&2; exit 2; }; M2=${2%/}; shift ;;
        --no-wrapper) WRAPPER=0 ;;
        --snapshot)   MODE=snapshot ;;
        *)            echo "usage: scan-repo.sh [--m2 DIR] [--no-wrapper] | --snapshot [--m2 DIR]" >&2; exit 2 ;;
    esac
    shift
done
REPO=$M2/repository
JAVA=${JAVA_HOME:+$JAVA_HOME/bin/}java

# Nothing below may depend on, or write to, the working directory - in D-REAL
# that is your checkout.
cd / || exit 1

count() { wc -l <"$1" | tr -d ' '; }
# The first few entries of a list, relative to the repository, on one line.
sample() { head -n "${2:-3}" "$1" | sed "s|^$REPO/||" | tr '\n' ' '; }

# ---------------------------------------------------------------------------

if [ "$MODE" = snapshot ]; then
    [ -d "$REPO" ] || { echo "no repository at $REPO" >&2; exit 1; }
    # ls -ln rather than find -printf: the size is field 5 in GNU and BSD ls
    # alike, so this reads the same wherever it is run. Maven paths have no
    # spaces, so the path is the last field.
    find "$REPO" -path "$REPO/.locks" -prune -o -type f \( -name '*.jar' -o -name '*.pom' -o -name '*.sha1' \) \
        ! -name 'maven-metadata*' ! -name 'resolver-status.properties' -exec ls -ln {} + |
        awk -v p="$REPO/" '{ f = $NF; if (index(f, p) == 1) f = substr(f, length(p) + 1); print f, $5 }' |
        LC_ALL=C sort
    exit 0
fi

TMPD=$(mktemp -d) || exit 1
trap 'rm -rf "$TMPD"' EXIT

# ---------------------------------------------------------------------------
# The repository
# ---------------------------------------------------------------------------

scan_repo() {
    if [ ! -d "$REPO" ]; then
        hc_fail SCAN-REPO "there is no repository at $REPO"
        return 0
    fi
    find "$REPO" -path "$REPO/.locks" -prune -o -type f -name '*.jar' -print >"$TMPD/jars"
    find "$REPO" -path "$REPO/.locks" -prune -o -type f -name '*.pom' -print >"$TMPD/poms"
    _jars=$(count "$TMPD/jars") _poms=$(count "$TMPD/poms")
    if [ "$_jars" -gt 0 ]; then
        hc_pass SCAN-REPO "$REPO holds $_jars jars and $_poms poms"
    else
        hc_fail SCAN-REPO "$REPO holds no jars ($_poms poms) - nothing was resolved into it"
        return 0
    fi

    # .locks is left out: it holds lock files, not artifacts, and a lock named
    # after an artifact that happens to contain ".part" is not a leftover.
    find "$REPO" -path "$REPO/.locks" -prune -o -type f \
        \( -name '*.tmp' -o -name '*.lastUpdated' -o -name '*.part*' \) -print >"$TMPD/leftovers"
    _n=$(count "$TMPD/leftovers")
    sed 's/^/LEFTOVER /' "$TMPD/leftovers"
    if [ "$_n" -eq 0 ]; then
        hc_pass SCAN-LEFTOVERS "no *.tmp, *.lastUpdated or *.part* files"
    else
        hc_fail SCAN-LEFTOVERS "$_n leftover files, e.g. $(sample "$TMPD/leftovers")"
    fi

    find "$REPO" -path "$REPO/.locks" -prune -o -type f \( -name '*.jar' -o -name '*.pom' \) -size 0 -print >"$TMPD/zero"
    _n=$(count "$TMPD/zero")
    sed 's/^/ZERO-BYTE /' "$TMPD/zero"
    if [ "$_n" -eq 0 ]; then
        hc_pass SCAN-ZERO "no zero-byte jar or pom"
    else
        hc_fail SCAN-ZERO "$_n zero-byte jars or poms, e.g. $(sample "$TMPD/zero")"
    fi

    scan_sha1
    scan_jars
    scan_locks
}

# A .sha1 may hold just the hash or "hash  filename" (Central has both), so the
# first 40-hex-digit word counts. One awk and one sha1sum for the whole
# repository rather than two processes per file: there are thousands.
scan_sha1() {
    find "$REPO" -path "$REPO/.locks" -prune -o -type f -name '*.sha1' -print | LC_ALL=C sort >"$TMPD/sha1-all"
    : >"$TMPD/sha1-have"; : >"$TMPD/orphans"
    while IFS= read -r _f; do
        if [ -f "${_f%.sha1}" ]; then printf '%s\n' "$_f" >>"$TMPD/sha1-have"; else printf '%s\n' "$_f" >>"$TMPD/orphans"; fi
    done <"$TMPD/sha1-all"
    : >"$TMPD/sha1-check"
    if [ -s "$TMPD/sha1-have" ]; then
        tr '\n' '\0' <"$TMPD/sha1-have" | xargs -0 awk '
            FNR == 1 { found = 0 }
            !found {
                for (i = 1; i <= NF; i++)
                    if (length($i) == 40 && $i ~ /^[0-9a-fA-F]+$/) {
                        print tolower($i) "  " substr(FILENAME, 1, length(FILENAME) - 5)
                        found = 1
                        break
                    }
            }' >"$TMPD/sha1-check"
    fi
    # Files whose .sha1 has no hash in it at all: not comparable, so not good.
    # Both sides sorted again: taking a suffix off can change the order.
    sed 's/\.sha1$//' "$TMPD/sha1-have" | LC_ALL=C sort >"$TMPD/want"
    sed 's/^[0-9a-f]*  //' "$TMPD/sha1-check" | LC_ALL=C sort >"$TMPD/got"
    LC_ALL=C comm -23 "$TMPD/want" "$TMPD/got" >"$TMPD/nohash"
    : >"$TMPD/mismatch"
    if [ -s "$TMPD/sha1-check" ]; then
        # --quiet prints only the files that do not match.
        sha1sum -c --quiet "$TMPD/sha1-check" 2>/dev/null | sed -n 's/: FAILED.*$//p' >"$TMPD/mismatch"
    fi
    _checked=$(count "$TMPD/sha1-check") _bad=$(count "$TMPD/mismatch") _nohash=$(count "$TMPD/nohash") _orph=$(count "$TMPD/orphans")
    sed 's/^/SHA1-MISMATCH /' "$TMPD/mismatch"
    sed 's/^/SHA1-UNREADABLE /' "$TMPD/nohash"
    sed 's/^/SHA1-ORPHAN /' "$TMPD/orphans"
    if [ "$_bad" -gt 0 ] || [ "$_nohash" -gt 0 ]; then
        hc_fail SCAN-SHA1 "$_bad of $_checked files do not match their .sha1 and $_nohash .sha1 files hold no hash, e.g. $(cat "$TMPD/mismatch" "$TMPD/nohash" | sample /dev/stdin)"
    elif [ "$_checked" -eq 0 ]; then
        hc_warn SCAN-SHA1 "no .sha1 files to compare - the resolver stored no checksums"
    elif [ "$_orph" -gt 0 ]; then
        hc_warn SCAN-SHA1 "all $_checked files match their .sha1, but $_orph .sha1 files have no file beside them, e.g. $(sample "$TMPD/orphans")"
    else
        hc_pass SCAN-SHA1 "all $_checked files match their .sha1"
    fi
}

scan_jars() {
    "$JAVA" "$HERE/../java/VerifyJars.java" "$REPO" >"$TMPD/verify" 2>&1
    _rc=$?
    cat "$TMPD/verify"
    _sum=$(grep '^VERIFY-JARS ' "$TMPD/verify" | tail -n 1)
    if [ "$_rc" -eq 0 ] && [ -n "$_sum" ]; then
        hc_pass SCAN-JARS "every entry of every jar reads back intact: ${_sum#VERIFY-JARS }"
    elif [ "$_rc" -eq 1 ]; then
        hc_fail SCAN-JARS "broken jars: ${_sum#VERIFY-JARS }; $(grep '^BROKEN ' "$TMPD/verify" | sed 's/^BROKEN //' | sample /dev/stdin 2)"
    else
        hc_fail SCAN-JARS "VerifyJars.java did not run (exit $_rc): $(tail -n 2 "$TMPD/verify" | tr '\n' ' ')"
    fi
}

scan_locks() {
    _ld=$REPO/.locks
    if [ ! -d "$_ld" ]; then
        hc_fail SCAN-LOCKS "there is no $_ld: the file-lock factory never ran against this repository"
        return 0
    fi
    _a=$(find "$_ld" -maxdepth 1 -type f -name 'artifact~*.lock' | wc -l | tr -d ' ')
    _m=$(find "$_ld" -maxdepth 1 -type f -name 'metadata~*.lock' | wc -l | tr -d ' ')
    if [ "$_a" -gt 0 ]; then
        hc_pass SCAN-LOCKS "$_a artifact~*.lock and $_m metadata~*.lock files are still in .locks after every build exited - deleteLockFiles=false was in effect"
    else
        hc_fail SCAN-LOCKS ".locks exists but holds no artifact~*.lock ($_m metadata~*.lock): the lock files were deleted as they were opened, so they excluded nobody"
    fi
}

# ---------------------------------------------------------------------------
# The wrapper's install
# ---------------------------------------------------------------------------

# mvnw's own hash_string (maven-wrapper 3.3.4), as in build-once.sh: Java's
# String.hashCode of the distribution URL, in hex.
hash_string() {
    str="${1:-}" h=0
    while [ -n "$str" ]; do
        char="${str%"${str#?}"}"
        h=$(((h * 31 + $(LC_CTYPE=C printf %d "'$char")) % 4294967296))
        str="${str#?}"
    done
    printf %x\\n $h
}

dist_complete() {
    [ -f "$1/bin/mvn" ] && ls "$1"/lib/maven-core-*.jar >/dev/null 2>&1 && ls "$1"/boot/plexus-classworlds-*.jar >/dev/null 2>&1
}

scan_wrapper() {
    _wd=$M2/wrapper
    find "$_wd/dists" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | LC_ALL=C sort >"$TMPD/dists"
    _n=$(count "$TMPD/dists")
    if [ "$_n" -eq 0 ]; then
        hc_fail WRAP-DISTS "no Maven install under $_wd/dists"
        return 0
    fi
    _list=$(sed "s|^$_wd/dists/||" "$TMPD/dists" | tr '\n' ' ')
    if [ "$_n" -eq 1 ]; then hc_pass WRAP-DISTS "one install: $_list"
    else hc_warn WRAP-DISTS "$_n installs where the twelve checkouts pin one distributionUrl: $_list"; fi

    _nested="" _incomplete="" _vbad="" _vok=""
    while IFS= read -r _d; do
        for _x in "$_d"/apache-maven-*; do
            [ -d "$_x" ] && _nested="$_nested ${_x#"$_wd"/dists/}"
        done
        if ! dist_complete "$_d"; then _incomplete="$_incomplete ${_d#"$_wd"/dists/}"; fi
        _want=$(basename "$(dirname "$_d")" | sed -n 's/^apache-maven-//p')
        # From /tmp, so that no .mvn/ of any checkout is picked up. The
        # version line, not the first line: a JAVA_TOOL_OPTIONS would put its
        # "Picked up" note first.
        _out=$(cd /tmp && "$_d/bin/mvn" --version 2>&1)
        _got=$(printf '%s\n' "$_out" | grep -m 1 '^Apache Maven ') || _got=$(printf '%s\n' "$_out" | head -n 1)
        echo "WRAP ${_d#"$_wd"/dists/}: $_got"
        case $_got in
            "Apache Maven $_want "*|"Apache Maven $_want") _vok="$_vok $_want" ;;
            *) _vbad="$_vbad ${_d#"$_wd"/dists/}=[$_got]" ;;
        esac
    done <"$TMPD/dists"

    if [ -z "$_nested" ]; then hc_pass WRAP-NESTED "no apache-maven-* directory inside an install"
    else hc_fail WRAP-NESTED "a second install was moved INTO the first:$_nested"; fi
    if [ -z "$_incomplete" ]; then hc_pass WRAP-COMPLETE "bin/mvn, lib/maven-core and boot/plexus-classworlds present in every install"
    else hc_fail WRAP-COMPLETE "incomplete:$_incomplete"; fi
    if [ -z "$_vbad" ]; then hc_pass WRAP-VERSION "bin/mvn --version runs: Apache Maven$_vok"
    else hc_fail WRAP-VERSION "bin/mvn --version does not report the version it is installed as:$_vbad"; fi

    # Where mvnw will look for THIS checkout's distributionUrl.
    _props=${DEV_APP_DIR:-/app}/.mvn/wrapper/maven-wrapper.properties
    _url=$(sed -n 's/^distributionUrl=//p' "$_props" 2>/dev/null | tr -d '\r[:space:]')
    if [ -z "$_url" ]; then
        hc_skip WRAP-URL "no distributionUrl in $_props to compare with"
    else
        _name=${_url##*/}; _name=${_name%.*}; _name=${_name%-bin}
        _home=$_wd/dists/$_name/$(hash_string "$_url")
        if dist_complete "$_home"; then hc_pass WRAP-URL "mvnw's MAVEN_HOME for $_url is ${_home#"$_wd"/} and complete"
        else hc_fail WRAP-URL "mvnw would use ${_home#"$_wd"/} for $_url, and it is missing or incomplete"; fi
    fi

    if [ -d "$_wd/tmp" ] && [ -n "$(ls -A "$_wd/tmp" 2>/dev/null)" ]; then
        hc_warn WRAP-TMP "left in $_wd/tmp by an interrupted install: $(ls -A "$_wd/tmp" | head -n 5 | tr '\n' ' ')"
    else
        hc_pass WRAP-TMP "$_wd/tmp is empty"
    fi
}

scan_repo
if [ "$WRAPPER" = 1 ]; then scan_wrapper; fi
hc_exit
