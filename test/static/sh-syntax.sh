#!/bin/sh
# Suite A, A-SH: every shell script of the dev setup, parsed by every shell that
# is present to parse it, and checked for CR bytes.
#
#     sh test/static/sh-syntax.sh <infra-root> [<where>]
#
# Run in three places by test/lib/SuiteStatic.ps1, because each is a different
# parser that really runs these files: the host (Git Bash's sh.exe on Windows,
# /bin/sh elsewhere), homecrew-dev-runtime:jdk25 (dash is /bin/sh there, plus
# bash) and node:24-alpine (busybox ash). test/run.sh runs it on the host when
# there is no pwsh. <where> (host, image, alpine) goes into every result id,
# so the three runs do not report the same ids:
#
#     HCRESULT  A-SH-<where>-<shell>-<file>  PASS|FAIL  ...
#     HCRESULT  A-SH-<where>-cr-<file>       PASS|FAIL  ...
#
# Without <where> the ids are A-SH-<shell>-<file> and A-SH-cr-<file>.
#
# `<shell> -n` only proves the file PARSES in that shell: dash and busybox
# reject bash-only syntax (arrays, [[ at the wrong place, function f {), but a
# bashism that is merely an unknown command at run time still passes. That is
# what suite C and the CLI suite are for; this is the cheap gate in front.
#
# Exit status: 0 when every file parsed everywhere and none had a CR, 1 when
# anything failed, 2 when it could not run at all.

set -u

ROOT=${1:-}
WHERE=${2:-}
if [ -z "$ROOT" ]; then
    printf '%s\n' "usage: sh-syntax.sh <infra-root> [<where>]" >&2
    exit 2
fi
# Everything below uses paths relative to the root, so the ids and messages
# are the same whatever the root is called on each host - C:/Users/..., /src,
# a checkout path with a space in it.
cd "$ROOT" || exit 2
if [ ! -f test/container/lib.sh ]; then
    printf '%s\n' "sh-syntax.sh: $ROOT/test/container/lib.sh not found - is <infra-root> right?" >&2
    exit 2
fi
. ./test/container/lib.sh

P=A-SH-
[ -n "$WHERE" ] && P="A-SH-$WHERE-"

CR=$(printf '\r')
NL='
'

# The resolved binary behind a command, so that sh can be dropped when it is
# only another name for dash (Ubuntu) or busybox (alpine): the same parser
# twice adds a row, not a check. Where readlink -f is missing, the path itself
# is compared, which at worst keeps a duplicate.
real_path() {
    _p=$(command -v "$1" 2>/dev/null) || return 1
    readlink -f "$_p" 2>/dev/null || printf '%s\n' "$_p"
}

SHELLS=""
for _s in dash bash; do
    command -v "$_s" >/dev/null 2>&1 && SHELLS="$SHELLS $_s"
done
if command -v busybox >/dev/null 2>&1 && busybox sh -c : >/dev/null 2>&1; then
    SHELLS="$SHELLS busybox"
fi
if _sh=$(real_path sh); then
    _dup=""
    for _s in $SHELLS; do
        [ "$_s" = bash ] && continue    # a bash that is also sh parses in POSIX mode: keep both
        if [ "$(real_path "$_s")" = "$_sh" ]; then _dup=$_s; fi
    done
    if [ -n "$_dup" ]; then
        printf '%s\n' "sh is $_sh here, the same binary as $_dup: parsed once, as $_dup"
    else
        SHELLS="sh$SHELLS"
    fi
fi
printf '%s\n' "shells here:${SHELLS:- none}"

parse() {
    case $1 in
        busybox) busybox sh -n "$2" ;;
        *)       "$1" -n "$2" ;;
    esac
}

# The files. Globs rather than find: on Git Bash an unqualified find or sort can
# be the Windows program of the same name when PATH is not what it should be,
# and globs need nothing at all. Six levels is far deeper than test/ goes.
# test/results/ is output, not source.
FILES="dev${NL}dev-reload.sh${NL}webapp-dev.sh"
for _f in test/*.sh test/*/*.sh test/*/*/*.sh test/*/*/*/*.sh test/*/*/*/*/*.sh test/*/*/*/*/*/*.sh; do
    [ -f "$_f" ] || continue
    case $_f in test/results/*) continue ;; esac
    FILES="$FILES$NL$_f"
done

# One file per line, and no globbing of the names while iterating.
set -f
_ifs=$IFS
IFS=$NL
COUNT=0
for f in $FILES; do
    IFS=$_ifs
    COUNT=$((COUNT + 1))
    if [ ! -f "$f" ]; then
        hc_fail "${P}missing-$f" "$f does not exist under $ROOT"
        IFS=$NL
        continue
    fi

    # A CR anywhere breaks these inside the Linux containers (set -eu\r), and
    # in Git Bash. .gitattributes forces LF for all of them; a CR means an old
    # clone from before that rule, or an editor that rewrote the endings.
    # grep -c: 0 = found, 1 = not found, anything else = it could not look,
    # which must not read as "no CR".
    _n=$(LC_ALL=C grep -c "$CR" "$f" 2>/dev/null)
    case $? in
        0) hc_fail "${P}cr-$f" "$f has CR bytes on $_n line(s) (CRLF line endings). Tracked: rm $f && git checkout -- $f. Not committed yet: convert it to LF in the editor" ;;
        1) hc_pass "${P}cr-$f" "$f: LF only" ;;
        *) hc_fail "${P}cr-$f" "$f: could not be checked for CR bytes (grep failed)" ;;
    esac

    for s in $SHELLS; do
        _cmd=$s
        [ "$s" = busybox ] && _cmd="busybox sh"
        _err=$(parse "$s" "$f" 2>&1 >/dev/null)
        _rc=$?
        # Only the first two lines of the complaint: enough to find the spot.
        _err=$(printf '%s\n' "$_err" | sed -n '1,2p' | tr '\n' ' ')
        if [ "$_rc" -eq 0 ]; then
            hc_pass "${P}$s-$f" "$_cmd -n $f: parses"
        else
            hc_fail "${P}$s-$f" "$_cmd -n $f: exit $_rc: ${_err:-no message}"
        fi
    done
    IFS=$NL
done
IFS=$_ifs
set +f

printf '%s\n' "checked $COUNT file(s) with:${SHELLS:- no shell}"
hc_exit
